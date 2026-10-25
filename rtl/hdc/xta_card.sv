// xta_card.sv - the PC20-III's hard disk: the PC10-III main board's CN202
// host side and the Western Digital WD93024-X "intelligent storage
// peripheral" (an XT-attached drive with its controller on board), as one
// card on the card bus (doc/architecture.md section 3, doc/xta.md).
//
// The host side (CN202, schematic 312626 sheet 2) is buffers only: the
// drive decodes 320h-323h itself (-HDCS from the 5720, qualified with AEN),
// DACK3 selects it for DMA, its IRQ goes to IRQ5 (JMP206) and its DRQ to
// DRQ3 (JMP207). JMP208 position B connects the data buffer; in position A
// (`enable` = 0) the ports read FFh and the card does nothing at all.
//
//   320  read: completion byte, sense bytes, data (PIO)
//        write: the command block (CCB), parameters, data (PIO)
//   321  read: status; write: controller reset
//   322  read: configuration register (CONFIG, FFh for the PC20-III);
//        write: select (starts a command)
//   323  write: mask (bit 0 DMA, bit 1 interrupt)
//
// The drive (doc/xta.md sections 3-5, 8-9): translate mode, 615 cylinders x
// 4 heads x 17 sectors = 41,820 logical sectors (LBA = (C x 4 + H) x 17 + S,
// S 0-based in the CCB) on 782 physical cylinders x 2 heads x 27 sectors.
// Logical sector L is physical sector L (track L / 27, cylinder L / 54); a
// track's 27 sectors lie on the platter in the order of the last format's
// interleave. Timing follows the real drive: 3329 rpm (REV_CLK clk per
// revolution, 27 sector slots), seeks of SEEK_A_US + SEEK_B_US x
// sqrt(256 x d) us over d cylinders (5 / 39 / 65 ms for 1 / 261 / 781), a
// one-sector buffer (a sector is read from the platter only once the host
// has taken the previous one, and written only once the host has sent it),
// command overheads. Every assumption is marked [A] in doc/xta.md.
//
// The medium is a raw image of the 41,820 logical sectors behind the sector
// port (hdc_secbuf.sv, the XTIDE card's protocol; sp_lba < 41820). The
// sector buffer has four slots: the backend reads ahead and writes behind, so
// its latency stays hidden behind the drive's own timing; the drive's
// one-sector buffer is the timing model above, and "the sector buffer" of the
// buffer commands (0E, 0F, the format data) is the slot used last.
//
// GPL-3.0-or-later, pc10-iii.

module xta_card #(
    parameter logic [9:0] IO_BASE   = 10'h320,
    parameter int         IRQ       = 5,        // JMP206
    parameter int         DMA       = 3,        // JMP207 (DRQ) and DACK
    parameter logic [7:0] CONFIG    = 8'hFF,    // 322h: translate, table 1 type 3, IRQ5, XT
    // 1 us enable = clk * US_NUM / US_DEN (28.63636 MHz = 315/11 MHz)
    parameter int         US_NUM    = 11,
    parameter int         US_DEN    = 315,
    parameter int         REV_CLK   = 516124,   // 60 / 3329 s at 28.63636 MHz
    parameter int         BYTE_CLK  = 31,       // min. clk from a data byte's strobe start to the next REQ/DRQ: 0.938 MB/s (WD)
    parameter int         CCB_US    = 12,       // REQ low after each CCB byte [A]
    parameter int         CMD_US    = 300,      // the command's overhead after the CCB [A]
    parameter int         FREE_US   = 2,        // completion byte read -> BSY low [A]
    parameter int         RESET_US  = 1000,     // controller reset (321h, RESET DRV) [A]
    parameter int         SPINUP_MS = 5000,     // spin-up after power-on / a new medium [A]
    parameter int         SEEK_A_US = 2760,     // seek = SEEK_A_US + SEEK_B_US * isqrt(256 d)
    parameter int         SEEK_B_US = 140,
    parameter int         DIAG_US   = 2500,     // E0, E3, E4 [A]
    parameter int         ILV_INIT  = 3,        // the factory format's interleave (WD)
    parameter bit         DRV1_READY = 1'b1     // drive 1 answers test drive ready (doc/xta.md 11) [A]
) (
    input  logic        clk,
    input  logic        reset,          // RESET DRV

    // card bus (doc/architecture.md section 3)
    input  logic [19:0] isa_addr,
    input  logic [7:0]  isa_dout,
    output logic [7:0]  isa_din,
    output logic        isa_dsel,
    input  logic        isa_ior_n,
    input  logic        isa_iow_n,
    input  logic        isa_aen,
    output logic [7:2]  isa_irq,
    output logic [3:1]  isa_drq,
    input  logic [3:0]  isa_dack_n,

    // configuration
    input  logic        enable,         // JMP208 in position B: the drive is connected
    input  logic        present,        // a medium (image) is attached
    output logic        active,         // the drive's LED (J6): busy or writing back

    // sector port (doc/hdc.md section 5; sp_lba < 41820)
    output logic        sp_req,
    output logic        sp_write,
    output logic [27:0] sp_lba,
    input  logic        sp_rd_valid,
    input  logic [7:0]  sp_rd_data,
    output logic        sp_wr_valid,
    output logic [7:0]  sp_wr_data,
    input  logic        sp_wr_ready,
    input  logic        sp_done,
    input  logic        sp_err
);

localparam int LCYL = 615, LHEAD = 4, LSPT = 17;
localparam int LMAX = LCYL * LHEAD * LSPT;     // 41,820 logical sectors
localparam int PSPT = 27, PTRK = 782 * 2;      // physical sectors per track, tracks
localparam int BYTE_C = BYTE_CLK > 63 ? 63 : BYTE_CLK;

