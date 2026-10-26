// wait_run.cpp - unit bench of the wait-state generator (rtl/system/xt_wait.sv,
// doc/turbo.md section 6). A model of biu88's bus cycles (T1 T2 T3 Tw.. T4,
// "is this T3/Tw the last" decided by READY at the step that starts it) runs
// random cycles (types, on-board or not, speed, 63h bits 6-5) against random
// IOCHRDY and DMA waits (both as the 8284's samples on rdy_ce) and checks:
//   - ws_n at T2 = the FE2010A table (doc/turbo.md section 3);
//   - every state after T2 is the last exactly when RDY was high at the step
//     that started it and the board's wait states are used up, where a state
//     counts only if the DMA wait did not hold it;
//   - at 4.77 MHz READY equals the logic of 2026-10-22 in every clk.
//
//   wait_run [cycles] [seed]      exit status 0 = PASS
//
// GPL-3.0-or-later, pc10-iii.

#include "Vtb_wait.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <random>

enum { TI = 0, T1 = 1, T2 = 2, T3 = 3, TW = 4, T4 = 5 };
enum { ST_INTA = 0, ST_IOR = 1, ST_IOW = 2, ST_HALT = 3, ST_CODE = 4, ST_MEMR = 5, ST_MEMW = 6, ST_PASV = 7 };
static const int PER[3] = {6, 4, 3};

static int fails = 0;
static unsigned long long t = 0;
#define CHECK(c, ...) do { if (!(c)) { if (fails++ < 20) { printf("FAIL t=%llu: ", t); printf(__VA_ARGS__); printf("\n"); } } } while (0)

// the table (Kiselev, 2023-02-01)
static int table(int type, bool onboard, int spd, int cfg6, int cfg5) {
    bool io = type == ST_IOR || type == ST_IOW;
    bool mem = type == ST_CODE || type == ST_MEMR || type == ST_MEMW;
    if (io) return spd == 0 ? 1 : spd == 1 ? 4 : cfg6 ? 4 : 6;
    if (mem && !onboard && !cfg5) return spd == 0 ? 0 : spd == 1 ? 2 : cfg6 ? 2 : 4;
    return 0;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    long cycles = argc > 1 ? atol(argv[1]) : 400000;
    unsigned seed = argc > 2 ? atoi(argv[2]) : 1;
    std::mt19937 rng(seed);
    std::unique_ptr<Vtb_wait> top(new Vtb_wait);
    auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); t++; };

    top->reset = 1; top->cpu_step = 0; top->cpu_bus_t = TI; top->cpu_bus_type = ST_PASV;
    top->rdy_sync = 1; top->dma_rdy_sync = 1; top->spd = 0; top->cfg = 0; top->onboard = 1;
    for (int i = 0; i < 4; i++) tick();
    top->reset = 0;

    int spd = 0, sub = 0;
    int st = TI, type = ST_PASV;
    bool last = false;              // the running T3/Tw is the last
    int n = 0, counted = 0;         // the cycle's wait states, states that counted
    bool dma_ok_prev = true;        // the DMA part of the sample that started the running state
    long done = 0;
    long hist[3][8] = {};
    int dma_run = 0, rdy_run = 0;
    bool ref_mode = true;           // phases of the run at 4.77 MHz only (the old logic)
    long ws_seen[8] = {};

    while (done < cycles) {
        // the 8284's samples change in the rdy_ce clk (one before the step)
        bool rdy_ce = sub == PER[spd] - 1;
        if (rdy_ce) {
            if (dma_run > 0) dma_run--;
            else if (rng() % 12 == 0) dma_run = 1 + rng() % 7;
            if (rdy_run > 0) rdy_run--;
            else if (rng() % 10 == 0) rdy_run = 1 + rng() % 5;
            top->dma_rdy_sync = dma_run == 0;
            top->rdy_sync = dma_run == 0 && rdy_run == 0;
        }
        bool step = sub == 0;
        top->cpu_step = step;
        top->eval();
        if (ref_mode) CHECK(top->cpu_ready == top->ref_ready, "READY %d, the old logic %d (state %d type %d)",
                            top->cpu_ready, top->ref_ready, st, type);
        if (step) {
            bool rdy = top->cpu_ready;
            // the check of the state that this step decides
            if (st == T2 || st == T3 || st == TW) {
                // the state that starts now (T3 or a Tw) is the last when RDY is
                // high and the wait states are used up
                bool dma_ok = top->dma_rdy_sync;
                if (st != T2 && dma_ok_prev) counted++;
                bool forced = n - counted > 0;
                if (st == T2) {
                    CHECK(top->ws_n == n, "ws_n %d, the table %d (type %d spd %d cfg %d)", top->ws_n, n, type, spd, top->cfg);
                    ws_seen[top->ws_n & 7]++;
                }
                bool exp = top->rdy_sync && !forced;
                if (st == T2 || !last) CHECK(rdy == exp, "READY %d, expected %d (state %d, n %d, counted %d, rdy %d)",
                                            rdy, exp, st, n, counted, top->rdy_sync);
                dma_ok_prev = dma_ok;
            }
            // biu88's T-states
            int nst = st;
            switch (st) {
                case TI: case T4: {
                    // a new cycle or idle
                    if (rng() % 6 == 0) { nst = TI; type = ST_PASV; break; }
                    // speed changes only between cycles here (pc_clocks switches
                    // at any CPU clock boundary; the count does not depend on it)
                    if (!ref_mode && rng() % 8 == 0) spd = rng() % 3;
                    static const int types[] = {ST_INTA, ST_IOR, ST_IOW, ST_HALT, ST_CODE, ST_MEMR, ST_MEMW};
                    type = types[rng() % 7];
                    top->onboard = rng() % 3 != 0;
                    top->cfg = ref_mode ? 0 : rng() % 4;
                    n = table(type, top->onboard, spd, top->cfg >> 1 & 1, top->cfg & 1);
                    counted = 0;
                    nst = T1;
                    break;
                }
                case T1: nst = T2; break;
                case T2: nst = T3; last = rdy; break;
                case T3: case TW:
                    if (last) {
                        nst = T4; done++;
                        hist[spd][n]++;
                    } else { nst = TW; last = rdy; }
                    break;
            }
            st = nst;
            if (done == cycles / 4) ref_mode = false;
        }
        tick();
        top->cpu_step = 0;
        // biu88 changes its outputs at the step's clock edge
        if (step) { top->cpu_bus_t = st; top->cpu_bus_type = (st == TI) ? ST_PASV : type; top->spd = spd; }
        sub = (sub + 1) % PER[spd];     // (a new speed starts its period at a step)
    }
    printf("cycles %ld; wait-state counts at T2:", done);
    for (int i = 0; i < 8; i++) if (ws_seen[i]) printf(" %d:%ld", i, ws_seen[i]);
    printf("\n");
    for (int i = 0; i < 8; i++) if (!(i == 3 || i == 5 || i == 7)) CHECK(ws_seen[i] > 0, "no cycle with %d wait states", i);
    printf("%s (%d failures)\n", fails ? "FAIL" : "PASS", fails);
    return fails ? 1 : 0;
}
