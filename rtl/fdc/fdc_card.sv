// fdc_card.sv - the IBM PC/XT diskette adapter on the card bus
// (doc/architecture.md section 3, doc/fdc.md).
//
//   3F2  DOR (write only): bits 1-0 drive select, bit 2 = 0 holds the 765 in
//        reset, bit 3 enables the DRQ2 and IRQ6 drivers, bits 7-4 motor
//        enables of drives A-D
//   3F4  765 main status register (read only)
//   3F5  765 data register
//   DMA channel 2 (DRQ2/DACK2, TC qualified by DACK2), IRQ6.
//
// The XT adapter has no DIR (3F7 read) and no CCR (3F7 write): the data rate
// is fixed at 250 kbit/s. Both belong to the AT adapter (doc/fdc.md).
//
// As on IBM's adapter, a drive is selected by the DOR alone (select bits AND
// its motor bit); the 765's unit-select outputs are not connected and its
// READY input is tied high. Up to two drives (A:, B:).
//
// The drives are disk images outside the card: geometry, presence and write
// protection come in per drive, the sector data through the sector port
// (fdc_secbuf.sv).
//
// GPL-3.0-or-later, pc10-iii.

module fdc_card #(
    parameter int NDRIVES   = 2,
    // 1 us enable = clk * US_NUM / US_DEN (28.63636 MHz = 315/11 MHz)
    parameter int US_NUM    = 11,
    parameter int US_DEN    = 315,
    parameter int TIME_SCALE   = 2,
    parameter int RQM_DELAY_US = 12,
    parameter int RESET_US     = 1000,
    // pc10-iii (timing): 1 = decode the address registered, from
    // isa_addr_next/isa_aen_next (the values the bus has in the next clk);
    // 0 = combinationally from isa_addr/isa_aen (the card bus alone)
    parameter bit REG_DECODE   = 1'b0
) (
    input  logic        clk,
    input  logic        reset,          // RESET DRV

    // card bus (doc/architecture.md section 3)
    input  logic [19:0] isa_addr,
    input  logic [19:0] isa_addr_next,  // REG_DECODE: isa_addr of the next clk
    input  logic        isa_aen_next,   // REG_DECODE: isa_aen of the next clk
    input  logic        isa_ior_n_next, // REG_DECODE: isa_ior_n of the next clk
    input  logic        isa_iow_n_next, // REG_DECODE: isa_iow_n of the next clk
    input  logic [7:0]  isa_dout,
    output logic [7:0]  isa_din,
    output logic        isa_dsel,       // this card drives isa_din
    input  logic        isa_ior_n,
    input  logic        isa_iow_n,
    input  logic        isa_aen,
    output logic        isa_ready,
    output logic [7:2]  isa_irq,
    output logic [3:1]  isa_drq,
    input  logic [3:0]  isa_dack_n,
    input  logic        isa_tc,         // active high, valid during the DACK cycle

    // the drives
    input  logic [1:0]       drv_80trk,     // drive mechanics: 0 = 40 tracks (5.25" DD), 1 = 80 tracks
    input  logic [1:0]       img_present,
    input  logic [1:0]       img_wp,
    input  logic [1:0][7:0]  img_tracks,    // cylinders: 40 or 80 (up to 84)
    input  logic [1:0][1:0]  img_heads,     // 1 or 2
    input  logic [1:0][5:0]  img_spt,       // 8 or 9 (15/18 need a faster data rate)
    output logic [1:0]       drv_motor,     // for LEDs / drive sounds
    output logic             fdc_active,    // a read/write/format is executing
    // pc10-iii (drive LED, drive sound): drive n selected = the DOR selects it and
    // its motor bit is set (the drive's select line: its front-panel LED); the
    // selected drive's head moved one cylinder (one clk, the clk after the 765's
    // step pulse that moved it; not at the drive's stops) and in which direction
    output logic [1:0]       drv_select,
    output logic             drv_step,
    output logic             drv_step_in,   // 1 = inward (cylinder + 1)

    // sector port (doc/fdc.md)
    output logic        sp_req,
    output logic        sp_write,
    output logic        sp_fmt,         // pc10-iii (internal drive): a FORMAT TRACK commit (doc/fdc.md section 5)
    output logic        sp_drive,
    output logic [7:0]  sp_cyl,
    output logic        sp_head,
    output logic [7:0]  sp_sector,
    output logic [15:0] sp_lba,
    input  logic        sp_rd_valid,
    input  logic [7:0]  sp_rd_data,
    output logic        sp_wr_valid,
    output logic [7:0]  sp_wr_data,
    input  logic        sp_wr_ready,
    input  logic        sp_done,
    input  logic        sp_err
);

