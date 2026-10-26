// uart_run.cpp - Verilator testbench for rtl/system/uart8250.sv, the PC10-III's
// serial port (doc/ports.md section 7).
//
// The chip is driven with CPU I/O cycles of the card bus (bus.h); uart_model.h
// runs next to it on the same clk and every clk the read data and select, INTR,
// the two IRQ lines, SOUT and the modem outputs are compared with it. The tests
// add checks against independent expectations: bit times measured on SOUT
// against 16 x divisor / 1.8432 MHz, frames decoded by a separate line decoder,
// frames for SIN built by the testbench (formats, parity/framing errors, break,
// overrun, false starts, baud errors of +-3 %), the interrupt identification
// sequence, MSR deltas from the pins and in loopback.
//
// usage: uart_run [test ...]   (no test: all)
//
// GPL-3.0-or-later, pc10-iii.

#include "Vuart8250.h"
#include "uart_model.h"
#include "verilated.h"

#include <cmath>
#include <cstring>
#include <random>
#include <string>
#include <vector>

static const uint32_t NUM = 12672, DEN = 196875;
static const int PULSE = 8;
static const double TICK = double(DEN) / NUM;          // clk per 1.8432 MHz tick

struct Sim {
    Vuart8250 *top;
    UartModel m{NUM, DEN, PULSE};
    BusPlan bp;
    UartPins pins;
    bool rst = false;
    long mism = 0;
    bool dsel_seen = false;
    // SOUT edges (clk, new level)
    std::vector<std::pair<uint64_t, bool>> edges;
    bool last_sout = true;
    // the SIN generator: (level, clk)
    std::deque<std::pair<bool, uint64_t>> sinq;
    long intr_falls = 0;
    bool last_intr = false;

    Sim() {
        top = new Vuart8250;
        top->clk = 0;
        top->com = 2;
        top->sin = 1; top->cts_n = 1; top->dsr_n = 1; top->dcd_n = 1; top->ri_n = 1;
        top->reset = 0;
        top->isa_addr = 0x12345; top->isa_addr_next = 0x12345;
        top->isa_ior_n = 1; top->isa_iow_n = 1; top->isa_ior_n_next = 1; top->isa_iow_n_next = 1;
        top->isa_aen = 0; top->isa_aen_next = 0;
        top->eval();
        bp.clock = [this](const Bus &c, const Bus &n) { return clk1(c, n); };
        set_com(2);
        reset(4);
    }
    void set_com(int c) { m.com = c; top->com = c; }
    uint8_t clk1(const Bus &c, const Bus &n) {
        if (!sinq.empty()) {
            pins.sin = sinq.front().first;
            if (--sinq.front().second == 0) sinq.pop_front();
        }
        top->isa_addr = c.addr; top->isa_aen = c.aen; top->isa_ior_n = c.ior_n; top->isa_iow_n = c.iow_n;
        top->isa_dout = c.dout;
        top->isa_addr_next = n.addr; top->isa_aen_next = n.aen; top->isa_ior_n_next = n.ior_n;
        top->isa_iow_n_next = n.iow_n;
        top->sin = pins.sin; top->cts_n = pins.cts_n; top->dsr_n = pins.dsr_n; top->dcd_n = pins.dcd_n;
        top->ri_n = pins.ri_n;
        top->reset = rst;
        top->eval();
        dsel_seen |= top->isa_dsel;
        bool bad = top->isa_dsel != m.dsel(c) || top->isa_din != m.din(c) || top->intr != m.intr() ||
                   top->irq3 != m.irq3() || top->irq4 != m.irq4() || top->sout != m.sout() ||
                   top->rts_n != m.rts_n() || top->dtr_n != m.dtr_n() || top->out1_n != m.out1_n() ||
                   top->out2_n != m.out2_n();
        if (bad) {
            if (mism++ < 10)
                printf("MISMATCH clk %llu a %X: dsel %d/%d din %02X/%02X intr %d/%d irq %d%d/%d%d sout %d/%d "
                       "rts %d/%d dtr %d/%d o1 %d/%d o2 %d/%d\n",
                       (unsigned long long)bp.clk, c.addr, top->isa_dsel, m.dsel(c), top->isa_din, m.din(c),
                       top->intr, m.intr(), top->irq3, top->irq4, m.irq3(), m.irq4(), top->sout, m.sout(),
                       top->rts_n, m.rts_n(), top->dtr_n, m.dtr_n(), top->out1_n, m.out1_n(), top->out2_n,
                       m.out2_n());
            failures++;
        }
        if (top->sout != last_sout) { edges.push_back({bp.clk, (bool)top->sout}); last_sout = top->sout; }
        if (last_intr && !top->intr) intr_falls++;
        last_intr = top->intr;
        uint8_t d = top->isa_din;
        top->clk = 1;
        top->eval();
        m.clock(c, n, pins, rst);
        top->clk = 0;
        return d;
    }
    void run(uint64_t n) { bp.run(n); }
    void reset(int n) { rst = true; run(n); rst = false; run(2); }
    unsigned B() const { return m.com == 2 ? 0x3F8 : 0x2F8; }
    uint8_t in(int r, uint64_t gap = 0) { return bp.in(B() + r, gap); }
    void out(int r, uint8_t v, uint64_t gap = 0) { bp.out(B() + r, v, gap); }
    void baud(unsigned div, uint8_t lcr) {
        out(3, 0x80 | lcr); out(0, div & 255); out(1, div >> 8); out(3, lcr);
    }
    // wait until (LSR & mask) == want, at most n clk
    bool wait_lsr(uint8_t mask, uint8_t want, uint64_t n) {
        uint64_t t0 = bp.clk;
        while (bp.clk - t0 < n) { if ((in(5) & mask) == want) return true; run(50); }
        return false;
    }
    // a frame on SIN: bit time in clk (may be fractional), the bits as levels
    void sin_frame(const std::vector<bool> &bits, double bt) {
        double t = 0, done = 0;
        for (bool b : bits) {
            t += bt;
            uint64_t n = uint64_t(t - done + 0.5);
            if (n) sinq.push_back({b, n});
            done += n;
        }
    }
    void sin_idle(uint64_t n) { sinq.push_back({true, n}); }
    bool sin_busy() const { return !sinq.empty(); }
    void sin_wait() { while (!sinq.empty()) run(1); }
};

