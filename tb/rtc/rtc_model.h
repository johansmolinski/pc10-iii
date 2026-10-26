// rtc_model.h - reference model of the PC10-III's real-time clock (an OKI
// MSM6242B at 2C0h-2CFh) for tb/rtc, written from doc/rtc.md section 4 (the
// chip) and 5 (the MEGA65 seed and write-back), stepped once per clk like
// rtl/system/msm6242.sv.
//
// GPL-3.0-or-later, pc10-iii.
#pragma once
#include <cstdint>

struct RtcBus {
    uint32_t addr = 0x12345;
    bool ior_n = true, iow_n = true, aen = false;
    uint8_t dout = 0;
    bool sample = false;        // harness: take the read data in this clk
};

struct RtcModel {
    uint32_t NUM, DEN;
    // 0 S1 .. C W: S10/MI10 3 bits, H10 {PM, h20, h10}, D10 2, MO10 1, W 3
    int r[13] = {0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 2};
    bool hold = false, irq = false, adj = false;
    int ce = 0;
    bool rest = false, stop = false, h24 = true, test = false;
    bool busy = false, pend = false, dirty = false, owned = false, set = false;
    uint32_t acc = 0;
    unsigned div = 0;
    bool half = false;
    int busy_cnt = 0, adj_cnt = 0, irq_cnt = 0;
    uint64_t seed_q = 0;
    int seed_stable = 0;
    bool seed_tog = false;
    bool enable = true;

    RtcModel(uint32_t num, uint32_t den) : NUM(num), DEN(den) {}

    static int width(int a) {
        static const int w[13] = {4, 3, 4, 3, 4, 3, 4, 2, 4, 1, 4, 4, 3};
        return w[a];
    }

    bool sel(const RtcBus &b) const { return enable && !b.aen && ((b.addr >> 4) & 0x3F) == 0x2C; }

    int reg(int a) const {
        if (a < 13) {
            if (a == 5) return h24 ? (r[5] & 3) : r[5];
            return r[a];
        }
        if (a == 13) return (adj << 3) | (irq << 2) | (busy << 1) | hold;
        if (a == 14) return ce;
        return (test << 3) | (h24 << 2) | (stop << 1) | rest;
    }
    bool dsel(const RtcBus &b) const { return sel(b) && !b.ior_n; }
    uint8_t din(const RtcBus &b) const { return dsel(b) ? 0xF0 | reg(b.addr & 15) : 0; }

    // leap years: the binary year mod 4 (y10's parity and y1)
    static bool leap_d(int y10, int y1) {
        return (y10 & 1) ? (y1 == 2 || y1 == 6) : (y1 == 0 || y1 == 4 || y1 == 8);
    }
    static int monthlen(int mo10, int mo1, bool lp) {
        int m = mo10 * 10 + mo1;
        if (m == 2) return lp ? 29 : 28;
        if (m == 4 || m == 6 || m == 9 || m == 11) return 30;
        return 31;
    }

    // one counting step: from the seconds, or from the minutes (the 30 s
    // adjust); cm/ch: the minute / hour digits were carried into
    void step(int *t, bool from_min, bool &cm, bool &ch) const {
        bool c = from_min;
        if (!from_min) {
            if (t[1] == 5 && t[0] == 9) { t[0] = 0; t[1] = 0; c = true; }
            else if (t[0] == 9) { t[0] = 0; t[1] = (t[1] + 1) & 7; }
            else t[0] = (t[0] + 1) & 15;
        }
        cm = c;
        if (c) {
            c = false;
            if (t[3] == 5 && t[2] == 9) { t[2] = 0; t[3] = 0; c = true; }
            else if (t[2] == 9) { t[2] = 0; t[3] = (t[3] + 1) & 7; }
            else t[2] = (t[2] + 1) & 15;
        }
        ch = c;
        if (c) {
            c = false;
            int pm = t[5] & 4, h10 = t[5] & 3;
            if (h24) {
                if (h10 == 2 && t[4] == 3) { t[4] = 0; h10 = 0; c = true; }
                else if (t[4] == 9) { t[4] = 0; h10 = (h10 + 1) & 3; }
                else t[4] = (t[4] + 1) & 15;
            } else {
                // 12-hour clock: 12, 1, .., 11; 11 -> 12 flips PM/AM
                if ((h10 & 1) && t[4] == 1) { t[4] = 2; c = pm != 0; pm ^= 4; }
                else if ((h10 & 1) && t[4] == 2) { t[4] = 1; h10 &= 2; }
                else if (t[4] == 9) { t[4] = 0; h10 |= 1; }
                else t[4] = (t[4] + 1) & 15;
            }
            t[5] = pm | h10;
        }
        if (c) {
            t[12] = t[12] >= 6 ? 0 : t[12] + 1;
            c = false;
            int day = t[7] * 10 + t[6];
            if (day >= monthlen(t[9], t[8], leap_d(t[11], t[10]))) { t[6] = 1; t[7] = 0; c = true; }
            else if (t[6] == 9) { t[6] = 0; t[7] = (t[7] + 1) & 3; }
            else t[6] = (t[6] + 1) & 15;
        }
        if (c) {
            c = false;
            if (t[9] == 1 && t[8] == 2) { t[9] = 0; t[8] = 1; c = true; }
            else if (t[8] == 9) { t[8] = 0; t[9] = 1; }
            else t[8] = (t[8] + 1) & 15;
        }
        if (c) {
            if (t[10] == 9) { t[10] = 0; t[11] = t[11] == 9 ? 0 : (t[11] + 1) & 15; }
            else t[10] = (t[10] + 1) & 15;
        }
    }

