// sys_run.cpp - Verilator driver for the pc_system simulation.
//   sys_run -b bios.rom [-s seconds] [-t trace.txt] [-q]
// Loads the BIOS right-aligned below 1 MB, runs, prints POST codes (port 80h)
// and periodic CS:IP, and dumps the CGA text screen at the end.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "Vtb_sys.h"
#include "Vtb_sys___024root.h"
#include "verilated.h"

static const double CLK_HZ = 100227272.7;

int main(int argc, char **argv) {
    const char *bios = nullptr, *trace = nullptr;
    double secs = 1.0;
    bool quiet = false;
    unsigned dip = 0x6D;     // 5160 SW1 as read: 2 floppies, CGA 80x25, 640K, POST loop off
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-b") && i + 1 < argc) bios = argv[++i];
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) secs = atof(argv[++i]);
        else if (!strcmp(argv[i], "-t") && i + 1 < argc) trace = argv[++i];
        else if (!strcmp(argv[i], "-d") && i + 1 < argc) dip = strtoul(argv[++i], nullptr, 16);
        else if (!strcmp(argv[i], "-q")) quiet = true;
    }
    if (!bios) { fprintf(stderr, "usage: sys_run -b bios.rom [-s secs] [-t trace]\n"); return 1; }

    // ROM image: 64 KB, BIOS right-aligned, 0xFF below
    std::vector<unsigned char> rom(65536, 0xFF);
    FILE *f = fopen(bios, "rb");
    if (!f) { perror(bios); return 1; }
    std::vector<unsigned char> b(65536);
    size_t n = fread(b.data(), 1, b.size(), f);
    fclose(f);
    memcpy(rom.data() + 65536 - n, b.data(), n);
    std::string hex = std::string(trace ? trace : "/tmp") + ".romhex";
    if (!trace) { char t[] = "/tmp/sysromXXXXXX"; int fd = mkstemp(t); close(fd); hex = t; }
    FILE *h = fopen(hex.c_str(), "w");
    for (int i = 0; i < 65536; i++) fprintf(h, "%02x\n", rom[i]);
    fclose(h);

    std::string plus = "+rom=" + hex;
    const char *vargs[] = {argv[0], plus.c_str()};
    Verilated::commandArgs(2, vargs);
    Vtb_sys *tb = new Vtb_sys;
    FILE *tf = trace ? fopen(trace, "w") : nullptr;

    tb->dip_sw1 = dip;
    tb->kbd_valid = 0;
    tb->reset = 1;
    for (int i = 0; i < 200; i++) { tb->clk = 0; tb->eval(); tb->clk = 1; tb->eval(); }
    tb->reset = 0;

    unsigned long long total = (unsigned long long)(secs * CLK_HZ), cyc = 0;
    unsigned long long report = (unsigned long long)(0.05 * CLK_HZ);
    unsigned long long steps = 0;
    unsigned last_t = 0;
    for (cyc = 0; cyc < total; cyc++) {
        tb->clk = 0; tb->eval();
        // sample before the edge (the BIU changes its pins on the edge)
        if (tb->cpu_step) {
            steps++;
            if (tf) {
                static const char *tn[] = {"Ti", "T1", "T2", "T3", "Tw", "T4", "?6", "T0"};
                static const char *bt[] = {"INTA", "IOR", "IOW", "HALT", "CODE", "MEMR", "MEMW", "-"};
                fprintf(tf, "%llu %s %s %05X %02X qs%d %04X:%04X\n", steps, tn[tb->bus_t & 7],
                        bt[tb->bus_type & 7], tb->bus_addr, tb->bus_data, tb->qs, tb->cs, tb->ip);
            }
        }
        if (tb->io_wr) {
            if ((tb->io_addr & 0xFFFF) == 0x80 && !quiet)
                printf("[%9.3f ms] POST %02X\n", cyc / CLK_HZ * 1e3, tb->io_data);
        }
        tb->clk = 1; tb->eval();
        if (cyc % report == 0 && !quiet)
            printf("[%9.3f ms] CS:IP %04X:%04X\n", cyc / CLK_HZ * 1e3, tb->cs, tb->ip);
    }

    // CGA text screen (80x25 at B8000)
    auto *r = tb->rootp;
    printf("---- screen ----\n");
    for (int y = 0; y < 25; y++) {
        char line[81];
        for (int x = 0; x < 80; x++) {
            unsigned char c = r->tb_sys__DOT__u_pc__DOT__u_cga__DOT__vram[(y * 80 + x) * 2];
            line[x] = (c >= 32 && c < 127) ? c : (c == 0 ? ' ' : '.');
        }
        line[80] = 0;
        int e = 79; while (e >= 0 && line[e] == ' ') line[e--] = 0;
        printf("%s\n", line);
    }
    if (tf) fclose(tf);
    delete tb;
    return 0;
}
