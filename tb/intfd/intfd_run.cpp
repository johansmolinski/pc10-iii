// intfd_run.cpp - Verilator testbench for drive B: as the real drive
// (rtl/fdc/fdd_intdrv.sv, fdd_phys.sv, fdd_mfm_rd.sv, fdd_mfm_wr.sv) behind
// the FDC card (rtl/fdc/fdc_card.sv), doc/fdc.md section 10.
//
// The card bus is driven like the BIOS does (CPU I/O cycles, an 8237-like DMA
// model on channel 2; the helpers of tb/fdc/fdc_run.cpp). Drive A: (and B:
// while it is an image) is served from an in-memory image. Drive B: is a
// model of a 3.5" DD drive on the 34-pin interface:
//   * the disk: per cylinder and side, the flux transitions of the track as
//     positions in nanoseconds after the index (nominal 300 rpm), built from
//     sector data in the IBM layout (gaps, sync, IDAM/DAM, CRC) or empty
//     (unformatted);
//   * the spindle: motor on -> the speed ramps up in 300 ms; a speed factor
//     (+-2 %) and a Gaussian jitter on every read pulse; INDEX low for 2 ms
//     per turn; RDATA a 210 ns low pulse per transition under the head;
//   * the head: STEP falling edges while selected (STEPDIR high = outward),
//     stops at 0 and 82, a step can be lost on purpose; TRK0, WPT; SIDE1;
//   * writing: while WGATE is low the WDATA falling edges are new
//     transitions at the head's position; at the end of the gate the old
//     transitions between gate start and end are replaced (the erase);
//   * all outputs idle high while the drive is not selected.
// An independent software decoder (interval PLL, 0x4489 sync, CRC) reads the
// model's tracks back to check what was written.
//
//   ./obj/intfd_run [-v] [-s seed]
//
// GPL-3.0-or-later, pc10-iii.

#include "Vtb_intfd.h"
#include "verilated.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <random>
#include <string>
#include <vector>

static const double CLK_HZ = 28636363.64;
static const double CLK_NS = 1e9 / CLK_HZ;
static const int C = 6;                           // clk per 4.77 MHz CPU clock
static uint64_t us2clk(double us) { return (uint64_t)(us * CLK_HZ / 1e6 + 0.5); }
static double clk2ms(uint64_t c) { return c * 1e3 / CLK_HZ; }

static int fails = 0, checks = 0;
static bool verbose = false;

#define CHECK(cond, ...) do { checks++; if (!(cond)) { fails++; \
    printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// ------------------------------------------------------------ CRC, MFM
static uint16_t crc16(uint16_t c, uint8_t b) {
    for (int i = 7; i >= 0; i--) {
        bool fb = ((c >> 15) ^ (b >> i)) & 1;
        c = (uint16_t)(c << 1);
        if (fb) c ^= 0x1021;
    }
    return c;
}

// IBM MFM channel bits of a byte sequence (kind: 0 data, 1 A1*, 2 C2*)
struct MfmOut {
    std::vector<uint8_t> bits;
    int prev = 0;
    void put(uint8_t b, int kind = 0) {
        uint16_t w = 0;
        int q = prev;
        for (int i = 7; i >= 0; i--) {
            int d = (b >> i) & 1;
            int c = !(q | d);
            w |= (uint16_t)(c << (2 * i + 1)) | (uint16_t)(d << (2 * i));
            q = d;
        }
        if (kind == 1) w &= ~0x0020;
        if (kind == 2) w &= ~0x0080;
        for (int i = 15; i >= 0; i--) bits.push_back((w >> i) & 1);
        prev = b & 1;
    }
    void rep(uint8_t b, int n) { for (int i = 0; i < n; i++) put(b); }
};

static const double REV_NS = 200e6;              // 300 rpm
static const double CELL_NS = 2000.0;

struct Layout {
    int gap3 = 80;
    int spt = 9;
    std::vector<int> order;                      // R in physical order (empty: 1..spt)
    int bad_data_crc_r = 0;                      // this sector gets a wrong data CRC
    int bad_id_crc_r = 0;                        // this sector's ID field gets a wrong CRC
    int id_c = -1;                               // C written in the IDs (-1: the cylinder)
    int id_h = -1;                               // H written in the IDs (-1: the side)
};

// a track in the IBM layout, as flux positions (ns after the index)
static std::vector<double> build_track(int c, int h, const uint8_t *data /* spt x 512, by R */,
                                       const Layout &L, double scale = 1.0, double offset = 0) {
    MfmOut m;
    m.rep(0x4E, 80); m.rep(0x00, 12);
    for (int i = 0; i < 3; i++) m.put(0xC2, 2);
    m.put(0xFC); m.rep(0x4E, 50);
    for (int k = 0; k < L.spt; k++) {
        int r = L.order.empty() ? k + 1 : L.order[k];
        m.rep(0x00, 12);
        uint16_t crc = 0xFFFF;
        for (int i = 0; i < 3; i++) { m.put(0xA1, 1); crc = crc16(crc, 0xA1); }
        uint8_t id[5] = { 0xFE, (uint8_t)(L.id_c < 0 ? c : L.id_c), (uint8_t)(L.id_h < 0 ? h : L.id_h),
                          (uint8_t)r, 2 };
        for (int i = 0; i < 5; i++) { m.put(id[i]); crc = crc16(crc, id[i]); }
        if (r == L.bad_id_crc_r) crc ^= 0x0101;
        m.put(crc >> 8); m.put(crc & 0xFF);
        m.rep(0x4E, 22); m.rep(0x00, 12);
        crc = 0xFFFF;
        for (int i = 0; i < 3; i++) { m.put(0xA1, 1); crc = crc16(crc, 0xA1); }
        m.put(0xFB); crc = crc16(crc, 0xFB);
        const uint8_t *d = data + (size_t)(r - 1) * 512;
        for (int i = 0; i < 512; i++) { m.put(d[i]); crc = crc16(crc, d[i]); }
        if (r == L.bad_data_crc_r) crc ^= 0x1234;
        m.put(crc >> 8); m.put(crc & 0xFF);
        m.rep(0x4E, L.gap3);
    }
    while (m.bits.size() < 99000) m.put(0x4E);   // GAP4b (a little short of a turn)
    std::vector<double> t;
    for (size_t i = 0; i < m.bits.size(); i++)
        if (m.bits[i]) t.push_back(offset + (i * CELL_NS + CELL_NS / 2) * scale);
    return t;
}

// ------------------------------------------------------------ software decoder
struct DSector {
    int c, h, r, n;
    bool id_ok, data_ok, has_data;
    std::vector<uint8_t> d;
    double pos;
};
struct DTrack {
    std::vector<DSector> secs;
    int iam = 0;
    const DSector *find(int r) const {
        for (auto &s : secs) if (s.r == r) return &s;
        return nullptr;
    }
};

