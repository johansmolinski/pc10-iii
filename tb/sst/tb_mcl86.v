// tb_mcl86.v - MCL86 (EU + maximum-mode BIU) for the SingleStepTests harness.
//
// The harness drives CORE_CLK at 100 MHz (the speed MCL86's cycle counter is
// tuned for) and CLK, the 8088 clock, from a phase accumulator (4.77 MHz, 1/3
// duty like an 8284). The dbg_* outputs reach into the core through
// hierarchical references, so the vendored MCL86 files stay unmodified.

module tb_mcl86 (
    input             core_clk,
    input             clk,
    input             reset,
    input      [7:0]  ad_in,

    output     [19:0] ad_out,
    output            ad_oe,
    output     [2:0]  s2_s0,
    output            s6_3_mux,
    output            lock_n,

    output     [15:0] dbg_ax, dbg_bx, dbg_cx, dbg_dx,
    output     [15:0] dbg_sp, dbg_bp, dbg_si, dbg_di,
    output     [15:0] dbg_flags,
    output     [15:0] dbg_cs, dbg_ss, dbg_ds, dbg_es,
    output     [15:0] dbg_ip,
    output     [15:0] dbg_eu_cmd,
    output     [7:0]  dbg_pfq_top,
    output            dbg_dispatch,
    output            dbg_pfq_empty
);

wire [15:0] eu_biu_command, eu_biu_dataout, eu_register_r3;
wire        eu_prefix_lock, eu_flag_i;
wire        biu_done, biu_clk_counter_zero, biu_nmi_caught, biu_nmi_debounce, biu_intr;
wire [1:0]  biu_segment;
wire [7:0]  pfq_top_byte;
wire        pfq_empty;
wire [15:0] pfq_addr_out;
wire [15:0] biu_es, biu_ss, biu_cs, biu_ds, biu_rm, biu_reg, biu_return_data;

mcl86_eu_core eu (
    .CORE_CLK_INT         (core_clk),
    .RESET_INT            (reset),
    .TEST_N_INT           (1'b1),
    .EU_STEP              (1'b0),
    .EU_CYC               (12'd0),
    .EU_SINCE_READ        (12'd0),
    .EU_BIU_COMMAND       (eu_biu_command),
    .EU_BIU_DATAOUT       (eu_biu_dataout),
    .EU_REGISTER_R3       (eu_register_r3),
    .EU_PREFIX_LOCK       (eu_prefix_lock),
    .EU_FLAG_I            (eu_flag_i),
    .BIU_DONE             (biu_done),
    .BIU_CLK_COUNTER_ZERO (biu_clk_counter_zero),
    .BIU_NMI_CAUGHT       (biu_nmi_caught),
    .BIU_NMI_DEBOUNCE     (biu_nmi_debounce),
    .BIU_INTR             (biu_intr),
    .PFQ_TOP_BYTE         (pfq_top_byte),
    .PFQ_EMPTY            (pfq_empty),
    .PFQ_ADDR_OUT         (pfq_addr_out),
    .BIU_REGISTER_ES      (biu_es),
    .BIU_REGISTER_SS      (biu_ss),
    .BIU_REGISTER_CS      (biu_cs),
    .BIU_REGISTER_DS      (biu_ds),
    .BIU_REGISTER_RM      (biu_rm),
    .BIU_REGISTER_REG     (biu_reg),
    .BIU_RETURN_DATA      (biu_return_data)
);

biu_max biu (
    .CORE_CLK_INT         (core_clk),
    .CLK                  (clk),
    .RESET_INT            (reset),
    .READY_IN             (1'b1),
    .NMI                  (1'b0),
    .INTR                 (1'b0),
    .LOCK_n               (lock_n),
    .AD_OE                (ad_oe),
    .AD_OUT               (ad_out),
    .AD_IN                (ad_in),
    .S6_3_MUX             (s6_3_mux),
    .S2_S0_OUT            (s2_s0),
    .EU_BIU_COMMAND       (eu_biu_command),
    .EU_BIU_DATAOUT       (eu_biu_dataout),
    .EU_REGISTER_R3       (eu_register_r3),
    .EU_PREFIX_LOCK       (eu_prefix_lock),
    .BIU_DONE             (biu_done),
    .BIU_CLK_COUNTER_ZERO (biu_clk_counter_zero),
    .BIU_SEGMENT          (biu_segment),
    .BIU_NMI_CAUGHT       (biu_nmi_caught),
    .BIU_NMI_DEBOUNCE     (biu_nmi_debounce),
    .BIU_INTR             (biu_intr),
    .PFQ_TOP_BYTE         (pfq_top_byte),
    .PFQ_EMPTY            (pfq_empty),
    .PFQ_ADDR_OUT         (pfq_addr_out),
    .BIU_REGISTER_ES      (biu_es),
    .BIU_REGISTER_SS      (biu_ss),
    .BIU_REGISTER_CS      (biu_cs),
    .BIU_REGISTER_DS      (biu_ds),
    .BIU_REGISTER_RM      (biu_rm),
    .BIU_REGISTER_REG     (biu_reg),
    .BIU_RETURN_DATA      (biu_return_data)
);

assign dbg_ax        = eu.eu_register_ax;
assign dbg_bx        = eu.eu_register_bx;
assign dbg_cx        = eu.eu_register_cx;
assign dbg_dx        = eu.eu_register_dx;
assign dbg_sp        = eu.eu_register_sp;
assign dbg_bp        = eu.eu_register_bp;
assign dbg_si        = eu.eu_register_si;
assign dbg_di        = eu.eu_register_di;
assign dbg_flags     = eu.eu_flags;
assign dbg_cs        = biu_cs;
assign dbg_ss        = biu_ss;
assign dbg_ds        = biu_ds;
assign dbg_es        = biu_es;
assign dbg_ip        = pfq_addr_out;
assign dbg_eu_cmd    = eu_biu_command;
assign dbg_pfq_top   = pfq_top_byte;
// the EU is in its opcode jump table (0x100-0x1FF): it has just dispatched on
// the byte at the top of the queue, which is when a real 8088 reports QS=F
assign dbg_dispatch  = eu.new_instruction;
assign dbg_pfq_empty = pfq_empty;

endmodule