static double bit_clk(unsigned div) { return 16.0 * div * TICK; }

// the levels of a frame as the spec defines it (independent of the model)
static std::vector<bool> frame_bits(uint8_t d, int n, int par, int stops2, int bad_par = 0, int bad_stop = 0) {
    // par: 0 none, 1 odd, 2 even, 3 mark (stick, EPS 0), 4 space (stick, EPS 1)
    std::vector<bool> v{false};
    int ones = 0;
    for (int i = 0; i < n; i++) { bool b = (d >> i) & 1; v.push_back(b); ones += b; }
    if (par) {
        bool p = par == 1 ? !(ones & 1) : par == 2 ? (ones & 1) : par == 3;
        v.push_back(bad_par ? !p : p);
    }
    v.push_back(!bad_stop);
    if (stops2) v.push_back(!bad_stop);      // (1.5 for 5 bits: the second half bit is fine as a whole)
    return v;
}
static uint8_t lcr_of(int n, int par, int stops2) {
    uint8_t l = (n - 5) | (stops2 ? 4 : 0);
    if (par) l |= 8;
    if (par == 2) l |= 0x10;
    if (par == 3) l |= 0x20;
    if (par == 4) l |= 0x30;
    return l;
}

// decode the frame that starts at SOUT edge index i: sample each bit in its middle
struct Decoded { int data, par, stop_ok; uint64_t start; };
static Decoded decode(const std::vector<std::pair<uint64_t, bool>> &e, size_t i, int n, bool pen, double bt) {
    auto level = [&](double t) {
        bool lv = true;
        for (auto &x : e) { if (x.first <= t) lv = x.second; else break; }
        return lv;
    };
    Decoded d{0, -1, 0, e[i].first};
    double t0 = e[i].first;
    for (int b = 0; b < n; b++) d.data |= level(t0 + bt * (b + 1.5)) << b;
    int k = n + 1;
    if (pen) { d.par = level(t0 + bt * (k + 0.5)); k++; }
    d.stop_ok = level(t0 + bt * (k + 0.5));
    return d;
}

