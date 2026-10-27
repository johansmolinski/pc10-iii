// mouse_run.cpp - Verilator testbench for rtl/system/cbm_mouse.sv, the 5720's bus
// mouse (doc/ports.md section 7). The reference model counts with Minimig's
// userio.v conditions copied literally (the Amiga's decoding of the same mouse:
// "right" = HQ, "down" = H), is compared every clk, and drives a mouse model
// that moves by quadrature steps (p leading q for + moves). Tests: the BIOS
// 4.41 detection (F000:CD30-CD71), the Microsoft driver's read sequence (hold,
// four nibbles, release = clear), moves lost while held, wrap, buttons, the
// 32.768 ms interrupt on IRQ2 and its enables, a random run.
//
// usage: mouse_run [test ...]
//
// GPL-3.0-or-later, pc10-iii.

#include "Vcbm_mouse.h"
#include "bus.h"
#include "verilated.h"

#include <algorithm>
#include <cmath>
#include <random>
#include <string>
#include <vector>

struct MousePins { bool xp = true, xq = true, yp = true, yq = true, l = true, m = true, r = true; };

struct MouseModel {
    bool enable = true;
    uint8_t dummy = 0, ctrl = 0, cx = 0, cy = 0;    // ctrl = 23Eh bits 7-4
    MousePins s[3];                                  // synchronizer stages, s[2] the oldest
    uint32_t acc = 0, div = 0;

    bool irq2() const { return enable && !(ctrl & 1) && ((div >> 18) & 1); }
    bool sel(const Bus &b) const { int a = b.addr & 0x3FF; return enable && !b.aen && a >= 0x23C && a <= 0x23E; }
    bool dsel(const Bus &b) const { return sel(b) && !b.ior_n; }
    uint8_t din(const Bus &b) const {
        if (!dsel(b)) return 0;
        switch ((b.addr & 0x3FF) - 0x23C) {
        case 0: {
            uint8_t c = (ctrl & 4) ? cy : cx;
            uint8_t nib = (ctrl & 2) ? c >> 4 : c & 15;
            return s[1].l << 7 | s[1].m << 6 | s[1].r << 5 | nib;
        }
        case 1: return dummy;
        default: return (!irq2()) << 3 | 7;
        }
    }
    // userio.v's port-1 counter conditions with _sjoy = new, _djoy = old;
    // [0] = right = q, [2] = down = p (horizontal); [1] = left = q, [3] = up = p (vertical)
    // (userio.v gives the +1 priority when both lines change in one sample, which
    // is no valid quadrature step; the 5720 model counts nothing then)
    static int userio(bool d0, bool s0, bool d2, bool s2) {
        bool up = (!d0 && s0 && s2) || (d0 && !s0 && !s2) || (!d2 && s2 && !s0) || (d2 && !s2 && s0);
        bool dn = (!d0 && s0 && !s2) || (d0 && !s0 && s2) || (!d2 && s2 && s0) || (d2 && !s2 && !s0);
        return up && !dn ? +1 : dn && !up ? -1 : 0;
    }
    void clock(const Bus &c, const Bus &n, const MousePins &pins, bool rst) {
        int dx = userio(s[2].xq, s[1].xq, s[2].xp, s[1].xp);
        int dy = userio(s[2].yq, s[1].yq, s[2].yp, s[1].yp);
        bool sl = sel(c);
        bool snx = enable && !n.aen && (n.addr & 0x3FF) == (c.addr & 0x3FF);
        bool wr_end = sl && !c.iow_n && !(snx && !n.iow_n);
        int a = (c.addr & 0x3FF) - 0x23C;
        bool tick = acc + 176 >= 315;
        acc = tick ? acc + 176 - 315 : acc + 176;
        s[2] = s[1]; s[1] = s[0]; s[0] = pins;
        if (rst) { div = 0; ctrl = 0; dummy = 0; cx = cy = 0; return; }
        if (tick) div = (div + 1) & 0x7FFFF;
        if (!(ctrl & 8)) { cx += dx; cy += dy; }
        if (wr_end && a == 1) dummy = c.dout;
        if (wr_end && a == 2) {
            if ((ctrl & 8) && !(c.dout & 0x80)) cx = cy = 0;
            ctrl = c.dout >> 4;
        }
    }
};

