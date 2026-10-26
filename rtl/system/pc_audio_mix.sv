// pc_audio_mix.sv - the core's audio: the PC speaker plus a Covox Speech Thing on
// the parallel port's data latch (doc/ports.md section 5).
//
// - The speaker as before: 0 or +2000h (a DC-coupled square wave, the level the
//   core has always had).
// - The Covox: the latch as an unsigned 8-bit DAC, (d - 128) x 32 (+-4096, about
//   the speaker's swing), through a DC blocker (a first-order high-pass,
//   y = x - x' + y' - y'/2^K, K = 10: 7.4 Hz at the 47.7 kHz sample rate, clk /
//   600), so a latch that stands still is silence whatever its value: the BIOS
//   writes POST codes and the printer probe's 0Ch to it, and DOS's printing
//   moves it (a Covox in the port hears that too). y keeps F fraction bits; its
//   decay is y / 2^K rounded toward zero but at least one unit, so a resting
//   latch ends at exactly 0.
// - No clipping: the high-pass's impulse response has an L1 norm of 2, so
//   |y| <= 2 x 4096 = 8192 and the sum stays within -8192..+16384.
//
// GPL-3.0-or-later, pc10-iii.

module pc_audio_mix #(
    parameter int RATE_DIV = 600,       // the DC blocker's sample rate: clk / RATE_DIV
    parameter int K        = 10,        // its pole: 1 - 2^-K
    parameter int F        = 8          // fraction bits of y
) (
    input  logic               clk,
    input  logic               speaker,
    input  logic [7:0]         dac,     // the parallel port's data latch
    output logic signed [15:0] audio
);

localparam int YW = 16 + F + 2;

logic [$clog2(RATE_DIV) - 1:0] div = '0;
logic signed [13:0] x1 = -14'sd4096;          // the last sample's x (the latch's 00h at power-up)
logic signed [YW - 1:0] y = '0;

wire signed [13:0] x = $signed({1'b0, dac} - 9'sd128) * 14'sd32;
wire              tick = div == RATE_DIV[$bits(div) - 1:0] - 1'b1;

// the decay y / 2^K, rounded toward zero, at least one unit
wire signed [YW - 1:0] ay  = y < 0 ? -y : y;
wire signed [YW - 1:0] dk0 = ay >>> K;
wire signed [YW - 1:0] dk  = y == 0 ? '0 : (dk0 == 0 ? 1 : dk0);
wire signed [YW - 1:0] dec = y < 0 ? -dk : dk;

always_ff @(posedge clk) begin
    div <= tick ? '0 : div + 1'b1;
    if (tick) begin
        x1 <= x;
        y  <= y + ((YW'(x) - YW'(x1)) <<< F) - dec;
    end
end

wire signed [YW - 1:0] yo = y >>> F;
assign audio = (speaker ? 16'sh2000 : 16'sh0000) + yo[15:0];

endmodule
