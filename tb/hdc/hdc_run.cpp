// hdc_run.cpp - Verilator testbench for rtl/hdc/xtide_card.sv.
//
// Drives the card bus the way the 5160 does (8088 I/O cycles with the
// board's wait state, memory reads of the option ROM), serves the option ROM
// and the sector port from C++ models (random backend latency and byte
// spacing), and checks registers, data, task file results, INTRQ and the
// BSY/DRQ timing. Built with IRQ = 5.
//
//   ./obj/hdc_run [-v] [-s seed]
//
// GPL-3.0-or-later, pc10-iii.

#include "Vxtide_card.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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

static const int BASE = 0x300;
static const int CMD_US = 5, BLK_US = 2, RESET_US = 1000;      // the card's defaults

// ATA status / error bits
enum { BSY = 0x80, DRDY = 0x40, DF = 0x20, DSC = 0x10, DRQ = 0x08, ERR = 0x01 };
enum { ABRT = 0x04, IDNF = 0x10, UNC = 0x40 };

// ------------------------------------------------------------ disk images
struct Disk {
    std::vector<uint8_t> d;
    int cyls = 0, heads = 0, spt = 0;
    uint32_t sectors = 0;
    bool present = false;
    void make(int c, int h, int s, uint32_t extra, uint32_t salt) {
        cyls = c; heads = h; spt = s; present = true;
        sectors = (uint32_t)c * h * s + extra;
        d.assign((size_t)sectors * 512, 0);
        for (size_t i = 0; i < d.size(); i++) {
            uint32_t x = (uint32_t)i * 2654435761u ^ salt;
            x ^= x >> 13; x *= 0x5bd1e995u; x ^= x >> 15;
            d[i] = (uint8_t)x;
        }
    }
    uint8_t *sec(uint32_t lba) { return &d[(size_t)lba * 512]; }
};

// ------------------------------------------------------------ the simulation
struct Sim {
    Vxtide_card *t;
    uint64_t cyc = 0;
    std::mt19937 rng;
    Disk disk[2];
    std::vector<uint8_t> rom;
    int variant = 0;

    struct {
        double lat_us_min = 2, lat_us_max = 60;
        int byte_gap_max = 3;
        std::set<uint32_t> bad_lba;
        std::set<uint32_t> short_lba;   // reads that end after 100 bytes without sp_err
        int state = 0;
        uint64_t when = 0;
        int cnt = 0, drv = 0;
        uint32_t lba = 0;
        bool wr = false, err = false;
        std::vector<uint8_t> wbuf;
        int requests = 0, reads = 0, writes = 0;
        bool prev_req = false;
        std::vector<uint32_t> log;      // LBAs in request order (drive << 31)
    } be;

    Sim(uint32_t seed) : rng(seed), rom(16384) {
        for (int i = 0; i < 16384; i++) rom[i] = (uint8_t)(i * 7 + (i >> 8));
        t = new Vxtide_card;
        t->clk = 0; t->reset = 1;
        t->isa_ior_n = 1; t->isa_iow_n = 1; t->isa_memr_n = 1; t->isa_aen = 0;
        t->isa_addr = 0; t->isa_dout = 0;
        t->enable = 1; t->variant = 0;
        t->sp_rd_valid = 0; t->sp_wr_ready = 0; t->sp_done = 0; t->sp_err = 0;
        apply_drives();
        for (int i = 0; i < 20; i++) tick();
        t->reset = 0;
    }

    void apply_drives() {
        t->hd_present = (disk[0].present ? 1 : 0) | (disk[1].present ? 2 : 0);
        t->hd_sectors = ((uint64_t)disk[1].sectors << 28) | disk[0].sectors;
        t->hd_cyls    = ((uint32_t)disk[1].cyls << 16) | disk[0].cyls;
        t->hd_heads   = (disk[1].heads << 5) | disk[0].heads;
        t->hd_spt     = (disk[1].spt << 6) | disk[0].spt;
    }

    int rnd(int a, int b) { return std::uniform_int_distribution<int>(a, b)(rng); }

    // one clk: the models set the inputs, then the rising edge
    uint8_t rom_q = 0;
    uint64_t irq_rise = 0, last_lo = 0, irq_count = 0;     // the last INTRQ rise, the last data strobe at 00h
    bool irq_prev = false;
    void tick() {
        backend();
        t->rom_rdata = rom_q;
        t->clk = 0; t->eval();
        t->clk = 1; t->eval();
        rom_q = rom[t->rom_addr & 0x3FFF];      // block RAM: 1 clk latency
        cyc++;
        if (irq() && !irq_prev) { irq_rise = cyc; irq_count++; }
        irq_prev = irq();
    }
    void run_us(double us) { uint64_t e = cyc + us2clk(us); while (cyc < e) tick(); }
    bool irq() const { return (t->isa_irq >> 3) & 1; }       // IRQ5 (bit 5 of [7:2])

