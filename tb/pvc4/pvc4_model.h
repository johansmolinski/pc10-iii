// pvc4_model.h - reference model of the Paradise PVC4 for tb/pvc4.
//
// Written from doc/pvc4.md (the data sheet, the PC10-III manual and the
// decisions recorded there), not from the HDL. The display logic of the two
// personalities comes from this repository's reference models of the IBM
// cards, as the HDL's comes from the IBM cards:
//   - colour: tb/cga/cga_model.h (MartyPC's CGA and 6845, per 14.318 MHz
//     tick), with the PVC4's changes (no snow, the flicker override, the
//     border control, the Plantronics modes, 64 KB, the character ROM
//     layout, the registers);
//   - mono: tb/mda/mda_model.h (IBM's MDA logic diagrams, per clk), with the
//     dot clock always running (and /2 in 40-column mode), 8- or 9-dot
//     characters, the underline row register, the PVC4 status bits.
// The CPU's memory access follows the PVC4 sequence rule (doc/pvc4.md 4).
// The 6845 is MartyPC's (Crtc6845) behind the PVC4's register differences.
//
// GPL-3.0-or-later, pc10-iii.

#pragma once
#include "../cga/cga_model.h"
#include <cstdint>
#include <cstring>
#include <vector>

struct Pvc4Model {
    // ---------------------------------------------------------------- board
    uint8_t par_strap = 0xE0, cnf_strap = 0xF7;
    bool enable = true;
    bool cbm = false, a14 = true, a11 = true;
    std::vector<uint8_t> font = std::vector<uint8_t>(32768, 0);
    std::vector<uint8_t> mem = std::vector<uint8_t>(65536, 0);
    int cpu_t = 5;

    // ---------------------------------------------------------------- registers
    uint8_t par = 0, cnf = 0, mr = 0, pl = 0, att = 0, hgc = 0, ul_row = 12;
    int ulk = 0;
    int crtc_sel = 0;
    Crtc6845 crtc;
    bool lp_latch = false, lpen_sw = false;

    bool mono() const { return par & 0x80; }
    bool en_eff() const { return (mr & 0x08) || !(par & 0x04); }
    bool ext_on() const { return !(par & 0x08); }
    bool ca13() const { return ext_on() && (att & 0x04); }
    bool force80() const { return par & 0x01; }

    void reset() {
        par = par_strap; cnf = cnf_strap; mr = 0; pl = 0; att = 0; hgc = 0; ul_row = 12; ulk = 0;
        crtc = Crtc6845(); crtc_sel = 0;
        lp_latch = false;
        c = CPart(); m = MPart();
    }

    uint16_t cg(uint8_t ch, int row, bool monoro) const {
        if (cbm) return (a14 << 14) | (ca13() << 13) | ((ch >> 7) << 12) | (a11 << 11) | ((ch & 0x7F) << 4) | (row & 15);
        if (monoro) return ((row & 8) << 8) | (ch << 3) | (row & 7);
        return 0x1800 | (ch << 3) | (row & 7);
    }

    // ---------------------------------------------------------------- colour (CgaModel)
    struct CPart {
        uint64_t cycles = 0;
        int clock_divisor = 2;
        uint8_t mode_byte = 0;
        bool mode_pending = false;
        bool m0 = false, hires_txt = false, graphics = false, bw = false, enable = false, hires_gfx = false, blinking = false;
        uint8_t cc = 0;
        bool in_crtc_hblank = false, in_crtc_vblank = false, in_card_hblank = false, in_card_vblank = false;
        bool in_display_area = false;
        int char_col = 0;
        uint8_t cur_char = 0, cur_attr = 0, cur_fg = 0, cur_bg = 0;
        bool cur_blink = false;
        uint8_t g0 = 0, g1 = 0, h0 = 0, h1 = 0, glyph = 0;
        unsigned blink_ticks = 0;
        bool cursor_blink_on = false, text_blink_on = false;
        struct Dot { uint8_t c, h, v; };
        std::vector<Dot> dots = std::vector<Dot>(1u << 20);
        uint64_t dots_written = 0;
    } c;

