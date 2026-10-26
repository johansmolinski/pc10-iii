// cbm_mouse.sv - the PC10-III's bus mouse interface in the Commodore gate array
// 5720 (U602), documented in the PC-1 Technical Manual (MIO, pp. 1-28..1-31;
// the PC10-III carries the same chip). doc/ports.md section 4.
//
//   23Ch read   {L, M, R, 0, counter nibble}: the buttons (0 = pressed) and the
//               nibble of the counter selected by 23Eh bits 6-5 (the TM says R, M, L;
//               Commodore's own MOUSE.COM 6.11 reads bit 7 as the left button: tb/sys)
//   23Dh r/w    a plain register ("the MicroSoft driver uses this register to
//               recognize the mouse interface"; the BIOS 4.41 writes 66h and
//               reads it back, F000:CD5C)
//   23Eh write  bit 4 interrupt disable, bit 5 high nibble, bit 6 vertical
//               counter, bit 7 all inputs disabled (hold); the falling edge of
//               bit 7 clears both counters. Cleared by reset.
//   23Eh read   {0, 0, 0, 0, IRQ2 inverted, 1, 1, 1}: bit 3 is the interrupt's
//               32.8 ms square wave inverted, 1 while the interrupt is disabled
//
// All three answer only while 230h bit 4 (`enable`) is set, which also enables
// IRQ2. The interrupt is a square wave of 32.768 ms (16 MHz / 2^19: the board's
// 16 MHz floppy oscillator, made here from clk by an exact fractional
// accumulator, + 176 per clk modulo 315) on IRQ2 while 23Eh bit 4 is clear:
// the edge-triggered 8259 sees one interrupt per period.
//
// The mouse (an Amiga 1352-style quadrature mouse on the 9-pin port J8: pins
// 1/3 vertical, 2/4 horizontal; the core takes it from the MEGA65's joystick
// port): two 8-bit up/down counters, one count per edge of either quadrature
// line (Denise's decoding, as Minimig's userio.v): with p the "pulse" line
// (Amiga H, pin 2 / V, pin 1) and q the "quad" line (HQ, pin 4 / VQ, pin 3),
// +1 for q rising with p high, q falling with p low, p rising with q low, p
// falling with q high; -1 for the mirror cases; nothing when both change in
// the same clk. Up = right (X) and down (Y), as on the Amiga and as the PC's
// bus mouse reports. Counts wrap (8 bits); while
// 23Eh bit 7 is set the inputs are ignored (moves are lost). The buttons are
// read live. The counters keep counting while the interface is disabled.
//
// GPL-3.0-or-later, pc10-iii.

module cbm_mouse #(
    // 16 MHz = clk x OSC_NUM / OSC_DEN (exact for clk = 315/11 MHz)
    parameter int unsigned OSC_NUM = 32'd176,
    parameter int unsigned OSC_DEN = 32'd315,
    parameter int          SQ_BITS = 19            // the square wave: 2^SQ_BITS ticks
) (
    input  logic        clk,
    input  logic        reset,

    input  logic [19:0] isa_addr,
    input  logic [19:0] isa_addr_next,
    input  logic        isa_aen_next,
    input  logic        isa_iow_n_next,
    input  logic [7:0]  isa_dout,
    output logic [7:0]  isa_din,
    output logic        isa_dsel,
    input  logic        isa_ior_n,
    input  logic        isa_iow_n,
    input  logic        isa_aen,

    input  logic        enable,         // 230h bit 4
    output logic        irq2,

    // the mouse, asynchronous: quadrature pairs and the buttons (0 = pressed)
    input  logic        x_p,            // horizontal: Amiga H (DB9 pin 2)
    input  logic        x_q,            //             Amiga HQ (pin 4)
    input  logic        y_p,            // vertical:   Amiga V (pin 1)
    input  logic        y_q,            //             Amiga VQ (pin 3)
    input  logic        btn_l_n,
    input  logic        btn_m_n,
    input  logic        btn_r_n
);

