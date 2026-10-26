#include <unistd.h>
// sys_run.cpp - Verilator driver for the pc_system simulation.
//   sys_run -b bios.rom [-s seconds] [-t trace.txt] [-i itrace.txt from_ms] [-q]
//           [-a floppy.img] [-d dip_sw1] [-L ram_latency_clk]
//           [-X xub.bin] [-H disk.img] [-J slave.img] [-G c,h,s] [-V variant]
//           [-W out.img] [-K backend_us] [-S ms,ms,...]
//           [-F font.bin] [-m] [-v] [-o image] [-C [max]] [-f]
//           [-A xta.img] [-jmp208 A|B] [-WA out.img] [-xl] [-k ms:keys] [-w]
//           [-R "YYYY-MM-DD hh:mm:ss"] [-rl]
// The real-time clock (PVC4 builds, doc/rtc.md): -R seeds it like M2M's
// main_rtc_i 1 ms after the start (years 2000-2099, the weekday from the
// date); the PC's write-backs are printed; -rl logs the CPU's writes to
// 2C0h-2CFh and 230h.
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
//   PVC4 builds (make FE=1 PVC4=1, doc/pvc4.md): -P n sets the PC10-III's CONFIG
//       switches 1 and 2 (bit 0 = switch 1, bit 1 = switch 2, 1 = off; default 1:
//       USA/Europe characters, colour), -m also sets switch 2 (monochrome); -F
//       takes an 8 KB IBM image or a 32 KB Commodore character ROM; -o writes
//       the last PVC4 frame (the vid_hblank/vid_vblank window: RGBI, or green
//       for the mono personality); the text screen dump reads the PVC4's RAM;
//       the CPU's wait states in the PVC4's memory are counted (histogram at the end)
//   -f  floppy controller log: the CPU's 765 reads and writes (A0, data,
//       CS:IP), DOR writes, DACK2 cycles, TC, IRQ6 edges, DRQ2 rises, with the
//       CPU step number (the -t trace's first column)
//   -C  CGA wait-state oracle: every CPU memory cycle in B8000-BFFFF gets
//       MartyPC's number of wait states, WAIT_TABLE[(dc + 1) & 15] ticks
//       rounded up to CPU clocks, dc = the card's lchar phase at the end of
//       T2 (doc/cga.md section 4); cycles that a DMA wait stretched are
//       counted apart. Prints the first [max] (default 20) mismatches and a
//       summary; the exit code is 3 if any cycle differs.
//   PC20-III hard disk (make XTA=1, doc/xta.md): -A attaches the drive's image
//       (raw, 615 x 4 x 17 x 512 = 21,411,840 bytes; a shorter file is padded
//       with zeros), -jmp208 sets the jumper (B = the drive connected, the default
//       with -A; A = the ports float), -WA writes the image to a file at the end,
//       -xl logs the drive's commands and completion bytes; the backend's latency
//       per sector is -K's
//   -k ms:keys  types keys from ms on, one every 80 ms (XT scan codes, set 1;
//       \n Enter, \e Esc, \b Backspace, \t Tab; capitals and symbols with Shift);
//       may be given more than once
//   -e 'text|keys'  types keys (as -k) 50 ms after the cursor's line (the BIOS data area's
//       page 0 cursor row) shows text; the -e's are taken in order, each one only after the
//       keys of the one before were typed and 1.5 s passed (a dialogue: FDISK, FORMAT)
//   -E text  ends the run when the cursor's line shows text, after the last -e
//   -w  warm start: the BIOS's warm-boot flag 0472h = 1234h is in the RAM at
//       power-on (GLaBIOS-style BIOSes skip their memory test; the Commodore BIOS
//       4.41 still tests it and then fails "Bad DMA port = 0004h": not for it)
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>
#include <ctime>
#include "Vtb_sys.h"
#include "Vtb_sys___024root.h"
#include "verilated.h"
#include "ucode_file.h"
#ifndef PVC4_BUILD
#define PVC4_BUILD 0
#endif

static const double CLK_HZ = 28636363.64;      // 315/11 MHz

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

// one line of the text screen (the PVC4 build: its RAM; else the CGA's)
static std::string screen_line(Vtb_sys *tb, int y) {
    std::string l;
#if PVC4_BUILD
    auto *r = tb->rootp;
    for (int x = 0; x < 80; x++) {
        unsigned o = (tb->vid_monomode ? 0x0000 : 0x8000) + (y * 80 + x) * 2;
        unsigned char c = r->tb_sys__DOT__u_pc__DOT__g_pvc4__DOT__u_pvc4__DOT__vram0[((o >> 1) & 0x4000) | (o & 0x3FFF)];
        l += (c >= 32 && c < 127) ? (char)c : ' ';
    }
#else
    (void)tb; (void)y;
#endif
    return l;
}

