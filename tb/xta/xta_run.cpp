// xta_run.cpp - Verilator testbench for rtl/hdc/xta_card.sv (doc/xta.md).
//
// Drives the card bus the way the PC10-III does: 8088 I/O cycles with the
// board's wait state, and channel 3 of the 8237 in single-transfer mode
// (DRQ3 -> DACK3 with AEN, IOR+MEMW or MEMR+IOW, the CPU's bus cycle between
// two transfers). Serves the sector port from a C++ image (random latency and
// byte spacing, injectable read and write errors), and checks every command
// the Commodore BIOS 4.41 and its WD formatter use against a command-level
// reference model (`Ref`): completion byte, sense bytes, data, the image, the
// sector buffer. A second model checks the drive's timing: the spindle
// (REV_CLK clk, 27 slots), the interleave's slot order, the seek times and
// the one-sector buffer decide when each sector's data appear on DRQ3.
//
//   ./obj/xta_run [-v] [-s seed] [-f]     (-f: also format the whole drive, ~45 s PC time)
//
// GPL-3.0-or-later, pc10-iii.

#include "Vxta_card.h"
#include "verilated.h"

#include <algorithm>
#include <cmath>
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
static const int C = 6;
static uint64_t us2clk(double us) { return (uint64_t)(us * CLK_HZ / 1e6 + 0.5); }
static double clk2us(uint64_t c) { return c * 1e6 / CLK_HZ; }