// ------------------------------------------------------------ the bus
wire sel    = enable && !isa_aen && isa_addr[9:0] >= 10'h23C && isa_addr[9:0] <= 10'h23E;
wire sel_nx = enable && !isa_aen_next && isa_addr_next[9:0] == isa_addr[9:0];
wire wr_end = sel && !isa_iow_n && !(sel_nx && !isa_iow_n_next);

logic [7:0] dummy;
logic [3:0] ctrl;                       // 23Eh bits 7-4: hold, vertical, high nibble, irq off
logic [7:0] cx, cy;

// ------------------------------------------------------------ 32.768 ms
logic [9:0]  acc = '0;
wire  [9:0]  acc_n = acc + OSC_NUM[9:0];
wire         tick = acc_n >= OSC_DEN[9:0];
logic [SQ_BITS - 1:0] div;
always_ff @(posedge clk) begin
    acc <= tick ? acc_n - OSC_DEN[9:0] : acc_n;
    if (reset) div <= '0;
    else if (tick) div <= div + 1'b1;
end
wire sq = div[SQ_BITS - 1];
wire irq_on = enable && !ctrl[0];
assign irq2 = irq_on && sq;

// ------------------------------------------------------------ the quadrature inputs
logic [2:0] sxp = '1, sxq = '1, syp = '1, syq = '1;     // 2 synchronizer stages + the last
logic [1:0] sl = '1, sm = '1, sr = '1;
always_ff @(posedge clk) begin
    sxp <= {sxp[1:0], x_p};
    sxq <= {sxq[1:0], x_q};
    syp <= {syp[1:0], y_p};
    syq <= {syq[1:0], y_q};
    sl  <= {sl[0], btn_l_n};
    sm  <= {sm[0], btn_m_n};
    sr  <= {sr[0], btn_r_n};
end

// +1 / -1 from the old (o) and new (n) levels of the pulse (p) and quad (q) lines
function automatic logic [1:0] step(input logic po, pn, qo, qn);
    logic up, dn;
    up = (!qo && qn && pn) || (qo && !qn && !pn) || (!po && pn && !qn) || (po && !pn && qn);
    dn = (!qo && qn && !pn) || (qo && !qn && pn) || (!po && pn && qn) || (po && !pn && !qn);
    step = {dn, up};
endfunction
wire [1:0] sx = step(sxp[2], sxp[1], sxq[2], sxq[1]);
wire [1:0] sy = step(syp[2], syp[1], syq[2], syq[1]);

always_ff @(posedge clk) begin
    if (reset) begin
        ctrl <= 4'h0;  dummy <= 8'h00;  cx <= 8'h00;  cy <= 8'h00;
    end else begin
        if (!ctrl[3]) begin
            if (sx == 2'b01) cx <= cx + 8'd1;
            else if (sx == 2'b10) cx <= cx - 8'd1;
            if (sy == 2'b01) cy <= cy + 8'd1;
            else if (sy == 2'b10) cy <= cy - 8'd1;
        end
        if (wr_end && isa_addr[1:0] == 2'd1) dummy <= isa_dout;
        if (wr_end && isa_addr[1:0] == 2'd2) begin
            ctrl <= isa_dout[7:4];
            if (ctrl[3] && !isa_dout[7]) begin cx <= 8'h00; cy <= 8'h00; end
        end
    end
end

// ------------------------------------------------------------ reads
wire [7:0] cnt = ctrl[2] ? cy : cx;
logic [7:0] rd;
always_comb
    case (isa_addr[1:0])
        // the buttons as the Microsoft bus mouse driver reads them: 7 left, 6 middle,
        // 5 right (the TM's table has left and right the other way round, doc/ports.md)
        2'd0:    rd = {sl[1], sm[1], sr[1], 1'b0, ctrl[1] ? cnt[7:4] : cnt[3:0]};
        2'd1:    rd = dummy;
        default: rd = {4'h0, !irq2, 3'b111};
    endcase

assign isa_dsel = sel && !isa_ior_n;
assign isa_din  = isa_dsel ? rd : 8'h00;

endmodule
