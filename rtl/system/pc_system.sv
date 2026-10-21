// pc_system.sv - the PC: clocks, 8088, system board and the cards.
// Ports: doc/architecture.md section 4.
//
// GPL-3.0-or-later, pc10-iii.

module pc_system #(
    parameter int RAM_KB = 640
) (
    input  logic        clk,
    input  logic        reset,

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

    // CGA character ROM, loaded by the glue (8 KB, IBM 5788005 layout)
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

    input  logic [7:0]  kbd_code,
    input  logic        kbd_valid,
    output logic        kbd_busy,

    output logic        speaker,

    input  logic [7:0]  dip_sw1
);

// ------------------------------------------------------------ clocks
logic ce_14m, cpu_step, cpu_fall, ce_pclk, pit_clk;
pc_clocks u_clocks (
    .clk      (clk),
    .reset    (reset),
    .ce_14m   (ce_14m),
    .cpu_step (cpu_step),
    .cpu_fall (cpu_fall),
    .ce_pclk  (ce_pclk),
    .pit_clk  (pit_clk)
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
logic [19:0] isa_addr;
logic [7:0]  isa_dout, isa_din;
logic        isa_dsel, isa_memr_n, isa_memw_n, isa_ior_n, isa_iow_n;
logic        isa_aen, isa_ale, isa_ready, isa_tc;
logic [7:2]  isa_irq;
logic [3:1]  isa_drq;
logic [3:0]  isa_dack_n;

xt_board #(.RAM_KB(RAM_KB)) u_board (
    .clk          (clk),
    .reset        (reset),
    .cpu_step     (cpu_step),
    .cpu_fall     (cpu_fall),
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
logic [7:0] cga_din;
logic       cga_dsel, cga_ready;

cga_card u_cga (
    .clk        (clk),
    .reset      (reset),
    .ce_14m     (ce_14m),
    .isa_addr   (isa_addr),
    .isa_dout   (isa_dout),
    .isa_din    (cga_din),
    .isa_dsel   (cga_dsel),
    .isa_memr_n (isa_memr_n),
    .isa_memw_n (isa_memw_n),
    .isa_ior_n  (isa_ior_n),
    .isa_iow_n  (isa_iow_n),
    .isa_aen    (isa_aen),
    .isa_ready  (cga_ready),
    .font_we    (font_we),
    .font_addr  (font_addr),
    .font_data  (font_data),
    .font_thin  (font_thin),
    .lpen_trig  (1'b0),
    .lpen_sw    (1'b0),
    .vid_rgbi   (vid_rgbi),
    .vid_hsync  (vid_hsync),
    .vid_vsync  (vid_vsync),
    .vid_hblank (vid_hblank),
    .vid_vblank (vid_vblank),
    .comp_cphase(),
    .comp_hsync (),
    .comp_vsync (),
    .comp_burst (),
    .comp_bw    (),
    .comp_mode  ()
);

logic [7:0] fdc_din;
logic       fdc_dsel, fdc_ready;
logic [7:2] fdc_irq;
logic [3:1] fdc_drq;

fdc_card u_fdc (
    .clk         (clk),
    .reset       (reset),
    .isa_addr    (isa_addr),
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

assign isa_din   = (cga_dsel ? cga_din : 8'h00) | (fdc_dsel ? fdc_din : 8'h00);
assign isa_dsel  = cga_dsel | fdc_dsel;
assign isa_ready = cga_ready & fdc_ready;
assign isa_irq   = fdc_irq;
assign isa_drq   = fdc_drq;

endmodule
