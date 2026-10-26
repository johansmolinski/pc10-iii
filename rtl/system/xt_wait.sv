// xt_wait.sv - the system board's wait-state generator: READY for the 8088
// from the synchronized RDY and the board's own wait states (xt_board.sv,
// section READY; doc/turbo.md section 3).
//
// The board's wait states per CPU cycle (the 5160 and the FE2010A at 4.77 MHz:
// one on every I/O cycle, none on memory). The FE2010A at its turbo speeds
// (Sergey Kiselev, micro_8088 Documentation/Faraday-XT_Controller-FE2010A.md,
// table of 2023-02-01; doc/turbo.md section 3):
//
//   63h bit 7 6 5   speed      I/O   on-board RAM   memory bus
//           0 0 x   4.77 MHz   1     0              0
//           0 1 0   7.16 MHz   4     0              2
//           0 1 1   7.16 MHz   4     0              0
//           1 0 0   9.54 MHz   6     0              4
//           1 1 0   9.54 MHz   4     0              2
//           1 0 1   9.54 MHz   6     0              0
//           1 1 1   9.54 MHz   4     0              0
//
// "Memory bus" is every memory cycle outside the on-board RAM (onboard = the
// address is below the RAM size of 63h): the BIOS ROM [A], the video memory,
// option ROMs. INTA and HALT cycles get none. The speed is the one the CPU
// clock runs at (pc_clocks `spd`), bits 6 and 5 the register's.
//
// When the wait states count: n wait states are n T-states after T2 that the
// board keeps from being the last; a state that the DMA wait held (AEN keeps
// the command off, so the wait state starts with the command) does not count.
// biu88 decides at the step that starts T3/Tw whether that state is the last
// (MartyPC fixes the wait states at T2), so READY at the step that ends T2 says
// whether T3 is the last, at the step that ends T3 whether the first Tw is, and
// so on. CAL: MartyPC (cycle.rs: the I/O wait states are not decremented while
// DMA wait states remain), first seen at reference clock 1,042,013 (an OUT with
// the refresh in its T1). For one wait state this is the logic of 2026-10-22
// (io_wait/dma_ok in xt_board.sv; tb/wait checks the equivalence).
//
// GPL-3.0-or-later, pc10-iii.

module xt_wait (
    input  logic       clk,
    input  logic       reset,
    input  logic       cpu_step,
    input  logic [2:0] cpu_bus_t,       // biu88's T-state (xt_board: TI..T4)
    input  logic [2:0] cpu_bus_type,    // the running cycle's status
    input  logic       onboard,         // the cycle's address is in the on-board RAM
    input  logic [1:0] spd,             // the CPU clock: 0 4.77, 1 7.16, 2 9.54 MHz
    input  logic [6:5] cfg,             // FE2010A 63h bits 6 (7.16 / fewer waits), 5 (fast)
    input  logic       rdy_sync,        // the 8284's RDY: IOCHRDY and the DMA wait
    input  logic       dma_rdy_sync,    // its DMA part alone
    output logic       cpu_ready,
    output logic [2:0] ws_n             // the board's wait states for this cycle (T2)
);

localparam logic [2:0] T2 = 3'd2, T3 = 3'd3, TW = 3'd4;
localparam logic [2:0] ST_IOR = 3'd1, ST_IOW = 3'd2, ST_CODE = 3'd4, ST_MEMR = 3'd5, ST_MEMW = 3'd6;

wire io_cycle  = cpu_bus_type == ST_IOR || cpu_bus_type == ST_IOW;
wire mem_cycle = cpu_bus_type == ST_CODE || cpu_bus_type == ST_MEMR || cpu_bus_type == ST_MEMW;
always_comb begin
    ws_n = 3'd0;
    if (io_cycle)
        case (spd)
            2'd0:    ws_n = 3'd1;
            2'd1:    ws_n = 3'd4;
            default: ws_n = cfg[6] ? 3'd4 : 3'd6;
        endcase
    else if (mem_cycle && !onboard && !cfg[5])
        case (spd)
            2'd0:    ws_n = 3'd0;
            2'd1:    ws_n = 3'd2;
            default: ws_n = cfg[6] ? 3'd2 : 3'd4;
        endcase
end

// ws: the wait states still to come, set at the step that ends T2; dma_ok: the
// DMA part of the sample that decided the state being left. ws_dec: what is
// left after that state (it counts if the DMA wait did not hold it).
logic [2:0] ws;
logic       dma_ok;
wire  in_t3tw = cpu_bus_t == T3 || cpu_bus_t == TW;
wire [2:0] ws_dec = dma_ok && ws != 3'd0 ? ws - 3'd1 : ws;
always_ff @(posedge clk)
    if (reset) begin
        ws <= 3'd0;  dma_ok <= 1'b1;
    end else if (cpu_step) begin
        dma_ok <= dma_rdy_sync;
        ws     <= cpu_bus_t == T2 ? ws_n : in_t3tw ? ws_dec : 3'd0;
    end
assign cpu_ready = rdy_sync && !(cpu_bus_t == T2 && ws_n != 3'd0) && !(in_t3tw && ws_dec != 3'd0);

endmodule
