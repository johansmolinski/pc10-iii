// pvc4_run.cpp - Verilator testbench for rtl/video/pvc4 (doc/pvc4.md section 9).
//
// The chip is driven by a model of the pc10-iii system board's bus timing
// (rtl/system/xt_board.sv: the 8288 command edges, the commands ending at the
// CLK edge where T4 begins, READY sampled on rdy_ce 1 clk before the rising
// CLK edge that ends a state, one wait state on CPU I/O cycles, the card bus's
// next-clk values; biu88's READY rule) with the clock enables of pc_clocks.sv
// (2 clk per OSC tick, 6 per CPU clock). Next to it runs pvc4_model.h, stepped
// on the same clk. Every clk READY is compared with the model; every dot
// (colour: RGBI and the syncs DLY ticks late, as in tb/cga; mono: video,
// intensity, syncs and window at vid_ce, as in tb/mda) and every read.
//
// Tests:
//   regs     the unlock sequence, the Paradise and Configuration registers,
//            the mapping switch 3Dx <-> 3Bx, 3X8 read back, the clearing rules
//            of 3DD/3DE/3BF, the CRTC lock and the underline row, R8/R10,
//            the light pen ports, the status bits, the disabled chip (230h);
//   waits    random VRAM reads/writes at random gaps in both personalities:
//            READY against the sequence rule at every clk, wait states;
//   cmodeN   BIOS modes 0-6: every dot of 2 frames, line/frame periods, images;
//   flicker  mode 3 with 3D8 bit 3 = 0: shown (Paradise bit 2 = 0), blank
//            after the unlock writes bit 2 = 1;
//   plant    Plantronics 320x200x16 and 640x200x4, the plane swap;
//   nosnow   80-column text with VRAM writes during the display;
//   status   3DA / 3BA back-to-back over a frame;
//   torture  random register and VRAM traffic, every dot and read (colour);
//   mono     mode 7 (9-dot characters, 16.257 MHz), periods, images;
//   mono8    8-dot characters (Paradise bit 5 = 0);
//   mtorture random traffic in the mono personality;
//   hgc      Hercules 720x348, both pages;
//   cbm      the Commodore character ROM layout (A14, A13 = 3DE bit 2, A11);
//   blink    34 frames of mode 3 with blinking characters and the cursor.
//
// usage: pvc4_run -f font.bin -o outdir [test ...]
//
// GPL-3.0-or-later, pc10-iii.

#include "Vpvc4.h"
#include "Vpvc4___024root.h"
#include "pvc4_model.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <random>
#include <string>
#include <vector>

static const uint8_t P40[16]  = {0x38, 0x28, 0x2D, 0x0A, 0x1F, 0x06, 0x19, 0x1C, 0x02, 0x07, 0x06, 0x07, 0, 0, 0, 0};
static const uint8_t P80[16]  = {0x71, 0x50, 0x5A, 0x0A, 0x1F, 0x06, 0x19, 0x1C, 0x02, 0x07, 0x06, 0x07, 0, 0, 0, 0};
static const uint8_t PGFX[16] = {0x38, 0x28, 0x2D, 0x0A, 0x7F, 0x06, 0x64, 0x70, 0x02, 0x01, 0x06, 0x07, 0, 0, 0, 0};
static const uint8_t PMDA[16] = {0x61, 0x50, 0x52, 0x0F, 0x19, 0x06, 0x19, 0x19, 0x02, 0x0D, 0x0B, 0x0C, 0, 0, 0, 0};
// PC10-III manual 6-4: Hercules 720x348
static const uint8_t PHGC[12] = {0x36, 0x2D, 0x2F, 0x07, 0x5B, 0x00, 0x57, 0x53, 0x02, 0x03, 0x00, 0x00};
static const uint8_t MODE_REG[7] = {0x2C, 0x28, 0x2D, 0x29, 0x2A, 0x2E, 0x1E};

static int failures = 0;
#define CHECK(c, ...) do { if (!(c)) { failures++; if (failures < 40) { printf("FAIL: " __VA_ARGS__); printf("\n"); } } } while (0)

struct Op {
    enum Type { MEMR, MEMW, IOR, IOW, IDLE } t;
    uint32_t a;
    uint8_t d;
    int n;
    std::function<void(uint8_t)> cb;
};

struct Rec { uint8_t c, v, i, h, vs, hb, vb; };

struct Sim {
    Vpvc4 *top;
    Pvc4Model g;
    uint64_t clk_n = 0, hdl_ticks = 0, mdots = 0;
    int c2 = 0, c6 = 0;

    enum TS { TI, T1, T2, T3, TW, T4 } ts = TI;
    std::deque<Op> q;
    Op cur{Op::IDLE, 0, 0, 0, nullptr};
    int idle_left = 0;
    bool cmd_rd = false, cmd_wr = false, rdy_sync = true, t3_last = true;
    int tw = 0;

    std::vector<Rec> rec;
    bool recording = false, keep = true;
    uint64_t cmp_n = 0, cmp_bad = 0, cmp_lit = 0, rdy_bad = 0;
    int reads_checked = 0;
    int rdy_low = 0, rdy_low_max = 0;
    uint64_t we_bad = 0;              // VRAM write instants that differ    // READY low, clk
    std::map<std::string, std::map<int, int>> tw_hist;
    static constexpr int LAT = 6;        // colour: card tick k shows model dot k - LAT (as cga_card)

