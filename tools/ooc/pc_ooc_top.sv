// pc_ooc_top.sv - the PC side for an out-of-context Vivado run at 28.63636 MHz
// (tools/ooc/pc_ooc.tcl): pc_system with every card (CGA, Hercules, FDC, XTIDE, the PC20-III's
// hard disk) and the PVC4
// and the shell's system RAM (CORE/vhdl/pc_ram.vhd, latency 2), the BIOS ROM and
// the XTIDE option ROM as block RAMs read in 1 clk. The rest of pc_system's ports
// are the top's; out of context they are not timed, the paths inside are.
module pc_ooc_top (
    input  logic        clk,
    input  logic        reset,
    input  logic        fe2010a,
    input  logic        ucl_we,
    input  logic [12:0] ucl_addr,
    input  logic [7:0]  ucl_data,
    input  logic [1:0]  mem_size,
    input  logic        rom_we,
    input  logic [15:0] rom_waddr,
    input  logic [7:0]  rom_wdata,
    output logic        vid_ce,
    output logic [3:0]  vid_rgbi,
    output logic        vid_hsync, vid_vsync, vid_hblank, vid_vblank,
    output logic        mda_ce, mda_video, mda_intens, mda_hsync, mda_vsync, mda_hblank, mda_vblank,
    input  logic        font_we,
    input  logic [12:0] font_addr,
    input  logic [7:0]  font_data,
    input  logic        font_thin,
    input  logic [1:0]  font_addr_hi,
    input  logic        font_cbm,
    input  logic [1:0]  cbm_dip,
    output logic        vid_mono, vid_monomode,
    input  logic [1:0]  drv_80trk, img_present, img_wp,
    input  logic [1:0][7:0] img_tracks,
    input  logic [1:0][1:0] img_heads,
    input  logic [1:0][5:0] img_spt,
    output logic [1:0]  drv_motor,
    output logic        fdc_active,
    output logic [1:0]  drv_select,
    output logic        drv_step,
    output logic        drv_step_in,
    output logic        sp_req, sp_write, sp_drive,
    output logic [7:0]  sp_cyl,
    output logic        sp_head,
    output logic [7:0]  sp_sector,
    output logic [15:0] sp_lba,
    input  logic        sp_rd_valid,
    input  logic [7:0]  sp_rd_data,
    output logic        sp_wr_valid,
    output logic [7:0]  sp_wr_data,
    input  logic        sp_wr_ready, sp_done, sp_err,
    input  logic        hdc_enable,
    input  logic [1:0]  hdc_variant,
    input  logic [1:0]  hd_present,
    input  logic [1:0][27:0] hd_sectors,
    input  logic [1:0][15:0] hd_cyls,
    input  logic [1:0][4:0]  hd_heads,
    input  logic [1:0][5:0]  hd_spt,
    output logic        hd_active,
    output logic        hd_sp_req, hd_sp_write, hd_sp_drive,
    output logic [27:0] hd_sp_lba,
    input  logic        hd_sp_rd_valid,
    input  logic [7:0]  hd_sp_rd_data,
    output logic        hd_sp_wr_valid,
    output logic [7:0]  hd_sp_wr_data,
    input  logic        hd_sp_wr_ready, hd_sp_done, hd_sp_err,
    input  logic        xta_enable, xta_present,
    output logic        xta_active,
    output logic        xta_sp_req, xta_sp_write,
    output logic [27:0] xta_sp_lba,
    input  logic        xta_sp_rd_valid,
    input  logic [7:0]  xta_sp_rd_data,
    output logic        xta_sp_wr_valid,
    output logic [7:0]  xta_sp_wr_data,
    input  logic        xta_sp_wr_ready, xta_sp_done, xta_sp_err,
    input  logic [64:0] rtc_seed,
    output logic        rtc_set,
    output logic [63:0] rtc_time,
    output logic        ser_txd, ser_rts_n, ser_dtr_n,
    input  logic        ser_rxd, ser_cts_n, ser_dsr_n, ser_dcd_n, ser_ri_n,
    output logic [7:0]  lpt_data,
    output logic        lpt_strobe_n, lpt_autofd_n, lpt_init_n, lpt_selin_n,
    input  logic        lpt_busy, lpt_ack_n, lpt_pe, lpt_slct, lpt_err_n,
    input  logic        mouse_xp, mouse_xq, mouse_yp, mouse_yq,
    input  logic [2:0]  mouse_btn_n,
    input  logic [7:0]  kbd_code,
    input  logic        kbd_valid,
    output logic        kbd_busy,
    output logic        speaker,
    input  logic [7:0]  dip_sw1
);

