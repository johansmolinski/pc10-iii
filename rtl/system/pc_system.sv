// pc_system.sv - the PC: clocks, 8088, system board and the cards.
// Ports: doc/architecture.md section 4.
//
// GPL-3.0-or-later, pc10-iii.

module pc_system #(
    parameter int RAM_KB  = 640,
    // fitted video cards (doc/architecture.md section 4, doc/mda.md section 7)
    parameter bit CGA_FIT = 1'b1,       // IBM CGA at B8000-BFFFF, 3D0-3DF
    parameter int MDA_FIT = 0,          // 0 none, 1 IBM MDA, 2 Hercules (B0000, 3B0-3BF)
    parameter int DRQ0_SKEW = 0         // simulation only (xt_board)
) (
    input  logic        clk,
    input  logic        reset,
    // the chipset (xt_board): 1 = the PC10-III's FE2010A port logic, 0 = IBM
    // 5160 (8255); taken while reset is high
    input  logic        fe2010a,

    // the 8088's microcode bundle (tools/mkucode.py, doc/z8086.md): the file,
    // one byte per clk at offset ucl_addr, while reset is high
    input  logic        ucl_we,
    input  logic [12:0] ucl_addr,
    input  logic [7:0]  ucl_data,

    output logic [19:0] ram_addr,
    output logic        ram_en,
    output logic        ram_we,
    output logic [7:0]  ram_wdata,
    input  logic [7:0]  ram_rdata,
    input  logic        ram_ack,

    output logic [15:0] rom_addr,
    input  logic [7:0]  rom_rdata,

    output logic        vid_ce,
    output logic [3:0]  vid_rgbi,
    output logic        vid_hsync,
    output logic        vid_vsync,
    output logic        vid_hblank,
    output logic        vid_vblank,

    // MDA / Hercules video (MDA_FIT != 0): one dot per mda_ce (16.257 MHz,
    // Hercules 16.000 MHz, on average); 720x350 at 18.43 kHz / 49.8 Hz
    output logic        mda_ce,
    output logic        mda_video,
    output logic        mda_intens,
    output logic        mda_hsync,
    output logic        mda_vsync,
    output logic        mda_hblank,
    output logic        mda_vblank,

    // character ROM, loaded by the glue (8 KB, IBM 5788005 layout): the CGA
    // uses 0x1000-0x1FFF, the MDA 0x0000-0x0FFF
    input  logic        font_we,
    input  logic [12:0] font_addr,
    input  logic [7:0]  font_data,
    input  logic        font_thin,

    // floppy drives A: and B: (rtl/fdc, doc/fdc.md): image geometry from the
    // glue, the sector port to the image backend
    input  logic [1:0]       drv_80trk,
    input  logic [1:0]       img_present,
    input  logic [1:0]       img_wp,
    input  logic [1:0][7:0]  img_tracks,
    input  logic [1:0][1:0]  img_heads,
    input  logic [1:0][5:0]  img_spt,
    output logic [1:0]       drv_motor,
    output logic             fdc_active,
    output logic [1:0]       drv_select,    // drive LED / drive sound (fdc_card.sv)
    output logic             drv_step,
    output logic             drv_step_in,
    output logic        sp_req,
    output logic        sp_write,
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
    input  logic        sp_err,

    // hard disk card (rtl/hdc, doc/hdc.md): an XTIDE-compatible card with
    // its option ROM socket at C8000-CBFFF (16 KB, the glue's block RAM, read
    // like the BIOS ROM), two drives and their sector port
    input  logic             hdc_enable,
    input  logic [1:0]       hdc_variant,   // 0 XT-CF / Lo-tech, 1 XTIDE rev 1, 2 XTIDE rev 2
    output logic [13:0]      hdc_rom_addr,
    input  logic [7:0]       hdc_rom_rdata, // 1 clk latency
    input  logic [1:0]       hd_present,
    input  logic [1:0][27:0] hd_sectors,
    input  logic [1:0][15:0] hd_cyls,
    input  logic [1:0][4:0]  hd_heads,
    input  logic [1:0][5:0]  hd_spt,
    output logic             hd_active,
    output logic        hd_sp_req,
    output logic        hd_sp_write,
    output logic        hd_sp_drive,
    output logic [27:0] hd_sp_lba,
    input  logic        hd_sp_rd_valid,
    input  logic [7:0]  hd_sp_rd_data,
    output logic        hd_sp_wr_valid,
    output logic [7:0]  hd_sp_wr_data,
    input  logic        hd_sp_wr_ready,
    input  logic        hd_sp_done,
    input  logic        hd_sp_err,

    input  logic [7:0]  kbd_code,
    input  logic        kbd_valid,
    output logic        kbd_busy,

    output logic        speaker,

    input  logic [7:0]  dip_sw1
);