// ------------------------------------------------------------ tests
static void t_regs() {
    Sim s;
    CHECK(s.in(1) == 0x00, "IER after reset");
    CHECK(s.in(2) == 0x01, "IIR after reset");
    CHECK(s.in(3) == 0x00, "LCR after reset");
    CHECK(s.in(4) == 0x00, "MCR after reset");
    CHECK(s.in(5) == 0x60, "LSR after reset %02X", s.in(5));
    CHECK(s.in(6) == 0x00, "MSR after reset (nothing plugged in)");
    CHECK(s.in(7) == 0xFF, "no scratch register");
    s.out(7, 0x55);
    CHECK(s.in(7) == 0xFF, "scratch write ignored");
    s.out(3, 0x80); s.out(0, 0x0C); s.out(1, 0x00);
    CHECK(s.in(0) == 0x0C && s.in(1) == 0x00, "DLL/DLM read back");
    s.out(1, 0xA5);
    CHECK(s.in(1) == 0xA5, "DLM 8 bits");
    s.out(3, 0x1B);
    CHECK(s.in(3) == 0x1B, "LCR read back");
    s.out(1, 0xFF);
    CHECK(s.in(1) == 0x0F, "IER 4 bits");
    s.out(1, 0x00);
    s.out(4, 0xFF);
    CHECK(s.in(4) == 0x1F, "MCR 5 bits");
    s.out(4, 0x00);
    s.out(2, 0xC7);
    CHECK(s.in(2) == 0x01, "IIR not writable");
    // the BIOS's probe (F000:CCBC): divisor 1, MCR 0, divisor AAh, read DLL
    s.out(3, 0x80); s.out(1, 0x00); s.out(0, 0x01); s.out(4, 0x00);
    s.out(3, 0x80); s.out(1, 0x00); s.out(0, 0xAA);
    CHECK(s.in(0) == 0xAA, "the BIOS's probe");
    // decode
    for (int c = 0; c < 4; c++) {
        s.set_com(c);
        s.dsel_seen = false;
        uint8_t v2 = s.bp.in(0x2FB), v3 = s.bp.in(0x3FB);
        if (c == 1) CHECK(v2 == 0x80, "com 01: 2F8h");
        if (c == 2) CHECK(v3 == 0x80, "com 10: 3F8h");
        if (c == 0 || c == 3) CHECK(!s.dsel_seen, "com %d: no port", c);
        s.dsel_seen = false;
        s.bp.in(0x3FB, 0, true); s.bp.in(0x2FB, 0, true);
        CHECK(!s.dsel_seen, "AEN: no port (com %d)", c);
        s.dsel_seen = false;
    }
    s.set_com(2);
    s.dsel_seen = false;
    s.bp.in(0x3F7);
    CHECK(!s.dsel_seen, "3F7h is not the UART");
    s.bp.in(0x7F8);
    CHECK(s.dsel_seen, "A15-A10 not decoded (the 5720 decodes BA9-BA0)");
}

static void t_baud() {
    unsigned divs[] = {1, 2, 3, 6, 12, 0x18, 0x60, 0x180, 0x417};
    for (unsigned dv : divs) {
        Sim s;
        s.baud(dv, 0x03);
        s.edges.clear();
        int nchar = dv >= 0x60 ? 2 : 6;
        for (int i = 0; i < nchar; i++) {
            CHECK(s.wait_lsr(0x20, 0x20, uint64_t(bit_clk(dv) * 12)), "THRE (div %u)", dv);
            s.out(0, 0x55);
        }
        CHECK(s.wait_lsr(0x40, 0x40, uint64_t(bit_clk(dv) * 25)), "TEMT (div %u)", dv);
        // 0x55 8N1: an edge at every bit boundary from the start to the stop bit: 10 per frame
        double bt = bit_clk(dv);
        int bad = 0;
        for (size_t i = 1; i < s.edges.size(); i++) {
            double dt = double(s.edges[i].first - s.edges[i - 1].first);
            double k = std::round(dt / bt);
            if (k < 1 || std::fabs(dt - k * bt) > 1.0) bad++;
        }
        CHECK(bad == 0, "bit times (div %u): %d intervals off", dv, bad);
        CHECK((int)s.edges.size() == nchar * 10, "edges (div %u): %zu", dv, s.edges.size());
        // back to back: start to start = 10 bits
        for (int c = 1; c < nchar; c++) {
            double dt = double(s.edges[c * 10].first - s.edges[(c - 1) * 10].first);
            CHECK(std::fabs(dt - 10 * bt) <= 1.0, "frame length (div %u): %.1f vs %.1f", dv, dt, 10 * bt);
        }
        CHECK(s.mism == 0, "model (div %u)", dv);
    }
    // a DLL write alone restarts the divisor counter (the data sheet: "upon loading either
    // of the Divisor Latches, the baud counter is immediately loaded")
    {
        Sim s;
        s.baud(6, 0x03);
        for (int k = 0; k < 40; k++) {
            s.run(7 + k * 3);
            s.out(3, 0x83); s.out(0, 6); s.out(3, 0x03);
            s.out(0, 0x5A);
            s.wait_lsr(0x40, 0x40, 40000);
        }
        CHECK(s.mism == 0, "model (DLL write restarts the counter)");
    }
    // divisor 0: no clock, nothing goes out; a divisor then starts it
    Sim s;
    s.baud(0, 0x03);
    s.out(0, 0x41);
    s.run(100000);
    CHECK(s.edges.empty() && (s.in(5) & 0x60) == 0x00, "divisor 0 stops the clock");
    s.out(3, 0x83); s.out(0, 1); s.out(3, 0x03);
    CHECK(s.wait_lsr(0x40, 0x40, 5000), "divisor 1 restarts");
    CHECK(!s.edges.empty(), "the character went out");
    CHECK(s.mism == 0, "model (div 0)");
}