    void c_update_mode() {
        uint8_t mb = c.mode_byte;
        c.hires_txt = (mb & 0x01) || force80();
        c.graphics  = mb & 0x02;
        c.bw        = mb & 0x04;
        c.enable    = mb & 0x08;
        c.hires_gfx = mb & 0x10;
        c.blinking  = mb & 0x20;
        c.m0        = mb & 0x01;
        c_update_clock();
    }
    void c_update_clock() {
        if ((c.cycles & 0x0F) == 0) c.clock_divisor = (c.m0 || force80()) ? 1 : 2;
    }
    static bool is_text(uint8_t mb) { return (mb & 1) || ((mb & 3) == 3); }
    static bool is_gfx_class(uint8_t mb) { return (mb & 2) && !is_text(mb); }
    void c_write_mode(uint8_t mb) {
        mb &= 0x3F;
        if (is_gfx_class(mb) != is_gfx_class(c.mode_byte)) {
            c.mode_pending = true;
            c.mode_byte = mb;
        } else {
            c.mode_byte = mb;
            c_update_mode();
        }
    }
    bool c_en() const { return c.enable || !(par & 0x04); }
    bool p320() const { return pl & 0x10; }
    bool p640() const { return (pl & 0x20) && !(pl & 0x10); }
    uint8_t c_overscan() const {
        if (!(cnf & 0x04)) return 0;
        if (c.hires_gfx && !(p320() || p640())) return 0;
        return c.cc & 0x0F;
    }
    uint8_t c_palette(int idx, bool bwgfx) const {
        static const uint8_t P[6][4] = {{0, 2, 4, 6}, {0, 10, 12, 14}, {0, 3, 5, 7},
                                        {0, 11, 13, 15}, {0, 3, 4, 7}, {0, 11, 12, 15}};
        if (idx == 0) return c.cc & 0x0F;
        int p = bwgfx ? 4 : (c.cc & 0x20) ? 2 : 0;
        if (c.cc & 0x10) p++;
        return P[p][idx];
    }
    void c_tick_crtc_char() {
        bool last_h = c.in_crtc_hblank;
        crtc.tick();
        if (crtc.in_hsync && !last_h && c.mode_pending) { c_update_mode(); c.mode_pending = false; }
        c.in_crtc_hblank = crtc.in_hsync;
        c.in_crtc_vblank = crtc.in_vsync;
        c.in_display_area = crtc.den();
    }
    void c_calculate_blanking() {
        if ((c.cycles & 0x0F) == 0) {
            bool v = c.in_crtc_vblank && crtc.vsc < 3;
            if (v && !c.in_card_vblank) {
                c.blink_ticks++;
                if (c.blink_ticks % 8 == 0) c.cursor_blink_on = !c.cursor_blink_on;
                if (c.blink_ticks % 16 == 0) c.text_blink_on = !c.text_blink_on;
            }
            c.in_card_vblank = v;
            c.in_card_hblank = c.in_crtc_hblank;
        }
    }
    void c_set_char_addr() {
        int addr = 0x8000 | ((crtc.vma & 0x1FFF) << 1);
        c.cur_char = mem[addr];                  // no snow: the CPU has its own memory cycle
        c.cur_attr = mem[addr + 1];
        c.cur_fg = c.cur_attr & 0x0F;
        if (c.blinking) { c.cur_bg = (c.cur_attr >> 4) & 7; c.cur_blink = c.cur_attr & 0x80; }
        else            { c.cur_bg = c.cur_attr >> 4;       c.cur_blink = false; }
        c.glyph = font[cg(c.cur_char, crtc.ra(), false)];
        int ga = 0x8000 | ((((crtc.vma & 0x0FFF) | ((crtc.ra() & 1) << 12)) << 1));
        c.g0 = mem[ga];     c.g1 = mem[ga + 1];
        c.h0 = mem[ga | 0x4000]; c.h1 = mem[(ga + 1) | 0x4000];
    }
    uint8_t c_content(int col, int half) const {
        bool en = c_en();
        if (!c.graphics) {
            bool cursor = crtc.cursor() && c.cursor_blink_on;
            if (cursor) return c.cur_fg;
            if (!en) return 0;
            bool blink_en = !crtc.cursor() && c.blinking;
            if (c.cur_blink && !c.text_blink_on && blink_en) return c.cur_bg;
            return (c.glyph & (0x80 >> col)) ? c.cur_fg : c.cur_bg;
        }
        uint16_t w = (c.g0 << 8) | c.g1, w1 = (c.h0 << 8) | c.h1;
        if (p320()) {
            if (c.clock_divisor == 1) return c_overscan();
            if (!en) return c.hires_gfx ? 0 : (c.cc & 0x0F);
            int p0 = (w >> (14 - col * 2)) & 3, p1 = (w1 >> (14 - col * 2)) & 3;
            int idx = p0 | (p1 << 2);                         // c3 c2 c1 c0
            // c2 = I, c1 = R, c0 = G, c3 = B
            return (((idx >> 2) & 1) << 3) | (((idx >> 1) & 1) << 2) | ((idx & 1) << 1) | ((idx >> 3) & 1);
        }
        if (p640()) {
            if (!en) return 0;
            if (c.clock_divisor == 1) {
                int i = (((c.h0 >> (7 - col)) & 1) << 1) | ((c.g0 >> (7 - col)) & 1);
                return c_palette(i, c.bw);
            }
            int bit = 15 - (col * 2 + half);
            int i = (((w1 >> bit) & 1) << 1) | ((w >> bit) & 1);
            return c_palette(i, c.bw);
        }
        if (c.hires_gfx) {
            if (c.clock_divisor == 1) return (en && (c.g0 & (0x80 >> col))) ? (c.cc & 0x0F) : 0;
            int bit = 15 - (col * 2 + half);
            return (en && ((w >> bit) & 1)) ? (c.cc & 0x0F) : 0;
        }
        if (c.clock_divisor == 1) return c_overscan();
        if (!en) return c.cc & 0x0F;
        return c_palette((w >> (14 - col * 2)) & 3, c.bw && c.graphics && !c.hires_gfx);
    }
    uint8_t c_dot(int col, int half) const {
        if (c.in_display_area) return c_content(col, half);
        if (c.in_card_hblank || c.in_card_vblank) return 0;
        return c_overscan();
    }
    void c_put(uint64_t n, uint8_t col) {
        c.dots[n % c.dots.size()] = {col, (uint8_t)c.in_card_hblank, (uint8_t)c.in_card_vblank};
        c.dots_written = n + 1;
    }
    // one 14.318 MHz tick (the card's dot tick)
    void c_tick() {
        c.cycles++;
        bool crtc_on = !mono();
        if (c.clock_divisor == 2 && (c.cycles & 1)) return;
        if (c.clock_divisor == 1) c_put(c.cycles - 1, c_dot(c.char_col, 0));
        else { c_put(c.cycles - 2, c_dot(c.char_col, 0)); c_put(c.cycles - 1, c_dot(c.char_col, 1)); }
        c.char_col++;
        if (c.char_col == 8) {
            if (crtc_on) {
                c_tick_crtc_char();
                c_calculate_blanking();
                c_set_char_addr();
            }
            c.char_col = 0;
            c_update_clock();
        }
    }