struct Sim {
    Vcbm_mouse *top;
    MouseModel m;
    BusPlan bp;
    MousePins pins;
    bool rst = false, dsel_seen = false, last_irq = false;
    long mism = 0;
    std::vector<uint64_t> irq_rise, irq_fall;
    std::deque<std::pair<uint64_t, MousePins>> sched;   // pin changes at a clk
    int qx = 2, qy = 2;           // the mouse's quadrature phase (0..3): the pins idle high = 2
    Sim() {
        top = new Vcbm_mouse;
        top->clk = 0;
        top->enable = 1;
        apply();
        top->eval();
        bp.clock = [this](const Bus &c, const Bus &n) { return clk1(c, n); };
        rst = true; run(2); rst = false;
    }
    void apply() {
        top->x_p = pins.xp; top->x_q = pins.xq; top->y_p = pins.yp; top->y_q = pins.yq;
        top->btn_l_n = pins.l; top->btn_m_n = pins.m; top->btn_r_n = pins.r;
    }
    void set_enable(bool e) { m.enable = e; top->enable = e; }
    uint8_t clk1(const Bus &c, const Bus &n) {
        while (!sched.empty() && sched.front().first <= bp.clk) { pins = sched.front().second; sched.pop_front(); }
        top->isa_addr = c.addr; top->isa_aen = c.aen; top->isa_ior_n = c.ior_n; top->isa_iow_n = c.iow_n;
        top->isa_dout = c.dout; top->isa_addr_next = n.addr; top->isa_aen_next = n.aen;
        top->isa_iow_n_next = n.iow_n;
        top->reset = rst;
        apply();
        top->eval();
        dsel_seen |= top->isa_dsel;
        if (top->isa_dsel != m.dsel(c) || top->isa_din != m.din(c) || top->irq2 != m.irq2()) {
            if (mism++ < 10)
                printf("MISMATCH clk %llu a %X: dsel %d/%d din %02X/%02X irq %d/%d\n", (unsigned long long)bp.clk,
                       c.addr, top->isa_dsel, m.dsel(c), top->isa_din, m.din(c), top->irq2, m.irq2());
            failures++;
        }
        if (top->irq2 && !last_irq) irq_rise.push_back(bp.clk);
        if (!top->irq2 && last_irq) irq_fall.push_back(bp.clk);
        last_irq = top->irq2;
        uint8_t d = top->isa_din;
        top->clk = 1;
        top->eval();
        m.clock(c, n, pins, rst);
        top->clk = 0;
        return d;
    }
    void run(uint64_t n) { bp.run(n); }
    // the mouse: one quadrature step on an axis, p leading q for +
    void step(bool x, int dir, uint64_t gap) {
        int &q = x ? qx : qy;
        q = (q + dir) & 3;
        static const bool P[4] = {false, true, true, false}, Q[4] = {false, false, true, true};
        if (x) { pins.xp = P[q]; pins.xq = Q[q]; } else { pins.yp = P[q]; pins.yq = Q[q]; }
        run(gap);
    }
    void move(int dx, int dy, uint64_t gap = 40) {
        while (dx || dy) {
            if (dx) { step(true, dx > 0 ? 1 : -1, gap); dx += dx > 0 ? -1 : 1; }
            if (dy) { step(false, dy > 0 ? 1 : -1, gap); dy += dy > 0 ? -1 : 1; }
        }
    }
    // the Microsoft bus mouse driver's read: hold, X low/high, Y low/high, release
    void read_ms(int &x, int &y, uint8_t *btn = nullptr) {
        bp.out(0x23E, 0x80); uint8_t xl = bp.in(0x23C);
        bp.out(0x23E, 0xA0); uint8_t xh = bp.in(0x23C);
        bp.out(0x23E, 0xC0); uint8_t yl = bp.in(0x23C);
        bp.out(0x23E, 0xE0); uint8_t yh = bp.in(0x23C);
        bp.out(0x23E, 0x00);
        x = int8_t((xh & 15) << 4 | (xl & 15));
        y = int8_t((yh & 15) << 4 | (yl & 15));
        if (btn) *btn = xl & 0xE0;
    }
};

static void t_detect() {
    Sim s;
    s.set_enable(false);
    s.dsel_seen = false;
    s.bp.in(0x23E); s.bp.in(0x23C); s.bp.out(0x23D, 0x66); s.bp.in(0x23D);
    CHECK(!s.dsel_seen, "230h bit 4 clear: nothing answers");
    // the BIOS 4.41 (F000:CD30): 23Eh twice for DEh (an InPort card), then 91h to
    // 23Fh, 66h to 23Dh, 99h to 232h, 23Dh back
    s.set_enable(true);
    uint8_t a = s.bp.in(0x23E), b = s.bp.in(0x23E);
    CHECK(a != 0xDE && b != 0xDE, "23Eh is no InPort signature (%02X)", a);
    CHECK((a & 0xF7) == 0x07, "23Eh: bits 2-0 1, 7-4 0 (%02X)", a);
    s.bp.out(0x23F, 0x91);
    s.bp.out(0x23D, 0x66);
    s.bp.out(0x232, 0x99);
    CHECK(s.bp.in(0x23D) == 0x66, "23Dh reads back 66h");
    s.dsel_seen = false;
    s.bp.in(0x23F); s.bp.in(0x23B); s.bp.in(0x23C, 0, true);
    CHECK(!s.dsel_seen, "23Fh, 23Bh and AEN do not answer");
    s.bp.in(0x163C);
    CHECK(s.dsel_seen, "BA9-BA0 decoded");
    // the Microsoft driver's own probe values
    for (int v : {0x00, 0xA5, 0x5A, 0xFF}) { s.bp.out(0x23D, v); CHECK(s.bp.in(0x23D) == v, "23Dh %02X", v); }
    CHECK(s.mism == 0, "model (detect)");
}

