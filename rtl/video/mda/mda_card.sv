// mda_card.sv - IBM Monochrome Display Adapter (display part of the IBM
// Monochrome Display and Printer Adapter) and a Hercules Graphics Card mode,
// on the pc10-iii card bus.
//
// Reference: the logic diagrams of IBM's "Monochrome Display and Printer
// Adapter" Technical Reference (6361511, sheets 1-10). MartyPC's
// devices/mda/*.rs (MIT, (c) 2022-2026 Daniel Balsom) for the register
// behaviour and the Hercules extensions. The design, the schematic reading
// and every difference to MartyPC are in doc/mda.md.
//
// Clocking: everything on clk (100.2273 MHz). The card has its own crystal
// (16.257 MHz; 16.000 MHz on the Hercules card), asynchronous to the PC. It
// is made from clk with a fractional accumulator (DOT_INC/DOT_MOD): an
// enable for the rising dot clock edge (6 or 7 clk apart, exact in the
// average) and one for the falling edge half a dot later. The CPU side
// samples the card's state on clk like the real bus samples an asynchronous
// card.
//
// Character timing (sheet 3): a 9-state counter (U1, 74LS174 + NOR feedback)
// on the dot clock. In this file `ph` 0 is the state in which the character
// clock CCLK rises (the schematic's s5, "Q5"): the 6845 (clocked by -CCLK)
// steps, the video RAM output of the last character is latched (U31/U34),
// the attributes of the one before go to the dot stage (U29/U30), and the
// 6845's DISPEN/CURSOR/HSYNC/VSYNC are sampled (U55). CCLK is high for
// 4.5 dots (ph 0 to the middle of ph 4), low for 4.5.
//
// CPU access (sheet 3, U4/U5/U36): a VRAM access (B0000-B7FFF, any MEMR/
// MEMW) or a 6845 access (3B0-3B7, any IOR/IOW, AEN low) is a request. The
// request is sampled at the rising edge of the counter's 4Q (the start of
// the last dot of a character, ph 8); then the CPU owns the RAM address
// during the next CCLK-high half (ph 0 to the middle of ph 4) and IOCHRDY
// goes high at the CCLK falling edge (the middle of ph 4): 5.5 dots after
// the sample, 5.5 to 14.5 dots after the strobe. The I/O to 3B8-3BF waits
// for nothing. Without mode bit 0 (high resolution) the dot clock is not
// selected (U24) and nothing on the card runs: a VRAM or 6845 access then
// never ends (IBM: "the system unit's microprocessor will stop running").
//
// Card bus (doc/architecture.md section 3). MDA: 4 KB at B0000, mirrored to
// B7FFF; I/O 3B0-3B7 6845 (A0 = data), 3B8 mode, 3BA status. Hercules:
// 64 KB, B0000-B7FFF always, B8000-BFFFF when 3BF bit 1 is set and no CGA is
// fitted (`cga_fitted`); 3BF configuration switch (bit 0 allow graphics,
// bit 1 enable page 2); 3B8 bit 1 graphics, bit 7 display page.
//
// GPL-3.0-or-later, pc10-iii.

