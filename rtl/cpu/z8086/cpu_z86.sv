// cpu_z86.sv - the 8088: z8086's EU (Intel's microcode, one microinstruction
// per 8088 clock) and biu88, the cycle-stepped 8088 BIU, with the real chip's
// EU/BIU split (doc/z8086.md).
//
// Clocking: everything runs on `clk`. biu88 steps at `step` (one clk per 8088
// clock, at the CLK rising edge): it takes the EU's events of the last 8088
// clock and runs this clock's cycle. The EU's clock enable is `step` delayed
// by EU_DELAY clk, so that the EU sees the BIU after the step (the queue after
// a T4 push, a transfer done); the EU's outputs are registers it sets there,
// which biu88 takes at the next step. Nothing else happens per clk: both
// change state once per 8088 clock (rtl/cpu/cpu8088.xdc). INTR, NMI and TEST
// are sampled at the 8088 clock edge.
//
// The microcode tables (z86_tables.sv) are loaded through ucl_* (the bundle
// file, one byte per clk) while the CPU is held in reset.

module cpu_z86 #(
    parameter int EU_DELAY = 3,
    parameter bit OVERLAY  = 1'b1
) (
    input             clk,
    input             reset,
    input             step,

    // microcode bundle load port (tools/mkucode.py)
    input             ucl_we,
    input      [12:0] ucl_addr,
    input      [7:0]  ucl_data,

    // 8088 pins (maximum mode)
    input             READY_IN,
    input             NMI,
    input             INTR,
    input             TEST_n,
    output            LOCK_n,
    output     [19:0] AD_OUT,
    input      [7:0]  AD_IN,
    output     [2:0]  S2_S0_OUT,
    output            S6_3_MUX,
    output     [1:0]  QS_OUT,
    output     [7:0]  QS_BYTE,
    output            ALE,

    // test only (SingleStepTests): install a prefetched queue
    input             tb_preload,
    input      [31:0] tb_queue,
    input      [2:0]  tb_queue_len,
    input      [15:0] tb_ip,

    output            dbg_ce,
    output     [2:0]  dbg_t_state,
    output     [2:0]  dbg_ta_state,
    output     [2:0]  dbg_latch,
    output     [2:0]  dbg_queue_len,
    output     [15:0] dbg_cs,
    output     [15:0] dbg_ip
);

// ------------------------------------------------------------------ EU clock enable
reg [EU_DELAY-1:0] ce_sr = '0;
always @(posedge clk) ce_sr <= {ce_sr[EU_DELAY-2:0], step};
wire ce_step = ce_sr[EU_DELAY-1];
// in reset the EU is clocked every clk, so that its reset takes at any length
wire ce = ce_step | reset;
assign dbg_ce = ce_step;

// pins sampled at the 8088 clock edge
reg intr_q, nmi_q, test_q;
always @(posedge clk) if (step) begin
    intr_q <= INTR;
    nmi_q  <= NMI;
    test_q <= TEST_n;
end

// ------------------------------------------------------------------ tables
wire [12:0] ua;
wire [20:0] uc_word;
wire [8:0]  uc_row;
wire [7:0]  tr_idx;
wire [12:0] tr_out;
wire [8:0]  grp_idx;
wire [14:0] grp_out;
wire        genuine_8088;

z86_tables #(.OVERLAY(OVERLAY)) tables (
    .clk          (clk),
    .ucl_we       (ucl_we),
    .ucl_addr     (ucl_addr),
    .ucl_data     (ucl_data),
    .ua           (ua),
    .uc_word      (uc_word),
    .uc_row       (uc_row),
    .genuine_8088 (genuine_8088),
    .tr_idx       (tr_idx),
    .tr_out       (tr_out),
    .grp_idx      (grp_idx),
    .grp_out      (grp_out)
);

// ------------------------------------------------------------------ EU
wire        q_rd, q_rd_first, req, req_wr, req_io, req_word, req_inta, req_seg0;
wire [1:0]  req_seg;
wire [15:0] req_addr, req_data;
wire        flush, susp, halt_req, halted, eu_lock, rni_pend;
wire [15:0] flush_ip, seg_cs, seg_ds, seg_es, seg_ss;
wire        bus_done, bus_done_imm;
wire [15:0] bus_rdata, q_ip;
wire [7:0]  q_top;
wire        q_empty;

