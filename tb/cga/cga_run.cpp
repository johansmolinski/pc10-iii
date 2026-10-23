// cga_run.cpp - Verilator testbench for rtl/video/cga (doc/cga.md section 9).
//
// The card is driven by a model of the pc10-iii system board's bus timing
// (rtl/system/xt_board.sv: the 8288 command edges, the commands ending at the
// CLK edge where T4 begins, IOCHRDY sampled on rdy_ce, 1 clk before the rising
// CLK edge that ends a state, one wait state on CPU I/O cycles; the card bus's
// next-clk values) and of biu88's READY rule (at the edge that starts T3/Tw
// the CPU knows from READY whether that state is the last) with the clock
// enables of pc_clocks.sv on the 28.63636 MHz clock (2 clk per OSC tick, 6 per
// CPU clock). Next to it runs cga_model.h, a C++ transliteration
// of MartyPC's CGA, ticked on the board's 14.318 MHz instants. Checked:
//   waits   wait states of a CPU read/write at each of the 16 lchar phases
//           against MartyPC's WAIT_TABLE (mmio.rs + the CPU's conversion);
//   modeN   BIOS modes 0-6 (IBM BIOS 6845 tables): every dot of a frame,
//           HSYNC/VSYNC, line and frame period, PPM/PNG images;
//   status  3DA read back-to-back over a frame, each read against the model,
//           also with VSYNC inside the displayed rows;
//   torture random register writes (CRTC, mode, colour, light pen) at random
//           instants, every dot and every read against the model;
//   snow    80-column writes during the display, dot by dot;
//   blink   34 frames of mode 3 with blinking characters and the cursor;
//   thin    the thin font (P3 jumper input);
//   crtc    small 6845 geometries with fast random writes (frame end, VTA,
//           last-line management, cursor), every dot and read;
//   cursor  cursor lines wrapping across rows and through VTA, all R10 modes;
//
// usage: cga_run -f font.bin -o outdir [test ...]
// debug: CGAIOLOG=1 lists the I/O writes with the model's tick;
//        CGADOT=n prints card and model state around dot n.
//
// GPL-3.0-or-later, pc10-iii.

#include "Vcga_card.h"
#include "Vcga_card___024root.h"
#include "cga_model.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <deque>
#include <functional>
#include <random>
#include <string>
#include <vector>

static const uint8_t P40[16]  = {0x38, 0x28, 0x2D, 0x0A, 0x1F, 0x06, 0x19, 0x1C, 0x02, 0x07, 0x06, 0x07, 0, 0, 0, 0};
static const uint8_t P80[16]  = {0x71, 0x50, 0x5A, 0x0A, 0x1F, 0x06, 0x19, 0x1C, 0x02, 0x07, 0x06, 0x07, 0, 0, 0, 0};
static const uint8_t PGFX[16] = {0x38, 0x28, 0x2D, 0x0A, 0x7F, 0x06, 0x64, 0x70, 0x02, 0x01, 0x06, 0x07, 0, 0, 0, 0};
static const uint8_t MODE_REG[7] = {0x2C, 0x28, 0x2D, 0x29, 0x2A, 0x2E, 0x1E};
// MartyPC devices/cga/mod.rs: system ticks to the CPU slot, by phase
static const int WAIT_TABLE[16] = {14, 13, 12, 11, 10, 9, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15};

static int failures = 0;
#define CHECK(c, ...) do { if (!(c)) { failures++; if (failures < 40) { printf("FAIL: " __VA_ARGS__); printf("\n"); } } } while (0)

struct Op {
    enum Type { MEMR, MEMW, IOR, IOW, IDLE } t;
    uint32_t a;
    uint8_t d;
    int n;                               // IDLE: CPU cycles
    std::function<void(uint8_t)> cb;     // reads: the data
};

struct Rec { uint8_t c, h, v, hb, vb; };

struct Sim {
    Vcga_card *top;
    CgaModel g;
    uint64_t clk_n = 0, hdl_ticks = 0;
    int c2 = 0, c6 = 0;

    // board
    enum TS { TI, T1, T2, T3, TW, T4 } ts = TI;
    std::deque<Op> q;
    Op cur{Op::IDLE, 0, 0, 0, nullptr};
    int idle_left = 0;
    bool cmd_rd = false, cmd_wr = false, rdy_sync = true;
    bool t3_last = false;                // biu88: the running T3/Tw is the last
    int tw = 0;
    int exp_tw = -1;                     // MartyPC wait states for this access
    bool gpend = false;
    uint64_t gE = 0;

