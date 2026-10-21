// cpu_ooc_top.v - MCL86 EU + biu88 with registered I/O, for an out-of-context
// Vivado run that measures the CPU alone at 100.2273 MHz (tools/ooc/cpu_ooc.tcl).
// The wiring follows tb/sst/tb_mcl86_biu88.v; the test-only preload port is
// tied off.
module cpu_ooc_top (
    input             clk,
    input             reset_i,
    input             step_i,
    input             ready_i,
    input             nmi_i,
    input             intr_i,
    input      [7:0]  ad_in_i,
    output reg [19:0] ad_out_o,
    output reg        ad_oe_o,
    output reg [2:0]  s2_s0_o,
    output reg        s6_3_mux_o,
    output reg        lock_n_o,
    output reg [1:0]  qs_o,
    output reg        ale_o
);

reg        reset, step, ready, nmi, intr;
reg  [7:0] ad_in;
always @(posedge clk) begin
    reset <= reset_i; step <= step_i; ready <= ready_i;
    nmi <= nmi_i; intr <= intr_i; ad_in <= ad_in_i;
end

wire [15:0] eu_biu_command, eu_biu_dataout, eu_register_r3;
wire        eu_prefix_lock, eu_flag_i;
wire        biu_done, biu_clk_counter_zero, biu_nmi_caught, biu_nmi_debounce, biu_intr;
wire [1:0]  biu_segment;
wire [7:0]  pfq_top_byte;
wire        pfq_empty;
wire [15:0] pfq_addr_out;
wire [15:0] biu_es, biu_ss, biu_cs, biu_ds, biu_rm, biu_reg, biu_return_data;
wire [11:0] biu_cyc, biu_since_read, biu_since_done;
wire        biu_sr_pending;
wire [1:0]  eu_qread;
wire [19:0] ad_out;
wire        ad_oe, s6_3_mux, lock_n, ale;
wire [2:0]  s2_s0;
wire [1:0]  qs;

mcl86_eu_core eu (
    .CORE_CLK_INT(clk), .RESET_INT(reset), .TEST_N_INT(1'b1), .EU_STEP(step),
    .EU_CYC(biu_cyc), .EU_SINCE_READ(biu_since_read), .EU_SINCE_DONE(biu_since_done),
    .EU_SR_PENDING(biu_sr_pending), .EU_QREAD(eu_qread),
    .EU_BIU_COMMAND(eu_biu_command), .EU_BIU_DATAOUT(eu_biu_dataout),
    .EU_REGISTER_R3(eu_register_r3), .EU_PREFIX_LOCK(eu_prefix_lock), .EU_FLAG_I(eu_flag_i),
    .BIU_DONE(biu_done), .BIU_CLK_COUNTER_ZERO(biu_clk_counter_zero),
    .BIU_NMI_CAUGHT(biu_nmi_caught), .BIU_NMI_DEBOUNCE(biu_nmi_debounce), .BIU_INTR(biu_intr),
    .PFQ_TOP_BYTE(pfq_top_byte), .PFQ_EMPTY(pfq_empty), .PFQ_ADDR_OUT(pfq_addr_out),
    .BIU_REGISTER_ES(biu_es), .BIU_REGISTER_SS(biu_ss), .BIU_REGISTER_CS(biu_cs),
    .BIU_REGISTER_DS(biu_ds), .BIU_REGISTER_RM(biu_rm), .BIU_REGISTER_REG(biu_reg),
    .BIU_RETURN_DATA(biu_return_data)
);

biu88 biu (
    .CORE_CLK_INT(clk), .step(step), .RESET_INT(reset), .READY_IN(ready),
    .NMI(nmi), .INTR(intr), .LOCK_n(lock_n), .AD_OE(ad_oe), .AD_OUT(ad_out),
    .AD_IN(ad_in), .S6_3_MUX(s6_3_mux), .S2_S0_OUT(s2_s0), .QS_OUT(qs), .QS_BYTE(),
    .ALE(ale), .eu_qread(eu_qread),
    .tb_preload(1'b0), .tb_queue(32'd0), .tb_queue_len(3'd0), .tb_ip(16'd0),
    .dbg_t_state(), .dbg_ta_state(), .dbg_queue_len(),
    .EU_BIU_COMMAND(eu_biu_command), .EU_BIU_DATAOUT(eu_biu_dataout),
    .EU_REGISTER_R3(eu_register_r3), .EU_PREFIX_LOCK(eu_prefix_lock),
    .BIU_DONE(biu_done), .BIU_CLK_COUNTER_ZERO(biu_clk_counter_zero),
    .BIU_SEGMENT(biu_segment), .BIU_NMI_CAUGHT(biu_nmi_caught),
    .BIU_NMI_DEBOUNCE(biu_nmi_debounce), .BIU_INTR(biu_intr),
    .PFQ_TOP_BYTE(pfq_top_byte), .PFQ_EMPTY(pfq_empty), .PFQ_ADDR_OUT(pfq_addr_out),
    .BIU_REGISTER_ES(biu_es), .BIU_REGISTER_SS(biu_ss), .BIU_REGISTER_CS(biu_cs),
    .BIU_REGISTER_DS(biu_ds), .BIU_REGISTER_RM(biu_rm), .BIU_REGISTER_REG(biu_reg),
    .BIU_RETURN_DATA(biu_return_data),
    .BIU_CYC(biu_cyc), .BIU_SINCE_READ(biu_since_read), .BIU_SINCE_DONE(biu_since_done),
    .BIU_SR_PENDING(biu_sr_pending)
);

always @(posedge clk) begin
    ad_out_o <= ad_out; ad_oe_o <= ad_oe; s2_s0_o <= s2_s0; s6_3_mux_o <= s6_3_mux;
    lock_n_o <= lock_n; qs_o <= qs; ale_o <= ale;
end

endmodule