    // ---------------------------------------------------------------- mono (MdaModel)
    struct MPart {
        uint32_t acc = 0;
        bool fall_pend = false, div = false;
        uint64_t dots = 0;
        int ph = 0;
        bool wide = false, w9 = false, cpar = false;
        uint8_t s1_chr = 0, s1_att = 0, n_chr = 0, n_att = 0, n_glyph = 0;
        struct { uint8_t att, glyph; bool serin, nod, rvv, ul; uint16_t word; } s2 = {};
        bool de1 = false, de2 = false, cur1 = false, cur2 = false, hs1 = false, hs2 = false, vs1 = false;
        unsigned blink = 0;
        bool vq = false, iq = false;
        int hpos = 0x3FF, vpos = 0x1FF;
        bool hs_prev = false, vs_prev = false;
    } m;
    uint32_t m_inc = 59609, m_mod = 105000;
    int mp_x = 144, mp_w = 738, mp_y = 16, mp_h = 354;

    bool m_gfx() const { return (mr & 0x02) && (hgc & 1); }
    bool m_page() const { return (mr & 0x80) && (hgc & 2); }
    int m_last() const { return m.wide ? 15 : m.w9 ? 8 : 7; }
    bool m_hires() const { return (mr & 1) || force80(); }

    void m_dot_value(bool &v, bool &i) const {
        if (m.wide) {
            v = en_eff() && ((m.s2.word >> (15 - m.ph)) & 1);
            i = false;
        } else {
            bool sd = m.ph < 8 ? (m.s2.glyph >> (7 - m.ph)) & 1 : m.s2.serin;
            bool hide = (m.blink & 16) && (m.s2.att & 0x80) && (mr & 0x20) && !m.cur2;
            bool cur = m.cur2 && (m.blink & 8);
            bool alpha = cur || ((sd || m.s2.ul) && !m.s2.nod && !hide);
            v = alpha != m.s2.rvv;
            i = alpha ? (m.s2.att & 0x08) : ((m.s2.att & 0x80) && !(mr & 0x20));
        }
        v = v && m.de2;
        i = i && m.de2;
    }
    void m_cclk_rise() {
        bool de = crtc.den(), cu = crtc.cursor(), hs = crtc.in_hsync, vs = crtc.in_vsync;
        bool w9_old = m.w9;
        m.wide = m_gfx();
        m.w9 = par & 0x20;
        m.cpar = m_gfx() ? false : !m.cpar;
        m.de2 = m.de1; m.de1 = de;
        m.cur2 = m.cur1; m.cur1 = cu;
        m.hs2 = m.hs1; m.hs1 = hs;
        if (m.vs1 && !vs) m.blink = (m.blink + 1) & 31;
        m.vs1 = vs;
        uint8_t a = en_eff() ? m.s1_att : 0;
        int fg = a & 7, bg = (a >> 4) & 7;
        m.s2.att = a;
        m.s2.glyph = m.n_glyph;
        m.s2.serin = w9_old && (m.s1_chr & 0xE0) == 0xC0 && (m.n_glyph & 1);
        m.s2.nod = fg == 0 && bg == 0;
        m.s2.rvv = fg == 0 && bg == 7;
        m.s2.ul = fg == 1 && crtc.ra() == ul_row;
        m.s2.word = (uint16_t)(m.s1_chr << 8 | m.s1_att);
        m.s1_chr = m.n_chr;
        m.s1_att = en_eff() ? m.n_att : 0;
        crtc.tick();
    }
    void m_cclk_fall() {
        unsigned ma = crtc.vma, ra = crtc.ra();
        unsigned addr = m.wide ? (((m_page() ? 1u : 0u) << 15) | ((ra & 3) << 13) | ((ma & 0xFFF) << 1))
                               : (ma & 0x1FFF) << 1;
        m.n_chr = mem[addr];
        m.n_att = mem[addr | 1];
        m.n_glyph = font[cg(m.s1_chr, ra, true)];
    }

