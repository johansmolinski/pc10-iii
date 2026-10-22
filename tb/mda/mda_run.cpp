// mda_run.cpp - Verilator testbench for rtl/video/mda (doc/mda.md section 8).
//
// The card is driven by a model of the pc10-iii system board's bus timing
// (rtl/system/xt_board.sv: 8288 command edges, IOCHRDY synchronised on the
// falling CLK edge, one wait state on CPU I/O cycles; biu88.v: READY sampled
// as T3 and each Tw begin, so the falling edge before a state decides whether
// it is the last) with the clock enables of pc_clocks.sv. Next to it runs mda_model.h, a C++ model written from the
// IBM logic diagrams, stepped on the same clk. Every clk, the card's IOCHRDY
// is compared with the model; every dot (video, intensity, syncs, window)
// and every read are compared too. Tests (MDA build):
//   waits    random VRAM and 6845 accesses: wait states against the slot
//            model, their distribution, MartyPC's MDA numbers for reference;
//   text     IBM BIOS mode 7, all characters and attributes, 2 frames,
//            line and frame periods, images;
//   attrs    the attribute decoder against MartyPC's MDA_ATTR_TABLE;
//   status   3BA read back-to-back over a frame;
//   torture  random 6845, mode and VRAM writes, every dot and read;
//   blink    70 frames: cursor and character blink rates;
//   hdrive   no HSYNC to the monitor before video is enabled (U45);
//   hres     no dot clock without 3B8 bit 0: a VRAM access never ends.
// Hercules build (-h): hgc (config switch, page mapping, CGA coexistence,
// status bit 7), hgctext, hgcgfx (720x348 both pages, images).
//
// usage: mda_run [-h] -f font.bin -o outdir [test ...]
//
// GPL-3.0-or-later, pc10-iii.

#include "Vmda_card.h"
#include "Vmda_card___024root.h"
#include "mda_model.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <deque>
#include <functional>
#include <map>
#include <random>
#include <string>
#include <vector>

#ifndef HERC_BUILD
#define HERC_BUILD 0
#endif

// IBM PC/XT BIOS VIDEO_PARMS for the MDA (also the MDA Technical Reference)
static const uint8_t PMDA[16] = {0x61, 0x50, 0x52, 0x0F, 0x19, 0x06, 0x19, 0x19, 0x02, 0x0D, 0x0B, 0x0C, 0, 0, 0, 0};
// Hercules 720x348 graphics (Hercules manual / MartyPC)
static const uint8_t PHGC[12] = {0x35, 0x2D, 0x2E, 0x07, 0x5B, 0x02, 0x57, 0x57, 0x02, 0x03, 0x00, 0x00};
// MartyPC devices/mda/mod.rs: WAIT_TABLE (the CGA's, indexed by the MDA's clock)
static const int WAIT_TABLE[16] = {14, 13, 12, 11, 10, 9, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15};

static int failures = 0;
#define CHECK(c, ...) do { if (!(c)) { failures++; if (failures < 40) { printf("FAIL: " __VA_ARGS__); printf("\n"); } } } while (0)

struct Op {
    enum Type { MEMR, MEMW, IOR, IOW, IDLE } t;
    uint32_t a;
    uint8_t d;
    int n;
    std::function<void(uint8_t)> cb;
};

struct Rec { uint8_t v, i, h, vs, hb, vb; };

struct Sim {
    Vmda_card *top;
    MdaModel g;
    uint64_t clk_n = 0;
    int c7 = 0, c21 = 0;

    enum TS { TI, T1, T2, T3, TW, T4 } ts = TI;
    std::deque<Op> q;
    Op cur{Op::IDLE, 0, 0, 0, nullptr};
    int idle_left = 0;
    bool cmd_rd = false, cmd_wr = false, rdy_sync = true;
    int tw = 0;
    bool t3_last = true;                 // biu88: READY sampled as T3/Tw begin
    uint64_t t2_dots = 0;
    bool prev_ior = false, prev_iow = false;
    uint32_t io_a = 0;
    uint8_t io_d = 0;
    uint64_t dots = 0;                   // model dots (rising edges)

    // statistics
    std::vector<Rec> rec;
    bool recording = false, keep = true;
    uint64_t cmp_n = 0, cmp_bad = 0, cmp_lit = 0, rdy_bad = 0;
    int reads_checked = 0;
    std::map<std::string, std::map<int, int>> tw_hist;
    std::map<int, int> marty_hist;
    bool hang_ok = false;                // hres test: bus may hang

    Sim(const std::vector<uint8_t> &font, bool cga = false) : g(HERC_BUILD) {
        top = new Vmda_card;
        top->clk = 0;
        top->reset = 1;
        top->cga_fitted = cga;
        g.cga_fitted = cga;
        set_bus();
        for (int i = 0; i < 8; i++) { top->clk = 0; top->eval(); top->clk = 1; top->eval(); }
        for (int a = 0; a < 8192; a++) {
            top->font_we = 1;
            top->font_addr = a;
            top->font_data = font[a];
            top->clk = 0; top->eval(); top->clk = 1; top->eval();
        }
        top->font_we = 0;
        memcpy(g.font, font.data(), 4096);
        top->reset = 0;
    }
    ~Sim() { top->final(); delete top; }

