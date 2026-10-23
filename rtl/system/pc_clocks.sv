// pc_clocks.sv - the clock enables of the PC (doc/architecture.md section 1).
//
// The PC runs on clk = 28.63636 MHz = 2 x OSC, the PC10-III's master clock
// (its FE2010A takes a 28.63636 MHz crystal; doc/clock-plan.md). One
// modulo-24 counter (OSC / 12) gives the 8284 outputs and the 5160's PCLK
// divider with a fixed phase relation:
//   ce_14m      OSC   14.31818 MHz, every 2 clk
//   cpu_step    CLK88  4.77273 MHz, every 6 clk (the rising CLK edge)
//   cpu_fall           2 clk after cpu_step (CLK has the 8284's 1/3 duty
//                      cycle: high for 2 clk, low for 4)
//   rdy_ce             1 clk before cpu_step: the 8284's RDY sample for the
//                      rising CLK edge (xt_board.sv, READY)
//   cpu_prestep        the clk before cpu_step: the 8237 ends its strobes
//                      there (KF8237); at 4.77 MHz the same clk as rdy_ce
//   ce_pclk   PCLK/2   1.19318 MHz, every 24 clk (the 8253 count clock)
//   pit_clk            the same as a square wave, for the 8253 counters
//
// Each enable is high for one clk; what it enables happens at the clock edge
// that ends that clk. ce_14m, cpu_step and cpu_fall are in even clk (the edge
// that ends them is an OSC rising edge); rdy_ce and cpu_prestep in odd ones,
// where the cards' dot clocks tick too (cga_card.sv CE_DELAY), half an OSC
// period later.
//
// Turbo (not yet): the FE2010A divides the same master clock by 4 (7.16 MHz)
// and by 3 (9.54 MHz, 50% duty). The CPU clock has its own counter (c6, period
// CPU_DIV, CLK high for CPU_HIGH clk) next to the modulo-24 one: another speed
// changes c6's period and the positions of cpu_fall/rdy_ce/cpu_prestep in it.
// 24 is a multiple of 6, 4 and 3, so ce_14m and PCLK keep their phase to the
// CPU clock at every speed. A speed switch must happen where both periods
// start (a multiple of 12 clk), so that no CPU clock is shortened.
//
// GPL-3.0-or-later, pc10-iii.

module pc_clocks #(
    parameter int PHASE = 0             // OSC ticks (0..11) of the counter after reset
) (
    input  logic clk,
    input  logic reset,
    output logic ce_14m,
    output logic cpu_step,
    output logic cpu_fall,
    output logic rdy_ce,
    output logic cpu_prestep,
    output logic ce_pclk,
    output logic pit_clk
);

localparam int CPU_DIV  = 6;            // clk per 8088 clock (4.77 MHz)
localparam int CPU_HIGH = 2;            // clk of CLK high (the 8284's 1/3 duty)

logic [4:0] cnt, cnt_n;                 // 0..23
logic [2:0] c6, c6_n;                   // the 8088 clock: 0..CPU_DIV-1

always_comb begin
    if (reset) begin
        cnt_n = 5'(2 * PHASE);
        c6_n  = 3'((2 * PHASE) % CPU_DIV);
    end else begin
        cnt_n = cnt == 5'd23 ? 5'd0 : cnt + 5'd1;
        c6_n  = c6 == 3'(CPU_DIV - 1) ? 3'd0 : c6 + 3'd1;
    end
end

// the enables are registers, decoded from the counters' next values (they fan
// out to the whole PC)
always_ff @(posedge clk) begin
    cnt         <= cnt_n;
    c6          <= c6_n;
    ce_14m      <= !cnt_n[0];
    cpu_step    <= c6_n == 3'd0;
    cpu_fall    <= c6_n == 3'(CPU_HIGH);
    rdy_ce      <= c6_n == 3'(CPU_DIV - 1);
    cpu_prestep <= c6_n == 3'(CPU_DIV - 1);
    ce_pclk     <= cnt_n == 5'd0;
    pit_clk     <= cnt_n < 5'd12;
end

endmodule
