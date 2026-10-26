// tb_wait.sv - the wait-state generator (rtl/system/xt_wait.sv) next to the
// board's READY logic of 2026-10-22 (one wait state on every I/O cycle, io_wait/
// dma_ok in xt_board.sv), the reference at 4.77 MHz.
//
// GPL-3.0-or-later, pc10-iii.

module tb_wait (
    input  logic       clk,
    input  logic       reset,
    input  logic       cpu_step,
    input  logic [2:0] cpu_bus_t,
    input  logic [2:0] cpu_bus_type,
    input  logic       onboard,
    input  logic [1:0] spd,
    input  logic [6:5] cfg,
    input  logic       rdy_sync,
    input  logic       dma_rdy_sync,
    output logic       cpu_ready,
    output logic [2:0] ws_n,
    output logic       ref_ready
);
xt_wait dut (.*);

// the old logic
localparam logic [2:0] T2 = 3'd2, T3 = 3'd3, TW = 3'd4, ST_IOR = 3'd1, ST_IOW = 3'd2;
wire  in_t3tw  = cpu_bus_t == T3 || cpu_bus_t == TW;
wire  io_cycle = cpu_bus_type == ST_IOR || cpu_bus_type == ST_IOW;
logic io_wait, dma_ok;
wire  io_wait_n = io_wait && !dma_ok;
always_ff @(posedge clk)
    if (reset) begin
        io_wait <= 1'b0;  dma_ok <= 1'b1;
    end else if (cpu_step) begin
        dma_ok  <= dma_rdy_sync;
        io_wait <= cpu_bus_t == T2 ? io_cycle : in_t3tw && io_wait_n;
    end
assign ref_ready = rdy_sync && !(cpu_bus_t == T2 && io_cycle) && !(in_t3tw && io_wait_n);
endmodule
