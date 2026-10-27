// uart_model.h - reference model of the INS8250 as doc/ports.md section 2
// specifies it, clk by clk, for tb/ports/uart_run.cpp. Written apart from the
// RTL: the transmitter plays a frame waveform built per character (one level
// per 16x tick), the receiver works from the tick of the start bit and the
// sample ticks computed from it, the interrupt identification from a priority
// list.
//
// GPL-3.0-or-later, pc10-iii.
#pragma once
#include "bus.h"
#include <vector>

struct UartPins {               // the chip's inputs, as the pins are (asynchronous)
    bool sin = true, cts_n = true, dsr_n = true, dcd_n = true, ri_n = true;
};

struct UartModel {
    uint32_t NUM, DEN;
    int PULSE;
    int com = 2;                // 230h bits 3-2
    // registers
    uint8_t rbr = 0, thr = 0, dll = 0, dlm = 0, ier = 0, lcr = 0, mcr = 0;
    bool dr = false, oe = false, pe = false, fe = false, bi = false, thre = true, temt = true;
    bool thre_int = false;
    uint8_t dmsr = 0;
    // pins through two synchronizer stages; the MSR's last status
    UartPins s1, s2;
    uint8_t mst_q = 0;
    // baud
    uint32_t acc = 0, bcnt = 0;
    // transmitter: the frame being sent, one level per 16x tick
    std::vector<uint8_t> wave;
    size_t wpos = 0;
    bool tbusy = false;
    bool txl = true;            // the line (before BREAK)
    // receiver
    enum { RI, RS, RB, RM } rst = RI;       // idle, start seen, busy, waiting for mark
    long rtick = 0;             // 16x ticks since the start was seen
    std::vector<uint8_t> rbits; // sampled data, parity, stop
    // interrupt pulse
    int iir_q = 1, pulse = 0;

    UartModel(uint32_t n, uint32_t d, int p) : NUM(n), DEN(d), PULSE(p) {}

    unsigned base() const { return com == 2 ? 0x3F8 : 0x2F8; }
    bool on() const { return com == 1 || com == 2; }
    bool loop() const { return mcr & 0x10; }
    bool dlab() const { return lcr & 0x80; }
    int nbits() const { return 5 + (lcr & 3); }
    bool pen() const { return lcr & 8; }
    uint32_t divisor() const { return (uint32_t(dlm) << 8) | dll; }
    bool parity(uint8_t d) const {
        if (lcr & 0x20) return !(lcr & 0x10);
        bool x = __builtin_popcount(d & ((1u << nbits()) - 1)) & 1;
        return (lcr & 0x10) ? x : !x;
    }
    // {DCD, RI, DSR, CTS}
    uint8_t mst() const {
        if (loop()) return ((mcr >> 3) & 1) << 3 | ((mcr >> 2) & 1) << 2 | (mcr & 1) << 1 | ((mcr >> 1) & 1);
        return (!s2.dcd_n) << 3 | (!s2.ri_n) << 2 | (!s2.dsr_n) << 1 | (!s2.cts_n);
    }
    int iir() const {
        if ((ier & 4) && (oe || pe || fe || bi)) return 6;
        if ((ier & 1) && dr) return 4;
        if ((ier & 2) && thre_int) return 2;
        if ((ier & 8) && dmsr) return 0;
        return 1;
    }
    bool sel(const Bus &b) const { return on() && !b.aen && (b.addr & 0x3F8) == base(); }
    bool dsel(const Bus &b) const { return sel(b) && !b.ior_n; }
    uint8_t reg(int a) const {
        switch (a) {
        case 0: return dlab() ? dll : rbr;
        case 1: return dlab() ? dlm : ier;
        case 2: return iir();
        case 3: return lcr;
        case 4: return mcr;
        case 5: return temt << 6 | thre << 5 | bi << 4 | fe << 3 | pe << 2 | oe << 1 | dr;
        case 6: return mst_q << 4 | dmsr;
        default: return 0xFF;
        }
    }
    uint8_t din(const Bus &b) const { return dsel(b) ? reg(b.addr & 7) : 0; }
    bool intr() const { return iir() != 1 && pulse == 0; }
    bool sout() const { return loop() || (txl && !(lcr & 0x40)); }
    bool rts_n() const { return loop() || !(mcr & 2); }
    bool dtr_n() const { return loop() || !(mcr & 1); }
    bool out1_n() const { return loop() || !(mcr & 4); }
    bool out2_n() const { return loop() || !(mcr & 8); }
    bool irq4() const { return intr() && !out2_n() && com == 2; }
    bool irq3() const { return intr() && !out2_n() && com == 1; }

    void reset() {
        ier = lcr = mcr = 0;
        dr = oe = pe = fe = bi = false; thre = temt = true; thre_int = false;
        dmsr = 0; mst_q = mst();
        tbusy = false; txl = true; wave.clear(); wpos = 0;
        rst = RI; bcnt = 0; iir_q = 1; pulse = 0;
    }

    void build_frame() {
        int n = nbits();
        uint8_t d = thr & ((1u << n) - 1);
        wave.clear();
        for (int i = 0; i < 16; i++) wave.push_back(0);
        for (int b = 0; b < n; b++) for (int i = 0; i < 16; i++) wave.push_back((d >> b) & 1);
        if (pen()) { bool p = parity(d); for (int i = 0; i < 16; i++) wave.push_back(p); }
        int st = !(lcr & 4) ? 16 : n == 5 ? 24 : 32;
        for (int i = 0; i < st; i++) wave.push_back(1);
        wpos = 0;
    }

