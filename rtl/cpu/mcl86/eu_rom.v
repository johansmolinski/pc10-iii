// eu_rom.v - the MCL86 microcode ROM: 8K x 32, one clock read latency, read
// enable (pc10-iii: the SYNC microinstruction holds the output).
//
// Stands in for the Xilinx Block Memory Generator instance MCL86 expected
// (EU4Kx32, 4K words; the EU's addresses and jump targets were 13 bits wide
// already). The image comes from microcode.txt via tools/mcasm.py.

`ifndef MCL86_ROM
`define MCL86_ROM "microcode.hex"
`endif

module EU8Kx32 #(
    parameter INIT_FILE = `MCL86_ROM
) (
    input             clka,
    input             ena,
    input      [12:0] addra,
    output reg [31:0] douta
);

reg [31:0] rom [0:8191];

initial $readmemh(INIT_FILE, rom);

always @(posedge clka)
    if (ena)
        douta <= rom[addra];

endmodule
