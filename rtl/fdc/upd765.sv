// upd765.sv - a uPD765A / i8272A floppy disk controller with a synthetic,
// image-backed disk surface.
//
// The command layer is the real chip's (command, execution and result
// phases, MSR, ST0-ST3, interrupts, DMA and non-DMA transfers, overlapped
// seeks). Instead of a data separator it sees an IBM MFM track computed from
// the geometry of the medium (doc/fdc.md, "Timing model"): a rotating byte
// position, an index pulse per revolution, ID fields and data fields at the
// standard positions. Sector data come from a two-slot sector buffer that the
// sector engine (fdc_secbuf.sv) fills from / commits to the disk image.
//
// Everything on clk with a 1 us enable (us_tick). Commands:
//   02 READ TRACK, 03 SPECIFY, 04 SENSE DRIVE STATUS, 05 WRITE DATA,
//   06 READ DATA, 07 RECALIBRATE, 08 SENSE INTERRUPT STATUS,
//   09 WRITE DELETED DATA, 0A READ ID, 0C READ DELETED DATA,
//   0D FORMAT TRACK, 0F SEEK. Everything else (the SCAN commands too) is
//   an invalid command: one result byte, ST0 = 0x80.
//
// Behavioural references: NEC uPD765A / Intel 8272A data sheets; MartyPC
// (MIT, D. Balsom) devices/fdc for the PC-specific interrupt and Sense
// Interrupt Status behaviour. No code taken from either.
//
// GPL-3.0-or-later, pc10-iii.

module upd765 #(
    // 765 timing units: 1 = 8 MHz chip clock, 2 = 4 MHz (the 250 kbit/s
    // case, also the 82077's 250 kbit/s table): SRT 2 ms, HUT 32 ms,
    // HLT 4 ms per unit. CAL: the PC adapter's 765 clock.
    parameter int TIME_SCALE   = 2,
    parameter int BYTE_US      = 32,      // 250 kbit/s MFM
    parameter int TRACK_BYTES  = 6250,    // 200 ms at 300 RPM
    parameter int RQM_DELAY_US = 12,      // RQM low after each command/result byte (CAL)
    parameter int RESET_US     = 1000     // reset release -> ready + interrupt (MartyPC)
) (
    input  logic        clk,
    input  logic        reset,          // RESET pin (bus reset or DOR bit 2 = 0)
    input  logic        por,            // bus reset: also clears the SPECIFY values
    input  logic        us_tick,        // 1 us enable

    // processor interface (A0 = 0: MSR, A0 = 1: data register)
    input  logic        cpu_rd,         // one clk per read cycle; cpu_rdata valid in it
    input  logic        cpu_wr,         // one clk per write cycle
    input  logic        cpu_a0,
    input  logic [7:0]  cpu_wdata,
    output logic [7:0]  cpu_rdata,

    // DMA
    output logic        drq,
    input  logic        dma_ack,        // one clk: a DACK cycle's strobe started (read: byte taken)
    input  logic        dma_wr,         // one clk: write data valid (end of the write strobe)
    input  logic [7:0]  dma_wdata,
    output logic [7:0]  dma_rdata,
    input  logic        tc,             // one clk: the DACK cycle that just ended had TC
    output logic        intr,

    // drive interface (the drive the adapter has selected)
    output logic [1:0]  us,             // unit of the current/last command
    output logic        hd,             // head select
    output logic        step,           // one-clk step pulse
    output logic        step_dir,       // 1 = inward (cylinder + 1)
    input  logic        drv_trk0,
    input  logic        drv_wp,
    input  logic        drv_ready,      // READY pin (the PC ties it high)
    input  logic        drv_ts,         // TS pin (two-sided)
    input  logic        drv_spin,       // index pulses come: drive selected, medium in, motor on
    input  logic [7:0]  drv_cyl,        // physical head position = C of the ID fields
    input  logic [7:0]  geo_tracks,     // medium geometry (selected drive)
    input  logic [1:0]  geo_heads,
    input  logic [5:0]  geo_spt,

    // sector buffer, 2 slots x 512 bytes, 1 clk read latency
    output logic [9:0]  buf_addr,
    output logic        buf_we,
    output logic [7:0]  buf_wdata,
    input  logic [7:0]  buf_rdata,

    // sector engine (fdc_secbuf.sv)
    output logic        x_start,        // one clk
    output logic        x_write,
    output logic        x_slot,
    output logic [7:0]  x_cyl,
    output logic        x_head,
    output logic [7:0]  x_sec,
    input  logic        x_busy,         // includes the clk of x_start
    input  logic        x_done,         // one clk
    input  logic        x_err,

    output logic        active          // execution phase (for an activity LED)
);

// ======================================================================
// constants
// ======================================================================
localparam int PRE      = 146;          // GAP4a 80 + sync 12 + IAM 4 + GAP1 50
localparam int ID_END   = 22;           // sync 12 + IDAM 4 + CHRN 4 + CRC 2
localparam int DATA0    = 60;           // + GAP2 22 + sync 12 + DAM 4
localparam int SEC_END  = DATA0 + 514;  // 512 data + CRC 2