    bool is_read(const Op &o) const { return o.t == Op::MEMR || o.t == Op::IOR; }
    bool is_write(const Op &o) const { return o.t == Op::MEMW || o.t == Op::IOW; }
    bool is_io(const Op &o) const { return o.t == Op::IOR || o.t == Op::IOW; }
    bool in_cycle() const { return ts == T1 || ts == T2 || ts == T3 || ts == TW; }

    void set_bus() {
        top->isa_memr_n = !(cmd_rd && cur.t == Op::MEMR);
        top->isa_ior_n  = !(cmd_rd && cur.t == Op::IOR);
        top->isa_memw_n = !(cmd_wr && cur.t == Op::MEMW);
        top->isa_iow_n  = !(cmd_wr && cur.t == Op::IOW);
        top->isa_aen = 0;
    }
    void start_op() {
        cur = q.front();
        q.pop_front();
        ts = T1;
        tw = 0;
        top->isa_addr = cur.a;
        top->isa_dout = cur.a & 0xFF;
    }
    std::string kind() const {
        if (cur.t == Op::MEMR) return "MEMR";
        if (cur.t == Op::MEMW) return "MEMW";
        bool crtc = ((cur.a >> 4) & 0x3F) == 0x3B && !(cur.a & 8);
        return std::string(cur.t == Op::IOR ? "IOR" : "IOW") + (crtc ? " 6845" : " 3B8-F");
    }

    void step() {
        bool ce = c7 == 0, cs = c21 == 0, cf = c21 == 7;
        (void)ce;
        top->clk = 0;
        top->eval();
        bool ready = top->isa_ready;
        uint8_t din = top->isa_din;
        bool dsel = top->isa_dsel;

        // ---- model, same clk, same bus as the card sees
        bool memr = !top->isa_memr_n, memw = !top->isa_memw_n, ior = !top->isa_ior_n, iow = !top->isa_iow_n;
        uint32_t a = top->isa_addr;
        bool req = g.is_req(memr, memw, ior, iow, a);
        bool mready = g.ready(req);
        if (ready != mready) {
            if (rdy_bad < 5) printf("  clk %llu: IOCHRDY card %d model %d (%s %05X)\n",
                                    (unsigned long long)clk_n, ready, mready, kind().c_str(), a);
            rdy_bad++;
        }
        // read data the board takes at T4 (checked below), from the model now
        int m_io = ior ? g.io_read(a) : -1;
        int m_mem = memr && g.mem_off(a) >= 0 ? g.mem[g.mem_off(a)] : -1;
        MdaModel::Out o = g.step(memr, memw, ior, iow, a, top->isa_dout);
        dots = g.dots;
        if (iow) { io_a = a; io_d = top->isa_dout; }
        if (prev_iow && !iow) g.io_write(io_a, io_d);
        prev_iow = iow;
        prev_ior = ior;

        if (o.ce || top->vid_ce) {
            CHECK(o.ce == (bool)top->vid_ce, "vid_ce: card %d model %d at clk %llu", top->vid_ce, o.ce,
                  (unsigned long long)clk_n);
            if (recording) {
                Rec r{top->vid_video, top->vid_intens, top->vid_hsync, top->vid_vsync, top->vid_hblank, top->vid_vblank};
                if (keep) rec.push_back(r);
                cmp_n++;
                cmp_lit += r.v;
                if (r.v != o.v || r.i != o.i || r.h != o.hs || r.vs != o.vs || r.hb != o.hb || r.vb != o.vb) {
                    if (cmp_bad < 5)
                        printf("  dot %llu: card v%d i%d h%d v%d hb%d vb%d, model v%d i%d h%d v%d hb%d vb%d\n",
                               (unsigned long long)cmp_n, r.v, r.i, r.h, r.vs, r.hb, r.vb, o.v, o.i, o.hs, o.vs,
                               o.hb, o.vb);
                    cmp_bad++;
                }
            }
        }

        // ---- board (xt_board.sv)
        bool ncmd_rd = cmd_rd, ncmd_wr = cmd_wr;
        if (!in_cycle()) ncmd_rd = ncmd_wr = false;
        else if (cf) {
            if (ts == T1 && is_read(cur)) ncmd_rd = true;
            if (ts == T2 && is_write(cur)) ncmd_wr = true;
        }
        if (cf) rdy_sync = ready;
        if (cs) {
            bool cpu_ready = rdy_sync;
            switch (ts) {
            case TI:
            case T4:
                if (idle_left > 0) { idle_left--; ts = TI; break; }
                while (!q.empty() && q.front().t == Op::IDLE) { idle_left = q.front().n; q.pop_front(); }
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
                t2_dots = dots;
                t3_last = rdy_sync && !is_io(cur);
                break;
            case T3:
            case TW:
                if (t3_last) {
                    ts = T4;
                    tw_hist[kind()][tw]++;
                    if (cur.t == Op::MEMR || cur.t == Op::MEMW) {
                        // MartyPC: phase = (MDA clock + 1) & 15 at the end of T2
                        int p = (int)((t2_dots + 1) & 15);
                        marty_hist[(WAIT_TABLE[p] + 2) / 3]++;
                    }
                    if (cur.t == Op::IOR) {
                        if (m_io < 0) CHECK(!dsel, "IOR %03X: card drives the bus", cur.a);
                        else CHECK(dsel && din == m_io, "IOR %03X: card %02X model %02X", cur.a, din, m_io);
                        reads_checked++;
                    }
                    if (cur.t == Op::MEMR) {
                        if (m_mem < 0) CHECK(!dsel, "MEMR %05X: card drives the bus", cur.a);
                        else CHECK(dsel && din == m_mem, "MEMR %05X: card %02X model %02X", cur.a, din, m_mem);
                        reads_checked++;
                    }
                    if (cur.cb) cur.cb(dsel ? din : 0xFF);
                } else {
                    ts = TW;
                    tw++;
                    t3_last = cpu_ready;
                    if (!hang_ok && tw == 40) {
                        CHECK(false, "bus hangs at %05X", cur.a);
                        printf("FAILED: bus hangs\n");
                        exit(1);
                    }
                }
                break;
            }
        }
        cmd_rd = ncmd_rd;
        cmd_wr = ncmd_wr;
        c7 = c7 == 6 ? 0 : c7 + 1;
        c21 = c21 == 20 ? 0 : c21 + 1;

        top->clk = 1;
        top->eval();
        set_bus();
        clk_n++;
    }

