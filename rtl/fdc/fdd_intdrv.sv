// fdd_intdrv.sv - drive B: as an image or as the real drive (doc/fdc.md
// section 10): between the FDC card's drive inputs and sector port and the
// image backend (the MEGA65 glue's pc_fdd_sd.vhd).
//
//   enable = 0: everything passes through, the real drive's pins idle.
//   enable = 1: drive B: is fdd_phys.sv: its requests go there instead of to
//     the image backend; its medium is the drive's (present: index pulses,
//     wp: the WPT pin) with the geometry of a 720K disk in an 80-track drive
//     (80 cylinders, 2 heads, 9 sectors). Drive A: stays the image backend's.
//   A request is routed by the drive and enable of its first clk and stays
//   there until it is answered (a switch in between cannot strand it: the
//   drive answers sp_err when it is switched off).
//
// GPL-3.0-or-later, pc10-iii.

module fdd_intdrv #(
    parameter int CLK_HZ = 28_636_364
) (
    input  logic        clk,
    input  logic        reset,          // power-up
    input  logic        pc_reset,       // the PC's reset
    input  logic        enable,         // B: = the internal drive

    // the FDC card
    output logic [1:0]  drv_80trk,
    output logic [1:0]  img_present,
    output logic [1:0]  img_wp,
    output logic [15:0] img_tracks,     // {B, A}
    output logic [3:0]  img_heads,
    output logic [11:0] img_spt,
    input  logic [1:0]  drv_motor,
    input  logic [1:0]  drv_select,
    input  logic        drv_step,
    input  logic        drv_step_in,
    input  logic        fdc_active,
    input  logic        sp_req,
    input  logic        sp_write,
    input  logic        sp_fmt,
    input  logic        sp_drive,
    input  logic [7:0]  sp_cyl,
    input  logic        sp_head,
    input  logic [7:0]  sp_sector,
    output logic        sp_rd_valid,
    output logic [7:0]  sp_rd_data,
    input  logic        sp_wr_valid,
    output logic        sp_wr_ready,
    input  logic [7:0]  sp_wr_data,
    output logic        sp_done,
    output logic        sp_err,

    // the image backend
    input  logic [1:0]  i_drv_80trk,
    input  logic [1:0]  i_img_present,
    input  logic [1:0]  i_img_wp,
    input  logic [15:0] i_img_tracks,
    input  logic [3:0]  i_img_heads,
    input  logic [11:0] i_img_spt,
    output logic        i_sp_req,
    input  logic        i_sp_rd_valid,
    input  logic [7:0]  i_sp_rd_data,
    input  logic        i_sp_wr_ready,
    input  logic        i_sp_done,
    input  logic        i_sp_err,

    // the drive (34-pin, active low; f_stepdir_n = 1: outward)
    output logic        f_motor_n,
    output logic        f_select_n,
    output logic        f_stepdir_n,
    output logic        f_step_n,
    output logic        f_side1_n,
    output logic        f_wdata_n,
    output logic        f_wgate_n,
    input  logic        f_index_n,
    input  logic        f_track0_n,
    input  logic        f_wpt_n,
    input  logic        f_rdata_n,

    output logic        busy,           // the drive serves a request
    output logic [6:0]  cyl,            // the real head (testbench)
    output logic        known
);

// ------------------------------------------------------------ routing
logic req_d, route_q;
wire  route = req_d ? route_q : (sp_drive && enable);
always_ff @(posedge clk) begin
    req_d <= sp_req && !reset;
    if (sp_req && !req_d) route_q <= sp_drive && enable;
end

logic h_rd_valid, h_wr_ready, h_done, h_err, h_present, h_wp;
logic [7:0] h_rd_data;

assign i_sp_req    = sp_req && !route;
assign sp_rd_valid = route ? h_rd_valid : i_sp_rd_valid;
assign sp_rd_data  = route ? h_rd_data  : i_sp_rd_data;
assign sp_wr_ready = route ? h_wr_ready : i_sp_wr_ready;
assign sp_done     = route ? h_done     : i_sp_done;
assign sp_err      = route ? h_err      : i_sp_err;

// ------------------------------------------------------------ the medium of B:
assign drv_80trk   = {enable | i_drv_80trk[1], i_drv_80trk[0]};
assign img_present = {enable ? h_present : i_img_present[1], i_img_present[0]};
assign img_wp      = {enable ? h_wp : i_img_wp[1], i_img_wp[0]};
assign img_tracks  = {enable ? 8'd80 : i_img_tracks[15:8], i_img_tracks[7:0]};
assign img_heads   = {enable ? 2'd2 : i_img_heads[3:2], i_img_heads[1:0]};
assign img_spt     = {enable ? 6'd9 : i_img_spt[11:6], i_img_spt[5:0]};

fdd_phys #(
    .CLK_HZ (CLK_HZ)
) u_drive (
    .clk         (clk),
    .reset       (reset),
    .pc_reset    (pc_reset),
    .enable      (enable),
    .motor_b     (drv_motor[1]),
    .select_b    (drv_select[1]),
    .step        (drv_step),
    .step_in     (drv_step_in),
    .cmd_active  (fdc_active),
    .sp_req      (sp_req && route),
    .sp_write    (sp_write),
    .sp_fmt      (sp_fmt),
    .sp_cyl      (sp_cyl),
    .sp_head     (sp_head),
    .sp_sector   (sp_sector),
    .sp_rd_valid (h_rd_valid),
    .sp_rd_data  (h_rd_data),
    .sp_wr_valid (sp_wr_valid && route),
    .sp_wr_data  (sp_wr_data),
    .sp_wr_ready (h_wr_ready),
    .sp_done     (h_done),
    .sp_err      (h_err),
    .present     (h_present),
    .wp          (h_wp),
    .f_motor_n   (f_motor_n),
    .f_select_n  (f_select_n),
    .f_stepdir_n (f_stepdir_n),
    .f_step_n    (f_step_n),
    .f_side1_n   (f_side1_n),
    .f_wdata_n   (f_wdata_n),
    .f_wgate_n   (f_wgate_n),
    .f_index_n   (f_index_n),
    .f_track0_n  (f_track0_n),
    .f_wpt_n     (f_wpt_n),
    .f_rdata_n   (f_rdata_n),
    .cyl_o       (cyl),
    .known_o     (known),
    .busy_o      (busy)
);

endmodule
