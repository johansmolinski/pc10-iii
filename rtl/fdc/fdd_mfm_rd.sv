// fdd_mfm_rd.sv - the read side of a real 3.5" DD drive on the 34-pin
// interface: flux pulses -> channel bits -> IBM MFM bytes and sync marks
// (doc/fdc.md section 10).
//
// The front-end is Megamiga's Hardware Floppy read chain (sy2002, AExp/
// Megamiga CORE/vhdl/physical_fdd/, GPL-3.0; in turn adapted from the
// C64MEGA65 physical-1581 bring-up, hardware-proven on the MEGA65's drive),
// translated to SystemVerilog and re-timed from its 50 MHz to any clock
// (the parameters; the PC's 28.63636 MHz here):
//   * physical_fdd_inputs: 2-FF synchronizers on every pin, the INDEX pulse
//     qualified by a minimum low time (200 us) before its leading edge counts;
//   * physical_fdd_mfm_gaps: flux edges = falling edges of the active-low
//     RDATA, a runt filter (an edge closer than 320 ns to the last accepted
//     one is an electrical glitch and is dropped);
//   * physical_fdd_bits, its DPLL data separator (WIP-V2-A5): a phase
//     accumulator in 1/16 clock units emits one channel bit per tracked cell,
//     '1' when an edge fell into it; every edge pulls the phase half-way to
//     the cell's centre and the period by err/64, clamped to +-10 %.
// New here (the PC's format, not the Amiga's raw words):
//   * the IBM MFM framing: the 16 latest channel bits equal to 0x4489 (A1
//     with its missing clock) is a sync mark and restarts the byte framing;
//     every 16 channel bits after it are a byte (the data bits, every second
//     one). C2* (the index address mark, 0x5224) is not framed on: the
//     controller never needs it.
//
// GPL-3.0 (as Megamiga's code it is derived from), pc10-iii.

module fdd_mfm_rd #(
    parameter int CELL_Q    = 916,      // 2 us channel cell in 1/16 clocks (57.27 * 16)
    parameter int GLITCH    = 9,        // 320 ns: closer edges are runts
    parameter int IDX_MIN   = 5727      // 200 us: an index pulse must be low this long
) (
    input  logic        clk,
    input  logic        reset,

    // the drive's outputs (active low, asynchronous)
    input  logic        f_index_n,
    input  logic        f_track0_n,
    input  logic        f_wpt_n,
    input  logic        f_rdata_n,

    // synchronized levels (active high)
    output logic        trk0,
    output logic        wpt,
    output logic        index_edge,     // one clk: an accepted index pulse began

    // the decoded stream
    output logic        byte_valid,     // one clk: a byte (data bits of 16 channel bits)
    output logic        byte_sync,      // ... and it was the A1 sync mark (0x4489)
    output logic [7:0]  byte_data
);

localparam int CELL_MIN_Q = CELL_Q * 9 / 10;
localparam int CELL_MAX_Q = CELL_Q * 11 / 10;

// ------------------------------------------------------------ synchronizers
(* async_reg = "true" *) logic [1:0] s_idx, s_trk0, s_wpt, s_rd;
always_ff @(posedge clk) begin
    s_idx  <= {s_idx[0],  f_index_n};
    s_trk0 <= {s_trk0[0], f_track0_n};
    s_wpt  <= {s_wpt[0],  f_wpt_n};
    s_rd   <= {s_rd[0],   f_rdata_n};
end
assign trk0 = !s_trk0[1];
assign wpt  = !s_wpt[1];

// ------------------------------------------------------------ index pulse
logic [$clog2(IDX_MIN + 1) - 1:0] idx_low;
logic idx_acc;
always_ff @(posedge clk) begin
    index_edge <= 1'b0;
    if (reset) begin
        idx_low <= '0;
        idx_acc <= 1'b0;
    end else if (!s_idx[1]) begin
        if (!idx_acc) begin
            if (idx_low == ($bits(idx_low))'(IDX_MIN - 1)) begin
                idx_acc    <= 1'b1;
                index_edge <= 1'b1;
            end else
                idx_low <= idx_low + 1'b1;
        end
    end else begin
        idx_acc <= 1'b0;
        idx_low <= '0;
    end
end

// ------------------------------------------------------------ flux edges
logic       rd_d1, rd_d2;
logic [$clog2(GLITCH + 1) - 1:0] since;     // clks since the last accepted edge (saturating)
logic       edge_ok;
always_ff @(posedge clk) begin
    rd_d1 <= s_rd[1];
    rd_d2 <= rd_d1;
    edge_ok <= 1'b0;
    if (reset)
        since <= '0;
    else if (!rd_d1 && rd_d2 && since == ($bits(since))'(GLITCH)) begin
        edge_ok <= 1'b1;
        since   <= '0;
    end else if (since != ($bits(since))'(GLITCH))
        since <= since + 1'b1;
end

// ------------------------------------------------------------ DPLL
logic [12:0] phase;
logic [11:0] cellq;
logic        pend;
logic        bit_valid, bit_val;
always_ff @(posedge clk) begin
    logic [13:0] vph;
    logic        vpend;
    logic signed [14:0] err, vcell;
    bit_valid <= 1'b0;
    if (reset) begin
        phase <= '0;
        cellq  <= 12'(CELL_Q);
        pend  <= 1'b0;
    end else begin
        vph   = 14'(phase) + 14'd16;
        vpend = pend;
        if (edge_ok) begin
            vpend = 1'b1;
            err   = signed'(15'(vph)) - signed'(15'(cellq[11:1]));
            vph   = 14'(signed'(15'(vph)) - (err >>> 1));
            vcell = signed'(15'(cellq)) + (err >>> 6);
            if (vcell < 15'(CELL_MIN_Q))      cellq <= 12'(CELL_MIN_Q);
            else if (vcell > 15'(CELL_MAX_Q)) cellq <= 12'(CELL_MAX_Q);
            else                              cellq <= 12'(vcell);
        end
        if (vph >= 14'(cellq)) begin
            vph = vph - 14'(cellq);
            bit_valid <= 1'b1;
            bit_val   <= vpend;
            vpend     = 1'b0;
        end
        phase <= 13'(vph);
        pend  <= vpend;
    end
end

// ------------------------------------------------------------ MFM framing
logic [15:0] sr;
logic [3:0]  cnt;
wire  [15:0] sr_n = {sr[14:0], bit_val};
always_ff @(posedge clk) begin
    byte_valid <= 1'b0;
    if (reset) begin
        sr  <= '0;
        cnt <= 4'd0;
    end else if (bit_valid) begin
        sr <= sr_n;
        if (sr_n == 16'h4489 || cnt == 4'd15) begin
            byte_valid <= 1'b1;
            byte_sync  <= sr_n == 16'h4489;
            byte_data  <= {sr_n[14], sr_n[12], sr_n[10], sr_n[8], sr_n[6], sr_n[4], sr_n[2], sr_n[0]};
            cnt        <= 4'd0;
        end else
            cnt <= cnt + 4'd1;
    end
end

endmodule
