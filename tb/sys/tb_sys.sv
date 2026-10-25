// tb_sys.sv - pc_system with RAM and ROM models for the Verilator system
// simulation (sys_run.cpp). The ROM image comes from +rom=<hex file> (one
// byte per line, 64 KB, F0000-FFFFF), the XTIDE card's option ROM from
// +xub=<hex file> (16 KB, C8000-CBFFF; 0xFF without one). MDA_FIT: 0 none,
// 1 MDA, 2 Hercules.

module tb_sys #(
    parameter int RAM_KB = 640,
    parameter int DRQ0_SKEW = 0,
    parameter int MDA_FIT = 0,
    parameter bit FE2010A = 1'b0
) (
    input  logic        clk,
    input  logic        reset,
    // the 8088's microcode bundle (sys_run.cpp streams the file in reset)
    input  logic        ucl_we,
    input  logic [12:0] ucl_addr,
    input  logic [7:0]  ucl_data,
    // instruction log (sys_run -i): the EU's dispatch of a first byte
    output logic        it_disp,
    output logic [7:0]  it_op,
    output logic [15:0] it_ip,
    output logic [15:0] it_ax, it_bx, it_cx, it_dx, it_sp, it_bp, it_si, it_di,
    output logic [15:0] it_ds, it_es, it_ss, it_f,
    input  logic [7:0]  kbd_code,
    input  logic        kbd_valid,
    output logic        kbd_busy,
    input  logic [7:0]  dip_sw1,

    // character ROM load (sys_run -F), MDA video
    input  logic        font_we,
    input  logic [12:0] font_addr,
    input  logic [7:0]  font_data,
    output logic        mda_ce,
    output logic        mda_video,
    output logic        mda_intens,
    output logic        mda_hsync,
    output logic        mda_vsync,
    output logic        mda_hblank,
    output logic        mda_vblank,

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
    input  logic        sp_err,

    // hard disk: configuration and the sector port (served by sys_run.cpp)
    input  logic        hdc_enable,
    input  logic [1:0]  hdc_variant,
    input  logic [1:0]  hd_present,
    input  logic [55:0] hd_sectors,     // {slave, master}
    input  logic [31:0] hd_cyls,
    input  logic [9:0]  hd_heads,
    input  logic [11:0] hd_spt,
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
    input  logic        hd_sp_err
);

logic [7:0]  ram [1048576];
logic [7:0]  rom [65536];
logic [19:0] ram_addr;
logic        ram_en, ram_we, ram_ack;
logic [7:0]  ram_wdata, ram_rdata, rom_rdata;
logic [15:0] rom_addr;
logic [7:0]  xrom [16384];
logic [13:0] xrom_addr;
logic [7:0]  xrom_rdata;

initial begin
    string f;
    if ($value$plusargs("rom=%s", f)) $readmemh(f, rom);
    for (int i = 0; i < 16384; i++) xrom[i] = 8'hFF;
    if ($value$plusargs("xub=%s", f)) $readmemh(f, xrom);
end

// RAM model: the answer comes +ramlat=<n> clk after ram_en (default 1, like a
// bare block RAM; the MEGA65 glue's pc_ram answers after 6)
int         ram_lat = 1;
logic [15:0] ack_sh = '0;
logic [7:0]  rd_sh [16];
logic [7:0]  rd_q;
initial if ($value$plusargs("ramlat=%d", ram_lat)) ;
always_ff @(posedge clk) begin
    if (ram_en && ram_we) ram[ram_addr] <= ram_wdata;
    if (ram_en) rd_q = ram[ram_addr];
    ack_sh <= {ack_sh[14:0], ram_en};
    rd_sh[0] <= rd_q;
    for (int i = 1; i < 16; i++) rd_sh[i] <= rd_sh[i-1];
    rom_rdata <= rom[rom_addr];
    xrom_rdata <= xrom[xrom_addr];
end
assign ram_ack   = ack_sh[ram_lat - 1];
assign ram_rdata = rd_sh[ram_lat - 1];