// ------------------------------------------------------------ 1 us enable
logic [11:0] us_acc;
logic        us_tick;
always_ff @(posedge clk) begin
    if (reset) begin
        us_acc  <= 12'd0;
        us_tick <= 1'b0;
    end else if (us_acc + 12'(US_NUM) >= 12'(US_DEN)) begin
        us_acc  <= us_acc + 12'(US_NUM) - 12'(US_DEN);
        us_tick <= 1'b1;
    end else begin
        us_acc  <= us_acc + 12'(US_NUM);
        us_tick <= 1'b0;
    end
end

// ------------------------------------------------------------ bus strobes
logic       ior_d, iow_d;
logic [7:0] wdat_q;
logic       dma_rd_cyc, dma_wr_cyc, tc_q, io_cyc_dor, io_cyc_fdc;
logic       io_a0;
wire        dack2  = !isa_dack_n[2];
wire        io_sel = !isa_aen && isa_addr[9:3] == 7'b1111_110;        // 3F0-3F7
wire        sel_dor_c = io_sel && isa_addr[2:0] == 3'd2;
wire        sel_fdc_c = io_sel && (isa_addr[2:0] == 3'd4 || isa_addr[2:0] == 3'd5);
// pc10-iii (timing): the same decode one clk ahead into registers (REG_DECODE)
logic       sel_dor_q, sel_fdc_q;
wire        io_sel_n = !isa_aen_next && isa_addr_next[9:3] == 7'b1111_110;
always_ff @(posedge clk) begin
    sel_dor_q <= io_sel_n && isa_addr_next[2:0] == 3'd2;
    sel_fdc_q <= io_sel_n && (isa_addr_next[2:0] == 3'd4 || isa_addr_next[2:0] == 3'd5);
end
logic       a0_q;
always_ff @(posedge clk) a0_q <= isa_addr_next[0];
wire        sel_dor = REG_DECODE ? sel_dor_q : sel_dor_c;
wire        sel_fdc = REG_DECODE ? sel_fdc_q : sel_fdc_c;
wire        bus_a0  = REG_DECODE ? a0_q : isa_addr[0];
`ifndef SYNTHESIS
always_ff @(posedge clk)
    if (REG_DECODE && (sel_dor_q !== sel_dor_c || sel_fdc_q !== sel_fdc_c || a0_q !== isa_addr[0]))
        $fatal(1, "fdc_card: registered address decode differs from the bus");
`endif
wire        ior_fall_c = !isa_ior_n && ior_d;
wire        iow_fall_c = !isa_iow_n && iow_d;
wire        iow_rise_c = isa_iow_n && !iow_d;
wire        ior_rise_c = isa_ior_n && !ior_d;
// pc10-iii (timing): the strobe edges one clk ahead into registers
// (REG_DECODE): an edge in the next clk is the next strobe against this one.
// The next strobes from the board are exact except in a reset's first clk,
// where this card is in reset (doc/timing.md 2.11).
logic       ior_fall_q, iow_fall_q, iow_rise_q, ior_rise_q;
always_ff @(posedge clk) begin
    ior_fall_q <= !isa_ior_n_next && isa_ior_n;
    iow_fall_q <= !isa_iow_n_next && isa_iow_n;
    iow_rise_q <= isa_iow_n_next && !isa_iow_n;
    ior_rise_q <= isa_ior_n_next && !isa_ior_n;
end
wire        ior_fall = REG_DECODE ? ior_fall_q : ior_fall_c;
wire        iow_fall = REG_DECODE ? iow_fall_q : iow_fall_c;
wire        iow_rise = REG_DECODE ? iow_rise_q : iow_rise_c;
wire        ior_rise = REG_DECODE ? ior_rise_q : ior_rise_c;
`ifndef SYNTHESIS
always_ff @(posedge clk)
    if (REG_DECODE && !reset && (ior_fall_q !== ior_fall_c || iow_fall_q !== iow_fall_c ||
                                 iow_rise_q !== iow_rise_c || ior_rise_q !== ior_rise_c))
        $fatal(1, "fdc_card: registered strobe edges differ from the bus");
`endif

always_ff @(posedge clk) begin
    ior_d <= isa_ior_n;
    iow_d <= isa_iow_n;
    if (!isa_iow_n) wdat_q <= isa_dout;     // the last value seen during the strobe
end

// ------------------------------------------------------------ DOR
logic [7:0] dor;

