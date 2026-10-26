// rtc_run.cpp - Verilator testbench for rtl/system/msm6242.sv, the PC10-III's
// real-time clock (doc/rtc.md section 8).
//
// The chip is driven with I/O cycles of the card bus (address, AEN, IOR/IOW
// low for a CPU I/O cycle's length, the next-clk values); rtc_model.h runs
// next to it on the same clk. Every clk the read data and select, clk_set and
// the write-back vector `now` are compared with the model. The tests add
// checks against independent expectations: the calendar against the C
// library's gmtime, the Commodore BIOS 4.41's INT 1Ah routines and SETCLOCK
// V3.0's access sequences (their gaps from the 8088 cycle counts), the data
// sheet's HOLD/BUSY/adjust/STOP/REST/IRQ behaviour.
//
// Built twice: obj/ with the exact oscillator (28.63636 MHz clk, 32.768 kHz)
// and obj_fast/ with 32.768 kHz = clk / 8 (OSC_NUM 1, OSC_DEN 8) for the long
// calendar and torture runs.
//
// usage: rtc_run [test ...]   (no test: the build's default list)
//
// GPL-3.0-or-later, pc10-iii.

#include "Vmsm6242.h"
#include "rtc_model.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <deque>
#include <random>
#include <string>
#include <vector>

#ifndef OSC_NUM
#define OSC_NUM 360448u
#define OSC_DEN 315000000u
#endif
static const bool FAST = OSC_DEN < 1000;
// clk per second, per microsecond
static uint64_t clk_per_s() { return FAST ? uint64_t(32768) * OSC_DEN / OSC_NUM : 28636364ull; }
static uint64_t us(double u) { return uint64_t(u * (FAST ? 32768.0 * OSC_DEN / OSC_NUM : 28636363.636) / 1e6 + 0.5); }

static int failures = 0;
static long checks = 0;
#define CHECK(c, ...) do { checks++; if (!(c)) { failures++; if (failures < 40) { printf("FAIL: " __VA_ARGS__); printf("\n"); } } } while (0)

struct Sim {
    Vmsm6242 *top;
    RtcModel m{OSC_NUM, OSC_DEN};
    std::deque<RtcBus> plan;
    uint64_t clk = 0;
    uint64_t seed = 0;
    bool seed_t = false;
    uint8_t rd = 0;
    long sets = 0;                 // clk_set pulses
    long reads = 0;                // CPU reads (each compared with the model)
    long mism = 0;
    bool dsel_seen = false;

    Sim() {
        top = new Vmsm6242;
        top->clk = 0;
        top->enable = 1;
        drive(RtcBus{}, RtcBus{});
        top->eval();
    }
    void drive(const RtcBus &c, const RtcBus &n) {
        top->isa_addr = c.addr;
        top->isa_aen = c.aen;
        top->isa_ior_n = c.ior_n;
        top->isa_iow_n = c.iow_n;
        top->isa_dout = c.dout;
        top->isa_addr_next = n.addr;
        top->isa_aen_next = n.aen;
        top->isa_ior_n_next = n.ior_n;
        top->isa_iow_n_next = n.iow_n;
        top->seed[0] = uint32_t(seed);
        top->seed[1] = uint32_t(seed >> 32);
        top->seed[2] = seed_t;
        top->enable = m.enable;
    }
    void cycle() {
        RtcBus cur, nx;
        if (!plan.empty()) { cur = plan.front(); plan.pop_front(); }
        if (!plan.empty()) nx = plan.front();
        drive(cur, nx);
        top->eval();
        // combinational read path
        bool ds = top->isa_dsel;
        dsel_seen |= ds;
        if (ds != m.dsel(cur) || (ds && top->isa_din != m.din(cur))) {
            if (mism++ < 10)
                printf("MISMATCH read clk %llu a %X: hw %d %02X model %d %02X\n", (unsigned long long)clk,
                       cur.addr & 15, ds, top->isa_din, m.dsel(cur), m.din(cur));
            failures++;
        }
        if (cur.sample) { rd = top->isa_din; reads++; }
        top->clk = 1;
        top->eval();
        m.clock(cur, nx, seed, seed_t);
        top->clk = 0;                  // (evaluated with the next clk's inputs)
        clk++;
        if (top->clk_set) sets++;
        if (top->clk_set != m.set || top->now != m.now()) {
            if (mism++ < 10)
                printf("MISMATCH clk %llu: set hw %d model %d, now hw %016llX model %016llX\n",
                       (unsigned long long)clk, top->clk_set, m.set, (unsigned long long)top->now,
                       (unsigned long long)m.now());
            failures++;
        }
    }
    void run(uint64_t n) { for (uint64_t i = 0; i < n; i++) cycle(); }
    void flush() { while (!plan.empty()) cycle(); }