    // ---------------------------------------------------- backend model
    void backend() {
        auto &b = be;
        t->sp_done = 0; t->sp_err = 0; t->sp_rd_valid = 0; t->sp_wr_ready = 0;
        bool req = t->sp_req;
        if (b.state == 0 && req && !b.prev_req) {
            b.requests++;
            b.drv = t->sp_drive; b.wr = t->sp_write; b.lba = t->sp_lba;
            (b.wr ? b.writes : b.reads)++;
            b.log.push_back(b.lba | ((uint32_t)b.drv << 31));
            Disk &dk = disk[b.drv];
            b.err = b.bad_lba.count(b.lba) || !dk.present || b.lba >= dk.sectors;
            b.cnt = 0; b.wbuf.clear();
            b.state = 1;
            b.when = cyc + us2clk(b.lat_us_min + (b.lat_us_max - b.lat_us_min) *
                                  std::uniform_real_distribution<double>(0, 1)(rng));
            if (verbose) printf("[%.1f us] backend %s drv %d lba %u\n", clk2us(cyc),
                                b.wr ? "write" : "read", b.drv, b.lba);
        }
        b.prev_req = req;
        Disk &dk = disk[b.drv];
        switch (b.state) {
        case 1:
            if (b.wr) { b.state = 2; break; }
            if (cyc >= b.when) b.state = 2;
            break;
        case 2:
            if (b.err && !b.wr) { t->sp_done = 1; t->sp_err = 1; b.state = 4; break; }
            if (!b.wr) {
                if (rnd(0, b.byte_gap_max) == 0) {
                    t->sp_rd_valid = 1;
                    t->sp_rd_data = dk.d[(size_t)b.lba * 512 + b.cnt];
                    if (++b.cnt == 512 || (b.cnt == 100 && b.short_lba.count(b.lba))) {
                        t->sp_done = rnd(0, 1); b.state = t->sp_done ? 4 : 3;
                    }
                }
            } else if (t->sp_wr_valid && rnd(0, b.byte_gap_max) == 0) {
                t->sp_wr_ready = 1;
                b.wbuf.push_back(t->sp_wr_data);
                if (b.wbuf.size() == 512) {
                    b.state = 3;
                    b.when = cyc + us2clk(b.lat_us_min + (b.lat_us_max - b.lat_us_min) *
                                          std::uniform_real_distribution<double>(0, 1)(rng));
                }
            }
            break;
        case 3:
            if (!b.wr) { t->sp_done = 1; b.state = 4; break; }
            if (cyc >= b.when) {
                if (!b.err) memcpy(dk.sec(b.lba), b.wbuf.data(), 512);
                t->sp_done = 1; t->sp_err = b.err; b.state = 4;
            }
            break;
        case 4:
            if (!req) b.state = 0;
            break;
        }
    }

    // ---------------------------------------------------- bus cycles
    // An 8088 I/O cycle with the 5160's wait state (IOR from the falling edge
    // in T1, IOW from T2, both to T4), then some instruction time.
    void io_write(int port, int val, int gap = 2 * C) {
        t->isa_addr = port; t->isa_aen = 0;
        for (int i = 0; i < C + C / 3; i++) tick();
        t->isa_dout = val;
        t->isa_iow_n = 0;
        for (int i = 0; i < 8 * C / 3; i++) tick();
        t->isa_iow_n = 1;
        for (int i = 0; i < C + gap; i++) tick();
    }
    int io_read(int port, int gap = 2 * C) {
        t->isa_addr = port; t->isa_aen = 0;
        for (int i = 0; i < 2 * C / 3; i++) tick();
        t->isa_ior_n = 0;
        if (port == BASE) last_lo = cyc;
        for (int i = 0; i < 3 * C; i++) tick();
        int v = t->isa_dsel ? t->isa_din : 0xFF;
        t->isa_ior_n = 1;
        for (int i = 0; i < C + gap; i++) tick();
        return v;
    }
    int mem_read(uint32_t addr) {
        t->isa_addr = addr;
        for (int i = 0; i < 2 * C / 3; i++) tick();
        t->isa_memr_n = 0;
        // the data must be there 2 clk after the strobe and stay
        int first = -1;
        bool stable = true;
        for (int i = 0; i < 2 * C; i++) {
            tick();
            if (i >= 1) {
                int v = t->isa_dsel ? t->isa_din : 0xFF;
                if (first < 0) first = v; else if (v != first) stable = false;
            }
        }
        CHECK(stable, "memory read %05X: data not stable during MEMR", addr);
        int v = t->isa_dsel ? t->isa_din : 0xFF;
        t->isa_memr_n = 1;
        for (int i = 0; i < C; i++) tick();
        return v;
    }

    // ---------------------------------------------------- register map
    int swap03(int o) { return (o & ~9) | ((o & 1) << 3) | ((o >> 3) & 1); }
    int reg(int r) {                    // command block register r
        if (variant == 0) return BASE + 2 * r;
        if (variant == 1) return BASE + r;
        return BASE + swap03(r);
    }
    int ctl() {                         // device control / alternate status
        if (variant == 0) return BASE + 0x1C;
        if (variant == 1) return BASE + 0x0E;
        return BASE + swap03(0x0E);
    }
    int data_hi() { return variant == 0 ? BASE + 1 : variant == 1 ? BASE + 8 : BASE + swap03(8); }

    bool mode8 = false;
    int status() { return io_read(reg(7)); }
    int alt() { return io_read(ctl()); }
    // IN AX,DX / the XTIDE rev 1 pair / 8-bit mode
    int read_word() {
        int lo = io_read(BASE, 1);
        int hi = io_read(mode8 ? (variant == 0 ? BASE + 1 : BASE) : data_hi(), C);
        return lo | (hi << 8);
    }
    void write_word(int w) {
        if (mode8) { io_write(variant == 0 ? BASE + 1 : BASE, w & 0xFF, 1); io_write(BASE, w >> 8, C); return; }
        if (variant == 0) { io_write(BASE, w & 0xFF, 1); io_write(BASE + 1, w >> 8, C); }
        else { io_write(data_hi(), w >> 8, 1); io_write(BASE, w & 0xFF, C); }
    }

