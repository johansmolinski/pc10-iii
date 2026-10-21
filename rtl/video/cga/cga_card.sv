// cga_card.sv - IBM Color/Graphics Monitor Adapter on the pc10-iii card bus.
//
// Timing reference: MartyPC (MIT, (c) 2022-2026 Daniel Balsom),
// devices/cga/{mod,mmio,io,draw}.rs and devices/mc6845.rs at commit 05c0d08.
// The design and every deviation from MartyPC are in doc/cga.md.
//
// Clocking (doc/architecture.md section 1): everything on clk with the
// 14.31818 MHz enable ce_14m. The card advances its dot clock CE_DELAY clk
// after ce_14m (default 6 = one clk before the next ce_14m). The card's state
// for dot instant t is therefore complete one clk before the CPU-side edge
// of the same instant: what the board samples at a CPU clock edge (READY,
// read data) is the CGA as MartyPC sees it after "catching up" to that
// instant, and a strobe the board changes at that edge reaches the card after
// the update, as MartyPC applies an I/O access after catching up.
//
// Card bus (section 3): B8000-BFFFF (16 KB, mirrored at BC000), I/O A9-A4 =
// 3Dx with AEN low: 3D0-3D7 6845 (A0 = data), 3D8 mode, 3D9 colour, 3DA
// status, 3DB light pen latch clear, 3DC light pen latch set.
//
// Wait states (doc/cga.md section 4): a CPU memory access ends at the CGA's
// CPU slot, the instant at which the lchar phase becomes 14, and needs at
// least 9 ticks from MartyPC's phase reference (T3 start + 1 tick). This is
// MartyPC's WAIT_TABLE written as a rule. RD_LEAD/WR_LEAD = ticks from the
// card seeing MEMR/MEMW fall to that reference; the defaults fit xt_board.sv
// (MEMR from the CLK falling edge in T1, MEMW from the falling edge in T2).
//
// GPL-3.0-or-later, pc10-iii.

module cga_card #(
    parameter int CE_DELAY = 6,        // card dot tick = ce_14m delayed (clk)
    parameter int DC_RESET = 0,        // lchar phase after reset
    parameter int RD_LEAD  = 6,        // MEMR seen -> MartyPC phase reference (ticks)
    parameter int WR_LEAD  = 3,        // MEMW seen -> MartyPC phase reference (ticks)
    parameter bit SNOW     = 1'b1,     // 80-column snow
    // vid_hblank/vid_vblank window, counted from the start of vid_hsync
    // (dots) and vid_vsync (lines); default = MartyPC's "Full" aperture
    parameter int AP_X = 128,
    parameter int AP_W = 768,
    parameter int AP_Y = 17,
    parameter int AP_H = 245
) (
    input  logic        clk,           // 100.2273 MHz
    input  logic        reset,
    input  logic        ce_14m,

    // card bus
    input  logic [19:0] isa_addr,
    input  logic [7:0]  isa_dout,      // data from the CPU/DMA
    output logic [7:0]  isa_din,       // data to the CPU (0 when not selected)
    output logic        isa_dsel,      // the card drives isa_din
    input  logic        isa_memr_n,
    input  logic        isa_memw_n,
    input  logic        isa_ior_n,
    input  logic        isa_iow_n,
    input  logic        isa_aen,
    output logic        isa_ready,     // IOCHRDY

    // character ROM (8 KB, the layout of IBM's 5788005 ROM: the 8x8 font at
    // 0x1800, the thin 8x8 font at 0x1000; byte = char * 8 + row)
    input  logic        font_we,
    input  logic [12:0] font_addr,
    input  logic [7:0]  font_data,
    input  logic        font_thin,     // jumper P3: use the thin font

    // light pen
    input  logic        lpen_trig,     // rising edge latches the address
    input  logic        lpen_sw,       // 1 = switch pressed

    // video, one dot per ce_14m (outputs change 1 clk before ce_14m)
    output logic [3:0]  vid_rgbi,      // {I, R, G, B}
    output logic        vid_hsync,     // active high
    output logic        vid_vsync,     // active high
    output logic        vid_hblank,
    output logic        vid_vblank,

    // raw signals for a composite NTSC model (doc/cga.md section 7)
    output logic [1:0]  comp_cphase,   // colour carrier phase of this dot
    output logic        comp_hsync,    // the CGA's composite HSYNC (4 lchars)
    output logic        comp_vsync,    // the CGA's composite VSYNC (3 lines)
    output logic        comp_burst,    // colour burst gate
    output logic        comp_bw,       // mode bit 2: no burst
    output logic [5:0]  comp_mode      // effective mode register bits
);