    // an I/O cycle (one wait state): IOR from the CLK fall in T1 to T4, IOW from T2
    uint8_t in(unsigned port, uint64_t gap = 0) {
        RtcBus b; b.addr = port;
        for (int i = 0; i < 3; i++) plan.push_back(b);
        b.ior_n = false;
        for (int i = 0; i < 21; i++) { b.sample = i == 20; plan.push_back(b); }
        b.ior_n = true; b.sample = false;
        for (int i = 0; i < 3; i++) plan.push_back(b);
        flush();
        run(gap);
        return rd;
    }
    void out(unsigned port, uint8_t v, uint64_t gap = 0) {
        RtcBus b; b.addr = port; b.dout = v;
        for (int i = 0; i < 9; i++) plan.push_back(b);
        b.iow_n = false;
        for (int i = 0; i < 15; i++) plan.push_back(b);
        b.iow_n = true;
        for (int i = 0; i < 3; i++) plan.push_back(b);
        flush();
        run(gap);
    }
    void new_seed(uint64_t v) { seed = v; seed_t = !seed_t; }
    // the 8088 cycles of the code between two I/O instructions
    void cpu(int cycles) { run(uint64_t(cycles) * 6); }
};

// ------------------------------------------------------------ helpers
static int bcd(int v) { return ((v / 10) << 4) | (v % 10); }
static int unbcd(int v) { return (v >> 4) * 10 + (v & 15); }

struct Clock { int y, mo, d, h, mi, s, w; };     // y = full year

static Clock from_t(time_t t) {
    struct tm tm;
    gmtime_r(&t, &tm);
    return Clock{tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec, tm.tm_wday};
}
static time_t to_t(const Clock &c) {
    struct tm tm{};
    tm.tm_year = c.y - 1900; tm.tm_mon = c.mo - 1; tm.tm_mday = c.d;
    tm.tm_hour = c.h; tm.tm_min = c.mi; tm.tm_sec = c.s;
    return timegm(&tm);
}
// the chip's 13 registers for a time (24 h, or 12 h with PM)
static void regs_of(const Clock &c, bool h24, int *r) {
    int yy = ((c.y - 1980) % 100 + 100) % 100;
    r[0] = c.s % 10; r[1] = c.s / 10; r[2] = c.mi % 10; r[3] = c.mi / 10;
    if (h24) { r[4] = c.h % 10; r[5] = c.h / 10; }
    else {
        int h12 = c.h % 12 == 0 ? 12 : c.h % 12;
        r[4] = h12 % 10; r[5] = h12 / 10 | (c.h >= 12 ? 4 : 0);
    }
    r[6] = c.d % 10; r[7] = c.d / 10; r[8] = c.mo % 10; r[9] = c.mo / 10;
    r[10] = yy % 10; r[11] = yy / 10; r[12] = c.w;
}
static std::string str(const Clock &c) {
    char b[64];
    snprintf(b, sizeof b, "%04d-%02d-%02d %02d:%02d:%02d w%d", c.y, c.mo, c.d, c.h, c.mi, c.s, c.w);
    return b;
}
// the M2M seed vector for a time (years since 2000, weekday Monday = 0)
static uint64_t m2m_of(const Clock &c) {
    int yy = ((c.y - 2000) % 100 + 100) % 100;
    return uint64_t(bcd(c.s)) | uint64_t(bcd(c.mi)) << 8 | uint64_t(bcd(c.h)) << 16 | uint64_t(bcd(c.d)) << 24 |
           uint64_t(bcd(c.mo)) << 32 | uint64_t(bcd(yy)) << 40 | uint64_t((c.w + 6) % 7) << 48 |
           uint64_t(0x40) << 56;
}

// read all 16 registers (low nibbles); checks the high nibble is 1111
static void read_all(Sim &s, int *r) {
    for (int a = 0; a < 16; a++) {
        uint8_t v = s.in(0x2C0 + a);
        CHECK((v & 0xF0) == 0xF0, "high nibble %02X", v);
        r[a] = v & 15;
    }
}
// set the time the BIOS way (HOLD, the registers, HOLD off), all 13
static void write_regs(Sim &s, const int *r) {
    s.out(0x2CD, 0x07);
    for (int a = 0; a < 13; a++) s.out(0x2C0 + a, r[a], 30);
    s.out(0x2CD, 0x04);
}
static bool check_regs(Sim &s, const Clock &c, bool h24, const char *what) {
    s.out(0x2CD, 0x07);
    int r[16], e[13];
    for (int a = 0; a < 13; a++) r[a] = s.in(0x2C0 + a) & 15;
    s.out(0x2CD, 0x04);
    regs_of(c, h24, e);
    bool ok = true;
    for (int a = 0; a < 13; a++) if (r[a] != e[a]) ok = false;
    CHECK(ok, "%s: expected %s, read %X%X:%X%X:%X%X %X%X.%X%X.%X%X w%X", what, str(c).c_str(), r[5], r[4], r[3],
          r[2], r[1], r[0], r[7], r[6], r[9], r[8], r[11], r[10], r[12]);
    return ok;
}
// wait for the next 1 Hz carry (S1 changes; polled every 10 us), then `after_us`
static void sync_carry(Sim &s, double after_us = 0) {
    int a = s.in(0x2C0) & 15;
    while ((s.in(0x2C0) & 15) == a) s.run(us(10));
    // the model knows the carry's clk exactly: align to it
    s.run(us(after_us));
}

