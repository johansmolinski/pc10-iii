// cga_model.h - reference model of the IBM CGA for tb/cga.
//
// A C++ transliteration of MartyPC's CGA (devices/cga/{mod,io,mmio,draw}.rs)
// and MC6845 (devices/mc6845.rs) at commit 05c0d08 (MIT, (c) 2022-2026
// Daniel Balsom), clocked per 14.318 MHz tick (MartyPC's CGACard::tick()
// path). Written from the Rust source, not from the HDL, so that the two
// implementations are independent. The places where this model departs from
// MartyPC on purpose are the ones the HDL departs (doc/cga.md section 8),
// marked "DEV:".
//
// GPL-3.0-or-later, pc10-iii.

#pragma once
#include <cstdint>
#include <cstring>
#include <vector>

struct Crtc6845 {
    uint8_t reg[18] = {};
    int sel = 0;                         // DEV: 5-bit address register

    enum Mode { NORMAL, VTA, HALF } mode = NORMAL;
    uint16_t start_address = 0, start_address_latch = 0, cursor_address = 0;
    bool cursor_enabled = true;          // R10 = 0 at reset: bits 6:5 = 00
    int cursor_blink_rate = 0;           // 0 none, 8, 16
    uint8_t cursor_start_line = 0;
    bool cursor_active = false, blink_state = false;
    unsigned frames = 0;

    uint8_t hcc = 0, vlc = 0, vlci = 0, vcc = 0, vsc = 0, hsc = 0, vtac = 0;
    bool previous_last_line = false, last_line = false;
    uint16_t vma = 0, vma_t = 0;          // DEV: 14 bits (MartyPC u16)
    int interlace = 0;                   // R8 & 3
    bool parity = false;                 // false = even
    bool in_hsync = false, in_vsync = false, h_de = false, v_de = false;
    bool in_last_vblank_line = false;

    bool isync() const { return interlace == 1 || interlace == 3; }
    bool ivideo() const { return interlace == 3; }
    uint8_t ra() const { return ivideo() ? (uint8_t)((vlci << 1) | (parity ? 1 : 0)) : vlc; }
    bool den() const { return h_de && v_de; }
    bool cursor() const {
        bool c = cursor_enabled && cursor_active && vma == cursor_address;
        if (cursor_blink_rate) c = c && blink_state;
        return c;
    }

    void write_register(uint8_t b) {
        switch (sel) {
        case 0: reg[0] = b; break;
        case 1: reg[1] = b; break;
        case 2: reg[2] = b; break;
        case 3: reg[3] = b; break;
        case 4: reg[4] = b & 0x7F; break;
        case 5: reg[5] = b & 0x1F; break;
        case 6: reg[6] = b & 0x7F; break;
        case 7: reg[7] = b & 0x7F; break;
        case 8: {
            reg[8] = b & 0x03;
            bool was = isync();
            interlace = reg[8];
            if (was && !isync()) parity = false;
            break;
        }
        case 9: reg[9] = b & 0x1F; break;
        case 10:
            reg[10] = b & 0x7F;
            cursor_start_line = b & 0x1F;
            switch (reg[10] >> 5) {
            case 0: cursor_enabled = true;  cursor_blink_rate = 0;  break;
            case 1: cursor_enabled = false; cursor_blink_rate = 0;  break;
            case 2: cursor_enabled = true;  cursor_blink_rate = 8;  break;
            default: cursor_enabled = true; cursor_blink_rate = 16; break;
            }
            break;
        case 11: reg[11] = b & 0x1F; break;
        case 12: reg[12] = b & 0x3F; start_address = (reg[12] << 8) | reg[13]; break;
        case 13: reg[13] = b;        start_address = (reg[12] << 8) | reg[13]; break;
        case 14: reg[14] = b & 0x3F; cursor_address = (reg[14] << 8) | reg[15]; break;
        case 15: reg[15] = b;        cursor_address = (reg[14] << 8) | reg[15]; break;
        default: break;
        }
    }
    uint8_t read_register() const {
        if (sel >= 14 && sel <= 17) return reg[sel];
        return 0xFF;
    }
    void latch_lightpen() {
        reg[16] = (vma >> 8) & 0x3F;
        reg[17] = vma & 0xFF;
    }