static void t_count() {
    Sim s;
    int x, y;
    s.read_ms(x, y);
    CHECK(x == 0 && y == 0, "no move");
    s.move(5, 0);
    s.read_ms(x, y);
    CHECK(x == 5 && y == 0, "right 5: %d %d", x, y);
    s.move(0, 7);
    s.read_ms(x, y);
    CHECK(x == 0 && y == 7, "down 7: %d %d", x, y);
    s.move(-3, -9);
    s.read_ms(x, y);
    CHECK(x == -3 && y == -9, "left 3 up 9: %d %d", x, y);
    s.move(100, -120);
    s.read_ms(x, y);
    CHECK(x == 100 && y == -120, "100 -120: %d %d", x, y);
    // the counters are 8 bits: 200 counts read as -56
    s.move(200, 0, 20);
    s.read_ms(x, y);
    CHECK(x == -56, "wrap: %d", x);
    // moves while held are lost; the release clears
    s.move(4, 4);
    s.bp.out(0x23E, 0x80);
    s.move(6, 6);
    s.bp.out(0x23E, 0x00);
    s.read_ms(x, y);
    CHECK(x == 0 && y == 0, "moves while held lost, release cleared: %d %d", x, y);
    // without a hold the counters keep their value (no clear)
    s.move(3, 0);
    s.bp.out(0x23E, 0x00); s.bp.out(0x23E, 0x20);
    uint8_t lo = s.bp.in(0x23C);
    s.bp.out(0x23E, 0x00);
    lo = s.bp.in(0x23C);
    CHECK((lo & 15) == 3, "no clear without the hold's falling edge: %X", lo & 15);
    s.read_ms(x, y);
    // both lines in the same clk: no count
    s.pins.xp = !s.pins.xp; s.pins.xq = !s.pins.xq; s.run(10);
    s.read_ms(x, y);
    CHECK(x == 0, "both lines at once: nothing (%d)", x);
    // fast: an edge every 3 clk (10 MHz quadrature) still counts
    s.qx = 0; s.pins.xp = false; s.pins.xq = false; s.run(10); s.read_ms(x, y);
    s.move(50, 0, 3);
    s.read_ms(x, y);
    CHECK(x == 50, "fast moves: %d", x);
    // counting continues while the interface is disabled (230h bit 4)
    s.set_enable(false); s.move(-8, 2); s.set_enable(true);
    s.read_ms(x, y);
    CHECK(x == -8 && y == 2, "counted while disabled: %d %d", x, y);
    CHECK(s.mism == 0, "model (count)");
}

static void t_buttons() {
    Sim s;
    int x, y;
    uint8_t b;
    for (int k = 0; k < 8; k++) {
        s.pins.l = !(k & 1); s.pins.m = !(k & 2); s.pins.r = !(k & 4);
        s.run(4);
        s.read_ms(x, y, &b);
        uint8_t want = (!(k & 1)) << 7 | (!(k & 2)) << 6 | (!(k & 4)) << 5;   // left 7, middle 6, right 5
        CHECK(b == want, "buttons %d: %02X vs %02X", k, b, want);
        CHECK((s.bp.in(0x23C) & 0x10) == 0, "bit 4 is 0");
    }
    CHECK(s.mism == 0, "model (buttons)");
}