// ------------------------------------------------------------ clocks
logic ce_14m, cpu_step, cpu_fall, rdy_ce, cpu_prestep, ce_pclk, pit_clk;
pc_clocks u_clocks (
    .clk        (clk),
    .reset      (reset),
    .ce_14m     (ce_14m),
    .cpu_step   (cpu_step),
    .cpu_fall   (cpu_fall),
    .rdy_ce     (rdy_ce),
    .cpu_prestep(cpu_prestep),
    .ce_pclk    (ce_pclk),
    .pit_clk    (pit_clk)
);
assign vid_ce = ce_14m;

// ------------------------------------------------------------ CPU
logic [19:0] cpu_ad;
logic [7:0]  cpu_din;
logic [2:0]  cpu_s2_s0, cpu_bus_t, cpu_bus_type;
logic [1:0]  cpu_qs;
logic        cpu_lock_n, cpu_ale, cpu_ready, cpu_intr, cpu_nmi;

cpu8088 u_cpu (
    .clk      (clk),
    .reset    (reset),
    .step     (cpu_step),
    .ucl_we   (ucl_we),
    .ucl_addr (ucl_addr),
    .ucl_data (ucl_data),
    .ready    (cpu_ready),
    .intr     (cpu_intr),
    .nmi      (cpu_nmi),
    .test_n   (1'b1),
    .ad_out   (cpu_ad),
    .ad_in    (cpu_din),
    .s2_s0    (cpu_s2_s0),
    .qs       (cpu_qs),
    .lock_n   (cpu_lock_n),
    .ale      (cpu_ale),
    .bus_t    (cpu_bus_t),
    .bus_type (cpu_bus_type),
    .dbg_cs   (),
    .dbg_ip   ()
);

// ------------------------------------------------------------ system board
logic [19:0] isa_addr, isa_addr_next;
logic [7:0]  isa_dout, isa_din;
logic        isa_dsel, isa_memr_n, isa_memw_n, isa_ior_n, isa_iow_n;
logic        isa_aen, isa_aen_next, isa_ale, isa_ready, isa_tc;
logic        isa_ior_n_next, isa_iow_n_next, isa_memr_n_next, isa_memw_n_next;
logic [7:2]  isa_irq;
logic [3:1]  isa_drq;
logic [3:0]  isa_dack_n;

xt_board #(.RAM_KB(RAM_KB), .DRQ0_SKEW(DRQ0_SKEW)) u_board (
    .clk          (clk),
    .reset        (reset),
    .fe2010a      (fe2010a),
    .cpu_step     (cpu_step),
    .cpu_fall     (cpu_fall),
    .rdy_ce       (rdy_ce),
    .cpu_prestep  (cpu_prestep),
    .pit_clk      (pit_clk),
    .cpu_ad       (cpu_ad),
    .cpu_din      (cpu_din),
    .cpu_s2_s0    (cpu_s2_s0),
    .cpu_lock_n   (cpu_lock_n),
    .cpu_bus_t    (cpu_bus_t),
    .cpu_bus_type (cpu_bus_type),
    .cpu_ready    (cpu_ready),
    .cpu_intr     (cpu_intr),
    .cpu_nmi      (cpu_nmi),
    .ram_addr     (ram_addr),
    .ram_en       (ram_en),
    .ram_we       (ram_we),
    .ram_wdata    (ram_wdata),
    .ram_rdata    (ram_rdata),
    .ram_ack      (ram_ack),
    .rom_addr     (rom_addr),
    .rom_rdata    (rom_rdata),
    .isa_addr     (isa_addr),
    .isa_addr_next(isa_addr_next),
    .isa_aen_next (isa_aen_next),
    .isa_ior_n_next(isa_ior_n_next),
    .isa_iow_n_next(isa_iow_n_next),
    .isa_memr_n_next(isa_memr_n_next),
    .isa_memw_n_next(isa_memw_n_next),
    .isa_dout     (isa_dout),
    .isa_din      (isa_din),
    .isa_dsel     (isa_dsel),
    .isa_memr_n   (isa_memr_n),
    .isa_memw_n   (isa_memw_n),
    .isa_ior_n    (isa_ior_n),
    .isa_iow_n    (isa_iow_n),
    .isa_aen      (isa_aen),
    .isa_ale      (isa_ale),
    .isa_ready    (isa_ready),
    .isa_irq      (isa_irq),
    .isa_drq      (isa_drq),
    .isa_dack_n   (isa_dack_n),
    .isa_tc       (isa_tc),
    .kbd_code     (kbd_code),
    .kbd_valid    (kbd_valid),
    .kbd_busy     (kbd_busy),
    .speaker      (speaker),
    .dip_sw1      (dip_sw1)
);