    // poll status until !BSY (returns the status), with a time limit
    int wait_ready(double ms = 50) {
        uint64_t e = cyc + us2clk(ms * 1000);
        int s;
        do { s = status(); } while ((s & BSY) && cyc < e);
        CHECK(!(s & BSY), "still BSY after %.1f ms (status %02X)", ms, s);
        return s;
    }
    void select(int dev, int head = 0, bool lba = false) {
        io_write(reg(6), 0xA0 | (lba ? 0x40 : 0) | (dev << 4) | (head & 15));
    }
    void taskfile(int nsect, int sect, int cyl) {
        io_write(reg(2), nsect & 0xFF);
        io_write(reg(3), sect & 0xFF);
        io_write(reg(4), cyl & 0xFF);
        io_write(reg(5), (cyl >> 8) & 0xFF);
    }
    void lba_taskfile(int dev, uint32_t lba, int nsect) {
        select(dev, (lba >> 24) & 15, true);
        taskfile(nsect, lba & 0xFF, (lba >> 8) & 0xFFFF);
    }
    void command(int c) { io_write(reg(7), c); }
    uint32_t tf_lba() {
        return io_read(reg(3)) | (io_read(reg(4)) << 8) | (io_read(reg(5)) << 16) | ((io_read(reg(6)) & 15) << 24);
    }

    // read nsec sectors of PIO data (DRQ blocks of `blk`) into buf
    bool pio_in(std::vector<uint8_t> &buf, int nsec, int blk) {
        buf.clear();
        for (int s = 0; s < nsec; ) {
            int st = wait_ready();
            if (!(st & DRQ)) { printf("     pio_in: no DRQ before sector %d (status %02X)\n", s, st); return false; }
            int n = std::min(blk, nsec - s);
            for (int i = 0; i < n * 256; i++) { int w = read_word(); buf.push_back(w & 0xFF); buf.push_back(w >> 8); }
            s += n;
        }
        return true;
    }
    bool pio_out(const uint8_t *src, int nsec, int blk) {
        for (int s = 0; s < nsec; ) {
            int st = wait_ready();
            if (!(st & DRQ)) { printf("     pio_out: no DRQ before sector %d (status %02X)\n", s, st); return false; }
            int n = std::min(blk, nsec - s);
            for (int i = 0; i < n * 256; i++) write_word(src[(s * 256 + i) * 2] | (src[(s * 256 + i) * 2 + 1] << 8));
            s += n;
        }
        return true;
    }
};

// ------------------------------------------------------------ tests
static void t_reset(Sim &s) {
    // power-on: BSY for RESET_US, then the signature
    int st = s.status();
    CHECK(st == BSY, "status during reset %02X", st);
    uint64_t t0 = s.cyc;
    st = s.wait_ready(5);
    double us = clk2us(s.cyc - t0);
    CHECK(st == (DRDY | DSC), "status after reset %02X", st);
    CHECK(us > RESET_US - 40 && us < RESET_US + 40, "reset BSY lasted ~%.0f us", us);
    CHECK(s.io_read(s.reg(1)) == 0x01, "diagnostic code");
    CHECK(s.io_read(s.reg(2)) == 1 && s.io_read(s.reg(3)) == 1 && s.io_read(s.reg(4)) == 0 &&
          s.io_read(s.reg(5)) == 0, "signature");
    CHECK(s.io_read(s.reg(6)) == 0xA0, "drive/head after reset %02X", s.io_read(s.reg(6)));
}

static void t_identify(Sim &s, int dev) {
    Disk &d = s.disk[dev];
    s.select(dev);
    s.command(0xEC);
    CHECK(s.alt() == BSY, "IDENTIFY: BSY at once");
    uint64_t t0 = s.cyc;
    std::vector<uint8_t> b;
    bool ok = s.pio_in(b, 1, 1);
    CHECK(ok, "IDENTIFY dev %d: data", dev);
    if (!ok) return;
    auto w = [&](int i) { return b[2 * i] | (b[2 * i + 1] << 8); };
    CHECK(w(0) == 0x0040, "word 0 %04X", w(0));
    CHECK(w(1) == d.cyls && w(3) == d.heads && w(6) == d.spt, "default CHS %d/%d/%d", w(1), w(3), w(6));
    CHECK(w(47) == 0x8008, "word 47 %04X", w(47));
    CHECK(w(49) == 0x0200, "word 49 %04X", w(49));
    CHECK((w(60) | (w(61) << 16)) == (int)d.sectors, "LBA capacity %d", w(60) | (w(61) << 16));
    std::string model;
    for (int i = 27; i <= 46; i++) { model += (char)(w(i) >> 8); model += (char)(w(i) & 0xFF); }
    CHECK(model.rfind("PC10-III XTIDE disk image", 0) == 0, "model '%s'", model.c_str());
    CHECK(((w(19) & 0xFF) == (dev ? '1' : '0')), "serial number per drive");
    int st = s.status();
    CHECK(st == (DRDY | DSC), "after IDENTIFY status %02X", st);
    (void)t0;
}

static int ident_word(Sim &s, int dev, int i) {
    s.select(dev);
    s.command(0xEC);
    std::vector<uint8_t> b;
    if (!s.pio_in(b, 1, 1)) return -1;
    return b[2 * i] | (b[2 * i + 1] << 8);
}

