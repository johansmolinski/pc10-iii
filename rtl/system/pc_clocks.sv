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
// Turbo (doc/turbo.md): the FE2010A divides the same master clock by 4
// (7.16 MHz) and by 3 (9.54 MHz). `speed` selects the divider (0 /6, 1 /4,
// 2 /3; xt_board.sv, FE2010A port 63h bits 7-6); `spd` is the divider that runs.
//   speed 0  4.77 MHz  /6  CLK high 2 clk (1/3, the 8284's)  cpu_fall step + 2
//   speed 1  7.16 MHz  /4  CLK high 2 clk (50% [A])          cpu_fall step + 2
//   speed 2  9.54 MHz  /3  CLK high 1.5 clk (50%)            cpu_fall step + 1
// rdy_ce and cpu_prestep are the clk before cpu_step at every speed. At
// 9.54 MHz the falling edge is 1.5 clk after the rising one, off the clk grid;
// cpu_fall is the clk after the step (the board needs it only as an ordering
// point between the step and rdy_ce/cpu_prestep, which must stay apart).
// The CPU clock has its own counter (c6) next to the modulo-24 one; 24 is a
// multiple of 6, 4 and 3, and a new speed takes effect only where the
// modulo-24 counter is 0 or 12, where every one of the three periods starts:
// no CPU clock is shortened or stretched, and c6 = cnt mod the period at every
// speed, so ce_14m and PCLK keep their phase to the CPU clock. At speed 0 the
// enables are those of the plain /6 counter.
//   ce_477   a fixed 4.77273 MHz enable (cnt mod 6 = 0): cpu_step at speed 0;
//            real-time logic that counted CPU clocks at 4.77 MHz (the
//            keyboard's delays) counts it instead
//
// GPL-3.0-or-later, pc10-iii.

module pc_clocks #(
    parameter int PHASE = 0             // OSC ticks (0..11) of the counter after reset
) (
    input  logic clk,
    input  logic reset,
    input  logic [1:0] speed,           // 0 4.77, 1 7.16, 2 9.54 MHz (3: as 2)
    output logic [1:0] spd,             // the speed the CPU clock runs at (0..2)
    output logic ce_14m,
    output logic cpu_step,
    output logic cpu_fall,
    output logic rdy_ce,
    output logic cpu_prestep,
    output logic ce_477,
    output logic ce_pclk,
    output logic pit_clk
);

// clk per 8088 clock, and the clk of the falling CLK edge after cpu_step
function automatic logic [2:0] per(input logic [1:0] s);
    return s == 2'd0 ? 3'd6 : s == 2'd1 ? 3'd4 : 3'd3;
endfunction
function automatic logic [2:0] fall(input logic [1:0] s);
    return s[1] ? 3'd1 : 3'd2;          // 4.77: 1/3 duty, 7.16: 50%, 9.54: 50% (1.5 -> 1)
endfunction

logic [4:0] cnt, cnt_n;                 // 0..23
logic [2:0] c6, c6_n;                   // the 8088 clock: 0..per(spd)-1
logic [1:0] spd_n;

always_comb begin
    if (reset) cnt_n = 5'(2 * PHASE);
    else       cnt_n = cnt == 5'd23 ? 5'd0 : cnt + 5'd1;
end
wire        bound = cnt_n == 5'd0 || cnt_n == 5'd12;   // every period starts here

always_comb begin
    if (reset) begin
        c6_n  = 3'((2 * PHASE) % 6);
        spd_n = 2'd0;
    end else begin
        spd_n = bound ? (speed == 2'd3 ? 2'd2 : speed) : spd;
        // (at a boundary every period ends, so c6 wraps there by itself)
        c6_n  = c6 == per(spd) - 3'd1 ? 3'd0 : c6 + 3'd1;
    end
end

// the enables are registers, decoded from the counters' next values (they fan
// out to the whole PC)
always_ff @(posedge clk) begin
    cnt         <= cnt_n;
    c6          <= c6_n;
    spd         <= spd_n;
    ce_14m      <= !cnt_n[0];
    cpu_step    <= c6_n == 3'd0;
    cpu_fall    <= c6_n == fall(spd_n);
    rdy_ce      <= c6_n == per(spd_n) - 3'd1;
    cpu_prestep <= c6_n == per(spd_n) - 3'd1;
    ce_477      <= cnt_n == 5'd0 || cnt_n == 5'd6 || cnt_n == 5'd12 || cnt_n == 5'd18;
    ce_pclk     <= cnt_n == 5'd0;
    pit_clk     <= cnt_n < 5'd12;
end

`ifndef SYNTHESIS
// c6 = cnt mod the period (the phase relation above); at speed 0 = cnt mod 6
always_ff @(posedge clk)
    if (!reset && 5'(c6) != cnt % 5'(per(spd)))
        $fatal(1, "pc_clocks: the CPU clock lost its phase to the modulo-24 counter");
`endif

endmodule
