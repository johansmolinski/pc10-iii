// mix_run.cpp - Verilator testbench for rtl/system/pc_audio_mix.sv, the speaker
// plus the Covox (doc/ports.md section 7). A double-precision model of the DC
// blocker (y = x - x' + a y', a = 1 - 2^-10) runs next to it: the output must
// follow it within 1 LSB plus the integer filter's settling. Checks: silence is
// exactly 0 for any resting latch (also from power-up), the speaker's levels
// unchanged (0 / 2000h), no overflow for the worst cases (full-scale steps,
// square waves at many rates, random), the gain at 1 kHz and 5 Hz, the decay to
// exactly 0.
//
// usage: mix_run [test ...]
//
// GPL-3.0-or-later, pc10-iii.

#include "Vpc_audio_mix.h"
#include "bus.h"
#include "verilated.h"

#include <algorithm>
#include <cmath>
#include <random>
#include <string>
#include <vector>

static const int DIV = 600, K = 10;
static const double FS = 28636363.636 / DIV;

struct Sim {
    Vpc_audio_mix *top;
    uint64_t clk = 0;
    int div = 0;
    double yd = 0, x1d = -4096;   // the double model
    double maxdev = 0;
    int amin = 0, amax = 0;
    Sim() { top = new Vpc_audio_mix; top->clk = 0; top->dac = 0; top->speaker = 0; top->eval(); }
    int audio() const { return int16_t(top->audio); }
    void cycle() {
        top->eval();
        int a = audio() - (top->speaker ? 0x2000 : 0);
        amin = std::min(amin, audio()); amax = std::max(amax, audio());
        double dev = std::fabs(a - std::floor(yd));
        maxdev = std::max(maxdev, dev);
        bool tick = div == DIV - 1;
        div = tick ? 0 : div + 1;
        if (tick) {
            double x = (int(top->dac) - 128) * 32.0;
            yd = yd * (1 - std::ldexp(1.0, -K)) + x - x1d;
            x1d = x;
        }
        top->clk = 1; top->eval(); top->clk = 0;
        clk++;
    }
    void run(uint64_t n) { for (uint64_t i = 0; i < n; i++) cycle(); }
    void samples(uint64_t n) { run(n * DIV); }
};

static void t_silence() {
    Sim s;
    bool ok = true;
    for (uint64_t i = 0; i < 200000; i++) { s.cycle(); ok &= s.audio() == 0; }
    CHECK(ok, "power-up (latch 00h): exact silence");
    std::mt19937 rng(3);
    for (int v : {0x0C, 0xE4, 0x80, 0xFF, 0x00, int(rng() & 255), int(rng() & 255)}) {
        s.top->dac = v;
        s.run(14318182);                     // 0.5 s
        bool zero = true;
        for (int i = 0; i < 100000; i++) { s.cycle(); zero &= s.audio() == 0; }
        CHECK(zero, "latch %02X at rest: silence (audio %d)", v, s.audio());
    }
}

static void t_speaker() {
    Sim s;
    s.top->dac = 0x77;
    s.run(28636364);
    bool ok = true;
    for (int i = 0; i < 200000; i++) {
        s.top->speaker = (i / 1000) & 1;
        s.cycle();
        ok &= s.audio() == (s.top->speaker ? 0x2000 : 0);
    }
    CHECK(ok, "the speaker's levels unchanged with the DAC at rest");
}

static void t_range() {
    Sim s;
    s.amin = s.amax = 0;
    // full-scale steps after rest, both ways, with the speaker on and off
    for (int rep = 0; rep < 2; rep++) {
        s.top->speaker = rep; s.top->dac = 0x00; s.samples(30000);
        s.top->dac = 0xFF; s.samples(30000);
        s.top->dac = 0x00; s.samples(30000);
    }
    // square waves of the full range at many rates
    for (int half : {1, 2, 3, 5, 8, 13, 50, 200, 1000, 5000}) {
        for (int i = 0; i < 40; i++) {
            s.top->speaker = (i / 3) & 1;
            s.top->dac = (i & 1) ? 0xFF : 0x00;
            s.samples(half);
        }
    }
    std::mt19937 rng(17);
    for (int i = 0; i < 100000; i++) {
        s.top->dac = rng() & 1 ? 0xFF : rng() & 255;
        s.top->speaker = rng() & 1;
        s.run(1 + rng() % 1500);
    }
    printf("range: %d .. %d, max deviation from the double model %.2f\n", s.amin, s.amax, s.maxdev);
    CHECK(s.amin >= -8192 && s.amax <= 16384, "no overflow: %d .. %d", s.amin, s.amax);
    // the integer decay rounds toward zero (at least one unit): |error| < 2^K units of 2^-F = 4 LSB
    CHECK(s.maxdev < 4.0, "follows the model (%.2f LSB)", s.maxdev);
}

static void t_gain() {
    for (double f : {1000.0, 5.0}) {
        Sim s;
        s.top->dac = 128; s.samples(50000);
        double ph = 0;
        int amax = -100000, amin = 100000;
        int n = int(FS * 3);
        for (int i = 0; i < n; i++) {
            s.top->dac = 128 + int(std::lround(100 * std::sin(ph)));
            ph += 2 * M_PI * f / FS;
            s.samples(1);
            if (i > n * 2 / 3) { amax = std::max(amax, s.audio()); amin = std::min(amin, s.audio()); }
        }
        double g = (amax - amin) / 2.0 / 3200.0;
        double fc = (1 - (1 - std::ldexp(1.0, -K))) * FS / (2 * M_PI);
        double want = (f / fc) / std::sqrt(1 + (f / fc) * (f / fc));
        printf("gain at %.0f Hz: %.3f (first-order high-pass at %.1f Hz: %.3f)\n", f, g, fc, want);
        CHECK(std::fabs(g - want) < 0.03, "gain at %.0f Hz", f);
    }
}

static void t_decay() {
    Sim s;
    s.top->dac = 0xFF;
    s.samples(1);
    int n = 0;
    while (s.audio() != 0 && n < 100000) { s.samples(1); n++; }
    printf("decay: exactly 0 after %d samples (%.2f s)\n", n, n / FS);
    CHECK(n < 30000, "a step decays to exactly 0 (%d samples)", n);
    bool ok = true;
    for (int i = 0; i < 20000; i++) { s.samples(1); ok &= s.audio() == 0; }
    CHECK(ok, "and stays there");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    struct T { const char *n; void (*f)(); } tests[] = {
        {"silence", t_silence}, {"speaker", t_speaker}, {"range", t_range}, {"gain", t_gain}, {"decay", t_decay}};
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
    printf("mix: %d tests, %ld checks, %d failures\n", ran, checks, failures);
    return failures ? 1 : 0;
}
