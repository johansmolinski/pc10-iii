// lpt_run.cpp - Verilator testbench for rtl/system/lpt_ppc1.sv, the PC10-III's
// parallel port (doc/ports.md section 7): a reference model of IBM's printer
// adapter compared every clk (read data and select, the pins, IRQ7), explicit
// checks of the decode at 3BCh/378h/278h, the BIOS's probe (F000:CB8C), the
// status bits from the pins, the control register and its pins, reset, IRQ7 on
// the end of /ACK, and a random run.
//
// usage: lpt_run [test ...]
//
// GPL-3.0-or-later, pc10-iii.

#include "Vlpt_ppc1.h"
#include "bus.h"
#include "verilated.h"

#include <algorithm>
#include <random>
#include <string>
#include <vector>

struct LptModel {
    int lpt = 1;
    uint8_t data = 0, ctrl = 0;
    bool busy = false, ack_n = true, pe = false, slct = true, err_n = true;
    unsigned base() const { return lpt == 1 ? 0x3BC : lpt == 2 ? 0x378 : 0x278; }
    bool dsel(const Bus &b) const {
        return lpt && !b.aen && !b.ior_n && (b.addr & 0x3FF) >= base() && (b.addr & 0x3FF) <= base() + 2;
    }
    uint8_t din(const Bus &b) const {
        if (!dsel(b)) return 0;
        switch ((b.addr & 0x3FF) - base()) {
        case 0: return data;
        case 1: return (!busy) << 7 | ack_n << 6 | pe << 5 | slct << 4 | err_n << 3 | 7;
        default: return 0xE0 | ctrl;
        }
    }
    bool irq7() const { return lpt && (ctrl & 0x10) && ack_n; }
    void clock(const Bus &c, const Bus &n, bool rst) {
        bool sel = lpt && !c.aen && (c.addr & 0x3FF) >= base() && (c.addr & 0x3FF) <= base() + 2;
        bool snx = lpt && !n.aen && (n.addr & 0x3FF) == (c.addr & 0x3FF);
        bool wr_end = sel && !c.iow_n && !(snx && !n.iow_n);
        int r = (c.addr & 0x3FF) - base();
        if (wr_end && r == 0) data = c.dout;
        if (rst) ctrl = 0;
        else if (wr_end && r == 2) ctrl = c.dout & 0x1F;
    }
};

struct Sim {
    Vlpt_ppc1 *top;
    LptModel m;
    BusPlan bp;
    bool rst = false;
    long mism = 0, irq_rises = 0;
    bool last_irq = false, dsel_seen = false;
    Sim() {
        top = new Vlpt_ppc1;
        top->clk = 0;
        set_lpt(1);
        apply();
        top->eval();
        bp.clock = [this](const Bus &c, const Bus &n) { return clk1(c, n); };
    }
    void set_lpt(int v) { m.lpt = v; top->lpt = v; }
    void apply() {
        top->busy = m.busy; top->ack_n = m.ack_n; top->pe = m.pe; top->slct = m.slct; top->err_n = m.err_n;
    }
    uint8_t clk1(const Bus &c, const Bus &n) {
        top->isa_addr = c.addr; top->isa_aen = c.aen; top->isa_ior_n = c.ior_n; top->isa_iow_n = c.iow_n;
        top->isa_dout = c.dout; top->isa_addr_next = n.addr; top->isa_aen_next = n.aen;
        top->isa_iow_n_next = n.iow_n;
        top->reset = rst;
        apply();
        top->eval();
        dsel_seen |= top->isa_dsel;
        uint8_t ctl = m.ctrl;
        bool bad = top->isa_dsel != m.dsel(c) || top->isa_din != m.din(c) || top->irq7 != m.irq7() ||
                   top->data != m.data || top->strobe_n != !(ctl & 1) || top->autofd_n != !(ctl & 2) ||
                   top->init_n != !!(ctl & 4) || top->selin_n != !(ctl & 8);
        if (bad) {
            if (mism++ < 10)
                printf("MISMATCH clk %llu a %X: dsel %d/%d din %02X/%02X irq %d/%d data %02X/%02X\n",
                       (unsigned long long)bp.clk, c.addr, top->isa_dsel, m.dsel(c), top->isa_din, m.din(c),
                       top->irq7, m.irq7(), top->data, m.data);
            failures++;
        }
        if (top->irq7 && !last_irq) irq_rises++;
        last_irq = top->irq7;
        uint8_t d = top->isa_din;
        top->clk = 1;
        top->eval();
        m.clock(c, n, rst);
        top->clk = 0;
        return d;
    }
    unsigned B() const { return m.base(); }
    uint8_t in(int r) { return bp.in(B() + r); }
    void out(int r, uint8_t v) { bp.out(B() + r, v); }
    void run(uint64_t n) { bp.run(n); }
};

