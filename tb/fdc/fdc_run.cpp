// fdc_run.cpp - Verilator testbench for rtl/fdc/fdc_card.sv.
//
// Drives the card bus the way the 5160 does (CPU I/O cycles, an 8237-like
// single-transfer DMA model on channel 2), serves the sector port from
// in-memory disk images and checks data, result bytes and timing.
//
//   ./obj/fdc_run [-v] [-s seed] [-o dir]
//     -o dir: write the final images there (default ~/pcxt-work/fdc)
//
// GPL-3.0-or-later, pc10-iii.

#include "Vfdc_card.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <random>
#include <set>
#include <string>
#include <vector>

static const double CLK_HZ = 28636363.64;        // 315/11 MHz (6 clk per CPU clock)
static const int C = 6;                           // clk per 4.77 MHz CPU clock
static uint64_t us2clk(double us) { return (uint64_t)(us * CLK_HZ / 1e6 + 0.5); }
static double clk2us(uint64_t c) { return c * 1e6 / CLK_HZ; }

static int fails = 0, checks = 0;
static bool verbose = false;

#define CHECK(cond, ...) do { checks++; if (!(cond)) { fails++; \
    printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// ------------------------------------------------------------ disk images
struct Image {
    std::vector<uint8_t> d;
    int tracks = 0, heads = 0, spt = 0;
    bool present = false, wp = false;
    void make(int t, int h, int s, uint32_t salt) {
        tracks = t; heads = h; spt = s; present = true; wp = false;
        d.assign((size_t)t * h * s * 512, 0);
        for (size_t i = 0; i < d.size(); i++) {
            uint32_t x = (uint32_t)i * 2654435761u ^ salt;
            x ^= x >> 13; x *= 0x5bd1e995u; x ^= x >> 15;
            d[i] = (uint8_t)x;
        }
    }
    int lba(int c, int h, int r) const { return (c * heads + h) * spt + r - 1; }
    const uint8_t *sec(int c, int h, int r) const { return &d[(size_t)lba(c, h, r) * 512]; }
};

// ------------------------------------------------------------ the simulation
struct Sim {
    Vfdc_card *t;
    uint64_t cyc = 0;
    std::mt19937 rng;
    Image img[2];
    std::vector<uint8_t> mem;

    // DMA channel 2
    struct {
        bool armed = false;     // unmasked and count left
        int  dir = 0;           // 1: I/O -> memory (8237 "write"), 2: memory -> I/O ("read")
        uint32_t addr = 0;
        int count = 0;          // remaining - 1
        int done = 0;           // bytes moved
        // cycle state
        int phase = 0;
        uint64_t t0 = 0;
        bool tc = false;
    } dma;
    bool cpu_busy = false;      // a CPU bus cycle is running
    std::vector<uint64_t> drq_rise;
    bool drq_prev = false;
    // the drive LED / drive sound exports: the selected drive's head movements
    int mcyl[2] = { 0, 0 };     // the heads, followed from drv_step
    int steps_in = 0, steps_out = 0;
    int bad_step = 0;           // a step with no drive (or two) selected, or past a stop

    // backend
    struct {
        double lat_us_min = 2, lat_us_max = 40;   // per request
        int byte_gap_max = 3;                     // clk between bytes
        std::set<int> bad_lba;
        int state = 0;          // 0 idle, 1 latency, 2 streaming, 3 done wait
        uint64_t when = 0;
        int cnt = 0, drv = 0, lba = 0;
        bool wr = false, err = false;
        std::vector<uint8_t> wbuf;
        int requests = 0;
        bool prev_req = false;
    } be;

    Sim(uint32_t seed) : rng(seed), mem(1 << 20, 0) {
        t = new Vfdc_card;
        t->clk = 0; t->reset = 1;
        t->isa_ior_n = 1; t->isa_iow_n = 1; t->isa_aen = 0; t->isa_dack_n = 0xF;
        t->isa_tc = 0; t->isa_addr = 0; t->isa_dout = 0;
        t->sp_rd_valid = 0; t->sp_wr_ready = 0; t->sp_done = 0; t->sp_err = 0;
        apply_drives();
        for (int i = 0; i < 20; i++) tick();
        t->reset = 0;
    }

    void apply_drives() {
        t->img_present = (img[0].present ? 1 : 0) | (img[1].present ? 2 : 0);
        t->img_wp      = (img[0].wp ? 1 : 0) | (img[1].wp ? 2 : 0);
        t->img_tracks  = (img[1].tracks << 8) | img[0].tracks;
        t->img_heads   = (img[1].heads << 2) | img[0].heads;
        t->img_spt     = (img[1].spt << 6) | img[0].spt;
    }

    int rnd(int a, int b) { return std::uniform_int_distribution<int>(a, b)(rng); }

    // one clk: models update their inputs, then the rising edge
    void tick() {
        backend();
        dma_model();
        t->clk = 0; t->eval();
        t->clk = 1; t->eval();
        cyc++;
        bool drq = (t->isa_drq >> 1) & 1;
        if (drq && !drq_prev) drq_rise.push_back(cyc);
        drq_prev = drq;
        if (t->reset) mcyl[0] = mcyl[1] = 0;
        else if (t->drv_step) {
            int sel = t->drv_select;
            if (sel != 1 && sel != 2) bad_step++;
            else {
                int d = sel == 2;
                mcyl[d] += t->drv_step_in ? 1 : -1;
                (t->drv_step_in ? steps_in : steps_out)++;
                if (mcyl[d] < 0 || mcyl[d] > (((t->drv_80trk >> d) & 1) ? 83 : 41)) bad_step++;
            }
        }
    }
    void run_us(double us) { uint64_t e = cyc + us2clk(us); while (cyc < e) tick(); }
    bool irq() const { return (t->isa_irq >> 4) & 1; }