    // statistics / logs
    std::vector<Rec> rec;                // HDL output, one per HDL tick (from rec_base)
    uint64_t rec_base = 0;
    bool recording = false, keep = true;
    uint64_t cmp_n = 0, cmp_bad = 0, cmp_lit = 0;
    int reads_checked = 0, waits_checked = 0;
    std::vector<std::pair<int, int>> wait_log;   // (phase p, Tw) per access
    int wait_log_wr = 0;

    explicit Sim(const std::vector<uint8_t> &font, bool thin) {
        top = new Vcga_card;
        top->clk = 0;
        top->reset = 1;
        set_bus();
        for (int i = 0; i < 8; i++) { top->clk = 0; top->eval(); top->clk = 1; top->eval(); }
        // load the character ROM through the font port
        for (int a = 0; a < 8192; a++) {
            top->font_we = 1;
            top->font_addr = a;
            top->font_data = font[a];
            top->clk = 0; top->eval(); top->clk = 1; top->eval();
        }
        top->font_we = 0;
        top->font_thin = thin;
        memcpy(g.font, font.data(), 8192);
        g.thin = thin;
        top->reset = 0;
    }
    ~Sim() { top->final(); delete top; }

    bool is_read(const Op &o) const { return o.t == Op::MEMR || o.t == Op::IOR; }
    bool is_write(const Op &o) const { return o.t == Op::MEMW || o.t == Op::IOW; }
    bool is_io(const Op &o) const { return o.t == Op::IOR || o.t == Op::IOW; }
    bool in_cycle() const { return ts == T1 || ts == T2 || ts == T3 || ts == TW; }

    void set_bus() {
        bool rd = cmd_rd, wr = cmd_wr;       // registered: end at the edge where T4 begins
        top->isa_memr_n = !(rd && cur.t == Op::MEMR);
        top->isa_ior_n  = !(rd && cur.t == Op::IOR);
        top->isa_memw_n = !(wr && cur.t == Op::MEMW);
        top->isa_iow_n  = !(wr && cur.t == Op::IOW);
        top->isa_aen = 0;
        top->lpen_trig = 0;
        top->lpen_sw = 0;
    }

    // the card bus of the next clk (xt_board.sv isa_*_next): the commands as
    // they will be after the coming edge; the address only changes at a T1,
    // when no strobe is low
    void set_next(bool rd, bool wr) {
        top->isa_addr_next   = top->isa_addr;
        top->isa_aen_next    = 0;
        top->isa_memr_n_next = !(rd && cur.t == Op::MEMR);
        top->isa_ior_n_next  = !(rd && cur.t == Op::IOR);
        top->isa_memw_n_next = !(wr && cur.t == Op::MEMW);
        top->isa_iow_n_next  = !(wr && cur.t == Op::IOW);
    }

    void start_op() {
        cur = q.front();
        q.pop_front();
        ts = T1;
        tw = 0;
        top->isa_addr = cur.a;
        top->isa_dout = cur.a & 0xFF;    // T1: the address on AD7-AD0
    }

