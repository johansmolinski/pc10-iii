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

assign isa_din   = cga_dsel ? cga_din : 8'h00;
assign isa_dsel  = cga_dsel;
assign isa_ready = cga_ready;
assign isa_irq   = 6'b000000;
assign isa_drq   = 3'b000;

endmodule