module mda_card #(
    parameter bit HERC      = 1'b0,          // 1 = Hercules Graphics Card
    // dot clock = DOT_INC / DOT_MOD x clk (DOT_MOD even):
    //   MDA 16.257 MHz: 59609 / 367500;  HGC 16.000 MHz: 704 / 4410
    parameter int DOT_INC   = HERC ? 704  : 59609,
    parameter int DOT_MOD   = HERC ? 4410 : 367500,
    parameter bit HRES_STOP = !HERC,         // no dot clock without 3B8 bit 0
    // vid_hblank/vid_vblank window, counted from the start of vid_hsync
    // (dots) and vid_vsync (lines): the 720x350 text and the 720x348 HGC
    // graphics with one character of margin
    parameter int AP_X = 144,
    parameter int AP_W = 738,
    parameter int AP_Y = 16,
    parameter int AP_H = 354
) (
    input  logic        clk,            // 100.2273 MHz
    input  logic        reset,

    // card bus
    input  logic [19:0] isa_addr,
    input  logic [7:0]  isa_dout,
    output logic [7:0]  isa_din,
    output logic        isa_dsel,
    input  logic        isa_memr_n,
    input  logic        isa_memw_n,
    input  logic        isa_ior_n,
    input  logic        isa_iow_n,
    input  logic        isa_aen,
    output logic        isa_ready,      // IOCHRDY

    input  logic        cga_fitted,     // HGC: B8000-BFFFF belongs to the CGA

    // character ROM: the 8 KB image of IBM's 5788005; the card keeps
    // 0x0000-0x0FFF (the MDA font: A11 = row bit 3, A10-A3 = character,
    // A2-A0 = row bits 2-0)
    input  logic        font_we,
    input  logic [12:0] font_addr,
    input  logic [7:0]  font_data,

    // video, one dot per vid_ce; the outputs change on the dot clock and are
    // stable at vid_ce (the falling dot clock edge)
    output logic        vid_ce,
    output logic        vid_video,      // +VIDEO (connector pin 7)
    output logic        vid_intens,     // +INTENSITY (pin 6)
    output logic        vid_hsync,      // +HORIZONTAL DRIVE (pin 8), active high
    output logic        vid_vsync,      // VERTICAL DRIVE (pin 9 is active low), active high
    output logic        vid_hblank,
    output logic        vid_vblank
);

localparam int VW   = HERC ? 16 : 12;           // video RAM address bits
localparam int HALF = DOT_MOD / 2;

// ============================================================ dot clock
localparam int AW = $clog2(DOT_MOD) + 1;
logic [AW-1:0] acc;
wire  [AW-1:0] acc_n    = acc + AW'(DOT_INC);
wire           osc_rise = acc_n >= AW'(DOT_MOD);             // the crystal's rising edge
wire           osc_fall = acc < AW'(HALF) && acc_n >= AW'(HALF); // its falling edge
always_ff @(posedge clk)
    if (reset) acc <= '0;
    else       acc <= osc_rise ? acc_n - AW'(DOT_MOD) : acc_n;

// ============================================================ registers
logic [7:0] mode;                       // 3B8 (bits 0, 3, 5; HGC also 1, 7)
logic [1:0] cfg;                        // 3BF (HGC)
logic       hs_ok;                      // U45: video was enabled since reset
wire        m_hres  = mode[0];
wire        m_gfx   = HERC && mode[1];
wire        m_en    = mode[3];
wire        m_blink = mode[5];
wire        m_page  = HERC && mode[7];
wire        run     = !HRES_STOP || m_hres;
wire        rise    = osc_rise && run;      // DOTCLK rising
wire        fall    = osc_fall && run;      // DOTCLK falling

// character counter
logic [3:0] ph;
logic       gfx_c;                      // 16-dot characters (HGC graphics)
wire  [3:0] last = gfx_c ? 4'd15 : 4'd8;
wire  [3:0] ph_n = ph >= last ? 4'd0 : ph + 4'd1;
wire        ev_e   = rise && ph_n == 4'd0;   // CCLK rises: 6845 step, latches
wire        ev_cap = rise && ph_n == last;   // 4Q rises: request sampled
wire        ev_ack = fall && ph == 4'd4;     // CCLK falls: CPU slot ends

// ============================================================ CRTC
logic        crtc_wa, crtc_wd;
logic [7:0]  crtc_din, crtc_dout;
logic [13:0] ma;
logic [4:0]  ra, vsc;
logic        de, c_hs, c_vs, c_cur;

