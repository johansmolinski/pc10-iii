// fdd_mfm_wr.sv - the write side of a real 3.5" DD drive on the 34-pin
// interface: IBM MFM bytes -> channel bits -> WDATA pulses under WGATE
// (doc/fdc.md section 10).
//
// The magnetic discipline is Megamiga's physical_fdd_writer.vhd (sy2002,
// AExp/Megamiga, GPL-3.0; hardware-proven on the MEGA65's drive), re-timed
// from 50 MHz to CLK_HZ:
//   * one channel bit per 2.000 us cell (a fractional cell clock, exact on
//     average: CELL_NUM / CELL_DEN cells per clk);
//   * WDATA idle high, one registered active-low pulse of PULSE clks (500 ns)
//     per '1' channel bit, launched at the cell's midpoint (LAUNCH);
//   * write precompensation over a 7-bit window whose middle bit is the one
//     being written: a '1' whose gap before is shorter than its gap after goes
//     out PRECOMP clks (140 ns) early, the mirror case late, nothing at the
//     ends of a write (window not full) or with precomp_en = 0;
//   * WGATE opens in the cell in which the first channel bit is written and
//     closes at the end of the cell of the last one: no lead-in, no lead-out.
// New: the bytes come in with their kind and are MFM-encoded here (clock =
// NOR of the neighbouring data bits; A1 with the missing clock 0x4489, C2
// with its missing clock 0x5224). The byte source keeps a one-byte holding
// register filled (push when room = 1); when it runs dry the write ends.
//
// GPL-3.0 (as Megamiga's code it is derived from), pc10-iii.

module fdd_mfm_wr #(
    parameter int CELL_NUM = 11,        // cells per clk = CELL_NUM / CELL_DEN
    parameter int CELL_DEN = 630,       // (28.63636 MHz = 315/11 MHz, cell 2 us)
    parameter int LAUNCH   = 29,        // 1 us: the pulse at the cell's midpoint
    parameter int PULSE    = 14,        // 500 ns low
    parameter int PRECOMP  = 4          // 140 ns
) (
    input  logic        clk,
    input  logic        reset,

    // byte source
    input  logic        push,           // with room = 1: take byte/kind
    input  logic [7:0]  byte_data,
    input  logic [1:0]  byte_kind,      // 0 data, 1 A1 sync (missing clock), 2 C2 sync
    output logic        room,           // the holding register is free
    input  logic        precomp_en,

    output logic        busy,           // writing (from the first push to the closed gate)

    // the drive's inputs (active low, registered)
    output logic        f_wdata_n,
    output logic        f_wgate_n
);

// ------------------------------------------------------------ holding register
logic       h_valid;
logic [7:0] h_data;
logic [1:0] h_kind;
assign room = !h_valid;

// ------------------------------------------------------------ cell clock
logic [$clog2(CELL_DEN + CELL_NUM) - 1:0] acc;
logic tick;
logic running;                          // cells are being generated
always_ff @(posedge clk) begin
    tick <= 1'b0;
    if (reset || !running)
        acc <= '0;
    else if (acc + ($bits(acc))'(CELL_NUM) >= ($bits(acc))'(CELL_DEN)) begin
        acc  <= acc + ($bits(acc))'(CELL_NUM) - ($bits(acc))'(CELL_DEN);
        tick <= 1'b1;
    end else
        acc <= acc + ($bits(acc))'(CELL_NUM);
end