// sense codes (doc/xta.md section 5.4)
localparam logic [5:0] E_NOTRDY = 6'h04, E_DATA = 6'h11, E_ILLCMD = 6'h20, E_ILLADDR = 6'h21,
                       E_WRFAULT = 6'h03;

// ------------------------------------------------------------ 1 us / 1 ms enables
logic [11:0] us_acc;
logic        us_tick;
logic [9:0]  ms_cnt;
logic        ms_tick;
always_ff @(posedge clk) begin
    if (reset) begin
        us_acc <= 12'd0;  us_tick <= 1'b0;
        ms_cnt <= 10'd0;  ms_tick <= 1'b0;
    end else begin
        if (us_acc + 12'(US_NUM) >= 12'(US_DEN)) begin
            us_acc  <= us_acc + 12'(US_NUM) - 12'(US_DEN);
            us_tick <= 1'b1;
        end else begin
            us_acc  <= us_acc + 12'(US_NUM);
            us_tick <= 1'b0;
        end
        ms_tick <= 1'b0;
        if (us_tick) begin
            ms_cnt <= ms_cnt == 10'd999 ? 10'd0 : ms_cnt + 10'd1;
            ms_tick <= ms_cnt == 10'd999;
        end
    end
end

// ------------------------------------------------------------ the spindle
// 27 sector slots per revolution, exactly REV_CLK clk: spulse marks the clk
// in which slot sidx begins. It starts with RESET DRV (the real spindle
// runs from power-on; its phase is arbitrary either way). [A]
logic [19:0] sp_acc;
logic [4:0]  sidx;
logic        spulse;
always_ff @(posedge clk) begin
    spulse <= 1'b0;
    if (reset) begin
        sp_acc <= 20'd0;
        sidx   <= 5'd0;
    end else if (sp_acc + 20'd27 >= 20'(REV_CLK)) begin
        sp_acc <= sp_acc + 20'd27 - 20'(REV_CLK);
        sidx   <= sidx == 5'd26 ? 5'd0 : sidx + 5'd1;
        spulse <= 1'b1;
    end else
        sp_acc <= sp_acc + 20'd27;
end