static bool cmp(const uint8_t *got, const uint8_t *exp, int n, const char *what) {
    checks++;
    for (int i = 0; i < n; i++) if (got[i] != exp[i]) {
        fails++;
        printf("FAIL %s: byte %d (sector %d +%d) = %02X, expected %02X\n", what, i, i / 512, i % 512, got[i], exp[i]);
        return false;
    }
    return true;
}

// INTRQ per DRQ block (reads), per block after the first plus the end (writes)
static int blocks(int n, bool multiple, int blk) { return multiple ? (n + blk - 1) / blk : n; }

static void read_lba(Sim &s, int dev, uint32_t lba, int n, bool multiple, int blk, const char *what) {
    s.lba_taskfile(dev, lba, n);
    uint64_t i0 = s.irq_count;
    s.command(multiple ? 0xC4 : 0x20);
    std::vector<uint8_t> b;
    bool ok = s.pio_in(b, n, multiple ? blk : 1);
    CHECK(ok, "%s: transfer", what);
    if (ok) cmp(b.data(), s.disk[dev].sec(lba), n * 512, what);
    int st = s.wait_ready();
    CHECK(st == (DRDY | DSC), "%s: final status %02X", what, st);
    CHECK((int)(s.irq_count - i0) == blocks(n, multiple, blk), "%s: %d interrupts, expected %d", what,
          (int)(s.irq_count - i0), blocks(n, multiple, blk));
    CHECK(s.tf_lba() == lba + n - 1, "%s: task file LBA %u, expected %u", what, s.tf_lba(), lba + n - 1);
    CHECK(s.io_read(s.reg(2)) == 0, "%s: sector count 0", what);
}

static void write_lba(Sim &s, int dev, uint32_t lba, int n, bool multiple, int blk, const char *what) {
    std::vector<uint8_t> src(n * 512);
    for (auto &x : src) x = (uint8_t)s.rnd(0, 255);
    s.lba_taskfile(dev, lba, n);
    uint64_t i0 = s.irq_count;
    s.command(multiple ? 0xC5 : 0x30);
    bool ok = s.pio_out(src.data(), n, multiple ? blk : 1);
    CHECK(ok, "%s: transfer", what);
    int st = s.wait_ready();
    CHECK(st == (DRDY | DSC), "%s: final status %02X", what, st);
    s.run_us(1);
    CHECK((int)(s.irq_count - i0) == blocks(n, multiple, blk), "%s: %d interrupts, expected %d", what,
          (int)(s.irq_count - i0), blocks(n, multiple, blk));
    // write-through: everything is in the image when the command ends
    cmp(s.disk[dev].sec(lba), src.data(), n * 512, what);
    CHECK(s.tf_lba() == lba + n - 1, "%s: task file LBA %u", what, s.tf_lba());
}

static void t_chs(Sim &s) {
    // default geometry 615/4/17: read 6 sectors from C=1 H=3 S=15 (crosses
    // a head and a cylinder boundary), TF ends at C=2 H=0 S=3
    Disk &d = s.disk[0];
    s.select(0, 3);
    s.taskfile(6, 15, 1);
    s.command(0x20);
    std::vector<uint8_t> b;
    bool ok = s.pio_in(b, 6, 1);
    uint32_t lba = (1 * 4 + 3) * 17 + 14;
    CHECK(ok, "CHS read");
    if (ok) cmp(b.data(), d.sec(lba), 6 * 512, "CHS read");
    s.wait_ready();
    CHECK(s.io_read(s.reg(3)) == 3 && s.io_read(s.reg(4)) == 2 && s.io_read(s.reg(5)) == 0 &&
          (s.io_read(s.reg(6)) & 0x1F) == 0, "CHS read: task file C/H/S");
    // sector 0 and S > spt: IDNF, the task file keeps the address
    s.select(0, 1);
    s.taskfile(1, 18, 5);
    s.command(0x20);
    int st = s.wait_ready();
    CHECK(st == (DRDY | DSC | ERR) && s.io_read(s.reg(1)) == IDNF, "CHS S=18: IDNF (status %02X)", st);
    CHECK(s.io_read(s.reg(3)) == 18 && s.io_read(s.reg(4)) == 5, "IDNF keeps the address");
    s.select(0, 4);
    s.taskfile(1, 1, 0);
    s.command(0x20);
    st = s.wait_ready();
    CHECK(st & ERR, "CHS H=4 of 4 heads: error (status %02X)", st);

    // INITIALIZE DEVICE PARAMETERS 16 heads x 63: cylinders = 41820 / 1008 = 41
    s.select(0, 15);
    s.taskfile(63, 0, 0);
    s.command(0x91);
    st = s.wait_ready();
    CHECK(st == (DRDY | DSC), "INITIALIZE DEVICE PARAMETERS status %02X", st);
    CHECK(ident_word(s, 0, 54) == 41 && ident_word(s, 0, 55) == 16 && ident_word(s, 0, 56) == 63,
          "current CHS after INITIALIZE DEVICE PARAMETERS");
    CHECK(ident_word(s, 0, 57) == 41 * 16 * 63, "current capacity");
    // write in the new geometry: C=10 H=15 S=62, 3 sectors -> C=11 H=0 S=1
    std::vector<uint8_t> src(3 * 512);
    for (auto &x : src) x = (uint8_t)s.rnd(0, 255);
    s.select(0, 15);
    s.taskfile(3, 62, 10);
    s.command(0x30);
    ok = s.pio_out(src.data(), 3, 1);
    st = s.wait_ready();
    CHECK(ok && st == (DRDY | DSC), "CHS write (16/63) status %02X", st);
    cmp(d.sec((10 * 16 + 15) * 63 + 61), src.data(), 3 * 512, "CHS write (16/63)");
    CHECK(s.io_read(s.reg(3)) == 1 && s.io_read(s.reg(4)) == 11 && (s.io_read(s.reg(6)) & 15) == 0,
          "CHS write: task file at the last sector");
    // back to the default geometry
    s.select(0, 3);
    s.taskfile(17, 0, 0);
    s.command(0x91);
    s.wait_ready();
    CHECK(ident_word(s, 0, 54) == 615, "default geometry again (%d cylinders)", ident_word(s, 0, 54));
}