static void t_format() {
    std::mt19937 rng(7);
    for (int n = 5; n <= 8; n++)
        for (int par = 0; par <= 4; par++)
            for (int st = 0; st <= 1; st++) {
                Sim s;
                uint8_t lcr = lcr_of(n, par, st);
                s.baud(1, lcr);
                double bt = bit_clk(1);
                // out on SOUT, decoded by the line decoder
                std::vector<uint8_t> sent;
                s.edges.clear();
                for (int i = 0; i < 4; i++) {
                    CHECK(s.wait_lsr(0x20, 0x20, 20000), "THRE");
                    uint8_t v = rng();
                    sent.push_back(v);
                    s.out(0, v);
                }
                CHECK(s.wait_lsr(0x40, 0x40, 20000), "TEMT");
                s.run(uint64_t(bt * 3));
                // find the start edges: the first falling edge, then one per frame
                double flen = bt * (1 + n + (par ? 1 : 0)) + (st ? (n == 5 ? 1.5 : 2.0) * bt : bt);
                size_t i = 0;
                for (int c = 0; c < 4; c++) {
                    while (i < s.edges.size() && s.edges[i].second) i++;
                    if (i >= s.edges.size()) { CHECK(false, "frame %d not found", c); break; }
                    Decoded d = decode(s.edges, i, n, par != 0, bt);
                    uint8_t want = sent[c] & ((1 << n) - 1);
                    CHECK(d.data == want, "data %d%c%d: %02X vs %02X", n, "NOEMS"[par], st + 1, d.data, want);
                    if (par) {
                        int ones = __builtin_popcount(want);
                        int p = par == 1 ? !(ones & 1) : par == 2 ? (ones & 1) : par == 3;
                        CHECK(d.par == p, "parity %d%c%d", n, "NOEMS"[par], st + 1);
                    }
                    CHECK(d.stop_ok, "stop %d%c%d", n, "NOEMS"[par], st + 1);
                    // the next start edge (back to back) after exactly flen
                    uint64_t t0 = s.edges[i].first;
                    i++;
                    while (i < s.edges.size() && (s.edges[i].first < t0 + flen - 2 || s.edges[i].second)) i++;
                    if (c < 3)
                        CHECK(i < s.edges.size() && std::fabs(double(s.edges[i].first - t0) - flen) <= 1.0,
                              "frame length %d%c%d", n, "NOEMS"[par], st + 1);
                }
                // loopback: the receiver takes the same format
                s.out(4, 0x10);
                for (int k = 0; k < 6; k++) {
                    uint8_t v = rng();
                    s.out(0, v);
                    CHECK(s.wait_lsr(0x01, 0x01, uint64_t(bt * 30)), "loop: DR");
                    uint8_t lsr = s.in(5);
                    CHECK((lsr & 0x1E) == 0, "loop: no error %02X (%d%c%d)", lsr, n, "NOEMS"[par], st + 1);
                    uint8_t r = s.in(0);
                    CHECK(r == (v & ((1 << n) - 1)), "loop: %02X vs %02X", r, v);
                }
                CHECK(s.mism == 0, "model %d%c%d", n, "NOEMS"[par], st + 1);
            }
}