    // ---------------------------------------------------------------- the bus
    // memory decode: physical offset in mem, or -1
    int mem_off(uint32_t a) const {
        if (!enable) return -1;
        if (mono()) {
            if ((a >> 15) == 0x16) return a & 0x7FFF;
            if ((a >> 15) == 0x17 && (hgc & 2)) return 0x8000 | (a & 0x7FFF);
            return -1;
        }
        if ((a >> 15) != 0x17) return -1;
        bool plo = pl & 0x30;
        int a14 = plo ? (((a >> 14) & 1) ^ (((pl & 0x40) && (mr & 2)) ? 1 : 0)) : 0;
        return 0x8000 | (a14 << 14) | (a & 0x3FFF);
    }
    bool io_sel(uint32_t a) const { return enable && ((a >> 4) & 0x3F) == (mono() ? 0x3B : 0x3D); }

    uint8_t status() const {
        if (mono())
            return (m.vs1 ? 0 : 0x80) | 0x60 | ((cnf & 0x40) ? 0x10 : 0) | (m.vq ? 0x08 : 0) |
                   (!lpen_sw ? 0x04 : 0) | (lp_latch ? 0x02 : 0) | ((m.hs1 || m.hs2) ? 0x01 : 0);
        return 0xE0 | ((cnf & 0x40) ? 0x10 : 0) | (crtc.in_vsync ? 0x08 : 0) | (!lpen_sw ? 0x04 : 0) |
               (lp_latch ? 0x02 : 0) | ((crtc.in_vsync || !crtc.den()) ? 0x01 : 0);
    }
    // read data of an I/O read (-1: not driven), without side effects
    int io_peek(uint32_t a) const {
        if (!io_sel(a)) return -1;
        int p = a & 0xF;
        if (p < 8) return (p & 1) ? crtc.read_register() : -1;
        if (p == 8) return mr;
        if (p == 0xA) return status();
        return -1;
    }
    void set_lp() { if (!lp_latch) { lp_latch = true; crtc.latch_lightpen(); } }