    bool busy() const { return !q.empty() || ts != TI || idle_left > 0; }
    void run_ops() { while (busy()) step(); }
    void run_dots(uint64_t n) { uint64_t t = dots + n; while (dots < t) step(); }
    void run_to_vsync() {
        bool p = g.vs1;
        for (;;) { step(); if (g.vs1 && !p) break; p = g.vs1; }
    }

    void iow(int port, uint8_t d) { q.push_back({Op::IOW, (uint32_t)port, d, 0, nullptr}); }
    void ior(int port, std::function<void(uint8_t)> cb = nullptr) { q.push_back({Op::IOR, (uint32_t)port, 0, 0, cb}); }
    void memw(uint32_t a, uint8_t d) { q.push_back({Op::MEMW, a, d, 0, nullptr}); }
    void memr(uint32_t a, std::function<void(uint8_t)> cb = nullptr) { q.push_back({Op::MEMR, a, 0, 0, cb}); }
    void idle(int n) { if (n > 0) q.push_back({Op::IDLE, 0, 0, n, nullptr}); }
    void crtc(int r, uint8_t v) { iow(0x3B4, r); iow(0x3B5, v); }

    // IBM BIOS mode 7: 3B8 = 01 (high resolution first, Technical Reference),
    // 6845 table, 3B8 = 29 (video on, blink)
    void bios_mode7(uint8_t m = 0x29) {
        iow(0x3B8, 0x01);
        for (int i = 0; i < 16; i++) crtc(i, PMDA[i]);
        iow(0x3B8, m);
    }

    void rec_start(bool keep_dots = true) {
        rec.clear(); recording = true; keep = keep_dots;
        cmp_n = cmp_bad = cmp_lit = 0;
    }
    void rec_stop() { recording = false; }
    void compare(const char *what) {
        CHECK(cmp_bad == 0, "%s: %llu of %llu dots differ", what, (unsigned long long)cmp_bad,
              (unsigned long long)cmp_n);
        CHECK(rdy_bad == 0, "%s: IOCHRDY differs in %llu clk", what, (unsigned long long)rdy_bad);
        printf("  %s: %llu dots compared, %llu lit\n", what, (unsigned long long)cmp_n,
               (unsigned long long)cmp_lit);
    }
};

// ---------------------------------------------------------------- images
// green phosphor: (video, intensity)
static const uint8_t PAL[4][3] = {{0x00, 0x00, 0x00}, {0x10, 0x40, 0x10}, {0x20, 0xB0, 0x20}, {0x70, 0xFF, 0x70}};