    // ---------------------------------------------------- backend model
    void backend() {
        auto &b = be;
        t->sp_done = 0; t->sp_err = 0; t->sp_rd_valid = 0; t->sp_wr_ready = 0;
        bool req = t->sp_req;
        if (b.state == 0 && req && !b.prev_req) {
            b.requests++;
            b.drv = t->sp_drive; b.wr = t->sp_write; b.lba = t->sp_lba;
            int c = t->sp_cyl, h = t->sp_head, r = t->sp_sector;
            Image &im = img[b.drv];
            int l = im.lba(c, h, r);
            if (l != b.lba) { printf("FAIL backend: LBA %d != CHS-derived %d\n", b.lba, l); fails++; }
            b.err = b.bad_lba.count(b.lba) || !im.present || b.lba < 0 ||
                    (size_t)(b.lba + 1) * 512 > im.d.size();
            b.cnt = 0; b.wbuf.clear();
            b.state = 1;
            b.when = cyc + us2clk(b.lat_us_min + (b.lat_us_max - b.lat_us_min) *
                                  std::uniform_real_distribution<double>(0, 1)(rng));
            if (verbose) printf("[%.1f us] backend %s drv %d lba %d (C%d H%d R%d)\n",
                                clk2us(cyc), b.wr ? "write" : "read", b.drv, b.lba, c, h, r);
        }
        b.prev_req = req;
        Image &im = img[b.drv];
        switch (b.state) {
        case 1:                                 // latency (reads: before the data)
            if (b.wr) { b.state = 2; break; }
            if (cyc >= b.when) b.state = 2;
            break;
        case 2:
            if (b.err && !b.wr) { t->sp_done = 1; t->sp_err = 1; b.state = 4; break; }
            if (!b.wr) {
                if (rnd(0, b.byte_gap_max) == 0) {
                    t->sp_rd_valid = 1;
                    t->sp_rd_data = im.d[(size_t)b.lba * 512 + b.cnt];
                    if (++b.cnt == 512) { t->sp_done = rnd(0, 1); b.state = t->sp_done ? 4 : 3; }
                }
            } else {
                // take a byte when the card offers it (with random stalls)
                if (t->sp_wr_valid && rnd(0, b.byte_gap_max) == 0) {
                    t->sp_wr_ready = 1;
                    b.wbuf.push_back(t->sp_wr_data);
                    if (b.wbuf.size() == 512) { b.state = 3; b.when = cyc + us2clk(b.lat_us_min +
                        (b.lat_us_max - b.lat_us_min) * std::uniform_real_distribution<double>(0, 1)(rng)); }
                }
            }
            break;
        case 3:
            if (!b.wr) { t->sp_done = 1; b.state = 4; break; }
            if (cyc >= b.when) {
                if (!b.err) memcpy(&im.d[(size_t)b.lba * 512], b.wbuf.data(), 512);
                t->sp_done = 1; t->sp_err = b.err; b.state = 4;
            }
            break;
        case 4:                                 // wait for sp_req to drop
            if (!req) b.state = 0;
            break;
        }
    }

    // ---------------------------------------------------- DMA model
    // Single transfer mode. Per byte (in 4.77 MHz clocks of C clk): HRQ/HLDA
    // 2 clocks, then DACK2 + AEN + the strobe pair for 2 clocks (S2/S3 with
    // the 5160's DMA wait state: 3), then release.
    void dma_model() {
        auto &m = dma;
        switch (m.phase) {
        case 0:
            if (m.armed && ((t->isa_drq >> 1) & 1) && !cpu_busy) { m.phase = 1; m.t0 = cyc; }
            break;
        case 1:                                 // hold acquired, AEN, DACK
            if (cyc - m.t0 >= 2 * C) {
                t->isa_aen = 1;
                t->isa_addr = m.addr & 0xFFFFF;
                t->isa_dack_n = 0xF & ~4;
                m.tc = m.count == 0;
                m.phase = 2; m.t0 = cyc;
            }
            break;
        case 2:                                 // strobes (S2)
            if (cyc - m.t0 >= 1 * C) {
                if (m.dir == 1) t->isa_ior_n = 0;
                else { t->isa_dout = mem[m.addr & 0xFFFFF]; t->isa_iow_n = 0; }
                t->isa_tc = m.tc;
                m.phase = 3; m.t0 = cyc;
            }
            break;
        case 3:                                 // S3, Sw, end of S4
            if (cyc - m.t0 >= 3 * C) {
                if (m.dir == 1) mem[m.addr & 0xFFFFF] = t->isa_din;
                t->isa_ior_n = 1; t->isa_iow_n = 1;
                m.phase = 4; m.t0 = cyc;
            }
            break;
        case 4:
            if (cyc - m.t0 >= C / 3) {          // DACK/TC go with the next half clock
                t->isa_dack_n = 0xF; t->isa_tc = 0;
                m.addr++; m.done++;
                if (m.count == 0) m.armed = false; else m.count--;
                m.phase = 5; m.t0 = cyc;
            }
            break;
        case 5:
            if (cyc - m.t0 >= C) { t->isa_aen = 0; m.phase = 0; }
            break;
        }
    }
    void dma_setup(int dir, uint32_t addr, int n) {
        dma.armed = n > 0; dma.dir = dir; dma.addr = addr; dma.count = n - 1; dma.done = 0;
    }
    void dma_mask() { dma.armed = false; }
    bool dma_idle() const { return dma.phase == 0; }