z86_eu eu (
    .clk          (clk),
    .ce           (ce),
    .biu_t        (dbg_t_state),
    .reset_n      (~reset),
    .intr         (intr_q),
    .nmi          (nmi_q),
    .test_n       (test_q),
    .ua           (ua),
    .uc_word      (uc_word),
    .tr_idx       (tr_idx),
    .tr_out       (tr_out),
    .grp_idx      (grp_idx),
    .grp_out      (grp_out),
    .q_top        (q_top),
    .q_none       (q_empty),
    .biu_ip       (q_ip),
    .q_rd         (q_rd),
    .q_rd_first   (q_rd_first),
    .req          (req),
    .req_wr       (req_wr),
    .req_io       (req_io),
    .req_word     (req_word),
    .req_inta     (req_inta),
    .req_seg0     (req_seg0),
    .req_seg      (req_seg),
    .req_addr     (req_addr),
    .req_data     (req_data),
    .flush        (flush),
    .flush_ip     (flush_ip),
    .susp         (susp),
    .seg_cs       (seg_cs),
    .seg_ds       (seg_ds),
    .seg_es       (seg_es),
    .seg_ss       (seg_ss),
    .halt_req     (halt_req),
    .halted       (halted),
    .lock         (eu_lock),
    .rni_pend     (rni_pend),
    .bus_done     (bus_done),
    .bus_done_imm (bus_done_imm),
    .bus_rdata    (bus_rdata),
    .dbg_fc       ()
);

// ------------------------------------------------------------------ BIU
biu88 biu (
    .clk          (clk),
    .reset        (reset),
    .step         (step),
    .READY_IN     (READY_IN),
    .AD_IN        (AD_IN),
    .AD_OUT       (AD_OUT),
    .S2_S0_OUT    (S2_S0_OUT),
    .S6_3_MUX     (S6_3_MUX),
    .QS_OUT       (QS_OUT),
    .QS_BYTE      (QS_BYTE),
    .ALE          (ALE),
    .LOCK_n       (LOCK_n),
    .eu_qrd       (q_rd),
    .eu_qrd_first (q_rd_first),
    .eu_req       (req),
    .eu_wr        (req_wr),
    .eu_io        (req_io),
    .eu_word      (req_word),
    .eu_inta      (req_inta),
    .eu_seg0      (req_seg0),
    .eu_seg       (req_seg),
    .eu_addr      (req_addr),
    .eu_data      (req_data),
    .eu_flush     (flush),
    .eu_flush_ip  (flush_ip),
    .eu_susp      (susp),
    .eu_halt      (halt_req),
    .eu_lock      (eu_lock),
    .reg_cs       (seg_cs),
    .reg_ds       (seg_ds),
    .reg_es       (seg_es),
    .reg_ss       (seg_ss),
    // the 8088's INTA "word" is {2nd cycle, 1st cycle}: the genuine 8088
    // microcode takes the vector from the high byte; the overlay for an 8086
    // ROM expects it in the low byte, where the 8086's own second INTA access
    // puts it (doc/z8086.md section 5)
    .inta_vec_lo  (OVERLAY && !genuine_8088),
    .q_top        (q_top),
    .q_empty      (q_empty),
    .q_ip         (q_ip),
    .t_state      (dbg_t_state),
    .bus_type     (dbg_latch),
    .done         (bus_done),
    .done_imm     (bus_done_imm),
    .rdata        (bus_rdata),
    .tb_preload   (tb_preload),
    .tb_queue     (tb_queue),
    .tb_queue_len (tb_queue_len),
    .tb_ip        (tb_ip),
    .dbg_ta_state (dbg_ta_state),
    .dbg_queue_len(dbg_queue_len),
    .dbg_pc       ()
);

assign dbg_cs = seg_cs;
assign dbg_ip = q_ip;

endmodule