    // one clk
    void step() {
        bool ce = c2 == 0, cs = c6 == 0, cf = c6 == 2, cr = c6 == 5;
        top->ce_14m = ce;
        top->clk = 0;
        top->eval();
        bool hdl_tick = top->rootp->cga_card__DOT__tick;
        bool ready = top->isa_ready;
        uint8_t din = top->isa_din;
        bool dsel = top->isa_dsel;

        // ---- the model, at the board's 14.318 MHz instant
        if (ce) {
            if (hdl_ticks == g.cycles + 1) {
                g.tick();
                if (gpend && g.cycles == gE) {
                    g.mem_access(cur.t == Op::MEMW, cur.a, cur.d);
                    gpend = false;
                }
            }
            CHECK((g.cycles & 15) == (uint64_t)top->rootp->cga_card__DOT__dc,
                  "phase: model %llu, card dc %d", (unsigned long long)g.cycles,
                  top->rootp->cga_card__DOT__dc);
        }

        // ---- board registers (xt_board.sv)
        bool ncmd_rd = cmd_rd, ncmd_wr = cmd_wr;
        if (!in_cycle()) ncmd_rd = ncmd_wr = false;
        else if (cf) {
            if (ts == T1 && is_read(cur)) ncmd_rd = true;
            if (ts == T2 && is_write(cur)) ncmd_wr = true;
        }
        if (cr) rdy_sync = ready;        // xt_board.sv: rdy_ce
        if (cs) {
            bool cpu_ready = rdy_sync && !(ts == T2 && is_io(cur));
            switch (ts) {
            case TI:
            case T4:
                if (idle_left > 0) { idle_left--; ts = TI; break; }
                while (!q.empty() && q.front().t == Op::IDLE) {
                    idle_left = q.front().n;
                    q.pop_front();
                }
                if (idle_left > 0) { idle_left--; ts = TI; break; }
                if (!q.empty()) start_op();
                else ts = TI;
                break;
            case T1:
                ts = T2;
                if (is_write(cur)) top->isa_dout = cur.d;
                break;
            case T2:
                ts = T3;
                t3_last = cpu_ready;
                if (cur.t == Op::MEMR || cur.t == Op::MEMW) {
                    // MartyPC: phase = CGA ticks at the end of T2 + 1
                    uint64_t p = g.cycles + 1;
                    exp_tw = (WAIT_TABLE[p & 15] + 2) / 3;
                    uint64_t e = p + WAIT_TABLE[p & 15];
                    gE = e;
                    gpend = true;
                    wait_log.push_back({(int)(p & 15), -1});
                }
                break;
            case T3:
            case TW:
                if (t3_last) {
                    ts = T4;
                    ncmd_rd = ncmd_wr = false;   // the commands end at this edge
                    if (cur.t == Op::IOW) {
                        if (getenv("CGAIOLOG")) printf("    IOW %03X %02X at %llu (sel %d)\n", cur.a, cur.d, (unsigned long long)g.cycles, g.crtc.sel);
                        g.io_write(cur.a, cur.d);
                    }
                    if (cur.t == Op::IOR) {
                        int e = g.io_read(cur.a);
                        if (e < 0) CHECK(!dsel, "IOR %03X: card drives the bus", cur.a);
                        else CHECK(dsel && din == e, "IOR %03X at tick %llu: card %02X model %02X",
                                   cur.a, (unsigned long long)g.cycles, din, e);
                        reads_checked++;
                    }
                    if (cur.t == Op::MEMR || cur.t == Op::MEMW) {
                        CHECK(tw == exp_tw, "%s %05X: %d wait states, MartyPC %d (phase %d)",
                              cur.t == Op::MEMR ? "MEMR" : "MEMW", cur.a, tw, exp_tw,
                              wait_log.back().first);
                        wait_log.back().second = tw;
                        if (cur.t == Op::MEMW) wait_log_wr++;
                        waits_checked++;
                        if (cur.t == Op::MEMR)
                            CHECK(dsel && din == g.mem[cur.a & 0x3FFF], "MEMR %05X: %02X vs %02X",
                                  cur.a, din, g.mem[cur.a & 0x3FFF]);
                    }
                    if (cur.cb) cur.cb(din);
                } else {
                    ts = TW;
                    t3_last = cpu_ready;
                    tw++;
                    CHECK(tw < 40, "bus hangs at %05X", cur.a);
                }
                break;
            }
        }
        cmd_rd = ncmd_rd;
        cmd_wr = ncmd_wr;
        set_next(ncmd_rd, ncmd_wr);
        top->eval();
        c2 = c2 == 1 ? 0 : c2 + 1;
        c6 = c6 == 5 ? 0 : c6 + 1;

        top->clk = 1;
        top->eval();
        if (hdl_tick) {
            hdl_ticks++;
            if (recording) {
                Rec r{top->vid_rgbi, top->vid_hsync, top->vid_vsync, top->vid_hblank, top->vid_vblank};
                if (keep) rec.push_back(r);
                // the card shows model dot hdl_ticks - LAT; the model is ahead
                uint64_t n = hdl_ticks - LAT;
                CHECK(n < g.dots_written && n + g.dots.size() > g.dots_written,
                      "dot %llu not in the model", (unsigned long long)n);
                const CgaModel::Dot &d = g.dots[n % g.dots.size()];
                cmp_n++;
                cmp_lit += r.c != 0;
                static long long dbgdot = getenv("CGADOT") ? atoll(getenv("CGADOT")) : -1;
                if (dbgdot >= 0 && (long long)n >= dbgdot - 12 && (long long)n <= dbgdot + 4) {
                    auto *rp = top->rootp;
                    printf("    dot %llu card %X model %X | g: cyc %llu col %d ra %d cur %d de %d chr %02X att %02X | hdl: dc %d ra %d cur %d de %d chr %02X att %02X glyph %02X\n",
                           (unsigned long long)n, r.c, d.c, (unsigned long long)g.cycles, g.char_col, g.crtc.ra(), g.crtc.cursor(), g.in_display_area, g.cur_char, g.cur_attr,
                           rp->cga_card__DOT__dc, rp->cga_card__DOT__ra, rp->cga_card__DOT__c_cur, rp->cga_card__DOT__de, rp->cga_card__DOT__chr, rp->cga_card__DOT__att, rp->cga_card__DOT__glyph);
                }
                if (r.c != d.c || r.h != d.h || r.v != d.v) {
                    if (cmp_bad < 5)
                        printf("  dot %llu: card c%X h%d v%d, model c%X h%d v%d\n", (unsigned long long)n,
                               r.c, r.h, r.v, d.c, d.h, d.v);
                    cmp_bad++;
                }
            }
        }
        set_bus();
        clk_n++;
    }