static void t_rx() {
    std::mt19937 rng(11);
    Sim s;
    unsigned dv = 3;
    double bt = bit_clk(dv);
    // good characters in several formats and at baud errors of -3..+3 %
    for (int n = 5; n <= 8; n++)
        for (int par = 0; par <= 4; par++)
            for (double err : {-0.03, 0.0, 0.03}) {
                s.baud(dv, lcr_of(n, par, par & 1));
                uint8_t v = rng() & ((1 << n) - 1);
                s.sin_frame(frame_bits(v, n, par, par & 1), bt * (1 + err));
                s.sin_idle(uint64_t(bt * 2));
                s.sin_wait();
                uint8_t lsr = s.in(5);
                CHECK((lsr & 0x1F) == 0x01, "rx %d%c %+.0f%%: LSR %02X", n, "NOEMS"[par], err * 100, lsr);
                CHECK(s.in(0) == v, "rx %d%c %+.0f%%: data", n, "NOEMS"[par], err * 100);
                CHECK((s.in(5) & 1) == 0, "DR cleared by reading RBR");
            }
    // parity error
    s.baud(dv, lcr_of(8, 2, 0));
    s.sin_frame(frame_bits(0x35, 8, 2, 0, 1), bt); s.sin_idle(uint64_t(bt)); s.sin_wait();
    uint8_t lsr = s.in(5);
    CHECK((lsr & 0x1F) == 0x05, "parity error: LSR %02X", lsr);
    CHECK(s.in(0) == 0x35, "parity error: the data");
    CHECK((s.in(5) & 0x1E) == 0, "LSR read cleared PE");
    // framing error: stop bit 0, then the line goes high
    s.baud(dv, lcr_of(8, 0, 0));
    s.sin_frame(frame_bits(0xC3, 8, 0, 0, 0, 1), bt); s.sin_idle(uint64_t(bt * 2)); s.sin_wait();
    lsr = s.in(5);
    CHECK((lsr & 0x1F) == 0x09, "framing error: LSR %02X", lsr);
    CHECK(s.in(0) == 0xC3, "framing error: the data");
    // break: low for three frames, then high; one zero character
    s.sin_frame({false}, bt * 30); s.sin_idle(uint64_t(bt * 3)); s.sin_wait();
    lsr = s.in(5);
    CHECK((lsr & 0x1F) == 0x19, "break: LSR %02X (BI FE DR)", lsr);
    CHECK(s.in(0) == 0x00, "break: RBR 00h");
    CHECK((s.in(5) & 0x1F) == 0x00, "break: one character only");
    // overrun: two characters without reading
    s.sin_frame(frame_bits(0x11, 8, 0, 0), bt); s.sin_frame(frame_bits(0x22, 8, 0, 0), bt);
    s.sin_idle(uint64_t(bt)); s.sin_wait();
    lsr = s.in(5);
    CHECK((lsr & 0x1F) == 0x03, "overrun: LSR %02X", lsr);
    CHECK(s.in(0) == 0x22, "overrun: the newer character");
    CHECK((s.in(5) & 0x1F) == 0x00, "overrun cleared");
    // a false start: low for a quarter bit
    s.sin_frame({false}, bt / 4); s.sin_idle(uint64_t(bt * 12)); s.sin_wait();
    CHECK((s.in(5) & 0x1F) == 0x00, "false start ignored");
    // a burst back to back with one stop bit at +2 % (the receiver resynchronizes on every start)
    for (int i = 0; i < 1; i++) {
        std::vector<uint8_t> v;
        for (int k = 0; k < 5; k++) { v.push_back(rng()); s.sin_frame(frame_bits(v.back(), 8, 0, 0), bt * 1.02); }
        s.sin_idle(uint64_t(bt));
        int got = 0;
        while (s.sin_busy() || (s.in(5) & 1)) {
            if (s.in(5) & 1) { uint8_t r = s.in(0); CHECK(got < 5 && r == v[got], "burst %d", got); got++; }
            else s.run(100);
        }
        CHECK(got == 5, "burst: %d characters", got);
    }
    CHECK(s.mism == 0, "model (rx)");
}

