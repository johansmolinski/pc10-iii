// lpt_ppc1.sv - the PC10-III's parallel port: a Paradise PPC1 (U403, 318091-01
// in the service manual's parts list) behind the Commodore gate array 5720,
// which selects it at 3BCh, 378h or 278h (230h bits 1-0, `lpt`). No PPC1 data
// sheet was found, so this is IBM's printer adapter (doc/ports.md section 3):
//
//   base + 0  data      write: the output latch; read: the latch (IBM reads the
//                       pins, which the latch drives)
//   base + 1  status    read: {/BUSY, /ACK, PE, SLCT, /ERROR, 1, 1, 1} - bit 7
//                       is the BUSY pin inverted, the others the pins as they are
//   base + 2  control   write: {-, -, -, IRQ EN, SLCT IN, /INIT, AUTO FD, STROBE};
//                       read: {1, 1, 1, the five bits}; STROBE, AUTO FD and
//                       SLCT IN drive their (active-low) pins inverted, /INIT
//                       as written
//   base + 3  nothing
//
// IRQ7 (IBM): while IRQ EN is set the /ACK pin drives the interrupt line, so an
// interrupt is raised when /ACK goes back high at the end of the printer's
// acknowledge (an edge-triggered 8259), and once when IRQ EN is set with /ACK
// high; with IRQ EN clear the line is low.
//
// Reset: the control register is cleared (STROBE, AUTO FD, SLCT IN inactive,
// /INIT low = the printer held in its reset until the BIOS writes 08h/0Ch, as
// IBM's 74LS174); the data latch has no reset (IBM's 74LS374) and is 00h at
// power-up. `data` is the latch for the Covox Speech Thing (doc/ports.md
// section 5): it is inside the core, so it works with or without the PMOD.
//
// GPL-3.0-or-later, pc10-iii.

module lpt_ppc1 (
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

    input  logic [1:0]  lpt,            // 230h bits 1-0: 01 3BCh, 10 378h, 11 278h, 00 off
    output logic        irq7,

    output logic [7:0]  data,           // D7-D0 (the latch)
    output logic        strobe_n,
    output logic        autofd_n,
    output logic        init_n,
    output logic        selin_n,
    input  logic        busy,           // the pins, synchronized by the caller
    input  logic        ack_n,
    input  logic        pe,
    input  logic        slct,
    input  logic        err_n
);

wire [9:0] base = lpt == 2'b01 ? 10'h3BC : lpt == 2'b10 ? 10'h378 : 10'h278;
wire sel    = lpt != 2'b00 && !isa_aen && isa_addr[9:2] == base[9:2] && isa_addr[1:0] != 2'd3;
wire sel_nx = lpt != 2'b00 && !isa_aen_next && isa_addr_next[9:0] == isa_addr[9:0];
wire wr_end = sel && !isa_iow_n && !(sel_nx && !isa_iow_n_next);

logic [7:0] dlatch = 8'h00;
logic [4:0] ctrl;

always_ff @(posedge clk) begin
    if (wr_end && isa_addr[1:0] == 2'd0) dlatch <= isa_dout;
    if (reset) ctrl <= 5'h00;
    else if (wr_end && isa_addr[1:0] == 2'd2) ctrl <= isa_dout[4:0];
end

logic [7:0] rd;
always_comb
    case (isa_addr[1:0])
        2'd0:    rd = dlatch;
        2'd1:    rd = {!busy, ack_n, pe, slct, err_n, 3'b111};
        default: rd = {3'b111, ctrl};
    endcase

assign isa_dsel = sel && !isa_ior_n;
assign isa_din  = isa_dsel ? rd : 8'h00;

assign data     = dlatch;
assign strobe_n = !ctrl[0];
assign autofd_n = !ctrl[1];
assign init_n   = ctrl[2];
assign selin_n  = !ctrl[3];
assign irq7     = lpt != 2'b00 && ctrl[4] && ack_n;

endmodule