    Sim(const std::vector<uint8_t> &font, bool cbm, uint8_t par, uint8_t cnf = 0xF7,
        bool a14 = true, bool a11 = true) {
        top = new Vpvc4;
        top->clk = 0;
        top->reset = 1;
        top->enable = 1;
        top->par_strap = par;
        top->cnf_strap = cnf;
        top->cg_a14 = a14;
        top->cg_a11 = a11;
        top->font_cbm = cbm;
        g.par_strap = par; g.cnf_strap = cnf; g.a14 = a14; g.a11 = a11; g.cbm = cbm;
        set_bus();
        for (int i = 0; i < 8; i++) { top->clk = 0; top->eval(); top->clk = 1; top->eval(); }
        for (size_t a = 0; a < font.size(); a++) {
            top->font_we = 1;
            top->font_addr = a;
            top->font_data = font[a];
            top->clk = 0; top->eval(); top->clk = 1; top->eval();
            g.font[a] = font[a];
        }
        top->font_we = 0;
        // the reset ends where the counters are at their reset values: one more clk in reset
        top->clk = 0; top->eval(); top->clk = 1; top->eval();
        g.reset();
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
        top->lpen_trig = 0;
        top->lpen_sw = 0;
    }
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
        top->isa_dout = cur.a & 0xFF;
    }
    std::string kind() const {
        std::string p = g.mono() ? "mono " : "colour ";
        if (cur.t == Op::MEMR) return p + "MEMR";
        if (cur.t == Op::MEMW) return p + "MEMW";
        return p + (cur.t == Op::IOR ? "IOR" : "IOW");
    }

    void step() {
        bool ce = c2 == 0, cs = c6 == 0, cf = c6 == 2, cr = c6 == 5;
        top->ce_14m = ce;
        top->clk = 0;
        top->eval();
        bool hdl_tick = top->rootp->pvc4__DOT__tick;
        bool ready = top->isa_ready;
        uint8_t din = top->isa_din;
        bool dsel = top->isa_dsel;

        // ---- the model, same clk, same bus
        bool memr = !top->isa_memr_n, memw = !top->isa_memw_n, ior = !top->isa_ior_n;
        uint32_t a = top->isa_addr;
        bool mready = g.ready(memr, memw, a);
        if (ready != mready) {
            if (rdy_bad < 5) printf("  clk %llu: READY card %d model %d (%s %05X)\n",
                                    (unsigned long long)clk_n, ready, mready, kind().c_str(), a);
            rdy_bad++;
        }
        if (!ready) rdy_low++;
        else { if (rdy_low > rdy_low_max) rdy_low_max = rdy_low; rdy_low = 0; }
        int m_io = ior ? g.io_peek(a) : -1;
        int m_mem = memr && g.mem_off(a) >= 0 ? g.mem[g.mem_off(a)] : -1;
        bool hdl_we = top->rootp->pvc4__DOT__va_we;
        Pvc4Model::Out o = g.step(hdl_tick, memr, memw, a, top->isa_dout);
        if (hdl_we != g.wrote) {
            if (we_bad < 5) printf("  clk %llu: VRAM write card %d model %d (%05X)\n", (unsigned long long)clk_n,
                                   hdl_we, g.wrote, a);
            we_bad++;
        }

        if (g.mono() && (o.ce || top->vid_ce)) {
            CHECK(o.ce == (bool)top->vid_ce, "vid_ce: card %d model %d at clk %llu", top->vid_ce, o.ce,
                  (unsigned long long)clk_n);
            mdots++;
            if (recording) {
                Rec r{top->vid_rgbi, top->vid_mono, (uint8_t)(top->vid_rgbi >> 3), top->vid_hsync, top->vid_vsync,
                      top->vid_hblank, top->vid_vblank};
                if (keep) rec.push_back(r);
                cmp_n++;
                cmp_lit += r.v;
                if (r.v != o.v || r.i != o.i || r.c != o.rgbi || r.h != o.hs || r.vs != o.vs || r.hb != o.hb || r.vb != o.vb) {
                    if (cmp_bad < 5)
                        printf("  mono dot %llu: card v%d i%d h%d v%d hb%d vb%d, model v%d i%d h%d v%d hb%d vb%d\n",
                               (unsigned long long)cmp_n, r.v, r.i, r.h, r.vs, r.hb, r.vb, o.v, o.i, o.hs, o.vs,
                               o.hb, o.vb);
                    cmp_bad++;
                }
            }
        }

        // ---- board
        bool ncmd_rd = cmd_rd, ncmd_wr = cmd_wr;
        if (!in_cycle()) ncmd_rd = ncmd_wr = false;
        else if (cf) {
            if (ts == T1 && is_read(cur)) ncmd_rd = true;
            if (ts == T2 && is_write(cur)) ncmd_wr = true;
        }
        if (cr) rdy_sync = ready;
        if (cs) {
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
                t3_last = rdy_sync && !is_io(cur);
                break;
            case T3:
            case TW:
                if (t3_last) {
                    ts = T4;
                    ncmd_rd = ncmd_wr = false;   // the commands end at this edge
                    tw_hist[kind()][tw]++;
                    if (cur.t == Op::IOR) {
                        if (m_io < 0) CHECK(!dsel, "IOR %03X: card drives the bus (%02X)", cur.a, din);
                        else CHECK(dsel && din == m_io, "IOR %03X: card %02X model %02X", cur.a, din, m_io);
                        reads_checked++;
                    }
                    if (cur.t == Op::MEMR) {
                        if (m_mem < 0) CHECK(!dsel, "MEMR %05X: card drives the bus", cur.a);
                        else CHECK(dsel && din == m_mem, "MEMR %05X: card %02X model %02X", cur.a, din, m_mem);
                        reads_checked++;
                    }
                    if (is_io(cur)) g.io_end(cur.t == Op::IOR, cur.a, cur.d);
                    if (cur.cb) cur.cb(dsel ? din : 0xFF);
                } else {
                    ts = TW;
                    tw++;
                    t3_last = rdy_sync;
                    if (tw == 60) { printf("FAILED: bus hangs at %05X\n", cur.a); exit(1); }
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
            if (recording && !g.mono()) {
                Rec r{top->vid_rgbi, 0, 0, top->vid_hsync, top->vid_vsync, top->vid_hblank, top->vid_vblank};
                if (keep) rec.push_back(r);
                uint64_t n = hdl_ticks - LAT;
                CHECK(n < g.c.dots_written && n + g.c.dots.size() > g.c.dots_written,
                      "dot %llu not in the model", (unsigned long long)n);
                const auto &d = g.c.dots[n % g.c.dots.size()];
                cmp_n++;
                cmp_lit += r.c != 0;
                if (r.c != d.c || r.h != d.h || r.vs != d.v) {
                    if (cmp_bad < 5)
                        printf("  dot %llu: card c%X h%d v%d, model c%X h%d v%d\n", (unsigned long long)n,
                               r.c, r.h, r.vs, d.c, d.h, d.v);
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
    void run_mdots(uint64_t n) { uint64_t t = mdots + n; while (mdots < t) step(); }
    void run_clk(uint64_t n) { for (uint64_t i = 0; i < n; i++) step(); }

    void iow(int port, uint8_t d) { q.push_back({Op::IOW, (uint32_t)port, d, 0, nullptr}); }
    void ior(int port, std::function<void(uint8_t)> cb = nullptr) { q.push_back({Op::IOR, (uint32_t)port, 0, 0, cb}); }
    void memw(uint32_t a, uint8_t d) { q.push_back({Op::MEMW, a, d, 0, nullptr}); }
    void memr(uint32_t a, std::function<void(uint8_t)> cb = nullptr) { q.push_back({Op::MEMR, a, 0, 0, cb}); }
    void idle(int n) { if (n > 0) q.push_back({Op::IDLE, 0, 0, n, nullptr}); }
    int base() const { return g.mono() ? 0x3B0 : 0x3D0; }
    void crtc(int r, uint8_t v) { iow(base() + 4, r); iow(base() + 5, v); }
    // the unlock sequence (data sheet page 4): two reads of 3X8, the write
    void unlock_write(int reg, uint8_t v) {
        int b = base();
        ior(b + 8); ior(b + 8); iow(b + reg, v);
    }

    void bios_mode(int m) {
        const uint8_t *t = m <= 1 ? P40 : m <= 3 ? P80 : PGFX;
        iow(0x3D8, MODE_REG[m] & 0x37);
        for (int i = 0; i < 16; i++) crtc(i, t[i]);
        iow(0x3D9, m == 6 ? 0x3F : 0x30);
    }
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
        CHECK(cmp_n > 0, "%s: nothing compared", what);
        CHECK(cmp_bad == 0, "%s: %llu of %llu dots differ", what, (unsigned long long)cmp_bad,
              (unsigned long long)cmp_n);
        CHECK(rdy_bad == 0, "%s: READY differs in %llu clk", what, (unsigned long long)rdy_bad);
        CHECK(we_bad == 0, "%s: VRAM write instant differs %llu times", what, (unsigned long long)we_bad);
        CHECK(g.wr_lost == 0, "%s: %d writes lost", what, g.wr_lost);
        printf("  %s: %llu dots compared, %llu lit\n", what, (unsigned long long)cmp_n,
               (unsigned long long)cmp_lit);
    }
    uint8_t hdl_par() { return top->rootp->pvc4__DOT__par; }
    uint8_t hdl_cnf() { return top->rootp->pvc4__DOT__cnf; }
};

// ---------------------------------------------------------------- images
static const uint8_t RGBI[16][3] = {
    {0x00, 0x00, 0x00}, {0x00, 0x00, 0xAA}, {0x00, 0xAA, 0x00}, {0x00, 0xAA, 0xAA},
    {0xAA, 0x00, 0x00}, {0xAA, 0x00, 0xAA}, {0xAA, 0x55, 0x00}, {0xAA, 0xAA, 0xAA},
    {0x55, 0x55, 0x55}, {0x55, 0x55, 0xFF}, {0x55, 0xFF, 0x55}, {0x55, 0xFF, 0xFF},
    {0xFF, 0x55, 0x55}, {0xFF, 0x55, 0xFF}, {0xFF, 0xFF, 0x55}, {0xFF, 0xFF, 0xFF}};
static const uint8_t GREEN[4][3] = {{0x00, 0x00, 0x00}, {0x10, 0x40, 0x10}, {0x20, 0xB0, 0x20}, {0x70, 0xFF, 0x70}};

static void write_images(const std::vector<Rec> &r, const std::string &base, int W, int H, bool mono) {
    size_t s = 1;
    while (s < r.size() && !(r[s].vs && !r[s - 1].vs)) s++;
    if (s >= r.size()) { printf("  no VSYNC in the recording\n"); return; }
    std::vector<uint8_t> full(W * H * 3, 0x20), win;
    int x = 0, y = 0, ww = 0, wh = 0, wx = 0;
    std::vector<uint8_t> row;
    for (size_t k = s; k < r.size(); k++) {
        if (k > s && r[k].vs && !r[k - 1].vs) break;
        if (r[k].h && !r[k - 1].h) { x = 0; if (k > s) y++; }
        const uint8_t *c = mono ? GREEN[r[k].v * 2 + r[k].i] : RGBI[r[k].c & 15];
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
    if (!f) { printf("  cannot write %s_field.ppm\n", base.c_str()); return; }
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
           hs.size() > 1 ? (int)(hs[1] - hs[0]) : -1, vs.size(),
           vs.size() > 1 ? (int)(vs[1] - vs[0]) : -1,
           vs.size() > 1 ? (int)(vs[1] - vs[0]) / hper : -1);
}

static void fill_text(Sim &s, uint32_t base, int cols, int rows) {
    for (int i = 0; i < cols * rows; i++) {
        int ch = i & 0xFF;
        int at = ((i * 7 + 3) & 0x7F) | ((i % 37) == 5 ? 0x80 : 0);
        if (((at >> 4) & 7) == (at & 15)) at ^= 0x0F;
        s.memw(base + i * 2, ch);
        s.memw(base + i * 2 + 1, at);
    }
}
static void fill_gfx(Sim &s, bool hires, uint32_t plane = 0) {
    for (int y = 0; y < 200; y++)
        for (int xb = 0; xb < 80; xb++) {
            uint32_t a = 0xB8000 + plane + (y & 1) * 0x2000 + (y >> 1) * 80 + xb;
            uint8_t v;
            if (hires) v = ((y / 8 + xb) & 1) ? 0xAA ^ (uint8_t)(y * 3) : (uint8_t)(0x81 | (xb << 1));
            else {
                int band = (xb * 4) / 80;
                v = (uint8_t)(band * 0x55);
                int d = (y + xb * 4) % 50;
                if (d < 4) v ^= 0xC0 >> (2 * d);
            }
            if (plane) v = (uint8_t)((v << 1) | (v >> 7)) ^ (uint8_t)(y >> 3);
            s.memw(a, v);
        }
}

static std::string outdir = ".";
static std::vector<uint8_t> ibm_font, cbm_font;
static const uint8_t PAR_COLOUR = 0x40, PAR_MONO = 0xE0;     // the PC10-III straps (doc/pvc4.md 7)

// ---------------------------------------------------------------- tests
static void test_regs() {
    printf("regs\n");
    Sim s(ibm_font, false, PAR_COLOUR);
    // straps loaded at reset
    s.run_clk(4);
    CHECK(s.hdl_par() == PAR_COLOUR && s.hdl_cnf() == 0xF7, "straps: PAR %02X CNF %02X", s.hdl_par(), s.hdl_cnf());
    // 3XB/3XA writes without the unlock do nothing
    s.iow(0x3DB, 0xFF); s.iow(0x3DA, 0x00);
    s.run_ops();
    CHECK(s.hdl_par() == PAR_COLOUR && s.hdl_cnf() == 0xF7, "locked writes: PAR %02X CNF %02X", s.hdl_par(), s.hdl_cnf());
    // one read is not enough; an intervening I/O access breaks it
    s.ior(0x3D8); s.iow(0x3DB, 0x44);
    s.ior(0x3D8); s.ior(0x061); s.ior(0x3D8); s.iow(0x3DB, 0x44);
    s.ior(0x3D8); s.ior(0x3D8); s.iow(0x3D9, 0x01); s.iow(0x3DB, 0x44);
    s.run_ops();
    CHECK(s.hdl_par() == PAR_COLOUR, "broken unlock: PAR %02X", s.hdl_par());
    // the real thing; relocked after the write
    s.unlock_write(0xB, 0x44);
    s.iow(0x3DB, 0x00);
    s.run_ops();
    CHECK(s.hdl_par() == 0x44 && s.g.par == 0x44, "unlocked write: PAR %02X", s.hdl_par());
    s.unlock_write(0xA, 0xB3);
    s.run_ops();
    CHECK(s.hdl_cnf() == 0xB3, "unlocked write: CNF %02X", s.hdl_cnf());
    s.unlock_write(0xA, 0xF7);
    // 3X8 reads back the mode register
    s.iow(0x3D8, 0x2D);
    uint8_t m8 = 0;
    s.ior(0x3D8, [&](uint8_t v) { m8 = v; });
    s.run_ops();
    CHECK(m8 == 0x2D, "3D8 read back %02X", m8);
    // status: bits 7-5 = 1, bit 4 = Configuration bit 6 (1: IBM mode)
    uint8_t st = 0;
    s.ior(0x3DA, [&](uint8_t v) { st = v; });
    s.run_ops();
    CHECK((st & 0xF0) == 0xF0, "3DA bits 7-4: %02X", st);
    s.unlock_write(0xA, 0xB7);
    s.ior(0x3DA, [&](uint8_t v) { st = v; });
    s.unlock_write(0xA, 0xF7);
    s.run_ops();
    CHECK((st & 0xF0) == 0xE0, "3DA bit 4 with Configuration bit 6 = 0: %02X", st);
    // Plantronics: cleared in alpha mode, kept in graphics mode, disabled by Paradise bit 3
    s.iow(0x3D8, 0x0A); s.iow(0x3DD, 0x50); s.run_ops();
    CHECK(s.top->rootp->pvc4__DOT__pl == 0x50, "3DD in graphics: %02X", s.top->rootp->pvc4__DOT__pl);
    s.iow(0x3D8, 0x09); s.run_ops();
    CHECK(s.top->rootp->pvc4__DOT__pl == 0, "3DD after alpha mode: %02X", s.top->rootp->pvc4__DOT__pl);
    s.iow(0x3D8, 0x0A); s.unlock_write(0xB, 0x48); s.iow(0x3DD, 0x50); s.iow(0x3DE, 0x04); s.run_ops();
    CHECK(s.top->rootp->pvc4__DOT__pl == 0 && s.top->rootp->pvc4__DOT__att_r == 0, "3DD/3DE with Paradise bit 3");
    s.unlock_write(0xB, PAR_COLOUR); s.iow(0x3DE, 0x44); s.run_ops();
    CHECK(s.top->rootp->pvc4__DOT__att_r == 0x44, "3DE: %02X", s.top->rootp->pvc4__DOT__att_r);
    // the mapping: Paradise bit 7 moves the ports to 3Bx; 3Dx no longer answers
    s.unlock_write(0xB, PAR_MONO); s.run_ops();
    CHECK(s.g.mono() && s.top->vid_monomode, "mono mapping");
    int seen = -1;
    s.ior(0x3DA, [&](uint8_t v) { seen = v; });
    s.ior(0x3BA, [&](uint8_t v) { st = v; });
    s.run_ops();
    CHECK(seen == 0xFF, "3DA in the mono mapping: %02X", seen);
    CHECK((st & 0x70) == 0x70, "3BA bits 6-4: %02X", st);
    // Hercules: 3BF gates 3B8 bits 1 and 7; cleared by the colour mapping
    s.iow(0x3B8, 0x8A); s.ior(0x3B8, [&](uint8_t v) { m8 = v; }); s.run_ops();
    CHECK(m8 == 0x08, "3B8 without 3BF: %02X", m8);
    s.iow(0x3BF, 0x03); s.iow(0x3B8, 0x8A); s.ior(0x3B8, [&](uint8_t v) { m8 = v; }); s.run_ops();
    CHECK(m8 == 0x8A, "3B8 with 3BF = 3: %02X", m8);
    // B8000 belongs to the mono personality now (page 2)
    s.memw(0xB8010, 0x5A); s.memr(0xB8010, [&](uint8_t v) { m8 = v; }); s.run_ops();
    CHECK(m8 == 0x5A, "page 2 at B8010: %02X", m8);
    s.unlock_write(0xB, PAR_COLOUR); s.run_ops();
    CHECK(s.top->rootp->pvc4__DOT__hgc == 0, "3BF after the colour mapping");
    s.unlock_write(0xB, PAR_MONO); s.run_ops();
    s.memr(0xB8010, [&](uint8_t v) { m8 = v; }); s.run_ops();
    CHECK(m8 == 0xFF, "B8000 without 3BF: %02X", m8);
    // CRTC lock: R0-R11 ignored, R11 = underline row; R12+ still written
    s.unlock_write(0xB, PAR_MONO | 0x02);
    s.crtc(1, 0x33); s.crtc(11, 0x05); s.crtc(12, 0x12); s.run_ops();
    CHECK(s.top->rootp->pvc4__DOT__u_crtc__DOT__r1 == 0 && s.top->rootp->pvc4__DOT__ul_row == 5 &&
          s.top->rootp->pvc4__DOT__u_crtc__DOT__r11 == 0 && s.top->rootp->pvc4__DOT__u_crtc__DOT__r12 == 0x12,
          "CRTC lock");
    s.unlock_write(0xB, PAR_MONO);
    s.crtc(8, 0x03); s.crtc(10, 0x6D); s.run_ops();
    CHECK(s.top->rootp->pvc4__DOT__u_crtc__DOT__r8 == 0 && s.top->rootp->pvc4__DOT__u_crtc__DOT__r10 == 0x2D,
          "R8 %d R10 %02X", s.top->rootp->pvc4__DOT__u_crtc__DOT__r8, s.top->rootp->pvc4__DOT__u_crtc__DOT__r10);
    // light pen: 3B9 sets, 3BB clears (locked), status bit 1
    s.ior(0x3B9); s.ior(0x3BA, [&](uint8_t v) { st = v; }); s.run_ops();
    CHECK(st & 0x02, "3B9 sets the light pen latch");
    s.iow(0x3BB, 0); s.ior(0x3BA, [&](uint8_t v) { st = v; }); s.run_ops();
    CHECK(!(st & 0x02), "3BB clears the light pen latch");
    // disabled (230h venb' = 1): no reads, no READY, no writes
    s.top->enable = 0; s.g.enable = false;
    s.memw(0xB0020, 0x77); s.memr(0xB0020, [&](uint8_t v) { m8 = v; }); s.ior(0x3B8, [&](uint8_t v) { seen = v; });
    s.run_ops();
    CHECK(m8 == 0xFF && seen == 0xFF, "disabled: %02X %02X", m8, seen);
    s.top->enable = 1; s.g.enable = true;
    s.memr(0xB0020, [&](uint8_t v) { m8 = v; }); s.run_ops();
    CHECK(m8 != 0x77, "disabled write reached the RAM");
    CHECK(s.rdy_bad == 0, "READY differs in %llu clk", (unsigned long long)s.rdy_bad);
    printf("  %d reads checked\n", s.reads_checked);
}

static void print_hist(Sim &s) {
    for (auto &k : s.tw_hist) {
        if (k.first.find("MEM") == std::string::npos) continue;
        int n = 0; double sum = 0;
        printf("  %-12s", k.first.c_str());
        for (auto &e : k.second) { printf(" %d:%d", e.first, e.second); n += e.second; sum += e.first * e.second; }
        printf("  (mean %.2f)\n", n ? sum / n : 0);
    }
}

static void test_waits() {
    printf("waits\n");
    for (int k = 0; k < 4; k++) {
        // colour 80 columns, mono, colour 40 columns, mono with the clock / 2
        int mono = k & 1;
        Sim s(ibm_font, false, mono ? PAR_MONO : PAR_COLOUR);
        if (mono) s.bios_mode7(k == 3 ? 0x28 : 0x29); else s.bios_mode(k == 2 ? 1 : 3);
        s.run_ops();
        std::mt19937 rng(7 + k);
        uint32_t b = mono ? 0xB0000 : 0xB8000;
        int n = 0;
        for (int i = 0; i < 3000; i++) {
            uint32_t a = b + (rng() & 0x3FFF);
            if (rng() & 1) s.memw(a, rng() & 0xFF); else s.memr(a);
            s.idle(rng() % 7);
            if ((i & 63) == 63) s.run_ops();
            n++;
        }
        s.run_ops();
        CHECK(s.rdy_bad == 0, "%s: READY differs in %llu clk", mono ? "mono" : "colour", (unsigned long long)s.rdy_bad);
        CHECK(s.g.wr_lost == 0, "writes lost: %d", s.g.wr_lost);
        CHECK(s.we_bad == 0, "VRAM write instant differs %llu times", (unsigned long long)s.we_bad);
        print_hist(s);
        // data sheet parameters 17/26: READY low at most 2000 ns
        double ns = s.rdy_low_max * 1e9 / (315e6 / 11);
        printf("  longest READY low: %d clk = %.0f ns\n", s.rdy_low_max, ns);
        CHECK(ns <= 2000, "READY low %.0f ns > 2000 ns", ns);
        // every VRAM byte equal at the end
        int bad = 0;
        for (int a = 0; a < 0x8000; a++) {
            uint16_t p = (mono ? 0 : 0x8000) | a;
            uint8_t h = (p & 0x4000) ? s.top->rootp->pvc4__DOT__vram1[(p & 0x8000) >> 1 | (p & 0x3FFF)]
                                     : s.top->rootp->pvc4__DOT__vram0[(p & 0x8000) >> 1 | (p & 0x3FFF)];
            if (h != s.g.mem[p]) bad++;
        }
        CHECK(bad == 0, "VRAM: %d bytes differ", bad);
        static const char *KN[4] = {"colour 80", "mono", "colour 40", "mono / 2"};
        printf("  %s: %d accesses, %d reads checked\n", KN[k], n, s.reads_checked);
    }
}

static void test_cmode(int m) {
    char name[16];
    snprintf(name, sizeof name, "cmode%d", m);
    printf("%s\n", name);
    Sim s(ibm_font, false, PAR_COLOUR);
    s.bios_mode(m);
    if (m <= 3) fill_text(s, 0xB8000, m <= 1 ? 40 : 80, 25);
    else fill_gfx(s, m == 6);
    s.crtc(14, 0x00); s.crtc(15, 0x05);
    s.iow(0x3D8, MODE_REG[m]);
    s.run_ops();
    s.run_ticks(912 * 262);
    s.rec_start();
    s.run_ticks(912 * 262 * 2);
    s.rec_stop();
    s.compare(name);
    check_periods(s.rec, name, 912, 912 * 262);
    write_images(s.rec, outdir + "/" + name, 912, 262, false);
}

static void test_flicker() {
    printf("flicker\n");
    Sim s(ibm_font, false, PAR_COLOUR);
    s.bios_mode(3); fill_text(s, 0xB8000, 80, 25);
    s.iow(0x3D8, 0x21);                     // video "off"
    s.run_ops();
    s.run_ticks(912 * 262);
    s.rec_start(); s.run_ticks(912 * 262); s.rec_stop();
    s.compare("flicker override (Paradise bit 2 = 0)");
    uint64_t lit = s.cmp_lit;
    CHECK(lit > 20000, "video off but forced on: only %llu lit dots", (unsigned long long)lit);
    s.unlock_write(0xB, PAR_COLOUR | 0x04);
    s.run_ops();
    s.run_ticks(912 * 262);
    s.rec_start(); s.run_ticks(912 * 262); s.rec_stop();
    s.compare("video enable honoured (Paradise bit 2 = 1)");
    CHECK(s.cmp_lit < 2000, "video off: %llu lit dots", (unsigned long long)s.cmp_lit);
}

static void test_plant() {
    for (int pm = 0; pm < 2; pm++) {
        const char *name = pm ? "plant640" : "plant320";
        printf("%s\n", name);
        Sim s(ibm_font, false, PAR_COLOUR);
        s.bios_mode(pm ? 6 : 4);
        s.iow(0x3D8, MODE_REG[pm ? 6 : 4]);
        s.iow(0x3DD, pm ? 0x20 : 0x10);
        s.iow(0x3D9, pm ? 0x30 : 0x01);
        fill_gfx(s, pm, 0);
        fill_gfx(s, pm, 0x4000);
        // plane swap: with 3DD bit 6 the CPU's B8000 is plane 1
        s.iow(0x3DD, (pm ? 0x20 : 0x10) | 0x40);
        s.memw(0xB8000 + 40, 0xE7);
        s.memw(0xBC000 + 41, 0x7E);
        s.iow(0x3DD, pm ? 0x20 : 0x10);
        s.run_ops();
        CHECK(s.top->rootp->pvc4__DOT__vram1[0x4000 + 40] == 0xE7 && s.top->rootp->pvc4__DOT__vram0[0x4000 + 41] == 0x7E,
              "%s: plane swap", name);
        s.run_ticks(912 * 262);
        s.rec_start();
        s.run_ticks(912 * 262 * 2);
        s.rec_stop();
        s.compare(name);
        std::map<int, int> cols;
        for (auto &r : s.rec) cols[r.c]++;
        printf("  %zu colours on screen\n", cols.size());
        CHECK(cols.size() >= (pm ? 4u : 12u), "%s: only %zu colours", name, cols.size());
        write_images(s.rec, outdir + "/" + name, 912, 262, false);
    }
}

static void test_nosnow() {
    printf("nosnow\n");
    Sim s(ibm_font, false, PAR_COLOUR);
    s.bios_mode(3); fill_text(s, 0xB8000, 80, 25); s.run_ops();
    s.run_ticks(912 * 262);
    std::mt19937 rng(11);
    s.rec_start(false);
    uint64_t end = s.hdl_ticks + 912 * 262 * 2;
    while (s.hdl_ticks < end) {
        if (!s.busy()) {
            uint32_t a = 0xB8000 + (rng() % 4000);
            s.memw(a, rng() & 0xFF);
            s.idle(rng() % 3);
        }
        s.step();
    }
    s.rec_stop();
    s.run_ops();
    s.compare("nosnow (2 frames of VRAM writes, the model has no snow)");
}

static void test_status(bool mono) {
    printf("%s\n", mono ? "mstatus" : "status");
    Sim s(ibm_font, false, mono ? PAR_MONO : PAR_COLOUR);
    if (mono) s.bios_mode7(); else s.bios_mode(3);
    s.run_ops();
    s.run_clk(912 * 262 * 2);
    int n = 0, b0 = 0, b3 = 0, b7 = 0;
    for (int i = 0; i < 20000; i++)
        s.ior(mono ? 0x3BA : 0x3DA, [&](uint8_t v) { n++; b0 += v & 1; b3 += (v >> 3) & 1; b7 += (v >> 7) & 1; });
    s.run_ops();
    printf("  %d reads, bit 0 %.1f %%, bit 3 %.1f %%, bit 7 %.1f %%\n", n, 100.0 * b0 / n, 100.0 * b3 / n, 100.0 * b7 / n);
    CHECK(s.reads_checked >= 20000, "reads");
    CHECK(b0 > 0 && b0 < n, "bit 0 never changes");
    if (mono) CHECK(b7 > 0 && b7 < n, "bit 7 (VSYNC) never changes");
}

static void test_torture(bool mono, int seed) {
    char name[32];
    snprintf(name, sizeof name, "%s%d", mono ? "mtorture" : "torture", seed);
    printf("%s\n", name);
    Sim s(ibm_font, false, mono ? PAR_MONO : PAR_COLOUR);
    if (mono) { s.iow(0x3BF, 3); s.bios_mode7(); fill_text(s, 0xB0000, 80, 25); }
    else { s.bios_mode(seed & 1 ? 4 : 3); fill_text(s, 0xB8000, 80, 25); }
    s.run_ops();
    s.run_ticks(912 * 100);
    std::mt19937 rng(seed * 77 + mono);
    int b = s.base();
    s.rec_start(false);
    uint64_t end = s.clk_n + (uint64_t)912 * 2 * 262 * 5;
    int nw = 0;
    while (s.clk_n < end) {
        if (!s.busy()) {
            int k = rng() % 22;
            static const char *skip = getenv("TSKIP");
            if (skip && strchr(skip, 'a' + k)) k = 21;
            switch (k) {
            case 0: case 1: s.crtc(12 + rng() % 4, rng() & 0x3F); break;
            case 2: s.crtc(rng() % 16, (uint8_t)rng()); break;
            case 3: s.iow(b + 8, mono ? (0x01 | (rng() & 0xAA)) : (rng() & 0x3F)); break;
            case 4: s.iow(b + 9, rng() & 0x3F); break;
            case 5: s.iow(b + 0xA, rng()); s.iow(b + 0xB, rng()); break;
            case 6: s.ior(b + 0xA); break;
            case 7: s.ior(b + 5); s.ior(b + 8); break;
            case 8: if (!mono) s.iow(0x3DD, rng() & 0x70); else s.iow(0x3BF, rng() & 3); break;
            case 9: if (!mono) s.iow(0x3DE, rng() & 0x4D); break;
            case 10: s.ior(b + (rng() & 1 ? 0xC : 0xB)); s.ior(b + 9); break;
            case 11: {   // Paradise register: flicker, lock, 80 columns, 9 dots, ext (mapping kept)
                uint8_t v = (mono ? PAR_MONO : PAR_COLOUR) | (rng() & 0x2F);
                if (!mono) v &= ~0x20;
                if (mono) v |= 0x20 & (rng() | 0x20);
                s.unlock_write(0xB, v);
                break;
            }
            case 12: s.unlock_write(0xA, (rng() & 0x04) | 0xF3); break;
            case 13: s.crtc(1, 0x10 + rng() % 0x48); break;
            default:
                s.memw((mono ? 0xB0000 : 0xB8000) + (rng() & 0x7FFF), rng());
                if (rng() & 1) s.memr((mono ? 0xB0000 : 0xB8000) + (rng() & 0x7FFF));
                break;
            }
            s.idle(rng() % 40);
            nw++;
        }
        s.step();
    }
    s.rec_stop();
    s.run_ops();
    s.compare(name);
    printf("  %d operations, %d reads checked\n", nw, s.reads_checked);
}

static void test_mono(int w9) {
    const char *name = w9 ? "mono" : "mono8";
    printf("%s\n", name);
    Sim s(ibm_font, false, w9 ? PAR_MONO : (PAR_MONO & ~0x20));
    s.bios_mode7();
    fill_text(s, 0xB0000, 80, 25);
    static const uint8_t AT[12] = {0x07, 0x0F, 0x01, 0x09, 0x70, 0x78, 0x87, 0xF0, 0x00, 0x7F, 0x8F, 0x71};
    for (int i = 0; i < 256; i++) { s.memw(0xB0000 + i * 2, i); s.memw(0xB0000 + i * 2 + 1, AT[i % 12]); }
    s.crtc(14, 0x00); s.crtc(15, 0x05);
    s.run_ops();
    s.run_mdots(882 * 370);
    s.rec_start();
    s.run_mdots(882 * 370 * 2 + 1000);
    s.rec_stop();
    s.compare(name);
    int ch = w9 ? 9 : 8;
    check_periods(s.rec, name, 98 * ch, 98 * ch * 370);
    write_images(s.rec, outdir + "/" + name, 98 * ch, 370, true);
}

// mode register bit 0 = 0 in the mono personality: the 16.257 MHz clock / 2
static void test_mono40() {
    printf("mono40\n");
    Sim s(ibm_font, false, PAR_MONO);
    s.bios_mode7(0x28);
    fill_text(s, 0xB0000, 80, 25);
    s.run_ops();
    s.run_mdots(882 * 370);
    s.rec_start();
    s.run_mdots(882 * 370 * 2 + 1000);
    s.rec_stop();
    s.compare("mono40");
    check_periods(s.rec, "mono40", 882, 882 * 370);
    uint64_t c0 = s.clk_n, d0 = s.mdots;
    s.run_mdots(10000);
    double mhz = (s.mdots - d0) * (315.0 / 11) / (s.clk_n - c0);
    printf("  dot rate %.4f MHz\n", mhz);
    CHECK(mhz > 8.12 && mhz < 8.14, "dot rate %.4f MHz", mhz);
}

static void test_hgc() {
    printf("hgc\n");
    Sim s(ibm_font, false, PAR_MONO);
    s.iow(0x3BF, 0x03);
    s.iow(0x3B8, 0x02);
    for (int i = 0; i < 12; i++) s.crtc(i, PHGC[i]);
    for (int y = 0; y < 348; y++)
        for (int xb = 0; xb < 90; xb += 3) {
            uint32_t a = 0xB0000 + (y & 3) * 0x2000 + (y >> 2) * 90 + xb;
            s.memw(a, (uint8_t)(((y >> 3) ^ xb) & 1 ? 0xF0 : 0x3C) ^ (uint8_t)y);
            s.memw(a + 0x8000, (uint8_t)(xb * 3 + y));
        }
    s.iow(0x3B8, 0x0A);
    s.run_ops();
    for (int page = 0; page < 2; page++) {
        s.iow(0x3B8, page ? 0x8A : 0x0A);
        s.run_ops();
        s.run_mdots(880 * 368);
        s.rec_start();
        s.run_mdots(880 * 368 * 2 + 1000);
        s.rec_stop();
        char name[16];
        snprintf(name, sizeof name, "hgc_p%d", page);
        s.compare(name);
        check_periods(s.rec, name, 880, 880 * 368);  // the PC10-III table: R0 = 36h, 92 x 4 lines
        write_images(s.rec, outdir + "/" + name, 880, 368, true);
    }
}

static void test_cbm() {
    printf("cbm\n");
    for (int k = 0; k < 6; k++) {
        // k 4/5: A11 (DIP switch 2) against the mapping (the BIOS may switch it)
        bool a14 = k & 1, mono = (k & 2) != 0, a11 = k < 4 ? !mono : k == 4;
        if (k >= 4) mono = k == 4;
        Sim s(cbm_font, true, mono ? PAR_MONO : PAR_COLOUR, 0xF7, a14, a11);
        if (mono) { s.bios_mode7(); fill_text(s, 0xB0000, 80, 25); }
        else { s.bios_mode(3); fill_text(s, 0xB8000, 80, 25); }
        for (int set = 0; set < 2; set++) {
            if (!mono) s.iow(0x3DE, set ? 0x04 : 0x00);
            s.run_ops();
            if (mono && set) break;
            if (mono) s.run_mdots(882 * 370); else s.run_ticks(912 * 262);
            s.rec_start();
            if (mono) s.run_mdots(882 * 370 + 100); else s.run_ticks(912 * 262);
            s.rec_stop();
            char name[32];
            snprintf(name, sizeof name, "cbm_%s_a14%d_a11%d_set%d", mono ? "mono" : "col", a14, a11, set);
            s.compare(name);
            if (k == 0 || k == 3) write_images(s.rec, outdir + "/" + name, mono ? 882 : 912, mono ? 370 : 262, mono);
        }
    }
}

static void test_blink() {
    printf("blink\n");
    Sim s(ibm_font, false, PAR_COLOUR);
    s.bios_mode(3); fill_text(s, 0xB8000, 80, 25);
    s.crtc(14, 0x00); s.crtc(15, 0x45);
    s.run_ops();
    s.rec_start(false);
    s.run_ticks(912 * 262 * 34);
    s.rec_stop();
    s.compare("blink (34 frames)");
}

// a 32 KB Commodore-layout font from the IBM test image: each of the eight
// (A14, A13, A11) regions gets its own variant, so a wrong address line shows
static std::vector<uint8_t> make_cbm(const std::vector<uint8_t> &ibm) {
    std::vector<uint8_t> f(32768);
    for (int a = 0; a < 32768; a++) {
        int a14 = (a >> 14) & 1, a13 = (a >> 13) & 1, a12 = (a >> 12) & 1, a11 = (a >> 11) & 1;
        int ch = (a12 << 7) | ((a >> 4) & 0x7F), row = a & 15;
        uint8_t v = a11 ? (row < 8 ? ibm[0x1800 + ch * 8 + row] : 0x00)
                        : ibm[((row & 8) << 8) | (ch << 3) | (row & 7)];
        if (a13) v = (uint8_t)~v;
        if (!a14) v = (uint8_t)((v << 4) | (v >> 4));
        f[a] = v;
    }
    return f;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *fontfile = nullptr;
    std::vector<std::string> tests;
    for (int i = 1; i < argc; i++) {
        std::string s = argv[i];
        if (s == "-f" && i + 1 < argc) fontfile = argv[++i];
        else if (s == "-o" && i + 1 < argc) outdir = argv[++i];
        else if (s[0] != '+') tests.push_back(s);
    }
    if (!fontfile) { fprintf(stderr, "usage: pvc4_run -f font.bin -o outdir [test ...]\n"); return 2; }
    FILE *ff = fopen(fontfile, "rb");
    ibm_font.assign(8192, 0);
    if (!ff || fread(ibm_font.data(), 1, 8192, ff) != 8192) { fprintf(stderr, "font %s?\n", fontfile); return 2; }
    fclose(ff);
    cbm_font = make_cbm(ibm_font);
    if (tests.empty())
        tests = {"regs", "waits", "cmode0", "cmode1", "cmode2", "cmode3", "cmode4", "cmode5", "cmode6",
                 "flicker", "plant", "nosnow", "status", "mstatus", "torture", "mono", "mono8",
                 "mono40", "mtorture", "hgc", "cbm", "blink"};
    for (auto &t : tests) {
        if (t == "regs") test_regs();
        else if (t == "waits") test_waits();
        else if (t.rfind("cmode", 0) == 0) test_cmode(atoi(t.c_str() + 5));
        else if (t == "flicker") test_flicker();
        else if (t == "plant") test_plant();
        else if (t == "nosnow") test_nosnow();
        else if (t == "status") test_status(false);
        else if (t == "mstatus") test_status(true);
        else if (t == "torture") { for (int k = 1; k <= 4; k++) test_torture(false, k); }
        else if (t == "mtorture") { for (int k = 1; k <= 3; k++) test_torture(true, k); }
        else if (t == "mono") test_mono(1);
        else if (t == "mono8") test_mono(0);
        else if (t == "hgc") test_hgc();
        else if (t == "mono40") test_mono40();
        else if (t == "cbm") test_cbm();
        else if (t == "blink") test_blink();
        else { fprintf(stderr, "unknown test %s\n", t.c_str()); return 2; }
    }
    printf(failures ? "FAILED: %d checks\n" : "PASS\n", failures);
    return failures ? 1 : 0;
}
