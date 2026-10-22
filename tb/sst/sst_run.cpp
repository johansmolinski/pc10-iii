// sst_run.cpp - run SingleStepTests 8088 v2 cases against an HDL 8088.
//
//   sst_run [options] XX.txt...
//     -v IDX      print the trace comparison of test IDX (per file)
//     -n N        run only the first N tests of each file
//     -f          stop at the first failing test of each file and print it
//     -r / -m     only tests without / with a memory operand
//     -p          compare only up to the first EU bus cycle's T1 (tuning)
//     -d          dump every cycle with the EU events (debugging)
//
// The CPU gets its registers from a loader program served on the bus (POPF,
// MOV r16,imm, MOV sreg,AX, JMP FAR), the way Arduino8088 sets up the real
// chip, so no backdoor writes are needed. Final registers are read through
// the dbg_* outputs when the next instruction's first byte leaves the queue.
//
// Three verdicts per test:
//   state  registers (undefined flags masked) and memory
//   length number of cycles from the first byte to the next instruction
//   trace  every cycle: ALE, bus status, T-state, address at T1, data at T3,
//          queue operation and byte
// Tests that start with a full queue (half of the suite) cannot be set up
// through the bus; they get the state verdict only.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include "Vtb_mcl86.h"
#include "verilated.h"

enum { AX, BX, CX, DX, CS, SS, DS, ES, SP, BP, SI, DI, IP, FLAGS, NREG };
static const char *REGN[NREG] = {"ax", "bx", "cx", "dx", "cs", "ss", "ds",
                                 "es", "sp", "bp", "si", "di", "ip", "flags"};
static const char *BUSN[8] = {"INTA", "IOR", "IOW", "HALT",
                              "CODE", "MEMR", "MEMW", "PASV"};

struct Cycle {
    int ale = 0;
    unsigned addr = 0;
    int data = 0;
    std::string bus, t, qop;
    int qbyte = 0;
};

struct Test {
    int idx = 0;
    unsigned flagmask = 0xFFFF;
    std::string name;
    std::vector<int> bytes;
    unsigned init[NREG] = {};
    std::vector<std::pair<unsigned, int>> ram;
    std::vector<int> queue;
    unsigned fmask = 0;
    unsigned fin[NREG] = {};
    std::vector<std::pair<unsigned, int>> fram;
    std::vector<Cycle> cycles;
};