static void t_irq() {
    Sim s;
    s.irq_rise.clear(); s.irq_fall.clear();
    s.run(4000000);
    // 32.768 ms = 938356.36 clk, half high
    CHECK(s.irq_rise.size() >= 4, "IRQ2 square wave: %zu rises", s.irq_rise.size());
    for (size_t i = 1; i < s.irq_rise.size(); i++) {
        double p = double(s.irq_rise[i] - s.irq_rise[i - 1]);
        CHECK(std::fabs(p - 938356.36) <= 1.0, "period %.0f", p);
    }
    for (size_t i = 0; i < s.irq_fall.size() && i < s.irq_rise.size(); i++) {
        if (s.irq_fall[i] < s.irq_rise[i]) continue;
        double h = double(s.irq_fall[i] - s.irq_rise[i]);
        CHECK(std::fabs(h - 469178.18) <= 1.0, "high %.0f", h);
    }
    // status bit 3 is IRQ2 inverted
    for (int i = 0; i < 8; i++) {
        s.run(100000);
        uint8_t v = s.bp.in(0x23E);
        CHECK(((v >> 3) & 1) == !s.top->irq2, "status bit 3 = IRQ2 inverted");
    }
    // 23Eh bit 4: no interrupt, bit 3 = 1
    s.bp.out(0x23E, 0x10);
    size_t r0 = s.irq_rise.size();
    s.run(2000000);
    CHECK(s.irq_rise.size() == r0 && !s.top->irq2, "23Eh bit 4: IRQ2 off");
    CHECK(s.bp.in(0x23E) == 0x0F, "status with the interrupt off: 0Fh");
    s.bp.out(0x23E, 0x00);
    s.run(1000000);
    CHECK(s.irq_rise.size() > r0, "IRQ2 back");
    // 230h bit 4 clear: no IRQ2
    s.set_enable(false);
    r0 = s.irq_rise.size();
    s.run(2000000);
    CHECK(s.irq_rise.size() == r0 && !s.top->irq2, "230h bit 4 clear: IRQ2 off");
    s.set_enable(true);
    // reset clears 23Eh (the interrupt enabled again)
    s.bp.out(0x23E, 0x10);
    s.rst = true; s.run(2); s.rst = false;
    s.run(1000000);
    CHECK(s.top->irq2 || s.irq_rise.size() > r0, "reset: 23Eh cleared");
    CHECK(s.mism == 0, "model (irq)");
}

// quadrature steps every 1..4 clk while 23Ch is read: the counter's value in each clk of
// the strobe is compared with the model (the synchronizer depth, the step timing)
static void t_timing() {
    Sim s;
    std::mt19937 rng(8);
    for (int k = 0; k < 400; k++) {
        s.bp.out(0x23E, (rng() & 3) << 5);
        MousePins p = s.pins;
        uint64_t t = s.bp.clk + 2;
        static const bool P[4] = {false, true, true, false}, Q[4] = {false, false, true, true};
        for (int i = 0; i < 12; i++) {
            bool x = rng() & 1;
            int &q = x ? s.qx : s.qy;
            q = (q + ((rng() % 4) ? 1 : 3)) & 3;
            if (x) { p.xp = P[q]; p.xq = Q[q]; } else { p.yp = P[q]; p.yq = Q[q]; }
            t += 1 + rng() % 3;
            s.sched.push_back({t, p});
        }
        s.bp.in(0x23C);
        s.run(60);
    }
    CHECK(s.mism == 0, "model (timing)");
}

static void t_random() {
    std::mt19937 rng(5);
    Sim s;
    for (int op = 0; op < 60000; op++) {
        int k = rng() % 12;
        if (k < 3) s.move(int(rng() % 9) - 4, int(rng() % 9) - 4, 2 + rng() % 30);
        else if (k < 5) { int x, y; s.read_ms(x, y); }
        else if (k < 7) s.bp.in(0x23C + rng() % 4, rng() % 10);
        else if (k < 9) s.bp.out(0x23C + rng() % 4, rng(), rng() % 10);
        else if (k < 10) {
            s.pins.l = rng() & 1; s.pins.m = rng() & 1; s.pins.r = rng() & 1;
            if (rng() % 4 == 0) { s.pins.xp = rng() & 1; s.pins.yq = rng() & 1; }
            s.run(rng() % 5);
        } else if (k < 11) { if (rng() % 8 == 0) s.set_enable(rng() & 1); }
        else if (rng() % 40 == 0) { s.rst = true; s.run(1 + rng() % 2); s.rst = false; }
        else s.run(rng() % 3000);
    }
    printf("random: %llu clk\n", (unsigned long long)s.bp.clk);
    CHECK(s.mism == 0, "model (random)");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    struct T { const char *n; void (*f)(); } tests[] = {
        {"detect", t_detect}, {"count", t_count}, {"buttons", t_buttons}, {"irq", t_irq}, {"timing", t_timing}, {"random", t_random}};
    std::vector<std::string> want;
    for (int i = 1; i < argc; i++) if (argv[i][0] != '+') want.push_back(argv[i]);
    int ran = 0;
    for (auto &t : tests) {
        if (!want.empty() && std::find(want.begin(), want.end(), std::string(t.n)) == want.end()) continue;
        int f0 = failures;
        t.f();
        printf("%s: %s\n", t.n, failures == f0 ? "PASS" : "FAIL");
        ran++;
    }
    printf("mouse: %d tests, %ld checks, %d failures\n", ran, checks, failures);
    return failures ? 1 : 0;
}