    bool busy() const { return !q.empty() || ts != TI || idle_left > 0; }
    void run_ops() { while (busy()) step(); }
    void run_ticks(uint64_t n) { uint64_t t = hdl_ticks + n; while (hdl_ticks < t) step(); }

    void iow(int port, uint8_t d) { q.push_back({Op::IOW, (uint32_t)port, d, 0, nullptr}); }
    void ior(int port, std::function<void(uint8_t)> cb = nullptr) { q.push_back({Op::IOR, (uint32_t)port, 0, 0, cb}); }
    void memw(uint32_t a, uint8_t d) { q.push_back({Op::MEMW, a, d, 0, nullptr}); }
    void memr(uint32_t a) { q.push_back({Op::MEMR, a, 0, 0, nullptr}); }
    void idle(int n) { if (n > 0) q.push_back({Op::IDLE, 0, 0, n, nullptr}); }

    void crtc(int r, uint8_t v) { iow(0x3D4, r); iow(0x3D5, v); }

    // the IBM BIOS mode set: video off, 6845 table, mode, palette
    void bios_mode(int m) {
        const uint8_t *t = m <= 1 ? P40 : m <= 3 ? P80 : PGFX;
        iow(0x3D8, MODE_REG[m] & 0x37);
        for (int i = 0; i < 16; i++) crtc(i, t[i]);
        iow(0x3D9, m == 6 ? 0x3F : 0x30);
    }

    // recording: every dot is compared with the model while it runs
    static constexpr int LAT = 6;        // card tick k shows model dot k - LAT (cga_card DLY 3 + 3)
    void rec_start(bool keep_dots = true) {
        rec.clear(); recording = true; keep = keep_dots; rec_base = hdl_ticks + 1;
        cmp_n = cmp_bad = cmp_lit = 0;
    }
    void rec_stop() { recording = false; }
    void compare(const char *what) {
        CHECK(cmp_bad == 0, "%s: %llu of %llu dots differ", what, (unsigned long long)cmp_bad,
              (unsigned long long)cmp_n);
        printf("  %s: %llu dots compared, %llu not black\n", what, (unsigned long long)cmp_n,
               (unsigned long long)cmp_lit);
    }
};

// ---------------------------------------------------------------- images
static const uint8_t RGBI[16][3] = {
    {0x00, 0x00, 0x00}, {0x00, 0x00, 0xAA}, {0x00, 0xAA, 0x00}, {0x00, 0xAA, 0xAA},
    {0xAA, 0x00, 0x00}, {0xAA, 0x00, 0xAA}, {0xAA, 0x55, 0x00}, {0xAA, 0xAA, 0xAA},
    {0x55, 0x55, 0x55}, {0x55, 0x55, 0xFF}, {0x55, 0xFF, 0x55}, {0x55, 0xFF, 0xFF},
    {0xFF, 0x55, 0x55}, {0xFF, 0x55, 0xFF}, {0xFF, 0xFF, 0x55}, {0xFF, 0xFF, 0xFF}};