    // a CPU I/O access ends (any port: the unlock counts every I/O access)
    void io_end(bool rd, uint32_t a, uint8_t d) {
        bool sel = io_sel(a);
        int p = a & 0xF;
        bool unl = ulk == 2;
        if (sel && rd && p == 8) ulk = ulk == 2 ? 2 : ulk + 1;
        else if (enable) ulk = 0;
        if (!sel) return;
        if (p == (mono() ? 9 : 0xC)) set_lp();
        if (p == 0xB && !(unl && !rd)) lp_latch = false;
        if (rd) return;
        if (p == 0xB && unl) { set_par(d); return; }
        if (p == 0xA && unl) { cnf = d; return; }
        if (p < 8) {
            if (!(p & 1)) { crtc_sel = d & 0x1F; crtc.sel = d & 0x1F; return; }
            if ((par & 0x02) && crtc_sel <= 11) { if (crtc_sel == 11) ul_row = d & 0x1F; return; }
            uint8_t v = crtc_sel == 8 ? 0 : crtc_sel == 10 ? (d & 0x3F) : d;
            crtc.write_register(v);
            return;
        }
        switch (p) {
        case 8: {
            uint8_t v = d & 0xBF;
            if (!(hgc & 2)) v &= 0x7F;
            if (mono() && !(hgc & 1)) v &= ~0x02;
            mr = v;
            if (!mono()) c_write_mode(d & 0x3F);
            break;
        }
        case 9: if (!mono()) c.cc = d & 0x3F; break;
        case 0xD: if (!mono() && ext_on()) pl = d & 0x70; break;
        case 0xE: if (!mono() && ext_on()) att = d; break;
        case 0xF: if (mono()) hgc = d & 3; break;
        default: break;
        }
        clear_rules();
    }
    void set_par(uint8_t d) {
        bool was_force = force80();
        par = d;
        clear_rules();
        if (force80() != was_force) {}            // the clock follows at the next lchar boundary
    }
    void clear_rules() {
        if (!(mr & 0x02) || mono() || !ext_on()) pl = 0;
        if (!mono()) hgc = 0;
        if (!ext_on()) att = 0;
    }

