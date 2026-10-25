// pvc4.sv - the Paradise PVC4 (Western Digital "Paradise Video Controller"),
// the Commodore PC10-III's onboard video, on the pc10-iii card bus.
//
// The chip, its registers, the PC10-III's wiring and every assumption are in
// doc/pvc4.md. Sources: the PVC4 data sheet (Paradise Systems 1987-1989), the
// PC10-III service manual (chapters 2.2, 5, 6 and the video schematic, sheet
// 9-6 "PC10/CR VIDEO", 312626). The display logic of the two personalities is
// taken from this repository's IBM cards, because the PVC4 claims "100% IBM
// CGA and MDA compatibility" and the data sheet does not describe its display
// pipeline: the colour personality is cga_card.sv's (MartyPC's CGA), the mono
// personality mda_card.sv's (IBM's MDA logic diagrams, plus the Hercules
// mode). What is the PVC4's own:
//   - one 6845-compatible CRTC (cga_crtc.sv) for both personalities: R8 does
//     not exist (non-interlace only), R10 has only the on/off bit 5, a locked
//     CRTC (Paradise register bit 1) ignores R0-R11 and takes R11 as the
//     underline scan line;
//   - I/O at 3Bx or 3Dx after the Paradise register's bit 7 (power-up straps
//     on MA7-0, the Configuration register's on MD7-0, both writable after
//     the unlock sequence: two reads of 3X8, then the write to 3XA/3XB);
//   - 64 KB of video RAM (one bank of 64K x 8 on the PC10-III), the
//     Plantronics ColorPlus register 3DD and modes, the Hercules register 3BF,
//     the AT&T register 3DE (stored; its font select drives CA13), the mode
//     register readable at 3X8, the PVC4 status bits;
//   - no snow: the CPU has its own part of every memory sequence (data sheet,
//     "Sequence diagrams": CPU read/write, then the display's page-mode read);
//     IOCHRDY (READY) goes low on the strobe and high when the CPU part of the
//     next sequence has done the access (section 4 of doc/pvc4.md);
//   - "flicker override": with Paradise register bit 2 = 0 (the PC10-III's
//     strap) the mode register's video enable bit reads as 1 to the display;
//   - the clocks: CLOCK0 = the board's OSC (14.31818 MHz, ce_14m) for the
//     colour personality, CLOCK1 = CLOCK2 = the 16.257 MHz oscillator for the
//     mono personality (a fractional accumulator as in mda_card.sv); mode
//     register bit 0 = 0 (and Paradise bit 0 = 0) divides the mono clock by 2;
//   - the character generator ROM (the PC10-III's 27256, 32 KB) as a RAM
//     loaded through the font port, addressed as the board wires it:
//     A14 = DIP switch 1, A13 = CA13, A12 = character bit 7, A11 = NOT DIP
//     switch 2 (mono/colour), A10-A4 = character bits 6-0, A3-A0 = row. With
//     font_cbm = 0 the RAM holds an IBM 5788005 image instead (8 KB at
//     0x0000-0x1FFF, the free default font of the shell) and is addressed as
//     the IBM cards do.
//
// Clocking (doc/architecture.md section 1): everything on clk (28.63636 MHz).
// The colour personality ticks CE_DELAY clk after ce_14m like cga_card.sv;
// the mono personality on the edges of its accumulator like mda_card.sv.
//
// GPL-3.0-or-later, pc10-iii.

module pvc4 #(
    parameter int CE_DELAY = 1,         // colour dot tick = ce_14m delayed (clk)
    parameter int DC_RESET = 0,         // colour lchar phase after reset
    // CLOCK1/CLOCK2 = M_INC / M_MOD x clk (16.257 MHz: 59609 / 105000)
    parameter int M_INC = 59609,
    parameter int M_MOD = 105000,
    // the CPU part of a memory sequence, in video clocks (data sheet:
    // RAS precharge, row, column, CAS; 5 T in the sequence diagrams)
    parameter int CPU_T = 5,
    // display windows (vid_hblank/vid_vblank), as the IBM cards
    parameter int AP_X = 128, parameter int AP_W = 768,
    parameter int AP_Y = 17,  parameter int AP_H = 245,
    parameter int MP_X = 144, parameter int MP_W = 738,
    parameter int MP_Y = 16,  parameter int MP_H = 354
) (
    input  logic        clk,            // 28.63636 MHz
    input  logic        reset,          // RESET (system reset): the straps are sampled
    input  logic        ce_14m,         // CLOCK0 (OSC)

    // card bus
    input  logic [19:0] isa_addr,
    input  logic [19:0] isa_addr_next,
    input  logic        isa_memr_n_next,
    input  logic        isa_memw_n_next,
    input  logic        isa_aen_next,
    input  logic        isa_ior_n_next,
    input  logic        isa_iow_n_next,
    input  logic [7:0]  isa_dout,
    output logic [7:0]  isa_din,
    output logic        isa_dsel,
    input  logic        isa_memr_n,
    input  logic        isa_memw_n,
    input  logic        isa_ior_n,
    input  logic        isa_iow_n,
    input  logic        isa_aen,
    output logic        isa_ready,      // READY -> IOCHRDY

    // the board
    input  logic        enable,         // the data buffer U604 and READY are on (230h venb' = 0)
    input  logic [7:0]  par_strap,      // pull-ups/downs on MA7-MA0 (Paradise register)
    input  logic [7:0]  cnf_strap,      // pull-ups/downs on MD7-MD0 (Configuration register)
    input  logic        cg_a14,         // character ROM A14 (PC10-III: DIP switch 1, 1 = off)
    input  logic        cg_a11,         // character ROM A11 (PC10-III: NOT DIP switch 2 = 1 colour)

    // character generator ROM load port
    input  logic        font_we,
    input  logic [14:0] font_addr,
    input  logic [7:0]  font_data,
    input  logic        font_cbm,       // 1: Commodore layout (32 KB); 0: IBM 5788005 (8 KB)

    // light pen (LPNSTN, LPNSWN)
    input  logic        lpen_trig,      // rising edge sets the latch
    input  logic        lpen_sw,        // 1 = switch pressed

    // video: one dot per vid_ce. Colour personality: vid_ce = ce_14m, RGBI;
    // mono personality: vid_ce on the 16.257 MHz falling edge, vid_mono =
    // MONO (video), vid_rgbi = {IT, MONO, MONO, MONO}
    output logic        vid_ce,
    output logic [3:0]  vid_rgbi,       // {I, R, G, B}
    output logic        vid_mono,       // MONO (mono personality)
    output logic        vid_hsync,      // active high
    output logic        vid_vsync,      // active high
    output logic        vid_hblank,
    output logic        vid_vblank,
    output logic        vid_monomode    // the mono personality (Paradise register bit 7)
);

