// cga_stub.sv - stand-in for the CGA card in the system simulation until
// rtl/video/cga exists: 16 KB of video RAM at B8000-BFFFF, the CRTC and
// mode registers stored, 3DA status bits toggled by a free-running counter.
// No video output, no wait states. The TB reads `vram` hierarchically.

module cga_card (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce_14m,
    input  logic [19:0] isa_addr,
    input  logic [7:0]  isa_dout,
    output logic [7:0]  isa_din,
    output logic        isa_dsel,
    input  logic        isa_memr_n,
    input  logic        isa_memw_n,
    input  logic        isa_ior_n,
    input  logic        isa_iow_n,
    input  logic        isa_aen,
    output logic        isa_ready,
    output logic [3:0]  vid_rgbi,
    output logic        vid_hsync,
    output logic        vid_vsync,
    output logic        vid_hblank,
    output logic        vid_vblank
);

logic [7:0] vram [16384];
logic [7:0] crtc [32];
logic [4:0] crtc_idx;
logic [7:0] mode_reg, color_reg;
logic [19:0] frame_cnt;                  // 14.318 MHz ticks in a frame

wire sel_mem = isa_addr[19:14] == 6'b1011_10;
wire sel_io  = !isa_aen && isa_addr[15:4] == 12'h03D;
logic memw_d, iow_d;

always_ff @(posedge clk) begin
    memw_d <= !isa_memw_n;
    iow_d  <= !isa_iow_n;
    if (ce_14m) frame_cnt <= frame_cnt == 20'd238943 ? 20'd0 : frame_cnt + 20'd1;   // 912 x 262
    if (reset) begin
        crtc_idx <= 5'd0; mode_reg <= 8'h00; color_reg <= 8'h00; frame_cnt <= 20'd0;
    end else begin
        if (sel_mem && !isa_memw_n && !memw_d) vram[isa_addr[13:0]] <= isa_dout;
        if (sel_io && !isa_iow_n && !iow_d)
            case (isa_addr[3:0])
                4'h0, 4'h2, 4'h4, 4'h6: crtc_idx <= isa_dout[4:0];
                4'h1, 4'h3, 4'h5, 4'h7: crtc[crtc_idx] <= isa_dout;
                4'h8: mode_reg <= isa_dout;
                4'h9: color_reg <= isa_dout;
                default: ;
            endcase
    end
end

wire [9:0] line = 10'(frame_cnt / 912);
wire [9:0] dot  = 10'(frame_cnt % 912);
wire       vblank = line >= 10'd200;
wire       hblank = dot >= 10'd640;

always_comb begin
    isa_dsel = 1'b0;
    isa_din  = 8'h00;
    if (sel_mem && !isa_memr_n) begin
        isa_dsel = 1'b1;
        isa_din  = vram[isa_addr[13:0]];
    end else if (sel_io && !isa_ior_n) begin
        isa_dsel = 1'b1;
        case (isa_addr[3:0])
            4'h1, 4'h3, 4'h5, 4'h7: isa_din = crtc[crtc_idx];
            4'hA: isa_din = {4'hF, vblank, 2'b11, hblank | vblank};
            default: isa_din = 8'hFF;
        endcase
    end
end

assign isa_ready  = 1'b1;
assign vid_rgbi   = 4'h0;
assign vid_hsync  = dot >= 10'd720 && dot < 10'd784;
assign vid_vsync  = line >= 10'd224 && line < 10'd227;
assign vid_hblank = hblank;
assign vid_vblank = vblank;

endmodule