static void t_multiple(Sim &s) {
    // SET MULTIPLE: only powers of two up to 8 (XUB tries 128, 64, ... 1)
    s.select(0);
    if (s.variant) { s.io_write(s.reg(2), 0); s.command(0xC6); s.wait_ready(); }
    s.command(0xC4);                    // READ MULTIPLE before SET MULTIPLE
    int st = s.wait_ready();
    CHECK((st & ERR) && s.io_read(s.reg(1)) == ABRT, "READ MULTIPLE without SET MULTIPLE: ABRT");
    for (int m : {128, 16, 3}) {
        s.io_write(s.reg(2), m);
        s.command(0xC6);
        st = s.wait_ready();
        CHECK((st & ERR) && s.io_read(s.reg(1)) == ABRT, "SET MULTIPLE %d: ABRT (status %02X)", m, st);
    }
    s.io_write(s.reg(2), 8);
    s.command(0xC6);
    st = s.wait_ready();
    CHECK(st == (DRDY | DSC), "SET MULTIPLE 8 (status %02X)", st);
    CHECK(ident_word(s, 0, 59) == 0x0108, "word 59 %04X", ident_word(s, 0, 59));
    read_lba(s, 0, 1000, 20, true, 8, "READ MULTIPLE 20 (blocks 8+8+4)");
    write_lba(s, 0, 2000, 21, true, 8, "WRITE MULTIPLE 21");
    s.io_write(s.reg(2), 4);
    s.command(0xC6);
    s.wait_ready();
    read_lba(s, 0, 3000, 13, true, 4, "READ MULTIPLE 13 (m=4)");
    write_lba(s, 0, 3500, 9, true, 4, "WRITE MULTIPLE 9 (m=4)");
    // 256 sectors (count 0) through the 8-slot ring
    s.io_write(s.reg(2), 8);
    s.command(0xC6);
    s.wait_ready();
    double lmax = s.be.lat_us_max;
    s.be.lat_us_max = 10;
    read_lba(s, 0, 5000, 256, true, 8, "READ MULTIPLE 256");
    write_lba(s, 0, 6000, 256, false, 1, "WRITE SECTORS 256");
    s.be.lat_us_max = lmax;
    s.io_write(s.reg(2), 0);            // multiple off
    s.command(0xC6);
    CHECK(s.wait_ready() == (DRDY | DSC), "SET MULTIPLE 0");
}

