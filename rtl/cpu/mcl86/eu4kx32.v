// eu4kx32.v - the MCL86 microcode ROM (4K x 32, one clock read latency).
//
// Stands in for the Xilinx Block Memory Generator instance MCL86 expects
// (EU4Kx32). The image comes from microcode.txt via tools/mcasm.py.

`ifndef MCL86_ROM
`define MCL86_ROM "microcode.hex"
`endif

module EU4Kx32 #(
    parameter INIT_FILE = `MCL86_ROM
) (
    input             clka,
    input      [11:0] addra,
    output reg [31:0] douta
);

reg [31:0] rom [0:4095];

initial $readmemh(INIT_FILE, rom);

always @(posedge clka)
    douta <= rom[addra];

endmodule
