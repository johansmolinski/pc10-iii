// pc_system_flat.sv - pc_system (doc/architecture.md section 4) with the per-drive packed
// arrays flattened, so that main.vhd can instantiate it as a VHDL component (Vivado's
// mixed-language boundary takes plain vectors).
//   img_tracks {B[7:0], A[7:0]}, img_heads {B[1:0], A[1:0]}, img_spt {B[5:0], A[5:0]}

module pc_system_flat #(
    parameter int RAM_KB = 640
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        fe2010a,        // the chipset: 1 = PC10-III (FE2010A), 0 = IBM 5160 (8255)

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
    input  logic [1:0]  font_addr_hi,       // PVC4: a 32 KB Commodore character ROM (bits 14-13)
    input  logic        font_cbm,           // PVC4: 1 = the font image is the Commodore layout
    input  logic [1:0]  cbm_dip,            // PVC4: CONFIG switches 1 and 2 (1 = off)
    output logic        vid_mono,           // PVC4: MONO
    output logic        vid_monomode,       // PVC4: the mono personality (16.257 MHz dots)

    input  logic        ucl_we,
    input  logic [12:0] ucl_addr,
    input  logic [7:0]  ucl_data,

    input  logic [1:0]  drv_80trk,
    input  logic [1:0]  img_present,
    input  logic [1:0]  img_wp,
    input  logic [15:0] img_tracks,
    input  logic [3:0]  img_heads,
    input  logic [11:0] img_spt,
    output logic [1:0]  drv_motor,
    output logic        fdc_active,
    output logic [1:0]  drv_select,
    output logic        drv_step,
    output logic        drv_step_in,
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

    // the PC20-III's hard disk (rtl/hdc/xta_card.sv, doc/xta.md): JMP208, the medium, the LED
    // and the sector port (hd_sp_* protocol, xta_sp_lba < 41820)
    input  logic        xta_enable,
    input  logic        xta_present,
    output logic        xta_active,
    output logic        xta_sp_req,
    output logic        xta_sp_write,
    output logic [27:0] xta_sp_lba,
    input  logic        xta_sp_rd_valid,
    input  logic [7:0]  xta_sp_rd_data,
    output logic        xta_sp_wr_valid,
    output logic [7:0]  xta_sp_wr_data,
    input  logic        xta_sp_wr_ready,
    input  logic        xta_sp_done,
    input  logic        xta_sp_err,
    // the real-time clock (doc/rtc.md): seed from main_rtc_i, write-back
    input  logic [64:0] rtc_seed,
    output logic        rtc_set,
    output logic [63:0] rtc_time,

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

// the PC10-III: its onboard video, the Paradise PVC4 (doc/pvc4.md), instead of
// the IBM CGA; no expansion video card. The chipset is the menu's (fe2010a). The
// PC20-III's hard disk on CN202 (XTA_FIT): JMP208 = xta_enable (the shell: an image
// is mounted).
pc_system #(.RAM_KB(RAM_KB), .PVC4_FIT(1'b1), .CGA_FIT(1'b0), .XTA_FIT(1'b1)) u_pc (
    .clk, .reset, .fe2010a,
    .ram_addr, .ram_en, .ram_we, .ram_wdata, .ram_rdata, .ram_ack,
    .rom_addr, .rom_rdata,
    .vid_ce, .vid_rgbi, .vid_hsync, .vid_vsync, .vid_hblank, .vid_vblank,
    .font_we, .font_addr, .font_data, .font_thin, .font_addr_hi, .font_cbm, .cbm_dip,
    .vid_mono, .vid_monomode,
    .ucl_we, .ucl_addr, .ucl_data,
    .drv_80trk, .img_present, .img_wp,
    .img_tracks(tracks), .img_heads(heads), .img_spt(spt),
    .drv_motor, .fdc_active, .drv_select, .drv_step, .drv_step_in,
    .sp_req, .sp_write, .sp_drive, .sp_cyl, .sp_head, .sp_sector, .sp_lba,
    .sp_rd_valid, .sp_rd_data, .sp_wr_valid, .sp_wr_data, .sp_wr_ready, .sp_done, .sp_err,
    // the hard disk card is not wired into the shell yet (doc/hdc.md section 8):
    // card disabled, no drives, the option ROM socket empty
    .hdc_enable(1'b0), .hdc_variant(2'd0), .hdc_rom_addr(), .hdc_rom_rdata(8'hFF),
    .hd_present(2'b00), .hd_sectors('0), .hd_cyls('0), .hd_heads('0), .hd_spt('0), .hd_active(),
    .hd_sp_req(), .hd_sp_write(), .hd_sp_drive(), .hd_sp_lba(),
    .hd_sp_rd_valid(1'b0), .hd_sp_rd_data(8'h00), .hd_sp_wr_valid(), .hd_sp_wr_data(),
    .hd_sp_wr_ready(1'b0), .hd_sp_done(1'b0), .hd_sp_err(1'b0),
    .xta_enable, .xta_present, .xta_active,
    .xta_sp_req, .xta_sp_write, .xta_sp_lba,
    .xta_sp_rd_valid, .xta_sp_rd_data, .xta_sp_wr_valid, .xta_sp_wr_data,
    .xta_sp_wr_ready, .xta_sp_done, .xta_sp_err,
    .rtc_seed, .rtc_set, .rtc_time,
    .kbd_code, .kbd_valid, .kbd_busy,
    .speaker,
    .dip_sw1
);

endmodule