cga_crtc u_crtc (
    .clk       (clk),
    .reset     (reset),
    .cclk      (ev_e),
    .wr_addr   (crtc_wa),
    .wr_data   (crtc_wd),
    .din       (crtc_din),
    .dout      (crtc_dout),
    .lp_strobe (1'b0),
    .ma        (ma),
    .ra        (ra),
    .de        (de),
    .hsync     (c_hs),
    .vsync     (c_vs),
    .cursor    (c_cur),
    .vsc       (vsc)
);

// ============================================================ memories
logic [7:0]    vram [2**VW];
logic [VW-1:0] va_addr, vb_addr;
logic [7:0]    va_q, vb_q;
logic          va_we;
logic [7:0]    va_d;
always_ff @(posedge clk) begin
    if (va_we) vram[va_addr] <= va_d;
    va_q <= vram[va_addr];
end
always_ff @(posedge clk)
    vb_q <= vram[vb_addr];

logic [7:0]  font [4096];
logic [11:0] fr_addr;
logic [7:0]  fr_q;
always_ff @(posedge clk) begin
    if (font_we && !font_addr[12]) font[font_addr[11:0]] <= font_data;
    fr_q <= font[fr_addr];
end

// ============================================================ bus decode
// MDA: U51 (A19-A15 = 10110, MEMR or MEMW), no AEN in the memory decode.
// HGC: the upper 32 KB only with 3BF bit 1 and no CGA in the machine.
wire        sel_lo  = isa_addr[19:15] == 5'b10110;
wire        sel_hi  = HERC && isa_addr[19:15] == 5'b10111 && cfg[1] && !cga_fitted;
wire        sel_mem = sel_lo || sel_hi;
wire [VW-1:0] cpu_off;
generate
    if (HERC) begin : g_off_hgc
        assign cpu_off = {sel_hi, isa_addr[14:0]};
    end else begin : g_off_mda
        assign cpu_off = isa_addr[11:0];
    end
endgenerate
wire        mem_rd  = sel_mem && !isa_memr_n;
wire        mem_wr  = sel_mem && !isa_memw_n;
wire        mem_any = mem_rd || mem_wr;
// U52 (A9-A4 = 3Bx, AEN low), U43 (A3 low: the 6845), U50 (A3 high)
wire        sel_io  = !isa_aen && isa_addr[9:4] == 6'b111011;
wire        io_rd   = sel_io && !isa_ior_n;
wire        io_wr   = sel_io && !isa_iow_n;
wire        crtc_io = (io_rd || io_wr) && !isa_addr[3];

// I/O acts when the strobe ends (the 6845's E and the mode latch U58 are
// clocked by the end of the strobe).
logic       io_rd_q, io_wr_q;
logic [3:0] io_a;
logic [7:0] io_d;
wire        io_wr_end = io_wr_q && !io_wr;

assign crtc_wa  = io_wr_end && !io_a[3] && !io_a[0];
assign crtc_wd  = io_wr_end && !io_a[3] &&  io_a[0];
assign crtc_din = io_d;

// ============================================================ CPU access
// U4a (cap): the request sampled at the 4Q edge. U4b (ack): set at the CCLK
// falling edge after a capture, IOCHRDY high; both preset while there is no
// request. One access per request.
logic          cap, ack;
wire           req = mem_any || crtc_io;
assign isa_ready = !(req && !ack);
// the write (-WE, U6) in the CPU's CCLK-high half; done at its end
assign va_we     = ev_ack && cap && mem_wr;
assign va_addr   = cpu_off;
assign va_d      = isa_dout;

// ============================================================ display
// stage 1 (U31 attribute, U34 character): the RAM word at the 6845 address,
// latched when CCLK rises; stage 2 (U29/U30, the shift register U32): the
// character before it, shown during the next character period.
typedef struct packed {
    logic [7:0] chr;
    logic [7:0] att;
} s1_t;
typedef struct packed {
    logic [7:0] att;        // U30
    logic [7:0] glyph;      // U32 parallel load
    logic       serin;      // U29 4Q: the 9th dot
    logic       nod;        // U29 1Q: no display (fg 000, bg 000)
    logic       rvv;        // U29 2Q: reverse (fg 000, bg 111)
    logic       ul;         // U29 3Q: underline (fg 001, row 12)
    logic [15:0] word;      // HGC graphics: the two bytes
} s2_t;
s1_t s1;
s2_t s2;
logic [7:0] n_chr, n_att, n_glyph;      // fetched in the CCLK-low half
logic [2:0] fs;
logic       de1, de2, cur1, cur2, hs1, hs2, vs1;   // U55, U101 (HSYNC stretch)
logic [4:0] blink_cnt;                  // U28: cursor = bit 3, characters = bit 4

wire [7:0] att_in = m_en ? s1.att : 8'h00;          // U31 cleared by -VIDEO ENABLE
wire [2:0] fg_in  = att_in[2:0];
wire [2:0] bg_in  = att_in[6:4];
wire       box    = s1.chr[7:5] == 3'b110;          // C0-DF: 9th dot = 8th

// fetch addresses (after the CPU slot; the 6845 address is stable until CCLK rises)
wire [VW-1:0] a_chr, a_gfx;
generate
    if (HERC) begin : g_fa_hgc
        assign a_chr = {4'b0000, ma[10:0], 1'b0};
        assign a_gfx = {m_page, ra[1:0], ma[11:0], 1'b0};
    end else begin : g_fa_mda
        assign a_chr = {ma[10:0], 1'b0};
        assign a_gfx = {ma[10:0], 1'b0};
    end
endgenerate
always_comb
    case (fs)
        3'd1:    vb_addr = gfx_c ? a_gfx : a_chr;
        default: vb_addr = (gfx_c ? a_gfx : a_chr) | VW'(1);
    endcase
assign fr_addr = {ra[3], s1.chr, ra[2:0]};

// ============================================================ dots
wire        curs  = cur2 && blink_cnt[3];
wire        hide  = blink_cnt[4] && s2.att[7] && m_blink && !cur2;    // U62
wire        sdot  = ph < 4'd8 ? s2.glyph[3'd7 - ph[2:0]] : s2.serin;
wire        alpha = curs || ((sdot || s2.ul) && !s2.nod && !hide);     // +ALPHA DOTS
wire        d_vid = gfx_c ? m_en && s2.word[4'd15 - ph] : alpha ^ s2.rvv;
wire        d_int = gfx_c ? 1'b0 : alpha ? s2.att[3] : s2.att[7] && !m_blink;
logic       vq, iq;                     // U101: +VIDEO, one dot late

// ============================================================ status
wire [7:0] status = HERC ? {!vs1, 3'b000, vq, 2'b00, hs1 || hs2}
                         : {4'hF, vq, 2'b00, hs1 || hs2};

always_comb begin
    isa_dsel = 1'b0;
    isa_din  = 8'h00;
    if (mem_rd) begin
        isa_dsel = 1'b1;
        isa_din  = va_q;
    end else if (io_rd) begin
        if (!isa_addr[3]) begin
            isa_dsel = 1'b1;
            isa_din  = isa_addr[0] ? crtc_dout : 8'hFF;
        end else if (isa_addr[2:0] == 3'd2) begin
            isa_dsel = 1'b1;
            isa_din  = status;
        end
    end
end

// ============================================================ window
// position of the current dot: hpos 0 = the first dot of vid_hsync, vpos 0 =
// the line in which vid_vsync starts
logic [9:0] hpos_q;
logic [8:0] vpos_q;
logic       hs_prev, vs_prev;
wire        hs_out = (hs1 || hs2) && hs_ok;
wire        hs_st  = hs_out && !hs_prev;
wire [9:0]  hpos   = hs_st ? 10'd0 : hpos_q == 10'h3FF ? hpos_q : hpos_q + 10'd1;
wire [8:0]  vpos   = vs1 && !vs_prev ? 9'd0 : hs_st && vpos_q != 9'h1FF ? vpos_q + 9'd1 : vpos_q;

always_ff @(posedge clk) begin
    if (reset) begin
        mode <= 8'h00; cfg <= 2'b00; hs_ok <= 1'b0;
        ph <= 4'd0; gfx_c <= 1'b0;
        io_rd_q <= 1'b0; io_wr_q <= 1'b0;
        cap <= 1'b0; ack <= 1'b0;
        s1 <= '0; s2 <= '0; fs <= 3'd0;
        de1 <= 1'b0; de2 <= 1'b0; cur1 <= 1'b0; cur2 <= 1'b0;
        hs1 <= 1'b0; hs2 <= 1'b0; vs1 <= 1'b0;
        blink_cnt <= 5'd0;
        vq <= 1'b0; iq <= 1'b0;
        hpos_q <= 10'h3FF; vpos_q <= 9'h1FF; hs_prev <= 1'b0; vs_prev <= 1'b0;
    end else begin
        // ---------------------------------------------- CPU access
        if (!req) begin
            cap <= 1'b0;
            ack <= 1'b0;
        end else begin
            if (ev_cap && !ack) cap <= 1'b1;
            if (ev_ack && cap) begin
                ack <= 1'b1;
                cap <= 1'b0;
            end
        end

        // ---------------------------------------------- display fetch
        // after the CPU slot (CCLK low): character and attribute at the
        // 6845 address, the glyph row of the stage 1 character
        if (ev_ack) fs <= 3'd1;
        else if (fs != 3'd0) fs <= fs == 3'd3 ? 3'd0 : fs + 3'd1;
        if (fs == 3'd2) n_chr <= vb_q;
        if (fs == 3'd3) n_att <= vb_q;
        if (fs == 3'd2) n_glyph <= fr_q;

        // ---------------------------------------------- dot clock
        if (rise) begin
            ph <= ph_n;
            vq <= de2 && d_vid;
            iq <= de2 && d_int;
        end
        if (ev_e) begin
            gfx_c <= m_gfx;
            // U55: the 6845's outputs before it steps
            de1  <= de;    de2  <= de1;
            cur1 <= c_cur; cur2 <= cur1;
            hs1  <= c_hs;  hs2  <= hs1;
            vs1  <= c_vs;
            // U28: counts the end of each VSYNC
            if (vs1 && !c_vs) blink_cnt <= blink_cnt + 5'd1;
            // U29/U30/U32 from stage 1, decoded with the current row
            s2.att   <= att_in;
            s2.glyph <= n_glyph;
            s2.serin <= box && n_glyph[0];
            s2.nod   <= fg_in == 3'd0 && bg_in == 3'd0;
            s2.rvv   <= fg_in == 3'd0 && bg_in == 3'd7;
            s2.ul    <= fg_in == 3'd1 && ra[3:0] == 4'd12;
            s2.word  <= {s1.chr, s1.att};
            // U31/U34
            s1.chr <= n_chr;
            s1.att <= m_en ? n_att : 8'h00;
        end

        // ---------------------------------------------- window counters
        if (fall) begin
            hpos_q  <= hpos;
            vpos_q  <= vpos;
            hs_prev <= hs_out;
            vs_prev <= vs1;
        end

        // ---------------------------------------------- I/O
        io_rd_q <= io_rd;
        io_wr_q <= io_wr;
        if (io_rd || io_wr) begin
            io_a <= isa_addr[3:0];
            io_d <= isa_dout;
        end
        if (io_wr_end && io_a == 4'h8) begin
            // MDA: U58 keeps bits 0, 2, 3, 5. HGC: bit 1 only with 3BF bit
            // 0, bit 7 only with 3BF bit 1 (else they keep their value).
            mode <= {HERC && (cfg[1] ? io_d[7] : mode[7]), 1'b0, io_d[5], 1'b0,
                     io_d[3], io_d[2], HERC && (cfg[0] ? io_d[1] : mode[1]), io_d[0]};
            if (io_d[3]) hs_ok <= 1'b1;
        end
        if (HERC && io_wr_end && io_a == 4'hF) cfg <= io_d[1:0];
    end
end

assign vid_ce     = fall;
assign vid_video  = vq;
assign vid_intens = iq;
assign vid_hsync  = hs_out;
assign vid_vsync  = vs1;
assign vid_hblank = !(hpos >= 10'(AP_X) && hpos < 10'(AP_X + AP_W));
assign vid_vblank = !(vpos >= 9'(AP_Y) && vpos < 9'(AP_Y + AP_H));

endmodule
