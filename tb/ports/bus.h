// bus.h - the card bus as tb/ports drives it: CPU I/O cycles of the 8088 at
// 4.77 MHz with one wait state (IOR from the CLK fall in T1 to T4, IOW from T2;
// doc/architecture.md section 3), one Bus per clk with the next clk's values.
// Shared by the port testbenches (uart, lpt, mouse).
//
// GPL-3.0-or-later, pc10-iii.
#pragma once
#include <cstdint>
#include <cstdio>
#include <deque>
#include <functional>

struct Bus {
    uint32_t addr = 0x12345;
    bool ior_n = true, iow_n = true, aen = false;
    uint8_t dout = 0;
    bool sample = false;        // harness: take the read data in this clk
};

static int failures = 0;
static long checks = 0;
#define CHECK(c, ...) do { checks++; if (!(c)) { failures++; if (failures < 40) { printf("FAIL: " __VA_ARGS__); printf("\n"); } } } while (0)

// The plan of bus states; `clock` is called once per clk with the current and
// the next bus state and must drive, evaluate, compare, edge and return the
// read data of a sampled clk.
struct BusPlan {
    std::deque<Bus> plan;
    std::function<uint8_t(const Bus &, const Bus &)> clock;
    uint8_t rd = 0;
    uint64_t clk = 0;

    void cycle() {
        Bus cur, nx;
        if (!plan.empty()) { cur = plan.front(); plan.pop_front(); }
        if (!plan.empty()) nx = plan.front();
        uint8_t d = clock(cur, nx);
        if (cur.sample) rd = d;
        clk++;
    }
    void run(uint64_t n) { for (uint64_t i = 0; i < n; i++) cycle(); }
    void flush() { while (!plan.empty()) cycle(); }

    uint8_t in(unsigned port, uint64_t gap = 0, bool aen = false) {
        Bus b; b.addr = port; b.aen = aen;
        for (int i = 0; i < 3; i++) plan.push_back(b);
        b.ior_n = false;
        for (int i = 0; i < 21; i++) { b.sample = i == 20; plan.push_back(b); }
        b.ior_n = true; b.sample = false;
        for (int i = 0; i < 3; i++) plan.push_back(b);
        flush();
        run(gap);
        return rd;
    }
    void out(unsigned port, uint8_t v, uint64_t gap = 0, bool aen = false) {
        Bus b; b.addr = port; b.dout = v; b.aen = aen;
        for (int i = 0; i < 9; i++) plan.push_back(b);
        b.iow_n = false;
        for (int i = 0; i < 15; i++) plan.push_back(b);
        b.iow_n = true;
        for (int i = 0; i < 3; i++) plan.push_back(b);
        flush();
        run(gap);
    }
    // the 8088 cycles between two I/O instructions
    void cpu(int cycles) { run(uint64_t(cycles) * 6); }
};