static int fails = 0, checks = 0;
static bool verbose = false;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { fails++; \
    printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// the card's parameters (the Makefile builds it with SPINUP_MS = 5)
static const int REV_CLK = 516124, BYTE_CLK = 31, CCB_US = 12, CMD_US = 300, FREE_US = 2,
                 RESET_US = 1000, SPINUP_MS = 5, SEEK_A_US = 2760, SEEK_B_US = 140, DIAG_US = 2500,
                 ILV_INIT = 3;
static const int LMAX = 615 * 4 * 17;
static const int PORT = 0x320;
enum { REQ = 1, IO = 2, CD = 4, BSY = 8, DRQ = 0x10, IRQ = 0x20 };

static int isqrt(int n) { int r = (int)std::sqrt((double)n); while (r * r > n) r--; while ((r + 1) * (r + 1) <= n) r++; return r; }
static double seek_us(int d) { return d ? SEEK_A_US + SEEK_B_US * isqrt(256 * d) : 0; }
// the usual interleaved layout of 27 sectors: sector k's slot
static std::vector<int> layout(int ilv) {
    std::vector<int> slot(27);
    std::vector<bool> used(27, false);
    int s = 0;
    for (int k = 0; k < 27; k++) {
        while (used[s]) s = (s + 1) % 27;
        slot[k] = s; used[s] = true;
        s = (s + ilv) % 27;
    }
    return slot;
}
static void chs_of(int l, int &c, int &h, int &s) { c = l / 68; h = (l / 17) % 4; s = l % 17; }

// ------------------------------------------------------------ the reference model
struct Ref {
    std::vector<uint8_t> img;
    uint8_t buf[512] = {};
    uint8_t sense[4] = {};
    int ilv = ILV_INIT;
    bool ready = true, drv1_test_ok = true;
    std::set<int> bad_rd, bad_wr;           // the backend fails these LBAs

    struct Res { uint8_t comp = 0; std::vector<uint8_t> din; int sectors = 0; };

    void set_sense(int code, bool av, int drv, int c, int h, int s) {
        sense[0] = (av ? 0x80 : 0) | code;
        sense[1] = (drv << 5) | h;
        sense[2] = ((c >> 8) << 6) | s;
        sense[3] = c & 0xFF;
    }
    Res exec(const uint8_t *ccb, const std::vector<uint8_t> &dout) {
        Res r;
        int op = ccb[0], drv = (ccb[1] >> 5) & 1, head = ccb[1] & 31, sec = ccb[2] & 63;
        int cyl = ((ccb[2] >> 6) << 8) | ccb[3], n = ccb[4] ? ccb[4] : 256;
        static const std::set<int> known = {0x00, 0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0A, 0x0B, 0x0C,
                                            0x0D, 0x0E, 0x0F, 0xE0, 0xE3, 0xE4, 0xE5, 0xE6};
        static const std::set<int> ctrl = {0x03, 0x0C, 0x0D, 0x0E, 0x0F, 0xE0, 0xE4};
        auto err = [&](int code, bool av, int c, int h, int s) {
            set_sense(code, av, drv, c, h, s);
            r.comp = (drv << 5) | 2;
            return r;
        };
        r.comp = drv << 5;
        if (!known.count(op)) return err(0x20, false, cyl, head, sec);
        if (!ctrl.count(op)) {
            if (drv ? !(op == 0x00 && drv1_test_ok) : !ready) return err(0x04, false, cyl, head, sec);
        }
        bool rw = op == 0x05 || op == 0x08 || op == 0x0A || op == 0xE5 || op == 0xE6;
        if ((rw || op == 0x06 || op == 0x07 || op == 0x0B) && (cyl >= 615 || head >= 4 || (rw && sec >= 17)))
            return err(0x21, true, cyl, head, sec);
        if ((op == 0x04 || op == 0x06 || op == 0x07) && (ccb[4] == 0 || ccb[4] > 26))
            return err(0x21, false, cyl, head, sec);
        if (op == 0x03) {
            r.din.assign(sense, sense + 4);
            memset(sense, 0, 4);
            return r;
        }
        memset(sense, 0, 4);
        int l0 = (cyl * 4 + head) * 17 + ((op == 0x06 || op == 0x07) ? 0 : sec);
        int c, h, s;
        switch (op) {
        case 0x0D: r.din.push_back(0); break;
        case 0x0E: r.din.assign(buf, buf + 512); break;
        case 0x0F: memcpy(buf, dout.data(), 512); break;
        case 0x08: case 0xE5: case 0x05:
            for (int i = 0; i < n; i++) {
                int l = l0 + i;
                chs_of(l, c, h, s);
                if (l >= LMAX) return err(0x21, true, c, h, s);
                if (op == 0x05) continue;
                if (bad_rd.count(l)) return err(0x11, true, c, h, s);
                r.din.insert(r.din.end(), &img[(size_t)l * 512], &img[(size_t)l * 512] + 512);
                if (op == 0xE5) r.din.insert(r.din.end(), 4, 0);
                memcpy(buf, &img[(size_t)l * 512], 512);
                r.sectors++;
            }
            break;
        case 0x0A: case 0xE6: {
            int len = op == 0xE6 ? 516 : 512, bad = -1;
            for (int i = 0; i < n; i++) {
                int l = l0 + i;
                if (l >= LMAX) {
                    if (bad >= 0) break;
                    chs_of(l, c, h, s);
                    return err(0x21, true, c, h, s);
                }
                memcpy(buf, &dout[(size_t)i * len], 512);
                if (bad_wr.count(l)) { if (bad < 0) bad = l; }
                else memcpy(&img[(size_t)l * 512], buf, 512);
                r.sectors++;
            }
            if (bad >= 0) { chs_of(bad, c, h, s); return err(0x03, true, c, h, s); }
            break;
        }
        case 0x04: case 0x06: case 0x07: {
            ilv = ccb[4];
            int a = op == 0x04 ? 0 : l0, b = op == 0x04 ? LMAX : l0 + 17, bad = -1;
            for (int l = a; l < b; l++) {
                if (bad_wr.count(l)) { if (bad < 0) bad = l; }
                else memcpy(&img[(size_t)l * 512], buf, 512);
            }
            if (bad >= 0) {
                chs_of(bad, c, h, s);
                if (op != 0x04) { c = cyl; h = head; s = bad - l0; }
                return err(0x03, true, c, h, s);
            }
            break;
        }
        default: break;     // 00 01 0B 0C E0 E3 E4
        }
        return r;
    }
};

// ------------------------------------------------------------ the simulation
struct Sim {
    Vxta_card *t;
    uint64_t cyc = 0, t0 = 0;
    std::mt19937 rng;
    std::vector<uint8_t> img;               // the backend's image (the DUT's medium)
    Ref ref;

    // the backend
    struct {
        double lat_us_min = 20, lat_us_max = 300;
        int byte_gap_max = 3;
        int state = 0, cnt = 0;
        uint64_t when = 0;
        uint32_t lba = 0;
        bool wr = false, err = false, prev_req = false;
        std::vector<uint8_t> wbuf;
        int reads = 0, writes = 0;
        std::vector<std::pair<uint32_t, uint64_t>> log;     // (LBA | write << 31, request clk)
    } be;

    // channel 3 of the 8237: single transfers
    struct {
        bool on = false, to_mem = false;
        std::vector<uint8_t> buf;
        size_t pos = 0, count = 0;
        int st = 0;
        uint64_t when = 0;
        std::vector<uint64_t> first, last;  // per byte: DRQ rise, strobe end
        bool drq_d = false;
        int double_req = 0;
    } dma;
    bool cpu_cycle = false;
    uint64_t irq_rise = 0;
    bool irq_d = false;

    Sim(uint32_t seed) : rng(seed) {
        img.resize((size_t)LMAX * 512);
        for (size_t i = 0; i < img.size(); i++) {
            uint32_t x = (uint32_t)i * 2654435761u ^ seed;
            x ^= x >> 13; x *= 0x5bd1e995u; x ^= x >> 15;
            img[i] = (uint8_t)x;
        }
        ref.img = img;
        t = new Vxta_card;
        t->clk = 0; t->reset = 1;
        t->isa_ior_n = 1; t->isa_iow_n = 1; t->isa_aen = 0; t->isa_dack_n = 0xF;
        t->isa_addr = 0; t->isa_dout = 0;
        t->enable = 1; t->present = 1;
        t->sp_rd_valid = 0; t->sp_wr_ready = 0; t->sp_done = 0; t->sp_err = 0;
        for (int i = 0; i < 20; i++) tick();
        t->reset = 0;
        t0 = cyc;
    }
    int rnd(int a, int b) { return std::uniform_int_distribution<int>(a, b)(rng); }
    bool irq() const { return (t->isa_irq >> 3) & 1; }      // IRQ5 = bit 5 of [7:2]
    bool drq() const { return (t->isa_drq >> 2) & 1; }      // DRQ3 = bit 3 of [3:1]

    void tick() {
        backend();
        dma_step();
        t->clk = 0; t->eval();
        t->clk = 1; t->eval();
        cyc++;
        if (irq() && !irq_d) irq_rise = cyc;
        irq_d = irq();
        if (drq() && !dma.drq_d && dma.on && dma.pos < dma.count) dma.first[dma.pos] = cyc;
        dma.drq_d = drq();
    }
    void run_us(double us) { uint64_t e = cyc + us2clk(us); while (cyc < e) tick(); }

    // ---------------------------------------------------- backend model
    void backend() {
        auto &b = be;
        t->sp_done = 0; t->sp_err = 0; t->sp_rd_valid = 0; t->sp_wr_ready = 0;
        bool req = t->sp_req;
        double lat = b.lat_us_min + (b.lat_us_max - b.lat_us_min) * std::uniform_real_distribution<double>(0, 1)(rng);
        if (b.state == 0 && req && !b.prev_req) {
            b.wr = t->sp_write; b.lba = t->sp_lba;
            (b.wr ? b.writes : b.reads)++;
            b.log.push_back({b.lba | (b.wr ? 0x80000000u : 0), cyc});
            CHECK(b.lba < (uint32_t)LMAX, "backend: LBA %u beyond the image", b.lba);
            b.err = b.lba >= (uint32_t)LMAX || (b.wr ? ref.bad_wr.count(b.lba) : ref.bad_rd.count(b.lba));
            b.cnt = 0; b.wbuf.clear();
            b.state = 1;
            b.when = cyc + us2clk(lat);
            if (verbose) printf("[%.1f us] backend %s lba %u\n", clk2us(cyc), b.wr ? "write" : "read", b.lba);
        }
        b.prev_req = req;
        switch (b.state) {
        case 1:
            if (b.wr || cyc >= b.when) b.state = 2;
            break;
        case 2:
            if (!b.wr) {
                if (b.err) { t->sp_done = 1; t->sp_err = 1; b.state = 4; break; }
                if (rnd(0, b.byte_gap_max) == 0) {
                    t->sp_rd_valid = 1;
                    t->sp_rd_data = img[(size_t)b.lba * 512 + b.cnt];
                    if (++b.cnt == 512) { t->sp_done = 1; b.state = 4; }
                }
            } else if (t->sp_wr_valid && rnd(0, b.byte_gap_max) == 0) {
                t->sp_wr_ready = 1;
                b.wbuf.push_back(t->sp_wr_data);
                if (b.wbuf.size() == 512) { b.state = 3; b.when = cyc + us2clk(lat); }
            }
            break;
        case 3:
            if (cyc >= b.when) {
                if (!b.err) memcpy(&img[(size_t)b.lba * 512], b.wbuf.data(), 512);
                t->sp_done = 1; t->sp_err = b.err; b.state = 4;
            }
            break;
        case 4:
            if (!req) b.state = 0;
            break;
        }
    }

    // ---------------------------------------------------- the 8237, channel 3
    void dma_start(bool to_mem, const std::vector<uint8_t> &src, size_t count) {
        dma.on = true; dma.to_mem = to_mem; dma.pos = 0; dma.count = count; dma.st = 0;
        dma.buf = src; dma.buf.resize(count);
        dma.first.assign(count + 1, 0); dma.last.assign(count + 1, 0);
        dma.drq_d = drq();
        if (drq()) dma.first[0] = cyc;
    }
    void dma_step() {
        auto &d = dma;
        switch (d.st) {
        case 0:
            if (d.on && d.pos < d.count && drq() && !cpu_cycle) { d.st = 1; d.when = cyc + 3 * C; }
            break;
        case 1:     // HLDA: AEN, DACK3, the address
            if (cyc >= d.when) {
                CHECK(drq(), "DMA: DRQ3 dropped before DACK3 (byte %zu)", d.pos);
                t->isa_aen = 1; t->isa_dack_n = 0x7; t->isa_addr = 0x20000 + d.pos;
                d.st = 2; d.when = cyc + C;
            }
            break;
        case 2:     // the strobes
            if (cyc >= d.when) {
                if (d.to_mem) t->isa_ior_n = 0;
                else { t->isa_iow_n = 0; t->isa_dout = d.buf[d.pos]; }
                d.st = 3; d.when = cyc + 2 * C;
            }
            break;
        case 3:
            if (cyc >= d.when) {
                if (drq()) d.double_req++;
                if (d.to_mem) { d.buf[d.pos] = t->isa_dsel ? t->isa_din : 0xFF; t->isa_ior_n = 1; }
                else t->isa_iow_n = 1;
                d.last[d.pos] = cyc;
                d.pos++;
                d.st = 4; d.when = cyc + C;
            }
            break;
        case 4:
            if (cyc >= d.when) {
                t->isa_aen = 0; t->isa_dack_n = 0xF;
                d.st = 5; d.when = cyc + 4 * C;    // the CPU's bus cycle in between
            }
            break;
        case 5:
            if (cyc >= d.when) d.st = 0;
            break;
        }
    }
    void dma_idle() { while (dma.st != 0) tick(); }

    // ---------------------------------------------------- CPU I/O cycles
    void io_write(int port, int val, int gap = 2 * C) {
        dma_idle();
        cpu_cycle = true;
        t->isa_addr = port; t->isa_aen = 0;
        for (int i = 0; i < C + C / 3; i++) tick();
        t->isa_dout = val;
        t->isa_iow_n = 0;
        for (int i = 0; i < 8 * C / 3; i++) tick();
        t->isa_iow_n = 1;
        cpu_cycle = false;
        for (int i = 0; i < C + gap; i++) tick();
    }
    int io_read(int port, int gap = 2 * C) {
        dma_idle();
        cpu_cycle = true;
        t->isa_addr = port; t->isa_aen = 0;
        for (int i = 0; i < 2 * C / 3; i++) tick();
        t->isa_ior_n = 0;
        int first = -1; bool stable = true;
        for (int i = 0; i < 3 * C; i++) {
            tick();
            if (i >= 1) { int v = t->isa_dsel ? t->isa_din : 0xFF; if (first < 0) first = v; else if (v != first) stable = false; }
        }
        CHECK(stable, "I/O read %03X: data not stable during IOR", port);
        int v = t->isa_dsel ? t->isa_din : 0xFF;
        t->isa_ior_n = 1;
        cpu_cycle = false;
        for (int i = 0; i < C + gap; i++) tick();
        return v;
    }
    int status() { return io_read(PORT + 1); }

    // ---------------------------------------------------- spindle and timing model
    // slot boundary n (n >= 1) begins slot n mod 27
    uint64_t pulse(uint64_t n) const { return t0 + (n * REV_CLK + 26) / 27; }
    // the end of slot p, for the first start of slot p after `arm`; *amb if
    // that start is within `tol` of arm (the next revolution is then also right)
    uint64_t platter_end(uint64_t arm, int p, uint64_t tol, bool *amb) const {
        uint64_t n = arm > t0 ? (arm - t0) * 27 / REV_CLK : 0;
        while (n % 27 != (uint64_t)p || n == 0 || pulse(n) <= arm) n++;
        if (amb) *amb = pulse(n) < arm + tol;
        return pulse(n + 1);
    }
    uint64_t platter_track(uint64_t arm, uint64_t tol, bool *amb) const {     // index to index
        uint64_t n = arm > t0 ? (arm - t0) * 27 / REV_CLK : 0;
        while (n % 27 != 0 || n == 0 || pulse(n) <= arm) n++;
        if (amb) *amb = pulse(n) < arm + tol;
        return pulse(n + 27);
    }

    // ---------------------------------------------------- a command
    struct Out {
        bool ok = true;                 // the handshake worked
        uint8_t comp = 0xFF;
        std::vector<uint8_t> din;
        uint64_t t_ccb = 0, t_stat = 0; // the last CCB byte's strobe end, the status phase (IRQ)
        int polls = 0;
    };
    // mode: 0 PIO, no interrupt (mask FC); 1 interrupt, no data or PIO data (mask 02);
    // 2 DMA + interrupt (mask 03)
    Out command(const uint8_t *ccb, int mode, size_t din_len, const std::vector<uint8_t> &dout,
                double max_ms = 200, bool no_mask = false) {
        Out o;
        if (!no_mask) io_write(PORT + 3, mode == 2 ? 0x03 : mode == 1 ? 0x02 : 0xFC);
        int st = 0;
        for (int i = 0; i < 100; i++) {
            io_write(PORT + 2, 0);
            st = status();
            if ((st & 0x0D) == 0x0D) break;
        }
        CHECK(st == (BSY | CD | REQ), "select: status %02X", st);
        if (st != (BSY | CD | REQ)) { o.ok = false; return o; }
        for (int i = 0; i < 6; i++) {
            uint64_t e = cyc + us2clk(1000);
            do st = status(); while (!(st & REQ) && (st & BSY) && cyc < e);
            CHECK(st == (BSY | CD | REQ), "CCB byte %d: status %02X", i, st);
            if (st != (BSY | CD | REQ)) { o.ok = false; return o; }
            io_write(PORT, ccb[i], 0);
            if (i == 5) o.t_ccb = cyc - C;      // io_write ends C clk after the strobe
            else {
                // REQ stays low for CCB_US after each byte
                st = status();
                CHECK(st == (BSY | CD), "CCB byte %d: status %02X right after it", i, st);
            }
            for (int k = 0; k < 2 * C; k++) tick();
        }
        uint64_t e = cyc + us2clk(max_ms * 1000);
        if (mode == 2) {
            dma_start(din_len > 0, dout, din_len ? din_len : dout.size());
            while (!irq() && cyc < e) tick();
            dma_idle();
            o.din.assign(dma.buf.begin(), dma.buf.begin() + std::min(dma.pos, din_len));
            dma.on = false;
            CHECK(irq(), "no interrupt within %.0f ms (op %02X)", max_ms, ccb[0]);
            o.t_stat = irq_rise;
            st = status();
            CHECK(st == (IRQ | BSY | CD | IO | REQ), "status phase with interrupt: %02X", st);
            CHECK(dma.double_req == 0, "DRQ3 still high at a strobe's end (%d times)", dma.double_req);
            dma.double_req = 0;
            io_write(PORT + 3, 0xFC);
        } else {
            size_t ni = 0, no = 0;
            for (;;) {
                st = status();
                if ((st & 0x0F) == (BSY | CD | IO | REQ) || cyc >= e || !(st & BSY)) break;
                if (!(st & REQ)) continue;
                if (st & IO) {
                    CHECK(st == (BSY | IO | REQ) && ni < din_len, "data in: status %02X, byte %zu of %zu", st, ni, din_len);
                    o.din.push_back(io_read(PORT, 0)); ni++;
                } else {
                    CHECK(st == (BSY | REQ) && no < dout.size(), "data out: status %02X, byte %zu of %zu", st, no, dout.size());
                    io_write(PORT, no < dout.size() ? dout[no] : 0, 0); no++;
                }
            }
            if (mode == 1) {
                while (!irq() && cyc < e) tick();
                CHECK(irq(), "no interrupt within %.0f ms (op %02X)", max_ms, ccb[0]);
                o.t_stat = irq_rise;
                st = status();
                CHECK(st == (IRQ | BSY | CD | IO | REQ), "status phase with interrupt: %02X", st);
                io_write(PORT + 3, 0xFC);
            }
            st = status();
        }
        st = status();
        CHECK(st == (BSY | CD | IO | REQ), "status phase: %02X (op %02X)", st, ccb[0]);
        if (st != (BSY | CD | IO | REQ)) { o.ok = false; return o; }
        o.comp = io_read(PORT, 0);
        do { st = status(); o.polls++; } while ((st & BSY) && o.polls < 1000);
        CHECK(st == 0 && o.polls < 100, "bus free after the completion byte: status %02X after %d polls", st, o.polls);
        CHECK(!irq(), "IRQ5 after the completion byte");
        return o;
    }
};

// ------------------------------------------------------------ helpers for the tests
static void mk_ccb(uint8_t *c, int op, int drv, int cyl, int head, int sec, int n, int ctl = 5) {
    c[0] = op; c[1] = (drv << 5) | head; c[2] = ((cyl >> 8) << 6) | sec; c[3] = cyl & 0xFF; c[4] = n; c[5] = ctl;
}

// run a command on DUT and model, compare completion, data, sense
static Sim::Out run(Sim &s, const uint8_t *ccb, int mode, const std::vector<uint8_t> &dout, const char *what,
                    double max_ms = 200) {
    Ref::Res r = s.ref.exec(ccb, dout);
    Sim::Out o = s.command(ccb, mode, r.din.size() ? r.din.size() : (ccb[0] == 0x08 || ccb[0] == 0xE5 || ccb[0] == 0x0E ? 1 : 0),
                           dout, max_ms);
    CHECK(o.comp == r.comp, "%s: completion %02X, model %02X", what, o.comp, r.comp);
    CHECK(o.din.size() >= r.din.size() && std::equal(r.din.begin(), r.din.end(), o.din.begin()),
          "%s: data in (%zu bytes, model %zu)%s", what, o.din.size(), r.din.size(),
          [&] { static char b[64]; size_t i = 0; while (i < r.din.size() && i < o.din.size() && o.din[i] == r.din[i]) i++;
                snprintf(b, sizeof b, ", first difference at %zu", i); return b; }());
    if (verbose) printf("     %s: comp %02X, %zu bytes, IRQ at %.1f us after the CCB\n", what, o.comp, o.din.size(),
                        clk2us(o.t_stat - o.t_ccb));
    return o;
}
static void check_sense(Sim &s, const char *what) {
    uint8_t c[6]; mk_ccb(c, 0x03, 0, 0, 0, 0, 0);
    uint8_t exp[4]; memcpy(exp, s.ref.sense, 4);
    Sim::Out o = run(s, c, 0, {}, what);
    CHECK(o.din.size() == 4, "%s: 4 sense bytes", what);
    if (o.din.size() == 4)
        CHECK(!memcmp(o.din.data(), exp, 4), "%s: sense %02X %02X %02X %02X, model %02X %02X %02X %02X", what,
              o.din[0], o.din[1], o.din[2], o.din[3], exp[0], exp[1], exp[2], exp[3]);
}
static void check_image(Sim &s, const char *what) {
    size_t i = 0;
    while (i < s.img.size() && s.img[i] == s.ref.img[i]) i++;
    CHECK(i == s.img.size(), "%s: image differs from the model at LBA %zu byte %zu", what, i / 512, i % 512);
}
static std::vector<uint8_t> pattern(size_t n, int salt) {
    std::vector<uint8_t> v(n);
    for (size_t i = 0; i < n; i++) v[i] = (uint8_t)(i * 31 + (i >> 9) * 7 + salt);
    return v;
}

// The timing of a sector command, from the observed DMA strobes:
//   reads:  sector i's first byte = the end of its slot, first passed after
//           max(seek done, the host took sector i-1)
//   writes: sector i+1's first byte = the end of sector i's slot, first
//           passed after max(seek done, the host sent sector i)
// The seek to sector i's cylinder starts at the end of sector i-1's slot, for
// sector 0 at the end of the command overhead.
struct Tm { int cyl_before; int ilv; };
static int check_timing(Sim &s, const Sim::Out &o, int l0, int n, bool wr, int len, const Tm &tm, const char *what) {
    std::vector<int> lay = layout(tm.ilv);
    const uint64_t tol = us2clk(3);
    uint64_t start = o.t_ccb + us2clk(CMD_US);
    // within a sector, DRQ comes back BYTE_CLK after a byte's strobe
    for (int i = 0; i < n; i++)
        for (int b = 1; b < len; b++) {
            size_t k = (size_t)i * len + b;
            if (s.dma.first[k] < s.dma.last[k - 1] + BYTE_CLK) {
                CHECK(false, "%s: byte %zu: DRQ %.2f us after the previous strobe", what, k,
                      clk2us(s.dma.first[k] - s.dma.last[k - 1]));
                return -1;
            }
        }
    int cur = tm.cyl_before;
    uint64_t seek_from = start;
    for (int i = 0; i < n; i++) {
        int l = l0 + i, pc = l / 54, p = lay[l % 27];
        uint64_t seek_done = seek_from + (pc != cur ? us2clk(seek_us(std::abs(pc - cur))) : 0);
        cur = pc;
        uint64_t host = wr ? s.dma.last[(size_t)i * len + len - 1] : (i ? s.dma.last[(size_t)i * len - 1] : 0);
        uint64_t arm = std::max(seek_done, host);
        bool amb = false;
        uint64_t exp = s.platter_end(arm, p, tol, &amb);
        // the observation: reads: sector i's first DRQ; writes: sector i+1's first DRQ
        uint64_t obs;
        if (!wr) obs = s.dma.first[(size_t)i * len];
        else if (i + 1 < n) obs = s.dma.first[(size_t)(i + 1) * len];
        else {
            obs = 0;
            for (auto &e : s.be.log) if (e.first == (0x80000000u | l) && e.second >= exp - tol) { obs = e.second; break; }
        }
        bool ok = obs >= exp && obs < exp + tol;
        if (!ok && amb) { exp += REV_CLK; ok = obs >= exp && obs < exp + tol; }
        if (!ok && wr && i + 1 == n) ok = obs >= exp && obs < exp + us2clk(400);    // the writer may be busy
        CHECK(ok, "%s: sector %d (LBA %d, cyl %d, slot %d): at %.1f us, the model says %.1f us", what, i, l, pc, p,
              clk2us(obs - o.t_ccb), clk2us(exp - o.t_ccb));
        if (!ok) return -1;
        seek_from = exp;
    }
    return 0;
}

// a time in us against an expectation, the card's us timers allowing ~1 us less
static bool near(double us, double exp) { return us >= exp - 3 && us < exp + 5; }

// The possible end times of a chain of platter operations without host
// transfers (verify, format): steps of (physical cylinder, slot or -1 for a
// whole track from the index). Where an arm time lies within the tolerance of
// the slot's start, both outcomes are followed.
static void chain(const Sim &s, uint64_t t, int cur, const std::vector<std::pair<int, int>> &steps, size_t i,
                  std::vector<uint64_t> &out) {
    const uint64_t tol = us2clk(3);
    if (i == steps.size()) { out.push_back(t); return; }
    int pc = steps[i].first, p = steps[i].second;
    if (pc != cur) t += us2clk(seek_us(std::abs(pc - cur)));
    bool amb = false;
    uint64_t e = p < 0 ? s.platter_track(t, tol, &amb) : s.platter_end(t, p, tol, &amb);
    chain(s, e, pc, steps, i + 1, out);
    if (amb && out.size() < 64) chain(s, e + REV_CLK, pc, steps, i + 1, out);
}
static bool in_chain(const std::vector<uint64_t> &ends, uint64_t obs, uint64_t slack, uint64_t *best) {
    *best = ends.empty() ? 0 : ends[0];
    for (uint64_t e : ends) if (obs >= e && obs < e + slack) { *best = e; return true; }
    return false;
}

static void recal(Sim &s) {
    uint8_t c[6];
    mk_ccb(c, 0x01, 0, 0, 0, 0, 0);
    run(s, c, 1, {}, "recalibrate");
}

// ------------------------------------------------------------ tests
static void t_power(Sim &s) {
    int st = s.status();
    CHECK(st == 0x00, "status during the power-on reset %02X", st);
    CHECK(s.io_read(PORT + 2) == 0xFF, "configuration register");
    CHECK(s.io_read(PORT + 3) == 0xFF, "323h is not readable");
    // a select during the reset is ignored
    s.io_write(PORT + 2, 0);
    CHECK(s.status() == 0x00, "select during the reset");
    s.run_us(RESET_US + 50);
    CHECK(s.status() == 0x00, "status after the reset");
    // JMP208 open: everything floats
    s.t->enable = 0;
    for (int p = 0; p < 4; p++) CHECK(s.io_read(PORT + p) == 0xFF, "JMP208 open: %03X reads %02X", PORT + p, s.io_read(PORT + p));
    s.io_write(PORT + 3, 0x03);
    s.io_write(PORT + 2, 0);
    CHECK(!s.irq() && !s.drq(), "JMP208 open: no IRQ, no DRQ");
    s.t->enable = 1;
    s.io_write(PORT + 1, 0);
    s.run_us(RESET_US + 50);
    // AEN (DMA) cycles do not select the ports
    s.t->isa_aen = 1; s.t->isa_addr = PORT + 2;
    for (int i = 0; i < 10; i++) s.tick();
    s.t->isa_ior_n = 0;
    for (int i = 0; i < 20; i++) s.tick();
    CHECK(!s.t->isa_dsel, "AEN: no I/O decode");
    s.t->isa_ior_n = 1; s.t->isa_aen = 0;
    for (int i = 0; i < 20; i++) s.tick();
    // the window: 320-323 only
    CHECK(s.io_read(0x324) == 0xFF && s.io_read(0x31F) == 0xFF && s.io_read(0x726) == 0xFF, "outside 320-323");
}

// the Commodore BIOS's detection (doc/xta.md section 6)
static void t_detect(Sim &s) {
    // controller reset, ~5 ms, status: no DRQ, no IRQ; the reset clears the mask
    s.io_write(PORT + 3, 0x03);
    s.io_write(PORT + 1, 0);
    CHECK(s.status() == 0x00, "status right after a reset");
    s.run_us(5000);
    CHECK((s.status() & 0x30) == 0, "after the reset: DRQ/IRQ");
    // recalibrate without writing the mask (it is 00 after the reset): poll for 0Fh
    uint8_t c[6];
    mk_ccb(c, 0x01, 0, 0, 0, 0, 0);
    Sim::Out o = s.command(c, 0, 0, {}, 200, true);
    s.ref.exec(c, {});
    CHECK(o.comp == 0x00, "detection recalibrate: %02X", o.comp);
    mk_ccb(c, 0xE4, 0, 0, 0, 0, 0);
    o = run(s, c, 1, {}, "controller diagnostic");
    CHECK(near(clk2us(o.t_stat - o.t_ccb), CMD_US + DIAG_US), "E4 took %.1f us", clk2us(o.t_stat - o.t_ccb));
    mk_ccb(c, 0x00, 0, 0, 0, 0, 0);
    o = run(s, c, 1, {}, "test ready drive 0");
    CHECK(near(clk2us(o.t_stat - o.t_ccb), CMD_US), "test ready took %.1f us", clk2us(o.t_stat - o.t_ccb));
    // reset: recalibrate both drives, initialize both
    s.io_write(PORT + 1, 0);
    s.run_us(5000);
    mk_ccb(c, 0x01, 0, 0, 0, 0, 0);
    run(s, c, 1, {}, "recalibrate drive 0");
    mk_ccb(c, 0x01, 1, 0, 0, 0, 0);
    run(s, c, 1, {}, "recalibrate drive 1 (fails)");
    std::vector<uint8_t> par = {0x02, 0x67, 0x04, 0x02, 0x68, 0x02, 0x68, 0x0B};
    mk_ccb(c, 0x0C, 0, 0, 0, 0, 0);
    run(s, c, 0, par, "initialize drive 0");
    mk_ccb(c, 0x0C, 1, 0, 0, 0, 0);
    run(s, c, 0, par, "initialize drive 1");
    mk_ccb(c, 0x01, 0, 0, 0, 0, 0);
    run(s, c, 1, {}, "recalibrate drive 0 (counts the drive)");
    mk_ccb(c, 0x00, 1, 0, 0, 0, 0);
    run(s, c, 1, {}, "test ready drive 1");
    mk_ccb(c, 0x01, 1, 0, 0, 0, 0);
    run(s, c, 1, {}, "recalibrate drive 1");
    check_sense(s, "sense after drive 1");
    check_sense(s, "sense cleared");
    // the other controller commands on drive 1, the drive commands fail
    mk_ccb(c, 0xE0, 1, 0, 0, 0, 0);
    run(s, c, 1, {}, "RAM diagnostic drive 1");
    mk_ccb(c, 0xE3, 1, 0, 0, 0, 0);
    run(s, c, 1, {}, "drive diagnostic drive 1");
    mk_ccb(c, 0x08, 1, 0, 0, 0, 1);
    run(s, c, 2, {}, "read drive 1");
    check_sense(s, "sense: read drive 1");
    mk_ccb(c, 0xE3, 0, 0, 0, 0, 0);
    o = run(s, c, 1, {}, "drive diagnostic");
    CHECK(near(clk2us(o.t_stat - o.t_ccb), CMD_US + DIAG_US), "E3 took %.1f us", clk2us(o.t_stat - o.t_ccb));
    // the select restarts the command phase: a CCB cut short, then a full one
    s.io_write(PORT + 3, 0x02);
    s.io_write(PORT + 2, 0);
    s.io_write(PORT, 0x00);
    s.run_us(20);
    s.io_write(PORT, 0x20);
    mk_ccb(c, 0x00, 0, 0, 0, 0, 0);
    run(s, c, 1, {}, "test ready after a cut CCB");
    // the mask: IRQ5 only with bit 1, status bit 5 with it
    mk_ccb(c, 0x00, 0, 0, 0, 0, 0);
    o = s.command(c, 0, 0, {});
    CHECK(!s.irq(), "no IRQ with mask FC");
}

static void t_spinup(Sim &s) {
    // a new medium: the drive spins up for SPINUP_MS
    s.t->present = 0;
    s.run_us(10);
    uint8_t c[6];
    s.ref.ready = false;
    mk_ccb(c, 0x00, 0, 0, 0, 0, 0);
    run(s, c, 1, {}, "test ready without a medium");
    check_sense(s, "sense: not ready");
    mk_ccb(c, 0x08, 0, 0, 0, 0, 1);
    run(s, c, 2, {}, "read without a medium");
    mk_ccb(c, 0x0E, 0, 0, 0, 0, 0);
    s.ref.ready = true;
    run(s, c, 2, {}, "read buffer without a medium (the controller's)");
    s.t->present = 1;
    uint64_t t_in = s.cyc;
    s.ref.ready = false;
    mk_ccb(c, 0x00, 0, 0, 0, 0, 0);
    run(s, c, 1, {}, "test ready while spinning up");
    // poll as the BIOS does until it answers
    uint64_t t_rdy = 0;
    for (int i = 0; i < 100 && !t_rdy; i++) {
        uint8_t comp = s.command(c, 1, 0, {}).comp;
        if (comp == 0) t_rdy = s.cyc;
    }
    s.ref.ready = true;
    double ms = clk2us(t_rdy - t_in) / 1000;
    CHECK(t_rdy && ms > SPINUP_MS - 1.2 && ms < SPINUP_MS + 1.5, "spin-up took %.2f ms", ms);
    // a bus reset does not stop the drive
    s.t->reset = 1;
    for (int i = 0; i < 20; i++) s.tick();
    s.t->reset = 0;
    s.t0 = s.cyc;                       // the spindle model restarts with RESET DRV [A]
    s.run_us(RESET_US + 10);
    run(s, c, 1, {}, "test ready after RESET DRV");
}

// sector reads and writes with the timing model; returns the physical cylinder after
static int s_cyl = 0;
static void rd(Sim &s, int l0, int n, int mode, const char *what, int op = 0x08, bool timing = true) {
    int c, h, sc; chs_of(l0, c, h, sc);
    uint8_t ccb[6]; mk_ccb(ccb, op, 0, c, h, sc, n & 0xFF);
    Sim::Out o = run(s, ccb, mode, {}, what, 6000);
    int nn = n ? n : 256;
    if (mode == 2 && timing && o.comp == 0) check_timing(s, o, l0, nn, false, op == 0xE5 ? 516 : 512, {s_cyl, s.ref.ilv}, what);
    if (o.comp == 0) s_cyl = (l0 + nn - 1) / 54;
}
static void wr(Sim &s, int l0, int n, int mode, int salt, const char *what, int op = 0x0A, bool timing = true) {
    int c, h, sc; chs_of(l0, c, h, sc);
    uint8_t ccb[6]; mk_ccb(ccb, op, 0, c, h, sc, n & 0xFF);
    int nn = n ? n : 256, len = op == 0xE6 ? 516 : 512;
    std::vector<uint8_t> d = pattern((size_t)nn * len, salt);
    Sim::Out o = run(s, ccb, mode, d, what, 6000);
    if (mode == 2 && timing && o.comp == 0) check_timing(s, o, l0, nn, true, len, {s_cyl, s.ref.ilv}, what);
    if (o.comp == 0) s_cyl = (l0 + nn - 1) / 54;
}

static void t_rw(Sim &s) {
    uint8_t c[6];
    mk_ccb(c, 0x01, 0, 0, 0, 0, 0);
    run(s, c, 1, {}, "recalibrate");
    s_cyl = 0;
    // the BIOS's PIO read of sector 0 (mask FC)
    rd(s, 0, 1, 0, "PIO read of sector 0");
    rd(s, 0, 1, 2, "DMA read of sector 0");
    rd(s, 1, 17, 2, "read 17 (the rest of C0 H0, into H1)");
    rd(s, 20, 40, 2, "read 40 across a physical track and cylinder");
    rd(s, 68 * 300 + 5, 3, 2, "read 3 at cylinder 300");
    rd(s, 68 * 614, 68, 2, "read cylinder 614 (the last)");
    rd(s, 1000, 0, 2, "read 256 (count 0)");
    wr(s, 5000, 1, 2, 1, "write 1");
    rd(s, 5000, 1, 2, "read it back");
    wr(s, 5010, 30, 2, 2, "write 30 across tracks");
    rd(s, 5010, 30, 2, "read them back");
    wr(s, 7000, 2, 0, 3, "PIO write 2");
    rd(s, 7000, 2, 0, "PIO read 2");
    rd(s, 6990, 15, 2, "read across the PIO-written sectors");
    rd(s, 300, 4, 2, "read long", 0xE5);
    wr(s, 400, 3, 2, 4, "write long", 0xE6);
    rd(s, 399, 5, 2, "read around the long write");
    // verify: timing like a read without data
    {
        int l0 = 9000, n = 10, cc, h, sc; chs_of(l0, cc, h, sc);
        mk_ccb(c, 0x05, 0, cc, h, sc, n);
        Sim::Out o = run(s, c, 1, {}, "verify 10");
        std::vector<int> lay = layout(s.ref.ilv);
        std::vector<std::pair<int, int>> steps;
        for (int i = 0; i < n; i++) steps.push_back({(l0 + i) / 54, lay[(l0 + i) % 27]});
        std::vector<uint64_t> ends;
        chain(s, o.t_ccb + us2clk(CMD_US), s_cyl, steps, 0, ends);
        uint64_t best;
        CHECK(in_chain(ends, o.t_stat, us2clk(3), &best), "verify: done at %.1f us, the model %.1f us",
              clk2us(o.t_stat - o.t_ccb), clk2us(best - o.t_ccb));
        int cur = (l0 + n - 1) / 54;
        s_cyl = cur;
    }
    check_image(s, "after the reads and writes");
    // the backend read ahead never went beyond what the command needs
    CHECK(s.dma.double_req == 0, "DRQ held over a strobe");
}

static void t_seek(Sim &s) {
    uint8_t c[6];
    int cyls[] = {0, 1, 2, 130, 391, 614, 0, 307, 306};
    int cur = s_cyl;
    for (int lc : cyls) {
        mk_ccb(c, 0x0B, 0, lc, 0, 0, 0);
        Sim::Out o = run(s, c, 1, {}, "seek");
        int pc = (lc * 68) / 54;
        double us = clk2us(o.t_stat - o.t_ccb) - CMD_US, exp = seek_us(std::abs(pc - cur));
        CHECK(near(us, exp), "seek from cylinder %d to %d (logical %d): %.1f us, expected %.1f", cur, pc, lc,
              us, exp);
        cur = pc;
    }
    // recalibrate: a seek to cylinder 0
    mk_ccb(c, 0x01, 0, 0, 0, 0, 0);
    Sim::Out o = run(s, c, 1, {}, "recalibrate");
    double us = clk2us(o.t_stat - o.t_ccb) - CMD_US, exp = seek_us(cur);
    CHECK(near(us, exp), "recalibrate from %d: %.1f us, expected %.1f", cur, us, exp);
    s_cyl = 0;
    // 5 / 39 / 65 ms (doc/xta.md section 8)
    CHECK(std::fabs(seek_us(1) - 5000) < 1 && std::fabs(seek_us(261) - 38880) < 1 && std::fabs(seek_us(781) - 65340) < 1,
          "the seek formula");
}

static void t_buffer(Sim &s) {
    uint8_t c[6];
    std::vector<uint8_t> d = pattern(512, 77);
    mk_ccb(c, 0x0F, 0, 0, 0, 0, 0);
    run(s, c, 2, d, "write sector buffer (DMA)");
    mk_ccb(c, 0x0E, 0, 0, 0, 0, 0);
    run(s, c, 2, {}, "read sector buffer (DMA)");
    d = pattern(512, 99);
    mk_ccb(c, 0x0F, 0, 0, 0, 0, 0);
    run(s, c, 0, d, "write sector buffer (PIO)");
    mk_ccb(c, 0x0E, 0, 0, 0, 0, 0);
    run(s, c, 0, {}, "read sector buffer (PIO)");
    // a read leaves its last sector in the buffer
    rd(s, 2222, 3, 2, "read 3");
    mk_ccb(c, 0x0E, 0, 0, 0, 0, 0);
    run(s, c, 2, {}, "read sector buffer after a read");
    wr(s, 3333, 2, 2, 5, "write 2");
    mk_ccb(c, 0x0E, 0, 0, 0, 0, 0);
    run(s, c, 2, {}, "read sector buffer after a write");
    mk_ccb(c, 0x0D, 0, 0, 0, 0, 0);
    run(s, c, 0, {}, "read ECC burst length");
}

static void t_format(Sim &s) {
    uint8_t c[6];
    // format track C100 H2 with the buffer's data, interleave 1
    std::vector<uint8_t> d = pattern(512, 0x6C);
    mk_ccb(c, 0x0F, 0, 0, 0, 0, 0);
    run(s, c, 2, d, "write buffer for the format");
    mk_ccb(c, 0x06, 0, 100, 2, 0, 1);
    Sim::Out o = run(s, c, 1, {}, "format track C100 H2", 400);
    // logical track 402 = LBA 6834-6850: physical tracks 253 (from sector 3) and 254
    {
        int l0 = (100 * 4 + 2) * 17;
        std::vector<std::pair<int, int>> steps;
        for (int tr = l0 / 27; tr <= (l0 + 16) / 27; tr++) steps.push_back({tr / 2, -1});
        std::vector<uint64_t> ends;
        chain(s, o.t_ccb + us2clk(CMD_US), s_cyl, steps, 0, ends);
        uint64_t best;
        CHECK(in_chain(ends, o.t_stat, us2clk(400 * 17), &best), "format track: done at %.1f us, the tracks end at %.1f us",
              clk2us(o.t_stat - o.t_ccb), clk2us(best - o.t_ccb));
        s_cyl = steps.back().first;
    }
    check_image(s, "format track");
    // interleave 1: with a one-sector buffer every sector costs a revolution
    rd(s, 100 * 68 + 2 * 17 + 5, 6, 2, "read at interleave 1");
    mk_ccb(c, 0x06, 0, 100, 2, 0, 5);
    run(s, c, 1, {}, "format track again, interleave 5", 400);
    s_cyl = (100 * 68 + 2 * 17 + 16) / 54;
    rd(s, 100 * 68 + 2 * 17, 12, 2, "read at interleave 5");
    mk_ccb(c, 0x07, 0, 200, 3, 0, 4);
    run(s, c, 1, {}, "format bad track C200 H3, interleave 4", 400);
    s_cyl = (200 * 68 + 3 * 17 + 16) / 54;
    rd(s, 200 * 68 + 3 * 17, 17, 2, "read the bad track, interleave 4");
    mk_ccb(c, 0x06, 0, 10, 0, 0, 0);
    run(s, c, 1, {}, "format track with interleave 0");
    check_sense(s, "sense: interleave 0");
    mk_ccb(c, 0x06, 0, 10, 0, 0, 27);
    run(s, c, 1, {}, "format track with interleave 27");
    mk_ccb(c, 0x06, 0, 0, 0, 0, 3);
    run(s, c, 1, {}, "format track C0 H0, interleave 3", 400);
    s_cyl = 0;
    check_image(s, "after the formats");
}

static void t_format_drive(Sim &s) {
    uint8_t c[6];
    std::vector<uint8_t> d = pattern(512, 0xE5);
    mk_ccb(c, 0x0F, 0, 0, 0, 0, 0);
    run(s, c, 2, d, "write buffer for the format");
    mk_ccb(c, 0x04, 0, 0, 0, 0, 4);
    Sim::Out o = run(s, c, 1, {}, "format drive, interleave 4", 80000);
    std::vector<std::pair<int, int>> steps;
    for (int tr = 0; tr < 782 * 2; tr++) steps.push_back({tr / 2, -1});
    std::vector<uint64_t> ends;
    chain(s, o.t_ccb + us2clk(CMD_US), s_cyl, steps, 0, ends);
    uint64_t best;
    CHECK(in_chain(ends, o.t_stat, us2clk(400), &best), "format drive: done at %.3f s, the model %.3f s",
          clk2us(o.t_stat - o.t_ccb) / 1e6, clk2us(best - o.t_ccb) / 1e6);
    int cur = 781;
    printf("     format drive: %.2f s\n", clk2us(o.t_stat - o.t_ccb) / 1e6);
    s_cyl = cur;
    check_image(s, "format drive");
    rd(s, 41000, 30, 2, "read after the format, interleave 4");
}

static void t_errors(Sim &s) {
    uint8_t c[6];
    mk_ccb(c, 0x02, 0, 0, 0, 0, 0);
    run(s, c, 1, {}, "invalid command 02");
    check_sense(s, "sense: invalid command");
    mk_ccb(c, 0xFF, 0, 0, 0, 0, 0);
    run(s, c, 1, {}, "invalid command FF");
    mk_ccb(c, 0x08, 0, 615, 0, 0, 1);
    run(s, c, 2, {}, "read cylinder 615");
    check_sense(s, "sense: cylinder 615");
    mk_ccb(c, 0x08, 0, 10, 4, 0, 1);
    run(s, c, 2, {}, "read head 4");
    check_sense(s, "sense: head 4");
    mk_ccb(c, 0x0A, 0, 10, 0, 17, 1);
    run(s, c, 2, pattern(512, 1), "write sector 17");
    check_sense(s, "sense: sector 17");
    mk_ccb(c, 0x0B, 0, 700, 0, 0, 0);
    run(s, c, 1, {}, "seek cylinder 700");
    // past the end: the sectors that exist, then the error at the first that does not
    rd(s, LMAX - 3, 5, 2, "read past the end", 0x08, false);
    check_sense(s, "sense: past the end"); recal(s); s_cyl = 0;
    wr(s, LMAX - 2, 4, 2, 9, "write past the end", 0x0A, false);
    check_sense(s, "sense: write past the end"); recal(s); s_cyl = 0;
    {
        int cc, h, sc; chs_of(LMAX - 2, cc, h, sc);
        mk_ccb(c, 0x05, 0, cc, h, sc, 4);
        run(s, c, 1, {}, "verify past the end");
        check_sense(s, "sense: verify past the end"); recal(s); s_cyl = 0;
    }
    // backend errors
    s.ref.bad_rd.insert(12002);
    rd(s, 12000, 5, 2, "read with a bad sector", 0x08, false);
    check_sense(s, "sense: data error"); recal(s); s_cyl = 0;
    rd(s, 12000, 2, 2, "read before the bad sector");
    s.ref.bad_rd.clear();
    s.ref.bad_wr.insert(13001);
    wr(s, 13000, 3, 2, 11, "write with a bad sector", 0x0A, false);
    check_sense(s, "sense: write fault"); recal(s); s_cyl = 0;
    s.ref.bad_wr.clear();
    check_image(s, "after the errors");
    // a select in the middle of a DMA read: the next command still works
    {
        mk_ccb(c, 0x08, 0, 20, 0, 0, 10);
        s.io_write(PORT + 3, 0x03);
        s.io_write(PORT + 2, 0);
        for (int i = 0; i < 6; i++) { while (!(s.status() & REQ)) ; s.io_write(PORT, c[i]); }
        s.dma_start(true, {}, 5120);
        s.run_us(4000);
        s.dma_idle();
        s.dma.on = false;
        s.io_write(PORT + 2, 0);
        CHECK(s.status() == (BSY | CD | REQ), "select during a read");
        s.io_write(PORT + 1, 0);        // the BIOS would rather reset
        s.run_us(RESET_US + 10);
        recal(s); s_cyl = 0;
        rd(s, 20 * 68, 3, 2, "read after an aborted read");
    }
    // a slow backend (3 ms per sector): slower than the drive, still right
    s.be.lat_us_min = s.be.lat_us_max = 3000;
    rd(s, 15000, 6, 2, "read with a slow backend", 0x08, false);
    wr(s, 15100, 6, 2, 13, "write with a slow backend", 0x0A, false);
    rd(s, 15100, 6, 2, "read back with a slow backend", 0x08, false);
    recal(s); s_cyl = 0;
    s.be.lat_us_min = 20; s.be.lat_us_max = 300;
    check_image(s, "slow backend");
}

static void t_random(Sim &s, int n) {
    for (int i = 0; i < n; i++) {
        int cnt = s.rnd(1, 40);
        int l = s.rnd(0, LMAX - cnt);
        bool w = s.rnd(0, 2) == 0;
        int mode = s.rnd(0, 7) == 0 ? 0 : 2;
        char what[80];
        snprintf(what, sizeof what, "random %d: %s LBA %d n %d %s", i, w ? "write" : "read", l, cnt, mode ? "DMA" : "PIO");
        if (w) wr(s, l, cnt, mode, i, what); else rd(s, l, cnt, mode, what);
    }
    check_image(s, "random");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    uint32_t seed = 1;
    bool fmt_drive = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-v")) verbose = true;
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) seed = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-f")) fmt_drive = true;
    }
    Sim s(seed);
    struct { const char *name; std::function<void(Sim &)> fn; } tests[] = {
        {"power", t_power},
        {"detect", t_detect},
        {"spin-up", t_spinup},
        {"read/write", t_rw},
        {"seek", t_seek},
        {"buffer", t_buffer},
        {"format", t_format},
        {"errors", t_errors},
        {"random", [](Sim &s) { t_random(s, 25); }},
    };
    for (auto &t : tests) {
        int f0 = fails;
        uint64_t c0 = s.cyc;
        t.fn(s);
        printf("%-12s %s  (%.1f ms)\n", t.name, fails == f0 ? "ok" : "FAILED", clk2us(s.cyc - c0) / 1000);
    }
    if (fmt_drive) {
        int f0 = fails;
        uint64_t c0 = s.cyc;
        t_format_drive(s);
        printf("%-12s %s  (%.1f ms)\n", "format drive", fails == f0 ? "ok" : "FAILED", clk2us(s.cyc - c0) / 1000);
    }
    printf("%d checks, %d failed; backend: %d reads, %d writes; %.1f ms simulated\n", checks, fails, s.be.reads,
           s.be.writes, clk2us(s.cyc) / 1000);
    return fails ? 1 : 0;
}