// a full field as the beam sees it (x from HSYNC start, y from VSYNC start;
// syncs drawn dark grey/blue), and the vid_hblank/vid_vblank window
static void write_images(const std::vector<Rec> &r, const std::string &base) {
    // find a VSYNC start
    size_t s = 1;
    while (s < r.size() && !(r[s].v && !r[s - 1].v)) s++;
    if (s >= r.size()) { printf("  no VSYNC in the recording\n"); return; }
    const int W = 912, H = 262;
    std::vector<uint8_t> full(W * H * 3, 0x20), win;
    int x = 0, y = 0, ww = 0, wh = 0, wx = 0;
    std::vector<uint8_t> row;
    for (size_t k = s; k < r.size(); k++) {
        if (k > s && r[k].v && !r[k - 1].v) break;
        if (r[k].h && !r[k - 1].h) { x = 0; if (k > s) y++; }
        const uint8_t *c = RGBI[r[k].c & 15];
        if (x < W && y < H) {
            uint8_t *p = &full[(y * W + x) * 3];
            if (r[k].h || r[k].v) { p[0] = 0x30; p[1] = 0x30; p[2] = r[k].v ? 0x80 : 0x30; }
            else { p[0] = c[0]; p[1] = c[1]; p[2] = c[2]; }
        }
        x++;
        if (!r[k].hb && !r[k].vb) {
            row.insert(row.end(), c, c + 3);
            wx++;
        } else if (wx) {
            win.insert(win.end(), row.begin(), row.end());
            ww = wx; wh++; wx = 0; row.clear();
        }
    }
    FILE *f = fopen((base + "_field.ppm").c_str(), "wb");
    fprintf(f, "P6\n%d %d\n255\n", W, H);
    fwrite(full.data(), 1, full.size(), f);
    fclose(f);
    if (ww) {
        f = fopen((base + "_window.ppm").c_str(), "wb");
        fprintf(f, "P6\n%d %d\n255\n", ww, wh);
        fwrite(win.data(), 1, (size_t)ww * wh * 3, f);
        fclose(f);
    }
    printf("  images: %s_field.ppm (912x262), _window.ppm (%dx%d)\n", base.c_str(), ww, wh);
}

// HSYNC/VSYNC periods from the card's output
static void check_periods(const std::vector<Rec> &r, const char *what, int hper, int vper) {
    std::vector<size_t> hs, vs;
    for (size_t k = 1; k < r.size(); k++) {
        if (r[k].h && !r[k - 1].h) hs.push_back(k);
        if (r[k].v && !r[k - 1].v) vs.push_back(k);
    }
    int hbad = 0, vbad = 0;
    for (size_t i = 1; i < hs.size(); i++) if ((int)(hs[i] - hs[i - 1]) != hper) hbad++;
    for (size_t i = 1; i < vs.size(); i++) if ((int)(vs[i] - vs[i - 1]) != vper) vbad++;
    CHECK(hs.size() > 2 && hbad == 0, "%s: %d of %zu lines not %d dots", what, hbad, hs.size(), hper);
    CHECK(vs.size() >= 2 && vbad == 0, "%s: %d of %zu frames not %d dots", what, vbad, vs.size(), vper);
    printf("  %zu lines of %d dots, %zu frames of %d dots (%d lines)\n", hs.size(),
           hs.size() > 1 ? (int)(hs[1] - hs[0]) : -1, vs.size(),
           vs.size() > 1 ? (int)(vs[1] - vs[0]) : -1,
           vs.size() > 1 ? (int)(vs[1] - vs[0]) / hper : -1);
}

// ---------------------------------------------------------------- content
static void fill_text(Sim &s, int cols) {
    for (int i = 0; i < cols * 25; i++) {
        int ch = i & 0xFF;
        int at = ((i * 7 + 3) & 0x7F) | ((i % 37) == 5 ? 0x80 : 0);   // a few blinking
        if (((at >> 4) & 7) == (at & 15)) at ^= 0x0F;
        s.memw(0xB8000 + i * 2, ch);
        s.memw(0xB8000 + i * 2 + 1, at);
    }
}
static void fill_gfx(Sim &s, bool hires) {
    for (int y = 0; y < 200; y++)
        for (int xb = 0; xb < 80; xb++) {
            uint32_t a = 0xB8000 + (y & 1) * 0x2000 + (y >> 1) * 80 + xb;
            uint8_t v;
            if (hires) v = ((y / 8 + xb) & 1) ? 0xAA ^ (uint8_t)(y * 3) : (uint8_t)(0x81 | (xb << 1));
            else {
                int band = (xb * 4) / 80;    // vertical bands of the 4 colours, a diagonal
                v = (uint8_t)(band * 0x55);
                int d = (y + xb * 4) % 50;
                if (d < 4) v ^= 0xC0 >> (2 * d);
            }
            s.memw(a, v);
        }
}

static std::string outdir = ".";

static void test_mode(const std::vector<uint8_t> &font, int m) {
    printf("mode %d\n", m);
    Sim s(font, false);
    s.bios_mode(m);
    if (m <= 3) fill_text(s, m <= 1 ? 40 : 80);
    else fill_gfx(s, m == 6);
    if (m <= 3) { s.crtc(14, (12 * (m <= 1 ? 40 : 80) + 10) >> 8); s.crtc(15, (12 * (m <= 1 ? 40 : 80) + 10) & 0xFF); }
    s.iow(0x3D8, MODE_REG[m]);
    s.run_ops();
    s.run_ticks(2 * 238944);
    s.rec_start();
    s.run_ticks(2 * 238944 + 2000);
    s.rec_stop();
    s.compare(("mode " + std::to_string(m)).c_str());
    check_periods(s.rec, ("mode " + std::to_string(m)).c_str(), 912, 238944);
    write_images(s.rec, outdir + "/mode" + std::to_string(m));
}