// ============================================================ configuration
logic [7:0] par, cnf;                   // Paradise register 3XB, Configuration register 3XA
logic [7:0] mr;                         // mode register 3X8 (as written, read back)
logic [6:0] pl;                         // Plantronics 3DD (bits 6-4)
logic [7:0] att_r;                      // AT&T / M24 register 3DE
logic [1:0] hgc;                        // Hercules register 3BF
logic [4:0] ul_row;                     // underline scan line (R11 while the CRTC is locked)
logic [1:0] ulk;                        // unlock: reads of 3X8 in succession

wire mono    = par[7];                  // monochrome I/O mapping and clock
wire en_eff  = mr[3] || !par[2];        // flicker override: video enable forced on
wire lock_c  = par[1];                  // CRTC R0-R11 write protected
wire force80 = par[0];                  // 80-column character clock forced
wire ext_on  = !par[3];                 // Plantronics and AT&T registers enabled
wire bdr_on  = cnf[2];                  // border (overscan) colour enabled
wire ca13    = ext_on && att_r[2];      // AT&T set select -> CA13
wire c9dot   = par[5];                  // 9-dot alpha characters

// ============================================================ colour dot clock
logic [CE_DELAY-1:0] ce_sh;
generate if (CE_DELAY == 1) begin : g_ce1
    always_ff @(posedge clk) ce_sh <= reset ? '0 : ce_14m;
end else begin : g_cen
    always_ff @(posedge clk) ce_sh <= reset ? '0 : {ce_sh[CE_DELAY-2:0], ce_14m};
end endgenerate
wire tick = ce_sh[CE_DELAY-1];

// ============================================================ mono dot clock
localparam int MAW   = $clog2(M_MOD) + 1;
localparam int MHALF = M_MOD / 2;
logic [MAW-1:0] macc;
wire  [MAW-1:0] macc_n   = macc + MAW'(M_INC);
wire            osc_rise = macc_n >= MAW'(M_MOD);
logic           mfall_pend;
wire            osc_fall = (macc < MAW'(MHALF) && macc_n >= MAW'(MHALF)) || mfall_pend;
logic           mdiv;                   // /2: the next oscillator rise is a falling dot edge
wire            m_hires = mr[0] || force80;
// undivided: the oscillator's edges; divided by 2 (40-column, mode bit 0 = 0):
// every second oscillator rise is a rising dot edge, the others falling ones
wire            rise = m_hires ? osc_rise : osc_rise && !mdiv;
wire            fall = m_hires ? osc_fall : osc_rise && mdiv;
always_ff @(posedge clk)
    if (reset) begin
        macc <= '0; mfall_pend <= 1'b0; mdiv <= 1'b0;
    end else begin
        macc       <= osc_rise ? macc_n - MAW'(M_MOD) : macc_n;
        mfall_pend <= macc_n >= MAW'(M_MOD + MHALF);
        if (osc_rise) mdiv <= m_hires ? 1'b0 : !mdiv;
    end

// ============================================================ colour sequencer (cga_card)
logic [3:0] dc;                         // lchar phase
logic       hclk;                       // 80-column character clock
wire  [3:0] dn   = dc + 4'd1;
wire        drw  = hclk || !dn[0];
wire        bnd  = hclk ? dn[2:0] == 3'd0 : dn == 4'd0;
wire        c_cclk = tick && bnd && !mono;

