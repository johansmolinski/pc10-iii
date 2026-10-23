// z86_tables.sv - the EU's four Intel tables as RAMs, filled at start-up from
// the microcode bundle (tools/mkucode.py; AGENTS.md rule 4: neither the
// repository nor the bitstream contains them, the block RAMs start empty):
//
//   - the microcode, 512 x 21 bits (block RAM);
//   - the microcode ROM's address decoder, {AR, CR}[12:2] -> row group
//     (2048 x 7, block RAM);
//   - the translation ROM, 256 x 13 bits (distributed RAM, read
//     asynchronously like z8086's logic was);
//   - the group decode ROM, 512 x 15 bits (distributed RAM, ditto).
//
// Load port (clk domain, one byte per clk with ucl_we): ucl_addr is the
// offset in the bundle file, so the loader just streams the file:
//   0x0009          flags (bit 0: genuine 8088 microcode, the overlay is off)
//   0x0200-0x03FF   translation, u16 little endian
//   0x0400-0x07FF   group decode, u16 little endian
//   0x0800-0x0FFF   address decoder, u8
//   0x1000-0x17FF   microcode, u32 little endian (byte 3 unused)
// The header's other bytes (magic, version, checksum) are checked by the
// loader (the QNICE firmware in the core, the testbench in simulation).
//
// Microcode read: two clocks from {AR, CR} to the word (decoder, then ROM),
// both registered. The EU changes AR/CR only at its clock enable and takes the
// word at its next one, at least 3 clk later at every CPU speed planned
// (doc/clock-plan.md). The 8088 interrupt overlay (8086 microcode only)
// replaces words on the ROM's output; see z86_overlay.svh.
//
// pc10-iii, 2026-10-22. GPL-3.0-or-later.

module z86_tables #(
    parameter bit OVERLAY = 1'b1        // the 8088 interrupt overlay for an 8086 ROM
) (
    input              clk,

    input              ucl_we,
    input       [12:0] ucl_addr,
    input       [7:0]  ucl_data,

    input       [12:0] ua,              // {AR, CR}
    output      [20:0] uc_word,         // ROM[ua], two clk later
    output reg  [8:0]  uc_row,          // its row (debug)
    output             genuine_8088,

    input       [7:0]  tr_idx,
    output      [12:0] tr_out,
    input       [8:0]  grp_idx,
    output      [14:0] grp_out
);

reg ov_off = 1'b0;

`include "z86_overlay.svh"
assign genuine_8088 = ov_off;

(* ram_style = "distributed" *) reg [7:0] tr_lo  [0:255];
(* ram_style = "distributed" *) reg [4:0] tr_hi  [0:255];
(* ram_style = "distributed" *) reg [7:0] grp_lo [0:511];
(* ram_style = "distributed" *) reg [6:0] grp_hi [0:511];
(* ram_style = "block" *)       reg [6:0] pack   [0:2047];
(* ram_style = "block" *)       reg [23:0] rom   [0:511];

wire sel_hdr = ucl_addr[12:9] == 4'b0000;                  // 0x0000-0x01FF
wire sel_tr  = ucl_addr[12:9] == 4'b0001;                  // 0x0200-0x03FF
wire sel_grp = ucl_addr[12:10] == 3'b001;                  // 0x0400-0x07FF
wire sel_pk  = ucl_addr[12:11] == 2'b01;                   // 0x0800-0x0FFF
wire sel_uc  = ucl_addr[12:11] == 2'b10;                   // 0x1000-0x17FF

always @(posedge clk) if (ucl_we) begin
    if (sel_hdr && ucl_addr[8:0] == 9'h009) ov_off <= ucl_data[0];
    if (sel_tr  && !ucl_addr[0]) tr_lo[ucl_addr[8:1]]  <= ucl_data;
    if (sel_tr  &&  ucl_addr[0]) tr_hi[ucl_addr[8:1]]  <= ucl_data[4:0];
    if (sel_grp && !ucl_addr[0]) grp_lo[ucl_addr[9:1]] <= ucl_data;
    if (sel_grp &&  ucl_addr[0]) grp_hi[ucl_addr[9:1]] <= ucl_data[6:0];
end

always @(posedge clk) if (ucl_we && sel_pk) pack[ucl_addr[10:0]] <= ucl_data[6:0];

// byte-wide writes into the 24-bit microcode word (block RAM byte enables)
always @(posedge clk) if (ucl_we && sel_uc) begin
    if (ucl_addr[1:0] == 2'd0) rom[ucl_addr[10:2]][7:0]   <= ucl_data;
    if (ucl_addr[1:0] == 2'd1) rom[ucl_addr[10:2]][15:8]  <= ucl_data;
    if (ucl_addr[1:0] == 2'd2) rom[ucl_addr[10:2]][23:16] <= ucl_data;
end

assign tr_out  = (OVERLAY && !ov_off && tr_ov_hit(tr_idx)) ? tr_ov(tr_idx) : {tr_hi[tr_idx], tr_lo[tr_idx]};

assign grp_out = {grp_hi[grp_idx], grp_lo[grp_idx]};

// microcode: decoder, then ROM
reg  [6:0]  pk;
reg  [1:0]  lo1;
reg  [23:0] w;
always @(posedge clk) begin
    pk     <= pack[ua[12:2]];
    lo1    <= ua[1:0];
    w      <= rom[{pk, lo1}];
    uc_row <= {pk, lo1};
end


wire        ov_hit;
wire [20:0] ov_w;
assign {ov_hit, ov_w} = (OVERLAY && !ov_off) ? overlay_8088(uc_row) : 22'd0;
assign uc_word = ov_hit ? ov_w : w[20:0];

endmodule