    bool in_vta() const { return mode == VTA; }
    bool has_half_scanline() const { return isync() && !parity; }

    void process_start_of_frame() {
        frames++;
        if (isync()) parity = !parity;
        mode = NORMAL;
        last_line = false;
        vtac = 0; vcc = 0; vlc = 0; vlci = 0;
        start_address_latch = start_address;
        vma = start_address;
        vma_t = vma;
        h_de = true; v_de = true;
        in_vsync = false;
    }
    void process_frame_end() {
        if (has_half_scanline()) mode = HALF;
        else process_start_of_frame();
    }
    void process_last_line() {
        switch (mode) {
        case NORMAL:
            if (reg[5] != 0) { mode = VTA; last_line = false; }
            else if (has_half_scanline()) mode = HALF;
            else process_frame_end();
            break;
        case HALF: process_start_of_frame(); break;
        default: break;
        }
    }
    void tick_vlc(bool tick_i) {
        vlc = (vlc + 1) & 0x1F;
        if (tick_i) vlci = (vlci + 1) & 0x0F;
        if (ra() == cursor_start_line && !in_vta()) cursor_active = true;
    }

    void tick() {
        bool c4_r4 = vcc == reg[4];
        bool c0_r0 = hcc == reg[0];
        bool c0_r0_half = hcc == (reg[0] >> 1);
        bool c9_r9_half = vlc == (reg[9] >> 1);
        bool c9_r9 = vlc == reg[9];
        bool c9_ivm_split = ivideo() && c9_r9_half;

        if (hcc == 0) {
            if (ra() == cursor_start_line && !in_vta()) cursor_active = true;
            if (vcc == 0 && vlc == 0) vma = start_address_latch;
            if (vcc == reg[4]) {
                last_line = c9_r9 && !previous_last_line && !in_hsync;
                vtac = 0;
            } else
                last_line = false;
        }
        hcc = hcc + 1;
        if (hcc == 0) {
            h_de = true;
            if (vcc == 0) vma = start_address_latch;
        }
        vma = (vma + 1) & 0x3FFF;

        if (in_hsync) {
            hsc = (hsc - 1) & 0x0F;
            if (hsc == 0) {
                previous_last_line = c4_r4 && c9_r9;
                if (in_vsync) {
                    vsc++;
                    if (vsc == 16) { in_last_vblank_line = true; vsc = 0; in_vsync = false; }
                }
                in_hsync = false;
            }
        }
        if (hcc == reg[1]) {
            if (c9_r9 || c9_ivm_split) vma_t = vma;
            h_de = false;
        }
        if (hcc == reg[2]) {
            in_hsync = true;
            hsc = reg[3] & 0x0F;
        }
        if (c0_r0) {
            if (ra() == reg[11] && !in_vta()) cursor_active = false;
            if (in_last_vblank_line) { in_last_vblank_line = false; in_vsync = false; }
            hcc = 0;
            h_de = true;
            vma = vma_t;
            if (c9_r9) {
                vlc = 0; vlci = 0;
                vcc = (vcc + 1) & 0x7F;          // DEV: 7-bit C4 (MartyPC u8)
                vma = vma_t;
                if (vcc == reg[7]) {
                    in_vsync = true;
                    if (cursor_blink_rate && frames % cursor_blink_rate == 0)
                        blink_state = !blink_state;
                }
                if (last_line) process_last_line();
            } else if (c9_ivm_split) {
                vlci = 0;
                tick_vlc(false);
            } else
                tick_vlc(true);
            if (vcc == reg[6]) v_de = false;
            if (in_vta()) {
                vtac++;
                if (vtac > reg[5]) process_frame_end();
            }
        } else if (mode == HALF && c0_r0_half)
            process_last_line();
    }
};

struct CgaModel {
    Crtc6845 crtc;
    uint8_t mem[16384] = {};
    uint8_t font[8192] = {};
    bool thin = false, snow_enabled = true;

    uint64_t cycles = 0;
    int clock_divisor = 2;               // DEV: follows the mode (MartyPC starts at 1)
    uint8_t mode_byte = 0;
    bool mode_pending = false;
    bool hires_txt = false, graphics = false, bw = false, enable = false,
         hires_gfx = false, blinking = false;
    uint8_t cc = 0x30;