// ------------------------------------------------------------ the 765
logic       cpu_rd, cpu_wr;
logic [7:0] cpu_rdata, dma_rdata;
logic       drq, intr, dma_ack, dma_wr, tc_pulse;
logic [1:0] us;
logic       hd, step, step_dir;
logic [9:0] buf_addr;
logic       buf_we;
logic [7:0] buf_wdata, buf_rdata;
logic       x_start, x_write, x_fmt, x_slot, x_head, x_busy, x_done, x_err;
logic [7:0] x_cyl, x_sec;
logic       active;

assign cpu_rd  = ior_fall && sel_fdc;
assign cpu_wr  = iow_rise && io_cyc_fdc;
// pc10-iii (2026-10-26): DMA verify cycles. The BIOS's INT 13h AH=04 (DOS FORMAT's
// verify of every track) programs channel 2 for a verify transfer (8237 mode 42h): DACK2
// cycles without IOR or IOW. The 765 counts a DACK as the byte taken (its DRQ is cleared
// by DACK); without this every verify ended in an overrun (FORMAT: "Track 0 bad"). Here
// such a cycle is acknowledged when its DACK ends, with its TC.
logic       dack_d, dack_strb, dack_tc;
always_ff @(posedge clk) begin
    dack_d <= dack2 && !reset;
    if (!dack2) begin
        dack_strb <= 1'b0;
        dack_tc   <= 1'b0;
    end else begin
        if (!isa_ior_n || !isa_iow_n) dack_strb <= 1'b1;
        if (isa_tc) dack_tc <= 1'b1;
    end
end
wire        vfy_end = dack_d && !dack2 && !dack_strb;

assign dma_ack = ((ior_fall || iow_fall) && dack2) || vfy_end;
assign dma_wr  = iow_rise && dma_wr_cyc;
assign tc_pulse = (iow_rise && dma_wr_cyc && tc_q) || (ior_rise && dma_rd_cyc && tc_q) ||
                  (vfy_end && dack_tc);

always_ff @(posedge clk) begin
    if (reset) begin
        dma_rd_cyc <= 1'b0;  dma_wr_cyc <= 1'b0;  tc_q <= 1'b0;
        io_cyc_dor <= 1'b0;  io_cyc_fdc <= 1'b0;
        isa_din <= 8'h00;
    end else begin
        // CPU I/O cycles: decode at the strobe's start, act at its end
        if (iow_fall) begin
            io_cyc_dor <= sel_dor;
            io_cyc_fdc <= sel_fdc;
            io_a0      <= isa_addr[0];
        end
        if (iow_rise) begin
            io_cyc_dor <= 1'b0;
            io_cyc_fdc <= 1'b0;
        end
        if (cpu_rd) isa_din <= cpu_rdata;

        // DMA cycles on channel 2
        if (dma_ack) begin
            dma_rd_cyc <= !isa_ior_n;
            dma_wr_cyc <= !isa_iow_n;
            tc_q <= isa_tc;
            if (!isa_ior_n) isa_din <= dma_rdata;
        end else if ((dma_rd_cyc || dma_wr_cyc) && dack2 && isa_tc)
            tc_q <= 1'b1;
        if ((ior_rise && dma_rd_cyc) || (iow_rise && dma_wr_cyc)) begin
            dma_rd_cyc <= 1'b0;
            dma_wr_cyc <= 1'b0;
            tc_q <= 1'b0;
        end
    end
end

assign isa_dsel  = (!isa_ior_n && sel_fdc) || (!isa_ior_n && dack2);
assign isa_ready = 1'b1;
assign isa_irq   = {1'b0, intr && dor[3], 4'b0000};
assign isa_drq   = {1'b0, drq && dor[3], 1'b0};

// ------------------------------------------------------------ the drives
// pc10-iii (timing): the drive inputs (image geometry, presence, write
// protection: the glue's, asynchronous to the PC) are registered where they
// enter the card, and everything of the selected drive the 765 uses is a
// register loaded from the next values (the DOR's, the cylinders' and these
// inputs), so neither the DOR's select bits nor the geometry multiplexers
// sit in front of the 765. The inputs take effect one clk later than before,
// which is the same as a glue one clk slower (doc/timing.md 2.7).
logic [1:0]      b_80trk, b_present, b_wp;
logic [1:0][7:0] b_tracks;
logic [1:0][1:0] b_heads;
logic [1:0][5:0] b_spt;
logic [7:0]      b_spc [2];             // sectors per cylinder per drive
always_ff @(posedge clk) begin
    b_80trk   <= drv_80trk;
    b_present <= img_present;
    b_wp      <= img_wp;
    b_tracks  <= img_tracks;
    b_heads   <= img_heads;
    b_spt     <= img_spt;
    b_spc[0]  <= 8'(img_heads[0]) * 8'(img_spt[0]);
    b_spc[1]  <= 8'(img_heads[1]) * 8'(img_spt[1]);