// ------------------------------------------------------------ the BIOS (4.41) and SETCLOCK (V3.0)
// F000:DEDA: HOLD on and wait for BUSY = 0 (50 x, then HOLD off, twice); C = timeout
static bool bios_wait(Sim &s) {
    for (int di = 0; di < 2; di++) {
        s.cpu(4);
        for (int cx = 0; cx < 50; cx++) {
            s.out(0x2CD, 0x07, 6 * 4);              // mov al,7 / out dx,al
            uint8_t v = s.in(0x2CD, 6 * 8);          // in al,dx / test al,2 / je
            if (!(v & 2)) return true;
            s.cpu(17);                               // loop
        }
        s.out(0x2CD, 0x04, 6 * 15);                  // mov al,4 / out / jmp $+2 / dec di / jne
    }
    return false;
}
// F000:DE84: read three register pairs from `port` (de84), HOLD off
static bool bios_read3(Sim &s, unsigned port, int &bl, int &bh, int &ch) {
    if (!bios_wait(s)) return false;
    int v[6];
    for (int i = 0; i < 6; i++) v[i] = s.in(port + i, 6 * 12) & 15;
    bl = v[0] | v[1] << 4; bh = v[2] | v[3] << 4; ch = v[4] | v[5] << 4;
    s.out(0x2CD, 0x04);
    return true;
}
// INT 1Ah AH=02: CH hours, CL minutes, DH seconds (BCD); false = C (timeout)
static bool int1a_02(Sim &s, int &ch, int &cl, int &dh) {
    int bl, bh, c;
    if (!bios_read3(s, 0x2C0, bl, bh, c)) return false;
    dh = bl; cl = bh; ch = c;
    return true;
}
// INT 1Ah AH=04: CX century+year, DH month, DL day (the BIOS's year arithmetic)
static bool int1a_04(Sim &s, int &cx, int &dh, int &dl) {
    int bl, bh, ch;
    if (!bios_read3(s, 0x2C6, bl, bh, ch)) return false;
    int ax = (ch >> 4) * 10 + (ch & 15) + 0x7BC, cent;
    if (ax < 0x7D0) { ax -= 0x76C; cent = 0x19; } else { ax -= 0x7D0; cent = 0x20; }
    cx = cent << 8 | ((ax / 10) << 4 | ax % 10);
    dh = bh; dl = bl;
    return true;
}
// F000:DEB5: write three register pairs
static bool bios_write3(Sim &s, unsigned port, int ah, int bl, int bh) {
    if (!bios_wait(s)) return false;
    int v[6] = {ah & 15, ah >> 4, bl & 15, bl >> 4, bh & 15, bh >> 4};
    for (int i = 0; i < 6; i++) s.out(port + i, v[i], 6 * 10);
    s.out(0x2CD, 0x04);
    return true;
}
// INT 1Ah AH=03: CH hours, CL minutes, DH seconds
static bool int1a_03(Sim &s, int ch, int cl, int dh) { return bios_write3(s, 0x2C0, dh, cl, ch); }
// INT 1Ah AH=05: CX century+year (CH ignored), DH month, DL day
static bool int1a_05(Sim &s, int cx, int dh, int dl) {
    int y = unbcd(cx & 0xFF);
    int ax = (y < 0x50 ? y + 0x7D0 : y + 0x76C) - 0x7BC;
    return bios_write3(s, 0x2C6, dl, dh, bcd(ax & 0xFF));
}
// F000:CE80: the POST's probe: two reads of 2C0h 10 x 65536 LOOPs apart (2.33 s)
static bool post_probe(Sim &s) {
    uint8_t a = s.in(0x2C0);
    s.cpu(10 * (65536 * 17 + 14));
    uint8_t b = s.in(0x2C0);
    return a != b;
}
// SETCLOCK.EXE V3.0 0031h: HOLD on, poll BUSY (count = (speed + 2) x 13), 5 x
static bool sc_wait(Sim &s, int speed = 0) {
    for (int tries = 0; tries < 5; tries++) {
        s.out(0x2CD, 0x07, 6 * 2);
        for (int cx = (speed + 2) * 13; cx > 0; cx--) {
            uint8_t v = s.in(0x2CD, 6 * 8);
            if (!(v & 2)) return true;
            s.cpu(17);
        }
        s.out(0x2CD, 0x04, 6 * 60);
    }
    return false;                                    // "RTC timeout"
}
static bool sc_read(Sim &s, int *b) {
    if (!sc_wait(s)) return false;
    for (int a = 0; a < 13; a++) b[a] = s.in(0x2C0 + a, 6 * 30) & 15;
    s.out(0x2CD, 0x04);
    return true;
}
static bool sc_write(Sim &s, const int *b) {
    if (!sc_wait(s)) return false;
    s.out(0x2CF, 0x07, 6 * 8);
    s.out(0x2CE, 0x00, 6 * 8);
    for (int a = 0; a < 13; a++) s.out(0x2C0 + a, b[a], 6 * 30);
    s.out(0x2CF, 0x04, 6 * 8);
    s.out(0x2CD, 0x04);
    return true;
}

