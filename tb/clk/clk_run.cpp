// clk_run.cpp - unit bench of the clock enables with the turbo divider
// (rtl/system/pc_clocks.sv, doc/turbo.md section 4).
//
//   clk_run ref      speed 0 only (with random resets): every enable equals
//                    the /6-only reference (tb_clk.sv) in every clk, ce_477 =
//                    cpu_step
//   clk_run fixed    each speed (0-3) held from reset: the period, the falling
//                    edge, rdy_ce/cpu_prestep, the phase to PCLK, the fixed enables
//   clk_run switch   random speed requests (2M clk): a speed changes only where
//                    every period starts (PCLK phase 0 or 12), within 13 clk of a
//                    stable request; every CPU clock has the length and the
//                    edges of the speed it started at; OSC, PCLK and ce_477 never
//                    move; at speed 0 everything equals the reference
//
// Exit status 0 = PASS. GPL-3.0-or-later, pc10-iii.

#include "Vtb_clk.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { if (fails++ < 20) { printf("FAIL t=%llu: ", (unsigned long long)t); printf(__VA_ARGS__); printf("\n"); } } } while (0)

static const int PER[4]  = {6, 4, 3, 3};
static const int FALL[4] = {2, 2, 1, 1};
static int map_speed(int s) { return s == 3 ? 2 : s; }

struct Bench {
    std::unique_ptr<Vtb_clk> top{new Vtb_clk};
    unsigned long long t = 0;
    void tick() {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
        t++;
    }
    void do_reset(int n = 4) {
        top->reset = 1;
        for (int i = 0; i < n; i++) tick();
        top->reset = 0;
    }
};

// the checks that hold at every speed and in every clk
struct Tracker {
    unsigned long long t = 0;
    long long last_pclk = -1, last_step = -1;
    int cur_spd = -1;                   // the speed of the running CPU clock
    int seen_fall = 0, seen_rdy = 0, seen_pre = 0;
    long long fall_at = -1, rdy_at = -1;
    bool started = false;

    void clk(Vtb_clk *top, unsigned long long now) {
        t = now;
        // fixed enables: the reference's, whatever the speed
        CHECK(top->ce_14m == top->r_ce_14m, "ce_14m %d ref %d", top->ce_14m, top->r_ce_14m);
        CHECK(top->ce_pclk == top->r_ce_pclk, "ce_pclk differs");
        CHECK(top->pit_clk == top->r_pit_clk, "pit_clk differs");
        CHECK(top->ce_477 == top->r_cpu_step, "ce_477 is not the fixed 4.77 MHz step");
        if (top->ce_pclk) last_pclk = (long long)now;
        if (last_pclk < 0) return;
        long long ph = (long long)now - last_pclk;      // 0..23
        if (top->cpu_step) {
            if (started) {
                long long len = (long long)now - last_step;
                CHECK(len == PER[cur_spd], "CPU clock of %lld clk at speed %d", len, cur_spd);
                CHECK(seen_fall == 1 && fall_at == last_step + FALL[cur_spd],
                      "falling edge %d times, at +%lld (speed %d)", seen_fall, fall_at - last_step, cur_spd);
                CHECK(seen_rdy == 1 && rdy_at == (long long)now - 1, "rdy_ce %d times, at -%lld", seen_rdy, (long long)now - rdy_at);
                CHECK(seen_pre == 1, "cpu_prestep %d times", seen_pre);
            }
            if (started && top->spd != cur_spd)
                CHECK(ph % 12 == 0, "speed %d -> %d at PCLK phase %lld", cur_spd, top->spd, ph);
            CHECK(ph % PER[top->spd] == 0, "step at PCLK phase %lld at speed %d", ph, top->spd);
            cur_spd = top->spd;
            started = true;
            last_step = (long long)now;
            seen_fall = seen_rdy = seen_pre = 0;
        } else if (started) {
            CHECK(top->spd == cur_spd, "speed changed between steps");
        }
        if (top->cpu_fall) { seen_fall++; fall_at = (long long)now; CHECK(!top->cpu_step, "fall with step"); }
        if (top->rdy_ce)   { seen_rdy++; rdy_at = (long long)now; CHECK(!top->cpu_fall && !top->cpu_step, "rdy_ce with fall/step"); }
        if (top->cpu_prestep) { seen_pre++; CHECK(top->rdy_ce, "cpu_prestep without rdy_ce"); }
        if (top->ce_14m) CHECK(ph % 2 == 0, "OSC at odd PCLK phase");
        if (top->spd == 0) {
            CHECK(top->cpu_step == top->r_cpu_step && top->cpu_fall == top->r_cpu_fall &&
                  top->rdy_ce == top->r_rdy_ce && top->cpu_prestep == top->r_cpu_prestep,
                  "speed 0 differs from the reference (step %d/%d fall %d/%d rdy %d/%d pre %d/%d)",
                  top->cpu_step, top->r_cpu_step, top->cpu_fall, top->r_cpu_fall,
                  top->rdy_ce, top->r_rdy_ce, top->cpu_prestep, top->r_cpu_prestep);
        }
    }
    void reset() { started = false; last_step = -1; last_pclk = -1; }
};