// ------------------------------------------------------------ cards
logic [7:0] cga_din, cga_din_c;
logic       cga_dsel, cga_ready, cga_dsel_c, cga_ready_c;
logic [3:0] cga_rgbi;
logic       cga_hs, cga_vs, cga_hb, cga_vb;

cga_card #(.REG_READY(1'b1)) u_cga (
    .clk        (clk),
    .reset      (reset),
    .ce_14m     (ce_14m),
    .isa_addr   (isa_addr),
    .isa_addr_next  (isa_addr_next),
    .isa_memr_n_next(isa_memr_n_next),
    .isa_memw_n_next(isa_memw_n_next),
    .isa_aen_next   (isa_aen_next),
    .isa_ior_n_next (isa_ior_n_next),
    .isa_iow_n_next (isa_iow_n_next),
    .isa_dout   (isa_dout),
    .isa_din    (cga_din_c),
    .isa_dsel   (cga_dsel_c),
    .isa_memr_n (isa_memr_n),
    .isa_memw_n (isa_memw_n),
    .isa_ior_n  (isa_ior_n),
    .isa_iow_n  (isa_iow_n),
    .isa_aen    (isa_aen),
    .isa_ready  (cga_ready_c),
    .font_we    (font_we),
    .font_addr  (font_addr),
    .font_data  (font_data),
    .font_thin  (font_thin),
    .lpen_trig  (1'b0),
    .lpen_sw    (1'b0),
    .vid_rgbi   (cga_rgbi),
    .vid_hsync  (cga_hs),
    .vid_vsync  (cga_vs),
    .vid_hblank (cga_hb),
    .vid_vblank (cga_vb),
    .comp_cphase(),
    .comp_hsync (),
    .comp_vsync (),
    .comp_burst (),
    .comp_bw    (),
    .comp_mode  ()
);

// a card that is not fitted is not on the bus (synthesis removes it)
assign cga_din    = CGA_FIT ? cga_din_c : 8'h00;
assign cga_dsel   = CGA_FIT && cga_dsel_c;
assign cga_ready  = !CGA_FIT || cga_ready_c;
assign vid_rgbi   = CGA_FIT ? cga_rgbi : 4'h0;
assign vid_hsync  = CGA_FIT && cga_hs;
assign vid_vsync  = CGA_FIT && cga_vs;
assign vid_hblank = !CGA_FIT || cga_hb;
assign vid_vblank = !CGA_FIT || cga_vb;

// MDA or Hercules. With a CGA in the machine the Hercules card does not
// answer at B8000-BFFFF (its page 2 stays invisible to the CPU).
logic [7:0] mda_din, mda_din_c;
logic       mda_dsel, mda_ready, mda_dsel_c, mda_ready_c;
logic       mda_ce_c, mda_v_c, mda_i_c, mda_hs_c, mda_vs_c, mda_hb_c, mda_vb_c;
wire        mda_on = MDA_FIT != 0;

mda_card #(.HERC(MDA_FIT == 2)) u_mda (
    .clk        (clk),
    .reset      (reset),
    .isa_addr   (isa_addr),
    .isa_dout   (isa_dout),
    .isa_din    (mda_din_c),
    .isa_dsel   (mda_dsel_c),
    .isa_memr_n (isa_memr_n | !mda_on),     // an unfitted card sees no strobes (its
    .isa_memw_n (isa_memw_n | !mda_on),     // write-lost check would fire on a BIOS
    .isa_ior_n  (isa_ior_n  | !mda_on),     // probing B0000 with nobody answering)
    .isa_iow_n  (isa_iow_n  | !mda_on),
    .isa_aen    (isa_aen),
    .isa_ready  (mda_ready_c),
    .cga_fitted (CGA_FIT),
    .font_we    (font_we),
    .font_addr  (font_addr),
    .font_data  (font_data),
    .vid_ce     (mda_ce_c),
    .vid_video  (mda_v_c),
    .vid_intens (mda_i_c),
    .vid_hsync  (mda_hs_c),
    .vid_vsync  (mda_vs_c),
    .vid_hblank (mda_hb_c),
    .vid_vblank (mda_vb_c)
);