static void t_timing_irq(Sim &s) {
    // IDENTIFY: DRQ about CMD_US after the command; INTRQ with DRQ
    s.be.lat_us_min = 50; s.be.lat_us_max = 50; s.be.byte_gap_max = 0;
    s.select(0);
    s.io_write(s.ctl(), 0x00);          // nIEN = 0
    s.command(0xEC);
    uint64_t t0 = s.cyc;
    while (!(s.irq()) && s.cyc - t0 < us2clk(200)) s.tick();
    double us = clk2us(s.cyc - t0);
    CHECK(s.irq(), "IDENTIFY: INTRQ");
    // BSY for CMD_US from the command, or while the card writes the 512 bytes
    // of the IDENTIFY sector into its buffer (one per clk), whichever is longer
    const double id_us = std::max<double>(CMD_US, clk2us(512));
    CHECK(us > id_us && us < id_us + 3, "IDENTIFY: DRQ %.1f us after the command", us);
    CHECK(s.alt() == (DRDY | DSC | DRQ) && s.irq(), "alternate status does not clear INTRQ");
    CHECK(s.status() == (DRDY | DSC | DRQ) && !s.irq(), "status clears INTRQ");
    std::vector<uint8_t> b;
    s.pio_in(b, 1, 1);
    s.run_us(20);
    CHECK(!s.irq(), "no INTRQ at the end of a read");

    // READ SECTORS 3: DRQ per sector, INTRQ each. The first sector waits
    // for the backend; the next ones were prefetched while the host read,
    // so DRQ (and INTRQ) come BLK_US after the strobe that ended the block.
    s.lba_taskfile(0, 77, 3);
    s.command(0x20);
    t0 = s.cyc;
    for (int k = 0; k < 3; k++) {
        uint64_t a = s.cyc;
        while (!s.irq() && s.cyc - a < us2clk(500)) s.tick();
        CHECK(s.irq(), "read sector %d: INTRQ", k);
        if (k == 0) {
            double w = clk2us(s.cyc - a);
            CHECK(w > 50 && w < 70, "first sector after %.1f us (backend 50 us)", w);
        } else {
            double w = clk2us(s.irq_rise - s.last_lo);
            CHECK(w > BLK_US - 1.1 && w < BLK_US + 1.1, "sector %d: DRQ %.2f us after the block's last strobe", k, w);
        }
        CHECK(s.status() & DRQ, "DRQ with INTRQ");
        for (int i = 0; i < 256; i++) s.read_word();
    }
    s.wait_ready();
    // nIEN masks the line
    s.io_write(s.ctl(), 0x02);
    s.command(0xEC);
    s.run_us(30);
    CHECK(!s.irq() && (s.alt() & DRQ), "nIEN masks INTRQ");
    s.io_write(s.ctl(), 0x00);
    CHECK(s.irq(), "INTRQ pending shows when nIEN is cleared");
    s.pio_in(b, 1, 1);

    // prefetch: with a fast backend the next sector is ready when the host
    // finishes the previous one, the BSY gap is BLK_US
    s.be.lat_us_min = 1; s.be.lat_us_max = 1;
    s.lba_taskfile(0, 300, 4);
    s.command(0x20);
    s.wait_ready();
    double gmin = 1e9, gmax = 0;
    for (int k = 0; k < 4; k++) {
        for (int i = 0; i < 256; i++) s.read_word();
        uint64_t a = s.cyc;
        if (k == 3) break;
        while (!(s.alt() & DRQ) && s.cyc - a < us2clk(200)) ;
        double g = clk2us(s.cyc - a);
        gmin = std::min(gmin, g); gmax = std::max(gmax, g);
    }
    CHECK(gmax < BLK_US + 6, "prefetched sectors: DRQ gap %.1f-%.1f us (poll %.1f us)", gmin, gmax,
          clk2us(14 + 63 + 21 + 40));
    s.wait_ready();
    // writes: the command ends (INTRQ) only when the backend stored the data
    s.be.lat_us_min = 300; s.be.lat_us_max = 300;
    std::vector<uint8_t> src(512, 0x5A);
    s.lba_taskfile(0, 400, 1);
    s.command(0x30);
    t0 = s.cyc;
    while (!(s.alt() & DRQ) && s.cyc - t0 < us2clk(100)) ;
    CHECK(!s.irq(), "write: no INTRQ for the first block");
    s.pio_out(src.data(), 1, 1);
    uint64_t t1 = s.cyc;
    while (!s.irq() && s.cyc - t1 < us2clk(2000)) s.tick();
    CHECK(s.irq() && clk2us(s.cyc - t1) > 250, "write: INTRQ %.0f us after the data (backend 300 us)",
          clk2us(s.cyc - t1));
    CHECK(s.status() == (DRDY | DSC), "write: status");
    CHECK(s.disk[0].sec(400)[100] == 0x5A, "write stored");
    // a backend slower than the host: the ring fills (DRQ waits for a free
    // slot), the command ends when the last of 12 sectors is stored
    s.be.lat_us_min = 2500; s.be.lat_us_max = 2500;
    write_lba(s, 0, 450, 12, false, 1, "write 12, slow backend");
    s.be.lat_us_min = 2; s.be.lat_us_max = 60; s.be.byte_gap_max = 3;
}

