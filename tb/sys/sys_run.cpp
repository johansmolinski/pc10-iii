#include <unistd.h>
// sys_run.cpp - Verilator driver for the pc_system simulation.
//   sys_run -b bios.rom [-s seconds] [-t trace.txt] [-i itrace.txt from_ms] [-q]
//           [-a floppy.img] [-d dip_sw1] [-L ram_latency_clk]
//           [-X xub.bin] [-H disk.img] [-J slave.img] [-G c,h,s] [-V variant]
//           [-W out.img] [-K backend_us] [-S ms,ms,...]
//           [-F font.bin] [-m] [-v] [-o image] [-C [max]]
// Loads the BIOS right-aligned below 1 MB, runs, prints POST codes (port 80h)
// and periodic CS:IP, and dumps the CGA text screen at the end.
//
// Hard disk (rtl/hdc, doc/hdc.md): -X puts an option ROM (the XTIDE Universal
// BIOS) into the card's socket at C8000, -H/-J attach master/slave images
// (geometry from -G, else from the image's partition table, else 16 heads x
// 63 sectors), -V picks the card's register map (0 XT-CF/Lo-tech, 1 XTIDE
// rev 1, 2 XTIDE rev 2), -W writes the master image to a file at the end,
// -K sets the backend's latency per sector, -S dumps the screen at the given
// times as well.
//   -F  character ROM image (8 KB, IBM 5788005 layout) through the font port
//   -m  monochrome: DIP SW1 bits 5-4 = 11 (the BIOS uses the MDA); dumps the
//       MDA text screen (build with make MDA=1 or MDA=2)
//   -v  log the CPU's writes to 3B0-3BF and 3D0-3DF
//   -o  with -m: the last MDA frame as <image>.ppm (the vid_hblank/vid_vblank
//       window, green phosphor; tb/mda/topng.py makes a PNG)
//   -C  CGA wait-state oracle: every CPU memory cycle in B8000-BFFFF gets
//       MartyPC's number of wait states, WAIT_TABLE[(dc + 1) & 15] ticks
//       rounded up to CPU clocks, dc = the card's lchar phase at the end of
//       T2 (doc/cga.md section 4); cycles that a DMA wait stretched are
//       counted apart. Prints the first [max] (default 20) mismatches and a
//       summary; the exit code is 3 if any cycle differs.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>
#include "Vtb_sys.h"
#include "Vtb_sys___024root.h"
#include "verilated.h"

static const double CLK_HZ = 100227272.7;

// A hard disk image and its geometry: -G, else the end CHS of the MBR's
// partitions (heads = end head + 1, spt = end sector), else 16 x 63.
struct HdImage {
    std::vector<unsigned char> d;
    unsigned cyls = 0, heads = 0, spt = 0, sectors = 0;
    bool load(const char *fn, const char *geo) {
        FILE *f = fopen(fn, "rb");
        if (!f) { perror(fn); return false; }
        fseek(f, 0, SEEK_END); d.resize(ftell(f)); fseek(f, 0, SEEK_SET);
        if (fread(d.data(), 1, d.size(), f) != d.size()) { perror(fn); fclose(f); return false; }
        fclose(f);
        sectors = d.size() / 512;
        if (geo) sscanf(geo, "%u,%u,%u", &cyls, &heads, &spt);
        else {
            if (d.size() >= 512 && d[510] == 0x55 && d[511] == 0xAA)
                for (int p = 0; p < 4; p++) {
                    const unsigned char *e = &d[446 + 16 * p];
                    if (e[4] == 0) continue;
                    unsigned h = e[5] + 1, s = e[6] & 63;
                    if (s && h > heads) { heads = h; spt = s; }
                }
            if (!heads || !spt || heads > 16) { heads = 16; spt = 63; }
            cyls = std::min(sectors / (heads * spt), 65535u);
        }
        printf("hard disk %s: %u sectors, CHS %u/%u/%u\n", fn, sectors, cyls, heads, spt);
        return true;
    }
};

static void dump_screen(Vtb_sys *tb, const char *title, bool mono = false) {
    auto *r = tb->rootp;
    printf("---- %s ----\n", title);
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
}

