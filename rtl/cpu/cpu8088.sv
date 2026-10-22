// cpu8088.sv - the 8088 behind its max-mode pins.
//
// CPU = "z86" (default): z8086's EU running Intel's 8088 microcode (loaded
// from the microcode bundle through ucl_*, doc/z8086.md) + biu88.
// CPU = "mcl86": MCL86's EU + biu88 (the old CPU; until biu88 has its native
// EU interface).
//
// Runs on clk (100.2273 MHz); `step` is the rising edge of the 8088 CLK (one
// clk wide, every 21 clk at 4.77 MHz). The pins follow the real chip:
// multiplexed AD bus, S2-S0, QS1-QS0, LOCK, READY, INTR, NMI, TEST. For the
// system board's bus controller the BIU's own T-state and latched bus status
// are exported too (bus_t, bus_type), so the 8288 function needs no
// status-pin timing reconstruction.
//
// GPL-3.0-or-later, pc10-iii. z8086 (Apache 2.0, nand2mario) in rtl/cpu/z8086,
// MCL86 EU (MIT, Ted Fried / MicroCore Labs) and biu88 (pc10-iii) in
// rtl/cpu/mcl86.

module cpu8088 #(
    parameter string CPU = "z86"
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        step,

    // microcode bundle (z86): the file, one byte per clk, while reset is high
    input  logic        ucl_we,
    input  logic [12:0] ucl_addr,
    input  logic [7:0]  ucl_data,

    input  logic        ready,
    input  logic        intr,
    input  logic        nmi,
    input  logic        test_n,

    output logic [19:0] ad_out,         // A19-A8 + AD7-AD0 as driven
    input  logic [7:0]  ad_in,          // data the bus returns (reads, INTA)
    output logic [2:0]  s2_s0,          // status pins (active in T1/T2)
    output logic [1:0]  qs,
    output logic        lock_n,
    output logic        ale,

    output logic [2:0]  bus_t,          // T-state: 0 Ti 1 T1 2 T2 3 T3 4 Tw 5 T4
    output logic [2:0]  bus_type,       // the running cycle's status (7 = none)

    // debug
    output logic [15:0] dbg_cs,
    output logic [15:0] dbg_ip
);

generate if (CPU == "mcl86") begin : g_mcl86

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

mcl86_eu_core eu (
    .CORE_CLK_INT         (clk),
    .RESET_INT            (reset),
    .TEST_N_INT           (test_n),
    .EU_STEP              (step),
    .EU_CYC               (biu_cyc),
    .EU_SINCE_READ        (biu_since_read),
    .EU_SINCE_DONE        (biu_since_done),
    .EU_SR_PENDING        (biu_sr_pending),
    .EU_QREAD             (eu_qread),
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

biu88 biu (
    .CORE_CLK_INT         (clk),
    .RESET_INT            (reset),
    .step                 (step),
    .READY_IN             (ready),
    .NMI                  (nmi),
    .INTR                 (intr),
    .LOCK_n               (lock_n),
    .AD_OE                (),
    .AD_OUT               (ad_out),
    .AD_IN                (ad_in),
    .S2_S0_OUT            (s2_s0),
    .S6_3_MUX             (),
    .QS_OUT               (qs),
    .QS_BYTE              (),
    .ALE                  (ale),
    .EU_BIU_COMMAND       (eu_biu_command),
    .EU_BIU_DATAOUT       (eu_biu_dataout),
    .EU_REGISTER_R3       (eu_register_r3),
    .EU_PREFIX_LOCK       (eu_prefix_lock),
    .eu_qread             (eu_qread),
    .INTA_VEC_LO          (1'b1),
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
    .BIU_RETURN_DATA      (biu_return_data),
    .BIU_CYC              (biu_cyc),
    .BIU_SINCE_READ       (biu_since_read),
    .BIU_SINCE_DONE       (biu_since_done),
    .BIU_SR_PENDING       (biu_sr_pending),
    .tb_preload           (1'b0),
    .tb_queue             (32'h0),
    .tb_queue_len         (3'd0),
    .tb_ip                (16'h0),
    .dbg_t_state          (bus_t),
    .dbg_ta_state         (),
    .dbg_latch            (bus_type),
    .dbg_queue_len        ()
);

assign dbg_cs       = biu_cs;
assign dbg_ip       = pfq_addr_out;

end else begin : g_z86

cpu_z86 cpu (
    .clk          (clk),
    .reset        (reset),
    .step         (step),
    .ucl_we       (ucl_we),
    .ucl_addr     (ucl_addr),
    .ucl_data     (ucl_data),
    .READY_IN     (ready),
    .NMI          (nmi),
    .INTR         (intr),
    .TEST_n       (test_n),
    .LOCK_n       (lock_n),
    .AD_OUT       (ad_out),
    .AD_IN        (ad_in),
    .S2_S0_OUT    (s2_s0),
    .S6_3_MUX     (),
    .QS_OUT       (qs),
    .QS_BYTE      (),
    .ALE          (ale),
    .tb_preload   (1'b0),
    .tb_queue     (32'h0),
    .tb_queue_len (3'd0),
    .tb_ip        (16'h0),
    .dbg_cmd      (),
    .dbg_ce       (),
    .dbg_t_state  (bus_t),
    .dbg_ta_state (),
    .dbg_latch    (bus_type),
    .dbg_queue_len(),
    .dbg_cs       (dbg_cs),
    .dbg_ip       (dbg_ip)
);

end endgenerate

endmodule
