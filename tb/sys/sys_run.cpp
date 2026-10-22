#include <unistd.h>
// sys_run.cpp - Verilator driver for the pc_system simulation.
//   sys_run -b bios.rom [-s seconds] [-t trace.txt] [-i itrace.txt from_ms] [-q]
//           [-F font.bin] [-m] [-o image]
// Loads the BIOS right-aligned below 1 MB, runs, prints POST codes (port 80h)
// and periodic CS:IP, and dumps the CGA text screen at the end.
//   -F  character ROM image (8 KB, IBM 5788005 layout) through the font port
//   -m  monochrome: DIP SW1 bits 5-4 = 11 (the BIOS uses the MDA); dumps the
//       MDA text screen (build with make MDA=1 or MDA=2)
//   -v  log the CPU's writes to 3B0-3BF and 3D0-3DF
//   -o  with -m: the last MDA frame as <image>.ppm (the vid_hblank/vid_vblank
//       window, green phosphor; tb/mda/topng.py makes a PNG)
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
    bool quiet = false, mono = false, vidlog = false;
    const char *fontfile = nullptr, *imgfile = nullptr;
    unsigned dip = 0x6D;     // 5160 SW1 as read: 2 floppies, CGA 80x25, 640K, POST loop off
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-b") && i + 1 < argc) bios = argv[++i];
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) secs = atof(argv[++i]);
        else if (!strcmp(argv[i], "-t") && i + 1 < argc) trace = argv[++i];
        else if (!strcmp(argv[i], "-d") && i + 1 < argc) dip = strtoul(argv[++i], nullptr, 16);
        else if (!strcmp(argv[i], "-q")) quiet = true;
        else if (!strcmp(argv[i], "-m")) mono = true;
        else if (!strcmp(argv[i], "-v")) vidlog = true;
        else if (!strcmp(argv[i], "-F") && i + 1 < argc) fontfile = argv[++i];
        else if (!strcmp(argv[i], "-o") && i + 1 < argc) imgfile = argv[++i];
        else if (!strcmp(argv[i], "-a") && i + 1 < argc) fdimg = argv[++i];
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
    const char *vargs[] = {argv[0], plus.c_str()};
    Verilated::commandArgs(2, vargs);
    Vtb_sys *tb = new Vtb_sys;
    FILE *tf = trace ? fopen(trace, "w") : nullptr;
    FILE *itf = itrace ? fopen(itrace, "w") : nullptr;
    unsigned long long itrace_cyc = (unsigned long long)(itrace_from * 1e-3 * CLK_HZ);

    if (mono) dip |= 0x30;               // SW1 5-6 off: monochrome 80x25
    tb->dip_sw1 = dip;
    std::vector<unsigned char> font(8192, 0);
    if (fontfile) {
        FILE *ff = fopen(fontfile, "rb");
        if (!ff || fread(font.data(), 1, 8192, ff) != 8192) { fprintf(stderr, "font %s?\n", fontfile); return 1; }
        fclose(ff);
    }
    // MDA dots: video | intensity << 1 | hsync << 2 | vsync << 3 | window << 4
    std::vector<unsigned char> mring(1 << 20);
    unsigned long long mdots = 0;

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
    for (int a = 0; fontfile && a < 8192; a++) {
        tb->font_we = 1; tb->font_addr = a; tb->font_data = font[a];
        tb->clk = 0; tb->eval(); tb->clk = 1; tb->eval();
    }
    tb->font_we = 0;
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
            if (vidlog && ((tb->io_addr & 0x3F0) == 0x3B0 || (tb->io_addr & 0x3F0) == 0x3D0))
                printf("[%9.3f ms] OUT %03X %02X\n", cyc / CLK_HZ * 1e3, tb->io_addr & 0x3FF, tb->io_data);
        }
        if (vidlog) {
            // CPU writes to B0000-B7FFF, as the card sees them: the strobe and
            // the card's RAM write
            static bool mw_d = false;
            static unsigned long long nmw = 0, nwe = 0;
            bool mw = !r->tb_sys__DOT__u_pc__DOT__isa_memw_n && (r->tb_sys__DOT__u_pc__DOT__isa_addr >> 15) == 0x16;
            if (mw && !mw_d && ++nmw <= 12)
                printf("[%9.3f ms] MEMW %05X %02X\n", cyc / CLK_HZ * 1e3, r->tb_sys__DOT__u_pc__DOT__isa_addr,
                       r->tb_sys__DOT__u_pc__DOT__isa_dout);
            mw_d = mw;
            if (r->tb_sys__DOT__u_pc__DOT__u_mda__DOT__va_we) nwe++;
            if (cyc % report == 0 && nmw)
                printf("[%9.3f ms] %llu MDA memory writes, %llu RAM writes, mode %02X, B0000: %02X %02X %02X %02X\n",
                       cyc / CLK_HZ * 1e3, nmw, nwe, r->tb_sys__DOT__u_pc__DOT__u_mda__DOT__mode,
                       r->tb_sys__DOT__u_pc__DOT__u_mda__DOT__vram[0xA0], r->tb_sys__DOT__u_pc__DOT__u_mda__DOT__vram[0xA1],
                       r->tb_sys__DOT__u_pc__DOT__u_mda__DOT__vram[0xA2], r->tb_sys__DOT__u_pc__DOT__u_mda__DOT__vram[0xA3]);
        }
        if (tb->mda_ce)
            mring[mdots++ & (mring.size() - 1)] = tb->mda_video | tb->mda_intens << 1 | tb->mda_hsync << 2 |
                                                  tb->mda_vsync << 3 | (!tb->mda_hblank && !tb->mda_vblank) << 4;
        tb->clk = 1; tb->eval();
        if (cyc % report == 0 && !quiet)
            printf("[%9.3f ms] CS:IP %04X:%04X\n", cyc / CLK_HZ * 1e3, tb->cs, tb->ip);
    }

    // text screen (80x25 at B8000 for the CGA, B0000 for the MDA)
    auto *r = tb->rootp;
    printf("---- screen (%s) ----\n", mono ? "MDA" : "CGA");
    for (int y = 0; y < 25; y++) {
        char line[81];
        for (int x = 0; x < 80; x++) {
            unsigned char c = mono ? r->tb_sys__DOT__u_pc__DOT__u_mda__DOT__vram[(y * 80 + x) * 2]
                                   : r->tb_sys__DOT__u_pc__DOT__u_cga__DOT__vram[(y * 80 + x) * 2];
            line[x] = (c >= 32 && c < 127) ? c : (c == 0 ? ' ' : '.');
        }
        line[80] = 0;
        int e = 79; while (e >= 0 && line[e] == ' ') line[e--] = 0;
        printf("%s\n", line);
    }
    // the last complete MDA frame (VSYNC start to VSYNC start), its window
    if (mono && imgfile) {
        const size_t N = mring.size();
        auto at = [&](unsigned long long k) { return mring[k & (N - 1)]; };
        unsigned long long lo = mdots > N ? mdots - N + 1 : 1, e = 0, s = 0;
        for (unsigned long long k = mdots - 1; k > lo; k--)
            if ((at(k) & 8) && !(at(k - 1) & 8)) { if (!e) e = k; else { s = k; break; } }
        if (!s) printf("no complete MDA frame recorded\n");
        else {
            static const unsigned char PAL[4][3] = {{0, 0, 0}, {0x10, 0x40, 0x10}, {0x20, 0xB0, 0x20}, {0x70, 0xFF, 0x70}};
            std::vector<unsigned char> img, row;
            int w = 0, h = 0;
            for (unsigned long long k = s; k < e; k++) {
                if (at(k) & 16) row.insert(row.end(), PAL[at(k) & 3], PAL[at(k) & 3] + 3);
                else if (!row.empty()) { w = row.size() / 3; img.insert(img.end(), row.begin(), row.end()); row.clear(); h++; }
            }
            std::string fn = std::string(imgfile) + ".ppm";
            FILE *pf = fopen(fn.c_str(), "wb");
            fprintf(pf, "P6\n%d %d\n255\n", w, h);
            fwrite(img.data(), 1, (size_t)w * h * 3, pf);
            fclose(pf);
            printf("MDA frame: %llu dots, window %dx%d -> %s\n", e - s, w, h, fn.c_str());
        }
    }
    if (tf) fclose(tf);
    if (itf) fclose(itf);
    delete tb;
    return 0;
}
