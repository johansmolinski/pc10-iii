// cpu8088.sv - the 8088 behind its max-mode pins.
//
// z8086's EU running Intel's 8088 microcode (loaded from the microcode bundle
// through ucl_*, doc/z8086.md) + biu88 (rtl/cpu/biu88.sv), one step per 8088
// clock each.
//
// Runs on clk (28.63636 MHz); `step` is the rising edge of the 8088 CLK (one
// clk wide, every 6 clk at 4.77 MHz). The pins follow the real chip:
// multiplexed AD bus, S2-S0, QS1-QS0, LOCK, READY, INTR, NMI, TEST. For the
// system board's bus controller the BIU's own T-state and latched bus status
// are exported too (bus_t, bus_type), so the 8288 function needs no
// status-pin timing reconstruction.
//
// GPL-3.0-or-later, pc10-iii. z8086 (Apache 2.0, nand2mario) in rtl/cpu/z8086,
// biu88 (pc10-iii) in rtl/cpu.

module cpu8088 (
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
    .dbg_ce       (),
    .dbg_t_state  (bus_t),
    .dbg_ta_state (),
    .dbg_latch    (bus_type),
    .dbg_queue_len(),
    .dbg_cs       (dbg_cs),
    .dbg_ip       (dbg_ip)
);


endmodule