// ------------------------------------------------------------ tests
static Clock base = {2026, 10, 26, 13, 45, 30, 1};

static void t_bios(Sim &s) {
    // power-up: the chip runs from 01.01.1980 00:00:00 (24 h)
    int r[16];
    read_all(s, r);
    CHECK(r[6] == 1 && r[8] == 1 && r[10] == 0 && r[11] == 0 && r[15] == 4, "power-up state");
    // the seed: 2026-10-26 13:45:30 Monday
    s.new_seed(m2m_of(base));
    s.run(100);
    if (getenv("RTC_DBG")) printf("dbg: hw %016llX model %016llX clk %llu\n", (unsigned long long)s.top->now, (unsigned long long)s.m.now(), (unsigned long long)s.clk);
    time_t t0 = to_t(base);
    uint64_t c0 = s.clk;
    check_regs(s, base, true, "seeded");
    // the POST probe sees it tick
    CHECK(post_probe(s), "POST: 2C0h does not tick");
    // INT 1Ah AH=02 / AH=04
    int ch, cl, dh, cx, dl;
    bool ok = int1a_02(s, ch, cl, dh);
    Clock e = from_t(t0 + time_t((s.clk - c0) / clk_per_s()));
    CHECK(ok && ch == bcd(e.h) && cl == bcd(e.mi) && dh == bcd(e.s), "INT 1A 02: %d %02X:%02X:%02X, expected %s", ok, ch, cl, dh,
          str(e).c_str());
    ok = int1a_04(s, cx, dh, dl);
    CHECK(ok && cx == 0x2026 && dh == 0x10 && dl == 0x26, "INT 1A 04: %d %04X %02X %02X", ok, cx, dh, dl);
    printf("bios: seeded, POST probe ticks, INT 1A 02 = %02X:%02X, 04 = %04X-%02X-%02X\n", ch, cl, cx, dh, dl);
    // INT 1Ah AH=03/05: 23:59:58 31.12.1999; write-back pulses
    long sets0 = s.sets;
    CHECK(int1a_03(s, 0x23, 0x59, 0x58), "INT 1A 03 timeout");
    s.run(10);
    CHECK(s.sets == sets0 + 1, "one clk_set after AH=03 (%ld)", s.sets - sets0);
    CHECK(((s.top->now >> 8) & 0xFFFFFF) == 0x235958 || ((s.top->now >> 8) & 0xFFFFFF) == 0x235959, "now after AH=03 %016llX",
          (unsigned long long)s.top->now);
    CHECK(int1a_05(s, 0x1999, 0x12, 0x31), "INT 1A 05 timeout");
    s.run(10);
    CHECK(s.sets == sets0 + 2, "one clk_set after AH=05");
    CHECK(((s.top->now >> 32) & 0xFFFFFF) == 0x991231, "now: 1999 is M2M 2099: %016llX", (unsigned long long)s.top->now);
    s.run(clk_per_s() * 5 / 2);
    CHECK(int1a_04(s, cx, dh, dl) && cx == 0x2000 && dh == 0x01 && dl == 0x01, "after midnight: %04X-%02X-%02X", cx, dh, dl);
    CHECK(int1a_02(s, ch, cl, dh) && ch == 0 && cl == 0 && dh <= 0x02, "after midnight: %02X:%02X:%02X", ch, cl,
          dh);
    // SETCLOCK -w (DOS's date, weekday; the hundredths as the seconds: V3.0's bug) and -r
    int b[13] = {7, 4, 3, 2, 1, 1, 4, 1, 3, 0, 4, 0, 0};          // 47 s, 11:23, 14.03.1984, Sunday
    sets0 = s.sets;
    CHECK(sc_write(s, b), "SETCLOCK -w: RTC timeout");
    s.run(10);
    CHECK(s.sets == sets0 + 1, "one clk_set after SETCLOCK -w");
    CHECK(s.m.reg(14) == 0 && s.m.reg(15) == 4, "SETCLOCK -w leaves CE 0, CF 4");
    int rb[13];
    CHECK(sc_read(s, rb), "SETCLOCK -r: RTC timeout");
    CHECK(rb[2] == 3 && rb[3] == 2 && rb[4] == 1 && rb[5] == 1 && rb[6] == 4 && rb[7] == 1 && rb[8] == 3 && rb[10] == 4 &&
              rb[12] == 0, "SETCLOCK -r");
    CHECK(((s.top->now >> 56) & 7) == 6 && ((s.top->now >> 48) & 0xFF) == 0x84, "now: Sunday = 6, 1984 = M2M 84: %016llX",
          (unsigned long long)s.top->now);
    // enable = 0 (230h bit 6 clear): no reads, writes ignored
    s.m.enable = false;
    s.dsel_seen = false;
    s.out(0x2CF, 0x06);
    s.in(0x2C0);
    CHECK(!s.dsel_seen, "disabled: selected");
    s.m.enable = true;
    CHECK((s.in(0x2CF) & 2) == 0, "disabled: STOP written");
    // aliases: only 2C0h-2CFh (A9-A4), with AEN low
    {
        RtcBus bb; bb.addr = 0x2D0; bb.ior_n = false;
        s.plan.push_back(bb); s.plan.push_back(bb); s.flush();
        CHECK(!s.m.dsel(bb), "2D0h");
        bb.addr = 0x6C0; CHECK(s.m.dsel(bb), "6C0h is an alias (10-bit decode)");
        bb.addr = 0x2C0; bb.aen = true; CHECK(!s.m.dsel(bb), "AEN");
        s.plan.push_back(bb); s.flush();
    }
    printf("bios: AH=03/05 and SETCLOCK -w/-r round trips, %ld write-backs\n", s.sets);
}

