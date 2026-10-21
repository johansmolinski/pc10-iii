// pc_clocks.sv - the clock enables of the PC (doc/architecture.md section 1).
//
// One modulo-84 counter on clk = 100.2273 MHz = 7 x 14.31818 MHz gives the
// 8284 outputs and the 5160's PCLK divider with a fixed phase relation:
//   ce_14m    OSC   14.31818 MHz, every 7 clk
//   cpu_step  CLK88  4.77273 MHz, every 21 clk (the rising CLK edge)
//   cpu_fall         7 clk after cpu_step (CLK has a 1/3 duty cycle)
//   ce_pclk   PCLK/2 1.19318 MHz, every 84 clk (the 8253 count clock)
//   pit_clk          the same as a square wave, for the 8253 counters
//
// GPL-3.0-or-later, pc10-iii.

module pc_clocks #(
    parameter int PHASE = 0             // counter value after reset
) (
    input  logic clk,
    input  logic reset,
    output logic ce_14m,
    output logic cpu_step,
    output logic cpu_fall,
    output logic ce_pclk,
    output logic pit_clk
);

logic [6:0] cnt;
logic [4:0] c21;                        // cnt mod 21
logic [2:0] c7;                         // cnt mod 7

always_ff @(posedge clk) begin
    if (reset) begin
        cnt <= 7'(PHASE);
        c21 <= 5'(PHASE % 21);
        c7  <= 3'(PHASE % 7);
    end else begin
        cnt <= cnt == 7'd83 ? 7'd0 : cnt + 7'd1;
        c21 <= c21 == 5'd20 ? 5'd0 : c21 + 5'd1;
        c7  <= c7  == 3'd6  ? 3'd0 : c7  + 3'd1;
    end
end

assign ce_14m   = c7  == 3'd0;
assign cpu_step = c21 == 5'd0;
assign cpu_fall = c21 == 5'd7;
assign ce_pclk  = cnt == 7'd0;
assign pit_clk  = cnt < 7'd42;

endmodule