    bool in_crtc_hblank = false, in_crtc_vblank = false;
    bool in_card_hblank = false, in_card_vblank = false;
    bool in_display_area = false;
    int char_col = 0;

    uint8_t cur_char = 0, cur_attr = 0, cur_fg = 0, cur_bg = 0;
    bool cur_blink = false;
    uint8_t g0 = 0, g1 = 0;              // DEV: graphics bytes fetched at the boundary
    uint8_t glyph = 0;                   // DEV: glyph row loaded at the boundary
    unsigned blink_ticks = 0;
    bool cursor_blink_on = false, text_blink_on = false;
    bool lightpen_latch = false, lightpen_switch = false;

    bool snow_pending = false;
    uint8_t snow_byte = 0;

    // dot output: colour, card hsync, card vsync, for dot number n
    struct Dot { uint8_t c, h, v; };
    std::vector<Dot> dots;               // ring, indexed by n % size
    uint64_t dots_written = 0;
    CgaModel() : dots(1u << 20) {}

    void update_mode() {
        hires_txt = mode_byte & 0x01;
        graphics  = mode_byte & 0x02;
        bw        = mode_byte & 0x04;
        enable    = mode_byte & 0x08;
        hires_gfx = mode_byte & 0x10;
        blinking  = mode_byte & 0x20;
        update_clock();
    }
    void update_clock() {
        if ((cycles & 0x0F) == 0) clock_divisor = hires_txt ? 1 : 2;
    }
    static bool is_text(uint8_t m) { return (m & 1) || ((m & 3) == 3); }
    static bool is_gfx_class(uint8_t m) { return (m & 2) && !is_text(m); }
    void write_mode(uint8_t m) {
        m &= 0x3F;
        if (is_gfx_class(m) != is_gfx_class(mode_byte)) {
            mode_pending = true;
            mode_byte = m;
        } else {
            mode_byte = m;
            update_mode();
        }
    }
    uint8_t overscan() const { return hires_gfx ? 0 : (cc & 0x0F); }
    uint8_t palette(int idx) const {
        static const uint8_t P[6][4] = {{0, 2, 4, 6}, {0, 10, 12, 14}, {0, 3, 5, 7},
                                        {0, 11, 13, 15}, {0, 3, 4, 7}, {0, 11, 12, 15}};
        if (idx == 0) return cc & 0x0F;
        int p = (bw && graphics && !hires_gfx) ? 4 : (cc & 0x20) ? 2 : 0;
        if (cc & 0x10) p++;
        return P[p][idx];
    }

    uint8_t status() const {
        uint8_t b = in_crtc_vblank ? 0xF9 : !in_display_area ? 0xF1 : 0xF0;
        if (lightpen_latch) b |= 0x02;
        if (!lightpen_switch) b |= 0x04;
        return b;
    }
    void set_lp() { if (!lightpen_latch) { lightpen_latch = true; crtc.latch_lightpen(); } }

    void io_write(int port, uint8_t d) {
        port &= 0x0F;
        if (!(port & 8)) {
            if (port & 1) crtc.write_register(d);
            else crtc.sel = d & 0x1F;
        } else switch (port) {
            case 8: write_mode(d); break;
            case 9: cc = d & 0x3F; break;
            case 0xB: lightpen_latch = false; break;
            case 0xC: set_lp(); break;
            default: break;
        }
    }
    // returns -1 when the card does not drive the bus
    int io_read(int port) {
        port &= 0x0F;
        if (!(port & 8)) return (port & 1) ? crtc.read_register() : 0;
        switch (port) {
        case 0xA: return status();
        case 0xB: lightpen_latch = false; return 0;
        case 0xC: set_lp(); return 0;
        case 8: case 9: return 0;
        default: return -1;
        }
    }

    // a CPU access at the CPU slot (doc/cga.md section 4)
    void mem_access(bool wr, int a, uint8_t d) {
        a &= 0x3FFF;
        snow_pending = true;
        snow_byte = wr ? d : mem[a];
        if (wr) mem[a] = d;
    }

