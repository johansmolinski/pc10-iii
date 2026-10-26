// tb_clk.sv - the clock enables (rtl/system/pc_clocks.sv) next to the /6-only
// pc_clocks of 2026-10-23 (before the turbo), which serves as the reference
// for speed 0: at 4.77 MHz every enable must be the same in every clk.
//
// GPL-3.0-or-later, pc10-iii.

module pc_clocks_ref #(
    parameter int PHASE = 0
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
localparam int CPU_DIV  = 6;
localparam int CPU_HIGH = 2;
logic [4:0] cnt, cnt_n;
logic [2:0] c6, c6_n;
always_comb begin
    if (reset) begin
        cnt_n = 5'(2 * PHASE);
        c6_n  = 3'((2 * PHASE) % CPU_DIV);
    end else begin
        cnt_n = cnt == 5'd23 ? 5'd0 : cnt + 5'd1;
        c6_n  = c6 == 3'(CPU_DIV - 1) ? 3'd0 : c6 + 3'd1;
    end
end
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

module tb_clk #(
    parameter int PHASE = 0
) (
    input  logic       clk,
    input  logic       reset,
    input  logic [1:0] speed,
    output logic [1:0] spd,
    output logic       ce_14m, cpu_step, cpu_fall, rdy_ce, cpu_prestep, ce_477, ce_pclk, pit_clk,
    output logic       r_ce_14m, r_cpu_step, r_cpu_fall, r_rdy_ce, r_cpu_prestep, r_ce_pclk, r_pit_clk
);
pc_clocks #(.PHASE(PHASE)) dut (
    .clk(clk), .reset(reset), .speed(speed), .spd(spd),
    .ce_14m(ce_14m), .cpu_step(cpu_step), .cpu_fall(cpu_fall), .rdy_ce(rdy_ce),
    .cpu_prestep(cpu_prestep), .ce_477(ce_477), .ce_pclk(ce_pclk), .pit_clk(pit_clk)
);
pc_clocks_ref #(.PHASE(PHASE)) ref0 (
    .clk(clk), .reset(reset),
    .ce_14m(r_ce_14m), .cpu_step(r_cpu_step), .cpu_fall(r_cpu_fall), .rdy_ce(r_rdy_ce),
    .cpu_prestep(r_cpu_prestep), .ce_pclk(r_ce_pclk), .pit_clk(r_pit_clk)
);
endmodule