pc_system #(.RAM_KB(RAM_KB), .DRQ0_SKEW(DRQ0_SKEW), .MDA_FIT(MDA_FIT), .FE2010A(FE2010A)) u_pc (
    .clk        (clk),
    .reset      (reset),
    .ucl_we     (ucl_we),
    .ucl_addr   (ucl_addr),
    .ucl_data   (ucl_data),
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
    .mda_ce     (mda_ce),
    .mda_video  (mda_video),
    .mda_intens (mda_intens),
    .mda_hsync  (mda_hsync),
    .mda_vsync  (mda_vsync),
    .mda_hblank (mda_hblank),
    .mda_vblank (mda_vblank),
    .font_we    (font_we),
    .font_addr  (font_addr),
    .font_data  (font_data),
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
    .hdc_enable    (hdc_enable),
    .hdc_variant   (hdc_variant),
    .hdc_rom_addr  (xrom_addr),
    .hdc_rom_rdata (xrom_rdata),
    .hd_present    (hd_present),
    .hd_sectors    (hd_sectors),
    .hd_cyls       (hd_cyls),
    .hd_heads      (hd_heads),
    .hd_spt        (hd_spt),
    .hd_active     (),
    .hd_sp_req     (hd_sp_req),
    .hd_sp_write   (hd_sp_write),
    .hd_sp_drive   (hd_sp_drive),
    .hd_sp_lba     (hd_sp_lba),
    .hd_sp_rd_valid(hd_sp_rd_valid),
    .hd_sp_rd_data (hd_sp_rd_data),
    .hd_sp_wr_valid(hd_sp_wr_valid),
    .hd_sp_wr_data (hd_sp_wr_data),
    .hd_sp_wr_ready(hd_sp_wr_ready),
    .hd_sp_done    (hd_sp_done),
    .hd_sp_err     (hd_sp_err),
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
assign cs       = u_pc.u_cpu.dbg_cs;
assign ip       = u_pc.u_cpu.dbg_ip;
assign bus_t    = u_pc.cpu_bus_t;
assign bus_type = u_pc.cpu_bus_type;
assign bus_addr = u_pc.u_board.cpu_addr;  // the CPU's latched address (as MartyPC's trace)
assign bus_data = u_pc.cpu_bus_type == 3'd6 || u_pc.cpu_bus_type == 3'd2 ? u_pc.isa_dout : u_pc.cpu_din;
assign qs       = u_pc.cpu_qs;

// the EU's first clock of an instruction (not an interrupt): its opcode is q_top
assign it_disp = u_pc.u_cpu.cpu.dbg_ce && u_pc.u_cpu.cpu.eu.FC && !u_pc.u_cpu.cpu.eu.irq_take;
assign it_op   = u_pc.u_cpu.cpu.eu.q_top;
assign it_ip   = u_pc.u_cpu.cpu.eu.biu_ip;
assign it_ax   = u_pc.u_cpu.cpu.eu.AX;
assign it_bx   = u_pc.u_cpu.cpu.eu.BX;
assign it_cx   = u_pc.u_cpu.cpu.eu.CX;
assign it_dx   = u_pc.u_cpu.cpu.eu.DX;
assign it_sp   = u_pc.u_cpu.cpu.eu.SP;
assign it_bp   = u_pc.u_cpu.cpu.eu.BP;
assign it_si   = u_pc.u_cpu.cpu.eu.SI;
assign it_di   = u_pc.u_cpu.cpu.eu.DI;
assign it_ds   = u_pc.u_cpu.cpu.eu.DS;
assign it_es   = u_pc.u_cpu.cpu.eu.ES;
assign it_ss   = u_pc.u_cpu.cpu.eu.SS;
assign it_f    = u_pc.u_cpu.cpu.eu.F;

// +ztrace_from=<step> +ztrace_to=<step>: one line per EU clock (sys_run passes
// plusargs through), the step number as the -t trace's first column
longint unsigned zsteps = 0, zfrom = 0, zto = 0;
initial begin
    if ($value$plusargs("ztrace_from=%d", zfrom)) ;
    if ($value$plusargs("ztrace_to=%d", zto)) ;
end
always_ff @(posedge clk) if (u_pc.cpu_step && !reset) zsteps <= zsteps + 1;
always_ff @(posedge clk)
    if (zto != 0 && zsteps >= zfrom && zsteps < zto && u_pc.u_cpu.cpu.dbg_ce)
        $display("z %0d ls=%0d FC=%b SC=%b ROME=%b st=%b busy=%b row=%03h RNI=%b NXT=%b qe=%b qt=%02h IR=%02h ip=%04h t=%0d irq=%b int=%b F=%04h CX=%04h",
                 zsteps, u_pc.u_cpu.cpu.eu.loader_state, u_pc.u_cpu.cpu.eu.FC,
                 u_pc.u_cpu.cpu.eu.SC, u_pc.u_cpu.cpu.eu.ROME, u_pc.u_cpu.cpu.eu.stall,
                 u_pc.u_cpu.cpu.eu.bus_busy, u_pc.u_cpu.cpu.tables.uc_row,
                 u_pc.u_cpu.cpu.eu.RNI, u_pc.u_cpu.cpu.eu.NXT, u_pc.u_cpu.cpu.eu.q_empty,
                 u_pc.u_cpu.cpu.eu.q_top, u_pc.u_cpu.cpu.eu.IR, u_pc.u_cpu.cpu.eu.biu_ip,
                 u_pc.cpu_bus_t, u_pc.u_cpu.cpu.eu.irq_take, u_pc.u_cpu.cpu.eu.int_cond,
                 u_pc.u_cpu.cpu.eu.F, u_pc.u_cpu.cpu.eu.CX);

endmodule
