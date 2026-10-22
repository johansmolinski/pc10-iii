// mda_model.h - reference model of the IBM MDA (and the Hercules mode) for
// tb/mda.
//
// Written from the reading of IBM's MDA logic diagrams in doc/mda.md (not
// from the HDL), stepped once per clk (100.2273 MHz) like the card:
//   - the crystal as a fractional accumulator (rising and falling edge);
//   - the 9-state character counter, CCLK, the 6845 stepping when CCLK rises;
//   - the CPU slot: request sampled at 4Q, IOCHRDY at the CCLK falling edge;
//   - the display pipeline U34/U31 -> U29/U30/U32, U55 delays, U101, U28.
// The 6845 is MartyPC's (Crtc6845 from tb/cga/cga_model.h), as in the card
// (rtl/video/cga/cga_crtc.sv).
//
// GPL-3.0-or-later, pc10-iii.

#pragma once
#include "../cga/cga_model.h"
#include <cstdint>
#include <cstring>
#include <vector>

struct MdaModel {
    bool herc = false;
    uint32_t inc = 59609, mod = 367500, acc = 0;
    bool hres_stop = true;
    bool cga_fitted = false;

    Crtc6845 crtc;
    std::vector<uint8_t> mem;
    uint8_t font[4096] = {};

    uint8_t mode = 0, cfg = 0;
    bool hs_ok = false;

    uint64_t dots = 0;                   // rising dot clock edges
    int ph = 0;                          // dot in the character; 0 = CCLK rises
    bool wide = false;                   // 16-dot characters (HGC graphics)

    // CPU slot (U4a, U4b); a write whose strobe ends before the slot
    bool cap = false, ack = false;
    bool wr_prev = false, wr_done = false;
    int wr_off = 0;
    uint8_t wr_dat = 0;

    // display pipeline
    uint8_t s1_chr = 0, s1_att = 0;      // U34, U31
    uint8_t n_chr = 0, n_att = 0, n_glyph = 0;
    struct { uint8_t att, glyph; bool serin, nod, rvv, ul; uint16_t word; } s2 = {};
    bool de1 = false, de2 = false, cur1 = false, cur2 = false, hs1 = false, hs2 = false, vs1 = false;
    unsigned blink = 0;                  // U28, 5 bits
    bool vq = false, iq = false;         // U101

    // window
    int hpos = 0x3FF, vpos = 0x1FF;
    bool hs_prev = false, vs_prev = false;
    int ap_x = 144, ap_w = 738, ap_y = 16, ap_h = 354;

    explicit MdaModel(bool h) : herc(h), mem(h ? 65536 : 4096, 0) {
        if (h) { inc = 704; mod = 4410; hres_stop = false; }
    }

    bool m_hres() const { return mode & 0x01; }
    bool m_gfx() const { return herc && (mode & 0x02); }
    bool m_en() const { return mode & 0x08; }
    bool m_blink() const { return mode & 0x20; }
    bool m_page() const { return herc && (mode & 0x80); }
    int last() const { return wide ? 15 : 8; }

    // ---------------------------------------------------------------- bus
    // address decode: byte offset in mem, or -1
    int mem_off(uint32_t a) const {
        if ((a >> 15) == 0x16) return herc ? (a & 0x7FFF) : (a & 0x0FFF);
        if (herc && (a >> 15) == 0x17 && (cfg & 2) && !cga_fitted) return 0x8000 | (a & 0x7FFF);
        return -1;
    }
    static bool io_sel(uint32_t a) { return ((a >> 4) & 0x3F) == 0x3B; }
    // does this strobe ask for the CPU slot?
    bool is_req(bool memr, bool memw, bool ior, bool iow, uint32_t a) const {
        if ((memr || memw) && mem_off(a) >= 0) return true;
        return (ior || iow) && io_sel(a) && !(a & 8);
    }
    bool ready(bool req) const { return !(req && !ack); }

    uint8_t status() const {
        uint8_t b = (hs1 || hs2 ? 0x01 : 0) | (vq ? 0x08 : 0);
        if (herc) b |= vs1 ? 0x00 : 0x80;
        else b |= 0xF0;
        return b;
    }
    // read data (-1: not driven)
    int io_read(uint32_t a) const {
        if (!io_sel(a)) return -1;
        if (!(a & 8)) return (a & 1) ? crtc.read_register() : 0xFF;
        if ((a & 7) == 2) return status();
        return -1;
    }
    void io_write(uint32_t a, uint8_t d) {
        if (!io_sel(a)) return;
        if (!(a & 8)) {
            if (a & 1) crtc.write_register(d);
            else crtc.sel = d & 0x1F;
            return;
        }
        if ((a & 0xF) == 8) {
            uint8_t m = d & 0x2D;                         // U58: bits 0, 2, 3, 5
            if (herc) {
                m |= ((cfg & 1) ? d : mode) & 0x02;
                m |= ((cfg & 2) ? d : mode) & 0x80;
            }
            mode = m;
            if (d & 0x08) hs_ok = true;
        } else if ((a & 0xF) == 0xF && herc)
            cfg = d & 3;
    }