    void tick_crtc_char() {
        bool last_h = in_crtc_hblank;
        crtc.tick();
        if (crtc.in_hsync && !last_h && mode_pending) {
            update_mode();
            mode_pending = false;
        }
        in_crtc_hblank = crtc.in_hsync;
        in_crtc_vblank = crtc.in_vsync;
        in_display_area = crtc.den();
    }
    void calculate_blanking() {
        if ((cycles & 0x0F) == 0) {
            bool v = in_crtc_vblank && crtc.vsc < 3;
            if (v && !in_card_vblank) {
                // DEV: blink counters on the card's VSYNC (MartyPC: monitor flyback)
                blink_ticks++;
                if (blink_ticks % 8 == 0) cursor_blink_on = !cursor_blink_on;
                if (blink_ticks % 16 == 0) text_blink_on = !text_blink_on;
            }
            in_card_vblank = v;
            in_card_hblank = in_crtc_hblank;
        }
    }
    void set_char_addr() {
        int addr = (crtc.vma & 0x1FFF) << 1;
        // DEV: snow on the first odd hchar after the CPU slot, char = attr = bus byte
        if (snow_enabled && hires_txt && snow_pending && (cycles & 0x0F) == 8) {
            cur_char = snow_byte;
            cur_attr = snow_byte;
        } else {
            cur_char = mem[addr];
            cur_attr = mem[addr + 1];
        }
        if ((cycles & 0x0F) == 8 || !hires_txt) snow_pending = false;
        cur_fg = cur_attr & 0x0F;
        if (blinking) { cur_bg = (cur_attr >> 4) & 7; cur_blink = cur_attr & 0x80; }
        else          { cur_bg = cur_attr >> 4;       cur_blink = false; }
        glyph = font[(thin ? 0x1000 : 0x1800) + cur_char * 8 + (crtc.ra() & 7)];
        int ga = (((crtc.vma & 0x0FFF) | ((crtc.ra() & 1) << 12)) << 1);
        g0 = mem[ga];
        g1 = mem[ga + 1];
    }

    // colour of glyph-row bit / gfx pixel for character column `col`
    // (hires: dot 0-7; lores: pair 0-7), `half` = second dot of a lores pair
    uint8_t content(int col, int half) const {
        if (!graphics) {
            bool cursor = crtc.cursor() && cursor_blink_on;
            if (cursor) return cur_fg;                       // char path: cursor first
            if (!enable) return 0;
            bool blink_en = !crtc.cursor() && blinking;
            if (cur_blink && !text_blink_on && blink_en) return cur_bg;
            return (glyph & (0x80 >> col)) ? cur_fg : cur_bg;
        }
        if (hires_gfx) {
            if (clock_divisor == 1) return (enable && (g0 & (0x80 >> col))) ? (cc & 0x0F) : 0;
            uint16_t w = (g0 << 8) | g1;
            int bit = 15 - (col * 2 + half);
            return (enable && ((w >> bit) & 1)) ? (cc & 0x0F) : 0;
        }
        if (clock_divisor == 1) return overscan();
        if (!enable) return cc & 0x0F;
        uint16_t w = (g0 << 8) | g1;
        return palette((w >> (14 - col * 2)) & 3);
    }
    uint8_t dot_colour(int col, int half) const {
        if (in_display_area) return content(col, half);
        if (in_card_hblank || in_card_vblank) return 0;
        return overscan();
    }
    void put(uint64_t n, uint8_t c) {
        dots[n % dots.size()] = {c, (uint8_t)in_card_hblank, (uint8_t)in_card_vblank};
        dots_written = n + 1;
    }

    // CGACard::tick(): one 14.318 MHz clock
    void tick() {
        cycles++;
        if (clock_divisor == 2 && (cycles & 1)) return;
        if (clock_divisor == 1)
            put(cycles - 1, dot_colour(char_col, 0));
        else {
            put(cycles - 2, dot_colour(char_col, 0));
            put(cycles - 1, dot_colour(char_col, 1));
        }
        char_col++;
        if (char_col == 8) {
            tick_crtc_char();
            calculate_blanking();
            set_char_addr();
            char_col = 0;
            update_clock();
        }
    }
};