typedef enum logic [3:0] {
    OP_INV, OP_RTRK, OP_SPEC, OP_SDS, OP_WR, OP_RD, OP_RECAL, OP_SIS,
    OP_WRDEL, OP_RID, OP_RDDEL, OP_FMT, OP_SEEK
} op_t;

typedef enum logic [1:0] { PH_RESET, PH_CMD, PH_EXEC, PH_RES } ph_t;

typedef enum logic [3:0] {
    EX_IDLE, EX_WAITSP, EX_HLOAD, EX_START, EX_INDEX, EX_SEARCH, EX_SLOT,
    EX_DATA, EX_FMT, EX_FMTSLOT, EX_FMTFILL, EX_FMTEND, EX_DRAIN
} ex_t;

typedef enum logic [2:0] { SL_EMPTY, SL_BUSYR, SL_READY, SL_ERR, SL_DIRTY, SL_BUSYW } sl_t;

localparam logic [1:0] UA_NONE = 2'd0, UA_SEEK = 2'd1, UA_READY = 2'd2;

// ======================================================================
// time base
// ======================================================================
logic [9:0] ms_cnt;
wire        ms_tick = us_tick && ms_cnt == 10'd999;
always_ff @(posedge clk)
    if (por) ms_cnt <= 10'd0;
    else if (us_tick) ms_cnt <= ms_tick ? 10'd0 : ms_cnt + 10'd1;

logic [5:0] byte_cnt;
wire        byte_tick = us_tick && byte_cnt == 6'(BYTE_US - 1);
always_ff @(posedge clk)
    if (por) byte_cnt <= 6'd0;
    else if (us_tick) byte_cnt <= byte_tick ? 6'd0 : byte_cnt + 6'd1;

// ======================================================================
// rotation: one byte position per byte time; held while the sector buffer
// is not ready (the backend is slower than the disk).
// ======================================================================
logic        rot_hold;
logic [13:0] rpos;
logic [4:0]  rsec;                     // sector slot under the head, 31 = none
logic [10:0] roff;                     // byte offset within the sector pitch
logic        ev_adv;                   // the head moved one byte (last clk)