assign mda_din    = mda_on ? mda_din_c : 8'h00;
assign mda_dsel   = mda_on && mda_dsel_c;
assign mda_ready  = !mda_on || mda_ready_c;
assign mda_ce     = mda_on && mda_ce_c;
assign mda_video  = mda_on && mda_v_c;
assign mda_intens = mda_on && mda_i_c;
assign mda_hsync  = mda_on && mda_hs_c;
assign mda_vsync  = mda_on && mda_vs_c;
assign mda_hblank = !mda_on || mda_hb_c;
assign mda_vblank = !mda_on || mda_vb_c;

logic [7:0] fdc_din;
logic       fdc_dsel, fdc_ready;
logic [7:2] fdc_irq;
logic [3:1] fdc_drq;

fdc_card #(.REG_DECODE(1'b1)) u_fdc (
    .clk         (clk),
    .reset       (reset),
    .isa_addr    (isa_addr),
    .isa_addr_next(isa_addr_next),
    .isa_aen_next(isa_aen_next),
    .isa_ior_n_next(isa_ior_n_next),
    .isa_iow_n_next(isa_iow_n_next),
    .isa_dout    (isa_dout),
    .isa_din     (fdc_din),
    .isa_dsel    (fdc_dsel),
    .isa_ior_n   (isa_ior_n),
    .isa_iow_n   (isa_iow_n),
    .isa_aen     (isa_aen),
    .isa_ready   (fdc_ready),
    .isa_irq     (fdc_irq),
    .isa_drq     (fdc_drq),
    .isa_dack_n  (isa_dack_n),
    .isa_tc      (isa_tc),
    .drv_80trk   (drv_80trk),
    .img_present (img_present),
    .img_wp      (img_wp),
    .img_tracks  (img_tracks),
    .img_heads   (img_heads),
    .img_spt     (img_spt),
    .drv_motor   (drv_motor),
    .fdc_active  (fdc_active),
    .drv_select  (drv_select),
    .drv_step    (drv_step),
    .drv_step_in (drv_step_in),
    .sp_req      (sp_req),
    .sp_write    (sp_write),
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

logic [7:0] hdc_din;
logic       hdc_dsel, hdc_ready;
logic [7:2] hdc_irq;

xtide_card u_hdc (
    .clk         (clk),
    .reset       (reset),
    .isa_addr    (isa_addr),
    .isa_dout    (isa_dout),
    .isa_din     (hdc_din),
    .isa_dsel    (hdc_dsel),
    .isa_memr_n  (isa_memr_n),
    .isa_ior_n   (isa_ior_n),
    .isa_iow_n   (isa_iow_n),
    .isa_aen     (isa_aen),
    .isa_ready   (hdc_ready),
    .isa_irq     (hdc_irq),
    .enable      (hdc_enable),
    .variant     (hdc_variant),
    .rom_addr    (hdc_rom_addr),
    .rom_rdata   (hdc_rom_rdata),
    .hd_present  (hd_present),
    .hd_sectors  (hd_sectors),
    .hd_cyls     (hd_cyls),
    .hd_heads    (hd_heads),
    .hd_spt      (hd_spt),
    .hd_active   (hd_active),
    .sp_req      (hd_sp_req),
    .sp_write    (hd_sp_write),
    .sp_drive    (hd_sp_drive),
    .sp_lba      (hd_sp_lba),
    .sp_rd_valid (hd_sp_rd_valid),
    .sp_rd_data  (hd_sp_rd_data),
    .sp_wr_valid (hd_sp_wr_valid),
    .sp_wr_data  (hd_sp_wr_data),
    .sp_wr_ready (hd_sp_wr_ready),
    .sp_done     (hd_sp_done),
    .sp_err      (hd_sp_err)
);

assign isa_din   = (cga_dsel ? cga_din : 8'h00) | (mda_dsel ? mda_din : 8'h00) |
                   (fdc_dsel ? fdc_din : 8'h00) | (hdc_dsel ? hdc_din : 8'h00);
assign isa_dsel  = cga_dsel | mda_dsel | fdc_dsel | hdc_dsel;
assign isa_ready = cga_ready & mda_ready & fdc_ready & hdc_ready;
assign isa_irq   = fdc_irq | hdc_irq;
assign isa_drq   = fdc_drq;

endmodule