static void t_intr() {
    Sim s;
    s.baud(1, 0x03);
    s.out(4, 0x08);                         // OUT2
    s.out(1, 0x02);                         // ETBEI with THRE set: an interrupt at once
    CHECK(s.top->irq4, "THRE interrupt on enabling: IRQ4");
    CHECK(s.in(2) == 0x02, "THRE interrupt on enabling");
    CHECK(!s.top->irq4 && s.in(2) == 0x01, "IIR read cleared it");
    s.out(1, 0x02);
    CHECK(s.in(2) == 0x02, "an IER write with ETBEI sets it again (the 8250)");
    s.out(0, 0x41);
    s.run(200);
    CHECK(s.in(2) == 0x02, "THRE again after the transfer");
    s.out(1, 0x00);
    CHECK(s.in(2) == 0x01 && !s.top->irq4, "IER 0: none");
    // all four sources in loopback: RLS (overrun), RDA, THRE, MS
    s.out(4, 0x18);
    s.out(0, 0x11); s.wait_lsr(0x01, 0x01, 20000);
    s.out(0, 0x22); s.wait_lsr(0x02, 0x02, 20000);   // reading LSR clears OE: wait on the model instead
    s.run(5000);
    s.out(4, 0x19);                          // DTR -> DSR in loopback: DDSR
    s.out(1, 0x0F);
    s.run(3000);
    // OE may have been cleared by the polling above: make a fresh overrun
    s.in(0);
    s.out(0, 0x33); s.run(6000); s.out(0, 0x44); s.run(6000);
    s.out(1, 0x0F);
    long f0 = s.intr_falls;
    CHECK(s.in(2) == 0x06, "RLS first");
    CHECK(s.top->intr, "INTR");
    s.in(5);                                 // clears RLS: RDA stays, INTR pulses
    CHECK(s.intr_falls == f0 + 1, "the 8250's pulse after RLS was cleared");
    CHECK(s.in(2) == 0x04, "then RDA");
    s.in(0);
    CHECK(s.intr_falls == f0 + 2, "pulse after RDA");
    CHECK(s.in(2) == 0x02, "then THRE");     // this read clears THRE
    CHECK(s.intr_falls == f0 + 3, "pulse after THRE");
    CHECK(s.in(2) == 0x00, "then MS");
    s.in(6);
    CHECK(s.in(2) == 0x01, "none");
    CHECK(s.intr_falls == f0 + 4, "INTR fell once more");
    CHECK(!s.top->irq4, "no IRQ in loopback (OUT2 pin inactive)");
    // the bus IRQ needs OUT2 out of loopback; com 01 routes it to IRQ3
    s.out(4, 0x08); s.out(1, 0x02);
    CHECK(s.top->irq4 && !s.top->irq3, "IRQ4 at 3F8h");
    s.set_com(1);
    s.run(2);
    CHECK(s.top->irq3 && !s.top->irq4, "IRQ3 at 2F8h");
    s.out(4, 0x00);
    CHECK(!s.top->irq3 && s.top->intr, "OUT2 off: no IRQ, INTR still set");
    CHECK(s.mism == 0, "model (intr)");
}