// the calendar against gmtime: each case set as 1 s before, read after k s
static void t_calendar(Sim &s) {
    std::vector<std::pair<Clock, int>> cases;
    auto add = [&](int y, int mo, int d, int h, int mi, int se, int k) {
        Clock c{y, mo, d, h, mi, se, 0};
        c = from_t(to_t(c));
        cases.push_back({c, k});
    };
    add(1999, 12, 31, 23, 59, 58, 3);
    add(2079, 12, 31, 23, 59, 59, 2);                // 99 -> 00: 1980
    for (int y : {1980, 1981, 1984, 1985, 2000, 2023, 2024, 2026})
        for (int mo = 1; mo <= 12; mo++) {
            static const int ml[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
            int d = ml[mo - 1] + (mo == 2 && y % 4 == 0);
            add(y, mo, d, 23, 59, 59, 1);
            if (mo == 2) add(y, 2, 28, 23, 59, 59, 1);
        }
    add(1987, 6, 15, 9, 59, 59, 1);
    add(1987, 6, 15, 19, 59, 59, 1);
    add(1987, 6, 15, 12, 34, 59, 61);
    int n = 0;
    for (auto &[c, k] : cases) {
        // 24 h, then 12 h
        for (int mode = 0; mode < 2; mode++) {
            bool h24 = mode == 0;
            if (FAST || n < 6) {
                if (!h24) { s.out(0x2CF, 0x01); s.out(0x2CF, 0x00); }
                int r[13];
                regs_of(c, h24, r);
                sync_carry(s, 100);                  // set just after a carry
                write_regs(s, r);
                s.run(clk_per_s() * k + us(2000) - us(1000));
                Clock e = from_t(to_t(c) + k);
                if (e.y >= 2080) e.y -= 100;
                check_regs(s, e, h24, h24 ? "24 h" : "12 h");
                if (!h24) { s.out(0x2CF, 0x05); s.out(0x2CF, 0x04); }
                n++;
            }
        }
    }
    // 12-hour hours: 12 AM .. 11 PM across a whole day by the hour (fast build; the exact one: 3)
    s.out(0x2CF, 0x01); s.out(0x2CF, 0x00);
    for (int h = 0; h < 24; h += FAST ? 1 : 11) {
        Clock c{1990, 7, 4, h, 59, 59, 0};
        c = from_t(to_t(c));
        int r[13];
        regs_of(c, false, r);
        sync_carry(s, 100);
        write_regs(s, r);
        s.run(clk_per_s() + us(1000));
        check_regs(s, from_t(to_t(c) + 1), false, "12 h by the hour");
        // the write-back vector: 24 h
        uint64_t nv = s.top->now;
        Clock e = from_t(to_t(c) + 1);
        CHECK(((nv >> 24) & 0xFF) == uint64_t(bcd(e.h)), "now hours in 12 h mode: %02llX for %d",
              (unsigned long long)((nv >> 24) & 0xFF), e.h);
    }
    s.out(0x2CF, 0x05); s.out(0x2CF, 0x04);
    printf("calendar: %d cases (%s)\n", n, FAST ? "all, 24 h and 12 h" : "the first 6");
}

// HOLD and BUSY
static void t_hold(Sim &s) {
    int r[16];
    // a held carry is applied at the release (+1 s), only one
    sync_carry(s, 300);
    int s0 = s.in(0x2C0) & 15;
    s.out(0x2CD, 0x07);
    CHECK((s.in(0x2CD) & 2) == 0, "BUSY 300 us after the carry");
    s.run(clk_per_s() * 3 / 2);
    CHECK((s.in(0x2C0) & 15) == s0, "held: S1 changed");
    s.out(0x2CD, 0x04);
    CHECK((s.in(0x2C0) & 15) == (s0 + 1) % 10, "release: +1 s");
    // HOLD 2.5 s: one carry
    sync_carry(s, 300);
    s0 = s.in(0x2C0) & 15;
    s.out(0x2CD, 0x07);
    s.run(clk_per_s() * 5 / 2);
    s.out(0x2CD, 0x04);
    CHECK((s.in(0x2C0) & 15) == (s0 + 1) % 10, "2.5 s held: +1 s only");
    // HOLD within the increment: BUSY 1, kept while HOLD stays set (the BIOS's loop)
    sync_carry(s, 20);
    s.out(0x2CD, 0x07);
    CHECK((s.in(0x2CD) & 2) != 0, "BUSY 20 us after the carry");
    s.run(us(400));
    s.out(0x2CD, 0x07);
    CHECK((s.in(0x2CD) & 2) != 0, "BUSY kept while HOLD stays set");
    s.out(0x2CD, 0x04);
    s.run(us(100));
    s.out(0x2CD, 0x07);
    CHECK((s.in(0x2CD) & 2) == 0, "BUSY cleared by HOLD = 0 (100 us)");
    s.out(0x2CD, 0x04);
    // phase sweep: the BIOS and SETCLOCK at every phase around the carry
    int bios_fail = 0, sc_fail = 0, sweeps = 0;
    for (int ph : {-150, -50, 0, 40, 80, 120, 160, 200, 240, 300, 500}) {
        sync_carry(s, 0);
        s.run(clk_per_s() + us(ph) - us(80));
        int ch, cl, dh;
        if (!int1a_02(s, ch, cl, dh)) bios_fail++;
        sync_carry(s, 0);
        s.run(clk_per_s() + us(ph) - us(80));
        int b[13];
        if (!sc_read(s, b)) sc_fail++;
        sweeps++;
    }
    printf("hold: phase sweep %d phases: BIOS timeouts %d, SETCLOCK timeouts %d\n", sweeps, bios_fail, sc_fail);
    read_all(s, r);
}

static void t_adjust(Sim &s) {
    struct { Clock c; Clock e; } cases[] = {
        {{1988, 3, 1, 12, 34, 29, 2}, {1988, 3, 1, 12, 34, 0, 2}},
        {{1988, 3, 1, 12, 34, 30, 2}, {1988, 3, 1, 12, 35, 0, 2}},
        {{1988, 12, 31, 23, 59, 45, 6}, {1989, 1, 1, 0, 0, 0, 0}},
    };
    for (auto &k : cases) {
        int r[13];
        regs_of(k.c, true, r);
        write_regs(s, r);
        s.run(us(1000));
        long sets0 = s.sets;
        s.out(0x2CD, 0x0C);
        CHECK(s.in(0x2CD) & 8, "ADJ reads 1 at once");
        s.run(us(200));
        CHECK(!(s.in(0x2CD) & 8), "ADJ back to 0 after 125 us");
        CHECK(s.sets == sets0 + 1, "adjust: one write-back");
        check_regs(s, k.e, true, "30 s adjust");
    }
    printf("adjust: 3 cases\n");
}

static void t_stoprest(Sim &s) {
    Clock c{1991, 5, 5, 5, 5, 5, 0};
    int r[13];
    regs_of(c, true, r);
    write_regs(s, r);
    s.out(0x2CF, 0x06);                              // STOP
    s.run(clk_per_s() * 2);
    check_regs(s, c, true, "STOP");
    s.out(0x2CF, 0x05);                              // REST
    s.run(clk_per_s() * 2);
    check_regs(s, c, true, "REST");
    s.out(0x2CF, 0x04);
    s.run(clk_per_s() - us(1500));
    check_regs(s, c, true, "REST: a whole second after the release");
    s.run(us(3000));
    Clock c1 = from_t(to_t(c) + 1);
    check_regs(s, c1, true, "REST: +1 s");
    // 24/12 only while REST = 1
    s.out(0x2CF, 0x00);
    CHECK((s.in(0x2CF) & 4) != 0, "24/12 written without REST");
    s.out(0x2CF, 0x01);
    s.out(0x2CF, 0x00);
    CHECK((s.in(0x2CF) & 4) == 0, "24/12 not written with REST");
    CHECK((s.in(0x2C5) & 4) == 0, "AM");
    s.out(0x2C5, 0x05);                              // PM, h10 = 1
    CHECK((s.in(0x2C5) & 15) == 5, "PM reads in 12 h mode");
    s.out(0x2CF, 0x05); s.out(0x2CF, 0x04);
    CHECK((s.in(0x2C5) & 15) == 1, "PM reads 0 in 24 h mode");
    // TEST: the seconds at 8192 Hz
    s.out(0x2C0, 0); s.out(0x2C1, 0); s.out(0x2C2, 0);
    s.out(0x2CF, 0x0C);
    s.run(us(10000));
    s.out(0x2CF, 0x04);
    int secs = (s.in(0x2C2) & 15) * 60 + (s.in(0x2C1) & 7) * 10 + (s.in(0x2C0) & 15);
    CHECK(secs >= 78 && secs <= 86, "TEST: %d s in 10 ms", secs);
    printf("stoprest: STOP, REST, 24/12, PM, TEST (%d s in 10 ms)\n", secs);
}

static void t_irq(Sim &s) {
    // 1/64 s standard pulse: 50 % duty
    s.out(0x2CE, 0x00);
    s.out(0x2CD, 0x04);
    int hi = 0, n = 0, edges = 0, last = 0;
    for (int i = 0; i < 2000; i++) {
        int v = (s.in(0x2CD) >> 2) & 1;
        hi += v; n++;
        if (v && !last) edges++;
        last = v;
        s.run(us(50));
    }
    CHECK(edges >= 6 && edges <= 7 && hi * 100 / n >= 45 && hi * 100 / n <= 55, "1/64 s: %d edges, %d %%", edges,
          hi * 100 / n);
    // 1 s standard pulse: 7.8 ms after the carry
    s.out(0x2CE, 0x04);
    s.out(0x2CD, 0x00);
    sync_carry(s, 50);
    CHECK(s.in(0x2CD) & 4, "1 s pulse after the carry");
    s.run(us(8500));
    CHECK(!(s.in(0x2CD) & 4), "1 s pulse over after 7.8 ms");
    // interrupt mode: stays until written 0
    s.out(0x2CE, 0x06);
    sync_carry(s, 50);
    s.run(us(20000));
    CHECK(s.in(0x2CD) & 4, "1 s interrupt kept");
    s.out(0x2CD, 0x04);
    CHECK(s.in(0x2CD) & 4, "writing 1 does not clear");
    s.out(0x2CD, 0x00);
    CHECK(!(s.in(0x2CD) & 4), "writing 0 clears");
    // MASK
    s.out(0x2CE, 0x07);
    sync_carry(s, 50);
    CHECK(!(s.in(0x2CD) & 4), "MASK");
    // 1 minute, 1 hour
    Clock c{1992, 1, 1, 10, 59, 58, 3};
    int r[13];
    for (int t1t0 = 2; t1t0 <= 3; t1t0++) {
        s.out(0x2CE, (t1t0 << 2) | 2);
        s.out(0x2CD, 0x00);
        regs_of(c, true, r);
        sync_carry(s, 100);
        write_regs(s, r);
        s.run(clk_per_s() + us(1000));
        CHECK(!(s.in(0x2CD) & 4), "no minute/hour event at :59");
        s.run(clk_per_s());
        CHECK(s.in(0x2CD) & 4, "minute/hour event");
    }
    s.out(0x2CE, 0x00);
    printf("irq: 1/64 s %d edges %d %% high, 1 s pulse, interrupt, MASK, minute, hour\n", edges, hi * 100 / n);
}

static void t_seed(Sim &s) {
    // HOLD defers a seed; an invalid one is ignored; 12 h mode
    Clock c{2031, 2, 3, 17, 8, 9, 1};
    s.out(0x2CD, 0x07);
    s.new_seed(m2m_of(c));
    s.run(us(500));
    CHECK(s.m.seed_tog != s.seed_t, "seed waits while HOLD");
    s.out(0x2CD, 0x04);
    s.run(100);
    check_regs(s, c, true, "seed after HOLD");
    Clock bad = c; bad.mo = 13;
    s.new_seed(m2m_of(bad));
    s.run(us(100));
    check_regs(s, c, true, "invalid seed ignored");
    s.out(0x2CF, 0x01); s.out(0x2CF, 0x00);
    Clock c2{2040, 8, 9, 0, 1, 2, 4};
    s.new_seed(m2m_of(c2));
    s.run(us(100));
    check_regs(s, c2, false, "seed in 12 h mode (midnight)");
    c2.h = 12; s.new_seed(m2m_of(c2)); s.run(us(100)); check_regs(s, c2, false, "seed 12 h noon");
    c2.h = 23; s.new_seed(m2m_of(c2)); s.run(us(100)); check_regs(s, c2, false, "seed 12 h 11 PM");
    s.out(0x2CF, 0x05); s.out(0x2CF, 0x04);
    // 2085 is 1985 to the PC
    Clock c3{2085, 6, 7, 8, 9, 10, 4};
    s.new_seed(m2m_of(c3));
    s.run(us(100));
    Clock c3p = c3; c3p.y = 1985;
    check_regs(s, c3p, true, "2085 -> 1985");
    // the data must be stable for 8 clk: a toggle with the data changing in the next clk
    Clock c4{2050, 1, 2, 3, 4, 5, 0};
    s.new_seed(m2m_of(c));
    s.run(1);
    s.seed = m2m_of(c4);
    s.run(us(100));
    check_regs(s, c4, true, "the seed taken once stable");
    // once the PC has set the clock, seeds are ignored
    int r[13];
    regs_of(c, true, r);
    write_regs(s, r);
    s.run(10);
    s.new_seed(m2m_of(c4));
    s.run(us(100));
    check_regs(s, c, true, "seed ignored after the PC set the clock");
    printf("seed: HOLD, invalid, 12 h, 2085, stability, owned\n");
}

static void t_writeback(Sim &s) {
    // (the PC owns the clock after t_seed) writes without HOLD: one pulse each
    long sets0 = s.sets;
    s.out(0x2C0, 3);
    s.run(10);
    CHECK(s.sets == sets0 + 1, "a write while running: one write-back");
    // during STOP: none until STOP is cleared
    sets0 = s.sets;
    s.out(0x2CF, 0x06);
    s.out(0x2C2, 4);
    s.out(0x2C3, 1);
    s.run(1000);
    CHECK(s.sets == sets0, "no write-back while STOP");
    s.out(0x2CF, 0x04);
    s.run(10);
    CHECK(s.sets == sets0 + 1, "write-back when STOP is cleared");
    // control registers alone: none
    sets0 = s.sets;
    s.out(0x2CE, 0x00); s.out(0x2CF, 0x04); s.out(0x2CD, 0x04);
    s.run(100);
    CHECK(s.sets == sets0, "control registers: no write-back");
    // hundredths
    sync_carry(s, 0);
    s.run(us(250000) - us(30));
    int hu = int(s.top->now & 0xFF);
    CHECK(hu == 0x24 || hu == 0x25, "hundredths 0.25 s after the carry: %02X", hu);
    printf("writeback: running, STOP, control, hundredths %02X\n", hu);
}

static void t_torture(Sim &s, int seed_n) {
    std::mt19937 rng(seed_n);
    auto R = [&](int n) { return int(rng() % n); };
    uint64_t end = s.clk + clk_per_s() * 40;
    int ops = 0;
    while (s.clk < end) {
        int k = R(100);
        if (k < 30) s.in(0x2C0 + R(16), R(40));
        else if (k < 55) {
            int a = R(16), d = R(16);
            if (a == 15) d &= R(4) ? 0x5 : 0xF;          // seldom STOP/TEST for long
            if (a == 13 && R(3)) d &= 0x5;
            s.out(0x2C0 + a, d, R(40));
        } else if (k < 60) {
            Clock c = from_t(time_t(R(1 << 30)) * 3);
            uint64_t v = m2m_of(c);
            if (R(5) == 0) v ^= uint64_t(1) << R(56);
            s.new_seed(v);
        } else if (k < 62) s.m.enable = !s.m.enable;
        else if (k < 64) { s.out(0x2CF, 0x04); s.out(0x2CD, 0x04); }
        else s.run(R(10) ? R(2000) : R(int(clk_per_s() / 2)));
        ops++;
    }
    s.m.enable = true;
    printf("torture %d: %d operations over 40 s, %ld write-backs\n", seed_n, ops, s.sets);
}

int main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IOLBF, 0);
    Verilated::commandArgs(argc, argv);
    std::vector<std::string> tests;
    for (int i = 1; i < argc; i++) tests.push_back(argv[i]);
    if (tests.empty()) {
        if (FAST) tests = {"calendar", "torture1", "torture2", "torture3"};
        else tests = {"bios", "calendar", "hold", "adjust", "stoprest", "irq", "seed"};
    }
    for (auto &t : tests) {
        Sim s;
        int f0 = failures;
        // every test but bios starts from a seeded clock
        if (t != "bios") { s.new_seed(m2m_of(base)); s.run(100); }
        if (t == "bios") t_bios(s);
        else if (t == "calendar") t_calendar(s);
        else if (t == "hold") t_hold(s);
        else if (t == "adjust") t_adjust(s);
        else if (t == "stoprest") t_stoprest(s);
        else if (t == "irq") t_irq(s);
        else if (t == "seed") { t_seed(s); t_writeback(s); }
        else if (t.rfind("torture", 0) == 0) t_torture(s, atoi(t.c_str() + 7));
        else { printf("unknown test %s\n", t.c_str()); return 2; }
        printf("%s: %s (%llu clk compared, %.2f s, %ld reads)\n", t.c_str(), failures == f0 ? "PASS" : "FAIL",
               (unsigned long long)s.clk, double(s.clk) / clk_per_s(), s.reads);
        delete s.top;
    }
    printf("%s: %ld checks, %d failures (%s oscillator)\n", failures ? "FAIL" : "PASS", checks, failures,
           FAST ? "fast" : "exact");
    return failures ? 1 : 0;
}