logic [19:0] ram_addr;
logic        ram_en, ram_we, ram_ack;
logic [7:0]  ram_wdata, ram_rdata;
logic [15:0] rom_addr;
logic [7:0]  rom_rdata, xrom_rdata;
logic [13:0] xrom_addr;

(* ram_style = "block" *) logic [7:0] rom [65536];
(* ram_style = "block" *) logic [7:0] xrom [16384];
always_ff @(posedge clk) begin
    if (rom_we) rom[rom_waddr] <= rom_wdata;
    rom_rdata <= rom[rom_addr];
end
always_ff @(posedge clk) begin
    if (rom_we) xrom[rom_waddr[13:0]] <= rom_wdata;
    xrom_rdata <= xrom[xrom_addr];
end

pc_ram u_ram (
    .clk_i(clk), .size_i(mem_size), .ram_addr_i(ram_addr), .ram_en_i(ram_en), .ram_we_i(ram_we),
    .ram_wdata_i(ram_wdata), .ram_rdata_o(ram_rdata), .ram_ack_o(ram_ack)
);

pc_system #(.RAM_KB(640), .CGA_FIT(1'b1), .MDA_FIT(2), .PVC4_FIT(1'b1), .XTA_FIT(1'b1)) u_pc (
    .clk, .reset, .fe2010a, .ucl_we, .ucl_addr, .ucl_data,
    .ram_addr, .ram_en, .ram_we, .ram_wdata, .ram_rdata, .ram_ack,
    .rom_addr, .rom_rdata,
    .vid_ce, .vid_rgbi, .vid_hsync, .vid_vsync, .vid_hblank, .vid_vblank,
    .mda_ce, .mda_video, .mda_intens, .mda_hsync, .mda_vsync, .mda_hblank, .mda_vblank,
    .font_we, .font_addr, .font_data, .font_thin, .font_addr_hi, .font_cbm, .cbm_dip,
    .vid_mono, .vid_monomode,
    .drv_80trk, .img_present, .img_wp, .img_tracks, .img_heads, .img_spt,
    .drv_motor, .fdc_active, .drv_select, .drv_step, .drv_step_in,
    .sp_req, .sp_write, .sp_drive, .sp_cyl, .sp_head, .sp_sector, .sp_lba,
    .sp_rd_valid, .sp_rd_data, .sp_wr_valid, .sp_wr_data, .sp_wr_ready, .sp_done, .sp_err,
    .hdc_enable, .hdc_variant, .hdc_rom_addr(xrom_addr), .hdc_rom_rdata(xrom_rdata),
    .hd_present, .hd_sectors, .hd_cyls, .hd_heads, .hd_spt, .hd_active,
    .hd_sp_req, .hd_sp_write, .hd_sp_drive, .hd_sp_lba,
    .hd_sp_rd_valid, .hd_sp_rd_data, .hd_sp_wr_valid, .hd_sp_wr_data,
    .hd_sp_wr_ready, .hd_sp_done, .hd_sp_err,
    .xta_enable, .xta_present, .xta_active,
    .xta_sp_req, .xta_sp_write, .xta_sp_lba,
    .xta_sp_rd_valid, .xta_sp_rd_data, .xta_sp_wr_valid, .xta_sp_wr_data,
    .xta_sp_wr_ready, .xta_sp_done, .xta_sp_err,
    .rtc_seed, .rtc_set, .rtc_time,
    .ser_txd, .ser_rts_n, .ser_dtr_n, .ser_rxd, .ser_cts_n, .ser_dsr_n, .ser_dcd_n, .ser_ri_n,
    .lpt_data, .lpt_strobe_n, .lpt_autofd_n, .lpt_init_n, .lpt_selin_n,
    .lpt_busy, .lpt_ack_n, .lpt_pe, .lpt_slct, .lpt_err_n,
    .mouse_xp, .mouse_xq, .mouse_yp, .mouse_yq, .mouse_btn_n,
    .kbd_code, .kbd_valid, .kbd_busy, .speaker, .dip_sw1
);

endmodule