// ============================================================ mono character counter (mda_card)
logic [3:0] ph;
logic       gfx_c;                      // 16-dot characters (Hercules graphics)
logic       w9;                         // 9-dot characters
logic       cpar;                       // character parity: a memory sequence is two characters
wire  [3:0] last = gfx_c ? 4'd15 : w9 ? 4'd8 : 4'd7;
wire  [3:0] ph_n = ph >= last ? 4'd0 : ph + 4'd1;
wire        ev_e = rise && ph_n == 4'd0 && mono;      // CCLK rises: the 6845 steps
wire        ev_f = fall && ph == 4'd4 && mono;         // CCLK falls: the display read

// ============================================================ CRTC
logic        crtc_wa, crtc_wd, lp_strobe;
logic [7:0]  crtc_din, crtc_dout;
logic [13:0] ma;
logic [4:0]  ra, vsc;
logic        de, c_hs, c_vs, c_cur;
logic [4:0]  crtc_sel;                  // shadow of the CRTC's address register

cga_crtc u_crtc (
    .clk       (clk),
    .reset     (reset),
    .cclk      (mono ? ev_e : c_cclk),
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
// Video RAM: 64 KB as two 32 KB banks split by A14, so the display reads a
// byte of both Plantronics planes (A14 = 0/1) in one clk. Port A: the CPU,
// port B: the display (A15, A13-A0, both banks).
logic [7:0]  vram0 [32768];             // A14 = 0
logic [7:0]  vram1 [32768];             // A14 = 1
logic [15:0] va_addr;
logic [14:0] vb_addr;
logic [7:0]  va_q0, va_q1, vb_q0, vb_q1;
logic        va_we;
wire  [14:0] va_a15 = {va_addr[15], va_addr[13:0]};
always_ff @(posedge clk) begin
    if (va_we && !va_addr[14]) vram0[va_a15] <= isa_dout;
    if (va_we &&  va_addr[14]) vram1[va_a15] <= isa_dout;
    va_q0 <= vram0[va_a15];
    va_q1 <= vram1[va_a15];
end
logic        va_a14_q;
always_ff @(posedge clk) va_a14_q <= va_addr[14];
wire  [7:0]  va_q = va_a14_q ? va_q1 : va_q0;
always_ff @(posedge clk) begin
    vb_q0 <= vram0[vb_addr];
    vb_q1 <= vram1[vb_addr];
end

// Character generator ROM (32 KB)
logic [7:0]  font [32768];
logic [14:0] fr_addr;
logic [7:0]  fr_q;
always_ff @(posedge clk) begin
    if (font_we) font[font_addr] <= font_data;
    fr_q <= font[fr_addr];
end

// ============================================================ bus decode
// the strobes reach the chip only while the board enables it (230h venb')
wire        memr  = enable && !isa_memr_n;
wire        memw  = enable && !isa_memw_n;
wire        ior   = enable && !isa_ior_n && !isa_aen;
wire        iow   = enable && !isa_iow_n && !isa_aen;

// memory: colour B8000-BFFFF (16 KB, mirrored; 32 KB in the Plantronics
// modes, 3DD bit 6 swaps the planes); mono B0000-B7FFF, B8000-BFFFF with
// 3BF bit 1. Physical address: B0000 + offset (colour at 0x8000).
wire        pl_on = pl[5] || pl[4];
function automatic logic [16:0] mem_map(logic [19:0] a, logic mo, logic [1:0] hg, logic plo, logic sw, logic gr);
    // {selected, physical address}
    if (mo) begin
        if (a[19:15] == 5'b10110) return {1'b1, 1'b0, a[14:0]};
        if (a[19:15] == 5'b10111 && hg[1]) return {1'b1, 1'b1, a[14:0]};
        return '0;
    end
    if (a[19:15] == 5'b10111)
        return {1'b1, 1'b1, plo ? a[14] ^ (sw && gr) : 1'b0, a[13:0]};
    return '0;
endfunction
wire [16:0] mm      = mem_map(isa_addr, mono, hgc, pl_on, pl[6], mr[1]);
wire [16:0] mm_nx   = mem_map(isa_addr_next, mono, hgc, pl_on, pl[6], mr[1]);
wire        sel_mem = mm[16];
wire        mem_rd  = sel_mem && memr;
wire        mem_wr  = sel_mem && memw;
wire        mem_any = mem_rd || mem_wr;
assign      va_addr = mm[15:0];

// I/O: 3Bx (mono) or 3Dx (colour), A9-A4, AEN low
wire        sel_io = isa_addr[9:4] == (mono ? 6'h3B : 6'h3D);
wire        io_rd  = sel_io && ior;
wire        io_wr  = sel_io && iow;
// the access acts in the strobe's last clk (the bus's next-clk values), as
// in cga_card.sv
wire        any_io    = ior || iow;
wire        io_nx     = enable && !isa_aen_next && (!isa_ior_n_next || !isa_iow_n_next) &&
                        isa_addr_next[9:0] == isa_addr[9:0];
wire        any_end   = any_io && !io_nx;
wire        io_rd_end = io_rd && any_end;
wire        io_wr_end = io_wr && any_end;
wire [3:0]  io_a = isa_addr[3:0];
wire [7:0]  io_d = isa_dout;

// light pen: colour 3DC sets, 3DB clears; mono 3B9 sets, 3BB clears (3XB
// only while it is locked: an unlocked write goes to the Paradise register)
logic lp_latch, lp_trig_q;
wire  wr_par  = io_wr_end && io_a == 4'hB && ulk == 2'd2;
wire  wr_cnf  = io_wr_end && io_a == 4'hA && ulk == 2'd2;
wire  wr_mr   = io_wr_end && io_a == 4'h8;
// the mode register as written (Hercules: bit 1 only with 3BF bit 0, bit 7
// only with 3BF bit 1; in the colour mapping 3BF is clear: bit 7 cannot be set)
wire [7:0] mr_wd  = {io_d[7] && hgc[1], 1'b0, io_d[5:2], io_d[1] && (hgc[0] || !mono), io_d[0]};
wire [7:0] mr_nx  = wr_mr ? mr_wd : mr;
wire [7:0] par_nx = wr_par ? io_d : par;
wire  lp_set_ev = (lpen_trig && !lp_trig_q) ||
                  ((io_rd_end || io_wr_end) && io_a == (mono ? 4'h9 : 4'hC));
wire  lp_clr_ev = (io_rd_end || io_wr_end) && io_a == 4'hB && !wr_par;
assign lp_strobe = lp_set_ev && !lp_latch;

// CRTC: R8 does not exist, R10 has only bit 5 (on/off), the lock
wire        crtc_data_wr = io_wr_end && !io_a[3] && io_a[0];
wire        crtc_locked  = lock_c && crtc_sel <= 5'd11;
assign crtc_wa  = io_wr_end && !io_a[3] && !io_a[0];
assign crtc_wd  = crtc_data_wr && !crtc_locked;
assign crtc_din = crtc_sel == 5'd8  && !crtc_wa ? 8'h00 :
                  crtc_sel == 5'd10 && !crtc_wa ? {2'b00, io_d[5:0]} : io_d;

// ============================================================ display: colour (cga_card)
logic [5:0] mode;                       // in effect (text <-> graphics deferred to HSYNC)
logic       mode_pend;
logic [5:0] cc;                         // 3D9
wire  [5:0] mode_reg = mr[5:0];
function automatic logic gfx_class(logic [5:0] m);
    return m[1] && !m[0];
endfunction

logic       post, post_lclk;
logic [2:0] fs;
logic       blink_snap;
logic [7:0] chr, att, g0, g1, h0, h1, glyph;
logic       hs_q;
wire        hs_mode   = c_hs && !hs_q && mode_pend;
wire [5:0]  mode_char = hs_mode ? mode_reg : mode;

wire [13:0] a_txt = {ma[12:0], 1'b0};
wire [13:0] a_gfx = {ra[0], ma[11:0], 1'b0};
logic [13:0] a_txt_q, a_gfx_q;
logic [3:0]  ra_q;
// colour: A15 = 1 (B8000); bank 0 holds plane 0 and the CGA's 16 KB
logic [14:0] vb_c;
always_comb
    if (post) vb_c = {1'b1, a_txt};
    else case (fs)
        3'd1:    vb_c = {1'b1, a_txt_q | 14'd1};
        3'd2:    vb_c = {1'b1, a_gfx_q};
        default: vb_c = {1'b1, a_gfx_q | 14'd1};
    endcase

logic card_hb, card_vb;
logic [3:0] blink_cnt;
logic cur_blink_on, txt_blink_on;

localparam int DLY = 3;
typedef struct packed {
    logic       de, cur;
    logic [5:0] mode, cc;
    logic [2:0] pl;                     // Plantronics bits 6-4 (bits 5-4 used)
    logic       bdr;                    // border enabled
    logic       hb, vb;
    logic       cbo, tbo;
    logic [3:0] dc;
    logic       hclk, drw, bnd;
} dly_t;
dly_t dl [DLY];
dly_t r;
assign r = dl[DLY-1];
logic [7:0] att_d, glyph_d, g0_d, g1_d, h0_d, h1_d;
logic       blink_d;

wire       r_en   = r.mode[3];
wire       r_gfx  = r.mode[1];
wire       r_bw   = r.mode[2];
wire       r_640  = r.mode[4];
wire       r_blk  = r.mode[5];
wire       r_p320 = r.pl[0];            // 3DD bit 4: 320x200x16 (overrides bit 5)
wire       r_p640 = r.pl[1] && !r.pl[0];// 3DD bit 5: 640x200x4
wire [3:0] fg   = att_d[3:0];
wire [3:0] bg   = blink_d ? {1'b0, att_d[6:4]} : att_d[7:4];
wire       cbl  = blink_d && att_d[7];
wire       curs = r.cur && r.cbo;
wire       boff = cbl && !r.tbo && !r.cur && r_blk;
wire [3:0] overscan = !r.bdr ? 4'h0 : (r_640 && !(r_p320 || r_p640)) ? 4'h0 : r.cc[3:0];
wire [2:0] col  = r.hclk ? r.dc[2:0] : r.dc[3:1];
wire [15:0] word  = {g0_d, g1_d};
wire [15:0] word1 = {h0_d, h1_d};

function automatic logic [3:0] pal(logic [1:0] idx, logic [5:0] cr, logic bw, logic gfx, logic m640);
    logic [2:0] c;
    if (idx == 2'd0) return cr[3:0];
    if (bw && gfx && !m640)
        c = idx == 2'd1 ? 3'd3 : idx == 2'd2 ? 3'd4 : 3'd7;
    else if (cr[5])
        c = {idx, 1'b1};
    else
        c = {idx, 1'b0};
    return {cr[4], c};
endfunction
// Plantronics 640x200x4: the 320x200 palette (86Box vid_cga_colorplus.c)
function automatic logic [3:0] pal4(logic [1:0] idx, logic [5:0] cr, logic bw);
    logic [2:0] c;
    if (idx == 2'd0) return cr[3:0];
    if (bw)         c = idx == 2'd1 ? 3'd3 : idx == 2'd2 ? 3'd4 : 3'd7;
    else if (cr[5]) c = {idx, 1'b1};
    else            c = {idx, 1'b0};
    return {cr[4], c};
endfunction
// Plantronics 320x200x16: plane 0 gives c1 c0, plane 1 c3 c2; c2 = I,
// c1 = R, c0 = G, c3 = B (PC10-III manual 6-6)
function automatic logic [3:0] pal16(logic [1:0] p0, logic [1:0] p1);
    return {p1[0], p0[1], p0[0], p1[1]};
endfunction

logic [3:0] pa, pb;
always_comb begin
    logic [3:0] t;
    logic [3:0] bit_a, bit_b;
    t  = curs ? fg : !r_en ? 4'h0 : boff ? bg : glyph_d[3'd7 - col] ? fg : bg;
    pa = 4'h0;
    pb = 4'h0;
    bit_a = 4'd15 - {col, 1'b0};
    bit_b = 4'd14 - {col, 1'b0};
    if (r.de) begin
        if (!r_gfx) begin
            pa = t; pb = t;
        end else if (r_p320) begin
            if (r.hclk) pb = overscan;
            else begin
                pa = r_en ? pal16({word[bit_a], word[bit_b]}, {word1[bit_a], word1[bit_b]})
                          : (r_640 ? 4'h0 : r.cc[3:0]);
                pb = pa;
            end
        end else if (r_p640) begin
            if (r.hclk) pb = r_en ? pal4({h0_d[3'd7 - col], g0_d[3'd7 - col]}, r.cc, r_bw) : 4'h0;
            else begin
                pa = r_en ? pal4({word1[bit_a], word[bit_a]}, r.cc, r_bw) : 4'h0;
                pb = r_en ? pal4({word1[bit_b], word[bit_b]}, r.cc, r_bw) : 4'h0;
            end
        end else if (r_640) begin
            if (r.hclk) pb = (r_en && g0_d[3'd7 - col]) ? r.cc[3:0] : 4'h0;
            else begin
                pa = (r_en && word[bit_a]) ? r.cc[3:0] : 4'h0;
                pb = (r_en && word[bit_b]) ? r.cc[3:0] : 4'h0;
            end
        end else if (r.hclk)
            pb = overscan;
        else begin
            pa = r_en ? pal(word[bit_a -: 2], r.cc, r_bw, r_gfx, r_640) : r.cc[3:0];
            pb = pa;
        end
    end else if (!r.hb && !r.vb) begin
        pa = overscan; pb = overscan;
    end
end

typedef struct packed {
    logic [3:0] c;
    logic       h, v;
} dot_t;
dot_t hold, cout, fin;
logic [9:0] hpos;
logic [8:0] vpos;
wire  [5:0] mode_now = {mode[5:4], mode[3] || !par[2], mode[2:0]};
wire dly_t  now = '{de, c_cur, mode_now, cc, pl[6:4], bdr_on, card_hb, card_vb,
                    cur_blink_on, txt_blink_on, dc, hclk, drw, bnd};

// ============================================================ display: mono (mda_card)
typedef struct packed {
    logic [7:0] chr;
    logic [7:0] att;
} s1_t;
typedef struct packed {
    logic [7:0] att;
    logic [7:0] glyph;
    logic       serin;
    logic       nod;
    logic       rvv;
    logic       ul;
    logic [15:0] word;
} s2_t;
s1_t s1;
s2_t s2;
logic [7:0] n_chr, n_att, n_glyph;
logic [2:0] mfs;
logic       de1, de2, cur1, cur2, hs1, hs2, vs1;
logic [4:0] mblink;
wire        m_gfx  = mr[1] && hgc[0];
wire        m_page = mr[7] && hgc[1];
wire        m_blink = mr[5];
wire [7:0]  matt_in = en_eff ? s1.att : 8'h00;
wire [2:0]  mfg_in  = matt_in[2:0];
wire [2:0]  mbg_in  = matt_in[6:4];
wire        box     = s1.chr[7:5] == 3'b110;
wire [14:0] a_mchr  = {1'b0, ma[12:0], 1'b0};
wire [14:0] a_mgfx  = {m_page, ra[0], ma[11:0], 1'b0};         // A14 = ra[1]: the bank
logic       mbank;                                             // bank of the mono fetch
logic [14:0] mf_a;                                             // its address, taken at ev_f
wire [14:0] vb_m    = mfs == 3'd1 ? mf_a : mf_a | 15'd1;
assign vb_addr = mono ? vb_m : vb_c;
wire [7:0]  vb_mq   = mbank ? vb_q1 : vb_q0;

wire        mcurs = cur2 && mblink[3];
wire        mhide = mblink[4] && s2.att[7] && m_blink && !cur2;
wire        sdot  = ph < 4'd8 ? s2.glyph[3'd7 - ph[2:0]] : s2.serin;
wire        alpha = mcurs || ((sdot || s2.ul) && !s2.nod && !mhide);
wire        d_vid = gfx_c ? en_eff && s2.word[4'd15 - ph] : alpha ^ s2.rvv;
wire        d_int = gfx_c ? 1'b0 : alpha ? s2.att[3] : s2.att[7] && !m_blink;
logic       vq, iq;

logic [9:0] mhpos_q;
logic [8:0] mvpos_q;
logic       mhs_prev, mvs_prev;
wire        mhs_out = hs1 || hs2;
wire        mhs_st  = mhs_out && !mhs_prev;
wire [9:0]  mhpos   = mhs_st ? 10'd0 : mhpos_q == 10'h3FF ? mhpos_q : mhpos_q + 10'd1;
wire [8:0]  mvpos   = vs1 && !mvs_prev ? 9'd0 : mhs_st && mvpos_q != 9'h1FF ? mvpos_q + 9'd1 : mvpos_q;

// font addresses
function automatic logic [14:0] cg_addr(logic cbm, logic a14, logic a13, logic a11, logic [7:0] ch,
                                        logic [3:0] row, logic monoro);
    if (cbm) return {a14, a13, ch[7], a11, ch[6:0], row};
    // IBM 5788005: the MDA font at 0x0000 (rows 8-15 at 0x0800), the CGA 8x8 at 0x1800
    if (monoro) return {2'b00, 1'b0, row[3], ch, row[2:0]};
    return {2'b00, 2'b11, ch, row[2:0]};
endfunction
assign fr_addr = mono ? cg_addr(font_cbm, cg_a14, ca13, cg_a11, s1.chr, ra[3:0], 1'b1)
                      : cg_addr(font_cbm, cg_a14, ca13, cg_a11, chr, ra_q, 1'b0);

// ============================================================ status, read data
wire [7:0] c_status = {3'b111, cnf[6], c_vs, !lpen_sw, lp_latch, c_vs || !de};
wire [7:0] m_status = {!vs1, 2'b11, cnf[6], vq, !lpen_sw, lp_latch, hs1 || hs2};

always_comb begin
    isa_dsel = 1'b0;
    isa_din  = 8'h00;
    if (mem_rd) begin
        isa_dsel = 1'b1;
        isa_din  = va_q;
    end else if (io_rd) begin
        if (!io_a[3] && io_a[0]) begin
            isa_dsel = 1'b1;
            isa_din  = crtc_dout;
        end else if (io_a == 4'h8) begin
            isa_dsel = 1'b1;
            isa_din  = mr;
        end else if (io_a == 4'hA) begin
            isa_dsel = 1'b1;
            isa_din  = mono ? m_status : c_status;
        end
    end
end

// ============================================================ CPU memory access
// The PVC4's memory sequence: the CPU part (CPU_T video clocks), then the
// display's page-mode read; one sequence per 16 colour dots (an lchar), per
// two characters in the mono personality (one Hercules graphics character).
// The request (MEMR/MEMW decoded) is synchronised on the video clock; a
// sequence that starts with it seen serves it: the access is done at the
// end of the CPU part, and READY goes high (doc/pvc4.md section 4). READY
// goes low as soon as the strobe is there (data sheet: 30 ns).
wire   vtick     = mono ? rise : tick;
wire   seq_start = mono ? ev_e && (gfx_c ? 1'b1 : !cpar) : tick && dn == 4'd0;
logic  req_s, busy, done;
logic [3:0] cpu_cnt;
logic  mem_any_q;
always_ff @(posedge clk)
    mem_any_q <= mm_nx[16] && enable && (!isa_memr_n_next || !isa_memw_n_next);
assign isa_ready = !(mem_any_q && !done);
wire   cpu_do = busy && vtick && cpu_cnt == 4'(CPU_T - 1);
assign va_we  = cpu_do && mem_wr;
`ifndef SYNTHESIS
// a CPU strobe is held until READY was seen; only a DMA transfer while the CPU
// waits (AEN takes the command away) ends one early (doc/pvc4.md section 4)
logic mem_wr_q, wr_done;
always_ff @(posedge clk) begin
    if (!reset && mem_any_q !== mem_any)
        $fatal(1, "pvc4: registered memory select differs from the bus");
    mem_wr_q <= mem_wr;
    if (reset || !mem_wr) wr_done <= 1'b0;
    if (va_we) wr_done <= 1'b1;
    if (!reset && mem_wr_q && !mem_wr && !wr_done && !isa_aen)
        $fatal(1, "pvc4: memory write strobe ended before the CPU part (write lost)");
end
`endif

// ============================================================ I/O end check (simulation)
`ifndef SYNTHESIS
logic any_q, any_end_q;
always_ff @(posedge clk) begin
    any_q <= any_io; any_end_q <= any_end;
    if (!reset && any_end_q != (any_q && !any_io))
        $fatal(1, "pvc4: I/O end from the next-clk bus mispredicted");
end
`endif

// ============================================================ sequential
always_ff @(posedge clk) begin
    if (reset) begin
        par <= par_strap; cnf <= cnf_strap;
        mr <= 8'h00; pl <= '0; att_r <= 8'h00; hgc <= 2'b00;
        ul_row <= 5'd12; ulk <= 2'd0; crtc_sel <= 5'd0;
        cc <= 6'h00;
        lp_latch <= 1'b0; lp_trig_q <= 1'b0;
        req_s <= 1'b0; busy <= 1'b0; done <= 1'b0; cpu_cnt <= 4'd0;
        // colour
        dc <= 4'(DC_RESET); hclk <= 1'b0;
        mode <= 6'd0; mode_pend <= 1'b0;
        post <= 1'b0; post_lclk <= 1'b0; fs <= 3'd7; blink_snap <= 1'b0;
        hs_q <= 1'b0; card_hb <= 1'b0; card_vb <= 1'b0;
        blink_cnt <= 4'd0; cur_blink_on <= 1'b0; txt_blink_on <= 1'b0;
        hold <= '0; cout <= '0; fin <= '0;
        hpos <= 10'h3FF; vpos <= 9'h1FF;
        for (int i = 0; i < DLY; i++) dl[i] <= '0;
        att_d <= 8'h00; glyph_d <= 8'h00; g0_d <= 8'h00; g1_d <= 8'h00;
        h0_d <= 8'h00; h1_d <= 8'h00; blink_d <= 1'b0;
        // mono
        ph <= 4'd0; gfx_c <= 1'b0; w9 <= 1'b0; cpar <= 1'b0;
        s1 <= '0; s2 <= '0; mfs <= 3'd0; mbank <= 1'b0;
        de1 <= 1'b0; de2 <= 1'b0; cur1 <= 1'b0; cur2 <= 1'b0;
        hs1 <= 1'b0; hs2 <= 1'b0; vs1 <= 1'b0; mblink <= 5'd0;
        vq <= 1'b0; iq <= 1'b0;
        mhpos_q <= 10'h3FF; mvpos_q <= 9'h1FF; mhs_prev <= 1'b0; mvs_prev <= 1'b0;
    end else begin
        // ---------------------------------------------- colour dot tick
        if (tick) begin
            dc <= dn;
            dl[0] <= now;
            for (int i = 1; i < DLY; i++) dl[i] <= dl[i-1];
            if (r.hclk) begin
                cout <= hold;
                hold <= '{pb, r.hb, r.vb};
            end else if (r.drw) begin
                cout <= '{pa, r.hb, r.vb};
                hold <= '{pb, r.hb, r.vb};
            end else
                cout <= hold;
            if (r.bnd) begin
                att_d <= att; glyph_d <= glyph;
                g0_d <= g0; g1_d <= g1; h0_d <= h0; h1_d <= h1;
                blink_d <= blink_snap;
            end
            fin <= cout;
            if (cout.h && !fin.h) hpos <= 10'd0;
            else if (hpos != 10'h3FF) hpos <= hpos + 10'd1;
            if (cout.v && !fin.v) vpos <= 9'd0;
            else if (cout.h && !fin.h && vpos != 9'h1FF) vpos <= vpos + 9'd1;
        end
        post      <= c_cclk;
        post_lclk <= c_cclk && dn == 4'd0;

        if (post) begin
            if (hs_mode) begin
                mode      <= mode_reg;
                mode_pend <= 1'b0;
            end
            hs_q <= c_hs;
            if (post_lclk) begin
                card_hb <= c_hs;
                card_vb <= c_vs && vsc < 5'd3;
                if (c_vs && vsc < 5'd3 && !card_vb) begin
                    blink_cnt <= blink_cnt + 4'd1;
                    if (blink_cnt[2:0] == 3'd7) cur_blink_on <= !cur_blink_on;
                    if (blink_cnt == 4'd15)     txt_blink_on <= !txt_blink_on;
                end
            end
            a_txt_q    <= a_txt;
            a_gfx_q    <= a_gfx;
            ra_q       <= ra[3:0];
            fs         <= 3'd1;
            blink_snap <= mode_char[5];
        end else if (fs != 3'd7)
            fs <= fs + 3'd1;
        case (fs)
            3'd1: chr <= vb_q0;
            3'd2: att <= vb_q0;
            3'd3: begin g0 <= vb_q0; h0 <= vb_q1; end
            3'd4: begin g1 <= vb_q0; h1 <= vb_q1; glyph <= fr_q; end
            default: ;
        endcase
        if (dc == 4'd0 && !tick) hclk <= (hs_mode && post ? mode_reg[0] : mode[0]) || force80;

        // ---------------------------------------------- mono dot clock
        if (rise && mono) begin
            ph <= ph_n;
            vq <= de2 && d_vid;
            iq <= de2 && d_int;
        end
        if (ev_f) begin mfs <= 3'd1; mbank <= gfx_c && ra[1]; mf_a <= gfx_c ? a_mgfx : a_mchr; end
        else if (mfs != 3'd0) mfs <= mfs == 3'd3 ? 3'd0 : mfs + 3'd1;
        if (mfs == 3'd2) begin n_chr <= vb_mq; n_glyph <= fr_q; end
        if (mfs == 3'd3) n_att <= vb_mq;
        if (ev_e) begin
            gfx_c <= m_gfx;
            w9    <= c9dot;
            cpar  <= m_gfx ? 1'b0 : !cpar;
            de1  <= de;    de2  <= de1;
            cur1 <= c_cur; cur2 <= cur1;
            hs1  <= c_hs;  hs2  <= hs1;
            vs1  <= c_vs;
            if (vs1 && !c_vs) mblink <= mblink + 5'd1;
            s2.att   <= matt_in;
            s2.glyph <= n_glyph;
            s2.serin <= w9 && box && n_glyph[0];
            s2.nod   <= mfg_in == 3'd0 && mbg_in == 3'd0;
            s2.rvv   <= mfg_in == 3'd0 && mbg_in == 3'd7;
            s2.ul    <= mfg_in == 3'd1 && ra == ul_row;
            s2.word  <= {s1.chr, s1.att};
            s1.chr <= n_chr;
            s1.att <= en_eff ? n_att : 8'h00;
        end
        if (fall && mono) begin
            mhpos_q  <= mhpos;
            mvpos_q  <= mvpos;
            mhs_prev <= mhs_out;
            mvs_prev <= vs1;
        end

        // ---------------------------------------------- CPU memory access
        if (!mem_any) begin
            req_s <= 1'b0; busy <= 1'b0; done <= 1'b0; cpu_cnt <= 4'd0;
        end else if (vtick && !done) begin
            if (busy) begin
                cpu_cnt <= cpu_cnt + 4'd1;
                if (cpu_do) begin busy <= 1'b0; done <= 1'b1; end
            end else if (seq_start && req_s) begin
                busy    <= 1'b1;
                cpu_cnt <= 4'd0;
            end
            req_s <= 1'b1;
        end

        // ---------------------------------------------- I/O
        lp_trig_q <= lpen_trig;
        if (lp_set_ev) lp_latch <= 1'b1;
        if (lp_clr_ev) lp_latch <= 1'b0;
        if (any_end) begin
            // the unlock sequence: reads of 3X8 in succession, then the write
            if (io_rd_end && io_a == 4'h8) ulk <= ulk == 2'd2 ? 2'd2 : ulk + 2'd1;
            else ulk <= 2'd0;
        end
        if (wr_par) par <= io_d;
        if (wr_cnf) cnf <= io_d;
        if (crtc_wa) crtc_sel <= io_d[4:0];
        if (crtc_data_wr && lock_c && crtc_sel == 5'd11) ul_row <= io_d[4:0];
        if (wr_mr) begin
            mr <= mr_wd;
            if (!mono) begin
                if (gfx_class(io_d[5:0]) != gfx_class(mode_reg))
                    mode_pend <= 1'b1;
                else begin
                    mode <= io_d[5:0];
                    if (dc == 4'd0) hclk <= io_d[0] || force80;
                end
            end
        end
        if (io_wr_end && io_a == 4'h9 && !mono) cc <= io_d[5:0];
        if (io_wr_end && io_a == 4'hD && !mono && ext_on) pl <= {io_d[6:4], 4'h0};
        if (io_wr_end && io_a == 4'hE && !mono && ext_on) att_r <= io_d;
        if (io_wr_end && io_a == 4'hF && mono) hgc <= io_d[1:0];
        // 3DD is cleared by alpha mode, mono mode or the Plantronics disable;
        // 3BF by the colour mapping; 3DE while it is disabled. With the
        // registers as they are after this clk's write, so a write that
        // clears them acts at the same edge.
        if (!mr_nx[1] || par_nx[7] || par_nx[3]) pl <= '0;
        if (!par_nx[7]) hgc <= 2'b00;
        if (par_nx[3]) att_r <= 8'h00;
    end
end

// ============================================================ outputs
wire c_hb = !(hpos >= 10'(AP_X) && hpos < 10'(AP_X + AP_W));
wire c_vb = !(vpos >= 9'(AP_Y) && vpos < 9'(AP_Y + AP_H));
wire m_hb = !(mhpos >= 10'(MP_X) && mhpos < 10'(MP_X + MP_W));
wire m_vb = !(mvpos >= 9'(MP_Y) && mvpos < 9'(MP_Y + MP_H));

assign vid_ce       = mono ? fall : ce_14m;
assign vid_rgbi     = mono ? {iq, vq, vq, vq} : fin.c;
assign vid_mono     = mono && vq;
assign vid_hsync    = mono ? mhs_out : fin.h;
assign vid_vsync    = mono ? vs1 : fin.v;
assign vid_hblank   = mono ? m_hb : c_hb;
assign vid_vblank   = mono ? m_vb : c_vb;
assign vid_monomode = mono;

endmodule