end

// A drive is selected when the DOR selects it and its motor bit is set.
wire [1:0] psel     = dor[1:0];
logic      drv_sel;                     // registered below: int'(psel) < NDRIVES && dor[4 + psel]
wire       pd       = psel[0];
logic [7:0] cyl [2];

// pc10-iii (timing): the DOR and the cylinders with their D inputs written
// out, so that the selected drive's cylinder (the 765's drv_cyl, which goes
// into its tag compares) is a register of its own: loaded with
// cyl_next[dor_next[0]] it equals cyl[pd] in every clk.
logic [7:0] dor_next;
logic [7:0] cyl_next [2];
logic [7:0] drv_cyl_q;
always_comb begin
    dor_next = dor;
    if (reset)
        dor_next = 8'h00;
    else if (iow_rise && io_cyc_dor)
        dor_next = wdat_q;

    cyl_next = cyl;
    if (reset) begin
        cyl_next[0] = 8'd0;
        cyl_next[1] = 8'd0;
    end else if (step && drv_sel) begin
        if (step_dir) begin
            if (cyl[pd] < (b_80trk[pd] ? 8'd83 : 8'd41)) cyl_next[pd] = cyl[pd] + 8'd1;
        end else if (cyl[pd] != 8'd0)
            cyl_next[pd] = cyl[pd] - 8'd1;
    end
end
// the selected drive, from the next values
wire [1:0]  psel_n  = dor_next[1:0];
wire        pd_n    = psel_n[0];
logic       s_present, s_wp, s_cyl_ok;
logic [1:0] s_heads;
logic [5:0] s_spt;
always_ff @(posedge clk) begin
    dor       <= dor_next;
    cyl       <= cyl_next;
    drv_cyl_q <= cyl_next[pd_n];
    drv_sel   <= int'(psel_n) < NDRIVES && dor_next[4 + psel_n];
    s_present <= img_present[pd_n];
    s_wp      <= img_wp[pd_n];
    s_heads   <= img_heads[pd_n];
    s_spt     <= img_spt[pd_n];
    s_cyl_ok  <= cyl_next[pd_n] < img_tracks[pd_n];
end
`ifndef SYNTHESIS
always_ff @(posedge clk)
    if (drv_cyl_q !== cyl[pd] || drv_sel !== (int'(psel) < NDRIVES && dor[4 + psel]) ||
        s_present !== b_present[pd] || s_wp !== b_wp[pd] || s_heads !== b_heads[pd] ||
        s_spt !== b_spt[pd] || s_cyl_ok !== (cyl[pd] < b_tracks[pd]) ||
        b_spc[0] !== 8'(b_heads[0]) * 8'(b_spt[0]) || b_spc[1] !== 8'(b_heads[1]) * 8'(b_spt[1]))
        $fatal(1, "fdc_card: registered selected-drive values differ from the original expressions");
`endif

assign drv_motor  = dor[5:4];
assign fdc_active = active;
assign drv_select = {drv_sel && pd, drv_sel && !pd};

// pc10-iii (drive sound): the head movements of the selected drive, as the
// drive mechanics above take them (a 765 step pulse at a stop moves nothing)
always_ff @(posedge clk) begin
    drv_step    <= !reset && cyl_next[pd] != cyl[pd];
    drv_step_in <= step_dir;
end

// geometry of the selected drive's medium and the image address
// (pc10-iii: g_cyl_ok = cyl[pd] < tracks for the 765's track format check)
wire        g_cyl_ok = s_cyl_ok;
wire [1:0]  g_heads  = s_heads;
wire [5:0]  g_spt    = s_spt;
// Timing (pc10-iii, doc/timing.md): the image address is computed for both
// drives' geometries and the DOR's drive select picks one at the end, so the
// DOR is one LUT before the sector port's LBA register instead of in front of
// the multiplication (keep: synthesis would otherwise share one multiplier
// behind a geometry multiplexer again). And as C * (H * S) + h * S + s - 1:
// one 8 x 8 bit multiplication by the sectors per cylinder (geometry only,
// at most 3 * 63 = 189, so 8 bits are exact) instead of two in a row. The
// same value for every input: nothing in either form exceeds 16 bits
// (255 * 189 + 63 + 255 < 65536). Originally:
//   wire [15:0] x_lba    = 16'(({8'd0, x_cyl} * 16'(g_heads) + 16'(x_head)) * 16'(g_spt) + 16'(x_sec) - 16'd1);
(* keep = "true" *) wire [15:0] x_lba_d0 =
    16'({8'd0, x_cyl} * {8'd0, b_spc[0]}) + (x_head ? 16'(b_spt[0]) : 16'd0) + 16'(x_sec) - 16'd1;
(* keep = "true" *) wire [15:0] x_lba_d1 =
    16'({8'd0, x_cyl} * {8'd0, b_spc[1]}) + (x_head ? 16'(b_spt[1]) : 16'd0) + 16'(x_sec) - 16'd1;
wire [15:0] x_lba    = pd ? x_lba_d1 : x_lba_d0;
`ifndef SYNTHESIS
always_ff @(posedge clk)
    if (x_lba !== 16'(({8'd0, x_cyl} * 16'(g_heads) + 16'(x_head)) * 16'(g_spt) + 16'(x_sec) - 16'd1))
        $fatal(1, "fdc_card: LBA differs from the original formula");
`endif

upd765 #(
    .TIME_SCALE   (TIME_SCALE),
    .RQM_DELAY_US (RQM_DELAY_US),
    .RESET_US     (RESET_US)
) u_765 (
    .clk        (clk),
    .reset      (reset || !dor[2]),
    .por        (reset),
    .us_tick    (us_tick),
    .cpu_rd     (cpu_rd),
    .cpu_wr     (cpu_wr),
    .cpu_a0     (cpu_rd ? bus_a0 : io_a0),
    .cpu_wdata  (wdat_q),
    .cpu_rdata  (cpu_rdata),
    .drq        (drq),
    .dma_ack    (dma_ack),
    .dma_wr     (dma_wr),
    .dma_wdata  (wdat_q),
    .dma_rdata  (dma_rdata),
    .tc         (tc_pulse),
    .intr       (intr),
    .us         (us),
    .hd         (hd),
    .step       (step),
    .step_dir   (step_dir),
    .drv_trk0   (drv_sel && drv_cyl_q == 8'd0),
    .drv_wp     (drv_sel && s_present && s_wp),
    .drv_ready  (1'b1),
    .drv_ts     (1'b1),
    .drv_spin   (drv_sel && s_present),
    .drv_cyl    (drv_cyl_q),            // = cyl[pd]
    .geo_cyl_ok (g_cyl_ok),
    .geo_heads  (g_heads),
    .geo_spt    (g_spt),
    .buf_addr   (buf_addr),
    .buf_we     (buf_we),
    .buf_wdata  (buf_wdata),
    .buf_rdata  (buf_rdata),
    .x_start    (x_start),
    .x_write    (x_write),
    .x_fmt      (x_fmt),
    .x_slot     (x_slot),
    .x_cyl      (x_cyl),
    .x_head     (x_head),
    .x_sec      (x_sec),
    .x_busy     (x_busy),
    .x_done     (x_done),
    .x_err      (x_err),
    .active     (active)
);

fdc_secbuf u_buf (
    .clk         (clk),
    .reset       (reset),
    .a_addr      (buf_addr),
    .a_we        (buf_we),
    .a_wdata     (buf_wdata),
    .a_rdata     (buf_rdata),
    .x_start     (x_start),
    .x_write     (x_write),
    .x_fmt       (x_fmt),
    .x_slot      (x_slot),
    .x_cyl       (x_cyl),
    .x_head      (x_head),
    .x_sec       (x_sec),
    .x_lba       (x_lba),
    .x_drive     (pd),
    .x_busy      (x_busy),
    .x_done      (x_done),
    .x_err       (x_err),
    .sp_req      (sp_req),
    .sp_write    (sp_write),
    .sp_fmt      (sp_fmt),
    .sp_drive    (sp_drive),
    .sp_cyl      (sp_cyl),
    .sp_head     (sp_head),
    .sp_sector   (sp_sector),
    .sp_lba      (sp_lba),
    .sp_rd_valid (sp_rd_valid),
    .sp_rd_data  (sp_rd_data),
    .sp_wr_valid (sp_wr_valid),
    .sp_wr_data  (sp_wr_data),
    .sp_wr_ready (sp_wr_ready),
    .sp_done     (sp_done),
    .sp_err      (sp_err)
);

endmodule