static int test_ref() {
    Bench b; Tracker tr;
    std::mt19937 rng(1);
    b.top->speed = 0;
    b.do_reset();
    for (int i = 0; i < 300000; i++) {
        if (rng() % 50000 == 0) { b.top->reset = 1; tr.reset(); }
        else b.top->reset = 0;
        b.tick();
        unsigned long long t = b.t;
        if (!b.top->reset) {
            CHECK(b.top->spd == 0, "speed %d with request 0", b.top->spd);
            CHECK(b.top->cpu_step == b.top->r_cpu_step && b.top->cpu_fall == b.top->r_cpu_fall &&
                  b.top->rdy_ce == b.top->r_rdy_ce && b.top->cpu_prestep == b.top->r_cpu_prestep &&
                  b.top->ce_14m == b.top->r_ce_14m && b.top->ce_pclk == b.top->r_ce_pclk &&
                  b.top->pit_clk == b.top->r_pit_clk && b.top->ce_477 == b.top->r_cpu_step,
                  "an enable differs from the reference");
            tr.clk(b.top.get(), b.t);
        }
    }
    return fails;
}

static int test_fixed() {
    for (int s = 0; s < 4; s++) {
        Bench b; Tracker tr;
        b.top->speed = s;
        b.do_reset();
        unsigned long long t = b.t, t_rst = b.t;
        CHECK(b.top->spd == 0, "speed %d in the clk after reset", b.top->spd);
        unsigned long long t_ok = 0;
        int steps = 0, pclks = 0;
        for (int i = 0; i < 24000; i++) {
            b.tick();
            t = b.t;
            tr.clk(b.top.get(), b.t);
            if (b.top->spd == map_speed(s) && !t_ok) t_ok = b.t;
            if (t_ok && b.top->cpu_step) steps++;
            if (t_ok && b.top->ce_pclk) pclks++;
        }
        CHECK(t_ok && t_ok - t_rst <= 13, "speed %d reached %llu clk after reset", s, t_ok - t_rst);
        CHECK(b.top->spd == map_speed(s), "speed %d runs as %d", s, b.top->spd);
        // CPU clocks per PCLK/2 tick (1.19318 MHz): 4, 6, 8
        double r = (double)steps / pclks;
        CHECK(r > 24.0 / PER[s] - 0.01 && r < 24.0 / PER[s] + 0.01, "speed %d: %.3f CPU clocks per PCLK", s, r);
        printf("speed %d: %d CPU clocks in %d PCLK ticks (%.3f per tick, %.4f MHz)\n", s, steps, pclks, r,
               r * 28.63636364 / 24);
    }
    return fails;
}

static int test_switch() {
    Bench b; Tracker tr;
    std::mt19937 rng(7);
    b.top->speed = 0;
    b.do_reset();
    int req = 0, hold = 0;
    long long req_since = 0;
    int changes = 0, prev_spd = 0;
    int hist[4] = {0, 0, 0, 0};
    for (int i = 0; i < 2000000; i++) {
        if (hold-- <= 0) {
            int n = rng() % 4;
            if (map_speed(n) != map_speed(req)) req_since = (long long)b.t;
            req = n;
            int k = rng() % 8;
            hold = k == 0 ? 1 + rng() % 3 : k < 4 ? 1 + rng() % 30 : 20 + rng() % 400;
        }
        // an occasional reset (the request returns to 0 with it, as 63h does)
        if (rng() % 300000 == 0) {
            req = 0; req_since = (long long)b.t; b.top->speed = 0;
            b.do_reset();
            tr.reset();
            unsigned long long t = b.t;
            CHECK(b.top->spd == 0, "speed %d after reset", b.top->spd);
            prev_spd = 0;
            continue;
        }
        b.top->speed = req;
        b.tick();
        unsigned long long t = b.t;
        tr.clk(b.top.get(), b.t);
        hist[b.top->spd]++;
        if (b.top->spd != prev_spd) changes++;
        prev_spd = b.top->spd;
        if ((long long)b.t - req_since > 13)
            CHECK(b.top->spd == map_speed(req), "request %d stable for %lld clk, speed %d", req,
                  (long long)b.t - req_since, b.top->spd);
    }
    printf("switch: %d speed changes; clk at 4.77/7.16/9.54: %d %d %d\n", changes, hist[0], hist[1], hist[2]);
    unsigned long long t = b.t;
    CHECK(changes > 5000 && hist[0] && hist[1] && hist[2], "too few changes");
    return fails;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: clk_run ref|fixed|switch\n"); return 2; }
    int f;
    if (!strcmp(argv[1], "ref")) f = test_ref();
    else if (!strcmp(argv[1], "fixed")) f = test_fixed();
    else if (!strcmp(argv[1], "switch")) f = test_switch();
    else { fprintf(stderr, "unknown test %s\n", argv[1]); return 2; }
    printf("%s: %s (%d failures)\n", argv[1], f ? "FAIL" : "PASS", f);
    return f ? 1 : 0;
}
