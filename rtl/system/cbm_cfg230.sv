// cbm_cfg230.sv - the Commodore configuration register at I/O 230h of the
// PC10-III (PC10/PC20-III service manual, chapter 5 "Autoconfig", 5-5;
// on the board in the Commodore gate array 5720, U602, sheet 9-6).
//
//   bit  7      6    5   4      3     2     1     0
//   R    mono   rtc  X   mouse  com1  com0  lpt1  lpt0
//   W    venb'  rtc  X   mouse  com1  com0  lpt1  lpt0
//
// Read bit 7 is the onboard video's mono/colour setting (DIP switch 2: 1 =
// up/off = monochrome); write bit 7 is venb' (0 = the onboard video, the
// PVC4, is enabled: the 5720's NOVID' output enables the PVC4's data buffer
// U604 and its READY driver Q602). Bits 6-0 read back what was written (the
// Commodore BIOS waits for the read-back after every write, F000:E07B and
// E0D3). Only the register is built here: the onboard RTC (02C0h), the bus
// mouse (023Ch), the serial port (com1/com0: off, 2F8h, 3F8h) and the
// parallel port (lpt1/lpt0: off, 3BCh, 378h, 278h) that its bits enable are
// not (doc/pvc4.md section 7).
//
// The value after reset is not documented; 00h (onboard video enabled, the
// peripherals off) is assumed. The Commodore BIOS writes the register before
// it uses any of them.
//
// GPL-3.0-or-later, pc10-iii.

module cbm_cfg230 (
    input  logic        clk,
    input  logic        reset,

    input  logic [19:0] isa_addr,
    input  logic [19:0] isa_addr_next,
    input  logic        isa_aen_next,
    input  logic        isa_ior_n_next,
    input  logic        isa_iow_n_next,
    input  logic [7:0]  isa_dout,
    output logic [7:0]  isa_din,
    output logic        isa_dsel,
    input  logic        isa_ior_n,
    input  logic        isa_iow_n,
    input  logic        isa_aen,

    input  logic        sw_mono,        // DIP switch 2: 1 = off = monochrome
    output logic        venb_n,         // 0: the onboard video is enabled
    output logic [6:0]  cfg             // rtc, X, mouse, com1, com0, lpt1, lpt0
);

// A9-A0 = 230h (the 5720 decodes BA0-BA9), AEN low
wire sel     = !isa_aen && isa_addr[9:0] == 10'h230;
wire sel_nx  = !isa_aen_next && isa_addr_next[9:0] == 10'h230;
// the write acts in the strobe's last clk (the card bus's next-clk values)
wire wr_end  = sel && !isa_iow_n && !(sel_nx && !isa_iow_n_next);

logic [7:0] r;
always_ff @(posedge clk)
    if (reset) r <= 8'h00;
    else if (wr_end) r <= isa_dout;

assign venb_n   = r[7];
assign cfg      = r[6:0];
assign isa_dsel = sel && !isa_ior_n;
assign isa_din  = isa_dsel ? {sw_mono, r[6:0]} : 8'h00;

endmodule