static void t_errors(Sim &s) {
    Disk &d = s.disk[0];
    // LBA beyond the capacity: IDNF at the first missing sector
    s.lba_taskfile(0, d.sectors - 2, 4);
    s.command(0x20);
    std::vector<uint8_t> b;
    bool ok = s.pio_in(b, 2, 1);
    int st = s.wait_ready();
    CHECK(ok && (st & ERR) && s.io_read(s.reg(1)) == IDNF, "read past the end: IDNF after 2 sectors (status %02X)", st);
    CHECK(s.tf_lba() == d.sectors && s.io_read(s.reg(2)) == 2, "IDNF: task file at the missing sector (%u, count %d)",
          s.tf_lba(), s.io_read(s.reg(2)));
    // backend read error at the 3rd of 5 sectors: UNC, two sectors delivered
    s.be.bad_lba = {5002};
    s.lba_taskfile(0, 5000, 5);
    s.command(0x20);
    ok = s.pio_in(b, 2, 1);
    st = s.wait_ready();
    CHECK(ok && (st & ERR) && !(st & DRQ) && s.io_read(s.reg(1)) == UNC, "backend read error: UNC (status %02X)", st);
    if (ok) cmp(b.data(), d.sec(5000), 1024, "sectors before the error");
    CHECK(s.tf_lba() == 5002 && s.io_read(s.reg(2)) == 3, "UNC: task file at the failing sector");
    // a read the backend ends early (100 bytes, no sp_err) is an error too
    s.be.short_lba = {5101};
    s.lba_taskfile(0, 5101, 1);
    s.command(0x20);
    st = s.wait_ready();
    CHECK((st & ERR) && !(st & DRQ) && s.io_read(s.reg(1)) == UNC, "short backend read: UNC (status %02X)", st);
    s.be.short_lba.clear();
    // inside a multiple block: no DRQ for the block
    s.io_write(s.reg(2), 8); s.command(0xC6); s.wait_ready();
    s.lba_taskfile(0, 4996, 8);
    s.command(0xC4);
    st = s.wait_ready();
    CHECK((st & ERR) && !(st & DRQ), "error inside a READ MULTIPLE block: no DRQ (status %02X)", st);
    s.io_write(s.reg(2), 0); s.command(0xC6); s.wait_ready();
    // backend write error: DF + ERR, ABRT
    s.lba_taskfile(0, 5001, 3);
    s.command(0x30);
    std::vector<uint8_t> src(3 * 512, 0x11);
    s.pio_out(src.data(), 2, 1);        // the error shows at the end of sector 2's commit at the latest
    st = s.wait_ready();
    for (int i = 0; i < 256 && (st & DRQ); i++) { s.write_word(0); st = s.status(); }
    st = s.wait_ready();
    CHECK((st & (ERR | DF)) == (ERR | DF) && s.io_read(s.reg(1)) == ABRT, "write error: DF ERR ABRT (status %02X)", st);
    CHECK(s.tf_lba() == 5002, "write error: task file %u", s.tf_lba());
    CHECK(d.sec(5001)[0] == 0x11, "the sector before the error was written");
    s.be.bad_lba.clear();
    // the next command clears the error
    s.command(0x10);
    CHECK(s.wait_ready() == (DRDY | DSC), "RECALIBRATE clears ERR/DF");
    // invalid command, invalid SET FEATURES
    s.command(0xE4);
    st = s.wait_ready();
    CHECK((st & ERR) && s.io_read(s.reg(1)) == ABRT, "READ BUFFER: ABRT");
    s.io_write(s.reg(1), 0x42);
    s.command(0xEF);
    st = s.wait_ready();
    CHECK((st & ERR) && s.io_read(s.reg(1)) == ABRT, "SET FEATURES 42h: ABRT");
    s.io_write(s.reg(1), 0x82);
    s.command(0xEF);
    CHECK(s.wait_ready() == (DRDY | DSC), "SET FEATURES 82h (write cache off) accepted");
    // INITIALIZE DEVICE PARAMETERS with 0 sectors: ABRT
    s.select(0, 3);
    s.taskfile(0, 0, 0);
    s.command(0x91);
    st = s.wait_ready();
    CHECK((st & ERR) && s.io_read(s.reg(1)) == ABRT, "INITIALIZE DEVICE PARAMETERS 0 spt: ABRT");
    // READ VERIFY
    s.lba_taskfile(0, 100, 50);
    s.command(0x40);
    st = s.wait_ready();
    CHECK(st == (DRDY | DSC) && s.tf_lba() == 149, "VERIFY 50: ok, task file %u", s.tf_lba());
    s.lba_taskfile(0, d.sectors - 10, 20);
    s.command(0x40);
    st = s.wait_ready();
    CHECK((st & ERR) && s.io_read(s.reg(1)) == IDNF && s.tf_lba() == d.sectors, "VERIFY past the end: IDNF");
    CHECK(s.be.requests > 0, "backend used");
}

static void t_srst(Sim &s) {
    // SRST in the middle of a multi-sector read
    s.lba_taskfile(0, 600, 10);
    s.command(0x20);
    s.wait_ready();
    for (int i = 0; i < 100; i++) s.read_word();
    s.io_write(s.ctl(), 0x04 | 0x02);
    CHECK(s.alt() == BSY, "BSY during SRST");
    s.run_us(10);
    s.io_write(s.ctl(), 0x02);
    uint64_t t0 = s.cyc;
    int st = s.wait_ready(5);
    CHECK(st == (DRDY | DSC) && clk2us(s.cyc - t0) > RESET_US - 50, "SRST: ready after ~%.0f us",
          clk2us(s.cyc - t0));
    CHECK(s.io_read(s.reg(1)) == 1 && s.io_read(s.reg(2)) == 1 && s.io_read(s.reg(3)) == 1, "SRST: signature");
    s.io_write(s.ctl(), 0x00);
    read_lba(s, 0, 610, 2, false, 1, "read after SRST");
}

static void t_mode8(Sim &s) {
    // SET FEATURES 01h: byte transfers (XT-CF PIO8: IN AL,DX at 00h; with BIU
    // offload IN AX,DX at 00h/01h, both data)
    s.select(0);
    s.io_write(s.reg(1), 0x01);
    s.command(0xEF);
    CHECK(s.wait_ready() == (DRDY | DSC), "SET FEATURES 01h");
    s.mode8 = true;
    read_lba(s, 0, 7000, 3, false, 1, "8-bit read");
    write_lba(s, 0, 7100, 2, false, 1, "8-bit write");
    // SRST restores 16-bit transfers
    s.io_write(s.ctl(), 0x04); s.run_us(5); s.io_write(s.ctl(), 0x00);
    s.wait_ready(5);
    s.mode8 = false;
    read_lba(s, 0, 7000, 1, false, 1, "16-bit after SRST");
    s.io_write(s.reg(1), 0x01); s.command(0xEF); s.wait_ready();
    s.io_write(s.reg(1), 0x81); s.command(0xEF); s.wait_ready();
    read_lba(s, 0, 7001, 1, false, 1, "16-bit after SET FEATURES 81h");
}