    // one clk: the edge at its end. cur/nx: the bus in this clk and the next one;
    // pins: the pins in this clk
    void clock(const Bus &cur, const Bus &nx, const UartPins &pins, bool rst_in) {
        // the values every register sees at this edge
        bool s = sel(cur);
        bool snx = on() && !nx.aen && (nx.addr & 0x3F8) == base() && (nx.addr & 7) == (cur.addr & 7);
        bool wr_end = s && !cur.iow_n && !(snx && !nx.iow_n);
        bool rd_end = s && !cur.ior_n && !(snx && !nx.ior_n);
        int a = cur.addr & 7;
        uint8_t m = mst();
        int iir_now = iir();
        bool rx_in = loop() ? txl : s2.sin;
        uint32_t div = divisor();
        bool xtick = acc + NUM >= DEN;
        bool b16 = xtick && div != 0 && bcnt + 1 >= div;
        bool wthr = wr_end && a == 0 && !dlab();

        // the synchronizers and the accumulator run regardless of reset
        acc = xtick ? acc + NUM - DEN : acc + NUM;
        s2 = s1; s1 = pins;

        if (rst_in) { reset(); mst_q = m; return; }

        // snapshot of state that this edge reads (the RTL's old values)
        uint8_t lcr_o = lcr;
        bool thre_o = thre, dr_o = dr, oe_o = oe;
        (void)lcr_o;

        if (xtick) bcnt = (div == 0 || bcnt + 1 >= div) ? 0 : bcnt + 1;

        uint8_t dm = dmsr;
        if (rd_end && a == 6) dm = 0;
        if ((m ^ mst_q) & 1) dm |= 1;
        if ((m ^ mst_q) & 2) dm |= 2;
        if ((mst_q & 4) && !(m & 4)) dm |= 4;
        if ((m ^ mst_q) & 8) dm |= 8;
        dmsr = dm;
        mst_q = m;

        // transmitter, receiver: computed from the old values
        bool n_thre = thre, n_temt = temt, n_thre_int = thre_int;
        bool n_txl = txl;
        if (wr_end) {
            switch (a) {
            case 0: if (dlab()) { dll = cur.dout; bcnt = 0; }
                    else { thr = cur.dout; n_thre = false; n_temt = false; n_thre_int = false; }
                    break;
            case 1: if (dlab()) { dlm = cur.dout; bcnt = 0; }
                    else { ier = cur.dout & 15; if ((cur.dout & 2) && thre_o) n_thre_int = true; }
                    break;
            case 3: lcr = cur.dout; break;
            case 4: mcr = cur.dout & 0x1F; break;
            default: break;
            }
        }
        bool n_dr = dr, n_oe = oe, n_pe = pe, n_fe = fe, n_bi = bi;
        if (rd_end) {
            if (a == 0 && !(lcr_o & 0x80)) n_dr = false;
            if (a == 2 && iir_now == 2) n_thre_int = false;
            if (a == 5) n_oe = n_pe = n_fe = n_bi = false;
        }
        if (b16) {
            // ---- transmitter (the frame format at this edge: lcr_o)
            uint8_t lcr_new = lcr; lcr = lcr_o;
            bool end = tbusy && wpos + 1 == wave.size();
            if (tbusy && !end) { wpos++; n_txl = wave[wpos]; }
            else if (!thre_o && !wthr) {
                build_frame(); tbusy = true; n_txl = wave[0];
                n_thre = true; n_thre_int = true;
            } else if (end) {
                tbusy = false;
                if (thre_o && !wthr) n_temt = true;
            }
            // ---- receiver
            switch (rst) {
            case RI: if (!rx_in) { rst = RS; rtick = 0; } break;
            case RS: rtick++;
                if (rtick == 7) {
                    if (rx_in) rst = RI;
                    else { rst = RB; rbits.clear(); }
                }
                break;
            case RB: {
                rtick++;
                if ((rtick - 7) % 16 == 0) {
                    rbits.push_back(rx_in);
                    int n = nbits(), want = n + (pen() ? 1 : 0) + 1;
                    if ((int)rbits.size() == want) {
                        uint8_t d = 0;
                        for (int i = 0; i < n; i++) d |= rbits[i] << i;
                        bool stop = rbits.back();
                        rbr = d;
                        n_oe = (oe_o && !(rd_end && a == 5)) || (dr_o && !(rd_end && a == 0 && !(lcr_o & 0x80)));
                        n_dr = true;
                        if (pen() && rbits[n] != parity(d)) n_pe = true;
                        if (!stop) n_fe = true;
                        if (!stop && d == 0 && !(pen() && rbits[n])) n_bi = true;
                        rst = stop ? RI : RM;
                    }
                }
                break;
            }
            case RM: if (rx_in) rst = RI; break;
            }
            lcr = lcr_new;
        }
        thre = n_thre; temt = n_temt; thre_int = n_thre_int; txl = n_txl;
        dr = n_dr; oe = n_oe; pe = n_pe; fe = n_fe; bi = n_bi;

        // the INS8250's INTR pulse
        int now = iir();      // (the next clk's identification is not this one's: use iir_now)
        (void)now;
        if (pulse) pulse--;
        else if (iir_q != 1 && iir_now != 1 && iir_q != iir_now && (iir_q >> 1) > (iir_now >> 1)) pulse = PULSE;
        iir_q = iir_now;
    }
};