// ============================================================ dot clock
logic [CE_DELAY-1:0] ce_sh;
always_ff @(posedge clk)
    ce_sh <= reset ? '0 : {ce_sh[CE_DELAY-2:0], ce_14m};
wire tick = ce_sh[CE_DELAY-1];

logic [3:0] dc;                         // lchar phase (MartyPC: cycles & 15)
logic       hclk;                       // 80-column character clock (divisor 1)
wire  [3:0] dn   = dc + 4'd1;           // phase after this tick
wire        drw  = hclk || !dn[0];      // this tick draws (lores: pairs)
wire        bnd  = hclk ? dn[2:0] == 3'd0 : dn == 4'd0;   // character boundary
wire        cclk = tick && bnd;

// ============================================================ registers
logic [5:0] mode_reg;                   // last written 3D8
logic [5:0] mode;                       // in effect
logic       mode_pend;                  // text <-> graphics, waits for HSYNC
logic [5:0] cc;                         // 3D9
wire  m_hires = mode[0];
wire  m_gfx   = mode[1];
wire  m_bw    = mode[2];
wire  m_en    = mode[3];
wire  m_640   = mode[4];
wire  m_blink = mode[5];

function automatic logic gfx_class(logic [5:0] m);
    return m[1] && !m[0];               // graphics bit without the 80-column bit
endfunction

// ============================================================ CRTC
logic        crtc_wa, crtc_wd, lp_strobe;
logic [7:0]  crtc_din, crtc_dout;
logic [13:0] ma;
logic [4:0]  ra, vsc;
logic        de, c_hs, c_vs, c_cur;

cga_crtc u_crtc (
    .clk       (clk),
    .reset     (reset),
    .cclk      (cclk),
    .wr_addr   (crtc_wa),
    .wr_data   (crtc_wd),
    .din       (crtc_din),
    .dout      (crtc_dout),
    .lp_strobe (lp_strobe),
    .ma        (ma),
    .ra        (ra),
    .de        (de),
    .hsync     (c_hs),
    .vsync     (c_vs),
    .cursor    (c_cur),
    .vsc       (vsc)
);

// ============================================================ memories
// Video RAM: 16 KB, port A for the CPU, port B for the display.
logic [7:0]  vram [16384];
logic [13:0] va_addr, vb_addr;
logic [7:0]  va_q, vb_q;
logic        va_we;
logic [7:0]  va_d;
always_ff @(posedge clk) begin
    if (va_we) vram[va_addr] <= va_d;
    va_q <= vram[va_addr];
end
always_ff @(posedge clk)
    vb_q <= vram[vb_addr];

// Character ROM: 8 KB, loaded by the glue.
logic [7:0]  font [8192];
logic [12:0] fr_addr;
logic [7:0]  fr_q;
always_ff @(posedge clk) begin
    if (font_we) font[font_addr] <= font_data;
    fr_q <= font[fr_addr];
end

// ============================================================ bus decode
wire        sel_mem = isa_addr[19:15] == 5'b10111;
wire        sel_io  = !isa_aen && isa_addr[9:4] == 6'b111101;
wire        mem_rd  = sel_mem && !isa_memr_n;
wire        mem_wr  = sel_mem && !isa_memw_n;
wire        io_rd   = sel_io && !isa_ior_n;
wire        io_wr   = sel_io && !isa_iow_n;

// I/O: address and data are held while the strobe is low, the access acts
// when it ends (MartyPC: at the end of the last T3/Tw).
logic       io_rd_q, io_wr_q;
logic [3:0] io_a;
logic [7:0] io_d;
wire        io_rd_end = io_rd_q && !io_rd;
wire        io_wr_end = io_wr_q && !io_wr;

