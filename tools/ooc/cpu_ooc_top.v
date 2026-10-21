// cpu_ooc_top.v - the 8088 (rtl/cpu/cpu8088.sv: MCL86 EU + biu88 + microcode
// ROM) with registered I/O, for an out-of-context Vivado run that measures the
// CPU alone at 100.2273 MHz (tools/ooc/cpu_ooc.tcl). The CPU's own timing
// constraints (rtl/cpu/cpu8088.xdc) are read scoped to cpu8088, as in the
// system.
module cpu_ooc_top (
    input             clk,
    input             reset_i,
    input             step_i,
    input             ready_i,
    input             nmi_i,
    input             intr_i,
    input      [7:0]  ad_in_i,
    output reg [19:0] ad_out_o,
    output reg [2:0]  s2_s0_o,
    output reg        lock_n_o,
    output reg [1:0]  qs_o,
    output reg        ale_o,
    output reg [2:0]  bus_t_o,
    output reg [2:0]  bus_type_o
);

reg        reset, step, ready, nmi, intr;
reg  [7:0] ad_in;
always @(posedge clk) begin
    reset <= reset_i; step <= step_i; ready <= ready_i;
    nmi <= nmi_i; intr <= intr_i; ad_in <= ad_in_i;
end

wire [19:0] ad_out;
wire [2:0]  s2_s0, bus_t, bus_type;
wire [1:0]  qs;
wire        lock_n, ale;

cpu8088 cpu (
    .clk(clk), .reset(reset), .step(step),
    .ready(ready), .intr(intr), .nmi(nmi), .test_n(1'b1),
    .ad_out(ad_out), .ad_in(ad_in), .s2_s0(s2_s0), .qs(qs),
    .lock_n(lock_n), .ale(ale), .bus_t(bus_t), .bus_type(bus_type),
    .dbg_cs(), .dbg_ip()
);

always @(posedge clk) begin
    ad_out_o <= ad_out; s2_s0_o <= s2_s0; lock_n_o <= lock_n; qs_o <= qs;
    ale_o <= ale; bus_t_o <= bus_t; bus_type_o <= bus_type;
end

endmodule