    // ---------------------------------------------------- CPU I/O cycles
    // An 8088 I/O cycle with the 5160's wait state: the strobe lasts ~2.67
    // CPU clocks; the bus is busy from T1 to T4.
    void wait_bus() { while (!dma_idle()) tick(); }
    void io_write(int port, int val) {
        wait_bus();
        cpu_busy = true;
        t->isa_addr = port; t->isa_aen = 0;
        for (int i = 0; i < C + C / 3; i++) tick();  // T1, T2 to the falling edge
        t->isa_dout = val;
        t->isa_iow_n = 0;
        for (int i = 0; i < 8 * C / 3; i++) tick();
        t->isa_iow_n = 1;
        for (int i = 0; i < C; i++) tick();     // T4
        cpu_busy = false;
        for (int i = 0; i < 2 * C; i++) tick(); // instruction overhead
    }
    int io_read(int port) {
        wait_bus();
        cpu_busy = true;
        t->isa_addr = port; t->isa_aen = 0;
        for (int i = 0; i < 2 * C / 3; i++) tick();
        t->isa_ior_n = 0;
        for (int i = 0; i < 3 * C; i++) tick();
        int v = t->isa_dsel ? t->isa_din : 0xFF;
        t->isa_ior_n = 1;
        for (int i = 0; i < C; i++) tick();
        cpu_busy = false;
        for (int i = 0; i < 2 * C; i++) tick();
        return v;
    }

    // ---------------------------------------------------- BIOS-like helpers
    int msr() { return io_read(0x3F4); }
    bool fdc_out(int b) {
        for (int i = 0; i < 20000; i++) {
            int m = msr();
            if ((m & 0xC0) == 0x80) { io_write(0x3F5, b); return true; }
        }
        printf("FAIL fdc_out(%02X): timeout, MSR %02X\n", b, msr()); fails++;
        return false;
    }
    int fdc_in() {
        for (int i = 0; i < 20000; i++) {
            int m = msr();
            if ((m & 0xC0) == 0xC0) return io_read(0x3F5);
        }
        printf("FAIL fdc_in: timeout, MSR %02X\n", msr()); fails++;
        return -1;
    }
    void cmd(std::initializer_list<int> bytes) { for (int b : bytes) fdc_out(b); }
    std::vector<int> results(int n) {
        std::vector<int> r;
        for (int i = 0; i < n; i++) r.push_back(fdc_in());
        int m = msr();
        CHECK((m & 0x10) == 0, "CB still set after %d result bytes (MSR %02X)", n, m);
        return r;
    }
    bool wait_irq(double ms) {
        uint64_t e = cyc + us2clk(ms * 1000);
        while (cyc < e) { if (irq()) return true; tick(); }
        return false;
    }
    std::vector<int> sense_int() {
        fdc_out(0x08);
        int st0 = fdc_in();
        if (st0 == 0x80) return { st0 };
        int pcn = fdc_in();
        return { st0, pcn };
    }
};

static std::string hex(const std::vector<int> &v) {
    std::string s;
    char b[8];
    for (int x : v) { snprintf(b, sizeof b, "%02X ", x & 0xFF); s += b; }
    return s;
}

static bool expect_res(const std::vector<int> &got, const std::vector<int> &exp, const char *what) {
    bool ok = got == exp;
    checks++;
    if (!ok) { fails++; printf("FAIL %s: results %s, expected %s\n", what, hex(got).c_str(), hex(exp).c_str()); }
    else if (verbose) printf("ok   %s: %s\n", what, hex(got).c_str());
    return ok;
}

static int cmp_mem(Sim &s, uint32_t addr, const uint8_t *exp, int n) {
    int bad = 0;
    for (int i = 0; i < n; i++) if (s.mem[addr + i] != exp[i]) {
        if (bad < 4) printf("     mem[%05X] (sector %d byte %d) = %02X, expected %02X\n",
                            addr + i, i / 512, i % 512, s.mem[addr + i], exp[i]);
        bad++;
    }
    if (bad) printf("     %d of %d bytes differ\n", bad, n);
    return bad;
}