    static bool bcd_ok(int v, int lo, int hi) {
        return (v & 15) <= 9 && (v >> 4) <= 9 && v >= lo && v <= hi;
    }
    static bool seed_valid(uint64_t s) {
        auto b = [&](int i) { return int((s >> (8 * i)) & 0xFF); };
        return bcd_ok(b(0), 0, 0x59) && bcd_ok(b(1), 0, 0x59) && bcd_ok(b(2), 0, 0x23) &&
               bcd_ok(b(3), 1, 0x31) && bcd_ok(b(4), 1, 0x12) && bcd_ok(b(5), 0, 0x99);
    }
    // the seed in the chip's registers (hours in the current 12/24 h mode)
    void seed_regs(uint64_t s, int *t) const {
        auto b = [&](int i) { return int((s >> (8 * i)) & 0xFF); };
        t[0] = b(0) & 15; t[1] = (b(0) >> 4) & 7;
        t[2] = b(1) & 15; t[3] = (b(1) >> 4) & 7;
        int hr = (b(2) >> 4) * 10 + (b(2) & 15);
        if (h24) { t[4] = b(2) & 15; t[5] = (b(2) >> 4) & 3; }
        else {
            int h12 = hr % 12 == 0 ? 12 : hr % 12;
            t[4] = h12 % 10; t[5] = (h12 / 10) | (hr >= 12 ? 4 : 0);
        }
        t[6] = b(3) & 15; t[7] = (b(3) >> 4) & 3;
        t[8] = b(4) & 15; t[9] = (b(4) >> 4) & 1;
        t[10] = b(5) & 15; t[11] = ((b(5) >> 4) + 2) % 10;     // years since 2000 -> since 1980
        int dow = b(6) & 7;
        t[12] = dow >= 6 ? 0 : dow + 1;                         // M2M Monday = 0 -> W Monday = 1
    }

    // the clock in M2M's register order
    uint64_t now() const {
        int hu = int((uint64_t(div) * 100) >> 15);
        uint64_t v = uint64_t(((hu / 10) << 4) | (hu % 10));
        v |= uint64_t((r[1] << 4) | r[0]) << 8;
        v |= uint64_t((r[3] << 4) | r[2]) << 16;
        int hb;
        if (h24) hb = ((r[5] & 3) << 4) | r[4];                 // the digits as they are
        else {
            int h12 = (r[5] & 1) * 10 + r[4];
            int hr = ((h12 == 12 ? 0 : h12) + ((r[5] & 4) ? 12 : 0)) & 31;
            hb = hr >= 20 ? ((2 << 4) | ((hr - 20) & 15)) : hr >= 10 ? ((1 << 4) | ((hr - 10) & 15)) : (hr & 15);
        }
        v |= uint64_t(hb & 0xFF) << 24;
        v |= uint64_t((r[7] << 4) | r[6]) << 32;
        v |= uint64_t((r[9] << 4) | r[8]) << 40;
        int y10 = r[11] >= 2 ? r[11] - 2 : r[11] + 8;           // since 1980 -> since 2000
        v |= uint64_t((y10 << 4) | r[10]) << 48;
        v |= uint64_t(r[12] == 0 ? 6 : r[12] - 1) << 56;        // W Sunday = 0 -> M2M 6
        return v;
    }

