#include <unistd.h>
// sys_run.cpp - Verilator driver for the pc_system simulation.
//   sys_run -b bios.rom [-s seconds] [-t trace.txt] [-i itrace.txt from_ms] [-q]
//           [-a floppy.img] [-d dip_sw1] [-L ram_latency_clk]
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
    setvbuf(stdout, nullptr, _IOLBF, 0);
    const char *bios = nullptr, *trace = nullptr, *itrace = nullptr, *fdimg = nullptr;
    double itrace_from = 0.0;
    double secs = 1.0;
    bool quiet = false;
    int ramlat = 1;          // -L: RAM answer after n clk (1..16; the MEGA65 glue: 6)
    unsigned dip = 0x6D;     // 5160 SW1 as read: 2 floppies, CGA 80x25, 640K, POST loop off
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-b") && i + 1 < argc) bios = argv[++i];
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) secs = atof(argv[++i]);
        else if (!strcmp(argv[i], "-t") && i + 1 < argc) trace = argv[++i];
        else if (!strcmp(argv[i], "-d") && i + 1 < argc) dip = strtoul(argv[++i], nullptr, 16);
        else if (!strcmp(argv[i], "-q")) quiet = true;
        else if (!strcmp(argv[i], "-a") && i + 1 < argc) fdimg = argv[++i];
        else if (!strcmp(argv[i], "-L") && i + 1 < argc) ramlat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-i") && i + 2 < argc) { itrace = argv[++i]; itrace_from = atof(argv[++i]); }
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
    std::string plat = "+ramlat=" + std::to_string(ramlat);
    const char *vargs[] = {argv[0], plus.c_str(), plat.c_str()};
    Verilated::commandArgs(3, vargs);
    Vtb_sys *tb = new Vtb_sys;
    FILE *tf = trace ? fopen(trace, "w") : nullptr;
    FILE *itf = itrace ? fopen(itrace, "w") : nullptr;
    unsigned long long itrace_cyc = (unsigned long long)(itrace_from * 1e-3 * CLK_HZ);

    tb->dip_sw1 = dip;

    // floppy A: from an image file (geometry from its size)
    std::vector<unsigned char> disk;
    if (fdimg) {
        FILE *d = fopen(fdimg, "rb");
        if (!d) { perror(fdimg); return 1; }
        fseek(d, 0, SEEK_END); disk.resize(ftell(d)); fseek(d, 0, SEEK_SET);
        if (fread(disk.data(), 1, disk.size(), d) != disk.size()) { perror(fdimg); return 1; }
        fclose(d);
        unsigned tr = 40, hd = 2, spt = 9;
        switch (disk.size()) {
            case 163840: hd = 1; spt = 8; break;
            case 184320: hd = 1; spt = 9; break;
            case 327680: spt = 8; break;
            case 368640: break;
            case 737280: tr = 80; break;
            default: fprintf(stderr, "%s: unknown floppy size %zu\n", fdimg, disk.size()); return 1;
        }
        tb->img_present = 1;
        tb->img_tracks = tr;
        tb->img_heads = hd;
        tb->img_spt = spt;
    } else
        tb->img_present = 0;
    int sp_state = 0, sp_n = 0;     // 0 idle, 1 reading, 2 writing, 3 done pulse
    tb->kbd_valid = 0;
    tb->reset = 1;
    for (int i = 0; i < 200; i++) { tb->clk = 0; tb->eval(); tb->clk = 1; tb->eval(); }
    if (!trace) unlink(hex.c_str());       // the ROM is loaded (initial block ran)
    tb->reset = 0;

    unsigned long long total = (unsigned long long)(secs * CLK_HZ), cyc = 0;
    unsigned long long report = (unsigned long long)(0.05 * CLK_HZ);
    unsigned long long steps = 0;
    unsigned last_t = 0;
    for (cyc = 0; cyc < total; cyc++) {
        tb->clk = 0;
        // the sector port backend: inputs for the coming edge
        tb->sp_rd_valid = 0; tb->sp_wr_ready = 0; tb->sp_done = 0; tb->sp_err = 0;
        if (sp_state == 0 && tb->sp_req) {
            sp_state = tb->sp_write ? 2 : 1; sp_n = 0;
            if (!quiet) printf("[%9.3f ms] FDC %s drive %d C%d H%d S%d lba %d\n", cyc / CLK_HZ * 1e3,
                               tb->sp_write ? "write" : "read", tb->sp_drive, tb->sp_cyl, tb->sp_head,
                               tb->sp_sector, tb->sp_lba);
        }
        size_t base = (size_t)tb->sp_lba * 512;
        bool bad = tb->sp_drive != 0 || base + 512 > disk.size();
        if (sp_state == 1) {
            if (bad) { tb->sp_done = 1; tb->sp_err = 1; sp_state = 3; }
            else {
                tb->sp_rd_valid = 1; tb->sp_rd_data = disk[base + sp_n];
                if (++sp_n == 512) { tb->sp_done = 1; sp_state = 3; }
            }
        } else if (sp_state == 2) {
            tb->sp_wr_ready = 1;
            if (tb->sp_wr_valid) {
                if (!bad) disk[base + sp_n] = tb->sp_wr_data;
                if (++sp_n == 512) { tb->sp_done = 1; tb->sp_err = bad; sp_state = 3; }
            }
        } else if (sp_state == 3 && !tb->sp_req)
            sp_state = 0;
        tb->eval();
        // sample before the edge (the BIU changes its pins on the edge)
        if (tb->cpu_step) {
            steps++;
            if (tf) {
                static const char *tn[] = {"Ti", "T1", "T2", "T3", "Tw", "T4", "?6", "T0"};
                static const char *bt[] = {"INTA", "IOR", "IOW", "HALT", "CODE", "MEMR", "MEMW", "-"};
                // DMA markers: R = DRQ0, H = HRQ, A = AEN, K = DACK0
                auto *rp = tb->rootp;
                char dm[8]; int dn = 0;
                if (rp->tb_sys__DOT__u_pc__DOT__u_board__DOT__drq0) dm[dn++] = 'R';
                if (rp->tb_sys__DOT__u_pc__DOT__u_board__DOT__hold_request) dm[dn++] = 'H';
                if (rp->tb_sys__DOT__u_pc__DOT__u_board__DOT__aen) dm[dn++] = 'A';
                if (!(rp->tb_sys__DOT__u_pc__DOT__u_board__DOT__dack_n & 1)) dm[dn++] = 'K';
                dm[dn] = 0;
                fprintf(tf, "%llu %s %s %05X %02X qs%d %04X:%04X%s%s\n", steps, tn[tb->bus_t & 7],
                        bt[tb->bus_type & 7], tb->bus_addr, tb->bus_data, tb->qs, tb->cs, tb->ip,
                        dn ? " dma=" : "", dm);
            }
        }
        // instruction log: at the EU's dispatch of an instruction's first
        // byte (a prefix starts the instruction it belongs to)
        auto *r = tb->rootp;
        bool disp = ((r->tb_sys__DOT__u_pc__DOT__u_cpu__DOT__eu__DOT__eu_rom_address >> 8) & 0x1F) == 1;
        static bool disp_d = false, in_prefix = false;
        if (itf && disp && !disp_d && cyc >= itrace_cyc) {
            unsigned ob = r->tb_sys__DOT__u_pc__DOT__u_cpu__DOT__biu__DOT__op_byte;
            bool pre = ob == 0x26 || ob == 0x2E || ob == 0x36 || ob == 0x3E || ob == 0xF0 || ob == 0xF2 || ob == 0xF3;
            if (!in_prefix)
            fprintf(itf, "%.6f %04X:%04X AX=%04X BX=%04X CX=%04X DX=%04X SP=%04X BP=%04X SI=%04X DI=%04X DS=%04X ES=%04X SS=%04X F=%04X\n",
                    cyc / CLK_HZ * 1e3, tb->cs, r->tb_sys__DOT__u_pc__DOT__u_cpu__DOT__biu__DOT__op_ip,
                    r->tb_sys__DOT__u_pc__DOT__u_cpu__DOT__eu__DOT__eu_register_ax,
                    r->tb_sys__DOT__u_pc__DOT__u_cpu__DOT__eu__DOT__eu_register_bx,
                    r->tb_sys__DOT__u_pc__DOT__u_cpu__DOT__eu__DOT__eu_register_cx,
                    r->tb_sys__DOT__u_pc__DOT__u_cpu__DOT__eu__DOT__eu_register_dx,
                    r->tb_sys__DOT__u_pc__DOT__u_cpu__DOT__eu__DOT__eu_register_sp,
                    r->tb_sys__DOT__u_pc__DOT__u_cpu__DOT__eu__DOT__eu_register_bp,
                    r->tb_sys__DOT__u_pc__DOT__u_cpu__DOT__eu__DOT__eu_register_si,
                    r->tb_sys__DOT__u_pc__DOT__u_cpu__DOT__eu__DOT__eu_register_di,
                    r->tb_sys__DOT__u_pc__DOT__u_cpu__DOT__biu__DOT__reg_ds,
                    r->tb_sys__DOT__u_pc__DOT__u_cpu__DOT__biu__DOT__reg_es,
                    r->tb_sys__DOT__u_pc__DOT__u_cpu__DOT__biu__DOT__reg_ss,
                    r->tb_sys__DOT__u_pc__DOT__u_cpu__DOT__eu__DOT__eu_flags);
            in_prefix = pre;
        }
        disp_d = disp;
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
    if (itf) fclose(itf);
    delete tb;
    return 0;
}
