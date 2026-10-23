// ucode_file.h - read and check the 8088 microcode bundle (tools/mkucode.py)
// for the simulations, which load it into the CPU through its load port as
// the core's firmware does. The bundle is not in the repository (AGENTS.md
// rule 4); its path comes from $PC10_UCODE, else the default compiled in
// (make Z86_UCODE=..., default ~/pcxt-work/ucode/8088.bin).
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#ifndef Z86_UCODE
#define Z86_UCODE ""
#endif

static inline std::string ucode_path() {
    const char *e = getenv("PC10_UCODE");
    return e && *e ? e : Z86_UCODE;
}

// the checks of the core's firmware (m2m-rom.asm, UCODE_CHECK)
static inline bool ucode_read(std::vector<uint8_t> &b, std::string &err) {
    std::string p = ucode_path();
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) { err = p + ": cannot open (make the bundle with tools/mkucode.py)"; return false; }
    b.assign(0x2000, 0);
    size_t n = fread(b.data(), 1, b.size(), f);
    fclose(f);
    if (n != 0x1800) { err = p + ": not 6144 bytes"; return false; }
    b.resize(n);
    unsigned sum = 0;
    for (size_t i = 0x100; i < n; i++) sum += b[i];
    if (memcmp(b.data(), "PC10UCOD", 8) || b[8] != 1 || (b[10] | b[11] << 8) != 0x1800 ||
        (b[12] | b[13] << 8) != (sum & 0xFFFF)) {
        err = p + ": not a valid microcode bundle (magic, version, size or checksum)";
        return false;
    }
    return true;
}