int main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IOLBF, 0);
    const char *bios = nullptr, *trace = nullptr, *itrace = nullptr, *fdimg = nullptr;
    const char *xub = nullptr, *hdimg[2] = {nullptr, nullptr}, *hdgeo = nullptr, *hdout = nullptr;
    unsigned variant = 0;
    double hd_lat_us = 20;
    std::vector<double> shots;
    double itrace_from = 0.0;
    double secs = 1.0;
    bool quiet = false, mono = false, vidlog = false;
    const char *fontfile = nullptr, *imgfile = nullptr;
    bool woracle = false;
    int wmax = 20;
    int ramlat = 1;          // -L: RAM answer after n clk (1..16; the MEGA65 glue: 6)
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
        else if (!strcmp(argv[i], "-C")) {
            woracle = true;
            if (i + 1 < argc && argv[i + 1][0] >= '0' && argv[i + 1][0] <= '9') wmax = atoi(argv[++i]);
        }
        else if (!strcmp(argv[i], "-a") && i + 1 < argc) fdimg = argv[++i];
        else if (!strcmp(argv[i], "-L") && i + 1 < argc) ramlat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-i") && i + 2 < argc) { itrace = argv[++i]; itrace_from = atof(argv[++i]); }
        else if (!strcmp(argv[i], "-X") && i + 1 < argc) xub = argv[++i];
        else if (!strcmp(argv[i], "-H") && i + 1 < argc) hdimg[0] = argv[++i];
        else if (!strcmp(argv[i], "-J") && i + 1 < argc) hdimg[1] = argv[++i];
        else if (!strcmp(argv[i], "-G") && i + 1 < argc) hdgeo = argv[++i];
        else if (!strcmp(argv[i], "-V") && i + 1 < argc) variant = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-W") && i + 1 < argc) hdout = argv[++i];
        else if (!strcmp(argv[i], "-K") && i + 1 < argc) hd_lat_us = atof(argv[++i]);
        else if (!strcmp(argv[i], "-S") && i + 1 < argc) {
            for (char *t = strtok(argv[++i], ","); t; t = strtok(nullptr, ",")) shots.push_back(atof(t));
            std::sort(shots.begin(), shots.end());
        }
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
    // the option ROM socket: the image from offset 0, 0xFF above it
    std::string xhex, xplus;
    if (xub) {
        std::vector<unsigned char> x(16384, 0xFF);
        FILE *xf = fopen(xub, "rb");
        if (!xf) { perror(xub); return 1; }
        size_t xn = fread(x.data(), 1, x.size(), xf);
        fclose(xf);
        unsigned sum = 0;
        for (size_t k = 0; k < xn; k++) sum += x[k];
        printf("option ROM %s: %zu bytes, header %02X%02X size %u KB, checksum %s\n", xub, xn, x[0], x[1],
               x[2] / 2, (sum & 0xFF) == 0 ? "ok" : "BAD");
        xhex = hex + ".xub";
        FILE *xh = fopen(xhex.c_str(), "w");
        for (int k = 0; k < 16384; k++) fprintf(xh, "%02x\n", x[k]);
        fclose(xh);
        xplus = "+xub=" + xhex;
    }
    const char *vargs[] = {argv[0], plus.c_str(), plat.c_str(), xplus.c_str()};
    Verilated::commandArgs(xub ? 4 : 3, vargs);
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

    // hard disks
    HdImage hd[2];
    for (int k = 0; k < 2; k++)
        if (hdimg[k] && !hd[k].load(hdimg[k], k == 0 ? hdgeo : nullptr)) return 1;
    tb->hdc_enable  = xub || hdimg[0] || hdimg[1];
    tb->hdc_variant = variant;
    tb->hd_present  = (hdimg[0] ? 1 : 0) | (hdimg[1] ? 2 : 0);
    tb->hd_sectors  = ((uint64_t)hd[1].sectors << 28) | hd[0].sectors;
    tb->hd_cyls     = (hd[1].cyls << 16) | hd[0].cyls;
    tb->hd_heads    = (hd[1].heads << 5) | hd[0].heads;
    tb->hd_spt      = (hd[1].spt << 6) | hd[0].spt;
    // backend: hd_lat_us per sector, then one byte per clk
    int hs = 0, hn = 0, hdrv = 0;   // 0 idle, 1 latency, 2 data, 3 write latency, 4 wait for req low
    unsigned long long hwhen = 0, hd_reads = 0, hd_writes = 0;
    unsigned hlba = 0;
    bool herr = false;
    size_t shot = 0;
    tb->kbd_valid = 0;
    tb->reset = 1;
    for (int i = 0; i < 200; i++) { tb->clk = 0; tb->eval(); tb->clk = 1; tb->eval(); }
    for (int a = 0; fontfile && a < 8192; a++) {
        tb->font_we = 1; tb->font_addr = a; tb->font_data = font[a];
        tb->clk = 0; tb->eval(); tb->clk = 1; tb->eval();
    }
    tb->font_we = 0;
    if (!trace) unlink(hex.c_str());       // the ROM is loaded (initial block ran)
    if (xub) unlink(xhex.c_str());
    tb->reset = 0;

    unsigned long long total = (unsigned long long)(secs * CLK_HZ), cyc = 0;
    unsigned long long report = (unsigned long long)(0.05 * CLK_HZ);
    unsigned long long steps = 0;
    unsigned last_t = 0;
    // the CGA wait-state oracle (-C)
    static const int WAIT_TABLE[16] = {14, 13, 12, 11, 10, 9, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15};
    struct WCyc { bool on = false, dma = false, wr = false; int p = 0, exp = 0, tw = 0; unsigned a = 0; unsigned long long st = 0; } wc;
    unsigned long long w_n[2] = {0, 0}, w_bad[2] = {0, 0}, w_dma = 0;
    unsigned long long w_ph[2][16] = {}, w_phbad[2][16] = {};
    int w_hist[2][16] = {};                  // Tw counts seen
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
        // the hard disk backend
        tb->hd_sp_rd_valid = 0; tb->hd_sp_wr_ready = 0; tb->hd_sp_done = 0; tb->hd_sp_err = 0;
        if (hs == 0 && tb->hd_sp_req) {
            hdrv = tb->hd_sp_drive; hlba = tb->hd_sp_lba; hn = 0;
            herr = hlba >= hd[hdrv].sectors;
            hs = tb->hd_sp_write ? 2 : 1;
            hwhen = cyc + (unsigned long long)(hd_lat_us * 1e-6 * CLK_HZ);
            (tb->hd_sp_write ? hd_writes : hd_reads)++;
            if (!quiet) printf("[%9.3f ms] HD %s drive %d lba %u\n", cyc / CLK_HZ * 1e3,
                               tb->hd_sp_write ? "write" : "read", hdrv, hlba);
        }
        if (hs == 1 && cyc >= hwhen) {
            if (herr) { tb->hd_sp_done = 1; tb->hd_sp_err = 1; hs = 4; }
            else {
                tb->hd_sp_rd_valid = 1; tb->hd_sp_rd_data = hd[hdrv].d[(size_t)hlba * 512 + hn];
                if (++hn == 512) { tb->hd_sp_done = 1; hs = 4; }
            }
        } else if (hs == 2) {
            tb->hd_sp_wr_ready = 1;
            if (tb->hd_sp_wr_valid) {
                if (!herr) hd[hdrv].d[(size_t)hlba * 512 + hn] = tb->hd_sp_wr_data;
                if (++hn == 512) { hs = 3; hwhen = cyc + (unsigned long long)(hd_lat_us * 1e-6 * CLK_HZ); }
            }
        } else if (hs == 3 && cyc >= hwhen) {
            tb->hd_sp_done = 1; tb->hd_sp_err = herr; hs = 4;
        } else if (hs == 4 && !tb->hd_sp_req)
            hs = 0;
        tb->eval();
        // sample before the edge (the BIU changes its pins on the edge)
        if (tb->cpu_step) {
            steps++;
            if (woracle) {
                auto *rp = tb->rootp;
                unsigned bt = tb->bus_t & 7, ty = tb->bus_type & 7;
                bool dmaw = rp->tb_sys__DOT__u_pc__DOT__u_board__DOT__aen ||
                            rp->tb_sys__DOT__u_pc__DOT__u_board__DOT__dma_wait;
                if (wc.on) {
                    if (bt == 3 || bt == 4) {                   // T3, Tw
                        if (dmaw) wc.dma = true;
                        if (bt == 4) wc.tw++;
                    } else {                                    // T4 (or anything else): the cycle ended
                        int k = wc.wr;
                        if (wc.dma) w_dma++;
                        else {
                            w_n[k]++; w_ph[k][wc.p]++;
                            if (wc.tw < 16) w_hist[k][wc.tw]++;
                            if (wc.tw != wc.exp || bt != 5) {
                                w_bad[k]++; w_phbad[k][wc.p]++;
                                if (w_bad[0] + w_bad[1] <= (unsigned long long)wmax)
                                    printf("[%9.3f ms] CGA wait oracle: step %llu %s %05X phase %d: %d Tw, MartyPC %d%s\n",
                                           cyc / CLK_HZ * 1e3, wc.st, wc.wr ? "MEMW" : "MEMR", wc.a, wc.p, wc.tw, wc.exp,
                                           bt != 5 ? " (no T4)" : "");
                            }
                        }
                        wc.on = false;
                    }
                }
                // the step that ends T2 of a CPU memory cycle in B8000-BFFFF:
                // MartyPC's phase is the card's lchar phase there, + 1
                if (bt == 2 && (ty == 4 || ty == 5 || ty == 6) && (tb->bus_addr >> 15) == 0x17) {
                    wc.on = true; wc.dma = dmaw; wc.wr = ty == 6; wc.tw = 0; wc.a = tb->bus_addr; wc.st = steps;
                    wc.p = (rp->tb_sys__DOT__u_pc__DOT__u_cga__DOT__dc + 1) & 15;
                    wc.exp = (WAIT_TABLE[wc.p] + 2) / 3;
                }
            }
            if (tf) {
                static const char *tn[] = {"Ti", "T1", "T2", "T3", "Tw", "T4", "?6", "T0"};
                static const char *bt[] = {"INTA", "IOR", "IOW", "HALT", "CODE", "MEMR", "MEMW", "-"};
                // DMA markers: R = DRQ0, H = HRQ, F = the first HOLDA flip-flop, A = AEN, K = DACK0
                auto *rp = tb->rootp;
                char dm[12]; int dn = 0;
                if (rp->tb_sys__DOT__u_pc__DOT__u_board__DOT__drq0) dm[dn++] = 'R';
                if (rp->tb_sys__DOT__u_pc__DOT__u_board__DOT__hold_request) dm[dn++] = 'H';
                if (rp->tb_sys__DOT__u_pc__DOT__u_board__DOT__hrq_ff1) dm[dn++] = 'F';
                if (rp->tb_sys__DOT__u_pc__DOT__u_board__DOT__aen) dm[dn++] = 'A';
                if (!(rp->tb_sys__DOT__u_pc__DOT__u_board__DOT__dack_n & 1)) dm[dn++] = 'K';
                // the 8237's state (SI S0 S1 S2 S3 SW S4), when not idle
                int ds = rp->tb_sys__DOT__u_pc__DOT__u_board__DOT__u_dma__DOT__u_Timing_And_Control__DOT__state;
                if (ds > 0 && ds < 7) { dm[dn++] = '/'; dm[dn++] = "I0123W4"[ds]; }
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
        if (shot < shots.size() && cyc / CLK_HZ * 1e3 >= shots[shot]) {
            char t[64];
            snprintf(t, sizeof t, "screen at %.0f ms, CS:IP %04X:%04X", shots[shot], tb->cs, tb->ip);
            dump_screen(tb, t, mono);
            shot++;
        }
    }
    if (tb->hdc_enable)
        printf("hard disk backend: %llu sector reads, %llu sector writes\n", hd_reads, hd_writes);
    if (hdout && hdimg[0]) {
        FILE *o = fopen(hdout, "wb");
        if (!o || fwrite(hd[0].d.data(), 1, hd[0].d.size(), o) != hd[0].d.size()) perror(hdout);
        if (o) fclose(o);
        printf("master image written to %s\n", hdout);
    }

    // text screen (80x25 at B8000 for the CGA, B0000 for the MDA)
    dump_screen(tb, mono ? "screen (MDA)" : "screen (CGA)", mono);
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
    int rc = 0;
    if (woracle) {
        for (int k = 0; k < 2; k++) {
            printf("CGA wait oracle, %s: %llu cycles, %llu differ from MartyPC; Tw seen:", k ? "writes" : "reads",
                   w_n[k], w_bad[k]);
            for (int t = 0; t < 16; t++) if (w_hist[k][t]) printf(" %d:%d", t, w_hist[k][t]);
            printf("\n  by phase (cycles/differ):");
            for (int q = 0; q < 16; q++) printf(" %d:%llu/%llu", q, w_ph[k][q], w_phbad[k][q]);
            printf("\n");
        }
        printf("CGA wait oracle: %llu cycles stretched by a DMA wait, not compared\n", w_dma);
        if (w_bad[0] || w_bad[1]) rc = 3;
    }
    if (tf) fclose(tf);
    if (itf) fclose(itf);
    delete tb;
    return rc;
}