static bool ascii_sc(char c, unsigned &sc, bool &shift);

// keys (as -k: one every 80 ms from ms on, make, break 30 ms later; \n \e \b \t escapes)
static bool add_keys(std::vector<std::pair<unsigned long long, unsigned>> &keys, double ms,
                     const char *s) {
    for (const char *c = s; *c; c++) {
        char ch = *c;
        // \#hh: one raw scan code (make or break as given), 40 ms to the next key
        // (Ctrl-Alt-D: \#1d\#38\#20\#a0\#b8\#9d)
        if (ch == '\\' && c[1] == '#' && isxdigit((unsigned char)c[2]) && isxdigit((unsigned char)c[3])) {
            char hx[3] = {c[2], c[3], 0};
            keys.push_back({(unsigned long long)(ms * 1e-3 * CLK_HZ), (unsigned)strtoul(hx, nullptr, 16)});
            ms += 40;
            c += 3;
            continue;
        }
        if (ch == '\\' && c[1]) {
            c++;
            ch = *c == 'n' ? '\n' : *c == 'e' ? 27 : *c == 'b' ? '\b' : *c == 't' ? '\t' : *c;
        }
        unsigned sc; bool sh;
        if (!ascii_sc(ch, sc, sh)) { fprintf(stderr, "-k: no scan code for '%c'\n", ch); return false; }
        unsigned long long t0 = (unsigned long long)(ms * 1e-3 * CLK_HZ), d = (unsigned long long)(0.03 * CLK_HZ);
        if (sh) keys.push_back({t0, 0x2A});
        keys.push_back({t0 + 1, sc});
        keys.push_back({t0 + d, sc | 0x80});
        if (sh) keys.push_back({t0 + d + 1, 0xAA});
        ms += 80;
    }
    return true;
}

static void dump_screen(Vtb_sys *tb, const char *title, bool mono = false) {
    auto *r = tb->rootp;
    printf("---- %s ----\n", title);
    for (int y = 0; y < 25; y++) {
        char line[81];
        for (int x = 0; x < 80; x++) {
#if PVC4_BUILD
            // the PVC4's RAM: B0000 + offset, banks by A14 (doc/pvc4.md 6.1)
            unsigned o = (tb->vid_monomode ? 0x0000 : 0x8000) + (y * 80 + x) * 2;
            unsigned char c = r->tb_sys__DOT__u_pc__DOT__g_pvc4__DOT__u_pvc4__DOT__vram0[((o >> 1) & 0x4000) | (o & 0x3FFF)];
            (void)mono;
#else
            unsigned char c = mono ? r->tb_sys__DOT__u_pc__DOT__u_mda__DOT__vram[(y * 80 + x) * 2]
                                   : r->tb_sys__DOT__u_pc__DOT__u_cga__DOT__vram[(y * 80 + x) * 2];
#endif
            line[x] = (c >= 32 && c < 127) ? c : (c == 0 ? ' ' : '.');
        }
        line[80] = 0;
        int e = 79; while (e >= 0 && line[e] == ' ') line[e--] = 0;
        printf("%s\n", line);
    }
}

// XT scan code (set 1) of an ASCII character; shift: with the left Shift key
static bool ascii_sc(char c, unsigned &sc, bool &shift) {
    static const char *lo = "1234567890-=";                 // 02..0D
    static const char *hi = "!@#$%^&*()_+";
    static const char *r1 = "qwertyuiop[]", *r1s = "QWERTYUIOP{}";   // 10..1B
    static const char *r2 = "asdfghjkl;'`", *r2s = "ASDFGHJKL:\"~"; // 1E..29
    static const char *r3 = "\\zxcvbnm,./", *r3s = "|ZXCVBNM<>?";    // 2B..35
    shift = false;
    const char *p;
    if ((p = strchr(lo, c)) && c) { sc = 0x02 + (p - lo); return true; }
    if ((p = strchr(hi, c)) && c) { sc = 0x02 + (p - hi); shift = true; return true; }
    if ((p = strchr(r1, c)) && c) { sc = 0x10 + (p - r1); return true; }
    if ((p = strchr(r1s, c)) && c) { sc = 0x10 + (p - r1s); shift = true; return true; }
    if ((p = strchr(r2, c)) && c) { sc = 0x1E + (p - r2); return true; }
    if ((p = strchr(r2s, c)) && c) { sc = 0x1E + (p - r2s); shift = true; return true; }
    if ((p = strchr(r3, c)) && c) { sc = 0x2B + (p - r3); return true; }
    if ((p = strchr(r3s, c)) && c) { sc = 0x2B + (p - r3s); shift = true; return true; }
    switch (c) {
        case ' ': sc = 0x39; return true;
        case '\n': sc = 0x1C; return true;
        case 27: sc = 0x01; return true;
        case '\b': sc = 0x0E; return true;
        case '\t': sc = 0x0F; return true;
    }
    return false;
}