static DTrack decode_track(const std::vector<double> &t) {
    DTrack out;
    if (t.size() < 2) return out;
    // intervals -> channel bits with an adaptive cell estimate
    std::vector<uint8_t> bits;
    std::vector<double> bpos;
    double cell = CELL_NS;
    for (size_t i = 1; i < t.size(); i++) {
        double iv = t[i] - t[i - 1];
        int n = (int)std::lround(iv / cell);
        if (n < 2 || n > 4) {                     // out of lock: a gap or a splice
            if (n > 4) n = std::min(n, 64);
            else n = 2;
        } else
            cell += (iv / n - cell) * 0.05;
        for (int k = 1; k < n; k++) { bits.push_back(0); bpos.push_back(t[i]); }
        bits.push_back(1); bpos.push_back(t[i]);
    }
    // bytes after A1* syncs
    // (C2* = 0x5224 can occur inside data at other bit positions: it does
    // not frame; three of them 16 bits apart are the index address mark)
    uint16_t sr = 0;
    int cnt = -1;
    std::vector<int> bytes;          // value | 0x100 for a sync
    std::vector<double> bytepos;
    std::vector<size_t> c2at;
    for (size_t i = 0; i < bits.size(); i++) {
        sr = (uint16_t)((sr << 1) | bits[i]);
        if (sr == 0x5224) {
            c2at.push_back(i);
            size_t n = c2at.size();
            if (n >= 3 && c2at[n - 2] == i - 16 && c2at[n - 3] == i - 32) out.iam++;
        }
        if (sr == 0x4489) { bytes.push_back(0x1A1); bytepos.push_back(bpos[i]); cnt = 0; continue; }
        if (cnt < 0) continue;
        if (++cnt == 16) {
            int b = 0;
            for (int k = 0; k < 8; k++) b |= ((sr >> (2 * k)) & 1) << k;
            bytes.push_back(b); bytepos.push_back(bpos[i]);
            cnt = 0;
        }
    }
    for (size_t i = 0; i + 3 < bytes.size(); i++) {
        if (!(bytes[i] == 0x1A1 && bytes[i + 1] == 0x1A1 && bytes[i + 2] == 0x1A1 && bytes[i + 3] == 0xFE))
            continue;
        if (i + 9 >= bytes.size()) break;
        uint16_t crc = 0xCDB4;
        crc = crc16(crc, 0xFE);
        bool sync_in = false;
        for (int k = 4; k < 10; k++) { if (bytes[i + k] > 0xFF) sync_in = true; crc = crc16(crc, bytes[i + k] & 0xFF); }
        DSector s;
        s.c = bytes[i + 4] & 0xFF; s.h = bytes[i + 5] & 0xFF; s.r = bytes[i + 6] & 0xFF; s.n = bytes[i + 7] & 0xFF;
        s.id_ok = crc == 0 && !sync_in;
        s.has_data = false; s.data_ok = false;
        s.pos = bytepos[i];
        // the data field: within 60 bytes
        for (size_t j = i + 10; j + 3 < bytes.size() && j < i + 70; j++) {
            if (bytes[j] == 0x1A1 && bytes[j + 1] == 0x1A1 && bytes[j + 2] == 0x1A1 &&
                (bytes[j + 3] == 0xFB || bytes[j + 3] == 0xF8)) {
                if (j + 4 + 514 > bytes.size()) break;
                uint16_t c2 = crc16(0xCDB4, bytes[j + 3]);
                bool si = false;
                for (int k = 0; k < 514; k++) {
                    int v = bytes[j + 4 + k];
                    if (v > 0xFF) si = true;
                    c2 = crc16(c2, v & 0xFF);
                    if (k < 512) s.d.push_back(v & 0xFF);
                }
                s.has_data = true;
                s.data_ok = c2 == 0 && !si;
                break;
            }
            if (bytes[j] == 0x1A1 && bytes[j + 1] == 0x1A1 && bytes[j + 2] == 0x1A1 && bytes[j + 3] == 0xFE)
                break;
        }
        out.secs.push_back(s);
    }
    return out;
}

// ------------------------------------------------------------ the drive model
struct Drive {
    // configuration
    bool disk = true, wp = false;
    double speed = 1.0;              // 1.02 = 2 % fast
    double jitter_ns = 60;
    int cyl = 30;
    int maxcyl = 82;
    int lose_steps = 0;              // the next n steps move nothing
    double runt_p = 0;               // probability of a runt (a 2nd pulse 150 ns after one)
    std::vector<double> trk[84][2];
    std::mt19937 rng{7};

    // state
    bool motor = false;
    double spin_ns = 0;              // time since the motor came on
    double pos = 0;                  // ns after the index (nominal)
    double upos = 0;                 // the same, not wrapped
    bool prev_step_n = true, prev_wdata_n = true, prev_gate_n = true;
    std::deque<double> pulses;       // read pulse start times (ns, absolute)
    double now = 0;
    double rd_end = -1, rd_start = -1, rd_last = -1e9;
    // write session
    bool writing = false;
    double gate_start = 0, gate_turn = 0;
    int wr_c = 0, wr_h = 0;
    std::vector<double> wr_pulses;
    std::vector<std::vector<double>> sessions;      // the written pulses of each session
    std::vector<int> session_cyl;
    int gate_count = 0;
    // statistics
    std::vector<double> step_t;      // times of the step pulses that moved (ms)
    int steps_out = 0, steps_in = 0, steps_unselected = 0;
    int selects = 0;

    double cur_speed() const {
        if (!motor) return 0;
        double r = std::min(1.0, spin_ns / 300e6);
        return speed * r;
    }
    bool at_speed() const { return motor && spin_ns >= 300e6; }

    void erase_insert(int c, int h, double a, double b, const std::vector<double> &ins) {
        auto &t = trk[c][h];
        std::vector<double> n;
        auto inside = [&](double x) {
            if (a <= b) return x >= a && x < b;
            return x >= a || x < b;               // across the index
        };
        for (double x : t) if (!inside(x)) n.push_back(x);
        for (double x : ins) n.push_back(x);
        std::sort(n.begin(), n.end());
        t = n;
    }