// read/write/verify helpers on top of the BIOS-like ones
static std::vector<int> rw(Sim &s, int op, int unit, int c, int h, int r, int eot,
                           int dma_dir, uint32_t addr, int nbytes, double timeout_ms = 1500) {
    if (dma_dir) s.dma_setup(dma_dir, addr, nbytes);
    s.cmd({ op, (h << 2) | unit, c, h, r, 2, eot, 0x2A, 0xFF });
    bool got = s.wait_irq(timeout_ms);
    CHECK(got, "no IRQ6 after command %02X C%d H%d R%d", op, c, h, r);
    auto res = s.results(7);
    s.dma_mask();
    return res;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    setvbuf(stdout, nullptr, _IOLBF, 0);
    uint32_t seed = 1;
    std::string outdir = std::string(getenv("HOME") ? getenv("HOME") : ".") + "/pcxt-work/fdc";
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-v")) verbose = true;
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) seed = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-o") && i + 1 < argc) outdir = argv[++i];
    }

    Sim s(seed);
    s.img[0].make(40, 2, 9, 0x360);          // A: 360K in a 40-track drive
    s.img[1].make(80, 2, 9, 0x720);          // B: 720K in an 80-track drive
    s.t->drv_80trk = 2;
    s.apply_drives();
    Image orig0 = s.img[0];

    // ======================================================== reset
    printf("== reset, sense interrupt status (%.0f ms)\n", clk2us(s.cyc) / 1000);
    s.io_write(0x3F2, 0x00);
    CHECK(s.msr() == 0x00, "MSR in reset: %02X", s.msr());
    s.io_write(0x3F2, 0x0C);
    uint64_t t0 = s.cyc;
    CHECK(s.wait_irq(5), "no IRQ6 after reset");
    double dt = clk2us(s.cyc - t0);
    CHECK(dt > 900 && dt < 1100, "reset to IRQ: %.1f us", dt);
    for (int u = 0; u < 4; u++) {
        auto r = s.sense_int();
        expect_res(r, { 0xC0 | u, 0 }, "SIS after reset");
        if (u == 0) CHECK(!s.irq(), "IRQ6 still up after the first SIS");
    }
    expect_res(s.sense_int(), { 0x80 }, "SIS with nothing pending");
    s.run_us(15);
    CHECK(s.msr() == 0x80, "MSR idle: %02X", s.msr());

    // ======================================================== RQM delay
    printf("== MSR timing (%.0f ms)\n", clk2us(s.cyc) / 1000);
    {
        s.io_write(0x3F5, 0x03);                         // SPECIFY, first byte
        int m1 = s.io_read(0x3F4);                       // ~1 us after the write strobe
        s.run_us(12);
        int m2 = s.io_read(0x3F4);
        CHECK(m1 == 0x10, "MSR right after a command byte: %02X (RQM low, CB)", m1);
        CHECK(m2 == 0x90, "MSR 12 us later: %02X", m2);
        s.fdc_out(0xCF); s.fdc_out(0x02);                // SRT 8 ms, HUT 480 ms, HLT 4 ms, DMA
        s.run_us(15);
        CHECK(s.msr() == 0x80, "MSR after SPECIFY: %02X", s.msr());
        expect_res(std::vector<int>{ s.io_read(0x3F4) }, { 0x80 }, "MSR");
    }

    // ======================================================== invalid command
    s.fdc_out(0x1F);
    expect_res(s.results(1), { 0x80 }, "invalid command");
    s.fdc_out(0x11);                                     // SCAN EQUAL: not implemented
    expect_res(s.results(1), { 0x80 }, "SCAN (unsupported)");

    // ======================================================== recalibrate, seek
    printf("== recalibrate, seek (%.0f ms)\n", clk2us(s.cyc) / 1000);
    s.io_write(0x3F2, 0x1C);                             // motor A, drive A
    s.cmd({ 0x07, 0x00 });
    CHECK(s.wait_irq(10), "no IRQ after RECAL at track 0");
    expect_res(s.sense_int(), { 0x20, 0 }, "RECAL at track 0");
    s.cmd({ 0x0F, 0x00, 10 });
    t0 = s.cyc;
    s.run_us(20000);
    CHECK(s.msr() == 0x81, "MSR during seek: %02X", s.msr());
    CHECK(s.wait_irq(200), "no IRQ after SEEK");
    dt = clk2us(s.cyc - t0) / 1000;
    CHECK(dt > 79.5 && dt < 80.5, "10 steps at SRT C: %.3f ms, expected 80", dt);
    CHECK(s.msr() == 0x81, "MSR after seek end: %02X", s.msr());
    expect_res(s.sense_int(), { 0x20, 10 }, "SEEK 10");
    CHECK(s.mcyl[0] == 10 && s.steps_in == 10 && s.steps_out == 0,
          "drv_step after SEEK 10: head %d, %d in, %d out", s.mcyl[0], s.steps_in, s.steps_out);
    s.run_us(15);
    CHECK(s.msr() == 0x80, "MSR after SIS: %02X", s.msr());
    CHECK(!s.irq(), "IRQ after SIS");

    // ======================================================== sense drive status
    s.fdc_out(0x04); s.fdc_out(0x00);
    expect_res(s.results(1), { 0x28 }, "SENSE DRIVE STATUS at C10");

    // ======================================================== read data
    printf("== read data (DMA) (%.0f ms)\n", clk2us(s.cyc) / 1000);
    uint64_t r0 = s.be.requests;
    s.drq_rise.clear();
    auto res = rw(s, 0xE6, 0, 10, 0, 1, 9, 1, 0x10000, 9 * 512);
    expect_res(res, { 0x00, 0x00, 0x00, 10, 1, 1, 2 }, "READ C10 H0 R1-9 (MT)");
    CHECK(cmp_mem(s, 0x10000, s.img[0].sec(10, 0, 1), 9 * 512) == 0, "read data mismatch");
    CHECK(s.dma.done == 9 * 512, "DMA moved %d bytes", s.dma.done);
    CHECK(s.be.requests - r0 == 10, "backend requests %d (expected 9 + prefetch of H1 R1)", (int)(s.be.requests - r0));
    {
        // byte rate: DRQ rises 32 us apart inside a sector
        int n = 0; double sum = 0, mn = 1e9, mx = 0;
        for (size_t i = 1; i < 512 && i < s.drq_rise.size(); i++) {
            double d = clk2us(s.drq_rise[i] - s.drq_rise[i - 1]);
            sum += d; n++; if (d < mn) mn = d; if (d > mx) mx = d;
        }
        CHECK(n == 511 && mn > 31.9 && mx < 32.1, "DRQ period in a sector: %.3f..%.3f us (n %d)", mn, mx, n);
        // sector to sector: one pitch (654 bytes)
        double d = clk2us(s.drq_rise[512] - s.drq_rise[0]) / 32;
        CHECK(d > 653.9 && d < 654.1, "sector pitch %.2f byte times", d);
    }

    printf("== multi-track, EN, ND, WC, MA (%.0f ms)\n", clk2us(s.cyc) / 1000);
    res = rw(s, 0xE6, 0, 10, 0, 8, 9, 1, 0x20000, 4 * 512);
    expect_res(res, { 0x04, 0x00, 0x00, 10, 1, 3, 2 }, "READ C10 H0 R8 -> H1 R2 (MT)");
    CHECK(cmp_mem(s, 0x20000, s.img[0].sec(10, 0, 8), 1024) == 0 &&
          cmp_mem(s, 0x20400, s.img[0].sec(10, 1, 1), 1024) == 0, "multi-track data mismatch");

    res = rw(s, 0x46, 0, 10, 0, 8, 9, 1, 0x20000, 4 * 512);
    expect_res(res, { 0x40, 0x80, 0x00, 11, 0, 1, 2 }, "READ past EOT without MT: EN");

    res = rw(s, 0xE6, 0, 10, 0, 10, 10, 1, 0x20000, 512);
    expect_res(res, { 0x40, 0x04, 0x00, 10, 0, 10, 2 }, "READ R10: ND");

    res = rw(s, 0xE6, 0, 11, 0, 1, 9, 1, 0x20000, 512);
    expect_res(res, { 0x40, 0x04, 0x10, 11, 0, 1, 2 }, "READ C11 at C10: ND + WC");

    res = rw(s, 0xA6, 0, 10, 0, 1, 9, 1, 0x20000, 512);   // MF = 0 (FM)
    expect_res(res, { 0x40, 0x01, 0x00, 10, 0, 1, 2 }, "READ in FM: MA");

    // ======================================================== read id, rotation
    printf("== read id, rotation (%.0f ms)\n", clk2us(s.cyc) / 1000);
    s.cmd({ 0x4A, 0x00 });
    CHECK(s.wait_irq(300), "no IRQ after READ ID");
    res = s.results(7);
    CHECK(res.size() == 7 && res[0] == 0 && res[1] == 0 && res[2] == 0 && res[3] == 10 &&
          res[4] == 0 && res[5] >= 1 && res[5] <= 9 && res[6] == 2, "READ ID: %s", hex(res).c_str());
    {
        rw(s, 0x66, 0, 10, 0, 3, 3, 1, 0x30000, 512);
        uint64_t a = s.cyc;
        rw(s, 0x66, 0, 10, 0, 3, 3, 1, 0x30000, 512);
        double rev = clk2us(s.cyc - a) / 1000;
        CHECK(rev > 199.9 && rev < 200.1, "same sector twice: %.3f ms apart (one revolution)", rev);
        // READ ID right after a sector returns the next one
        s.cmd({ 0x4A, 0x00 });
        CHECK(s.wait_irq(300), "no IRQ after READ ID");
        res = s.results(7);
        CHECK(res.size() == 7 && res[5] == 4, "READ ID after R3: %s", hex(res).c_str());
    }

    // ======================================================== write data
    printf("== write data (%.0f ms)\n", clk2us(s.cyc) / 1000);
    for (int i = 0; i < 1024; i++) s.mem[0x40000 + i] = (uint8_t)(i * 7 + 3);
    res = rw(s, 0xC5, 0, 10, 1, 5, 9, 2, 0x40000, 1024);
    expect_res(res, { 0x04, 0x00, 0x00, 10, 1, 7, 2 }, "WRITE C10 H1 R5-6");
    CHECK(memcmp(s.img[0].sec(10, 1, 5), &s.mem[0x40000], 1024) == 0, "written data not in the image");
    CHECK(memcmp(s.img[0].sec(10, 1, 4), orig0.sec(10, 1, 4), 512) == 0 &&
          memcmp(s.img[0].sec(10, 1, 7), orig0.sec(10, 1, 7), 512) == 0, "neighbour sectors changed");
    res = rw(s, 0xE6, 0, 10, 1, 5, 9, 1, 0x50000, 1024);
    expect_res(res, { 0x04, 0x00, 0x00, 10, 1, 7, 2 }, "read back");
    CHECK(memcmp(&s.mem[0x50000], &s.mem[0x40000], 1024) == 0, "read-back mismatch");

    // TC inside a sector: the rest is zero
    res = rw(s, 0xC5, 0, 10, 1, 8, 9, 2, 0x40000, 100);
    expect_res(res, { 0x04, 0x00, 0x00, 10, 1, 9, 2 }, "WRITE 100 bytes (TC mid-sector)");
    {
        std::vector<uint8_t> e(512, 0);
        memcpy(e.data(), &s.mem[0x40000], 100);
        CHECK(memcmp(s.img[0].sec(10, 1, 8), e.data(), 512) == 0, "TC padding: sector not data + zeros");
    }

    // write protect
    s.img[0].wp = true; s.apply_drives();
    s.fdc_out(0x04); s.fdc_out(0x00);
    expect_res(s.results(1), { 0x68 }, "SENSE DRIVE STATUS, protected");
    res = rw(s, 0xC5, 0, 10, 0, 1, 9, 2, 0x40000, 512);
    expect_res(res, { 0x40, 0x02, 0x00, 10, 0, 1, 2 }, "WRITE protected: NW");
    s.img[0].wp = false; s.apply_drives();

    // ======================================================== format
    printf("== format track (%.0f ms)\n", clk2us(s.cyc) / 1000);
    s.cmd({ 0x0F, 0x04, 20 });
    CHECK(s.wait_irq(200), "no IRQ after SEEK 20");
    expect_res(s.sense_int(), { 0x24, 20 }, "SEEK 20 head 1");
    for (int i = 0; i < 9; i++) {
        s.mem[0x60000 + 4 * i + 0] = 20; s.mem[0x60000 + 4 * i + 1] = 1;
        s.mem[0x60000 + 4 * i + 2] = i + 1; s.mem[0x60000 + 4 * i + 3] = 2;
    }
    s.dma_setup(2, 0x60000, 36);
    s.cmd({ 0x4D, 0x04, 2, 9, 0x50, 0xF6 });
    CHECK(s.wait_irq(600), "no IRQ after FORMAT");
    res = s.results(7);
    expect_res(res, { 0x04, 0x00, 0x00, 20, 1, 9, 2 }, "FORMAT C20 H1");
    {
        int bad = 0;
        for (int r = 1; r <= 9; r++) for (int i = 0; i < 512; i++) bad += s.img[0].sec(20, 1, r)[i] != 0xF6;
        CHECK(bad == 0, "formatted track: %d bytes not F6", bad);
        CHECK(memcmp(s.img[0].sec(20, 0, 1), orig0.sec(20, 0, 1), 9 * 512) == 0, "format touched head 0");
        CHECK(memcmp(s.img[0].sec(21, 1, 1), orig0.sec(21, 1, 1), 9 * 512) == 0, "format touched C21");
    }
    res = rw(s, 0xE6, 0, 20, 1, 9, 9, 1, 0x70000, 512);
    expect_res(res, { 0x04, 0x00, 0x00, 21, 0, 1, 2 }, "READ C20 H1 R9 (MT: next cylinder)");
    CHECK(s.mem[0x70000] == 0xF6 && s.mem[0x701FF] == 0xF6, "read of formatted sector");

    // ======================================================== read track
    printf("== read track (%.0f ms)\n", clk2us(s.cyc) / 1000);
    res = rw(s, 0x42, 0, 20, 0, 1, 9, 1, 0x80000, 9 * 512);
    expect_res(res, { 0x00, 0x00, 0x00, 20, 0, 10, 2 }, "READ TRACK C20 H0");
    CHECK(cmp_mem(s, 0x80000, s.img[0].sec(20, 0, 1), 9 * 512) == 0, "read track data");

    // ======================================================== overrun
    printf("== overrun, DOR gating (%.0f ms)\n", clk2us(s.cyc) / 1000);
    s.drq_rise.clear();
    s.cmd({ 0xE6, 0x00, 20, 0, 1, 2, 9, 0x2A, 0xFF });   // DMA not armed
    CHECK(s.wait_irq(600), "no IRQ after overrun");
    dt = s.drq_rise.empty() ? 0 : clk2us(s.cyc - s.drq_rise[0]);
    CHECK(dt > 31.5 && dt < 33.5, "overrun %.2f us after the first DRQ (one byte time expected)", dt);
    expect_res(s.results(7), { 0x40, 0x10, 0x00, 20, 0, 1, 2 }, "READ without DMA: OR");

    // DOR bit 3 off: no IRQ6 on the bus, the 765 still interrupts internally
    s.io_write(0x3F2, 0x14);
    s.cmd({ 0x0F, 0x00, 5 });
    s.run_us(200000);
    CHECK(!s.irq(), "IRQ6 visible with DOR bit 3 = 0");
    CHECK(s.msr() == 0x81, "MSR after hidden seek end: %02X", s.msr());
    expect_res(s.sense_int(), { 0x20, 5 }, "SIS after hidden seek");
    s.io_write(0x3F2, 0x1C);

    // ======================================================== non-DMA
    printf("== non-DMA read (%.0f ms)\n", clk2us(s.cyc) / 1000);
    s.cmd({ 0x03, 0xCF, 0x03 });                         // ND = 1
    s.cmd({ 0x46, 0x00, 5, 0, 1, 2, 1, 0x2A, 0xFF });
    {
        int got = 0, bad = 0, irqs = 0, msr_ok = 0, msr_bad = 0;
        uint64_t end = s.cyc + us2clk(500000);
        while (got < 512 && s.cyc < end) {
            int m = s.msr();
            if (m == 0xF0) {
                msr_ok++;
                if (s.irq()) irqs++;
                int v = s.io_read(0x3F5);
                if (v != s.img[0].sec(5, 0, 1)[got]) bad++;
                got++;
            } else if (m != 0x70) {
                if (!msr_bad) printf("     MSR in non-DMA execution: %02X\n", m);
                msr_bad++;
            }
        }
        CHECK(msr_bad == 0, "MSR not F0/70 in non-DMA execution: %d times", msr_bad);
        CHECK(got == 512 && bad == 0, "non-DMA read: %d bytes, %d wrong", got, bad);
        CHECK(irqs == 512, "IRQ6 with each byte: %d", irqs);
        CHECK(s.wait_irq(50), "no result IRQ (non-DMA)");
        expect_res(s.results(7), { 0x40, 0x80, 0x00, 6, 0, 1, 2 }, "non-DMA read ends with EN");
    }
    s.cmd({ 0x03, 0xCF, 0x02 });

    // ======================================================== drive B, EC
    printf("== drive B: 80 tracks, recalibrate EC (%.0f ms)\n", clk2us(s.cyc) / 1000);
    s.io_write(0x3F2, 0x2D);                             // motor B, drive B
    s.cmd({ 0x0F, 0x01, 79 });
    CHECK(s.wait_irq(1000), "no IRQ after SEEK 79");
    expect_res(s.sense_int(), { 0x21, 79 }, "SEEK B 79");
    CHECK(s.mcyl[1] == 79, "drv_step: B's head at %d after SEEK 79", s.mcyl[1]);
    res = rw(s, 0xE6, 1, 79, 1, 9, 9, 1, 0x90000, 512);
    expect_res(res, { 0x05, 0x00, 0x00, 80, 0, 1, 2 }, "READ B C79 H1 R9");
    CHECK(cmp_mem(s, 0x90000, s.img[1].sec(79, 1, 9), 512) == 0, "drive B data");
    s.cmd({ 0x07, 0x01 });
    t0 = s.cyc;
    CHECK(s.wait_irq(1000), "no IRQ after RECAL");
    dt = clk2us(s.cyc - t0) / 1000;
    CHECK(dt > 615.5 && dt < 616.5, "77 steps: %.3f ms", dt);
    expect_res(s.sense_int(), { 0x71, 0 }, "RECAL from 79: EC after 77 steps");
    CHECK(s.mcyl[1] == 2, "drv_step: B's head at %d after 77 steps out", s.mcyl[1]);
    s.cmd({ 0x07, 0x01 });
    CHECK(s.wait_irq(1000), "no IRQ after 2nd RECAL");
    expect_res(s.sense_int(), { 0x21, 0 }, "second RECAL");
    CHECK(s.mcyl[1] == 0, "drv_step: B's head at %d after the second RECAL", s.mcyl[1]);
    s.fdc_out(0x04); s.fdc_out(0x01);
    expect_res(s.results(1), { 0x39 }, "SENSE DRIVE STATUS B at track 0");

    // ======================================================== slow backend
    printf("== slow backend (%.0f ms)\n", clk2us(s.cyc) / 1000);
    s.io_write(0x3F2, 0x1C);
    s.be.lat_us_min = 25000; s.be.lat_us_max = 35000;
    t0 = s.cyc;
    res = rw(s, 0xE6, 0, 5, 0, 1, 9, 1, 0xA0000, 9 * 512, 5000);
    expect_res(res, { 0x00, 0x00, 0x00, 5, 1, 1, 2 }, "READ with a 30 ms backend");
    CHECK(cmp_mem(s, 0xA0000, s.img[0].sec(5, 0, 1), 9 * 512) == 0, "slow read data");
    printf("     9 sectors with 25-35 ms latency: %.1f ms\n", clk2us(s.cyc - t0) / 1000);
    for (int i = 0; i < 2048; i++) s.mem[0xB0000 + i] = (uint8_t)(i ^ 0x5A);
    res = rw(s, 0xE5, 0, 5, 0, 6, 9, 2, 0xB0000, 2048, 5000);
    expect_res(res, { 0x00, 0x00, 0x00, 5, 1, 1, 2 }, "WRITE with a 30 ms backend");
    CHECK(memcmp(s.img[0].sec(5, 0, 6), &s.mem[0xB0000], 2048) == 0, "slow write data");
    s.be.lat_us_min = 2; s.be.lat_us_max = 40;

    // backend errors
    s.be.bad_lba.insert(s.img[0].lba(5, 0, 3));
    res = rw(s, 0xE6, 0, 5, 0, 2, 9, 1, 0xA0000, 2 * 512);
    expect_res(res, { 0x40, 0x20, 0x20, 5, 0, 3, 2 }, "READ, backend error on R3: DE + DD");
    res = rw(s, 0xC5, 0, 5, 0, 3, 9, 2, 0xB0000, 512);
    expect_res(res, { 0x50, 0x00, 0x00, 5, 0, 4, 2 }, "WRITE, backend error: EC");
    s.be.bad_lba.clear();

    // ======================================================== single-sided medium
    printf("== single-sided medium, no medium (%.0f ms)\n", clk2us(s.cyc) / 1000);
    Image save0 = s.img[0];
    s.img[0].make(40, 1, 8, 0x160); s.apply_drives();
    res = rw(s, 0xE6, 0, 5, 1, 1, 8, 1, 0xA0000, 512);
    expect_res(res, { 0x44, 0x01, 0x00, 5, 1, 1, 2 }, "READ side 1 of a 160K disk: MA");
    res = rw(s, 0x66, 0, 5, 0, 8, 8, 1, 0xA0000, 512);
    expect_res(res, { 0x00, 0x00, 0x00, 6, 0, 1, 2 }, "READ 160K C5 R8");
    CHECK(cmp_mem(s, 0xA0000, s.img[0].sec(5, 0, 8), 512) == 0, "160K data");
    s.img[0] = save0; s.apply_drives();

    // no medium: the 765 waits for index pulses forever, as on a real PC
    s.img[1].present = false; s.apply_drives();
    s.io_write(0x3F2, 0x2D);
    s.dma_setup(1, 0xA0000, 512);
    s.cmd({ 0xE6, 0x01, 0, 0, 1, 2, 9, 0x2A, 0xFF });
    CHECK(!s.wait_irq(1000), "IRQ without a medium");
    CHECK(s.msr() == 0x50, "MSR while hanging: %02X", s.msr());
    s.dma_mask();
    s.io_write(0x3F2, 0x08);                             // reset
    s.io_write(0x3F2, 0x0C);
    CHECK(s.wait_irq(5), "no IRQ after the second reset");
    expect_res(s.sense_int(), { 0xC0, 0 }, "SIS after recovery");
    s.cmd({ 0x03, 0xCF, 0x02 });
    s.img[1].present = true; s.apply_drives();

    // ======================================================== random reads/writes
    printf("== random sector traffic (%.0f ms)\n", clk2us(s.cyc) / 1000);
    s.io_write(0x3F2, 0x1C);
    s.cmd({ 0x07, 0x00 });
    s.wait_irq(1000);
    s.sense_int();
    int cur = 0;
    for (int it = 0; it < 12; it++) {
        int c = s.rnd(0, 39), h = s.rnd(0, 1), r = s.rnd(1, 9);
        int n = s.rnd(1, 9 - r + 1);
        if (c != cur) {
            s.cmd({ 0x0F, h << 2, c });
            CHECK(s.wait_irq(1000), "seek IRQ");
            s.sense_int();
            cur = c;
        }
        bool wr = s.rnd(0, 1);
        if (wr) {
            for (int i = 0; i < n * 512; i++) s.mem[0xC0000 + i] = (uint8_t)s.rnd(0, 255);
            res = rw(s, 0xC5, 0, c, h, r, 9, 2, 0xC0000, n * 512);
            CHECK(memcmp(s.img[0].sec(c, h, r), &s.mem[0xC0000], n * 512) == 0, "random write C%d H%d R%d n%d", c, h, r, n);
        } else {
            res = rw(s, 0xE6, 0, c, h, r, 9, 1, 0xC0000, n * 512);
            CHECK(cmp_mem(s, 0xC0000, s.img[0].sec(c, h, r), n * 512) == 0, "random read C%d H%d R%d n%d", c, h, r, n);
        }
        int er = r + n - 1;
        int ec = c, eh = h, rr = er + 1;
        if (er == 9) { rr = 1; if (h == 0) eh = 1; else { ec = c + 1; eh = 0; } }
        expect_res(res, { h << 2, 0, 0, ec, eh, rr, 2 }, wr ? "random write" : "random read");
    }

    // ======================================================== drive LED, step export
    printf("== drive select and step exports (%.0f ms)\n", clk2us(s.cyc) / 1000);
    {
        const struct { int dor, sel; } dt[] = {
            { 0x1C, 1 }, { 0x2D, 2 }, { 0x1D, 0 }, { 0x2C, 0 }, { 0x0C, 0 }, { 0x3C, 1 },
            { 0x3D, 2 }, { 0x3E, 0 }, { 0x14, 1 } };
        for (auto &e : dt) {
            s.io_write(0x3F2, e.dor);
            s.run_us(2);
            CHECK((int)s.t->drv_select == e.sel, "DOR %02X: drv_select %d, expected %d",
                  e.dor, (int)s.t->drv_select, e.sel);
        }
        // A: is a 40-track drive: a seek to 50 (the PC10-III BIOS's 80-track probe) moves its
        // head to the stop (41) and the recalibrate back from there
        s.io_write(0x3F2, 0x1C);
        s.cmd({ 0x07, 0x00 });
        CHECK(s.wait_irq(1000), "no IRQ after RECAL A");
        s.sense_int();
        CHECK(s.mcyl[0] == 0, "drv_step: A's head at %d after RECAL", s.mcyl[0]);
        int i0 = s.steps_in, o0 = s.steps_out;
        s.cmd({ 0x0F, 0x00, 50 });
        CHECK(s.wait_irq(1000), "no IRQ after SEEK A 50");
        expect_res(s.sense_int(), { 0x20, 50 }, "SEEK A 50 (40-track drive)");
        CHECK(s.mcyl[0] == 41 && s.steps_in - i0 == 41, "SEEK 50 on 40 tracks: head %d, %d steps",
              s.mcyl[0], s.steps_in - i0);
        s.cmd({ 0x07, 0x00 });
        CHECK(s.wait_irq(1000), "no IRQ after RECAL from the stop");
        expect_res(s.sense_int(), { 0x20, 0 }, "RECAL A from the stop");
        CHECK(s.mcyl[0] == 0 && s.steps_out - o0 == 41, "RECAL from the stop: head %d, %d steps",
              s.mcyl[0], s.steps_out - o0);
        // the motor off: the drive is not selected, a seek moves nothing
        s.io_write(0x3F2, 0x0C);
        i0 = s.steps_in;
        s.cmd({ 0x0F, 0x00, 5 });
        CHECK(s.wait_irq(1000), "no IRQ after SEEK with the motor off");
        s.sense_int();
        CHECK(s.steps_in == i0 && s.mcyl[0] == 0, "steps with the motor off: %d", s.steps_in - i0);
        s.cmd({ 0x07, 0x00 });
        s.wait_irq(1000);
        s.sense_int();
        CHECK(s.bad_step == 0, "%d steps without one selected drive or past a stop", s.bad_step);
    }

    // ======================================================== done
    if (!outdir.empty()) {
        for (int d = 0; d < 2; d++) {
            std::string fn = outdir + "/out_" + (d ? "b" : "a") + ".img";
            FILE *f = fopen(fn.c_str(), "wb");
            if (f) { fwrite(s.img[d].d.data(), 1, s.img[d].d.size(), f); fclose(f); }
        }
    }
    printf("%s: %d checks, %d failed, %.1f ms simulated, %d backend requests\n",
           fails ? "FAIL" : "PASS", checks, fails, clk2us(s.cyc) / 1000, s.be.requests);
    s.t->final();
    delete s.t;
    return fails ? 1 : 0;
}
