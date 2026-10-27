// pit_run.cpp - Verilator testbench for the 8253 (rtl/system/kf/KF8253): the
// byte sequence of count reads and writes, the counter latch, and the control
// word that restarts both (doc/history.md 2026-10-26, "8253 control word").
//
// The chip is driven with I/O cycles as the board makes them (chip select,
// address and data stable around a 4-clk RD/WR strobe); the counters' clock
// inputs get single falling edges between the bus cycles, so every count is
// known. Next to it runs a model of the 8253 written from the Intel data sheet
// (and MartyPC's pit.rs, which behaves the same):
//   - a control word (RL != 00) stops the counter, sets RL and restarts the
//     read and the write byte sequence (LSB first for RL = 11) and drops a
//     latched count that was not read;
//   - RL = 00 latches the count unless a latched count is still unread;
//   - a read returns the latched count, else the counting element: RL = 01
//     the LSB, 10 the MSB, 11 LSB then MSB (a latch ends with the last byte);
//   - writes: RL = 01 / 10 one byte (the other one 0), 11 LSB then MSB; a
//     complete count is loaded at the next clock edge after a control word
//     (mode 2), reloaded after 1 (rate generator); 0 counts 65536.
// The counters stay in mode 2 (the model counts mode 2 only); each read's data
// is compared with the model.
//
// usage: pit_run [test ...]   tests: seq zen random   (none: all)
//
// GPL-3.0-or-later, pc10-iii.

#include "VKF8253.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

static int failures = 0;
static long checks = 0;
#define CHECK(c, ...) do { checks++; if (!(c)) { failures++; if (failures < 30) { printf("FAIL: " __VA_ARGS__); printf("\n"); } } } while (0)

struct Model {
    struct Ctr {
        int rl = 1;                 // after reset: KF8253 RL_SELECT_MSB? set by the first control word
        bool rmsb = false, wmsb = false;
        bool latched = false;
        uint32_t lv = 0;
        uint32_t count = 0;         // counting element, 17 bits (0x10000 = 65536)
        bool running = false, load = false;
        uint32_t n = 0;             // count register (17 bits)
        uint8_t wlsb = 0;
    } c[3];
    void control(uint8_t v) {
        int i = v >> 6;
        if (i == 3) return;
        Ctr &k = c[i];
        if (((v >> 4) & 3) == 0) {
            if (!k.latched) { k.latched = true; k.lv = k.count & 0xFFFF; }
            return;
        }
        k.rl = (v >> 4) & 3;
        k.rmsb = k.wmsb = (k.rl == 2);
        k.latched = false;
        k.running = false; k.load = false; k.count = 0;
    }
    void write(int i, uint8_t b) {
        Ctr &k = c[i];
        bool done = false;
        if (k.rl == 1) { k.n = b; done = true; }
        else if (k.rl == 2) { k.n = uint32_t(b) << 8; done = true; }
        else if (!k.wmsb) { k.wlsb = b; k.wmsb = true; }
        else { k.n = k.wlsb | (uint32_t(b) << 8); k.wmsb = false; done = true; }
        if (done) {
            if (k.n == 0) k.n = 0x10000;
            if (!k.running) { k.running = true; k.load = true; }
        }
    }
    uint8_t read(int i) {
        Ctr &k = c[i];
        uint32_t v = k.latched ? k.lv : (k.count & 0xFFFF);
        uint8_t r;
        if (k.rl == 1) { r = v & 0xFF; k.latched = false; }
        else if (k.rl == 2) { r = v >> 8; k.latched = false; }
        else if (!k.rmsb) { r = v & 0xFF; k.rmsb = true; }
        else { r = v >> 8; k.rmsb = false; k.latched = false; }
        return r;
    }
    void edge(int i) {
        Ctr &k = c[i];
        if (!k.running) return;
        if (k.load) { k.count = k.n; k.load = false; return; }
        k.count = (k.count <= 1) ? k.n : k.count - 1;
    }
};

struct Sim {
    VKF8253 *t;
    Model m;
    uint64_t clk = 0;
    long reads = 0;
    Sim() {
        t = new VKF8253;
        t->clock = 0; t->reset = 1;
        t->chip_select_n = 1; t->read_enable_n = 1; t->write_enable_n = 1;
        t->address = 0; t->data_bus_in = 0;
        t->counter_0_clock = 0; t->counter_1_clock = 0; t->counter_2_clock = 0;
        t->counter_0_gate = 1; t->counter_1_gate = 1; t->counter_2_gate = 1;
        for (int i = 0; i < 4; i++) tick();
        t->reset = 0;
        for (int i = 0; i < 4; i++) tick();
    }
    void tick() {
        t->clock = 1; t->eval();
        t->clock = 0; t->eval();
        clk++;
    }
    void idle(int n) { for (int i = 0; i < n; i++) tick(); }
    void out(int a, uint8_t d) {
        t->address = a; t->data_bus_in = d; t->chip_select_n = 0;
        tick();
        t->write_enable_n = 0; idle(4);
        t->write_enable_n = 1; idle(2);
        t->chip_select_n = 1; idle(2);
        if (a == 3) m.control(d); else m.write(a, d);
    }
    uint8_t in(int a) {
        t->address = a; t->chip_select_n = 0;
        tick();
        t->read_enable_n = 0; idle(4);
        t->eval();
        uint8_t d = t->data_bus_out;
        t->read_enable_n = 1; idle(2);
        t->chip_select_n = 1; idle(2);
        uint8_t e = m.read(a);
        reads++;
        CHECK(d == e, "clk %llu: read of counter %d = %02X, expected %02X", (unsigned long long)clk, a, d, e);
        return d;
    }
    // one falling edge on counter i's clock input
    void edge(int i) {
        auto set = [&](int v) {
            if (i == 0) t->counter_0_clock = v; else if (i == 1) t->counter_1_clock = v; else t->counter_2_clock = v;
        };
        set(1); idle(3);
        set(0); idle(4);
        m.edge(i);
    }
    void edges(int i, int n) { for (int k = 0; k < n; k++) edge(i); }
};