// spin-up: after the first RESET DRV and whenever a medium is attached;
// later bus resets do not stop the drive
logic        spun = 1'b0;
logic [15:0] spin_ms = 16'(SPINUP_MS);
logic        present_d = 1'b0;
always_ff @(posedge clk) begin
    present_d <= present;
    if (present && !present_d) begin
        spun    <= SPINUP_MS == 0;
        spin_ms <= 16'(SPINUP_MS);
    end else if (!reset && present && !spun && ms_tick) begin
        if (spin_ms <= 16'd1) spun <= 1'b1;
        spin_ms <= spin_ms - 16'd1;
    end
end
wire drive_ready = present && spun;

// ------------------------------------------------------------ bus strobes
logic       ior_d, iow_d;
logic [7:0] wdat_q;
// a DMA cycle: DACK3 with AEN. DACK can outlast AEN by a few clk, into the
// start of the CPU's next I/O cycle, which is not the DMA's.
wire        dack     = enable && !isa_dack_n[DMA] && isa_aen;
wire        sel_io   = enable && !isa_aen && isa_addr[9:2] == IO_BASE[9:2];
wire [1:0]  rsel     = isa_addr[1:0];
wire        ior_fall = !isa_ior_n && ior_d;
wire        iow_fall = !isa_iow_n && iow_d;
wire        ior_rise = isa_ior_n && !ior_d;
wire        iow_rise = isa_iow_n && !iow_d;
always_ff @(posedge clk) begin
    ior_d <= isa_ior_n;
    iow_d <= isa_iow_n;
    if (!isa_iow_n) wdat_q <= isa_dout;     // the last value seen during the strobe
end

// ------------------------------------------------------------ the sector buffer
logic [10:0] a_addr;
logic        a_we;
logic [7:0]  a_wdata, a_rdata;
logic        x_start, x_write, x_busy, x_done, x_err;
logic [1:0]  x_slot;
logic [15:0] x_lba;

hdc_secbuf #(.SLOTS_LOG2(2)) u_buf (
    .clk         (clk),
    .reset       (reset),
    .a_addr      (a_addr),
    .a_we        (a_we),
    .a_wdata     (a_wdata),
    .a_rdata     (a_rdata),
    .x_start     (x_start),
    .x_write     (x_write),
    .x_slot      (x_slot),
    .x_lba       ({12'd0, x_lba}),
    .x_drive     (1'b0),
    .x_busy      (x_busy),
    .x_done      (x_done),
    .x_err       (x_err),
    .sp_req      (sp_req),
    .sp_write    (sp_write),
    .sp_drive    (),
    .sp_lba      (sp_lba),
    .sp_rd_valid (sp_rd_valid),
    .sp_rd_data  (sp_rd_data),
    .sp_wr_valid (sp_wr_valid),
    .sp_wr_data  (sp_wr_data),
    .sp_wr_ready (sp_wr_ready),
    .sp_done     (sp_done),
    .sp_err      (sp_err)
);

// ------------------------------------------------------------ the physical slot of a sector
// The platter order of a track's 27 sectors after a format with interleave i
// (1-26): the usual layout, sector n at (n x i) mod 27 and one slot further
// each time the sequence returns to an occupied slot. With g = gcd(i, 27)
// the sequence closes after 27 / g sectors, so sector k sits at
// ((k mod 27/g) x i + k div (27/g)) mod 27.
function automatic logic [4:0] slot_of(input logic [4:0] k, input logic [4:0] i);
    logic [4:0] km, kd;
    logic [9:0] m, q;
    if (i == 5'd9 || i == 5'd18) begin               // g = 9: cycles of 3
        kd = 5'(k / 3);  km = 5'(k % 3);
    end else if (i % 3 == 0) begin                   // g = 3: cycles of 9
        kd = 5'(k / 9);  km = 5'(k % 9);
    end else begin
        kd = 5'd0;       km = k;
    end
    m = 10'(km) * 10'(i) + 10'(kd);
    q = 10'(({10'd0, m} * 20'd1214) >> 15);           // m / 27, exact for m < 702
    return 5'(m - q * 10'd27);
endfunction

// ------------------------------------------------------------ the head positioner
// m_go starts an operation on the cylinder m_cyl: the seek, then (unless
// m_only) the wait for slot m_p's start once m_arm is high, then one slot
// (m_trk = 0) or one revolution from the index (m_trk = 1); m_done is the clk
// after it. The head stays where it is across resets.
logic        m_go, m_only, m_trk, m_arm, m_abort;
logic [9:0]  m_cyl;
logic [4:0]  m_p;
logic        m_busy, m_done;
logic [9:0]  cur_cyl = 10'd0;

typedef enum logic [2:0] { M_IDLE, M_SQRT, M_LOAD, M_SEEK, M_ARM, M_START, M_PASS } mst_t;
mst_t        m_st;
logic [9:0]  m_tgt;
logic [4:0]  m_slot;
logic        m_t1, m_o1;
logic [8:0]  m_root;
logic [3:0]  m_bit;
logic [16:0] m_tmr;
logic [4:0]  m_left;                    // slots still to pass

wire [9:0]  m_d    = cur_cyl > m_tgt ? cur_cyl - m_tgt : m_tgt - cur_cyl;
wire [8:0]  m_try  = m_root | (9'd1 << m_bit);

always_ff @(posedge clk) begin
    m_done <= 1'b0;
    if (reset || m_abort) begin
        m_st <= M_IDLE;
    end else case (m_st)
        M_IDLE: if (m_go) begin
            m_tgt  <= m_cyl;
            m_slot <= m_p;
            m_t1   <= m_trk;
            m_o1   <= m_only;
            m_root <= 9'd0;
            m_bit  <= 4'd8;
            m_st   <= M_SQRT;
        end
        M_SQRT: begin                   // isqrt(256 d), one result bit per clk
            if (18'(m_try) * 18'(m_try) <= {m_d, 8'd0}) m_root <= m_try;
            m_bit <= m_bit - 4'd1;
            if (m_bit == 4'd0) m_st <= M_LOAD;
        end
        M_LOAD: if (m_d == 10'd0)
            m_st <= M_ARM;
        else begin
            m_tmr   <= 17'(SEEK_A_US) + 17'(SEEK_B_US) * 17'(m_root);
            cur_cyl <= m_tgt;
            m_st    <= M_SEEK;
        end
        M_SEEK: if (us_tick) begin
            m_tmr <= m_tmr - 17'd1;
            if (m_tmr == 17'd1) m_st <= M_ARM;
        end
        M_ARM: if (m_o1) begin
            m_done <= 1'b1;
            m_st   <= M_IDLE;
        end else if (m_arm) begin
            m_st   <= M_START;
            if (m_t1) m_slot <= 5'd0;   // a track: from the index
        end
        M_START: if (spulse && sidx == m_slot) begin
            m_left <= m_t1 ? 5'd27 : 5'd1;
            m_st   <= M_PASS;
        end
        M_PASS: if (spulse) begin
            if (m_left == 5'd1) begin
                m_done <= 1'b1;
                m_st   <= M_IDLE;
            end
            m_left <= m_left - 5'd1;
        end
        default: m_st <= M_IDLE;
    endcase
end
assign m_busy = m_st != M_IDLE;

// ------------------------------------------------------------ the backend scheduler
// Reads ahead for a read command (up to four sectors beyond the host's),
// writes behind for write and format commands. One transfer at a time.
logic        bk_clear;                  // command start: reset the read-ahead
logic        rd_en;                     // a read command runs (rd_l0, rd_n, ring0)
logic [15:0] rd_l0;
logic [8:0]  rd_n, rd_host;             // sectors, sectors the host has taken
logic [1:0]  ring0;
logic [8:0]  rd_iss, rd_cnt;            // reads issued, completed
logic [3:0]  rd_bad;                    // per slot: the backend read failed
logic        rd_fly;
// writer
logic        w_init;                    // load w_lba / w_base / w_fix / the CHS below
logic [15:0] w_init_lba;
logic        w_init_fix;
logic [9:0]  w_init_c;
logic [4:0]  w_init_h;
logic [5:0]  w_init_s;
logic [15:0] w_lim;                     // write LBAs below this (main FSM)
logic [15:0] w_lba, w_base;
logic        w_fix;                     // format: always from buf_slot
logic [1:0]  buf_slot;
logic        w_fly, w_bad;
logic [9:0]  w_c, wb_c;                 // the writer's logical address, the failed one's
logic [4:0]  w_h, wb_h;
logic [5:0]  w_s, wb_s;
wire         w_pend   = w_lba < w_lim || w_fly;
wire  [15:0] w_rel    = w_lba - w_base;
wire  [15:0] rd_lba   = rd_l0 + 16'(rd_iss);

always_ff @(posedge clk) begin
    x_start <= 1'b0;
    if (reset) begin
        rd_iss <= 9'd0;  rd_cnt <= 9'd0;  rd_fly <= 1'b0;  rd_bad <= 4'd0;
        w_lba  <= 16'd0; w_base <= 16'd0; w_fly <= 1'b0;  w_bad <= 1'b0;  w_fix <= 1'b0;
    end else begin
        if (bk_clear) begin
            rd_iss <= 9'd0;  rd_cnt <= 9'd0;  rd_bad <= 4'd0;
        end
        if (w_init) begin
            w_lba  <= w_init_lba;
            w_base <= w_init_lba;
            w_fix  <= w_init_fix;
            w_bad  <= 1'b0;
            w_c <= w_init_c;  w_h <= w_init_h;  w_s <= w_init_s;
        end
        if (x_done) begin
            if (w_fly) begin
                w_fly <= 1'b0;
                w_lba <= w_lba + 16'd1;
                if (x_err && !w_bad) begin
                    w_bad <= 1'b1;
                    wb_c <= w_c;  wb_h <= w_h;  wb_s <= w_s;
                end
                if (w_s == 6'(LSPT - 1)) begin
                    w_s <= 6'd0;
                    if (w_h == 5'(LHEAD - 1)) begin
                        w_h <= 5'd0;
                        w_c <= w_c + 10'd1;
                    end else
                        w_h <= w_h + 5'd1;
                end else
                    w_s <= w_s + 6'd1;
            end
            if (rd_fly) begin
                rd_fly <= 1'b0;
                rd_cnt <= rd_cnt + 9'd1;
                rd_bad[ring0 + rd_cnt[1:0]] <= x_err;
            end
        end
        if (!x_busy && !w_fly && !rd_fly && !x_start && !x_done && !w_init) begin
            if (w_lba < w_lim) begin
                x_start <= 1'b1;
                x_write <= 1'b1;
                x_lba   <= w_lba;
                x_slot  <= w_fix ? buf_slot : ring0 + w_rel[1:0];
                w_fly   <= 1'b1;
            end else if (rd_en && !bk_clear && rd_iss < rd_n && rd_iss < rd_host + 9'd4 &&
                         rd_lba < 16'(LMAX)) begin
                x_start <= 1'b1;
                x_write <= 1'b0;
                x_lba   <= rd_lba;
                x_slot  <= ring0 + rd_iss[1:0];
                rd_iss  <= rd_iss + 9'd1;
                rd_fly  <= 1'b1;
            end
        end
    end
end

// ------------------------------------------------------------ the controller
typedef enum logic [2:0] { P_IDLE, P_RESET, P_CMD, P_EXEC, P_DIN, P_DOUT, P_STAT, P_FREE } phase_t;
typedef enum logic [3:0] { S_IDLE, S_OVH, S_WAITQ, S_DIV, S_GO, S_RUN, S_FMT, S_XFER, S_TIMER,
                           S_MECH, S_DRAIN } st_t;
typedef enum logic [4:0] { K_BAD, K_TEST, K_RECAL, K_SENSE, K_FMTD, K_VERIFY, K_FMTT, K_READ,
                           K_WRITE, K_SEEK, K_INIT, K_ECC, K_RBUF, K_WBUF, K_DIAG, K_DDIAG,
                           K_RLONG, K_WLONG } kind_t;
typedef enum logic [1:0] { H_SEC, H_SENSE, H_ZERO } hsrc_t;

phase_t      phase;
st_t         st;
kind_t       kind;
logic        req, irq_l;
logic [1:0]  mask;
logic [7:0]  ccb [6];
logic [2:0]  ccb_n;
logic [21:0] tmr;                       // us
logic [4:0]  ilv = 5'(ILV_INIT);
// the command
logic        c_drv;
logic [9:0]  c_cyl;
logic [4:0]  c_head;
logic [5:0]  c_sec;
logic [8:0]  n_tot;
logic [15:0] l0;
// sense (doc/xta.md section 5.4)
logic [5:0]  sn_code;
logic        sn_av, sn_drv;
logic [9:0]  sn_c;
logic [4:0]  sn_h;
logic [5:0]  sn_s;
// the head positioner's sector: logical address, physical track and sector
logic [8:0]  mi, mdone, hdone;
logic [9:0]  q_c;
logic [4:0]  q_h;
logic [5:0]  q_s;
logic [15:0] q_l;
logic [9:0]  d_c;                       // the last sector read from the platter
logic [4:0]  d_h;
logic [5:0]  d_s;
logic [10:0] q_t;
logic [4:0]  q_k;
logic        q_bad, m_pend, fmt_all;
logic [15:0] f_end;                     // format: LBA limit
// L / 27
logic [15:0] dv_n;
logic [5:0]  dv_r;
logic [4:0]  dv_i;
// host transfer
logic        h_act, h_in, h_dma, h_strobe, g_run;
hsrc_t       h_src;
logic [9:0]  h_len, h_cnt;
logic [1:0]  h_slot;
logic [5:0]  gap, rate;               // rate: clk until the next byte may be offered
logic [7:0]  din_q;
// CPU / DMA cycles in progress (decoded at the strobe's start)
logic        r_cyc, r_take, w_cyc, w_take, d_rd, d_take;
logic [1:0]  r_reg, w_reg;

wire is_rd    = kind == K_READ || kind == K_RLONG || kind == K_VERIFY;
wire is_wr    = kind == K_WRITE || kind == K_WLONG;
wire is_long  = kind == K_RLONG || kind == K_WLONG;
wire [9:0] sec_len = is_long ? 10'd516 : 10'd512;

function automatic kind_t decode(input logic [7:0] op);
    case (op)
        8'h00: return K_TEST;    8'h01: return K_RECAL;   8'h03: return K_SENSE;
        8'h04: return K_FMTD;    8'h05: return K_VERIFY;  8'h06: return K_FMTT;
        8'h07: return K_FMTT;    8'h08: return K_READ;    8'h0A: return K_WRITE;
        8'h0B: return K_SEEK;    8'h0C: return K_INIT;    8'h0D: return K_ECC;
        8'h0E: return K_RBUF;    8'h0F: return K_WBUF;    8'hE0: return K_DIAG;
        8'hE3: return K_DDIAG;   8'hE4: return K_DIAG;    8'hE5: return K_RLONG;
        8'hE6: return K_WLONG;
        default: return K_BAD;
    endcase
endfunction
// commands that need the drive (spinning, a medium); the others are the
// controller's alone and work for drive 1 too
function automatic logic needs_drive(input kind_t k);
    return !(k == K_SENSE || k == K_INIT || k == K_ECC || k == K_RBUF || k == K_WBUF ||
             k == K_DIAG || k == K_BAD);
endfunction

kind_t dk;
assign dk = decode(ccb[0]);

// status register (doc/xta.md section 4)
logic       st_bsy, st_cd, st_io;
always_comb begin
    st_bsy = 1'b1;  st_cd = 1'b0;  st_io = 1'b0;
    case (phase)
        P_IDLE, P_RESET: st_bsy = 1'b0;
        P_CMD, P_EXEC:   st_cd  = 1'b1;
        P_DIN:           st_io  = 1'b1;
        P_DOUT:          ;
        P_STAT, P_FREE:  begin st_cd = 1'b1; st_io = 1'b1; end
        default: ;
    endcase
end
wire drq_o  = enable && h_act && h_dma && req && mask[0] && (phase == P_DIN || phase == P_DOUT);
wire irq_o  = enable && irq_l && mask[1];
wire [7:0] status = {2'b00, irq_o, drq_o, st_bsy, st_cd, st_io, req && phase != P_FREE};

// the next sector's physical slot
wire [4:0] q_p = slot_of(q_k, ilv);

// the sense bytes
logic [7:0] sense_b;
always_comb case (h_cnt[1:0])
    2'd0:    sense_b = {sn_av, 1'b0, sn_code};
    2'd1:    sense_b = {2'b00, sn_drv, sn_h};
    2'd2:    sense_b = {sn_c[9:8], sn_s};
    default: sense_b = sn_c[7:0];
endcase

// the head positioner may start on its sector: reads once the host has the
// previous sector (the one-sector buffer is free), writes once the host has
// sent this one, formats at once
assign m_arm   = st == S_FMT || (is_rd ? hdone == mi : hdone > mi);
assign rd_host = hdone;
// a data byte moved (the end of its strobe)
wire moved = (ior_rise && (r_take || d_take)) || (iow_rise && w_cyc && w_take);

task automatic finish(input logic err);
    phase <= P_STAT;
    st    <= S_IDLE;
    h_act <= 1'b0;
    g_run <= 1'b0;
    req   <= 1'b1;
    irq_l <= 1'b1;
    din_q <= {2'b00, c_drv, 3'b000, err, 1'b0};
endtask

// a failed command: the sense code and its address
task automatic fail(input logic [5:0] code, input logic av, input logic [9:0] c,
                    input logic [4:0] h, input logic [5:0] s);
    sn_code <= code;  sn_av <= av;  sn_drv <= c_drv;
    sn_c <= c;  sn_h <= h;  sn_s <= s;
    finish(1'b1);
endtask

task automatic host_go(input logic in, input hsrc_t src, input logic [9:0] len, input logic [1:0] slot,
                       input logic dma);
    h_act  <= 1'b1;  h_in <= in;  h_src <= src;  h_len <= len;  h_slot <= slot;  h_dma <= dma;
    h_cnt  <= 10'd0;
    h_strobe <= 1'b0;
    req    <= 1'b0;
    g_run  <= 1'b1;
    gap    <= 6'd2;
    a_addr <= {slot, 9'd0};
    phase  <= in ? P_DIN : P_DOUT;
endtask

always_ff @(posedge clk) begin
    a_we     <= 1'b0;
    m_go     <= 1'b0;
    m_abort  <= 1'b0;
    bk_clear <= 1'b0;
    w_init   <= 1'b0;

    if (reset) begin
        phase <= P_RESET;
        tmr   <= 22'(RESET_US);
        st    <= S_IDLE;
        req   <= 1'b0;  irq_l <= 1'b0;  mask <= 2'b00;
        h_act <= 1'b0;  g_run <= 1'b0;  h_strobe <= 1'b0;  rate <= 6'd0;
        r_cyc <= 1'b0;  w_cyc <= 1'b0;  d_rd <= 1'b0;  r_take <= 1'b0;  w_take <= 1'b0;  d_take <= 1'b0;
        rd_en <= 1'b0;  w_lim <= 16'd0;  buf_slot <= 2'd0;  ring0 <= 2'd0;
        sn_code <= 6'd0;  sn_av <= 1'b0;  sn_drv <= 1'b0;  sn_c <= 10'd0;  sn_h <= 5'd0;  sn_s <= 6'd0;
        m_abort <= 1'b1;
        isa_din <= 8'hFF;
    end else begin
        // ---------------------------------------------- timers
        if (us_tick && tmr != 22'd0) tmr <= tmr - 22'd1;
        if (rate != 6'd0) rate <= rate - 6'd1;

        // ---------------------------------------------- CPU and DMA strobes
        if (ior_fall) begin
            r_cyc <= sel_io;
            r_reg <= rsel;
            r_take <= 1'b0;
            d_rd  <= 1'b0;
            d_take <= 1'b0;
            if (dack) begin
                // a DMA read (drive -> memory)
                d_rd    <= 1'b1;
                isa_din <= din_q;
                if (req && h_act && h_dma && h_in && phase == P_DIN) begin
                    d_take <= 1'b1;  req <= 1'b0;  h_strobe <= 1'b1;  rate <= 6'(BYTE_C);
                end
            end else if (sel_io) case (rsel)
                2'd0: begin
                    isa_din <= din_q;
                    if (req && ((phase == P_DIN && h_act) || phase == P_STAT)) begin
                        r_take <= 1'b1;  req <= 1'b0;  h_strobe <= 1'b1;  rate <= 6'(BYTE_C);
                    end
                end
                2'd1: isa_din <= status;
                2'd2: isa_din <= CONFIG;
                default: ;
            endcase
        end
        if (iow_fall) begin
            w_cyc  <= sel_io || dack;
            w_reg  <= dack ? 2'd0 : rsel;
            w_take <= 1'b0;
            if (((dack && h_act && h_dma) || (sel_io && rsel == 2'd0)) && req &&
                ((phase == P_DOUT && h_act && !h_in) || (phase == P_CMD && !dack))) begin
                w_take <= 1'b1;  req <= 1'b0;  h_strobe <= 1'b1;  rate <= 6'(BYTE_C);
            end
        end

        // ---------------------------------------------- a byte moved (strobe end)
        if (moved) begin
            r_take <= 1'b0;  d_take <= 1'b0;  w_take <= 1'b0;
            h_strobe <= 1'b0;
            if (phase == P_STAT) begin
                // the completion byte: the interrupt clears, the bus frees
                irq_l <= 1'b0;
                phase <= P_FREE;
                tmr   <= 22'(FREE_US);
            end else if (phase == P_CMD) begin
                ccb[ccb_n] <= wdat_q;
                if (ccb_n == 3'd5) begin
                    phase <= P_EXEC;
                    st    <= S_OVH;
                    tmr   <= 22'(CMD_US);
                end else begin
                    ccb_n <= ccb_n + 3'd1;
                    tmr   <= 22'(CCB_US);
                end
            end else if (h_act) begin
                if (!h_in && h_src == H_SEC && !h_cnt[9]) begin
                    a_we    <= 1'b1;
                    a_addr  <= {h_slot, h_cnt[8:0]};
                    a_wdata <= wdat_q;
                end
                h_cnt <= h_cnt + 10'd1;
                if (h_cnt + 10'd1 == h_len)
                    h_act <= 1'b0;
                else begin
                    g_run <= 1'b1;
                    gap   <= rate > 6'd2 ? rate : 6'd2;   // >= 2: the RAM's read
                    if (h_in) a_addr <= {h_slot, h_cnt[8:0] + 9'd1};
                end
            end
        end
        if (ior_rise) begin r_cyc <= 1'b0; d_rd <= 1'b0; end
        if (iow_rise) w_cyc <= 1'b0;

        // ---------------------------------------------- host transfer: the next byte
        if (g_run && !h_strobe) begin
            if (gap == 6'd1) begin
                case (h_src)
                    H_SEC:   din_q <= h_cnt[9] ? 8'h00 : a_rdata;     // read long: 4 ECC bytes of 0 [A]
                    H_SENSE: din_q <= sense_b;
                    default: din_q <= 8'h00;
                endcase
            end
            if (gap == 6'd0) begin
                g_run <= 1'b0;
                req   <= 1'b1;
            end else
                gap <= gap - 6'd1;
        end

        // ---------------------------------------------- register writes
        if (iow_rise && w_cyc && w_reg != 2'd0) begin
            case (w_reg)
                2'd1: begin                             // controller reset
                    phase <= P_RESET;
                    tmr   <= 22'(RESET_US);
                    st    <= S_IDLE;
                    req   <= 1'b0;  irq_l <= 1'b0;  mask <= 2'b00;
                    h_act <= 1'b0;  g_run <= 1'b0;  h_strobe <= 1'b0;
                    rd_en <= 1'b0;
                    sn_code <= 6'd0;  sn_av <= 1'b0;  sn_drv <= 1'b0;
                    sn_c <= 10'd0;  sn_h <= 5'd0;  sn_s <= 6'd0;
                    m_abort <= 1'b1;
                end
                2'd2: if (phase != P_RESET) begin       // select: a new command
                    phase <= P_CMD;
                    ccb_n <= 3'd0;
                    st    <= S_IDLE;
                    req   <= 1'b1;
                    irq_l <= 1'b0;
                    h_act <= 1'b0;  g_run <= 1'b0;  h_strobe <= 1'b0;
                    rd_en <= 1'b0;
                    m_abort <= 1'b1;
                end
                2'd3: mask <= wdat_q[1:0];
                default: ;
            endcase
        end

        // ---------------------------------------------- phases on timers
        case (phase)
            P_RESET: if (tmr == 22'd0) phase <= P_IDLE;
            P_FREE:  if (tmr == 22'd0) phase <= P_IDLE;
            P_CMD:   if (!req && !h_strobe && tmr == 22'd0 && ccb_n != 3'd0 && st == S_IDLE) req <= 1'b1;
            default: ;
        endcase

        // ---------------------------------------------- the command
        case (st)
            S_OVH: if (tmr == 22'd0) begin
                kind   <= dk;
                c_drv  <= ccb[1][5];
                c_head <= ccb[1][4:0];
                c_sec  <= ccb[2][5:0];
                c_cyl  <= {ccb[2][7:6], ccb[3]};
                n_tot  <= ccb[4] == 8'd0 ? 9'd256 : {1'b0, ccb[4]};
                st     <= S_WAITQ;
            end
            S_WAITQ: begin
                // the previous command's write-behind is on the image first
                l0 <= 16'((c_cyl * 4 + 10'(c_head)) * 17) + (kind == K_FMTT ? 16'd0 : 16'(c_sec));
                if (!w_pend && !x_busy) begin
                    bk_clear <= 1'b1;
                    if (kind != K_SENSE) begin  // the sense belongs to the last command [A]
                        sn_code <= 6'd0;  sn_av <= 1'b0;  sn_drv <= 1'b0;
                        sn_c <= 10'd0;  sn_h <= 5'd0;  sn_s <= 6'd0;
                    end
                    if (kind == K_BAD)
                        fail(E_ILLCMD, 1'b0, c_cyl, c_head, c_sec);
                    else if (needs_drive(kind) && (c_drv ? !(DRV1_READY && kind == K_TEST) : !drive_ready))
                        fail(E_NOTRDY, 1'b0, c_cyl, c_head, c_sec);
                    else if (c_drv && kind == K_TEST)
                        finish(1'b0);
                    else if ((is_rd || is_wr || kind == K_SEEK || kind == K_FMTT) &&
                             (c_cyl >= 10'(LCYL) || c_head >= 5'(LHEAD) ||
                              ((is_rd || is_wr) && c_sec >= 6'(LSPT))))
                        fail(E_ILLADDR, 1'b1, c_cyl, c_head, c_sec);
                    else if ((kind == K_FMTD || kind == K_FMTT) && (ccb[4] == 8'd0 || ccb[4] > 8'd26))
                        fail(E_ILLADDR, 1'b0, c_cyl, c_head, c_sec);    // interleave 1-26 [A]
                    else case (kind)
                        K_TEST:  finish(1'b0);
                        K_RECAL: begin
                            m_cyl <= 10'd0;  m_only <= 1'b1;  m_go <= 1'b1;
                            st <= S_MECH;
                        end
                        K_SENSE: begin
                            host_go(1'b1, H_SENSE, 10'd4, 2'd0, 1'b0);
                            st <= S_XFER;
                        end
                        K_ECC: begin
                            host_go(1'b1, H_ZERO, 10'd1, 2'd0, 1'b0);
                            st <= S_XFER;
                        end
                        K_INIT: begin
                            host_go(1'b0, H_ZERO, 10'd8, 2'd0, 1'b0);
                            st <= S_XFER;
                        end
                        K_RBUF: begin
                            host_go(1'b1, H_SEC, 10'd512, buf_slot, 1'b1);
                            st <= S_XFER;
                        end
                        K_WBUF: begin
                            host_go(1'b0, H_SEC, 10'd512, buf_slot, 1'b1);
                            st <= S_XFER;
                        end
                        K_DIAG, K_DDIAG: begin
                            tmr <= 22'(DIAG_US);
                            st  <= S_TIMER;
                        end
                        default: begin          // read, write, verify, seek, format: L / 27
                            dv_n <= 16'((c_cyl * 4 + 10'(c_head)) * 17) + (kind == K_FMTT ? 16'd0 : 16'(c_sec));
                            dv_r <= 6'd0;
                            dv_i <= 5'd16;
                            st   <= S_DIV;
                        end
                    endcase
                end
            end
            S_DIV: begin
                // restoring division of l0 by 27: q_t = l0 / 27, q_k = l0 % 27
                if (dv_i != 5'd0) begin
                    if ({dv_r[4:0], dv_n[15]} >= 6'd27) begin
                        dv_r <= {dv_r[4:0], dv_n[15]} - 6'd27;
                        dv_n <= {dv_n[14:0], 1'b1};
                    end else begin
                        dv_r <= {dv_r[4:0], dv_n[15]};
                        dv_n <= {dv_n[14:0], 1'b0};
                    end
                    dv_i <= dv_i - 5'd1;
                end else begin
                    q_t   <= dv_n[10:0];
                    q_k   <= dv_r[4:0];
                    q_l   <= l0;
                    q_c   <= c_cyl;  q_h <= c_head;  q_s <= kind == K_FMTT ? 6'd0 : c_sec;
                    q_bad <= 1'b0;
                    mi    <= 9'd0;  mdone <= 9'd0;  hdone <= 9'd0;
                    ring0 <= buf_slot + 2'd1;
                    st    <= S_GO;
                    case (kind)
                        K_SEEK: begin
                            m_cyl <= dv_n[10:1];  m_only <= 1'b1;  m_go <= 1'b1;
                            st <= S_MECH;
                        end
                        K_FMTD, K_FMTT: begin
                            ilv     <= ccb[4][4:0];
                            fmt_all <= kind == K_FMTD;
                            f_end   <= kind == K_FMTD ? 16'(LMAX) : l0 + 16'(LSPT);
                            w_lim   <= kind == K_FMTD ? 16'd0 : l0;
                            if (kind == K_FMTD) begin
                                q_t <= 11'd0;
                                q_k <= 5'd0;
                                q_l <= 16'd0;
                            end
                            w_init <= 1'b1;
                            w_init_lba <= kind == K_FMTD ? 16'd0 : l0;
                            w_init_fix <= 1'b1;
                            w_init_c <= kind == K_FMTD ? 10'd0 : c_cyl;
                            w_init_h <= kind == K_FMTD ? 5'd0 : c_head;
                            w_init_s <= 6'd0;
                        end
                        default: if (is_wr) begin
                            w_lim  <= l0;
                            w_init <= 1'b1;
                            w_init_lba <= l0;
                            w_init_fix <= 1'b0;
                            w_init_c <= c_cyl;  w_init_h <= c_head;  w_init_s <= c_sec;
                        end
                    endcase
                end
            end
            S_GO: begin
                // the first sector (or track): the seek starts now
                m_cyl  <= q_t[10:1];
                m_p    <= q_p;
                m_only <= 1'b0;
                m_trk  <= kind == K_FMTD || kind == K_FMTT;
                m_go   <= 1'b1;
                m_pend <= 1'b0;
                if (kind == K_FMTD || kind == K_FMTT) begin
                    st    <= S_FMT;
                    phase <= P_EXEC;
                end else begin
                    st    <= S_RUN;
                    rd_en <= is_rd && kind != K_VERIFY;
                    rd_l0 <= l0;
                    rd_n  <= n_tot;
                    // a write starts with the host filling the buffer
                    if (is_wr) host_go(1'b0, H_SEC, sec_len, ring0, 1'b1);
                end
            end
            S_RUN: begin
                // the next sector for the head positioner (m_pend: one clk after
                // its address advanced, so that q_p has followed q_k)
                if (m_pend && !q_bad) begin
                    m_pend <= 1'b0;
                    m_cyl  <= q_t[10:1];
                    m_p    <= q_p;
                    m_go   <= 1'b1;
                end
                if (m_done && !m_only) begin
                    mdone <= mdone + 9'd1;
                    d_c <= q_c;  d_h <= q_h;  d_s <= q_s;
                    if (is_wr) w_lim <= q_l + 16'd1;
                    if (mi + 9'd1 < n_tot) begin
                        // the head positioner's next sector
                        mi  <= mi + 9'd1;
                        q_l <= q_l + 16'd1;
                        q_bad <= q_l + 16'd1 >= 16'(LMAX);
                        m_pend <= 1'b1;
                        if (q_k == 5'(PSPT - 1)) begin
                            q_k <= 5'd0;
                            q_t <= q_t + 11'd1;
                        end else
                            q_k <= q_k + 5'd1;
                        if (q_s == 6'(LSPT - 1)) begin
                            q_s <= 6'd0;
                            if (q_h == 5'(LHEAD - 1)) begin
                                q_h <= 5'd0;
                                q_c <= q_c + 10'd1;
                            end else
                                q_h <= q_h + 5'd1;
                        end else
                            q_s <= q_s + 6'd1;
                    end
                    if (kind == K_VERIFY) hdone <= hdone + 9'd1;
                end
                // reads: the sector is under the head once the host has the
                // previous one; then the data go to the host
                if (h_act && moved && h_cnt + 10'd1 == h_len)
                    hdone <= hdone + 9'd1;
                if (is_rd) begin
                    if (kind != K_VERIFY && !h_act && hdone + 9'd1 == mdone) begin
                        // the sector hdone was read from the platter
                        if (rd_cnt > hdone) begin
                            if (rd_bad[ring0 + hdone[1:0]]) begin
                                rd_en <= 1'b0;
                                fail(E_DATA, 1'b1, d_c, d_h, d_s);
                            end else
                                host_go(1'b1, H_SEC, sec_len, ring0 + hdone[1:0], 1'b1);
                        end
                    end
                    if (hdone == n_tot && !h_act) begin
                        rd_en    <= 1'b0;
                        if (kind != K_VERIFY) buf_slot <= ring0 + 2'(n_tot - 9'd1);
                        finish(1'b0);
                    end else if (q_bad && hdone == mdone && !h_act && !m_busy)
                        fail(E_ILLADDR, 1'b1, q_c, q_h, q_s);
                end else begin
                    // writes: the host fills the next sector once the previous
                    // one is on the platter and its slot is free
                    if (!h_act && hdone == mdone && hdone != 9'd0 && hdone < n_tot && !q_bad &&
                        16'(mdone) - (w_lba - w_base) < 16'd4)
                        host_go(1'b0, H_SEC, sec_len, ring0 + hdone[1:0], 1'b1);
                    if (mdone == n_tot || (q_bad && hdone == mdone && !h_act && !m_busy)) begin
                        st <= S_DRAIN;
                        buf_slot <= ring0 + 2'(mdone - 9'd1);
                    end
                end
            end
            S_FMT: begin
                if (m_pend) begin
                    m_pend <= 1'b0;
                    m_cyl  <= q_t[10:1];
                    m_go   <= 1'b1;
                end
                if (m_done) begin
                    // one track formatted: its logical sectors get the buffer
                    w_lim <= q_l + 16'(PSPT) - 16'(q_k) > f_end ? f_end : q_l + 16'(PSPT) - 16'(q_k);
                    if (fmt_all ? q_t == 11'(PTRK - 1) : q_l + 16'(PSPT) - 16'(q_k) >= f_end)
                        st <= S_DRAIN;
                    else begin
                        q_t <= q_t + 11'd1;
                        q_l <= q_l + 16'(PSPT) - 16'(q_k) > 16'(LMAX) ? 16'(LMAX) : q_l + 16'(PSPT) - 16'(q_k);
                        q_k <= 5'd0;
                        m_pend <= 1'b1;
                    end
                end
            end
            S_DRAIN: if (!w_pend && !m_busy) begin
                if (w_bad)
                    fail(E_WRFAULT, 1'b1, wb_c, wb_h, wb_s);
                else if (q_bad && is_wr)
                    fail(E_ILLADDR, 1'b1, q_c, q_h, q_s);
                else
                    finish(1'b0);
            end
            S_XFER: if (!h_act && !g_run) begin
                if (kind == K_SENSE) begin
                    sn_code <= 6'd0;  sn_av <= 1'b0;  sn_drv <= 1'b0;
                    sn_c <= 10'd0;  sn_h <= 5'd0;  sn_s <= 6'd0;
                end
                finish(1'b0);
            end
            S_TIMER: if (tmr == 22'd0) finish(1'b0);
            S_MECH:  if (m_done) finish(1'b0);
            default: ;
        endcase
    end
end

// ------------------------------------------------------------ outputs
assign isa_dsel = enable && !isa_ior_n && ((r_cyc && r_reg != 2'd3) || d_rd);
always_comb begin
    isa_irq = 6'b000000;
    if (IRQ >= 2 && IRQ <= 7) isa_irq[IRQ] = irq_o;
    isa_drq = 3'b000;
    if (DMA >= 1 && DMA <= 3) isa_drq[DMA] = drq_o;
end
assign active = enable && (st_bsy || w_pend);

endmodule