static void test_waits(const std::vector<uint8_t> &font) {
    printf("waits\n");
    Sim s(font, false);
    s.bios_mode(3);
    s.iow(0x3D8, MODE_REG[3]);
    s.run_ops();
    // 16 idle offsets x 3 sweep T2 over every lchar phase; a read and a write
    for (int rep = 0; rep < 8; rep++)
        for (int k = 0; k < 16; k++) {
            s.idle(k + 1);
            s.memr(0xB8000 + k);
            s.idle((k * 5 + rep * 3) % 16);
            s.memw(0xBC000 + k * 2, k);
        }
    s.run_ops();
    int tab_r[16], tab_w[16], n_r[16], n_w[16];
    auto tally = [&]() {
        for (int i = 0; i < 16; i++) { tab_r[i] = tab_w[i] = -1; n_r[i] = n_w[i] = 0; }
        bool wr = false;
        for (auto &e : s.wait_log) {
            (wr ? tab_w : tab_r)[e.first] = e.second;
            (wr ? n_w : n_r)[e.first]++;
            wr = !wr;
        }
        for (int p = 0; p < 16; p++) if (n_r[p] < 8 || n_w[p] < 8) return false;
        return true;
    };
    // then random gaps until every phase has 8 reads and 8 writes
    std::mt19937 rng(5160);
    for (int round = 0; round < 40 && !tally(); round++) {
        for (int k = 0; k < 16; k++) {
            s.idle(rng() % 17);
            s.memr(0xB8000 + (rng() & 0x3FFF));
            s.idle(rng() % 17);
            s.memw(0xB8000 + (rng() & 0x3FFF), rng() & 0xFF);
        }
        s.run_ops();
    }
    printf("  phase  MartyPC  card-read  card-write  (accesses: reads/writes)\n");
    int seen = 0;
    for (int p = 0; p < 16; p++) {
        printf("  %5d  %7d  %9d  %10d  (%d/%d)\n", p, (WAIT_TABLE[p] + 2) / 3, tab_r[p], tab_w[p], n_r[p], n_w[p]);
        if (n_r[p] >= 8 && n_w[p] >= 8) seen++;
    }
    CHECK(seen == 16, "waits: only %d phases covered by 8 reads and 8 writes", seen);
    printf("  %d accesses checked\n", s.waits_checked);
}

static void test_status(const std::vector<uint8_t> &font) {
    printf("status\n");
    Sim s(font, false);
    s.bios_mode(3);
    s.iow(0x3D8, MODE_REG[3]);
    s.run_ops();
    s.run_ticks(238944);
    int n1 = 0, n8 = 0, n = 0;
    uint64_t t0 = s.hdl_ticks;
    while (s.hdl_ticks < t0 + 238944) {
        for (int i = 0; i < 64; i++)
            s.ior(0x3DA, [&](uint8_t v) { n++; n1 += v & 1; n8 += (v >> 3) & 1; });
        s.run_ops();
    }
    printf("  %d reads: bit 0 set in %d, bit 3 set in %d (%d checked against the model)\n",
           n, n1, n8, s.reads_checked);
    // 16 VSYNC lines of 262; display 640 of 912 dots x 200 of 262 lines
    double f8 = (double)n8 / n, f1 = (double)n1 / n;
    CHECK(f8 > 0.05 && f8 < 0.07, "status: bit 3 fraction %.3f (16/262 = 0.061)", f8);
    CHECK(f1 > 0.45 && f1 < 0.50, "status: bit 0 fraction %.3f (1 - 640*200/912/262 = 0.464)", f1);
    // VSYNC inside the displayed rows: bit 0 must be set during all of it
    s.crtc(7, 10);
    s.run_ops();
    s.run_ticks(238944);
    int both = 0;
    t0 = s.hdl_ticks;
    while (s.hdl_ticks < t0 + 238944) {
        for (int i = 0; i < 64; i++)
            s.ior(0x3DA, [&](uint8_t v) { both += (v & 9) == 9; });
        s.run_ops();
    }
    printf("  VSYNC at row 10: %d reads with bits 3 and 0, %d checked against the model\n", both,
           s.reads_checked);
    CHECK(both > 800, "status: VSYNC in the display: only %d reads with bits 3 and 0", both);
}