// the regression: one odd read or write, then a control word with the same RL
static void t_seq() {
    Sim s;
    s.out(3, 0x34); s.out(0, 0x00); s.out(0, 0x00);    // Zen timer start
    s.edges(0, 300);
    s.out(3, 0x00); s.in(0);                            // latch, LSB only
    s.out(3, 0x34); s.out(0, 0x00); s.out(0, 0x00);    // the same RL again
    s.edges(0, 1234);
    s.out(3, 0x00); s.in(0); s.in(0);                   // must be LSB, MSB
    s.edges(0, 5);
    s.in(0); s.in(0);                                   // unlatched
    // an odd write, then the control word
    s.out(3, 0x34); s.out(0, 0x12);
    s.out(3, 0x34); s.out(0, 0x34); s.out(0, 0x12);    // count 1234h
    s.edges(0, 7);
    s.out(3, 0x00); s.in(0); s.in(0);
    // a latch that was never read, then a control word: the latch is gone
    s.out(3, 0x00);
    s.out(3, 0x34); s.out(0, 0x00); s.out(0, 0x10);
    s.edges(0, 20);
    s.in(0); s.in(0);
    // a second latch before the read is ignored
    s.out(3, 0x00); s.edges(0, 9); s.out(3, 0x00); s.in(0); s.in(0);
    // the BIOS (36h) and the Zen timer (34h) on counter 0; counter 1 (54h, LSB only), counter 2 (B4h)
    s.out(3, 0x54); s.out(1, 18); s.edges(1, 40); s.in(1); s.in(1);
    s.out(3, 0x40); s.in(1); s.out(3, 0x54); s.in(1);
    s.out(3, 0xB4); s.out(2, 0x00); s.out(2, 0x08); s.edges(2, 100);
    s.out(3, 0x80); s.in(2);
    s.out(3, 0xB4); s.out(2, 0x00); s.out(2, 0x08); s.edges(2, 3);
    s.out(3, 0x80); s.in(2); s.in(2);
    // RL = 10 (MSB only), then back to 11
    s.out(3, 0x24); s.out(0, 0x05); s.edges(0, 300); s.in(0); s.in(0);
    s.out(3, 0x34); s.out(0, 0xFF); s.out(0, 0x00); s.edges(0, 3); s.in(0); s.in(0);
}

// 8088 MPH's metric and CGA_COMP's timings: Zen timer start, run, latch, two reads
static void t_zen() {
    Sim s;
    std::mt19937 r(5150);
    for (int k = 0; k < 400; k++) {
        s.out(3, 0x34); s.out(0, 0x00); s.out(0, 0x00);
        s.edges(0, 1 + r() % 900);
        s.out(3, 0x00);
        s.in(0); s.in(0);
        if (r() % 7 == 0) s.in(0);          // somebody's odd read in between
    }
}

static void t_random() {
    Sim s;
    std::mt19937 r(8088);
    for (int i = 0; i < 3; i++) { s.out(3, uint8_t((i << 6) | 0x34)); s.out(i, 0x00); s.out(i, 0x00); }
    for (int k = 0; k < 60000; k++) {
        int i = r() % 3;
        switch (r() % 10) {
        case 0: s.out(3, uint8_t((i << 6) | ((1 + r() % 3) << 4) | 0x04)); break;      // mode 2, random RL
        case 1: s.out(3, uint8_t(i << 6)); break;                                      // latch
        case 2: case 3: s.out(i, uint8_t(r())); break;
        case 4: case 5: case 6: s.in(i); break;
        default: s.edges(i, 1 + r() % 40); break;
        }
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::vector<std::string> tests;
    for (int i = 1; i < argc; i++) if (argv[i][0] != '+') tests.push_back(argv[i]);
    if (tests.empty()) tests = {"seq", "zen", "random"};
    for (auto &n : tests) {
        int f0 = failures; long c0 = checks;
        if (n == "seq") t_seq();
        else if (n == "zen") t_zen();
        else if (n == "random") t_random();
        else { printf("unknown test %s\n", n.c_str()); return 2; }
        printf("%s: %s (%ld reads compared, %d failures)\n", n.c_str(), failures == f0 ? "PASS" : "FAIL",
               checks - c0, failures - f0);
    }
    if (failures) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    return 0;
}