static void t_regs() {
    Sim s;
    for (int l = 1; l <= 3; l++) {
        s.set_lpt(l);
        s.out(0, 0x5A + l);
        CHECK(s.in(0) == 0x5A + l, "data latch at %03X", s.B());
        // the BIOS's probe: 0Ch to data, 0Dh to control, data reads 0Ch
        s.out(0, 0x0C); s.out(2, 0x0D);
        CHECK(s.in(0) == 0x0C, "the BIOS's probe at %03X", s.B());
        CHECK(s.in(2) == 0xED, "control read %02X", s.in(2));
        s.dsel_seen = false;
        s.in(3);
        CHECK(!s.dsel_seen, "base + 3 does not answer");
        s.bp.in(s.B(), 0, true);
        CHECK(!s.dsel_seen, "AEN");
        // the other bases do not answer
        for (unsigned b : {0x3BCu, 0x378u, 0x278u}) {
            if (b == s.B()) continue;
            s.bp.in(b); s.bp.in(b + 1); s.bp.in(b + 2);
        }
        CHECK(!s.dsel_seen, "only %03X answers", s.B());
    }
    s.set_lpt(0);
    s.dsel_seen = false;
    for (unsigned b : {0x3BCu, 0x378u, 0x278u}) { s.bp.in(b); s.bp.in(b + 1); s.bp.in(b + 2); }
    CHECK(!s.dsel_seen, "lpt 00: no port");
    s.bp.out(0x378, 0x99);
    s.set_lpt(2);
    CHECK(s.in(0) != 0x99, "lpt 00: writes ignored");
    // A15-A10 not decoded
    s.dsel_seen = false;
    s.bp.in(0x1378);
    CHECK(s.dsel_seen, "BA9-BA0 decoded");
    CHECK(s.mism == 0, "model (regs)");
}

static void t_status() {
    Sim s;
    // ready (nothing connected on the PMOD): BUSY low, /ACK high, PE low, SLCT high, /ERROR high
    CHECK(s.in(1) == 0xDF, "status ready %02X", s.in(1));
    for (int k = 0; k < 32; k++) {
        s.m.busy = k & 1; s.m.ack_n = k & 2; s.m.pe = k & 4; s.m.slct = k & 8; s.m.err_n = k & 16;
        uint8_t v = s.in(1);
        uint8_t want = (!(k & 1)) << 7 | (!!(k & 2)) << 6 | (!!(k & 4)) << 5 | (!!(k & 8)) << 4 | (!!(k & 16)) << 3 | 7;
        CHECK(v == want, "status %02X vs %02X", v, want);
    }
    CHECK(s.mism == 0, "model (status)");
}

static void t_ctrl() {
    Sim s;
    // reset: control 0 = /INIT low, STROBE/AUTOFD/SLCTIN inactive
    s.rst = true; s.run(3); s.rst = false;
    CHECK(s.top->strobe_n && s.top->autofd_n && !s.top->init_n && s.top->selin_n, "pins after reset");
    s.out(2, 0x08 | 0x04);
    CHECK(s.top->strobe_n && s.top->autofd_n && s.top->init_n && !s.top->selin_n, "SLCTIN, /INIT high");
    s.out(2, 0x0D);
    CHECK(!s.top->strobe_n && s.top->init_n, "STROBE");
    s.out(2, 0x0E);
    CHECK(s.top->strobe_n && !s.top->autofd_n, "AUTOFD");
    s.out(2, 0xFF);
    CHECK(s.in(2) == 0xFF, "control read FF");
    s.out(0, 0xA5);
    s.rst = true; s.run(3); s.rst = false;
    CHECK(s.in(2) == 0xE0 && s.in(0) == 0xA5, "reset clears the control register, not the data latch");
    CHECK(s.mism == 0, "model (ctrl)");
}

static void t_irq() {
    Sim s;
    s.out(2, 0x0C);
    CHECK(!s.top->irq7, "IRQ EN clear: no IRQ7");
    long r0 = s.irq_rises;
    s.out(2, 0x1C);
    CHECK(s.top->irq7 && s.irq_rises == r0 + 1, "IRQ EN with /ACK high: one edge");
    // a printer's acknowledge: /ACK low for 5 us, the interrupt at its end
    s.m.ack_n = false; s.run(143);
    CHECK(!s.top->irq7, "/ACK low: IRQ7 low");
    s.m.ack_n = true; s.run(2);
    CHECK(s.top->irq7 && s.irq_rises == r0 + 2, "/ACK back high: the edge");
    s.set_lpt(0); s.run(1);
    CHECK(!s.top->irq7, "port off: no IRQ7");
    s.set_lpt(1);
    s.out(2, 0x0C);
    CHECK(!s.top->irq7, "IRQ EN cleared");
    CHECK(s.mism == 0, "model (irq)");
}

static void t_random() {
    std::mt19937 rng(99);
    Sim s;
    for (int op = 0; op < 100000; op++) {
        int k = rng() % 10;
        unsigned port = (k < 8) ? (std::vector<unsigned>{0x3BC, 0x378, 0x278}[rng() % 3] + rng() % 4) : rng() & 0x3FF;
        if (k < 4) s.bp.in(port, rng() % 10, rng() % 16 == 0);
        else if (k < 8) s.bp.out(port, rng(), rng() % 10, rng() % 16 == 0);
        else if (k < 9) {
            s.m.busy = rng() & 1; s.m.ack_n = rng() & 1; s.m.pe = rng() & 1; s.m.slct = rng() & 1;
            s.m.err_n = rng() & 1; s.run(rng() % 5);
        } else if (rng() % 4 == 0) s.set_lpt(rng() % 4);
        else if (rng() % 50 == 0) { s.rst = true; s.run(1 + rng() % 3); s.rst = false; }
    }
    printf("random: %llu clk\n", (unsigned long long)s.bp.clk);
    CHECK(s.mism == 0, "model (random)");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    struct T { const char *n; void (*f)(); } tests[] = {
        {"regs", t_regs}, {"status", t_status}, {"ctrl", t_ctrl}, {"irq", t_irq}, {"random", t_random}};
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
    printf("lpt: %d tests, %ld checks, %d failures\n", ran, checks, failures);
    return failures ? 1 : 0;
}