// small 6845 geometry, fast random register writes: frame-end, VTA, last-line
// and cursor corner cases
static void test_crtc(const std::vector<uint8_t> &font, int seed) {
    printf("crtc seed %d\n", seed);
    Sim s(font, false);
    std::mt19937 rng(seed);
    auto R = [&](int n) { return (int)(rng() % n); };
    s.bios_mode(seed & 1 ? 3 : 1);
    fill_text(s, 80);
    s.iow(0x3D8, MODE_REG[seed & 1 ? 3 : 1]);
    const uint8_t init[16] = {40, 30, 33, 4, 6, 2, 5, 5, 0, 3, 1, 2, 0, 0, 0, 40};
    for (int i = 0; i < 16; i++) s.crtc(i, init[i]);
    s.run_ops();
    s.rec_start();
    uint64_t t0 = s.hdl_ticks;
    int nw = 0;
    while (s.hdl_ticks < t0 + 3 * 238944) {
        s.idle(R(80));
        int r0 = 20 + R(40);
        switch (R(16)) {
        case 0: s.crtc(0, r0); break;
        case 1: s.crtc(1, 1 + R(r0)); break;
        case 2: s.crtc(2, R(8) ? 1 + R(r0 - 12) : R(r0)); break;     // mostly HSYNC ends before C0 = 0
        case 3: s.crtc(3, R(8) ? 1 + R(8) : R(16)); break;
        case 4: case 5: s.crtc(4, R(10)); break;
        case 6: s.crtc(4, s.g.crtc.vcc); break;               // R4 = the current row
        case 7: s.crtc(5, R(5)); break;
        case 8: s.crtc(6, R(10)); break;
        case 9: s.crtc(7, R(10)); break;
        case 10: case 11: s.crtc(9, R(4)); break;
        case 12: s.crtc(10, R(4) | (R(4) << 5)); break;
        case 13: s.crtc(11, R(4)); break;
        case 14: s.crtc(15, R(160)); break;
        default: s.crtc(R(2) ? 12 : 13, R(2) ? 0 : R(100)); break;
        }
        if (R(8) == 0) s.crtc(8, R(4));
        s.ior(0x3DA);
        nw++;
        s.run_ops();
    }
    s.rec_stop();
    printf("  %d register writes, %d reads checked\n", nw, s.reads_checked);
    s.compare("crtc");
    write_images(s.rec, outdir + "/crtc" + std::to_string(seed));
}

static void test_torture(const std::vector<uint8_t> &font, int seed, int base_mode) {
    printf("torture seed %d (mode %d)\n", seed, base_mode);
    Sim s(font, false);
    std::mt19937 rng(seed);
    auto R = [&](int n) { return (int)(rng() % n); };
    s.bios_mode(base_mode);
    if (base_mode <= 3) fill_text(s, 80); else fill_gfx(s, base_mode == 6);
    s.iow(0x3D8, MODE_REG[base_mode]);
    s.run_ops();
    s.run_ticks(238944);
    s.rec_start();
    uint64_t t0 = s.hdl_ticks;
    int nw = 0;
    while (s.hdl_ticks < t0 + 5 * 238944) {
        s.idle(R(400));
        switch (R(14)) {
        case 0: s.iow(0x3D9, R(64)); break;
        case 1: s.iow(0x3D8, (uint8_t[]){0x2C, 0x28, 0x2D, 0x29, 0x2A, 0x2E, 0x1E, 0x21, 0x09, 0x0A, 0x1A, 0x0B, 0x01, 0x3B}[R(14)]); break;
        case 2: s.crtc(12, R(64)); break;
        case 3: s.crtc(13, R(256)); break;
        case 4: s.crtc(1, 30 + R(60)); break;
        case 5: s.crtc(2, 40 + R(60)); break;
        case 6: s.crtc(3, R(256)); break;
        case 7: s.crtc(R(2) ? 4 : 9, R(2) ? 0x1F + R(4) - 2 : R(16)); break;
        case 8: s.crtc(R(2) ? 6 : 7, R(40)); break;
        case 9: s.crtc(R(2) ? 10 : 11, R(128)); break;
        case 10: s.crtc(R(2) ? 14 : 15, R(256)); break;
        case 11: s.iow(R(2) ? 0x3DB : 0x3DC, 0); break;
        case 12: s.iow(0x3D4, 14 + R(4)); s.ior(0x3D5); break;
        default:
            if (R(4) == 0) s.crtc(0, 0x38 + R(0x40));
            else if (R(3) == 0) s.crtc(5, R(32));
            else s.crtc(8, R(4));
            break;
        }
        s.ior(0x3DA);
        nw++;
        s.run_ops();
    }
    s.rec_stop();
    printf("  %d register writes, %d reads checked\n", nw, s.reads_checked);
    s.compare("torture");
}