function automatic logic [10:0] pitch_of(input logic [5:0] spt);
    // ID 22 + GAP2 22 + sync 12 + DAM 4 + 512 + CRC 2 + GAP3
    if (spt <= 6'd9)       pitch_of = 11'(574 + 80);   // 0x50: 160K-720K
    else if (spt <= 6'd15) pitch_of = 11'(574 + 84);   // 0x54: 1.2M
    else                   pitch_of = 11'(574 + 108);  // 0x6C: 1.44M
endfunction
wire [10:0] pitch = pitch_of(geo_spt);

wire radv = byte_tick && !rot_hold;
always_ff @(posedge clk) begin
    ev_adv <= radv;
    if (por) begin
        rpos <= 14'd0;
        rsec <= 5'd31;
        roff <= 11'd0;
    end else if (radv) begin
        if (rpos == 14'(TRACK_BYTES - 1)) begin
            rpos <= 14'd0;
            rsec <= 5'd31;
        end else
            rpos <= rpos + 14'd1;
        if (rpos == 14'(PRE - 1)) begin
            rsec <= 5'd0;
            roff <= 11'd0;
        end else if (rsec != 5'd31) begin
            if (roff == pitch - 11'd1) begin
                roff <= 11'd0;
                rsec <= rsec + 5'd1;
            end else
                roff <= roff + 11'd1;
        end
    end
end

// the surface under the head (events are one-clk pulses after ev_adv)
wire        trk_fmt  = drv_spin && drv_cyl < geo_tracks && {1'b0, hd} < geo_heads;
wire        in_sec   = rsec != 5'd31 && {1'b0, rsec} < geo_spt;
wire        ev_index = ev_adv && rpos == 14'd0 && drv_spin;
wire        ev_id    = ev_adv && trk_fmt && in_sec && roff == 11'(ID_END);
wire        ev_dat   = ev_adv && trk_fmt && in_sec && roff >= 11'(DATA0) && roff < 11'(DATA0 + 512);
wire        ev_send  = ev_adv && trk_fmt && in_sec && roff == 11'(SEC_END);
wire [8:0]  didx     = 9'(roff - 11'(DATA0));
wire [7:0]  id_r     = 8'(rsec) + 8'd1;

// ======================================================================
// registers
// ======================================================================
ph_t        ph;
ex_t        ex;
op_t        op;
logic [3:0] cmd_len, cmd_n;
logic [7:0] cmd_buf [9];
logic       exec_go;
logic       mt, mf, sk;
logic [7:0] res [7];
logic [2:0] res_n, res_i;
logic [7:0] last_data;
logic [4:0] rqm_dly;
logic [10:0] rst_cnt;

// SPECIFY
logic [3:0] srt, hut;
logic [6:0] hlt;
logic       nd;

// execution
logic [7:0] c_r, h_r, r_r, n_r, eot_r, gpl_r, dtl_r;
logic       dir_rd, dir_wr;            // data direction of the current command
logic       idx_cnt;                   // one index pulse seen while searching
logic       seen_id, seen_wc;
logic       xfer;                      // this sector's data go to/from the host
logic       xslot;                     // slot of the next sector transfer
logic       cm_flag, cm_term, nd_flag;
logic       tc_seen, wr_err;
logic [7:0] trk_cnt;                   // READ TRACK: sectors read
logic [7:0] latch;
logic       latch_full, want, wr_inflight, rd_addr, rd_pend;  // buffer read: address, data
logic [19:0] tmr_us;                   // head load wait
logic       hd_loaded;
logic [1:0] hd_unit;
logic [12:0] hut_ms;

// format
logic [13:0] fpos, fnext;
logic [7:0]  fk;
logic [1:0]  fj;
logic [7:0]  fid [4];
logic [8:0]  fill_cnt;

// sector slots
sl_t        slot_st [2];
logic [16:0] slot_tag [2];             // {cyl, head, sector}
logic       fetch_pend;
logic       fetch_slot;
logic [16:0] fetch_tag;
logic       eng_slot, eng_wr;

// seeks (owned by the seek block below)
logic [7:0] pcn [4];
logic [1:0] unack [4];
logic [7:0] ust0 [4];
logic [3:0] seeking;
logic       int_sense;
logic       sis_take;
logic [1:0] sis_unit;
logic       rdy_poll;
logic       sk_start, sk_recal;
logic [1:0] sk_unit;
logic [7:0] sk_ncn;
logic       sk_hd;

logic       int_res;

// ======================================================================
// helpers
// ======================================================================
op_t        dec_op;
logic [3:0] dec_len;
always_comb begin
    case (cpu_wdata[4:0])
        5'h02: begin dec_op = OP_RTRK; dec_len = 4'd9; end
        5'h03: begin dec_op = OP_SPEC; dec_len = 4'd3; end
        5'h04: begin dec_op = OP_SDS; dec_len = 4'd2; end
        5'h05: begin dec_op = OP_WR; dec_len = 4'd9; end
        5'h06: begin dec_op = OP_RD; dec_len = 4'd9; end
        5'h07: begin dec_op = OP_RECAL; dec_len = 4'd2; end
        5'h08: begin dec_op = OP_SIS; dec_len = 4'd1; end
        5'h09: begin dec_op = OP_WRDEL; dec_len = 4'd9; end
        5'h0A: begin dec_op = OP_RID; dec_len = 4'd2; end
        5'h0C: begin dec_op = OP_RDDEL; dec_len = 4'd9; end
        5'h0D: begin dec_op = OP_FMT; dec_len = 4'd6; end
        5'h0F: begin dec_op = OP_SEEK; dec_len = 4'd3; end
        default: begin dec_op = OP_INV; dec_len = 4'd1; end
    endcase
end

// position after the last sector transferred (data sheet table)
logic [7:0] nx_c, nx_h, nx_r;
always_comb begin
    nx_c = c_r;  nx_h = h_r;  nx_r = r_r + 8'd1;
    if (r_r == eot_r) begin
        nx_r = 8'd1;
        if (!mt)          nx_c = c_r + 8'd1;
        else if (!h_r[0]) nx_h = {h_r[7:1], 1'b1};
        else begin        nx_c = c_r + 8'd1;  nx_h = {h_r[7:1], 1'b0}; end
    end
end

// the next sector a multi-sector read would want, for the prefetch
logic        pf_ok;
logic [16:0] pf_tag;
always_comb begin
    pf_ok  = 1'b0;
    pf_tag = {drv_cyl, hd, r_r + 8'd1};
    if (op == OP_RD || op == OP_RDDEL) begin
        if (r_r != eot_r) begin
            pf_ok  = c_r == drv_cyl && h_r == {7'd0, hd} && n_r == 8'd2 &&
                     r_r + 8'd1 <= {2'b00, geo_spt};
        end else if (mt && !h_r[0]) begin
            pf_tag = {drv_cyl, 1'b1, 8'd1};
            pf_ok  = c_r == drv_cyl && h_r == 8'd0 && n_r == 8'd2 && geo_heads == 2'd2;
        end
    end
end

wire [16:0] cur_tag  = {drv_cyl, hd, (op == OP_RTRK) ? id_r : r_r};
wire        slot_free = slot_st[xslot] != SL_DIRTY && slot_st[xslot] != SL_BUSYW;
wire        wslot     = slot_st[0] != SL_DIRTY;    // slot to commit next
wire        drain_ok  = !dir_wr || (slot_st[0] != SL_DIRTY && slot_st[0] != SL_BUSYW &&
                                    slot_st[1] != SL_DIRTY && slot_st[1] != SL_BUSYW && !x_busy);
wire [7:0]  st0_cmd  = {2'b00, 1'b0, 1'b0, !drv_ready, hd, us};
wire        fmt_store = n_r == 8'd2 && fid[2] >= 8'd1 && fid[2] <= {2'b00, geo_spt} &&
                        drv_cyl < geo_tracks && {1'b0, hd} < geo_heads;
wire [13:0] fpitch   = 14'd62 + (14'd128 << n_r[2:0]) + 14'(gpl_r);
wire [16:0] step_us  = 17'((16 - int'(srt)) * 1000 * TIME_SCALE);

// PIO service request and DMA request
wire pio_req = dir_rd ? latch_full : (want && !latch_full);
wire xfer_ph = ph == PH_EXEC && (dir_rd || dir_wr);
assign drq   = xfer_ph && !nd && (dir_rd ? latch_full : (want && !latch_full && !wr_inflight));
assign intr  = ph != PH_RESET && (int_sense || int_res || (xfer_ph && nd && pio_req));
assign dma_rdata = latch;
assign active = ph == PH_EXEC;

assign rot_hold = ph == PH_EXEC && (ex == EX_SLOT || ex == EX_FMTSLOT);

// Sense Interrupt Status: pending ready changes first, then seek ends
logic       sis_ok;
logic [1:0] sis_u;
logic [7:0] sis_st0;
always_comb begin
    sis_ok = 1'b0;  sis_u = 2'd0;  sis_st0 = 8'h80;
    for (int u = 3; u >= 0; u--)
        if (unack[u] == UA_SEEK) begin sis_ok = 1'b1; sis_u = 2'(u); sis_st0 = ust0[u]; end
    for (int u = 3; u >= 0; u--)
        if (unack[u] == UA_READY) begin sis_ok = 1'b1; sis_u = 2'(u); sis_st0 = 8'hC0 | 8'(u); end
end

// ======================================================================
// MSR and read data
// ======================================================================
logic [7:0] msr;
always_comb begin
    msr = 8'h00;
    if (ph != PH_RESET) begin
        for (int u = 0; u < 4; u++)
            msr[u] = seeking[u] || unack[u] == UA_SEEK;
        msr[4] = (ph == PH_CMD && cmd_n != 4'd0) || ph == PH_EXEC || ph == PH_RES || exec_go;
        msr[5] = ph == PH_EXEC && nd;
        msr[6] = ph == PH_RES || (ph == PH_EXEC && dir_rd);
        msr[7] = ((ph == PH_CMD || ph == PH_RES) && !exec_go && rqm_dly == 5'd0) ||
                 (xfer_ph && nd && pio_req);
    end
end

always_comb begin
    if (!cpu_a0)                                    cpu_rdata = msr;
    else if (ph == PH_RES)                          cpu_rdata = res[res_i];
    else if (xfer_ph && nd && dir_rd && latch_full) cpu_rdata = latch;
    else                                            cpu_rdata = last_data;
end

wire take_now = dir_rd && xfer_ph && ((!nd && dma_ack) || (nd && cpu_rd && cpu_a0 && latch_full));
wire give_cpu = dir_wr && xfer_ph && nd && cpu_wr && cpu_a0 && want && !latch_full;

// ======================================================================
// the controller
// ======================================================================
task automatic finish(input logic [1:0] ic, input logic [7:0] st1, input logic [7:0] st2,
                      input logic [7:0] c, input logic [7:0] h, input logic [7:0] r, input logic [7:0] n);
    res[0] <= {ic, 6'd0} | st0_cmd;
    res[1] <= st1;
    res[2] <= st2 | (cm_flag ? 8'h40 : 8'h00);
    res[3] <= c;
    res[4] <= h;
    res[5] <= r;
    res[6] <= n;
    res_n  <= 3'd7;
    ex     <= EX_DRAIN;
    want   <= 1'b0;
    rd_addr <= 1'b0;
    rd_pend <= 1'b0;
    fetch_pend <= 1'b0;
    hut_ms <= 13'((hut == 4'd0 ? 16 : int'(hut)) * 16 * TIME_SCALE);
endtask

always_ff @(posedge clk) begin
    x_start  <= 1'b0;
    buf_we   <= 1'b0;
    sis_take <= 1'b0;
    rdy_poll <= 1'b0;
    sk_start <= 1'b0;
    exec_go  <= 1'b0;

    if (reset) begin
        ph <= PH_RESET;  ex <= EX_IDLE;  op <= OP_INV;
        rst_cnt <= 11'(RESET_US);
        cmd_n <= 4'd0;  cmd_len <= 4'd1;  res_i <= 3'd0;  res_n <= 3'd0;
        rqm_dly <= 5'd0;
        int_res <= 1'b0;
        latch_full <= 1'b0;  want <= 1'b0;  wr_inflight <= 1'b0;  rd_pend <= 1'b0;  rd_addr <= 1'b0;
        dir_rd <= 1'b0;  dir_wr <= 1'b0;
        hd_loaded <= 1'b0;  hut_ms <= 13'd0;
        slot_st[0] <= SL_EMPTY;  slot_st[1] <= SL_EMPTY;
        fetch_pend <= 1'b0;
        tc_seen <= 1'b0;
        us <= 2'd0;  hd <= 1'b0;
        if (por) begin
            srt <= 4'd0;  hut <= 4'd0;  hlt <= 7'd0;  nd <= 1'b0;
            last_data <= 8'h00;
        end
    end else begin
        // ---------------------------------------------------- timers
        if (us_tick && rqm_dly != 5'd0) rqm_dly <= rqm_dly - 5'd1;
        if (ms_tick && hut_ms != 13'd0) begin
            hut_ms <= hut_ms - 13'd1;
            if (hut_ms == 13'd1) hd_loaded <= 1'b0;
        end

        // ---------------------------------------------------- reset wait
        if (ph == PH_RESET && us_tick) begin
            if (rst_cnt == 11'd0) begin
                ph <= PH_CMD;
                rdy_poll <= 1'b1;
            end else
                rst_cnt <= rst_cnt - 11'd1;
        end

        // ---------------------------------------------------- sector engine
        if (x_done) begin
            if (eng_wr) begin
                slot_st[eng_slot] <= SL_EMPTY;
                if (x_err) wr_err <= 1'b1;
            end else
                slot_st[eng_slot] <= x_err ? SL_ERR : SL_READY;
        end
        if (!x_busy) begin
            if (fetch_pend) begin
                x_start <= 1'b1;  x_write <= 1'b0;  x_slot <= fetch_slot;
                {x_cyl, x_head, x_sec} <= fetch_tag;
                slot_st[fetch_slot] <= SL_BUSYR;
                slot_tag[fetch_slot] <= fetch_tag;
                eng_slot <= fetch_slot;  eng_wr <= 1'b0;
                fetch_pend <= 1'b0;
            end else if (slot_st[0] == SL_DIRTY || slot_st[1] == SL_DIRTY) begin
                x_start <= 1'b1;  x_write <= 1'b1;  x_slot <= wslot;
                {x_cyl, x_head, x_sec} <= slot_tag[wslot];
                slot_st[wslot] <= SL_BUSYW;
                eng_slot <= wslot;  eng_wr <= 1'b1;
            end
        end

        // ---------------------------------------------------- data latch
        if (take_now) latch_full <= 1'b0;
        if (xfer_ph && dir_wr && !nd && dma_ack) wr_inflight <= 1'b1;
        if (xfer_ph && dir_wr && dma_wr) begin
            latch <= dma_wdata;  latch_full <= 1'b1;  wr_inflight <= 1'b0;
        end
        if (give_cpu) begin
            latch <= cpu_wdata;  latch_full <= 1'b1;
        end
        if (ph == PH_EXEC && tc) begin
            tc_seen <= 1'b1;
            if (dir_wr) want <= 1'b0;
        end
        rd_addr <= 1'b0;
        rd_pend <= rd_addr;
        if (rd_pend) begin
            if (latch_full && !take_now)
                finish(2'b01, 8'h10, 8'h00, c_r, h_r, r_r, n_r);      // OR
            else begin
                latch <= buf_rdata;
                latch_full <= 1'b1;
            end
        end

        // ---------------------------------------------------- processor
        if (cpu_rd && cpu_a0) begin
            last_data <= cpu_rdata;
            if (ph == PH_RES) begin
                int_res <= 1'b0;
                rqm_dly <= 5'(RQM_DELAY_US);
                if (res_i == res_n - 3'd1) begin
                    ph <= PH_CMD;
                    res_i <= 3'd0;
                    dir_rd <= 1'b0;  dir_wr <= 1'b0;
                end else
                    res_i <= res_i + 3'd1;
            end
        end
        if (cpu_wr && cpu_a0 && ph == PH_CMD && !exec_go) begin
            rqm_dly <= 5'(RQM_DELAY_US);
            cmd_buf[cmd_n] <= cpu_wdata;
            if (cmd_n == 4'd0) begin
                op <= dec_op;  cmd_len <= dec_len;
                mt <= cpu_wdata[7];  mf <= cpu_wdata[6];  sk <= cpu_wdata[5];
                if (dec_op == OP_INV) begin
                    res[0] <= 8'h80;  res_n <= 3'd1;  res_i <= 3'd0;
                    ph <= PH_RES;
                end else if (dec_op == OP_SIS) begin
                    res[0] <= sis_st0;  res[1] <= pcn[sis_u];
                    res_n <= sis_ok ? 3'd2 : 3'd1;  res_i <= 3'd0;
                    sis_take <= sis_ok;  sis_unit <= sis_u;
                    ph <= PH_RES;
                end else
                    cmd_n <= 4'd1;
            end else if (cmd_n == cmd_len - 4'd1) begin
                cmd_n <= 4'd0;
                exec_go <= 1'b1;
            end else
                cmd_n <= cmd_n + 4'd1;
        end

        // ---------------------------------------------------- command start
        if (exec_go) begin
            us <= cmd_buf[1][1:0];
            hd <= cmd_buf[1][2];
            case (op)
            OP_SPEC: begin
                srt <= cmd_buf[1][7:4];  hut <= cmd_buf[1][3:0];
                hlt <= cmd_buf[2][7:1];  nd  <= cmd_buf[2][0];
                ph  <= PH_CMD;
                us  <= us;  hd <= hd;
            end
            OP_SDS: begin
                res[0] <= {1'b0, drv_wp, drv_ready, drv_trk0, drv_ts, cmd_buf[1][2:0]};
                res_n <= 3'd1;  res_i <= 3'd0;
                ph <= PH_RES;
            end
            OP_SEEK, OP_RECAL: begin
                sk_start <= 1'b1;
                sk_recal <= op == OP_RECAL;
                sk_unit  <= cmd_buf[1][1:0];
                sk_hd    <= cmd_buf[1][2];
                sk_ncn   <= cmd_buf[2];
                ph <= PH_CMD;
            end
            default: begin              // data commands
                ph <= PH_EXEC;
                ex <= EX_WAITSP;
                c_r <= cmd_buf[2];  h_r <= cmd_buf[3];  r_r <= cmd_buf[4];
                n_r <= cmd_buf[5];  eot_r <= cmd_buf[6];  gpl_r <= cmd_buf[7];
                dtl_r <= cmd_buf[8];
                if (op == OP_RID) begin
                    c_r <= drv_cyl;  h_r <= {7'd0, cmd_buf[1][2]};  r_r <= 8'd1;  n_r <= 8'd2;
                end
                if (op == OP_FMT) begin
                    n_r <= cmd_buf[2];  eot_r <= cmd_buf[3];      // N, SC
                    gpl_r <= cmd_buf[4];  dtl_r <= cmd_buf[5];    // GPL, D
                    c_r <= drv_cyl;  h_r <= {7'd0, cmd_buf[1][2]};
                end
                dir_rd <= op == OP_RD || op == OP_RDDEL || op == OP_RTRK;
                dir_wr <= op == OP_WR || op == OP_WRDEL || op == OP_FMT;
            end
            endcase
        end

        // ---------------------------------------------------- execution
        if (ph == PH_EXEC) begin
            if (op == OP_FMT && ev_adv && ex != EX_INDEX) fpos <= fpos + 14'd1;

            case (ex)
            EX_WAITSP: if (!x_busy && !x_start) begin
                slot_st[0] <= SL_EMPTY;  slot_st[1] <= SL_EMPTY;
                slot_tag[0] <= 17'd0;    slot_tag[1] <= 17'd0;
                fetch_pend <= 1'b0;
                tc_seen <= 1'b0;  wr_err <= 1'b0;
                cm_flag <= 1'b0;  cm_term <= 1'b0;  nd_flag <= 1'b0;
                seen_id <= 1'b0;  seen_wc <= 1'b0;  idx_cnt <= 1'b0;
                xslot <= 1'b0;  trk_cnt <= 8'd0;
                latch_full <= 1'b0;  want <= 1'b0;  wr_inflight <= 1'b0;
                hut_ms <= 13'd0;
                if (hd_loaded && hd_unit == us) ex <= EX_START;
                else begin
                    tmr_us <= 20'((hlt == 7'd0 ? 128 : int'(hlt)) * 2 * TIME_SCALE * 1000);
                    ex <= EX_HLOAD;
                end
            end
            EX_HLOAD: if (us_tick) begin
                if (tmr_us == 20'd0) begin
                    hd_loaded <= 1'b1;  hd_unit <= us;
                    ex <= EX_START;
                end else
                    tmr_us <= tmr_us - 20'd1;
            end
            EX_START: begin
                if (dir_wr && drv_wp)
                    finish(2'b01, 8'h02, 8'h00, c_r, h_r, r_r, n_r);    // NW
                else if (op == OP_FMT || op == OP_RTRK)
                    ex <= EX_INDEX;
                else
                    ex <= EX_SEARCH;
            end
            EX_INDEX: if (ev_index) begin
                if (op == OP_FMT) begin
                    fpos <= 14'd1;
                    fnext <= 14'(PRE + 16);
                    fk <= 8'd0;  fj <= 2'd0;
                    want <= 1'b1;
                    ex <= EX_FMT;
                end else
                    ex <= EX_SEARCH;
            end
            EX_SEARCH: begin
                if (ev_index) begin
                    if (op == OP_RTRK)
                        finish(2'b01, 8'h80 | (nd_flag ? 8'h04 : 8'h00), 8'h00, c_r, h_r, r_r, n_r);
                    else if (idx_cnt)
                        finish(2'b01, seen_id ? 8'h04 : 8'h01, (seen_id && seen_wc) ? 8'h10 : 8'h00,
                               c_r, h_r, r_r, n_r);                     // ND / MA (+WC)
                    else
                        idx_cnt <= 1'b1;
                end else if (ev_id && mf) begin
                    seen_id <= 1'b1;
                    case (op)
                    OP_RID:
                        finish(2'b00, 8'h00, 8'h00, drv_cyl, {7'd0, hd}, id_r, 8'd2);
                    OP_RTRK: begin
                        if (!(c_r == drv_cyl && h_r == {7'd0, hd} && r_r == id_r && n_r == 8'd2))
                            nd_flag <= 1'b1;
                        xfer <= 1'b1;
                        ex <= EX_SLOT;
                    end
                    default:
                        if (c_r == drv_cyl && h_r == {7'd0, hd} && r_r == id_r && n_r == 8'd2) begin
                            if (op == OP_RDDEL) begin       // the image has normal data marks only
                                cm_flag <= 1'b1;
                                xfer    <= !sk;
                                cm_term <= !sk;
                                ex      <= sk ? EX_DATA : EX_SLOT;
                            end else begin
                                xfer <= 1'b1;
                                ex   <= EX_SLOT;
                            end
                        end else if (c_r != drv_cyl)
                            seen_wc <= 1'b1;
                    endcase
                end
            end
            EX_SLOT: begin                     // rotation held
                if (dir_rd) begin
                    if (slot_tag[xslot] == cur_tag && slot_st[xslot] == SL_READY) begin
                        ex <= EX_DATA;
                        if (pf_ok && !(slot_tag[!xslot] == pf_tag &&
                                       (slot_st[!xslot] == SL_READY || slot_st[!xslot] == SL_BUSYR))) begin
                            fetch_pend <= 1'b1;
                            fetch_slot <= !xslot;
                            fetch_tag  <= pf_tag;
                        end
                    end else if (slot_tag[xslot] == cur_tag && slot_st[xslot] == SL_ERR)
                        finish(2'b01, 8'h20, 8'h20, c_r, h_r, r_r, n_r);   // DE + DD
                    else if (!(slot_tag[xslot] == cur_tag && slot_st[xslot] == SL_BUSYR) &&
                             !fetch_pend && !x_busy) begin
                        fetch_pend <= 1'b1;
                        fetch_slot <= xslot;
                        fetch_tag  <= cur_tag;
                    end
                end else if (slot_free) begin
                    ex <= EX_DATA;
                    want <= 1'b1;
                end
            end
            EX_DATA: begin
                if (ev_dat && xfer) begin
                    if (dir_rd) begin
                        if (!tc_seen) begin
                            buf_addr <= {xslot, didx};
                            rd_addr <= 1'b1;
                        end
                    end else begin
                        buf_addr <= {xslot, didx};
                        if (latch_full || dma_wr) begin
                            buf_we <= 1'b1;
                            buf_wdata <= latch_full ? latch : dma_wdata;
                            latch_full <= 1'b0;
                            want <= didx != 9'd511 && !tc_seen && !tc;
                        end else if (tc_seen) begin
                            buf_we <= 1'b1;            // the 765 pads with zeros after TC
                            buf_wdata <= 8'h00;
                        end else
                            finish(2'b01, 8'h10, 8'h00, c_r, h_r, r_r, n_r);  // OR
                        if (didx == 9'd511 && (latch_full || dma_wr || tc_seen)) begin
                            slot_st[xslot] <= SL_DIRTY;
                            slot_tag[xslot] <= cur_tag;
                        end
                    end
                end
                if (ev_send) begin
                    if (dir_rd && xfer && latch_full && !take_now)
                        finish(2'b01, 8'h10, 8'h00, c_r, h_r, r_r, n_r);      // OR
                    else begin
                        if (xfer) xslot <= !xslot;
                        if (op == OP_RTRK) begin
                            r_r <= r_r + 8'd1;
                            trk_cnt <= trk_cnt + 8'd1;
                            if (tc_seen)
                                finish(2'b00, nd_flag ? 8'h04 : 8'h00, 8'h00, c_r, h_r, r_r + 8'd1, n_r);
                            else if (trk_cnt + 8'd1 == eot_r)
                                finish(2'b00, nd_flag ? 8'h04 : 8'h00, 8'h00, c_r + 8'd1, h_r, 8'd1, n_r);
                            else
                                ex <= EX_SEARCH;
                        end else if (cm_term || tc_seen)
                            finish(2'b00, 8'h00, 8'h00, nx_c, nx_h, nx_r, n_r);
                        else if (r_r == eot_r) begin
                            if (mt && !h_r[0]) begin
                                h_r <= {h_r[7:1], 1'b1};
                                hd <= 1'b1;
                                r_r <= 8'd1;
                                idx_cnt <= 1'b0;
                                ex <= EX_SEARCH;
                            end else
                                finish(2'b01, 8'h80, 8'h00, nx_c, nx_h, nx_r, n_r);   // EN
                        end else begin
                            r_r <= r_r + 8'd1;
                            idx_cnt <= 1'b0;
                            ex <= EX_SEARCH;
                        end
                    end
                end
            end
            EX_FMT: if (ev_adv && fpos == fnext) begin
                if (latch_full || dma_wr) begin
                    fid[fj] <= latch_full ? latch : dma_wdata;
                    latch_full <= 1'b0;
                    if (fj == 2'd3) begin
                        fj <= 2'd0;
                        want <= 1'b0;
                        fnext <= fnext + fpitch - 14'd3;
                        ex <= EX_FMTSLOT;
                    end else begin
                        fj <= fj + 2'd1;
                        fnext <= fnext + 14'd1;
                        want <= !tc_seen && !tc;
                    end
                end else if (tc_seen)
                    ex <= EX_FMTEND;             // TC inside an ID: stop
                else
                    finish(2'b01, 8'h10, 8'h00, fid[0], fid[1], fid[2], fid[3]);   // OR
            end
            EX_FMTSLOT: begin                  // rotation held
                if (!fmt_store) begin
                    fk <= fk + 8'd1;
                    if (fk + 8'd1 == eot_r || tc_seen) ex <= EX_FMTEND;
                    else begin want <= 1'b1; ex <= EX_FMT; end
                end else if (slot_free) begin
                    fill_cnt <= 9'd0;
                    ex <= EX_FMTFILL;
                end
            end
            EX_FMTFILL: begin
                buf_we <= 1'b1;
                buf_addr <= {xslot, fill_cnt};
                buf_wdata <= dtl_r;
                fill_cnt <= fill_cnt + 9'd1;
                if (fill_cnt == 9'd511) begin
                    slot_st[xslot] <= SL_DIRTY;
                    slot_tag[xslot] <= {drv_cyl, hd, fid[2]};
                    xslot <= !xslot;
                    fk <= fk + 8'd1;
                    if (fk + 8'd1 == eot_r || tc_seen) ex <= EX_FMTEND;
                    else begin want <= 1'b1; ex <= EX_FMT; end
                end
            end
            EX_FMTEND: if (ev_index)
                finish(2'b00, 8'h00, 8'h00, fid[0], fid[1], fid[2], fid[3]);
            EX_DRAIN: if (drain_ok) begin
                if (wr_err) res[0] <= res[0] | 8'h50;           // IC = 01, EC
                ph <= PH_RES;
                ex <= EX_IDLE;
                res_i <= 3'd0;
                int_res <= 1'b1;
                latch_full <= 1'b0;
            end
            default: ;
            endcase
        end
    end
end

// ======================================================================
// seeks: one step engine per unit (overlapped seeks), all step pulses go to
// the drive the adapter selects
// ======================================================================
logic [3:0]  recal;
logic [7:0]  ncn [4];
logic [3:0]  skhd;
logic [6:0]  stepcnt [4];
logic [16:0] stmr [4];

always_ff @(posedge clk) begin
    step <= 1'b0;
    if (reset) begin
        for (int u = 0; u < 4; u++) begin
            pcn[u] <= 8'd0;  unack[u] <= UA_NONE;  ust0[u] <= 8'h00;
            stmr[u] <= 17'd0;  stepcnt[u] <= 7'd0;  ncn[u] <= 8'd0;
        end
        seeking <= 4'd0;  recal <= 4'd0;  skhd <= 4'd0;
        int_sense <= 1'b0;
        step_dir <= 1'b0;
    end else begin
        if (sis_take) begin
            unack[sis_unit] <= UA_NONE;
            int_sense <= 1'b0;
        end
        if (rdy_poll) begin
            for (int u = 0; u < 4; u++) unack[u] <= UA_READY;
            int_sense <= 1'b1;
        end
        if (sk_start) begin
            for (int u = 0; u < 4; u++) unack[u] <= UA_NONE;
            seeking[sk_unit] <= 1'b1;
            recal[sk_unit]   <= sk_recal;
            ncn[sk_unit]     <= sk_ncn;
            skhd[sk_unit]    <= sk_hd;
            stepcnt[sk_unit] <= 7'd0;
            stmr[sk_unit]    <= 17'd0;
        end
        for (int u = 0; u < 4; u++) begin
            if (seeking[u] && !(sk_start && sk_unit == 2'(u))) begin
                if (stmr[u] != 17'd0) begin
                    if (us_tick) stmr[u] <= stmr[u] - 17'd1;
                end else if (recal[u] ? drv_trk0 : pcn[u] == ncn[u]) begin
                    seeking[u] <= 1'b0;
                    unack[u] <= UA_SEEK;
                    ust0[u] <= {2'b00, 1'b1, 1'b0, !drv_ready, skhd[u], 2'(u)};      // SE
                    if (recal[u]) pcn[u] <= 8'd0;
                    int_sense <= 1'b1;
                end else if (recal[u] && stepcnt[u] == 7'd77) begin
                    seeking[u] <= 1'b0;
                    unack[u] <= UA_SEEK;
                    ust0[u] <= {2'b01, 1'b1, 1'b1, !drv_ready, skhd[u], 2'(u)};      // SE + EC
                    pcn[u] <= 8'd0;
                    int_sense <= 1'b1;
                end else begin
                    step <= 1'b1;
                    step_dir <= !recal[u] && ncn[u] > pcn[u];
                    if (!recal[u] && ncn[u] > pcn[u]) pcn[u] <= pcn[u] + 8'd1;
                    else if (pcn[u] != 8'd0)          pcn[u] <= pcn[u] - 8'd1;
                    stepcnt[u] <= stepcnt[u] + 7'd1;
                    stmr[u] <= step_us;
                end
            end
        end
    end
end

endmodule