static bool fdclog = false;     // -f
int main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IOLBF, 0);
    const char *bios = nullptr, *trace = nullptr, *itrace = nullptr, *fdimg = nullptr;
    const char *xub = nullptr, *hdimg[2] = {nullptr, nullptr}, *hdgeo = nullptr, *hdout = nullptr;
    const char *xtaimg = nullptr, *xtaout = nullptr;
    int jmp208 = -1;                    // -1: B with an image, else A
    bool xtalog = false, warm = false;
    std::vector<std::pair<unsigned long long, unsigned>> keys;     // (clk, scan code)
    std::vector<std::pair<std::string, std::string>> trig;         // -e text|keys
    const char *endtext = nullptr;                                 // -E
    unsigned variant = 0;
    double hd_lat_us = 20;
    std::vector<double> shots;
    double itrace_from = 0.0;
    double secs = 1.0;
    bool quiet = false, mono = false, vidlog = false;
    const char *fontfile = nullptr, *imgfile = nullptr;
    bool woracle = false;
    int wmax = 20;
    int ramlat = 1;          // -L: RAM answer after n clk (1..16; the MEGA65 glue: 2)
    bool cpurate = false;    // -cr: the CPU clocks per 50 ms
    unsigned dip = 0x6D;     // 5160 SW1 as read: 2 floppies, CGA 80x25, 640K, POST loop off
    unsigned cbm_dip = 1;    // PVC4: CONFIG switch 1 off (USA/Europe), switch 2 on (colour)
    const char *rtc_at = nullptr;
    bool rtclog = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-b") && i + 1 < argc) bios = argv[++i];
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) secs = atof(argv[++i]);
        else if (!strcmp(argv[i], "-t") && i + 1 < argc) trace = argv[++i];
        else if (!strcmp(argv[i], "-d") && i + 1 < argc) dip = strtoul(argv[++i], nullptr, 16);
        else if (!strcmp(argv[i], "-q")) quiet = true;
        else if (!strcmp(argv[i], "-f")) fdclog = true;
        else if (!strcmp(argv[i], "-m")) mono = true;
        else if (!strcmp(argv[i], "-P") && i + 1 < argc) cbm_dip = strtoul(argv[++i], nullptr, 16);
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
        else if (!strcmp(argv[i], "-A") && i + 1 < argc) xtaimg = argv[++i];
        else if (!strcmp(argv[i], "-WA") && i + 1 < argc) xtaout = argv[++i];
        else if (!strcmp(argv[i], "-jmp208") && i + 1 < argc) { i++; jmp208 = argv[i][0] == 'B' || argv[i][0] == 'b'; }
        else if (!strcmp(argv[i], "-xl")) xtalog = true;
        else if (!strcmp(argv[i], "-w")) warm = true;
        else if (!strcmp(argv[i], "-cr")) cpurate = true;
        else if (!strcmp(argv[i], "-R") && i + 1 < argc) rtc_at = argv[++i];
        else if (!strcmp(argv[i], "-rl")) rtclog = true;
        else if (!strcmp(argv[i], "-k") && i + 1 < argc) {
            // ms:keys, one key every 80 ms: make, break 30 ms later
            char *t = argv[++i], *colon = strchr(t, ':');
            if (!colon) { fprintf(stderr, "-k ms:keys\n"); return 1; }
            if (!add_keys(keys, atof(t), colon + 1)) return 1;
        }
        else if (!strcmp(argv[i], "-e") && i + 1 < argc) {
            char *t = argv[++i], *bar = strchr(t, '|');
            if (!bar) { fprintf(stderr, "-e text|keys\n"); return 1; }
            trig.push_back({std::string(t, bar - t), std::string(bar + 1)});
            std::vector<std::pair<unsigned long long, unsigned>> chk;
            if (!add_keys(chk, 0, bar + 1)) return 1;
        }
        else if (!strcmp(argv[i], "-E") && i + 1 < argc) endtext = argv[++i];
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
    // $SYS_PLUSARGS: more plusargs for the model, e.g. "+ztrace_from=606000 +ztrace_to=606050"
    std::vector<std::string> extra;
    if (const char *e = getenv("SYS_PLUSARGS")) {
        std::string t;
        for (const char *c = e;; c++) {
            if (*c == ' ' || *c == 0) { if (!t.empty()) extra.push_back(t); t.clear(); if (!*c) break; }
            else t += *c;
        }
    }
    static const char *vargs[32];
    int nv = 0;
    vargs[nv++] = argv[0]; vargs[nv++] = plus.c_str(); vargs[nv++] = plat.c_str();
    if (xub) vargs[nv++] = xplus.c_str();
    if (xtalog) vargs[nv++] = "+xtalog";
    if (warm) vargs[nv++] = "+warm";
    for (auto &x : extra) if (nv < 32) vargs[nv++] = x.c_str();
    Verilated::commandArgs(nv, vargs);
    Vtb_sys *tb = new Vtb_sys;
    FILE *tf = trace ? fopen(trace, "w") : nullptr;
    FILE *itf = itrace ? fopen(itrace, "w") : nullptr;
    unsigned long long itrace_cyc = (unsigned long long)(itrace_from * 1e-3 * CLK_HZ);

    if (mono) dip |= 0x30;               // SW1 5-6 off: monochrome 80x25
    if (mono) cbm_dip |= 2;              // PVC4: CONFIG switch 2 off (onboard video mono)
    tb->dip_sw1 = dip;
    tb->cbm_dip = cbm_dip;
    std::vector<unsigned char> font(8192, 0);
    if (fontfile) {
        FILE *ff = fopen(fontfile, "rb");
        if (ff) { fseek(ff, 0, SEEK_END); font.resize(ftell(ff)); fseek(ff, 0, SEEK_SET); }
        if (!ff || (font.size() != 8192 && !(PVC4_BUILD && font.size() == 32768)) ||
            fread(font.data(), 1, font.size(), ff) != font.size()) { fprintf(stderr, "font %s?\n", fontfile); return 1; }
        fclose(ff);
    }
    tb->font_cbm = font.size() == 32768;
    // PVC4 dots: rgbi | mono << 4 | hsync << 5 | vsync << 6 | window << 7
    std::vector<unsigned char> pring(PVC4_BUILD ? 1 << 21 : 1);
    unsigned long long pdots = 0;
    bool pmono_last = false;
    // PVC4: wait states of the CPU's memory cycles in B0000-BFFFF
    int pw_hist[2][32] = {};
    bool pw_on = false, pw_wr = false, pw_dma = false;
    int pw_tw = 0;
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
    // the PC20-III's hard disk: the image, JMP208
    const size_t XTA_BYTES = 615u * 4 * 17 * 512;
    std::vector<unsigned char> xta;
    if (xtaimg) {
        FILE *xf = fopen(xtaimg, "rb");
        if (!xf) { perror(xtaimg); return 1; }
        xta.assign(XTA_BYTES, 0);
        size_t xn = fread(xta.data(), 1, XTA_BYTES, xf);
        fclose(xf);
        printf("XTA image %s: %zu bytes%s\n", xtaimg, xn, xn < XTA_BYTES ? " (padded with zeros)" : "");
    }
    if (jmp208 < 0) jmp208 = xtaimg != nullptr;
    tb->xta_enable  = jmp208;
    tb->xta_present = xtaimg != nullptr;
    int xs = 0, xn = 0;                 // backend: 0 idle, 1 latency, 2 data, 3 write latency, 4 wait for req low
    unsigned long long xwhen = 0, xta_reads = 0, xta_writes = 0;
    unsigned xlba = 0;
    bool xerr = false;
    // the RTC seed: MiSTer/M2M format, BCD, years since 2000, weekday 0 = Monday
    uint64_t rtc_seed = 0;
    if (rtc_at) {
        struct tm tm{};
        if (sscanf(rtc_at, "%d-%d-%d %d:%d:%d", &tm.tm_year, &tm.tm_mon, &tm.tm_mday, &tm.tm_hour, &tm.tm_min,
                   &tm.tm_sec) != 6 || tm.tm_year < 2000 || tm.tm_year > 2099) {
            fprintf(stderr, "-R \"YYYY-MM-DD hh:mm:ss\" (2000-2099)\n"); return 1;
        }
        tm.tm_year -= 1900; tm.tm_mon -= 1;
        time_t tt = timegm(&tm);
        gmtime_r(&tt, &tm);
        auto bcd = [](int v) { return uint64_t(((v / 10) << 4) | (v % 10)); };
        rtc_seed = bcd(tm.tm_sec) | bcd(tm.tm_min) << 8 | bcd(tm.tm_hour) << 16 | bcd(tm.tm_mday) << 24 |
                   bcd(tm.tm_mon + 1) << 32 | bcd(tm.tm_year - 100) << 40 | uint64_t((tm.tm_wday + 6) % 7) << 48 |
                   uint64_t(0x40) << 56;
    }
    tb->rtc_seed[0] = tb->rtc_seed[1] = tb->rtc_seed[2] = 0;
    std::sort(keys.begin(), keys.end());
    size_t key_i = 0;
    tb->kbd_valid = 0;
    tb->reset = 1;
    for (int i = 0; i < 200; i++) { tb->clk = 0; tb->eval(); tb->clk = 1; tb->eval(); }
    for (int a = 0; fontfile && a < (int)font.size(); a++) {
        tb->font_we = 1; tb->font_addr = a & 0x1FFF; tb->font_addr_hi = a >> 13; tb->font_data = font[a];
        tb->clk = 0; tb->eval(); tb->clk = 1; tb->eval();
    }
    tb->font_we = 0;
    {
        // the 8088's microcode bundle through the CPU's load port, in reset
        // ($PC10_UCODE, else make Z86_UCODE=...), as the core's firmware loads it
        std::vector<uint8_t> uc;
        std::string err;
        if (!ucode_read(uc, err)) { fprintf(stderr, "%s\n", err.c_str()); return 2; }
        for (size_t i = 0; i < uc.size(); i++) {
            tb->ucl_we = 1; tb->ucl_addr = i; tb->ucl_data = uc[i];
            tb->clk = 0; tb->eval(); tb->clk = 1; tb->eval();
        }
        tb->ucl_we = 0;
    }
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
        // the XTA backend (the same latency as the XTIDE's)
        tb->xta_sp_rd_valid = 0; tb->xta_sp_wr_ready = 0; tb->xta_sp_done = 0; tb->xta_sp_err = 0;
        if (xs == 0 && tb->xta_sp_req) {
            xlba = tb->xta_sp_lba; xn = 0;
            xerr = (size_t)xlba * 512 + 512 > xta.size();
            xs = tb->xta_sp_write ? 2 : 1;
            xwhen = cyc + (unsigned long long)(hd_lat_us * 1e-6 * CLK_HZ);
            (tb->xta_sp_write ? xta_writes : xta_reads)++;
        }
        if (xs == 1 && cyc >= xwhen) {
            if (xerr) { tb->xta_sp_done = 1; tb->xta_sp_err = 1; xs = 4; }
            else {
                tb->xta_sp_rd_valid = 1; tb->xta_sp_rd_data = xta[(size_t)xlba * 512 + xn];
                if (++xn == 512) { tb->xta_sp_done = 1; xs = 4; }
            }
        } else if (xs == 2) {
            tb->xta_sp_wr_ready = 1;
            if (tb->xta_sp_wr_valid) {
                if (!xerr) xta[(size_t)xlba * 512 + xn] = tb->xta_sp_wr_data;
                if (++xn == 512) { xs = 3; xwhen = cyc + (unsigned long long)(hd_lat_us * 1e-6 * CLK_HZ); }
            }
        } else if (xs == 3 && cyc >= xwhen) {
            tb->xta_sp_done = 1; tb->xta_sp_err = xerr; xs = 4;
        } else if (xs == 4 && !tb->xta_sp_req)
            xs = 0;
        // typed keys: one code per strobe, when the board has taken the last
        tb->kbd_valid = 0;
        static unsigned long long key_last = 0;
        if (key_i < keys.size() && cyc >= keys[key_i].first && !tb->kbd_busy &&
            cyc >= key_last + (unsigned long long)(0.002 * CLK_HZ)) {
            tb->kbd_code = keys[key_i].second; tb->kbd_valid = 1;
            key_last = cyc;
            if (!quiet && !(keys[key_i].second & 0x80))
                printf("[%9.3f ms] key %02X\n", cyc / CLK_HZ * 1e3, keys[key_i].second);
            key_i++;
        }
        // -e / -E: the cursor's line (BIOS data area 0451h: page 0's row), every 20 ms
        static size_t trig_i = 0;
        static unsigned long long trig_quiet = 0;
        if ((!trig.empty() || endtext) && cyc % (unsigned long long)(0.02 * CLK_HZ) == 0 &&
            key_i == keys.size() && cyc >= trig_quiet) {
            unsigned row = tb->rootp->tb_sys__DOT__ram[0x451];
            std::string line = screen_line(tb, row < 25 ? row : 24);
            if (trig_i < trig.size() && line.find(trig[trig_i].first) != std::string::npos) {
                double ms = cyc / CLK_HZ * 1e3 + 50;
                printf("[%9.3f ms] -e '%s': %s\n", cyc / CLK_HZ * 1e3, trig[trig_i].first.c_str(), line.c_str());
                size_t k0 = keys.size();
                add_keys(keys, ms, trig[trig_i].second.c_str());
                std::sort(keys.begin() + k0, keys.end());
                trig_quiet = keys.empty() ? cyc : keys.back().first + (unsigned long long)(1.5 * CLK_HZ);
                trig_i++;
            } else if (trig_i == trig.size() && endtext && line.find(endtext) != std::string::npos) {
                printf("[%9.3f ms] -E '%s': %s\n", cyc / CLK_HZ * 1e3, endtext, line.c_str());
                total = cyc + 1;
            }
        }
        tb->eval();
        // sample before the edge (the BIU changes its pins on the edge)
        if (tb->cpu_step) {
            steps++;
            if (PVC4_BUILD) {
                auto *rp = tb->rootp;
                unsigned bt = tb->bus_t & 7, ty = tb->bus_type & 7;
                bool dmaw = rp->tb_sys__DOT__u_pc__DOT__u_board__DOT__aen ||
                            rp->tb_sys__DOT__u_pc__DOT__u_board__DOT__dma_wait;
                if (pw_on) {
                    if (bt == 3 || bt == 4) { if (dmaw) pw_dma = true; if (bt == 4) pw_tw++; }
                    else { if (!pw_dma && pw_tw < 32) pw_hist[pw_wr][pw_tw]++; pw_on = false; }
                }
                // the cycles the PVC4 answers: B8000-BFFFF (colour) or B0000-B7FFF
                // (mono; Hercules page 2 not counted), the chip enabled (230h)
                bool on = !rp->tb_sys__DOT__u_pc__DOT__venb_n &&
                          (tb->bus_addr >> 15) == (tb->vid_monomode ? 0x16u : 0x17u);
                if (bt == 2 && (ty == 4 || ty == 5 || ty == 6) && on) {
                    pw_on = true; pw_wr = ty == 6; pw_dma = dmaw; pw_tw = 0;
                }
            }
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
        bool disp = tb->it_disp;
        static bool disp_d = false, in_prefix = false;
        if (itf && disp && !disp_d && cyc >= itrace_cyc) {
            unsigned ob = tb->it_op;
            bool pre = ob == 0x26 || ob == 0x2E || ob == 0x36 || ob == 0x3E || ob == 0xF0 || ob == 0xF2 || ob == 0xF3;
            if (!in_prefix)
            fprintf(itf, "%.6f %04X:%04X AX=%04X BX=%04X CX=%04X DX=%04X SP=%04X BP=%04X SI=%04X DI=%04X DS=%04X ES=%04X SS=%04X F=%04X\n",
                    cyc / CLK_HZ * 1e3, tb->cs, tb->it_ip, tb->it_ax, tb->it_bx, tb->it_cx, tb->it_dx,
                    tb->it_sp, tb->it_bp, tb->it_si, tb->it_di, tb->it_ds, tb->it_es, tb->it_ss, tb->it_f);
            in_prefix = pre;
        }
        disp_d = disp;
        if (rtc_at && cyc == (unsigned long long)(0.001 * CLK_HZ)) {
            tb->rtc_seed[0] = uint32_t(rtc_seed); tb->rtc_seed[1] = uint32_t(rtc_seed >> 32); tb->rtc_seed[2] = 1;
            printf("[%9.3f ms] RTC seed %016llX (%s)\n", cyc / CLK_HZ * 1e3, (unsigned long long)rtc_seed, rtc_at);
        }
        if (tb->rtc_set) {
            uint64_t t = tb->rtc_time;
            printf("[%9.3f ms] RTC write-back: 20%02llX-%02llX-%02llX %02llX:%02llX:%02llX.%02llX weekday %llu (0 = Monday)\n",
                   cyc / CLK_HZ * 1e3, (unsigned long long)(t >> 48 & 0xFF), (unsigned long long)(t >> 40 & 0xFF),
                   (unsigned long long)(t >> 32 & 0xFF), (unsigned long long)(t >> 24 & 0xFF),
                   (unsigned long long)(t >> 16 & 0xFF), (unsigned long long)(t >> 8 & 0xFF),
                   (unsigned long long)(t & 0xFF), (unsigned long long)(t >> 56));
        }
        if (tb->io_wr) {
            if (rtclog && ((tb->io_addr & 0x3F0) == 0x2C0 || (tb->io_addr & 0x3FF) == 0x230))
                printf("[%9.3f ms] OUT %03X %02X\n", cyc / CLK_HZ * 1e3, tb->io_addr & 0x3FF, tb->io_data);
            if ((tb->io_addr & 0xFFFF) == 0x80 && !quiet)
                printf("[%9.3f ms] POST %02X\n", cyc / CLK_HZ * 1e3, tb->io_data);
            if (vidlog && ((tb->io_addr & 0x3F0) == 0x3B0 || (tb->io_addr & 0x3F0) == 0x3D0 ||
                           (tb->io_addr & 0x3FF) == 0x230))
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
        if (PVC4_BUILD && tb->vid_ce) {
            pring[pdots++ & (pring.size() - 1)] = tb->vid_rgbi | tb->vid_mono << 4 | tb->vid_hsync << 5 |
                                                  tb->vid_vsync << 6 | (!tb->vid_hblank && !tb->vid_vblank) << 7;
            pmono_last = tb->vid_monomode;
        }
        if (tb->mda_ce)
            mring[mdots++ & (mring.size() - 1)] = tb->mda_video | tb->mda_intens << 1 | tb->mda_hsync << 2 |
                                                  tb->mda_vsync << 3 | (!tb->mda_hblank && !tb->mda_vblank) << 4;
        if (fdclog) {
            auto *q = tb->rootp;
            static unsigned intr_d = 0, drq_d = 0;
            double ms = cyc / CLK_HZ * 1e3;
            if (q->tb_sys__DOT__u_pc__DOT__u_fdc__DOT__cpu_wr)
                printf("[%9.4f ms] st %llu FDC W a0=%d %02X  %04X:%04X\n", ms, steps, q->tb_sys__DOT__u_pc__DOT__u_fdc__DOT__io_a0,
                       q->tb_sys__DOT__u_pc__DOT__u_fdc__DOT__wdat_q, tb->cs, tb->ip);
            if (q->tb_sys__DOT__u_pc__DOT__u_fdc__DOT__cpu_rd)
                printf("[%9.4f ms] st %llu FDC R a0=%d %02X  %04X:%04X\n", ms, steps, q->tb_sys__DOT__u_pc__DOT__u_fdc__DOT__bus_a0,
                       q->tb_sys__DOT__u_pc__DOT__u_fdc__DOT__cpu_rdata, tb->cs, tb->ip);
            if (q->tb_sys__DOT__u_pc__DOT__u_fdc__DOT__iow_rise && q->tb_sys__DOT__u_pc__DOT__u_fdc__DOT__io_cyc_dor)
                printf("[%9.4f ms] st %llu DOR %02X\n", ms, steps, q->tb_sys__DOT__u_pc__DOT__u_fdc__DOT__wdat_q);
            if (q->tb_sys__DOT__u_pc__DOT__u_fdc__DOT__dma_ack)
                printf("[%9.4f ms] st %llu DMA ack ior=%d iow=%d tc=%d\n", ms, steps, !q->tb_sys__DOT__u_pc__DOT__isa_ior_n,
                       !q->tb_sys__DOT__u_pc__DOT__isa_iow_n, q->tb_sys__DOT__u_pc__DOT__isa_tc);
            if (q->tb_sys__DOT__u_pc__DOT__u_fdc__DOT__tc_pulse)
                printf("[%9.4f ms] st %llu TC\n", ms, steps);
            unsigned it = q->tb_sys__DOT__u_pc__DOT__u_fdc__DOT__intr, dq = q->tb_sys__DOT__u_pc__DOT__u_fdc__DOT__drq;
            if (it != intr_d) printf("[%9.4f ms] st %llu INTR %d\n", ms, steps, it);
            if (dq != drq_d && dq) printf("[%9.4f ms] st %llu DRQ\n", ms, steps);
            intr_d = it; drq_d = dq;
        }
        tb->clk = 1; tb->eval();
        if (cyc % report == 0 && !quiet)
            printf("[%9.3f ms] CS:IP %04X:%04X\n", cyc / CLK_HZ * 1e3, tb->cs, tb->ip);
        // the CPU clock (turbo, doc/turbo.md): every change, and with -cr the CPU
        // clocks of each 50 ms
        {
            static unsigned spd_d = 0;
            static unsigned long long rate_steps = 0, spd_steps = 0, spd_cyc = 0;
            auto *rq = tb->rootp;
            unsigned sp = rq->tb_sys__DOT__u_pc__DOT__spd;
            if (sp != spd_d) {
                static const char *mhz[4] = {"4.77", "7.16", "9.54", "?"};
                printf("[%9.3f ms] CPU clock %s MHz (63h = %02X; %llu CPU clocks in %.3f ms at %s MHz)\n",
                       cyc / CLK_HZ * 1e3, mhz[sp & 3], rq->tb_sys__DOT__u_pc__DOT__u_board__DOT__fe_cfg,
                       steps - spd_steps, (cyc - spd_cyc) / CLK_HZ * 1e3, mhz[spd_d & 3]);
                spd_d = sp; spd_steps = steps; spd_cyc = cyc;
            }
            if (cpurate && cyc % report == 0 && cyc) {
                printf("[%9.3f ms] CPU clocks in 50 ms: %llu (%.4f MHz)\n", cyc / CLK_HZ * 1e3,
                       steps - rate_steps, (steps - rate_steps) / 0.05 / 1e6);
                rate_steps = steps;
            }
        }
        if (shot < shots.size() && cyc / CLK_HZ * 1e3 >= shots[shot]) {
            char t[64];
            snprintf(t, sizeof t, "screen at %.0f ms, CS:IP %04X:%04X", shots[shot], tb->cs, tb->ip);
            dump_screen(tb, t, mono);
            shot++;
        }
    }
    if (tb->hdc_enable)
        printf("hard disk backend: %llu sector reads, %llu sector writes\n", hd_reads, hd_writes);
    if (xtaimg)
        printf("XTA backend: %llu sector reads, %llu sector writes\n", xta_reads, xta_writes);
    if (xtaout && xtaimg) {
        FILE *o = fopen(xtaout, "wb");
        if (!o || fwrite(xta.data(), 1, xta.size(), o) != xta.size()) perror(xtaout);
        if (o) fclose(o);
        printf("XTA image written to %s\n", xtaout);
    }
    if (hdout && hdimg[0]) {
        FILE *o = fopen(hdout, "wb");
        if (!o || fwrite(hd[0].d.data(), 1, hd[0].d.size(), o) != hd[0].d.size()) perror(hdout);
        if (o) fclose(o);
        printf("master image written to %s\n", hdout);
    }

    // the last complete PVC4 frame (VSYNC start to VSYNC start), its window
    if (PVC4_BUILD && imgfile) {
        const size_t N = pring.size();
        auto at = [&](unsigned long long k) { return pring[k & (N - 1)]; };
        unsigned long long lo = pdots > N ? pdots - N + 1 : 1, e = 0, s = 0;
        for (unsigned long long k = pdots - 1; k > lo; k--)
            if ((at(k) & 0x40) && !(at(k - 1) & 0x40)) { if (!e) e = k; else { s = k; break; } }
        if (!s) printf("no complete PVC4 frame recorded\n");
        else {
            static const unsigned char RGBI[16][3] = {
                {0x00, 0x00, 0x00}, {0x00, 0x00, 0xAA}, {0x00, 0xAA, 0x00}, {0x00, 0xAA, 0xAA},
                {0xAA, 0x00, 0x00}, {0xAA, 0x00, 0xAA}, {0xAA, 0x55, 0x00}, {0xAA, 0xAA, 0xAA},
                {0x55, 0x55, 0x55}, {0x55, 0x55, 0xFF}, {0x55, 0xFF, 0x55}, {0x55, 0xFF, 0xFF},
                {0xFF, 0x55, 0x55}, {0xFF, 0x55, 0xFF}, {0xFF, 0xFF, 0x55}, {0xFF, 0xFF, 0xFF}};
            static const unsigned char GREEN[4][3] = {{0, 0, 0}, {0x10, 0x40, 0x10}, {0x20, 0xB0, 0x20}, {0x70, 0xFF, 0x70}};
            std::vector<unsigned char> img, row;
            int w = 0, h = 0;
            for (unsigned long long k = s; k < e; k++) {
                unsigned char d = at(k);
                const unsigned char *c = pmono_last ? GREEN[((d >> 4) & 1) * 2 + ((d >> 3) & 1)] : RGBI[d & 15];
                if (d & 0x80) row.insert(row.end(), c, c + 3);
                else if (!row.empty()) { w = row.size() / 3; img.insert(img.end(), row.begin(), row.end()); row.clear(); h++; }
            }
            std::string fn = std::string(imgfile) + ".ppm";
            FILE *pf = fopen(fn.c_str(), "wb");
            fprintf(pf, "P6\n%d %d\n255\n", w, h);
            fwrite(img.data(), 1, (size_t)w * h * 3, pf);
            fclose(pf);
            printf("PVC4 frame (%s): %llu dots, window %dx%d -> %s\n", pmono_last ? "mono" : "colour", e - s, w, h,
                   fn.c_str());
        }
    }
    if (PVC4_BUILD)
        for (int k = 0; k < 2; k++) {
            int n = 0; double sum = 0;
            printf("PVC4 CPU %s of its memory, wait states:", k ? "writes" : "reads");
            for (int t = 0; t < 32; t++) if (pw_hist[k][t]) { printf(" %d:%d", t, pw_hist[k][t]); n += pw_hist[k][t]; sum += t * pw_hist[k][t]; }
            printf(" (%d cycles, mean %.2f)\n", n, n ? sum / n : 0.0);
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