// cursor lines that wrap across rows (R10 > R11) and so stay on through the
// vertical total adjust into the next frame (the 6845 does not end them there)
static void test_cursor(const std::vector<uint8_t> &font) {
    printf("cursor\n");
    Sim s(font, false);
    s.bios_mode(3);
    fill_text(s, 80);
    s.iow(0x3D8, MODE_REG[3]);
    const uint8_t regs[16] = {113, 80, 90, 10, 3, 4, 4, 3, 0, 3, 0x03, 1, 0, 0, 0, 5};
    for (int i = 0; i < 16; i++) s.crtc(i, regs[i]);
    s.run_ops();
    s.rec_start(false);
    for (int m = 0; m < 4; m++) {
        s.crtc(10, 0x03 | (m << 5));            // on, off, 1/16, 1/32
        s.run_ops();
        s.run_ticks(40 * 912 * 20);
    }
    s.rec_stop();
    s.compare("cursor");
}

static void test_snow(const std::vector<uint8_t> &font) {
    printf("snow\n");
    Sim s(font, false);
    s.bios_mode(3);
    fill_text(s, 80);
    s.iow(0x3D8, MODE_REG[3]);
    s.run_ops();
    s.run_ticks(238944);
    s.rec_start();
    std::mt19937 rng(7);
    uint64_t t0 = s.hdl_ticks;
    while (s.hdl_ticks < t0 + 2 * 238944) {
        s.idle(rng() % 7);
        s.memw(0xB8000 + (rng() % 4000), rng() & 0xFF);
        s.run_ops();
    }
    s.rec_stop();
    s.compare("snow");
    write_images(s.rec, outdir + "/snow");
}

static void test_blink(const std::vector<uint8_t> &font) {
    printf("blink (34 frames)\n");
    Sim s(font, false);
    s.bios_mode(3);
    fill_text(s, 80);
    s.crtc(14, 0x03); s.crtc(15, 0x20);
    s.iow(0x3D8, MODE_REG[3]);
    s.run_ops();
    s.rec_start(false);
    s.run_ticks(34 * 238944);
    s.rec_stop();
    s.compare("blink");
}

static void test_thin(const std::vector<uint8_t> &font) {
    printf("thin font, mode 1\n");
    Sim s(font, true);
    s.bios_mode(1);
    fill_text(s, 40);
    s.iow(0x3D8, MODE_REG[1]);
    s.run_ops();
    s.run_ticks(238944);
    s.rec_start();
    s.run_ticks(2 * 238944 + 2000);
    s.rec_stop();
    s.compare("thin");
    write_images(s.rec, outdir + "/thin");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string fontfile;
    std::vector<std::string> tests;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-f" && i + 1 < argc) fontfile = argv[++i];
        else if (a == "-o" && i + 1 < argc) outdir = argv[++i];
        else tests.push_back(a);
    }
    std::vector<uint8_t> font(8192, 0);
    FILE *f = fopen(fontfile.c_str(), "rb");
    if (!f || fread(font.data(), 1, 8192, f) != 8192) { fprintf(stderr, "font %s?\n", fontfile.c_str()); return 2; }
    fclose(f);
    if (tests.empty()) tests = {"waits", "mode", "status", "torture", "crtc", "cursor", "snow", "blink", "thin"};
    for (auto &t : tests) {
        if (t == "waits") test_waits(font);
        else if (t == "mode") for (int m = 0; m <= 6; m++) test_mode(font, m);
        else if (t.rfind("mode", 0) == 0) test_mode(font, atoi(t.c_str() + 4));
        else if (t == "status") test_status(font);
        else if (t == "torture") { for (int sd = 1; sd <= 4; sd++) test_torture(font, sd, sd & 1 ? 3 : 4); }
        else if (t == "crtc") { for (int sd = 1; sd <= 4; sd++) test_crtc(font, sd); }
        else if (t == "snow") test_snow(font);
        else if (t == "cursor") test_cursor(font);
        else if (t == "blink") test_blink(font);
        else if (t == "thin") test_thin(font);
        else { fprintf(stderr, "unknown test %s\n", t.c_str()); return 2; }
    }
    printf(failures ? "FAILED: %d checks\n" : "PASS\n", failures);
    return failures ? 1 : 0;
}