    // one clk: cur = the bus in this clk, nx = in the next one, seed = main_rtc_i
    void clock(const RtcBus &cur, const RtcBus &nx, uint64_t seed, bool seed_t) {
        int a = cur.addr & 15, d = cur.dout & 15;
        bool wr_end = sel(cur) && !cur.iow_n &&
                      !(sel(nx) && (nx.addr & 15) == unsigned(a) && !nx.iow_n);
        uint32_t accn = acc + NUM;
        bool tick = accn >= DEN;
        unsigned dn = div;
        {
            unsigned lo = (div + 1) & 3, hi = div >> 2;
            if ((div & 3) == 3 && !stop) hi = (hi + 1) & 0x1FFF;
            dn = (hi << 2) | lo;
            if (rest) dn &= 0x7F;
        }
        bool c1 = tick && !test && !stop && !rest && div == 0x7FFF;
        bool ct = tick && test && (div & 3) == 3;
        bool e64 = tick && (div & 0x100) && !(dn & 0x100) && !rest;
        bool inc1 = (c1 || ct) && !hold;
        bool rel = wr_end && a == 13 && hold && !(d & 1) && pend;
        bool inc = inc1 || rel;
        bool adj_end = adj && tick && adj_cnt == 1;
        bool adj_up = r[1] >= 3;
        int st[13];
        bool cm = false, ch = false;
        if (inc || adj_end) {
            for (int i = 0; i < 13; i++) st[i] = r[i];
            step(st, adj_end, cm, ch);
        }

        // next state
        RtcModel n = *this;
        n.set = false;
        n.acc = tick ? accn - DEN : accn;
        if (tick) {
            n.div = dn;
            n.half = !half;
            if (busy_cnt) n.busy_cnt = busy_cnt - 1;
            if (adj_cnt) n.adj_cnt = adj_cnt - 1;
            if (half && !hold) n.busy = busy_cnt != 0;
            if (!stop && irq_cnt) {
                n.irq_cnt = irq_cnt - 1;
                if (irq_cnt == 1 && !(ce & 2)) n.irq = false;
            }
        }
        if ((c1 || ct) && hold) n.pend = true;
        if (rel) n.pend = c1 || ct;
        if (adj_end) {
            if (adj_up) for (int i = 0; i < 13; i++) n.r[i] = st[i];
            n.r[0] = 0; n.r[1] = 0;
            n.adj = false;
            n.div &= 0x7F;
            n.dirty = true;
        } else if (inc) {
            for (int i = 0; i < 13; i++) n.r[i] = st[i];
        }
        if (inc) { n.busy = true; n.busy_cnt = 6; }
        {
            bool ev;
            switch (ce >> 2) {
            case 0: ev = e64; break;
            case 1: ev = inc; break;
            case 2: ev = adj_end ? adj_up : inc && cm; break;
            default: ev = adj_end ? adj_up && ch : inc && ch; break;
            }
            if (ev && !(ce & 1) && (!irq || !(ce & 2))) { n.irq = true; n.irq_cnt = 256; }
        }
        // the seed
        bool seed_new = seed_t != seed_tog && seed == seed_q && seed_stable >= 8;
        n.seed_q = seed;
        if (seed != seed_q) n.seed_stable = 0;
        else if (seed_stable != 15) n.seed_stable = seed_stable + 1;
        if (seed_new && (owned || !hold)) n.seed_tog = seed_t;
        if (seed_new && !owned && !hold && seed_valid(seed)) {
            seed_regs(seed, n.r);
            n.div = 0;
            n.pend = false;
        }
        // the CPU's writes
        if (wr_end) {
            if (a < 13) n.r[a] = d & ((1 << width(a)) - 1);
            else if (a == 13) {
                n.hold = d & 1;
                if (!(d & 4)) { n.irq = false; n.irq_cnt = 0; }
                if ((d & 8) && !adj) { n.adj = true; n.adj_cnt = 4; }
            } else if (a == 14) n.ce = d;
            else {
                n.rest = d & 1;
                n.stop = (d >> 1) & 1;
                if (rest) n.h24 = (d >> 2) & 1;
                n.test = (d >> 3) & 1;
            }
            if (a <= 12) n.dirty = true;
        }
        if (dirty && !hold && !stop && !adj && !(wr_end && a <= 12)) {
            n.set = true;
            n.owned = true;
            n.dirty = false;
        }
        *this = n;
    }
};