    // one clk: the pins from the core (as registered after the last edge),
    // returns the drive's outputs through the references
    void tick(bool motor_n, bool select_n, bool stepdir_n, bool step_n, bool side1_n,
              bool wdata_n, bool wgate_n,
              uint8_t &index_n, uint8_t &track0_n, uint8_t &wpt_n, uint8_t &rdata_n) {
        now += CLK_NS;
        bool sel = !select_n;
        bool mot = !motor_n;
        if (mot && !motor) spin_ns = 0;
        motor = mot;
        if (motor) spin_ns += CLK_NS;
        int h = side1_n ? 0 : 1;

        // head
        if (prev_step_n && !step_n) {
            if (!sel) steps_unselected++;
            else if (lose_steps > 0) lose_steps--;
            else {
                int old = cyl;
                if (stepdir_n) { if (cyl > 0) cyl--; } else { if (cyl < maxcyl) cyl++; }
                if (cyl != old) { step_t.push_back(now / 1e6); (stepdir_n ? steps_out : steps_in)++; }
                if (verbose) printf("     [drive] step %s -> %d at %.3f ms\n", stepdir_n ? "out" : "in", cyl, now / 1e6);
            }
        }
        prev_step_n = step_n;

        // rotation
        double old = pos;
        double sp = disk ? cur_speed() : 0;
        pos += CLK_NS * sp;
        upos += CLK_NS * sp;
        bool wrapped = false;
        if (pos >= REV_NS) { pos -= REV_NS; wrapped = true; }

        // writing (positions unwrapped: a write longer than a turn overwrites its own start)
        bool gate = sel && !wgate_n && motor && disk;
        if (gate && !writing) {
            writing = true; gate_start = upos; wr_c = cyl; wr_h = h; wr_pulses.clear();
            gate_count++;
        }
        if (writing && prev_wdata_n && !wdata_n && gate) wr_pulses.push_back(upos);
        if (writing && !gate) {
            writing = false;
            std::vector<double> ins;
            double a = gate_start, b = upos;
            for (double x : wr_pulses) if (x >= b - REV_NS) ins.push_back(std::fmod(x, REV_NS));
            if (wr_c < 84) {
                if (b - a >= REV_NS) erase_insert(wr_c, wr_h, 0, REV_NS, ins);
                else erase_insert(wr_c, wr_h, std::fmod(a, REV_NS), std::fmod(b, REV_NS), ins);
            }
            sessions.push_back(wr_pulses);
            session_cyl.push_back(wr_c);
            if (verbose) printf("     [drive] write C%d H%d: %zu pulses, %.3f ms, from %.3f to %.3f ms\n", wr_c, wr_h,
                                wr_pulses.size(), wr_pulses.empty() ? 0 : (wr_pulses.back() - wr_pulses.front()) / 1e6,
                                std::fmod(a, REV_NS) / 1e6, std::fmod(b, REV_NS) / 1e6);
        }
        prev_wdata_n = wdata_n;
        prev_gate_n = wgate_n;

        // reading: transitions passed in this clk become pulses
        if (sp > 0 && !writing && cyl < 84) {
            auto &t = trk[cyl][h];
            auto emit = [&](double a, double b) {
                auto it = std::lower_bound(t.begin(), t.end(), a);
                for (; it != t.end() && *it < b; ++it) {
                    // a constant 1.5 us read-channel delay plus the jitter (clamped
                    // to +-1 us: the pulses keep their order)
                    double j = std::normal_distribution<double>(0, jitter_ns)(rng);
                    j = std::max(-1000.0, std::min(1000.0, j));
                    pulses.push_back(now + 1500 + j);
                    if (runt_p > 0 && std::uniform_real_distribution<double>(0, 1)(rng) < runt_p)
                        pulses.push_back(now + 1500 + j + 150);
                }
            };
            if (!wrapped) emit(old, pos);
            else { emit(old, REV_NS); emit(0, pos); }
        }
        bool rd = false;
        while (!pulses.empty() && pulses.front() <= now) {
            rd_start = pulses.front();
            rd_end = pulses.front() + (pulses.front() - rd_last < 200 ? 60 : 120);
            rd_last = pulses.front();
            pulses.pop_front();
        }
        if (now < rd_end && now >= rd_start) rd = true;

        index_n  = !(sel && disk && motor && sp > 0 && pos < 2e6);
        track0_n = !(sel && cyl == 0);
        wpt_n    = !(sel && wp);
        rdata_n  = !(sel && rd);
    }
};

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
    uint8_t *sec(int c, int h, int r) { return &d[(size_t)lba(c, h, r) * 512]; }
};

// ------------------------------------------------------------ the simulation
struct Sim {
    Vtb_intfd *t;
    uint64_t cyc = 0;
    std::mt19937 rng;
    Image img[2];
    Image disk;                      // the real disk's contents (expected)
    Drive drv;
    std::vector<uint8_t> mem;
    int img_requests[2] = { 0, 0 };
    int sel_while_off = 0;           // the drive selected while B: is an image
    bool enable_d = true;

    struct {
        bool armed = false;
        int  dir = 0;
        uint32_t addr = 0;
        int count = 0, done = 0, phase = 0;
        uint64_t t0 = 0;
        bool tc = false;
    } dma;
    bool cpu_busy = false;

    struct {
        int state = 0, cnt = 0, drv = 0, lba = 0;
        bool wr = false, err = false, prev_req = false;
        std::vector<uint8_t> wbuf;
    } be;

    Sim(uint32_t seed) : rng(seed), mem(1 << 20, 0) {
        t = new Vtb_intfd;
        t->clk = 0; t->reset = 1; t->pc_reset = 0; t->enable = 1;
        t->isa_ior_n = 1; t->isa_iow_n = 1; t->isa_aen = 0; t->isa_dack_n = 0xF;
        t->isa_tc = 0; t->isa_addr = 0; t->isa_dout = 0;
        t->i_sp_rd_valid = 0; t->i_sp_wr_ready = 0; t->i_sp_done = 0; t->i_sp_err = 0;
        t->f_index_n = 1; t->f_track0_n = 1; t->f_wpt_n = 1; t->f_rdata_n = 1;
        apply_drives();
        t->eval();                      // the outputs' power-up values before the models look
        for (int i = 0; i < 20; i++) tick();
        t->reset = 0;
    }

    void apply_drives() {
        t->i_img_present = (img[0].present ? 1 : 0) | (img[1].present ? 2 : 0);
        t->i_img_wp      = (img[0].wp ? 1 : 0) | (img[1].wp ? 2 : 0);
        t->i_img_tracks  = (img[1].tracks << 8) | img[0].tracks;
        t->i_img_heads   = (img[1].heads << 2) | img[0].heads;
        t->i_img_spt     = (img[1].spt << 6) | img[0].spt;
        t->i_drv_80trk   = (img[0].tracks == 80 ? 1 : 0) | (img[1].tracks == 80 ? 2 : 0);
    }

    // the real disk from an image (all tracks formatted in the standard layout)
    void format_disk(const Layout &L = Layout()) {
        for (int c = 0; c < 80; c++)
            for (int h = 0; h < 2; h++)
                drv.trk[c][h] = build_track(c, h, disk.sec(c, h, 1), L);
    }

    int rnd(int a, int b) { return std::uniform_int_distribution<int>(a, b)(rng); }

    void tick() {
        backend();
        dma_model();
        uint8_t ix, t0, wp, rd;
        drv.tick(t->f_motor_n, t->f_select_n, t->f_stepdir_n, t->f_step_n, t->f_side1_n,
                 t->f_wdata_n, t->f_wgate_n, ix, t0, wp, rd);
        t->f_index_n = ix; t->f_track0_n = t0; t->f_wpt_n = wp; t->f_rdata_n = rd;
        if (!t->enable && !enable_d && (!t->f_select_n || !t->f_motor_n || !t->f_wgate_n)) sel_while_off++;
        enable_d = t->enable;
        t->clk = 0; t->eval();
        t->clk = 1; t->eval();
        cyc++;
    }
    void run_us(double us) { uint64_t e = cyc + us2clk(us); while (cyc < e) tick(); }
    void run_ms(double ms) { run_us(ms * 1000); }
    bool irq() const { return (t->isa_irq >> 4) & 1; }