static void t_msr() {
    Sim s;
    s.out(4, 0x08); s.out(1, 0x08);
    struct { bool *p; uint8_t st, dl; const char *n; } pin[] = {
        {&s.pins.cts_n, 0x10, 0x01, "CTS"}, {&s.pins.dsr_n, 0x20, 0x02, "DSR"},
        {&s.pins.dcd_n, 0x80, 0x08, "DCD"}};
    for (auto &p : pin) {
        *p.p = false; s.run(4);
        CHECK(s.in(2) == 0x00 && s.top->irq4, "%s: MS interrupt", p.n);
        uint8_t v = s.in(6);
        CHECK(v == (p.st | p.dl), "%s active: MSR %02X", p.n, v);
        CHECK(s.in(6) == p.st, "%s: delta cleared", p.n);
        *p.p = true; s.run(4);
        CHECK(s.in(6) == p.dl, "%s inactive: delta", p.n);
        CHECK(s.in(2) == 0x01, "%s: none", p.n);
    }
    s.pins.ri_n = false; s.run(4);
    CHECK(s.in(6) == 0x40, "RI active: no TERI");
    s.pins.ri_n = true; s.run(4);
    CHECK(s.in(6) == 0x04, "RI inactive: TERI");
    // loopback: MCR -> MSR, the outputs inactive
    s.out(4, 0x1F);
    CHECK(s.top->rts_n && s.top->dtr_n && s.top->out1_n && s.top->out2_n && s.top->sout, "loopback outputs high");
    uint8_t v = s.in(6);
    CHECK((v & 0xF0) == 0xF0, "loopback: all four %02X", v);
    s.out(4, 0x10 | 0x01); v = s.in(6) & 0xF0;
    CHECK(v == 0x20, "DTR -> DSR %02X", v);
    s.out(4, 0x10 | 0x02); v = s.in(6) & 0xF0;
    CHECK(v == 0x10, "RTS -> CTS %02X", v);
    s.out(4, 0x10 | 0x04); v = s.in(6) & 0xF0;
    CHECK(v == 0x40, "OUT1 -> RI %02X", v);
    s.out(4, 0x10 | 0x08); v = s.in(6) & 0xF0;
    CHECK(v == 0x80, "OUT2 -> DCD %02X", v);
    // the outputs out of loopback
    s.out(4, 0x0F);
    CHECK(!s.top->rts_n && !s.top->dtr_n && !s.top->out1_n && !s.top->out2_n, "outputs active");
    s.out(4, 0x00);
    // BREAK
    s.out(3, 0x43);
    CHECK(!s.top->sout, "BREAK: SOUT low");
    s.out(3, 0x03);
    CHECK(s.top->sout, "BREAK off");
    // SOUT stays high in loopback while a character is sent
    s.baud(1, 0x03); s.out(4, 0x10); s.edges.clear();
    s.out(0, 0x00); s.run(4000);
    CHECK(s.edges.empty() && (s.in(5) & 1), "loopback: SOUT high, the character received");
    // reset
    s.out(1, 0x0F); s.out(4, 0x1F); s.out(3, 0x1F);
    s.reset(3);
    CHECK(s.in(1) == 0 && s.in(4) == 0 && s.in(3) == 0 && s.in(5) == 0x60 && s.in(2) == 0x01, "reset");
    CHECK(s.mism == 0, "model (msr)");
}

static void t_random() {
    std::mt19937 rng(1234);
    Sim s;
    s.baud(1, 0x03);
    uint8_t lcr = 0x03;
    for (long op = 0; op < 400000; op++) {
        int k = rng() % 100;
        if (k < 30) s.in(rng() % 8, rng() % 40);
        else if (k < 40) { if (s.in(5) & 0x20) s.out(0, rng(), rng() % 40); }
        else if (k < 45) s.out(1, rng() & 15);
        else if (k < 50) s.out(4, rng() & 0x1F);
        else if (k < 53) {
            // a new format or divisor only when both directions are idle
            if ((s.in(5) & 0x40) && !s.sin_busy() && s.m.rst == UartModel::RI) {
                lcr = rng() & 0x7F;
                unsigned dv = 1 + rng() % 4;
                s.baud(dv, lcr);
            }
        } else if (k < 60) {
            if (!s.sin_busy()) {
                int n = 5 + (lcr & 3);
                double bt = bit_clk(s.m.divisor() ? s.m.divisor() : 1) * (1 + ((int)(rng() % 7) - 3) / 100.0);
                int par = (lcr & 8) ? 1 + ((lcr >> 4) & 3) : 0;
                if (par == 3) par = 3; else if (par == 4) par = 4;
                s.sin_frame(frame_bits(rng(), n, (rng() % 8) ? par : (rng() % 5), lcr & 4, rng() % 6 == 0,
                                       rng() % 8 == 0), bt);
                s.sin_idle(uint64_t(rng() % 3000));
            }
        } else if (k < 66) {
            bool *pp[] = {&s.pins.cts_n, &s.pins.dsr_n, &s.pins.dcd_n, &s.pins.ri_n};
            *pp[rng() % 4] ^= 1;
            s.run(rng() % 20);
        } else if (k < 67) s.set_com(rng() % 4), s.run(3), s.set_com(2);
        else if (k < 68) s.out(7, rng());
        else if (k < 69) s.out(2, rng());
        else if (k < 70 && rng() % 20 == 0) s.reset(1 + rng() % 3), lcr = 0, s.baud(1, 0x03), lcr = 0x03;
        else s.run(rng() % 400);
    }
    printf("random: %llu clk\n", (unsigned long long)s.bp.clk);
    CHECK(s.mism == 0, "model (random)");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    struct T { const char *n; void (*f)(); } tests[] = {
        {"regs", t_regs}, {"baud", t_baud}, {"format", t_format}, {"rx", t_rx},
        {"intr", t_intr}, {"msr", t_msr}, {"random", t_random}};
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
    printf("uart: %d tests, %ld checks, %d failures\n", ran, checks, failures);
    return failures ? 1 : 0;
}