// ------------------------------------------------------------ MFM encoder
function automatic logic [15:0] mfm(input logic [7:0] b, input logic p, input logic [1:0] kind);
    logic [15:0] w;
    logic        q;
    q = p;
    for (int i = 7; i >= 0; i--) begin
        w[2 * i + 1] = !(q || b[i]);
        w[2 * i]     = b[i];
        q = b[i];
    end
    if (kind == 2'd1) w[5] = 1'b0;      // A1*: 0x4489
    if (kind == 2'd2) w[7] = 1'b0;      // C2*: 0x5224
    return w;
endfunction

logic [15:0] ch;                        // channel bits of the current byte, MSB first
logic [4:0]  ch_n;                      // bits left in ch
logic        prev_d;                    // the last data bit encoded
logic [6:0]  win, vwin;                 // [0] newest ... [3] written ... [6] oldest
logic [6:0]  dly;                       // clks into the cell
logic        fire;                      // the centre bit is a '1' to write in this cell
logic [5:0]  fire_at;
logic [4:0]  pcnt;
logic        gate;
// the pins as registers that power up inactive (an FPGA flip-flop without a
// reset value starts at 0 = WGATE active)
logic        wdata_q = 1'b1, wgate_q = 1'b1;
assign f_wdata_n = wdata_q;
assign f_wgate_n = wgate_q;

always_ff @(posedge clk) begin
    logic        nb, nv;
    logic [15:0] vch;
    logic [4:0]  vn;
    logic [6:0]  nwin, nvwin;
    int          gb, ga;
    if (reset) begin
        h_valid   <= 1'b0;
        running   <= 1'b0;
        ch_n      <= 5'd0;
        win       <= '0;
        vwin      <= '0;
        prev_d    <= 1'b0;
        gate      <= 1'b0;
        fire      <= 1'b0;
        pcnt      <= 5'd0;
        dly       <= '0;
        wdata_q <= 1'b1;
        wgate_q <= 1'b1;
    end else begin
        if (push && !h_valid) begin
            h_valid <= 1'b1;
            h_data  <= byte_data;
            h_kind  <= byte_kind;
            if (!running) begin
                running <= 1'b1;
                prev_d  <= 1'b0;
            end
        end

        if (tick) begin
            // the next channel bit: from the current byte, or the first of the
            // byte in the holding register
            vch = ch;  vn = ch_n;  nb = 1'b0;  nv = 1'b0;
            if (vn == 5'd0 && h_valid) begin
                vch     = mfm(h_data, prev_d, h_kind);
                vn      = 5'd16;
                prev_d  <= h_data[0];
                h_valid <= 1'b0;
            end
            if (vn != 5'd0) begin
                nb  = vch[15];
                nv  = 1'b1;
                vch = {vch[14:0], 1'b0};
                vn  = vn - 5'd1;
            end
            ch    <= vch;
            ch_n  <= vn;
            nwin  = {win[5:0], nb};
            nvwin = {vwin[5:0], nv};
            win   <= nwin;
            vwin  <= nvwin;
            // the written bit of this cell is nwin[3]; the gate covers its cell
            gate  <= nvwin[3];
            dly   <= 7'd0;
            fire  <= 1'b0;
            if (nvwin[3] && nwin[3]) begin
                // distance in cells to the previous '1' (older: 4, 5, 6) and
                // to the next one (newer: 2, 1, 0)
                gb = nwin[4] ? 1 : nwin[5] ? 2 : nwin[6] ? 3 : 4;
                ga = nwin[2] ? 1 : nwin[1] ? 2 : nwin[0] ? 3 : 4;
                fire    <= 1'b1;
                fire_at <= 6'(LAUNCH);
                if (precomp_en && &nvwin) begin
                    if (gb < ga)      fire_at <= 6'(LAUNCH - PRECOMP);
                    else if (gb > ga) fire_at <= 6'(LAUNCH + PRECOMP);
                end
            end
            // done when nothing is left to write and the last bit has passed
            if (vn == 5'd0 && !h_valid && !push && nvwin[3:0] == 4'd0)
                running <= 1'b0;
        end else if (dly != 7'h7F)
            dly <= dly + 7'd1;

        // pulse generator
        if (fire && dly == 7'(fire_at)) begin
            wdata_q <= 1'b0;
            pcnt      <= 5'(PULSE);
            fire      <= 1'b0;
        end else if (pcnt != 5'd0) begin
            pcnt <= pcnt - 5'd1;
            if (pcnt == 5'd1) wdata_q <= 1'b1;
        end
        wgate_q <= !gate;
    end
end

assign busy = running || gate || h_valid;

endmodule
