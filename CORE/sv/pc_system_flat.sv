// pc_system_flat.sv - pc_system (doc/architecture.md section 4) with the per-drive packed
// arrays flattened, so that main.vhd can instantiate it as a VHDL component (Vivado's
// mixed-language boundary takes plain vectors).
//   img_tracks {B[7:0], A[7:0]}, img_heads {B[1:0], A[1:0]}, img_spt {B[5:0], A[5:0]}

module pc_system_flat #(
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

    input  logic        font_we,
    input  logic [12:0] font_addr,
    input  logic [7:0]  font_data,
    input  logic        font_thin,

    input  logic [1:0]  drv_80trk,
    input  logic [1:0]  img_present,
    input  logic [1:0]  img_wp,
    input  logic [15:0] img_tracks,
    input  logic [3:0]  img_heads,
    input  logic [11:0] img_spt,
    output logic [1:0]  drv_motor,
    output logic        fdc_active,
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

logic [1:0][7:0] tracks;
logic [1:0][1:0] heads;
logic [1:0][5:0] spt;
assign tracks = img_tracks;
assign heads  = img_heads;
assign spt    = img_spt;

pc_system #(.RAM_KB(RAM_KB)) u_pc (
    .clk, .reset,
    .ram_addr, .ram_en, .ram_we, .ram_wdata, .ram_rdata, .ram_ack,
    .rom_addr, .rom_rdata,
    .vid_ce, .vid_rgbi, .vid_hsync, .vid_vsync, .vid_hblank, .vid_vblank,
    .font_we, .font_addr, .font_data, .font_thin,
    .drv_80trk, .img_present, .img_wp,
    .img_tracks(tracks), .img_heads(heads), .img_spt(spt),
    .drv_motor, .fdc_active,
    .sp_req, .sp_write, .sp_drive, .sp_cyl, .sp_head, .sp_sector, .sp_lba,
    .sp_rd_valid, .sp_rd_data, .sp_wr_valid, .sp_wr_data, .sp_wr_ready, .sp_done, .sp_err,
    .kbd_code, .kbd_valid, .kbd_busy,
    .speaker,
    .dip_sw1
);

endmodule