    // ---------------------------------------------------------------- dots
    void dot_value(bool &v, bool &i) const {
        if (wide) {
            v = m_en() && ((s2.word >> (15 - ph)) & 1);
            i = false;
        } else {
            bool sd = ph < 8 ? (s2.glyph >> (7 - ph)) & 1 : s2.serin;
            bool hide = (blink & 16) && (s2.att & 0x80) && m_blink() && !cur2;
            bool cur = cur2 && (blink & 8);
            bool alpha = cur || ((sd || s2.ul) && !s2.nod && !hide);
            v = alpha != s2.rvv;
            i = alpha ? (s2.att & 0x08) : ((s2.att & 0x80) && !m_blink());
        }
        v = v && de2;
        i = i && de2;
    }

    // the character clock: stage latches before the 6845 steps
    void cclk_rise() {
        wide = m_gfx();
        bool de = crtc.den(), cu = crtc.cursor(), hs = crtc.in_hsync, vs = crtc.in_vsync;
        de2 = de1; de1 = de;
        cur2 = cur1; cur1 = cu;
        hs2 = hs1; hs1 = hs;
        if (vs1 && !vs) blink = (blink + 1) & 31;
        vs1 = vs;
        uint8_t att = m_en() ? s1_att : 0;
        int fg = att & 7, bg = (att >> 4) & 7;
        s2.att = att;
        s2.glyph = n_glyph;
        s2.serin = (s1_chr & 0xE0) == 0xC0 && (n_glyph & 1);
        s2.nod = fg == 0 && bg == 0;
        s2.rvv = fg == 0 && bg == 7;
        s2.ul = fg == 1 && (crtc.ra() & 15) == 12;
        s2.word = (uint16_t)(s1_chr << 8 | s1_att);
        s1_chr = n_chr;
        s1_att = m_en() ? n_att : 0;
        crtc.tick();
    }
    // the CCLK falling edge: end of the CPU slot, then the display read
    void cclk_fall(bool req, bool memw, uint32_t a, uint8_t d) {
        if (req && cap) {
            ack = true;
            cap = false;
            if (memw && mem_off(a) >= 0) { mem[mem_off(a)] = d; wr_done = true; }
        }
        unsigned ma = crtc.vma, ra = crtc.ra();
        unsigned addr = wide ? (((m_page() ? 1u : 0u) << 15) | ((ra & 3) << 13) | ((ma & 0xFFF) << 1))
                             : (ma & 0x7FF) << 1;
        n_chr = mem[addr];
        n_att = mem[addr | 1];
        n_glyph = font[((ra & 8) << 8) | (s1_chr << 3) | (ra & 7)];
    }

    struct Out { bool ce, v, i, hs, vs, hb, vb; };

    // one clk. Bus state as the card sees it in this clk. Returns the video
    // signals at vid_ce (ce = false otherwise).
    Out step(bool memr, bool memw, bool ior, bool iow, uint32_t a, uint8_t d) {
        Out o{false, false, false, false, false, false, false};
        uint32_t n = acc + inc;
        bool rise = n >= mod, fall = acc < mod / 2 && n >= mod / 2;
        acc = rise ? n - mod : n;
        bool run = !hres_stop || m_hres();
        rise = rise && run;
        fall = fall && run;
        bool req = is_req(memr, memw, ior, iow, a);
        bool mw = memw && mem_off(a) >= 0;
        // the strobe ended before the slot: write now (doc/mda.md 4.2)
        if (wr_prev && !mw && !wr_done) mem[wr_off] = wr_dat;
        if (!mw) wr_done = false;
        wr_prev = mw;
        if (mw) { wr_off = mem_off(a); wr_dat = d; }

        if (fall) {
            bool hs = (hs1 || hs2) && hs_ok;
            bool hst = hs && !hs_prev;
            int hp = hst ? 0 : (hpos == 0x3FF ? hpos : hpos + 1);
            int vp = (vs1 && !vs_prev) ? 0 : (hst && vpos != 0x1FF ? vpos + 1 : vpos);
            o = {true, vq, iq, hs, vs1, !(hp >= ap_x && hp < ap_x + ap_w), !(vp >= ap_y && vp < ap_y + ap_h)};
            hpos = hp; vpos = vp; hs_prev = hs; vs_prev = vs1;
        }
        // U4: request sampled at 4Q, slot ends when CCLK falls
        bool cap_ev = rise && (ph >= last() ? 0 : ph + 1) == last();
        if (!req) { cap = false; ack = false; }
        else if (cap_ev && !ack) cap = true;
        if (fall && ph == 4) cclk_fall(req, memw, a, d);
        if (rise) {
            dots++;
            bool v, i;
            dot_value(v, i);
            vq = v; iq = i;
            ph = ph >= last() ? 0 : ph + 1;
            if (ph == 0) cclk_rise();
        }
        return o;
    }
};