static void t_drives(Sim &s) {
    // the slave
    t_identify(s, 1);
    read_lba(s, 1, s.disk[1].sectors - 3, 3, false, 1, "slave: last sectors (beyond C*H*S)");
    write_lba(s, 1, 12345, 5, false, 1, "slave write");
    CHECK(s.be.log.back() >> 31, "sector port drive bit for the slave");
    // only the master: the slave reads status 00h (device 0 answers), its
    // commands are ignored
    s.disk[1].present = false; s.apply_drives(); s.run_us(1);
    s.select(1);
    CHECK(s.status() == 0x00 && s.alt() == 0x00, "absent slave: status 00h");
    s.command(0xEC);
    s.run_us(20);
    CHECK(s.status() == 0x00, "absent slave: command ignored");
    s.select(0);
    CHECK(s.status() == (DRDY | DSC), "master still ready");
    // no drive at all: the DD7 pull-down
    s.disk[0].present = false; s.apply_drives(); s.run_us(1);
    CHECK(s.status() == 0x7F && s.io_read(s.reg(2)) == 0x7F, "no drives: 7Fh");
    s.disk[0].present = true; s.disk[1].present = true; s.apply_drives(); s.run_us(1);
    // a new medium starts with the default geometry
    s.select(0);
    CHECK(s.status() == (DRDY | DSC), "master back");
    CHECK(ident_word(s, 0, 54) == 615, "new medium: default geometry");
}

static void t_rom(Sim &s) {
    for (uint32_t a : {0xC8000u, 0xC8001u, 0xC9234u, 0xCBFFFu}) {
        int v = s.mem_read(a);
        CHECK(v == s.rom[a & 0x3FFF], "ROM %05X = %02X, expected %02X", a, v, s.rom[a & 0x3FFF]);
    }
    CHECK(s.mem_read(0xCC000) == 0xFF && s.mem_read(0xC7FFF) == 0xFF, "outside the ROM window");
    s.t->enable = 0;
    CHECK(s.mem_read(0xC8000) == 0xFF, "ROM: card disabled");
    CHECK(s.io_read(s.reg(7)) == 0xFF, "I/O: card disabled");
    s.t->enable = 1;
    // AEN (DMA) cycles do not select the I/O ports
    s.t->isa_aen = 1;
    s.t->isa_addr = s.reg(7);
    for (int i = 0; i < 10; i++) s.tick();
    s.t->isa_ior_n = 0;
    for (int i = 0; i < 20; i++) s.tick();
    CHECK(!s.t->isa_dsel, "AEN: no I/O decode");
    s.t->isa_ior_n = 1; s.t->isa_aen = 0;
    for (int i = 0; i < 20; i++) s.tick();
    // the decode window: 300-31F (variant 0)
    CHECK(s.io_read(0x320) == 0xFF && s.io_read(0x2FE) == 0xFF, "outside 300-31F");
}

static void t_random(Sim &s, int n) {
    // random reads and writes on both drives, mixed modes, against the model
    for (int i = 0; i < n; i++) {
        int dev = s.rnd(0, 1);
        Disk &d = s.disk[dev];
        int cnt = s.rnd(1, 24);
        uint32_t lba = s.rnd(0, d.sectors - cnt);
        bool mult = s.rnd(0, 1);
        int m = 1 << s.rnd(0, 3);
        if (mult) { s.select(dev); s.io_write(s.reg(2), m); s.command(0xC6); s.wait_ready(); }
        bool rd = s.rnd(0, 1);
        char what[80];
        snprintf(what, sizeof what, "random %d: %s dev %d lba %u n %d m %d", i, rd ? "r" : "w", dev, lba, cnt,
                 mult ? m : 1);
        if (rd) read_lba(s, dev, lba, cnt, mult, m, what);
        else write_lba(s, dev, lba, cnt, mult, m, what);
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    uint32_t seed = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-v")) verbose = true;
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) seed = atoi(argv[++i]);
    }
    Sim s(seed);
    s.disk[0].make(615, 4, 17, 0, 0x1234);             // 20 MB, ST-225 geometry
    s.disk[1].make(64, 16, 63, 100, 0x9876);           // 31.5 MB + 100 sectors beyond C*H*S
    s.apply_drives();

    struct { const char *name; void (*fn)(Sim &); } tests[] = {
        {"reset", t_reset},
        {"identify", [](Sim &s) { t_identify(s, 0); }},
        {"read/write", [](Sim &s) {
            read_lba(s, 0, 0, 1, false, 1, "read LBA 0");
            read_lba(s, 0, 41000, 20, false, 1, "read 20");
            write_lba(s, 0, 30000, 17, false, 1, "write 17");
            read_lba(s, 0, 30000, 17, false, 1, "read back 17");
        }},
        {"chs", t_chs},
        {"multiple", t_multiple},
        {"timing/irq", t_timing_irq},
        {"errors", t_errors},
        {"srst", t_srst},
        {"mode8", t_mode8},
        {"drives", t_drives},
        {"rom", t_rom},
    };
    for (int v = 0; v < 3; v++) {
        s.variant = v;
        s.t->variant = v;
        printf("== variant %d (%s)\n", v, v == 0 ? "XT-CF / Lo-tech" : v == 1 ? "XTIDE rev 1" : "XTIDE rev 2");
        for (auto &t : tests) {
            if (v > 0 && (t.fn == t_reset)) continue;
            int f0 = fails;
            uint64_t c0 = s.cyc;
            t.fn(s);
            printf("%-12s %s  (%.1f ms)\n", t.name, fails == f0 ? "ok" : "FAILED", clk2us(s.cyc - c0) / 1000);
        }
        int f0 = fails;
        t_random(s, v == 0 ? 40 : 15);
        printf("%-12s %s\n", "random", fails == f0 ? "ok" : "FAILED");
    }
    printf("%d checks, %d failed; backend: %d reads, %d writes; %.1f ms simulated\n", checks, fails,
           s.be.reads, s.be.writes, clk2us(s.cyc) / 1000);
    return fails ? 1 : 0;
}
