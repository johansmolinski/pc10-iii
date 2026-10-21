// tb_sys.sv - pc_system with RAM and ROM models for the Verilator system
// simulation (sys_run.cpp). The ROM image comes from +rom=<hex file> (one
// byte per line, 64 KB, F0000-FFFFF).

module tb_sys (
    input  logic        clk,
    input  logic        reset,
    input  logic [7:0]  kbd_code,
    input  logic        kbd_valid,
    output logic        kbd_busy,
    input  logic [7:0]  dip_sw1,

    // monitors
    output logic        io_wr,          // one clk: a CPU I/O write strobe began
    output logic [15:0] io_addr,
    output logic [7:0]  io_data,
    output logic        cpu_step,
    output logic [15:0] cs,
    output logic [15:0] ip,
    output logic [2:0]  bus_t,
    output logic [2:0]  bus_type,
    output logic [19:0] bus_addr,
    output logic [7:0]  bus_data,
    output logic [1:0]  qs,
    output logic        speaker,

    // floppy: geometry and the sector port (served by sys_run.cpp)
    input  logic [1:0]  img_present,
    input  logic [15:0] img_tracks,     // {B, A}
    input  logic [3:0]  img_heads,
    input  logic [11:0] img_spt,
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
    input  logic        sp_err
);

logic [7:0]  ram [1048576];
logic [7:0]  rom [65536];
logic [19:0] ram_addr;
logic        ram_en, ram_we, ram_ack;
logic [7:0]  ram_wdata, ram_rdata, rom_rdata;
logic [15:0] rom_addr;

initial begin
    string f;
    if ($value$plusargs("rom=%s", f)) $readmemh(f, rom);
end

always_ff @(posedge clk) begin
    ram_ack <= ram_en;
    if (ram_en && ram_we) ram[ram_addr] <= ram_wdata;
    if (ram_en) ram_rdata <= ram[ram_addr];
    rom_rdata <= rom[rom_addr];
end

pc_system u_pc (
    .clk        (clk),
    .reset      (reset),
    .ram_addr   (ram_addr),
    .ram_en     (ram_en),
    .ram_we     (ram_we),
    .ram_wdata  (ram_wdata),
    .ram_rdata  (ram_rdata),
    .ram_ack    (ram_ack),
    .rom_addr   (rom_addr),
    .rom_rdata  (rom_rdata),
    .vid_ce     (),
    .vid_rgbi   (),
    .vid_hsync  (),
    .vid_vsync  (),
    .vid_hblank (),
    .vid_vblank (),
    .font_we    (1'b0),
    .font_addr  (13'h0),
    .font_data  (8'h0),
    .font_thin  (1'b0),
    .drv_80trk  (2'b00),
    .img_present(img_present),
    .img_wp     (2'b00),
    .img_tracks (img_tracks),
    .img_heads  (img_heads),
    .img_spt    (img_spt),
    .drv_motor  (),
    .fdc_active (),
    .sp_req     (sp_req),
    .sp_write   (sp_write),
    .sp_drive   (sp_drive),
    .sp_cyl     (sp_cyl),
    .sp_head    (sp_head),
    .sp_sector  (sp_sector),
    .sp_lba     (sp_lba),
    .sp_rd_valid(sp_rd_valid),
    .sp_rd_data (sp_rd_data),
    .sp_wr_valid(sp_wr_valid),
    .sp_wr_data (sp_wr_data),
    .sp_wr_ready(sp_wr_ready),
    .sp_done    (sp_done),
    .sp_err     (sp_err),
    .kbd_code   (kbd_code),
    .kbd_valid  (kbd_valid),
    .kbd_busy   (kbd_busy),
    .speaker    (speaker),
    .dip_sw1    (dip_sw1)
);

logic iow_d;
always_ff @(posedge clk) iow_d <= !u_pc.isa_iow_n;
assign io_wr    = !u_pc.isa_iow_n && !iow_d && !u_pc.isa_aen;
assign io_addr  = u_pc.isa_addr[15:0];
assign io_data  = u_pc.isa_dout;
assign cpu_step = u_pc.cpu_step;
assign cs       = u_pc.u_cpu.biu.reg_cs;
assign ip       = u_pc.u_cpu.biu.eu_ip;
assign bus_t    = u_pc.cpu_bus_t;
assign bus_type = u_pc.cpu_bus_type;
assign bus_addr = u_pc.u_board.bus_addr;
assign bus_data = u_pc.cpu_bus_type == 3'd6 || u_pc.cpu_bus_type == 3'd2 ? u_pc.isa_dout : u_pc.cpu_din;
assign qs       = u_pc.cpu_qs;

endmodule