    // ---------------------------------------------------------------- the CPU slot
    bool req_s = false, busy = false, done = false, wrote = false;
    int cpu_cnt = 0;
    int wr_lost = 0;
    bool wr_prev = false, wr_done = false;
    bool ready(bool memr, bool memw, uint32_t a) const {
        bool req = (memr || memw) && mem_off(a) >= 0;
        return !(req && !done);
    }
    // a video clock rising edge with the memory strobe present
    void slot_edge(bool seq_start, bool memw, uint32_t a, uint8_t d) {
        if (done) return;
        if (busy) {
            if (++cpu_cnt == cpu_t) {
                busy = false; done = true;
                if (memw) { mem[mem_off(a)] = d; wr_done = true; wrote = true; }
            }
        } else if (seq_start && req_s) {
            busy = true; cpu_cnt = 0;
        }
        req_s = true;
    }

    struct Out { bool ce; uint8_t rgbi; bool v, i, hs, vs, hb, vb; };

    // one clk, with the bus as the chip sees it in this clk. ctick: the colour
    // dot tick (ce_14m delayed). Returns the mono personality's dot at its
    // vid_ce (the colour dots go to the ring c.dots).
    Out step(bool ctick, bool memr, bool memw, uint32_t a, uint8_t d) {
        Out o{false, 0, false, false, false, false, false, false};
        wrote = false;
        bool req = (memr || memw) && mem_off(a) >= 0;
        bool mw = memw && mem_off(a) >= 0;
        if (wr_prev && !mw && !wr_done) wr_lost++;
        if (!mw) wr_done = false;
        wr_prev = mw;
        if (!req) { req_s = false; busy = false; done = false; cpu_cnt = 0; }

        // mono oscillator
        uint32_t n = m.acc + m_inc;
        bool orise = n >= m_mod, ofall = (m.acc < m_mod / 2 && n >= m_mod / 2) || m.fall_pend;
        m.fall_pend = n >= m_mod + m_mod / 2;
        m.acc = orise ? n - m_mod : n;
        bool hires = m_hires();
        bool rise = hires ? orise : orise && !m.div;
        bool fall = hires ? ofall : orise && m.div;
        if (orise) m.div = hires ? false : !m.div;

        if (!mono()) {
            if (ctick) {
                // the sequence starts when the lchar phase becomes 0
                bool seq = ((c.cycles + 1) & 15) == 0;
                if (req) slot_edge(seq, memw, a, d);
                c_tick();
            }
            return o;
        }
        if (ctick) c.cycles++;                   // the colour phase keeps counting
        if (fall) {
            bool hs = m.hs1 || m.hs2;
            bool hst = hs && !m.hs_prev;
            int hp = hst ? 0 : (m.hpos == 0x3FF ? m.hpos : m.hpos + 1);
            int vp = (m.vs1 && !m.vs_prev) ? 0 : (hst && m.vpos != 0x1FF ? m.vpos + 1 : m.vpos);
            o = {true, 0, m.vq, m.iq, hs, m.vs1, !(hp >= mp_x && hp < mp_x + mp_w), !(vp >= mp_y && vp < mp_y + mp_h)};
            o.rgbi = (m.iq ? 8 : 0) | (m.vq ? 7 : 0);
            m.hpos = hp; m.vpos = vp; m.hs_prev = hs; m.vs_prev = m.vs1;
            if (m.ph == 4) m_cclk_fall();
        }
        // the sequencer counts the undivided oscillator; a sequence starts with
        // an even character (every character when the clock is divided)
        int phn = m.ph >= m_last() ? 0 : m.ph + 1;
        if (orise && req) slot_edge(rise && phn == 0 && (m.wide || !m.cpar || !hires), memw, a, d);
        if (rise) {
            m.dots++;
            bool v, i;
            m_dot_value(v, i);
            m.vq = v; m.iq = i;
            m.ph = phn;
            if (m.ph == 0) m_cclk_rise();
        }
        return o;
    }
};