static void write_images(const std::vector<Rec> &r, const std::string &base, int W, int H) {
    size_t s = 1;
    while (s < r.size() && !(r[s].vs && !r[s - 1].vs)) s++;
    if (s >= r.size()) { printf("  no VSYNC in the recording\n"); return; }
    std::vector<uint8_t> full(W * H * 3, 0x20), win;
    int x = 0, y = 0, ww = 0, wh = 0, wx = 0;
    std::vector<uint8_t> row;
    for (size_t k = s; k < r.size(); k++) {
        if (k > s && r[k].vs && !r[k - 1].vs) break;
        if (r[k].h && !r[k - 1].h) { x = 0; if (k > s) y++; }
        const uint8_t *c = PAL[r[k].v * 2 + r[k].i];
        if (x < W && y < H) {
            uint8_t *p = &full[(y * W + x) * 3];
            if (r[k].h || r[k].vs) { p[0] = 0x30; p[1] = 0x30; p[2] = r[k].vs ? 0x80 : 0x30; }
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
    printf("  images: %s_field.ppm (%dx%d), _window.ppm (%dx%d)\n", base.c_str(), W, H, ww, wh);
}

static void check_periods(const std::vector<Rec> &r, const char *what, int hper, int vper) {
    std::vector<size_t> hs, vs;
    for (size_t k = 1; k < r.size(); k++) {
        if (r[k].h && !r[k - 1].h) hs.push_back(k);
        if (r[k].vs && !r[k - 1].vs) vs.push_back(k);
    }
    int hbad = 0, vbad = 0;
    for (size_t i = 1; i < hs.size(); i++) if ((int)(hs[i] - hs[i - 1]) != hper) hbad++;
    for (size_t i = 1; i < vs.size(); i++) if ((int)(vs[i] - vs[i - 1]) != vper) vbad++;
    CHECK(hs.size() > 2 && hbad == 0, "%s: %d of %zu lines not %d dots", what, hbad, hs.size(), hper);
    CHECK(vs.size() >= 2 && vbad == 0, "%s: %d of %zu frames not %d dots", what, vbad, vs.size(), vper);
    printf("  %zu lines of %d dots, %zu frames of %d dots (%d lines)\n", hs.size(),
           hs.size() > 1 ? (int)(hs[1] - hs[0]) : -1, vs.size(), vs.size() > 1 ? (int)(vs[1] - vs[0]) : -1,
           vs.size() > 1 ? (int)(vs[1] - vs[0]) / hper : -1);
    // where the lit dots are, counted from the sync starts (after the first VSYNC)
    int x0 = -1, x1 = -1, y0 = -1, y1 = -1, hp = 0, vp = -1;
    for (size_t k = 1; k < r.size(); k++) {
        if (r[k].vs && !r[k - 1].vs) vp = 0;
        else if (r[k].h && !r[k - 1].h && vp >= 0) vp++;
        if (r[k].h && !r[k - 1].h) hp = 0;
        if (r[k].v && vp >= 0) {
            if (x0 < 0 || hp < x0) x0 = hp;
            if (hp > x1) x1 = hp;
            if (y0 < 0 || vp < y0) y0 = vp;
            if (vp > y1) y1 = vp;
        }
        hp++;
    }
    printf("  lit dots between x %d-%d, lines %d-%d (from the sync starts)\n", x0, x1, y0, y1);
}

// ---------------------------------------------------------------- content
static void fill_text(Sim &s) {
    static const uint8_t ATT[] = {0x07, 0x0F, 0x01, 0x09, 0x70, 0x78, 0x87, 0xF0, 0x00, 0x7F, 0x8F, 0x71};
    for (int i = 0; i < 2000; i++) {
        int row = i / 80, col = i % 80;
        uint8_t ch = (uint8_t)(row < 16 ? (row * 16 + (col % 16)) : (0xC0 + (i % 32)));
        uint8_t at = ATT[(col / 16 + row) % 12];
        if (row >= 16) at = (row & 1) ? 0x07 : 0x70;
        s.memw(0xB0000 + i * 2, ch);
        s.memw(0xB0000 + i * 2 + 1, at);
    }
}

static std::string outdir = ".";
static const int MDA_LINE = 882, MDA_FRAME = 882 * 370;

static void test_text(const std::vector<uint8_t> &font) {
    printf("text (mode 7)\n");
    Sim s(font);
    s.bios_mode7();
    fill_text(s);
    s.crtc(14, (12 * 80 + 10) >> 8);
    s.crtc(15, (12 * 80 + 10) & 0xFF);
    s.run_ops();
    s.run_dots(9 * MDA_FRAME);           // past the first cursor-off phase (8 frames)
    s.rec_start();
    s.run_dots(2 * MDA_FRAME + 2000);
    s.rec_stop();
    s.compare("text");
    check_periods(s.rec, "text", MDA_LINE, MDA_FRAME);
    write_images(s.rec, outdir + "/text", MDA_LINE, 370);
}

static void test_waits(const std::vector<uint8_t> &font) {
    printf("waits\n");
    Sim s(font);
    s.bios_mode7();
    s.run_ops();
    std::mt19937 rng(11);
    for (int k = 0; k < 3000; k++) {
        s.idle(rng() % 9);
        switch (rng() % 6) {
        case 0: case 1: s.memr(0xB0000 + (rng() % 0x8000)); break;    // mirrored 4 KB
        case 2: case 3: s.memw(0xB0000 + (rng() % 0x8000), rng() & 0xFF); break;
        case 4: s.iow(0x3B4, 14 + (rng() & 1)); s.ior(0x3B5); break;
        default: s.ior(0x3BA); break;
        }
    }
    s.run_ops();
    CHECK(s.rdy_bad == 0, "waits: IOCHRDY differs in %llu clk", (unsigned long long)s.rdy_bad);
    for (auto &h : s.tw_hist) {
        int n = 0, sum = 0, lo = 99, hi = -1;
        printf("  %-10s", h.first.c_str());
        for (auto &e : h.second) {
            printf(" %dTw:%d", e.first, e.second);
            n += e.second; sum += e.first * e.second;
            lo = std::min(lo, e.first); hi = std::max(hi, e.first);
        }
        printf("   (mean %.2f)\n", (double)sum / n);
        // the slot: IOCHRDY 5.5 to 14.5 dots after the strobe; with the
        // board's MEMR at the falling edge in T1 and READY sampled at the
        // falling edge before each T3/Tw: 1-4. MEMW starts at the falling
        // edge in T2, which already decides T3: never a wait (doc/mda.md 4.2)
        if (h.first == "MEMR") CHECK(lo == 1 && hi == 4, "MEMR waits %d-%d, expected 1-4", lo, hi);
        if (h.first == "MEMW") CHECK(lo == 0 && hi == 0, "MEMW waits %d-%d, expected 0", lo, hi);
        if (h.first == "IOR 3B8-F") CHECK(lo == 1 && hi == 1, "3BA waits %d-%d, expected 1 (the board's)", lo, hi);
        if (h.first == "IOR 6845") CHECK(lo == 1 && hi == 4, "6845 IOR waits %d-%d, expected 1-4", lo, hi);
        if (h.first == "IOW 6845") CHECK(lo == 2 && hi == 5, "6845 IOW waits %d-%d, expected 2-5", lo, hi);
    }
    int n = 0, sum = 0;
    printf("  MartyPC   ");
    for (auto &e : s.marty_hist) { printf(" %dTw:%d", e.first, e.second); n += e.second; sum += e.first * e.second; }
    printf("   (mean %.2f; MartyPC's MDA uses the CGA's table, doc/mda.md 4.3)\n", n ? (double)sum / n : 0.0);
    printf("  %d reads checked\n", s.reads_checked);
}

// attribute decoder against MartyPC's MDA_ATTR_TABLE: (fg, bg) brightness
// 0 black, 1 dark (intensity without video), 2 normal, 3 bright
static const char *MARTY_ATTR =
    "00202020202020200030303030303030" "20202020202020203030303030303030"
    "20202020202020203030303030303030" "20202020202020203030303030303030"
    "20202020202020203030303030303030" "20202020202020203030303030303030"
    "20202020202020203030303030303030" "02202020202020201230303030303030"
    "00202020202020200030303030303030" "20202020202020203030303030303030"
    "20202020202020203030303030303030" "20202020202020203030303030303030"
    "20202020202020203030303030303030" "20202020202020203030303030303030"
    "20202020202020203030303030303030" "02202020202020201230303030303030";

static void test_attrs(const std::vector<uint8_t> &font) {
    (void)font;
    printf("attrs (against MartyPC's MDA_ATTR_TABLE)\n");
    int diff_bg = 0, diff_other = 0;
    for (int blink = 1; blink >= 0; blink--)
        for (int a = 0; a < 256; a++) {
            MdaModel m(false);
            m.mode = 0x09 | (blink ? 0x20 : 0);
            m.crtc.cursor_enabled = false;
            m.s1_att = (uint8_t)a; m.s1_chr = 0x41; m.n_glyph = 0xF0;
            m.de1 = true;
            m.cclk_rise();
            bool v, i;
            m.ph = 0; m.dot_value(v, i); int fg = v * 2 + i;
            m.ph = 5; m.dot_value(v, i); int bg = v * 2 + i;
            int mf = MARTY_ATTR[a * 2] - '0', mb = MARTY_ATTR[a * 2 + 1] - '0';
            if (fg == mf && bg == mb) continue;
            // known: with blink off, bit 7 is background intensity (U46/U63);
            // MartyPC has no background intensity (only the intensity bit differs)
            if (!blink && (a & 0x80) && (fg ^ mf) <= 1 && (bg ^ mb) == 1) { diff_bg++; continue; }
            if (diff_other < 10) printf("  attr %02X blink %d: card fg %d bg %d, MartyPC fg %d bg %d\n", a, blink, fg, bg, mf, mb);
            diff_other++;
        }
    printf("  512 cases: %d differ only in the background intensity (blink off, bit 7), %d otherwise\n", diff_bg,
           diff_other);
    CHECK(diff_other == 0, "attrs: %d attributes differ from MartyPC", diff_other);
}

static void test_status(const std::vector<uint8_t> &font) {
    printf("status\n");
    Sim s(font);
    s.bios_mode7();
    for (int i = 0; i < 2000; i++) { s.memw(0xB0000 + i * 2, (i / 80) < 12 ? 0xDB : 0x20); s.memw(0xB0001 + i * 2, 0x07); }
    s.run_ops();
    s.run_dots(MDA_FRAME);
    int n = 0, n1 = 0, n8 = 0;
    uint64_t t0 = s.dots;
    while (s.dots < t0 + MDA_FRAME) {
        for (int i = 0; i < 64; i++) s.ior(0x3BA, [&](uint8_t v) { n++; n1 += v & 1; n8 += (v >> 3) & 1; });
        s.run_ops();
    }
    printf("  %d reads: bit 0 set in %d, bit 3 set in %d (%d checked against the model)\n", n, n1, n8,
           s.reads_checked);
    // HSYNC 15 characters + 1 (U101 stretch) of 98; video: 12 of 25 rows x 720 dots lit
    double f1 = (double)n1 / n, f8 = (double)n8 / n;
    CHECK(f1 > 0.15 && f1 < 0.18, "status: bit 0 fraction %.3f (16/98 = 0.163)", f1);
    CHECK(f8 > 0.20 && f8 < 0.32, "status: bit 3 fraction %.3f (12 x 14 x 720 / 326340 = 0.37 minus gaps)", f8);
    CHECK(s.rdy_bad == 0, "status: IOCHRDY differs");
}

static void test_torture(const std::vector<uint8_t> &font, int seed) {
    printf("torture seed %d\n", seed);
    Sim s(font);
    std::mt19937 rng(seed);
    auto R = [&](int n) { return (int)(rng() % n); };
    s.bios_mode7();
    fill_text(s);
    s.run_ops();
    s.rec_start(false);
    uint64_t t0 = s.dots;
    int nw = 0;
    while (s.dots < t0 + 4 * MDA_FRAME) {
        s.idle(R(300));
        switch (R(12)) {
        case 0: s.iow(0x3B8, (uint8_t[]){0x29, 0x09, 0x21, 0x01, 0x2D, 0xFF}[R(6)]); break;
        case 1: s.crtc(12, R(8)); break;
        case 2: s.crtc(13, R(256)); break;
        case 3: s.crtc(1, 40 + R(60)); break;
        // seeds 1 and 2 keep HSYNC ending before C0 = 0 (else the 6845
        // never ends a frame: last-line rule); seed 3 does not
        case 4: s.crtc(2, seed == 3 ? 70 + R(25) : 80 + R(3)); break;
        case 5: s.crtc(3, seed == 3 ? R(256) : (1 + R(14)) | (R(16) << 4)); break;
        case 6: if (R(2)) s.crtc(4, 0x19 + R(4)); else s.crtc(9, 11 + R(5)); break;
        case 7: s.crtc(R(2) ? 6 : 7, 20 + R(8)); break;
        case 8: s.crtc(R(2) ? 10 : 11, R(128)); break;
        case 9: s.crtc(R(2) ? 14 : 15, R(256)); break;
        case 10: for (int k = 0; k < 8; k++) s.memw(0xB0000 + R(4096), R(256)); break;
        default: s.memr(0xB0000 + R(4096)); s.iow(0x3B4, 14 + R(4)); s.ior(0x3B5); break;
        }
        s.ior(0x3BA);
        nw++;
        s.run_ops();
        if (getenv("MDADBG") && nw % 200 == 0) {
            printf("  [%d] lit %llu mode %02X regs", nw, (unsigned long long)s.cmp_lit, s.g.mode);
            for (int i = 0; i < 16; i++) printf(" %02X", s.g.crtc.reg[i]);
            printf(" vcc %d vlc %d\n", s.g.crtc.vcc, s.g.crtc.vlc);
        }
    }
    s.rec_stop();
    if (getenv("MDADBG")) {
        printf("  mode %02X regs", s.g.mode);
        for (int i = 0; i < 16; i++) printf(" %02X", s.g.crtc.reg[i]);
        printf(" vcc %d vlc %d hcc %d de %d\n", s.g.crtc.vcc, s.g.crtc.vlc, s.g.crtc.hcc, s.g.crtc.den());
    }
    printf("  %d operations, %d reads checked\n", nw, s.reads_checked);
    s.compare("torture");
}

static void test_blink(const std::vector<uint8_t> &font) {
    printf("blink (70 frames)\n");
    Sim s(font);
    s.bios_mode7();
    fill_text(s);
    s.crtc(14, 0x03); s.crtc(15, 0x20);
    s.run_ops();
    s.rec_start(false);
    // lit dots per frame (VSYNC to VSYNC): they change when the cursor (every
    // 8 frames) or the blinking characters (every 16) toggle
    std::vector<uint64_t> lit;
    for (int f = 0; f < 71; f++) {
        s.run_to_vsync();
        lit.push_back(s.cmp_lit);
    }
    s.rec_stop();
    s.compare("blink");
    std::vector<int> at;
    for (size_t i = 2; i < lit.size(); i++)
        if (lit[i] - lit[i - 1] != lit[i - 1] - lit[i - 2]) at.push_back((int)i - 1);
    printf("  frame lit count changes at frames");
    int bad = 0;
    for (size_t i = 0; i < at.size(); i++) {
        printf(" %d", at[i]);
        if (i && at[i] - at[i - 1] != 8) bad++;
    }
    printf(" (every 8 frames)\n");
    CHECK(at.size() >= 8 && bad == 0, "blink: %zu changes, %d not 8 frames apart", at.size(), bad);
    // the characters: frames with the cursor on come in two kinds
    std::map<uint64_t, int> kinds;
    for (size_t i = 1; i < lit.size(); i++) kinds[lit[i] - lit[i - 1]]++;
    printf("  %zu different frames (cursor on/off x characters on/off)\n", kinds.size());
    CHECK(kinds.size() == 4, "blink: %zu kinds of frames, expected 4", kinds.size());
    // VSYNC inside the displayed rows: the blink toggles where U28 counts
    // (the end of VSYNC) become visible
    s.crtc(7, 10);
    s.run_ops();
    s.rec_start(false);
    s.run_dots(34 * MDA_FRAME);
    s.rec_stop();
    s.compare("blink, VSYNC at row 10");
}

// U45: no horizontal drive to the monitor until video has been enabled once
static void test_hdrive(const std::vector<uint8_t> &font) {
    printf("hdrive\n");
    Sim s(font);
    s.iow(0x3B8, 0x01);
    for (int i = 0; i < 16; i++) s.crtc(i, PMDA[i]);
    s.run_ops();
    s.rec_start();
    s.run_dots(MDA_FRAME);
    int h = 0, v = 0;
    for (auto &r : s.rec) { h += r.h; v += r.vs; }
    printf("  video never enabled: %d dots with HSYNC, %d with VSYNC\n", h, v);
    CHECK(h == 0 && v > 0, "hdrive: HSYNC before video enable (%d dots)", h);
    s.iow(0x3B8, 0x29);
    s.iow(0x3B8, 0x21);                  // video off again: the drive stays on
    s.run_ops();
    s.rec_start();
    s.run_dots(MDA_FRAME);
    h = 0;
    for (auto &r : s.rec) h += r.h;
    printf("  after one enable: %d dots with HSYNC\n", h);
    CHECK(h > 50000, "hdrive: no HSYNC after video enable");
    s.compare("hdrive");
}

static void test_hres(const std::vector<uint8_t> &font) {
    printf("hres (3B8 bit 0 clear)\n");
    Sim s(font);
    s.bios_mode7();
    s.memw(0xB0000, 0x41);
    s.run_ops();
    printf("  with bit 0: a VRAM write done\n");
    CHECK(s.g.mem[0] == 0x41 && s.top->rootp->mda_card__DOT__vram[0] == 0x41, "hres: write lost");
    s.iow(0x3B8, 0x28);
    s.memr(0xB0002);
    s.hang_ok = true;
    for (int i = 0; i < 20000; i++) s.step();
    CHECK(s.ts == Sim::TW && s.cur.t == Op::MEMR, "hres: the VRAM read ended without the dot clock");
    printf("  without bit 0: the read is still waiting after 20000 clk (%d wait states)\n", s.tw);
    CHECK(s.rdy_bad == 0, "hres: IOCHRDY differs");
}

// ---------------------------------------------------------------- Hercules
static void test_hgc(const std::vector<uint8_t> &font) {
    printf("hgc: configuration switch, mapping, status\n");
    for (int cga = 0; cga <= 1; cga++) {
        Sim s(font, cga);
        s.bios_mode7();
        // config 0: graphics and page bits ignored, B8000 not mapped
        s.iow(0x3B8, 0x8B);
        s.memw(0xB8000, 0x55);
        s.memr(0xB8000);
        s.run_ops();
        CHECK(s.top->rootp->mda_card__DOT__mode == s.g.mode && (s.g.mode & 0x82) == 0,
              "hgc: mode %02X with config 0", s.g.mode);
        // config 3: both allowed; B8000 only without a CGA
        s.iow(0x3BF, 0x03);
        s.iow(0x3B8, 0x8B);
        s.memw(0xB8001, 0xAA);
        bool driven = false;
        s.memr(0xB8001, [&](uint8_t v) { driven = v == 0xAA; });
        s.memw(0xB7FFF, 0x5A);
        uint8_t lo = 0;
        s.memr(0xB7FFF, [&](uint8_t v) { lo = v; });
        s.run_ops();
        CHECK(s.top->rootp->mda_card__DOT__mode == s.g.mode && (s.g.mode & 0x82) == 0x82,
              "hgc: mode %02X with config 3", s.g.mode);
        CHECK(driven == !cga, "hgc: B8000 %s with cga_fitted %d", driven ? "mapped" : "not mapped", cga);
        CHECK(lo == 0x5A, "hgc: B7FFF read %02X", lo);
        printf("  cga_fitted %d: B8000-BFFFF %s, mode %02X\n", cga, driven ? "mapped" : "not mapped", s.g.mode);
        CHECK(s.rdy_bad == 0, "hgc: IOCHRDY differs");
    }
    // status bit 7 = not vertical retrace
    Sim s(font);
    s.bios_mode7();
    s.run_ops();
    int n = 0, n7 = 0;
    uint64_t t0 = s.dots;
    while (s.dots < t0 + 882 * 370) {
        for (int i = 0; i < 64; i++) s.ior(0x3BA, [&](uint8_t v) { n++; n7 += v >> 7; });
        s.run_ops();
    }
    double f = 1.0 - (double)n7 / n;
    printf("  status bit 7 clear in %.3f of %d reads (VSYNC 16 of 370 lines = 0.043)\n", f, n);
    CHECK(f > 0.035 && f < 0.05, "hgc: bit 7 fraction %.3f", f);
}

static void test_hgctext(const std::vector<uint8_t> &font) {
    printf("hgctext (mode 7 on the HGC, 16 MHz)\n");
    Sim s(font);
    s.bios_mode7();
    fill_text(s);
    s.run_ops();
    s.run_dots(9 * MDA_FRAME);
    s.rec_start();
    s.run_dots(2 * MDA_FRAME + 2000);
    s.rec_stop();
    s.compare("hgctext");
    check_periods(s.rec, "hgctext", MDA_LINE, MDA_FRAME);
    write_images(s.rec, outdir + "/hgctext", MDA_LINE, 370);
}

static void test_hgcgfx(const std::vector<uint8_t> &font) {
    printf("hgcgfx (720x348, pages 0 and 1)\n");
    Sim s(font);
    s.iow(0x3BF, 0x03);
    s.iow(0x3B8, 0x03);                  // graphics, video off
    for (int i = 0; i < 12; i++) s.crtc(i, PHGC[i]);
    // page 0: a grid and diagonals; page 1: inverse
    for (int y = 0; y < 348; y++)
        for (int xb = 0; xb < 90; xb++) {
            uint32_t off = (y & 3) * 0x2000 + (y >> 2) * 90 + xb;
            int x = xb * 8;
            uint8_t v = 0;
            for (int b = 0; b < 8; b++) {
                int px = x + b;
                bool on = (px % 60 == 0) || (y % 58 == 0) || ((px - y * 2) % 97 == 0) || (px / 4 == y / 2);
                if (on) v |= 0x80 >> b;
            }
            s.memw(0xB0000 + off, v);
            s.memw(0xB8000 + off, (uint8_t)~v);
        }
    s.iow(0x3B8, 0x0B);                  // graphics, video on, page 0
    s.run_ops();
    s.run_dots(2 * 864 * 370);
    s.rec_start();
    s.run_dots(2 * 864 * 370 + 2000);
    s.rec_stop();
    s.compare("hgcgfx page 0");
    check_periods(s.rec, "hgcgfx", 864, 864 * 370);
    write_images(s.rec, outdir + "/hgcgfx0", 864, 370);
    s.iow(0x3B8, 0x8B);                  // page 1
    s.run_ops();
    s.run_dots(864 * 370);
    s.rec_start();
    s.run_dots(864 * 370 + 2000);
    s.rec_stop();
    s.compare("hgcgfx page 1");
    write_images(s.rec, outdir + "/hgcgfx1", 864, 370);
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
    if (tests.empty()) {
        if (HERC_BUILD) tests = {"hgc", "hgctext", "hgcgfx"};
        else tests = {"waits", "text", "attrs", "status", "torture", "blink", "hdrive", "hres"};
    }
    for (auto &t : tests) {
        if (t == "waits") test_waits(font);
        else if (t == "text") test_text(font);
        else if (t == "attrs") test_attrs(font);
        else if (t == "status") test_status(font);
        else if (t == "torture") { for (int sd = 1; sd <= 3; sd++) test_torture(font, sd); }
        else if (t == "blink") test_blink(font);
        else if (t == "hres") test_hres(font);
        else if (t == "hdrive") test_hdrive(font);
        else if (t == "hgc") test_hgc(font);
        else if (t == "hgctext") test_hgctext(font);
        else if (t == "hgcgfx") test_hgcgfx(font);
        else { fprintf(stderr, "unknown test %s\n", t.c_str()); return 2; }
    }
    printf(failures ? "FAILED: %d checks\n" : "PASS\n", failures);
    return failures ? 1 : 0;
}