// light pen
logic lp_latch, lp_trig_q;
wire  lp_set_ev = (lpen_trig && !lp_trig_q) ||
                  ((io_rd_end || io_wr_end) && io_a == 4'hC);
wire  lp_clr_ev = (io_rd_end || io_wr_end) && io_a == 4'hB;
assign lp_strobe = lp_set_ev && !lp_latch;

assign crtc_wa  = io_wr_end && !io_a[3] && !io_a[0];
assign crtc_wd  = io_wr_end && !io_a[3] &&  io_a[0];
assign crtc_din = io_d;

wire [7:0] status = {4'hF, c_vs, !lpen_sw, lp_latch, c_vs || !de};

always_comb begin
    isa_dsel = 1'b0;
    isa_din  = 8'h00;
    if (mem_rd) begin
        isa_dsel = 1'b1;
        isa_din  = va_q;
    end else if (sel_io && !isa_ior_n) begin
        if (!isa_addr[3]) begin
            isa_dsel = 1'b1;
            isa_din  = isa_addr[0] ? crtc_dout : 8'h00;
        end else if (isa_addr[2:0] <= 3'd4) begin
            isa_dsel = 1'b1;
            isa_din  = isa_addr[2:0] == 3'd2 ? status : 8'h00;
        end
    end
end

// ============================================================ CPU memory access
// The access waits for the CPU slot: the instant the lchar phase becomes 14,
// at least LEAD + 9 ticks after the strobe was seen (doc/cga.md section 4).
logic        acc, acc_done, acc_wr;
logic [4:0]  el;                        // ticks since the strobe was seen
logic [4:0]  lead;
logic [13:0] acc_a;
logic [7:0]  acc_d;
wire         mem_any   = mem_rd || mem_wr;
wire         slot      = acc && mem_any && dc == 4'd14 && el >= lead + 5'd9;
// a board that ends the strobe early (ignoring IOCHRDY) still gets its write
wire         acc_abort = acc && !mem_any;
assign       isa_ready = !(acc && mem_any && !slot);

// snow: the byte of the last CPU access replaces the next odd hchar's
// character and attribute in 80-column text mode
logic       snow_pend;
logic [7:0] snow_byte;

assign va_we   = acc_wr && (slot || acc_abort);
assign va_addr = va_we ? acc_a : isa_addr[13:0];
assign va_d    = acc_d;

// ============================================================ display fetch
// post: the clk after a character clock; the CRTC outputs are new.
logic       post, post_lclk;
logic [2:0] fs;                         // fetch step after post
logic       snow_use, blink_snap;
logic [7:0] chr, att, g0, g1, glyph;
logic       hs_q;                       // CRTC HSYNC at the previous character
// the mode as set_char_addr sees it: a pending change applies at HSYNC first
wire        hs_mode   = c_hs && !hs_q && mode_pend;
wire [5:0]  mode_char = hs_mode ? mode_reg : mode;

wire [13:0] a_txt = {ma[12:0], 1'b0};
wire [13:0] a_gfx = {ra[0], ma[11:0], 1'b0};
logic [13:0] a_txt_q, a_gfx_q;
logic [2:0]  ra_q;                      // glyph row, latched with the character
always_comb
    if (post) vb_addr = a_txt;
    else case (fs)
        3'd1:    vb_addr = a_txt_q | 14'd1;
        3'd2:    vb_addr = a_gfx_q;
        default: vb_addr = a_gfx_q | 14'd1;
    endcase
assign fr_addr = {1'b1, ~font_thin, chr, ra_q};      // 0x1800 / 0x1000

// card syncs (MartyPC calculate_blanking: at lchar boundaries)
logic card_hb, card_vb;
logic [3:0] blink_cnt;
logic cur_blink_on, txt_blink_on;

// ============================================================ dot logic
wire [3:0] fg   = att[3:0];
wire [3:0] bg   = blink_snap ? {1'b0, att[6:4]} : att[7:4];
wire       cbl  = blink_snap && att[7];
wire       curs = c_cur && cur_blink_on;
wire       boff = cbl && !txt_blink_on && !c_cur && m_blink;
wire [3:0] overscan = m_640 ? 4'h0 : cc[3:0];
wire [2:0] col  = hclk ? dc[2:0] : dc[3:1];          // dot / pair in the char
wire [15:0] word = {g0, g1};

function automatic logic [3:0] pal(logic [1:0] idx);
    logic [2:0] c;
    if (idx == 2'd0) return cc[3:0];
    if (m_bw && m_gfx && !m_640)
        c = idx == 2'd1 ? 3'd3 : idx == 2'd2 ? 3'd4 : 3'd7;   // red/cyan/white
    else if (cc[5])
        c = {idx, 1'b1};                                     // cyan/magenta/white
    else
        c = {idx, 1'b0};                                     // green/red/brown
    return {cc[4], c};
endfunction

logic [3:0] pa, pb;                     // dot dc-1 (lores only), dot dc
always_comb begin
    logic [3:0] t;
    t  = curs ? fg : !m_en ? 4'h0 : boff ? bg : glyph[3'd7 - col] ? fg : bg;
    pa = 4'h0;
    pb = 4'h0;
    if (de) begin
        if (!m_gfx) begin
            pa = t; pb = t;
        end else if (m_640) begin
            if (hclk) pb = (m_en && g0[3'd7 - col]) ? cc[3:0] : 4'h0;
            else begin
                pa = (m_en && word[4'd15 - {col, 1'b0}]) ? cc[3:0] : 4'h0;
                pb = (m_en && word[4'd14 - {col, 1'b0}]) ? cc[3:0] : 4'h0;
            end
        end else if (hclk)
            pb = overscan;
        else begin
            pa = m_en ? pal(word[4'd15 - {col, 1'b0} -: 2]) : cc[3:0];
            pb = pa;
        end
    end else if (!card_hb && !card_vb) begin
        pa = overscan; pb = overscan;
    end
end

// ============================================================ output pipeline
// Each tick outputs the dot two ticks back: hires dots are computed one at a
// time, lores pairs at the second dot (MartyPC draws a pair with the state
// at its end). A third stage adds the window counters.
typedef struct packed {
    logic [3:0] c;          // RGBI
    logic       h, v;       // card HSYNC/VSYNC (MartyPC in_card_hblank/vblank)
    logic       ch, cv, cb; // composite HSYNC, VSYNC, burst
    logic [1:0] p;          // colour carrier phase
} dot_t;
dot_t hold, out, fin;
logic [9:0] hpos;
logic [8:0] vpos;
logic [3:0] chs_cnt;                    // lchars since the CRTC HSYNC began
logic       cvs_trig;
logic [3:0] cvs_sh;
wire        d_ch = card_hb && chs_cnt >= 4'd2 && chs_cnt <= 4'd5;
wire        d_cv = cvs_sh[0] && !cvs_sh[3];
wire        d_cb = card_hb && !m_bw && !c_vs && (chs_cnt == 4'd7 || chs_cnt == 4'd8);

always_ff @(posedge clk) begin
    if (reset) begin
        dc        <= 4'(DC_RESET);
        hclk      <= 1'b0;
        mode_reg  <= 6'd0;
        mode      <= 6'd0;
        mode_pend <= 1'b0;
        cc        <= 6'h30;
        io_rd_q   <= 1'b0;
        io_wr_q   <= 1'b0;
        lp_latch  <= 1'b0;
        lp_trig_q <= 1'b0;
        acc       <= 1'b0;
        acc_done  <= 1'b0;
        acc_wr    <= 1'b0;
        el        <= 5'd0;
        lead      <= 5'd0;
        snow_pend <= 1'b0;
        post      <= 1'b0;
        post_lclk <= 1'b0;
        fs        <= 3'd7;
        snow_use  <= 1'b0;
        blink_snap <= 1'b0;
        hs_q      <= 1'b0;
        card_hb   <= 1'b0;
        card_vb   <= 1'b0;
        blink_cnt <= 4'd0;
        cur_blink_on <= 1'b0;
        txt_blink_on <= 1'b0;
        hold <= '0; out <= '0; fin <= '0;
        hpos <= 10'h3FF; vpos <= 9'h1FF;
        chs_cnt <= 4'd0; cvs_trig <= 1'b0; cvs_sh <= 4'd0;
    end else begin
        // ---------------------------------------------- dot tick
        if (tick) begin
            dc <= dn;
            if (hclk) begin
                out  <= hold;
                hold <= '{pb, card_hb, card_vb, d_ch, d_cv, d_cb, dc[1:0]};
            end else if (drw) begin
                out  <= '{pa, card_hb, card_vb, d_ch, d_cv, d_cb, dc[1:0] - 2'd1};
                hold <= '{pb, card_hb, card_vb, d_ch, d_cv, d_cb, dc[1:0]};
            end else
                out  <= hold;
            fin <= out;
            if (out.h && !fin.h) hpos <= 10'd0;
            else if (hpos != 10'h3FF) hpos <= hpos + 10'd1;
            if (out.v && !fin.v) vpos <= 9'd0;
            else if (out.h && !fin.h && vpos != 9'h1FF) vpos <= vpos + 9'd1;
        end
        post      <= cclk;
        post_lclk <= cclk && dn == 4'd0;

        // ---------------------------------------------- character clock done
        if (post) begin
            // MartyPC tick_crtc_char: a pending text/graphics change at HSYNC
            if (hs_mode) begin
                mode      <= mode_reg;
                mode_pend <= 1'b0;
            end
            hs_q <= c_hs;
            if (post_lclk) begin
                card_hb <= c_hs;
                card_vb <= c_vs && vsc < 5'd3;
                if (c_vs && vsc < 5'd3 && !card_vb) begin
                    // CGA blink counter, clocked by the vertical retrace
                    blink_cnt <= blink_cnt + 4'd1;
                    if (blink_cnt[2:0] == 3'd7) cur_blink_on <= !cur_blink_on;
                    if (blink_cnt == 4'd15)     txt_blink_on <= !txt_blink_on;
                end
            end
            // fetch: character, attribute, two graphics bytes, glyph row
            a_txt_q    <= a_txt;
            a_gfx_q    <= a_gfx;
            ra_q       <= ra[2:0];
            fs         <= 3'd1;
            blink_snap <= mode_char[5];
            snow_use   <= SNOW && snow_pend && dc == 4'd8 && mode_char[0];
            if (dc == 4'd8 || !mode_char[0]) snow_pend <= 1'b0;
        end else if (fs != 3'd7)
            fs <= fs + 3'd1;
        case (fs)
            3'd1: chr <= snow_use ? snow_byte : vb_q;
            3'd2: att <= snow_use ? snow_byte : vb_q;
            3'd3: g0  <= vb_q;
            3'd4: begin g1 <= vb_q; glyph <= fr_q; end
            default: ;
        endcase

        // the 80-column clock switches on lchar boundaries only
        if (dc == 4'd0 && !tick) hclk <= m_hires;

        // ---------------------------------------------- CPU memory access
        if (!mem_any) begin
            acc      <= 1'b0;
            acc_done <= 1'b0;
        end else if (!acc && !acc_done) begin
            acc    <= 1'b1;
            acc_wr <= mem_wr;
            acc_a  <= isa_addr[13:0];
            acc_d  <= isa_dout;
            lead   <= 5'(mem_wr ? WR_LEAD : RD_LEAD);
            el     <= 5'd0;
        end else if (tick && el != 5'd31)
            el <= el + 5'd1;
        if (slot) begin
            acc       <= 1'b0;
            acc_done  <= 1'b1;
            snow_pend <= 1'b1;
            snow_byte <= acc_wr ? acc_d : va_q;
        end

        // ---------------------------------------------- I/O
        io_rd_q   <= io_rd;
        io_wr_q   <= io_wr;
        lp_trig_q <= lpen_trig;
        if (io_rd || io_wr) begin
            io_a <= isa_addr[3:0];
            io_d <= isa_dout;
        end
        if (lp_set_ev) lp_latch <= 1'b1;
        if (lp_clr_ev) lp_latch <= 1'b0;
        if (io_wr_end && io_a == 4'h8) begin
            mode_reg <= io_d[5:0];
            if (gfx_class(io_d[5:0]) != gfx_class(mode_reg))
                mode_pend <= 1'b1;
            else begin
                mode <= io_d[5:0];
                if (dc == 4'd0) hclk <= io_d[0];
            end
        end
        if (io_wr_end && io_a == 4'h9) cc <= io_d[5:0];

        // ---------------------------------------------- composite sync counters
        if (post_lclk) begin
            if (!c_hs) chs_cnt <= 4'd0;
            else if (chs_cnt != 4'd15) chs_cnt <= chs_cnt + 4'd1;
            cvs_trig <= c_hs && chs_cnt == 4'd1;
        end else
            cvs_trig <= 1'b0;
        if (cvs_trig) cvs_sh <= c_vs ? {cvs_sh[2:0], 1'b1} : 4'd0;
    end
end

assign vid_rgbi   = fin.c;
assign vid_hsync  = fin.h;
assign vid_vsync  = fin.v;
assign vid_hblank = !(hpos >= 10'(AP_X) && hpos < 10'(AP_X + AP_W));
assign vid_vblank = !(vpos >= 9'(AP_Y) && vpos < 9'(AP_Y + AP_H));

assign comp_cphase = fin.p;
assign comp_hsync  = fin.ch;
assign comp_vsync  = fin.cv;
assign comp_burst  = fin.cb;
assign comp_bw     = m_bw;
assign comp_mode   = mode;

endmodule