static bool read_test(std::istream &in, Test &t) {
    std::string line, tag;
    t = Test();
    while (std::getline(in, line)) {
        std::istringstream s(line);
        s >> tag;
        if (tag == "T") {
            s >> t.idx >> t.flagmask;
            std::getline(s, t.name);
            if (!t.name.empty() && t.name[0] == ' ') t.name.erase(0, 1);
        } else if (tag == "B") {
            int n, v; s >> n;
            while (n-- && s >> v) t.bytes.push_back(v);
        } else if (tag == "I") {
            for (int i = 0; i < NREG; i++) s >> t.init[i];
        } else if (tag == "M" || tag == "W") {
            int n; unsigned a; int v; s >> n;
            auto &dst = tag == "M" ? t.ram : t.fram;
            while (n-- && s >> a >> v) dst.push_back({a, v});
        } else if (tag == "Q") {
            int n, v; s >> n;
            while (n-- && s >> v) t.queue.push_back(v);
        } else if (tag == "F") {
            s >> t.fmask;
            for (int i = 0; i < NREG; i++)
                if (t.fmask & (1u << i)) s >> t.fin[i];
        } else if (tag == "c") {
            Cycle c; int pins, bhe; std::string seg, mem, io;
            s >> pins >> c.addr >> seg >> mem >> io >> bhe >> c.data
              >> c.bus >> c.t >> c.qop >> c.qbyte;
            c.ale = pins & 1;
            t.cycles.push_back(c);
        } else if (tag == "E") {
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------- simulation

struct Sim {
    std::unique_ptr<Vtb_mcl86> top;
    double phase = 0.0;               // 8088 CLK phase in periods
    static constexpr double STEP = 4.7727272 / 100.0;  // per 100 MHz core clock
    uint64_t core_clocks = 0;

    Sim() : top(new Vtb_mcl86) {}

    // One core clock. Returns true when CLK rose (an 8088 cycle boundary).
    bool step() {
        double next = phase + STEP;
        bool rose = (int)next != (int)phase;
        phase = next;
        double frac = phase - (int)phase;
        top->clk = frac < (1.0 / 3.0);
#ifdef BIU88
        top->step = rose;           // biu88 advances at the CLK rising edge
#endif
        top->core_clk = 0; top->eval();
        top->core_clk = 1; top->eval();
        core_clocks++;
        return rose;
    }
};

struct Result {
    bool state_ok = false, len_ok = false, trace_ok = false, ran = false;
    bool prefetched = false;
    int lag = -1;                     // core clocks from the start of the cycle in which the
                                      // BIU read the next opcode to the EU's dispatch on it
    std::string why;
    std::vector<Cycle> got;
    unsigned regs[NREG] = {};
};

static std::vector<uint8_t> loader_program(const Test &t) {
    std::vector<uint8_t> p;
    auto imm = [&](uint8_t op, unsigned v) {
        p.push_back(op); p.push_back(v & 0xFF); p.push_back(v >> 8);
    };
    p.push_back(0x9D);                       // POPF (data served below)
    imm(0xBB, t.init[BX]); imm(0xB9, t.init[CX]); imm(0xBA, t.init[DX]);
    imm(0xBE, t.init[SI]); imm(0xBF, t.init[DI]); imm(0xBD, t.init[BP]);
    imm(0xBC, t.init[SP]);
    imm(0xB8, t.init[ES]); p.push_back(0x8E); p.push_back(0xC0);
    imm(0xB8, t.init[SS]); p.push_back(0x8E); p.push_back(0xD0);
    imm(0xB8, t.init[DS]); p.push_back(0x8E); p.push_back(0xD8);
    imm(0xB8, t.init[AX]);
    p.push_back(0xEA);
    p.push_back(t.init[IP] & 0xFF); p.push_back(t.init[IP] >> 8);
    p.push_back(t.init[CS] & 0xFF); p.push_back(t.init[CS] >> 8);
    return p;
}

static int prefix_count(const Test &t) {
    int n = 0;
    for (int b : t.bytes) {
        if (b == 0x26 || b == 0x2E || b == 0x36 || b == 0x3E ||
            b == 0xF0 || b == 0xF2 || b == 0xF3) n++;
        else break;
    }
    return n;
}

static bool g_dump = false;   // -d: print every bus cycle of the test
static bool g_prefix = false; // -p: compare only up to the first EU bus cycle's T1
static long g_cyc = 0;        // 8088 cycle number (for -d)

static double g_phase = -1.0;   // -P: the CLK phase at each test's start (0 <= p < Sim::STEP
                                // places the 20-core-clock periods, one in ~21)
static int g_sweep = 0;         // -S n: run each test at n phases
static bool g_lag = false;      // -L: dispatch lag (see Result::lag) in -l lines, and per file

static Result run_test(Sim &sim, const Test &t) {
    Result r;
    if (g_phase >= 0.0) sim.phase = (double)(long)sim.phase + g_phase;
    r.prefetched = !t.queue.empty();
    if (g_dump) printf("=== test %d\n", t.idx);
    auto &top = sim.top;

    static std::vector<int> mem(1 << 20);
    std::fill(mem.begin(), mem.end(), 0x90);
    for (auto &m : t.ram) mem[m.first & 0xFFFFF] = m.second;
    std::vector<uint8_t> written_mask(0);
    std::vector<std::pair<unsigned, int>> writes;

    std::vector<uint8_t> loader = loader_program(t);
    uint8_t flagbytes[2] = {(uint8_t)(t.init[FLAGS] & 0xFF),
                            (uint8_t)(t.init[FLAGS] >> 8)};
    size_t lptr = 0; int dptr = 0;
    bool test_mode = false;

    // reset
    top->reset = 1; top->ad_in = 0x90;
    for (int i = 0; i < 64; i++) sim.step();
    top->reset = 0;

    int prev_status = 7, status_core_prev = 7;
    int tcount = 0, bus_type = 7;
    unsigned latched = 0;
    int read_val = 0x90;
    int prev_jump = 0, prev_strobe = 0, prev_dispatch = 0;
    int preload_at = 0;
    int snap_st = 7, snap_qs = 0, snap_qb = 0;
    int code_fetches = 0;
    const int code_bytes = (int)t.bytes.size() - (int)t.queue.size();
    bool cycle_of_test = true;
    unsigned snap_ad = 0;

    // queue events of the current 8088 cycle (reported in the next one)
    struct QEv { char op; int byte; };
    std::vector<QEv> qev_cur, qev_prev;

    const int want_f = prefix_count(t) + 1;
    int f_seen = 0;
    bool started = false, done = false;
    int cycle_no = 0;
    long budget = 400000;  // 8088 cycles for one test, generous for REP

    // MCL86 can start the next instruction while a write is still queued in
    // the BIU; let the bus drain so that the state verdict sees the memory
    int drain = 40;
#ifdef BIU88
    bool tstarted = false, tdone = false;
    int tf_seen = 0;
    uint64_t cyc_start = 0, cyc_start_prev = 0, read_start = 0, disp_core = 0;
#else
    const bool tdone = true;
#endif
    while ((!done || !tdone || drain-- > 0) && budget-- > 0) {
        const bool was_done = done;   // the cycle that ends the test is kept
        // run core clocks until the next CLK rising edge
        bool rose = false;
        while (!rose) {
            // the pins as they were during the cycle that is ending: biu88
            // changes them on the very clock where CLK rises
            snap_st = top->s2_s0; snap_ad = top->ad_out;
#ifdef BIU88
            snap_qs = top->qs; snap_qb = top->qs_byte;
#endif
            rose = sim.step();
            if (rose) g_cyc++;
#ifdef BIU88
            if (rose) { cyc_start_prev = cyc_start; cyc_start = sim.core_clocks; }
#endif
#ifdef BIU88
            if (g_dump && top->qs != snap_qs)
                printf("      qs c%ld%s %d -> %d\n", g_cyc, rose ? "(edge)" : "", snap_qs, (int)top->qs);
#endif
            int st = top->s2_s0;
            // the 8288 latches the address when the status leaves passive
            if (status_core_prev == 7 && st != 7) {
                latched = top->ad_out & 0xFFFFF;
                bus_type = st;
                // a bus cycle that starts after the EU dispatched the next
                // instruction is not the test's (the drain runs the code after
                // it, which the test may have just overwritten)
                cycle_of_test = !done;
                if (st == 4) {                       // code fetch
                    if (!test_mode)
                        read_val = lptr < loader.size() ? loader[lptr++] : 0x90;
                    else
                        // like the suite's generator: the instruction's own
                        // bytes (those not prefetched), then NOPs, whatever
                        // the address (a jump may land on its own bytes)
                        read_val = code_fetches++ < code_bytes ? mem[latched] : 0x90;
                } else if (st == 5) {                // memory read
                    read_val = test_mode ? mem[latched]
                                         : flagbytes[dptr++ & 1];
                } else if (st == 1) {                // I/O read
                    read_val = 0xFF;
                } else {
                    read_val = 0xFF;
                }
                top->ad_in = read_val;
            }
            status_core_prev = st;

            unsigned cmd = top->dbg_eu_cmd;
            int jump = ((cmd >> 9) & 1) && (((cmd >> 4) & 0x1F) == 0x19);
#ifdef BIU88
            // install the prefetched queue once the loader's JMP FAR has
            // flushed (preload_at counted down) and the EU waits in its main
            // loop (0x0006-0x000C): the test then starts from an idle CPU, as
            // the suite's generator starts it
            top->tb_preload = 0;
            if (preload_at > 1) preload_at--;
            else if (preload_at == 1 && top->dbg_rom_addr >= 0x0006 && top->dbg_rom_addr <= 0x000C) {
                top->tb_preload = 1;
                preload_at = 0;
            }
#endif
            if (jump && !prev_jump) {
                if (!test_mode && lptr >= loader.size()) {
                    test_mode = true;
#ifdef BIU88
                    // the BIU flushes on the next clock; install the queue
                    // right after that
                    if (!t.queue.empty()) {
                        uint32_t qw = 0;
                        for (size_t i = 0; i < t.queue.size() && i < 4; i++)
                            qw |= (uint32_t)t.queue[i] << (8 * i);
                        top->tb_queue = qw;
                        top->tb_queue_len = t.queue.size();
                        top->tb_ip = t.init[IP];
                        preload_at = 2;
                    }
#endif
                }
                if (test_mode && started) qev_cur.push_back({'E', 0});
            }
            prev_jump = jump;

            // MCL86 dispatches on the opcode at the top of the queue and
            // removes it only at the end of the instruction (strobe with QS
            // code 01). The dispatch is the real chip's first-byte read; the
            // strobes with QS code 11 are subsequent-byte reads.
            int strobe = ((cmd >> 12) & 3) == 1;
            int dispatch = top->dbg_dispatch;
#ifdef BIU88
            // SST_UC=1 with -d: every microcode address the EU visits
            static const bool uc_trace = getenv("SST_UC") != nullptr;
            static unsigned prev_uc = ~0u;
            if (g_dump && uc_trace && test_mode && top->dbg_rom_addr != prev_uc)
                printf("      uc c%ld %04X\n", g_cyc, (unsigned)top->dbg_rom_addr);
            prev_uc = top->dbg_rom_addr;
            if (g_dump && ((dispatch && !prev_dispatch) || (strobe && !prev_strobe) ||
                           (jump && !prev_jump)))
                printf("      ev c%ld%s rom=%03X cmd=%04X top=%02X empty=%d hold=%d qlen=%d pc=%04X %s%s%s\n",
                       g_cyc, rose ? "(edge)" : "", (unsigned)top->dbg_rom_addr, cmd, (unsigned)top->dbg_pfq_top,
                       (int)top->dbg_pfq_empty, (int)top->dbg_holding, (int)top->dbg_qlen,
                       (unsigned)top->dbg_pc, dispatch && !prev_dispatch ? "DISPATCH " : "",
                       strobe && !prev_strobe ? "STROBE " : "", jump && !prev_jump ? "JUMP" : "");
#endif
            // a REP iteration re-dispatches the same opcode through MCL86's
            // main loop; the microcode marks those with flag bit 1
            if (dispatch && !prev_dispatch && test_mode && !(top->dbg_flags & 2)) {
                int byte = top->dbg_pfq_top;
                if (g_dump) printf("    dispatch top=%02X\n", byte);
                if (done) {
                    // draining: the next instructions are NOPs
                } else if (!started) {
                    started = true; f_seen = 1;
                    qev_cur.push_back({'F', byte});
                } else if (++f_seen > want_f) {
                    // first byte of the next instruction: the test ends
                    r.regs[AX] = top->dbg_ax; r.regs[BX] = top->dbg_bx;
                    r.regs[CX] = top->dbg_cx; r.regs[DX] = top->dbg_dx;
                    r.regs[CS] = top->dbg_cs; r.regs[SS] = top->dbg_ss;
                    r.regs[DS] = top->dbg_ds; r.regs[ES] = top->dbg_es;
                    r.regs[SP] = top->dbg_sp; r.regs[BP] = top->dbg_bp;
                    r.regs[SI] = top->dbg_si; r.regs[DI] = top->dbg_di;
                    r.regs[IP] = top->dbg_ip;
                    // MCL86 keeps prefix state in flags 15..12, 5, 3, 1
                    r.regs[FLAGS] = (top->dbg_flags & 0x0FD5) | 0xF002;
                    done = true;
#ifdef BIU88
                    disp_core = sim.core_clocks;
#endif
                } else {
                    qev_cur.push_back({'F', byte});
                }
            }
            prev_dispatch = dispatch;
            if (strobe && !prev_strobe && test_mode && started && !done) {
                int qs = (cmd >> 2) & 3;
                if (g_dump) printf("    strobe cmd=%04X top=%02X\n", cmd, (unsigned)top->dbg_pfq_top);
                if (qs == 3) qev_cur.push_back({'S', (int)top->dbg_pfq_top});
            }
            prev_strobe = strobe;
        }

        // close the 8088 cycle that just ended
        int st = snap_st;
        Cycle c;
        if (prev_status == 7 && st != 7) {
            tcount = 1; c.ale = 1; c.addr = latched;
        } else if (tcount >= 1 && tcount < 4) {
            tcount++;
        } else {
            tcount = 0;
        }
        c.t = tcount == 0 ? "Ti" : "T" + std::to_string(tcount);
        c.bus = BUSN[st];
        if (tcount == 3) {
            if (bus_type == 6 || bus_type == 2) {        // write
                c.data = snap_ad & 0xFF;
                if (bus_type == 6 && test_mode && started && cycle_of_test) {
                    mem[latched] = c.data;
                    writes.push_back({latched, c.data});
                }
            } else if (bus_type != 7) {
                c.data = read_val;
            }
        }
        prev_status = st;
        if (g_dump)
            printf("    dump c%ld %s %-4s %c%05X d=%02X q=%s ip=%04X sp=%04X ss=%04X%s\n",
                   g_cyc - 1, c.t.c_str(), c.bus.c_str(), c.ale ? 'A' : ' ', latched,
                   c.data, c.qop.c_str(),
                   (unsigned)top->dbg_ip, (unsigned)top->dbg_sp,
                   (unsigned)top->dbg_ss, done ? " (drain)" : !test_mode ? " (load)" : "");
#ifdef BIU88
        if (g_dump && test_mode)
            printf("         ta=%u ql=%u cmd=%04X\n", (unsigned)top->dbg_ta_state,
                   (unsigned)top->dbg_queue_len, (unsigned)top->dbg_eu_cmd);
#endif

#ifdef BIU88
        {
            static const char *QSN[4] = {"-", "F", "E", "S"};
            c.qop = QSN[snap_qs & 3];
            c.qbyte = snap_qs ? snap_qb : 0;
        }
#else
        if (started && !qev_prev.empty()) {
            c.qop = std::string(1, qev_prev[0].op);
            c.qbyte = qev_prev[0].byte;
        } else {
            c.qop = "-";
        }
#endif
#ifdef BIU88
        // the trace window comes from the QS pins: from the cycle that reports
        // the test's first byte (F) up to the cycle before the F of the next
        // instruction. The BIU may read that opcode before the EU dispatches
        // on it; the registers are taken at the EU's dispatch (above).
        if (!tdone && test_mode) {
            if (!tstarted) {
                if (c.qop == "F") { tstarted = true; tf_seen = 1; r.got.push_back(c); }
            } else {
                if (c.qop == "F" && ++tf_seen > want_f) {
                    tdone = true;
                    read_start = cyc_start_prev;   // the read was in the cycle before the F
                }
                else r.got.push_back(c);
            }
        }
        (void)was_done;
#else
        if (started && !was_done) {
            // a cycle belongs to the test from the one reporting the first F
            if (cycle_no > 0 || !qev_prev.empty()) {
                r.got.push_back(c);
                cycle_no++;
            }
        }
#endif
        qev_prev = qev_cur;
        qev_cur.clear();
    }

    r.ran = done;
    if (!done) { r.why = "timeout"; return r; }
#ifdef BIU88
    if (tdone) r.lag = (int)((long)disp_core - (long)read_start);
#endif

    // the cycle in which the next first byte left the queue belongs to the test
    // (its F would be reported one cycle later); it was pushed above already

    // state verdict
    std::string why;
    for (int i = 0; i < NREG; i++) {
        unsigned want = (t.fmask & (1u << i)) ? t.fin[i] : t.init[i];
        unsigned got = r.regs[i];
        if (i == FLAGS) { want &= t.flagmask; got &= t.flagmask; }
        if (want != got) {
            char b[96];
            snprintf(b, sizeof b, "%s=%04X want %04X ", REGN[i], got, want);
            why += b;
        }
    }
    for (auto &w : t.fram) {
        if (mem[w.first & 0xFFFFF] != w.second) {
            char b[96];
            snprintf(b, sizeof b, "[%05X]=%02X want %02X ", w.first,
                     mem[w.first & 0xFFFFF], w.second);
            why += b;
        }
    }
    for (auto &w : writes) {
        bool expected = false;
        for (auto &f : t.fram) expected |= (f.first & 0xFFFFF) == w.first;
        bool unchanged = false;
        for (auto &m : t.ram)
            if ((m.first & 0xFFFFF) == w.first && m.second == w.second) unchanged = true;
        if (!expected && !unchanged) {
            char b[96];
            snprintf(b, sizeof b, "stray write [%05X]=%02X ", w.first, w.second);
            why += b;
        }
    }
    r.state_ok = why.empty();
    r.why = why;

#ifdef BIU88
    const bool graded = true;          // the queue was installed
#else
    const bool graded = !r.prefetched;
#endif
    if (graded) {
        r.len_ok = r.got.size() == t.cycles.size();
        bool ok = r.len_ok;
        size_t upto = t.cycles.size();
        if (g_prefix) {
            // tuning aid: only the cycles up to the first non-code T1
            for (size_t i = 0; i < t.cycles.size(); i++)
                if (t.cycles[i].ale && t.cycles[i].bus != "CODE") { upto = i + 1; break; }
            ok = r.got.size() >= upto;
        }
        for (size_t i = 0; ok && i < upto; i++) {
            const Cycle &a = t.cycles[i], &b = r.got[i];
            if (a.ale != b.ale || a.bus != b.bus || a.t != b.t || a.qop != b.qop)
                ok = false;
            if (a.ale && a.addr != b.addr) ok = false;
            if (a.t == "T3" && a.data != b.data) ok = false;
            if (a.qop != "-" && a.qbyte != b.qbyte) ok = false;
        }
        r.trace_ok = ok;
    }
    return r;
}

static void print_trace(const Test &t, const Result &r) {
    printf("  test %d \"%s\" bytes", t.idx, t.name.c_str());
    for (int b : t.bytes) printf(" %02X", b);
    printf("%s\n", r.prefetched ? " (prefetched)" : "");
    if (!r.why.empty()) printf("  state: %s\n", r.why.c_str());
    size_t n = std::max(t.cycles.size(), r.got.size());
    printf("  %-34s | %s\n", "want", "got");
    for (size_t i = 0; i < n; i++) {
        char a[64] = "", b[64] = "";
        if (i < t.cycles.size()) {
            const Cycle &c = t.cycles[i];
            snprintf(a, sizeof a, "%c %05X %-4s %-2s %s %02X %s", c.ale ? 'A' : ' ',
                     c.ale ? c.addr : 0, c.bus.c_str(), c.t.c_str(),
                     c.qop.c_str(), c.qbyte, c.t == "T3" ? (std::to_string(c.data)).c_str() : "");
        }
        if (i < r.got.size()) {
            const Cycle &c = r.got[i];
            snprintf(b, sizeof b, "%c %05X %-4s %-2s %s %02X %s", c.ale ? 'A' : ' ',
                     c.ale ? c.addr : 0, c.bus.c_str(), c.t.c_str(),
                     c.qop.c_str(), c.qbyte, c.t == "T3" ? (std::to_string(c.data)).c_str() : "");
        }
        bool same = strcmp(a, b) == 0;
        printf("  %3zu %-30s %s %s\n", i, a, same ? "|" : "#", b);
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    int verbose_idx = -1, limit = -1;
    bool first_fail = false, only_reg = false, only_mem = false, list = false;
    std::vector<std::string> files;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-v") && i + 1 < argc) verbose_idx = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-n") && i + 1 < argc) limit = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-f")) first_fail = true;
        else if (!strcmp(argv[i], "-l")) list = true;   // one line per test
        else if (!strcmp(argv[i], "-d")) g_dump = true;
        else if (!strcmp(argv[i], "-r")) only_reg = true;
        else if (!strcmp(argv[i], "-p")) g_prefix = true;
        else if (!strcmp(argv[i], "-m")) only_mem = true;
        else if (!strcmp(argv[i], "-P") && i + 1 < argc) g_phase = atof(argv[++i]);
        else if (!strcmp(argv[i], "-S") && i + 1 < argc) g_sweep = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-L")) g_lag = true;
        else if (argv[i][0] != '+') files.push_back(argv[i]);
    }
    Sim sim;
    printf("%-10s %6s %6s %6s %6s %6s %6s\n", "file", "tests", "state",
           "plain", "length", "trace", "tmout");
    for (auto &fn : files) {
        std::ifstream in(fn);
        if (!in) { fprintf(stderr, "cannot open %s\n", fn.c_str()); return 1; }
        Test t;
        int n = 0, st = 0, plain = 0, len = 0, tr = 0, tmo = 0;
        int lag_max = -1, lag1 = 0, lag2 = 0;
        bool shown = false;
        while (read_test(in, t)) {
            if (limit >= 0 && n >= limit) break;
            // -r / -m: only tests without / with a memory operand
            bool mem = t.name.find('[') != std::string::npos;
            if ((only_reg && mem) || (only_mem && !mem)) continue;
            Result r;
            int sweep_ok = 0;
            if (g_sweep > 0) {
                // the test at g_sweep CLK phases: it passes only if it passes at all
                bool all_st = true, all_tr = true;
                for (int k = 0; k < g_sweep; k++) {
                    g_phase = Sim::STEP * k / g_sweep;   // the 20-clock periods move
                    r = run_test(sim, t);
                    all_st = all_st && r.state_ok;
                    all_tr = all_tr && r.trace_ok;
                    if (r.state_ok && r.trace_ok) sweep_ok++;
                }
                r.state_ok = all_st; r.trace_ok = all_tr;
            } else
                r = run_test(sim, t);
            n++;
            if (!r.ran) tmo++;
            if (r.lag > lag_max) lag_max = r.lag;
            if (r.lag > 21) lag1++;
            if (r.lag > 42) lag2++;
            if (r.state_ok) st++;
#ifdef BIU88
            if (true) {
#else
            if (!r.prefetched) {
#endif
                plain++;
                if (r.len_ok) len++;
                if (r.trace_ok) tr++;
            }
            bool fail = !r.state_ok || !r.trace_ok;
            if (list) {
                if (g_sweep > 0) printf("%3d/%-3d", sweep_ok, g_sweep);
                printf("%5d %c%c q%zu c%-3zu %-24s", t.idx, r.state_ok ? 's' : 'S', r.trace_ok ? 't' : 'T',
                       t.queue.size(), t.cycles.size(), t.name.c_str());
                for (int b : t.bytes) printf(" %02X", b);
                if (g_lag) printf("  L%d", r.lag);
                printf("\n");
            }
            if (t.idx == verbose_idx || (first_fail && fail && !shown)) {
                print_trace(t, r);
                shown = true;
            }
        }
        std::string base = fn.substr(fn.find_last_of('/') + 1);
        base = base.substr(0, base.rfind(".txt"));
        printf("%-10s %6d %6d %6d %6d %6d %6d\n", base.c_str(), n, st, plain,
               len, tr, tmo);
        if (g_lag)
            printf("lag %-6s max %4d  >1 cycle %6d  >2 cycles %6d\n", base.c_str(), lag_max, lag1, lag2);
        fflush(stdout);
    }
    return 0;
}