    // the image backend (A:, B: as an image)
    void backend() {
        auto &b = be;
        t->i_sp_done = 0; t->i_sp_err = 0; t->i_sp_rd_valid = 0; t->i_sp_wr_ready = 0;
        bool req = t->i_sp_req;
        if (b.state == 0 && req && !b.prev_req) {
            b.drv = t->sp_drive; b.wr = t->sp_write; b.lba = t->sp_lba;
            img_requests[b.drv]++;
            Image &im = img[b.drv];
            b.err = !im.present || (size_t)(b.lba + 1) * 512 > im.d.size();
            b.cnt = 0; b.wbuf.clear(); b.state = 1;
        }
        b.prev_req = req;
        Image &im = img[b.drv];
        switch (b.state) {
        case 1:
            if (b.err) { t->i_sp_done = 1; t->i_sp_err = 1; b.state = 3; break; }
            if (!b.wr) {
                t->i_sp_rd_valid = 1;
                t->i_sp_rd_data = im.d[(size_t)b.lba * 512 + b.cnt];
                if (++b.cnt == 512) { t->i_sp_done = 1; b.state = 3; }
            } else if (t->sp_wr_valid) {
                t->i_sp_wr_ready = 1;
                b.wbuf.push_back(t->sp_wr_data);
                if (b.wbuf.size() == 512) b.state = 2;
            }
            break;
        case 2:
            memcpy(&im.d[(size_t)b.lba * 512], b.wbuf.data(), 512);
            t->i_sp_done = 1; b.state = 3;
            break;
        case 3:
            if (!req) b.state = 0;
            break;
        }
    }

    // DMA channel 2 (single transfer, as tb/fdc)
    void dma_model() {
        auto &m = dma;
        switch (m.phase) {
        case 0:
            if (m.armed && ((t->isa_drq >> 1) & 1) && !cpu_busy) { m.phase = 1; m.t0 = cyc; }
            break;
        case 1:
            if (cyc - m.t0 >= 2 * C) {
                t->isa_aen = 1; t->isa_addr = m.addr & 0xFFFFF; t->isa_dack_n = 0xF & ~4;
                m.tc = m.count == 0; m.phase = 2; m.t0 = cyc;
            }
            break;
        case 2:
            if (cyc - m.t0 >= 1 * C) {
                if (m.dir == 1) t->isa_ior_n = 0;
                else { t->isa_dout = mem[m.addr & 0xFFFFF]; t->isa_iow_n = 0; }
                t->isa_tc = m.tc; m.phase = 3; m.t0 = cyc;
            }
            break;
        case 3:
            if (cyc - m.t0 >= 3 * C) {
                if (m.dir == 1) mem[m.addr & 0xFFFFF] = t->isa_din;
                t->isa_ior_n = 1; t->isa_iow_n = 1; m.phase = 4; m.t0 = cyc;
            }
            break;
        case 4:
            if (cyc - m.t0 >= C / 3) {
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

    void wait_bus() { while (!dma_idle()) tick(); }
    void io_write(int port, int val) {
        wait_bus();
        cpu_busy = true;
        t->isa_addr = port; t->isa_aen = 0;
        for (int i = 0; i < C + C / 3; i++) tick();
        t->isa_dout = val; t->isa_iow_n = 0;
        for (int i = 0; i < 8 * C / 3; i++) tick();
        t->isa_iow_n = 1;
        for (int i = 0; i < C; i++) tick();
        cpu_busy = false;
        for (int i = 0; i < 2 * C; i++) tick();
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
    std::vector<int> seek(int unit, int c, double ms = 2000) {
        cmd({ 0x0F, unit, c });
        CHECK(wait_irq(ms), "no IRQ after SEEK %d to %d", unit, c);
        return sense_int();
    }
    std::vector<int> recal(int unit, double ms = 2000) {
        cmd({ 0x07, unit });
        CHECK(wait_irq(ms), "no IRQ after RECALIBRATE %d", unit);
        return sense_int();
    }
};

static std::string hex(const std::vector<int> &v) {
    std::string s;
    char b[8];
    for (int x : v) { snprintf(b, sizeof b, "%02X ", x & 0xFF); s += b; }
    return s;
}

// READ DATA / WRITE DATA: op 0xE6 (MT MF SK read) / 0xC5 (MT MF write)
static std::vector<int> rw(Sim &s, int op, int unit, int c, int h, int r, int eot, int dma_dir,
                           uint32_t addr, int nbytes, double timeout_ms = 3000, bool *got_irq = nullptr) {
    if (dma_dir) s.dma_setup(dma_dir, addr, nbytes);
    s.cmd({ op, (h << 2) | unit, c, h, r, 2, eot, 0x2A, 0xFF });
    bool got = s.wait_irq(timeout_ms);
    if (got_irq) *got_irq = got;
    else CHECK(got, "no IRQ6 after command %02X C%d H%d R%d", op, c, h, r);
    if (!got) { s.dma_mask(); return {}; }
    auto res = s.results(7);
    s.dma_mask();
    return res;
}

static int cmp(const uint8_t *a, const uint8_t *b, int n, const char *what) {
    int bad = 0;
    for (int i = 0; i < n; i++) if (a[i] != b[i]) {
        if (bad < 3) printf("     %s: byte %d (sector %d +%d) = %02X, expected %02X\n", what, i, i / 512, i % 512, a[i], b[i]);
        bad++;
    }
    return bad;
}

// read sectors of the real disk through the card and compare with the expected disk
static bool read_check(Sim &s, int c, int h, int r, int eot, const char *what, double *ms = nullptr) {
    int n = eot - r + 1;
    memset(&s.mem[0x10000], 0xEE, n * 512);
    uint64_t t0 = s.cyc;
    auto res = rw(s, 0xE6, 1, c, h, r, eot, 1, 0x10000, n * 512);
    if (ms) *ms = clk2ms(s.cyc - t0);
    bool ok = res.size() == 7 && (res[0] & 0xC0) == 0;
    CHECK(ok, "%s: read C%d H%d R%d-%d: results %s", what, c, h, r, eot, hex(res).c_str());
    int bad = cmp(&s.mem[0x10000], s.disk.sec(c, h, r), n * 512, what);
    CHECK(bad == 0, "%s: %d bytes differ", what, bad);
    if (verbose) printf("     %s: %s %.1f ms\n", what, hex(res).c_str(), clk2ms(s.cyc - t0));
    return ok && bad == 0;
}

static bool write_sectors(Sim &s, int c, int h, int r, int eot, uint32_t salt, const char *what) {
    int n = eot - r + 1;
    for (int i = 0; i < n * 512; i++) s.mem[0x20000 + i] = (uint8_t)(i * 7 + salt + (i >> 9) * 13);
    auto res = rw(s, 0xC5, 1, c, h, r, eot, 2, 0x20000, n * 512);
    bool ok = res.size() == 7 && (res[0] & 0xC0) == 0;
    CHECK(ok, "%s: write C%d H%d R%d-%d: results %s", what, c, h, r, eot, hex(res).c_str());
    if (ok) memcpy(s.disk.sec(c, h, r), &s.mem[0x20000], n * 512);
    return ok;
}

// the model's track against the expected disk: every sector with its ID, data and CRCs
static int check_track(Sim &s, int c, int h, const char *what, int fill = -1) {
    DTrack d = decode_track(s.drv.trk[c][h]);
    int bad = 0;
    for (int r = 1; r <= 9; r++) {
        const DSector *x = d.find(r);
        if (!x) { printf("     %s: C%d H%d R%d not on the track\n", what, c, h, r); bad++; continue; }
        if (!x->id_ok || x->c != c || x->h != h || x->n != 2) {
            printf("     %s: R%d: ID %d/%d/%d/%d crc %d\n", what, r, x->c, x->h, x->r, x->n, x->id_ok); bad++;
        }
        if (!x->has_data || !x->data_ok) {
            printf("     %s: R%d: data %d crc %d\n", what, r, x->has_data, x->data_ok); bad++; continue;
        }
        if (fill >= 0) {
            for (int i = 0; i < 512; i++) if (x->d[i] != fill) { bad++; break; }
        } else if (memcmp(x->d.data(), s.disk.sec(c, h, r), 512)) {
            printf("     %s: R%d: data differ\n", what, r); bad++;
        }
    }
    int extra = (int)d.secs.size() - 9;
    if (extra) { printf("     %s: %d ID fields more than 9\n", what, extra); bad++; }
    return bad;
}

// the write precompensation of a write session: written pulses are on the
// writer's cell grid (phase of the first pulse), shifted early when the gap
// before is shorter than the gap after, late in the mirror case
static void precomp_stats(const std::vector<double> &p, int &none, int &early, int &late, int &wrong) {
    none = early = late = wrong = 0;
    if (p.size() < 8) return;
    double ph = p[0];
    auto res = [&](double x) {
        double r = std::fmod(x - ph, CELL_NS);
        if (r > CELL_NS / 2) r -= CELL_NS;
        if (r < -CELL_NS / 2) r += CELL_NS;
        return r;
    };
    for (size_t i = 1; i + 1 < p.size(); i++) {
        int gb = (int)std::lround((p[i] - p[i - 1]) / CELL_NS);
        int ga = (int)std::lround((p[i + 1] - p[i]) / CELL_NS);
        double r = res(p[i]);
        int cls = r < -70 ? -1 : r > 70 ? 1 : 0;
        if (cls == 0) none++; else if (cls < 0) early++; else late++;
        if (i < 3 || i + 3 >= p.size()) continue;          // ends: not judged
        int expv = gb < ga ? -1 : gb > ga ? 1 : 0;
        if (std::fabs(r) > 220) wrong++;
        else if (cls != expv) wrong++;
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    setvbuf(stdout, nullptr, _IOLBF, 0);
    uint32_t seed = 1;
    bool only_fmt = false;          // -f: the set-up, then the FORMAT sections only (debugging)
    bool margin = false;            // -m: the set-up, then reads at speeds x jitters (a table)
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-v")) verbose = true;
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) seed = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-f")) only_fmt = true;
        else if (!strcmp(argv[i], "-m")) margin = true;
    }

    Sim s(seed);
    s.drv.rng.seed(seed * 7919 + 1);
    s.img[0].make(40, 2, 9, 0x360);              // A: 360K image
    s.img[1].make(80, 2, 9, 0x721);              // B:'s image (used while B: is an image)
    s.disk.make(80, 2, 9, 0x5A5);                // the real disk in the drive
    s.apply_drives();
    s.format_disk();
    s.drv.cyl = 30;                              // the head somewhere after power-up

    // ======================================================== homing
    printf("== homing at enable (%.0f ms)\n", clk2ms(s.cyc));
    s.run_ms(400);
    CHECK(s.drv.cyl == 0 && s.t->known && s.t->cyl == 0, "after homing: drive at %d, known %d, cyl %d",
          s.drv.cyl, s.t->known, s.t->cyl);
    CHECK(s.drv.steps_out == 30, "homing: %d steps out", s.drv.steps_out);
    {
        double mind = 1e9;
        for (size_t i = 1; i < s.drv.step_t.size(); i++) mind = std::min(mind, s.drv.step_t[i] - s.drv.step_t[i - 1]);
        CHECK(mind > 5.9, "homing step period %.3f ms", mind);
    }
    CHECK(s.t->f_motor_n, "the motor runs without a request");
    CHECK(s.drv.steps_unselected == 0, "steps while deselected: %d", s.drv.steps_unselected);
    CHECK(!(s.t->img_present & 2), "B: present without the motor");

    // ======================================================== controller set-up
    printf("== reset, SPECIFY, motor B: (%.0f ms)\n", clk2ms(s.cyc));
    s.io_write(0x3F2, 0x00);
    s.io_write(0x3F2, 0x0C);
    CHECK(s.wait_irq(5), "no IRQ after reset");
    for (int u = 0; u < 4; u++) s.sense_int();
    s.cmd({ 0x03, 0xCF, 0x02 });                 // SRT 8 ms, HUT, HLT 4 ms, DMA
    s.io_write(0x3F2, 0x2D);                     // B: selected, motor B:, DMA/IRQ, no reset
    uint64_t mon = s.cyc;
    while (!(s.t->img_present & 2) && s.cyc - mon < us2clk(1e6)) s.tick();
    double pres_ms = clk2ms(s.cyc - mon);
    CHECK(s.t->img_present & 2, "B: never present after the motor came on");
    CHECK(pres_ms < 700, "B: present %.1f ms after the motor came on", pres_ms);
    CHECK(!(s.t->img_wp & 2), "B: write protected");
    auto r0 = s.recal(1);
    CHECK(r0.size() == 2 && r0[0] == 0x21 && r0[1] == 0, "RECALIBRATE B: %s", hex(r0).c_str());

    if (only_fmt) goto fmt;
    if (margin) {
        s.seek(1, 5);
        for (double sp : { 0.97, 0.98, 1.0, 1.02, 1.03 })
            for (double j : { 60.0, 100.0, 150.0, 200.0 }) {
                s.drv.speed = sp; s.drv.jitter_ns = j;
                int bad = 0, n = 0;
                for (int k = 0; k < 4; k++) {
                    memset(&s.mem[0x10000], 0xEE, 9 * 512);
                    auto res = rw(s, 0xE6, 1, 5, k & 1, 1, 9, 1, 0x10000, 9 * 512);
                    n++;
                    if (res.size() != 7 || (res[0] & 0xC0) || cmp(&s.mem[0x10000], s.disk.sec(5, k & 1, 1), 9 * 512, "m"))
                        bad++;
                }
                printf("speed %.2f jitter %3.0f ns: %d of %d track reads failed\n", sp, j, bad, n);
            }
        goto end;
    }

    // ======================================================== seek mirror
    printf("== SEEK 10: the real head follows the model's steps (%.0f ms)\n", clk2ms(s.cyc));
    {
        size_t n0 = s.drv.step_t.size();
        auto r = s.seek(1, 10);
        CHECK(r.size() == 2 && r[0] == 0x21 && r[1] == 10, "SEEK 10: %s", hex(r).c_str());
        s.run_ms(1);
        CHECK(s.drv.cyl == 10, "the drive is at %d after SEEK 10", s.drv.cyl);
        CHECK(s.drv.step_t.size() - n0 == 10, "%zu step pulses for SEEK 10", s.drv.step_t.size() - n0);
        double mind = 1e9;
        for (size_t i = n0 + 1; i < s.drv.step_t.size(); i++) mind = std::min(mind, s.drv.step_t[i] - s.drv.step_t[i - 1]);
        CHECK(mind > 7.9 && mind < 8.2, "steps %.3f ms apart (the 765's SRT: 8 ms)", mind);
    }

    // ======================================================== reads
    printf("== READ DATA C10 both sides, 18 sectors (%.0f ms)\n", clk2ms(s.cyc));
    {
        double ms;
        read_check(s, 10, 0, 1, 9, "C10 H0", &ms);
        printf("     one side, 9 sectors: %.1f ms\n", ms);
        CHECK(ms < 900, "9 sectors took %.1f ms", ms);
        // MT: both heads in one command
        memset(&s.mem[0x10000], 0xEE, 18 * 512);
        auto res = rw(s, 0xE6, 1, 10, 0, 1, 9, 1, 0x10000, 18 * 512);
        CHECK(res.size() == 7 && (res[0] & 0xC0) == 0, "MT read: %s", hex(res).c_str());
        CHECK(cmp(&s.mem[0x10000], s.disk.sec(10, 0, 1), 18 * 512, "MT") == 0, "MT read data");
    }
    printf("== SEEK 79, READ DATA C79 H1 R5-R9 (%.0f ms)\n", clk2ms(s.cyc));
    s.seek(1, 79);
    read_check(s, 79, 1, 5, 9, "C79 H1");
    CHECK(s.drv.cyl == 79, "drive at %d", s.drv.cyl);
    printf("== a single sector on C45 H0 R7 (%.0f ms)\n", clk2ms(s.cyc));
    s.seek(1, 45);
    read_check(s, 45, 0, 7, 7, "C45 R7");

    // ======================================================== writes
    printf("== WRITE DATA C20 H0 R3-R5 (%.0f ms)\n", clk2ms(s.cyc));
    s.seek(1, 20);
    write_sectors(s, 20, 0, 3, 5, 0x31, "C20");
    CHECK(check_track(s, 20, 0, "C20 after the write") == 0, "C20 H0 on the disk");
    read_check(s, 20, 0, 1, 9, "C20 read back");
    {
        int none, e, l, w;
        precomp_stats(s.drv.sessions.back(), none, e, l, w);
        CHECK(e == 0 && l == 0, "C20: no precompensation below cylinder 40 (%d early, %d late)", e, l);
    }
    printf("== WRITE DATA C60 H1 R1-R9 with precompensation (%.0f ms)\n", clk2ms(s.cyc));
    s.seek(1, 60);
    s.drv.sessions.clear();
    write_sectors(s, 60, 1, 1, 9, 0x77, "C60");
    CHECK(check_track(s, 60, 1, "C60 after the write") == 0, "C60 H1 on the disk");
    read_check(s, 60, 1, 1, 9, "C60 read back");
    {
        int tot_e = 0, tot_l = 0, tot_w = 0, tot_n = 0;
        for (auto &p : s.drv.sessions) {
            int none, e, l, w;
            precomp_stats(p, none, e, l, w);
            tot_e += e; tot_l += l; tot_w += w; tot_n += none;
        }
        printf("     precomp: %d none, %d early, %d late, %d wrong\n", tot_n, tot_e, tot_l, tot_w);
        CHECK(s.drv.sessions.size() == 9, "%zu write sessions for 9 sectors", s.drv.sessions.size());
        CHECK(tot_e > 100 && tot_l > 100 && tot_w == 0, "precompensation: %d early, %d late, %d wrong", tot_e, tot_l, tot_w);
    }
    {
        // gate length of one sector write: 12 + 4 + 512 + 2 + 1 bytes
        auto &p = s.drv.sessions.back();
        double span = p.back() - p.front();
        CHECK(span > 530 * 32000 && span < 532 * 32000, "one sector's write spans %.1f us", span / 1000);
    }

    // ======================================================== format
fmt:
    printf("== FORMAT TRACK C30 H1, fill F6 (%.0f ms)\n", clk2ms(s.cyc));
    s.seek(1, 30);
    {
        for (int k = 0; k < 9; k++) {
            s.mem[0x30000 + 4 * k + 0] = 30; s.mem[0x30000 + 4 * k + 1] = 1;
            s.mem[0x30000 + 4 * k + 2] = k + 1; s.mem[0x30000 + 4 * k + 3] = 2;
        }
        int g0 = s.drv.gate_count;
        s.dma_setup(2, 0x30000, 36);
        s.cmd({ 0x4D, (1 << 2) | 1, 2, 9, 0x50, 0xF6 });
        CHECK(s.wait_irq(2000), "no IRQ after FORMAT");
        auto res = s.results(7);
        s.dma_mask();
        CHECK((res[0] & 0xC0) == 0, "FORMAT: %s", hex(res).c_str());
        CHECK(s.drv.gate_count - g0 == 1, "FORMAT: %d write gates (one turn)", s.drv.gate_count - g0);
        DTrack d = decode_track(s.drv.trk[30][1]);
        CHECK(d.iam == 1, "FORMAT: %d index address marks", d.iam);
        CHECK(check_track(s, 30, 1, "C30 H1 formatted", 0xF6) == 0, "the formatted track");
        for (int r = 1; r <= 9; r++) memset(s.disk.sec(30, 1, r), 0xF6, 512);
        read_check(s, 30, 1, 1, 9, "C30 H1 read after FORMAT");
        // its span: one turn
        auto &p = s.drv.sessions.back();
        double span = p.back() - p.front();
        CHECK(span > 199e6 && span < 201e6, "FORMAT wrote %.3f ms", span / 1e6);
        // the same track again in a new command: written again
        s.dma_setup(2, 0x30000, 36);
        s.cmd({ 0x4D, (1 << 2) | 1, 2, 9, 0x50, 0x6D });
        CHECK(s.wait_irq(2000), "no IRQ after the second FORMAT");
        res = s.results(7);
        s.dma_mask();
        CHECK((res[0] & 0xC0) == 0, "second FORMAT: %s", hex(res).c_str());
        CHECK(check_track(s, 30, 1, "C30 H1 formatted again", 0x6D) == 0, "the track formatted again");
        s.dma_setup(2, 0x30000, 36);
        s.cmd({ 0x4D, (1 << 2) | 1, 2, 9, 0x50, 0xF6 });
        CHECK(s.wait_irq(2000), "no IRQ after the third FORMAT");
        res = s.results(7);
        s.dma_mask();
        CHECK(check_track(s, 30, 1, "C30 H1 formatted a third time", 0xF6) == 0, "the track formatted a third time");
    }
    printf("== FORMAT TRACK on an unformatted cylinder C70 H0, fill E5 (%.0f ms)\n", clk2ms(s.cyc));
    s.drv.trk[70][0].clear();
    s.seek(1, 70);
    {
        auto res = rw(s, 0xE6, 1, 70, 0, 1, 1, 1, 0x10000, 512, 3000);
        CHECK(res.size() == 7 && res[0] == 0x41 && (res[1] & 0x20) && (res[2] & 0x20),
              "read of an unformatted track: %s (data error)", hex(res).c_str());
        for (int k = 0; k < 9; k++) {
            s.mem[0x30000 + 4 * k + 0] = 70; s.mem[0x30000 + 4 * k + 1] = 0;
            s.mem[0x30000 + 4 * k + 2] = k + 1; s.mem[0x30000 + 4 * k + 3] = 2;
        }
        s.dma_setup(2, 0x30000, 36);
        s.cmd({ 0x4D, 1, 2, 9, 0x50, 0xE5 });
        CHECK(s.wait_irq(2000), "no IRQ after FORMAT");
        auto r2 = s.results(7);
        s.dma_mask();
        CHECK((r2[0] & 0xC0) == 0, "FORMAT C70: %s", hex(r2).c_str());
        CHECK(check_track(s, 70, 0, "C70 H0 formatted", 0xE5) == 0, "the formatted C70");
        for (int r = 1; r <= 9; r++) memset(s.disk.sec(70, 0, r), 0xE5, 512);
        write_sectors(s, 70, 0, 2, 2, 0x99, "C70 R2 after FORMAT");
        read_check(s, 70, 0, 1, 9, "C70 read");
    }

    if (only_fmt) goto end;

    // ======================================================== errors
    printf("== a data CRC error (%.0f ms)\n", clk2ms(s.cyc));
    {
        Layout L; L.bad_data_crc_r = 4;
        s.drv.trk[12][0] = build_track(12, 0, s.disk.sec(12, 0, 1), L);
        s.seek(1, 12);
        auto res = rw(s, 0xE6, 1, 12, 0, 4, 4, 1, 0x10000, 512);
        CHECK(res.size() == 7 && res[0] == 0x41 && res[1] == 0x20 && res[2] == 0x20,
              "CRC error: %s (expected 41 20 20)", hex(res).c_str());
        read_check(s, 12, 0, 5, 9, "C12 R5-9 after the bad sector");
    }
    printf("== an ID field with a bad CRC, IDs with the other head (%.0f ms)\n", clk2ms(s.cyc));
    {
        Layout L; L.bad_id_crc_r = 3;
        s.drv.trk[13][1] = build_track(13, 1, s.disk.sec(13, 1, 1), L);
        s.seek(1, 13);
        auto res = rw(s, 0xE6, 1, 13, 1, 3, 3, 1, 0x10000, 512);
        CHECK(res.size() == 7 && res[0] == 0x45, "bad ID CRC: %s (an error)", hex(res).c_str());
        read_check(s, 13, 1, 4, 9, "C13 H1 R4-9");
        Layout L2; L2.id_h = 0;
        s.drv.trk[13][1] = build_track(13, 1, s.disk.sec(13, 1, 1), L2);
        res = rw(s, 0xE6, 1, 13, 1, 1, 1, 1, 0x10000, 512);
        CHECK(res.size() == 7 && res[0] == 0x45, "IDs with H = 0 on side 1: %s (an error)", hex(res).c_str());
        s.drv.trk[13][1] = build_track(13, 1, s.disk.sec(13, 1, 1), Layout());
        read_check(s, 13, 0, 1, 9, "C13 H0");
    }
    printf("== runts: a second short pulse after 2 %% of the transitions (%.0f ms)\n", clk2ms(s.cyc));
    {
        s.drv.runt_p = 0.02;
        s.seek(1, 33);
        read_check(s, 33, 0, 1, 9, "C33 with runts");
        s.drv.runt_p = 0;
    }
    printf("== write protected (%.0f ms)\n", clk2ms(s.cyc));
    {
        s.drv.wp = true;
        s.run_ms(1);
        CHECK(s.t->img_wp & 2, "B: not write protected");
        int g0 = s.drv.gate_count;
        auto res = rw(s, 0xC5, 1, 12, 0, 1, 1, 2, 0x20000, 512);
        CHECK(res.size() == 7 && res[0] == 0x41 && res[1] == 0x02, "write protected: %s", hex(res).c_str());
        CHECK(s.drv.gate_count == g0, "the gate opened on a protected disk");
        s.drv.wp = false;
        s.run_ms(1);
        CHECK(!(s.t->img_wp & 2), "B: still write protected");
        // the tab closed after the 765 took the command: the drive refuses to write
        for (int i = 0; i < 512; i++) s.mem[0x20000 + i] = (uint8_t)(i ^ 0xA5);
        s.seek(1, 12);
        s.dma_setup(2, 0x20000, 512);
        s.cmd({ 0xC5, 1, 12, 0, 6, 2, 6, 0x2A, 0xFF });
        uint64_t e = s.cyc + us2clk(500e3);
        while (!s.t->busy && s.cyc < e) s.tick();
        bool busy_seen = s.t->busy;
        s.drv.wp = true;
        CHECK(busy_seen, "the write did not reach the drive");
        CHECK(s.wait_irq(3000), "no IRQ after a write whose disk became protected");
        res = s.results(7);
        s.dma_mask();
        CHECK(res.size() == 7 && res[0] == 0x51,
              "protected during the write: %s (expected 51: the write failed, EC)", hex(res).c_str());
        CHECK(s.drv.gate_count == g0, "the gate opened on a disk protected during the command");
        if (verbose) printf("     protected during the write: %s, busy seen %d\n", hex(res).c_str(), busy_seen);
        s.drv.wp = false;
        s.run_ms(1);
    }
    printf("== a lost step: IDs of the wrong cylinder, home and seek again (%.0f ms)\n", clk2ms(s.cyc));
    {
        s.drv.lose_steps = 1;
        s.seek(1, 15);
        s.run_ms(10);
        CHECK(s.drv.cyl != 15, "drive at %d (a step lost)", s.drv.cyl);
        double ms;
        read_check(s, 15, 0, 1, 9, "C15 after the lost step", &ms);
        CHECK(s.drv.cyl == 15, "drive at %d after the read", s.drv.cyl);
        printf("     %.1f ms\n", ms);
    }
    printf("== another PC's disk: 2:1 interleave, GAP3 84, +1.5 %% speed of its drive (%.0f ms)\n", clk2ms(s.cyc));
    {
        Layout L; L.gap3 = 84; L.order = { 1, 6, 2, 7, 3, 8, 4, 9, 5 };
        s.drv.trk[25][1] = build_track(25, 1, s.disk.sec(25, 1, 1), L, 1.0 / 1.015, 3e6);
        s.seek(1, 25);
        read_check(s, 25, 1, 1, 9, "C25 interleaved");
        write_sectors(s, 25, 1, 8, 9, 0x42, "C25 R8-9 (other drive's track)");
        read_check(s, 25, 1, 1, 9, "C25 after the write");
    }
    printf("== speed +2 %% / -2 %%, jitter 100 ns (%.0f ms)\n", clk2ms(s.cyc));
    for (double sp : { 1.02, 0.98 }) {
        s.drv.speed = sp; s.drv.jitter_ns = 100;
        s.seek(1, 5);
        read_check(s, 5, 0, 1, 9, sp > 1 ? "C5 +2%" : "C5 -2%");
        write_sectors(s, 5, 1, 1, 9, sp > 1 ? 0x11 : 0x12, "C5 H1");
        read_check(s, 5, 1, 1, 9, "C5 H1 read back");
    }
    s.drv.speed = 1.0; s.drv.jitter_ns = 60;

    // ======================================================== no disk
    printf("== no disk: the command waits, a DOR reset recovers (%.0f ms)\n", clk2ms(s.cyc));
    {
        s.drv.disk = false;
        s.run_ms(500);
        CHECK(!(s.t->img_present & 2), "B: present without a disk");
        bool got;
        rw(s, 0xE6, 1, 5, 0, 1, 1, 1, 0x10000, 512, 1500, &got);
        CHECK(!got, "an IRQ without a disk");
        CHECK(!s.t->busy, "the drive serves a request without a disk");
        s.io_write(0x3F2, 0x29);                 // DOR reset (motor B: stays on)
        s.io_write(0x3F2, 0x2D);
        CHECK(s.wait_irq(5), "no IRQ after the DOR reset");
        for (int u = 0; u < 4; u++) s.sense_int();
        s.cmd({ 0x03, 0xCF, 0x02 });
        s.drv.disk = true;
        s.run_ms(600);
        CHECK(s.t->img_present & 2, "B: not present after the disk came back");
        s.recal(1);
        s.seek(1, 3);
        read_check(s, 3, 1, 1, 9, "C3 after the disk came back");
    }

    // ======================================================== A: alongside
    printf("== A: (an image) while B: is the drive (%.0f ms)\n", clk2ms(s.cyc));
    {
        int b0 = s.img_requests[1];
        s.io_write(0x3F2, 0x1C);                 // A: selected, motor A:
        s.recal(0);
        s.seek(0, 7);
        memset(&s.mem[0x10000], 0xEE, 9 * 512);
        auto res = rw(s, 0xE6, 0, 7, 1, 1, 9, 1, 0x10000, 9 * 512);
        CHECK(res.size() == 7 && (res[0] & 0xC0) == 0, "A: read: %s", hex(res).c_str());
        CHECK(cmp(&s.mem[0x10000], s.img[0].sec(7, 1, 1), 9 * 512, "A:") == 0, "A: data");
        CHECK(s.img_requests[1] == b0, "B:'s image backend was asked");
        CHECK(s.drv.cyl == 3, "the drive moved with A:'s seek (%d)", s.drv.cyl);
    }

    // ======================================================== PC reset
    printf("== the PC's reset: the model's heads go to 0, the drive follows (%.0f ms)\n", clk2ms(s.cyc));
    {
        s.io_write(0x3F2, 0x2D);
        s.seek(1, 40);
        s.run_ms(5);
        CHECK(s.drv.cyl == 40, "drive at %d", s.drv.cyl);
        s.t->pc_reset = 1; s.tick(); s.tick(); s.t->pc_reset = 0;
        s.run_ms(300);
        CHECK(s.drv.cyl == 0 && s.t->cyl == 0, "after the PC's reset the drive is at %d", s.drv.cyl);
        CHECK(s.t->f_motor_n, "the motor runs after the PC's reset");
        s.io_write(0x3F2, 0x0C);
        CHECK(s.wait_irq(5), "no IRQ after reset");
        for (int u = 0; u < 4; u++) s.sense_int();
        s.cmd({ 0x03, 0xCF, 0x02 });
        s.io_write(0x3F2, 0x2D);
        s.run_ms(600);
        read_check(s, 0, 0, 1, 9, "C0 after the PC's reset");
    }

    // ======================================================== B: as an image
    printf("== B: switched to its image (%.0f ms)\n", clk2ms(s.cyc));
    {
        s.t->enable = 0;
        s.run_ms(1);
        CHECK(s.t->f_select_n && s.t->f_motor_n && s.t->f_wgate_n, "the drive's pins with B: an image");
        int b0 = s.img_requests[1];
        s.recal(1);
        s.seek(1, 50);
        memset(&s.mem[0x10000], 0xEE, 512);
        auto res = rw(s, 0xE6, 1, 50, 0, 2, 2, 1, 0x10000, 512);
        CHECK(res.size() == 7 && (res[0] & 0xC0) == 0, "B: image read: %s", hex(res).c_str());
        CHECK(cmp(&s.mem[0x10000], s.img[1].sec(50, 0, 2), 512, "B: image") == 0, "B: image data");
        CHECK(s.img_requests[1] >= b0 + 1, "B:'s image backend: %d requests", s.img_requests[1] - b0);
        CHECK(s.sel_while_off == 0, "the drive was touched %d clks while B: is an image", s.sel_while_off);
        CHECK(s.drv.cyl == 0, "the drive moved while B: is an image (%d)", s.drv.cyl);
        // back to the drive: it is homed again and follows
        s.drv.cyl = 12;
        s.t->enable = 1;
        s.run_ms(200);
        CHECK(s.drv.cyl == 50 || s.drv.cyl > 12, "after enable: drive at %d", s.drv.cyl);
        s.run_ms(400);
        CHECK(s.drv.cyl == 50, "the drive follows the model to 50 (%d)", s.drv.cyl);
        read_check(s, 50, 1, 1, 9, "C50 H1 after the switch back");
    }
    printf("== switching to the image during a request (%.0f ms)\n", clk2ms(s.cyc));
    {
        s.dma_setup(1, 0x10000, 512);
        s.cmd({ 0xE6, 1, 50, 0, 9, 2, 9, 0x2A, 0xFF });
        uint64_t e = s.cyc + us2clk(500e3);
        while (!s.t->busy && s.cyc < e) s.tick();
        CHECK(s.t->busy, "the request did not reach the drive");
        s.t->enable = 0;
        CHECK(s.wait_irq(3000), "no IRQ after the switch during a request");
        auto res = s.results(7);
        s.dma_mask();
        CHECK(res.size() == 7 && res[0] == 0x41, "switched during a read: %s (an error)", hex(res).c_str());
        s.t->enable = 1;
        s.run_ms(400);
    }

    // ======================================================== final: the whole disk
    printf("== every track of the model decodes as expected (%.0f ms)\n", clk2ms(s.cyc));
    {
        int bad = 0;
        for (int c = 0; c < 80; c++)
            for (int h = 0; h < 2; h++) {
                if ((c == 12 && h == 0) || (c == 70 && h == 0) || (c == 25 && h == 1)) continue;
                if (c == 30 && h == 1) { bad += check_track(s, c, h, "C30 H1", 0xF6); continue; }
                bad += check_track(s, c, h, "track");
            }
        CHECK(bad == 0, "%d problems on the disk", bad);
    }

end:
    printf("%s: %d checks, %d failed (%.1f s simulated)\n", fails ? "FAIL" : "PASS", checks, fails,
           clk2ms(s.cyc) / 1000);
    delete s.t;
    return fails ? 1 : 0;
}
