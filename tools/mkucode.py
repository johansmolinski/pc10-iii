#!/usr/bin/env python3
"""mkucode.py - build the 8088 microcode bundle that the PC10-III core loads
from the SD card (/pc10/ucode.bin) and the simulations load from
~/pcxt-work/ucode/.

The bundle holds the four tables of the 8086/8088 that come from Intel's die
(AGENTS.md rule 4: none of them is in this repository or in the bitstream):
  - the microcode ROM, 512 words of 21 bits;
  - the address decoder of that ROM ("compression": a 13-bit microcode
    address {AR, CR} -> one of 128 four-word rows);
  - the translation ROM (EA routine entries, long jump/call targets);
  - the group decode ROM (instruction classes per opcode).
This tool contains no table data. It decodes them from your own copy of the
public sources:

  Andrew Jenner's "8086 microcode disassembled" v2 archive,
  https://www.reenigne.org/misc/8086_microcode_v2.zip (from Ken Shirriff's
  die photos): roms/l0..l3, r0..r3 (8088) and l0a..r3a (8086) bit images,
  roms/0t..8b (the ROM's address decoder), roms/translation_8088.txt /
  translation_8086.txt, roms/group.txt;

and optionally the 8086 microcode of nand2mario's z8086
(src/z8086/ucode.hex, the same ROM as Jenner's 8086 images) in place of the
8086 bit images. The decoding follows Jenner's XTCE (xtce_microcode.h, The
Unlicense) and his disassembler.

  mkucode.py --jenner DIR [--cpu 8088|8086] [--ucode-hex FILE] -o OUT
  mkucode.py --check FILE

--cpu 8088 (default) builds the genuine 8088 bundle (flag bit 0 set: the
EU's interrupt overlay is off). --cpu 8086 builds an 8086 bundle; the EU then
replaces the interrupt words that differ on the 8088 with its own overlay
(rtl/cpu/z8086/z86_eu.sv, doc/z8086.md).

Bundle format, version 1 (little endian, 6144 bytes):
  0x0000  8   magic "PC10UCOD"
  0x0008  1   version (1)
  0x0009  1   flags: bit 0 = genuine 8088 ROM (overlay off), bit 1 = 8086 ROM
  0x000A  2   size of the bundle (0x1800)
  0x000C  2   checksum: sum of the bytes 0x0100..0x17FF, modulo 65536
  0x000E  2   0
  0x0010  32  description (ASCII, NUL padded)
  0x0030      0 up to 0x01FF
  0x0200  512 translation ROM: 256 x u16, entry {mode_rm[4:0], mem_read_not,
              is_mem, disp_not} -> {AR[8:0], CR[3:0]}
  0x0400  1K  group decode: 512 x u16 (the 15 outputs in z8086's order and
              polarity), index = opcode, 0x100 = the interrupt pseudo-opcode
  0x0800  2K  address decoder: 2048 x u8, {AR, CR}[12:2] -> ROM row group
              (0..127; 0 where no row answers)
  0x1000  2K  microcode: 512 x u32 (21 bits), row 4 * group + CR[1:0]
"""

import argparse
import os
import struct
import sys

MAGIC = b"PC10UCOD"
VERSION = 1
SIZE = 0x1800
OFF_TRANS, OFF_GROUP, OFF_PACK, OFF_UCODE = 0x200, 0x400, 0x800, 0x1000
FLAG_8088, FLAG_8086 = 1, 2


def read_text(path):
    with open(path, "rb") as f:
        return f.read().decode("latin1").replace("\r", "")


def roms_dir(d):
    return os.path.join(d, "roms") if os.path.isdir(os.path.join(d, "roms")) else d


def decode_rom(d, cpu):
    """512 x 21-bit words from the bit images (XTCE's CPUEmulator)."""
    sfx = "a" if cpu == "8086" else ""
    words = [0] * 512
    for y in range(4):
        h = 24 if y < 3 else 12
        for half in range(2):
            s = read_text(os.path.join(d, ("l" if half else "r") + str(y) + sfx + ".txt"))
            rows = s.split("\n")
            for yy in range(h):
                ib = y * 24 + yy
                line = rows[yy]
                for xx in range(64):
                    if line[63 - xx] == "0":
                        words[xx * 8 + half * 4 + yy % 4] |= 1 << (20 - (ib >> 2))
    return words


def decode_pack(d):
    """2048 entries: microcode address bits 12..2 -> row group (XTCE)."""
    stage1 = [0] * 128
    xxs = [0, 8, 24, 40, 56, 72, 88, 104, 120]
    for g in range(9):
        n = 8 if g in (0, 8) else 16
        for h in range(2):
            rows = read_text(os.path.join(d, str(g) + ("t" if h == 0 else "b") + ".txt")).split("\n")
            for y in range(11):
                for x in range(n):
                    if rows[y][x] == "0":
                        stage1[127 - (x + xxs[g])] |= 1 << (y * 2 + (h ^ (1 if y <= 2 else 0)))
    order = [7, 2, 1, 0, 5, 6, 8, 9, 10, 3, 4]
    pack = [0] * 2048
    for i in range(2048):
        for j in range(128):
            s1 = stage1[j]
            if s1 == 0:
                continue
            ok = True
            for b in range(11):
                x = (s1 >> (order[b] * 2)) & 3
                ib = (i >> (10 - b)) & 1
                if not (x == 0 or (x == 1 and ib == 1) or (x == 2 and ib == 0)):
                    ok = False
                    break
            if ok:
                pack[i] = j
                break
    return pack


def decode_translation(d, cpu):
    """256 entries of 13 bits (XTCE: 33 pattern lines, the last match wins)."""
    lines = [l for l in read_text(os.path.join(d, "translation_%s.txt" % cpu)).split("\n") if l.strip()]
    t = [0] * 256
    for l in lines[:33]:
        pat = l[:8]
        bits = "".join(c for c in l[8:] if c in "01")[:14]
        out = int(bits, 2) >> 1
        mask = sum(128 >> j for j, c in enumerate(pat) if c != "?")
        val = sum(128 >> j for j, c in enumerate(pat) if c == "1")
        for j in range(256):
            if (j & mask) == val:
                t[j] = out
    return t


def decode_group(d):
    """512 entries (opcodes 0..0xFF and the interrupt pseudo-opcode 0x100) in
    z8086's order and polarity (the complement of the ROM rows)."""
    s = read_text(os.path.join(d, "group.txt"))
    rows = s.split("\n")
    go = [[0] * 38 for _ in range(15)]
    gi = [[0] * 38 for _ in range(18)]
    for x in range(38):
        for y in range(15):
            go[y][x] = 0 if rows[y][x] == "0" else 1
        for y in range(18):
            c = rows[(y // 2) + 15][x]
            gi[y][x] = (1 if c in "*0" else 0) if (y & 1) == 0 else (1 if c in "*1" else 0)
    yy = [1, 0, 3, 2, 4, 6, 5, 7, 11, 10, 12, 13, 8, 9, 15, 14, 16, 17]
    groups = [None] * 512
    for x in range(34):
        if x == 11:
            continue
        for i in range(0x101):
            if groups[i] is not None:
                continue
            ok = True
            for j in range(9):
                y0 = gi[yy[j * 2]][x]
                y1 = gi[yy[j * 2 + 1]][x]
                b = (i >> j) & 1
                if (y0 == 1 and b == 1) or (y1 == 1 and b == 0):
                    ok = False
                    break
            if ok:
                g = 0
                for j in range(15):
                    g |= go[j][x] << j
                groups[i] = g
    missing = [i for i in range(0x101) if groups[i] is None]
    if missing:
        sys.exit("group.txt: no column for opcodes %s" % missing[:8])
    return [(~g) & 0x7FFF if g is not None else 0 for g in groups]


def read_ucode_hex(path):
    words = []
    for line in open(path):
        line = line.split("//")[0].strip()
        if line:
            words.append(int(line.split()[0], 16) & 0x1FFFFF)
    if len(words) != 512:
        sys.exit("%s: %d words, expected 512" % (path, len(words)))
    return words


def checksum(b):
    return sum(b[0x100:SIZE]) & 0xFFFF


def build(trans, group, pack, ucode, flags, desc):
    b = bytearray(SIZE)
    b[0:8] = MAGIC
    b[8] = VERSION
    b[9] = flags
    struct.pack_into("<H", b, 10, SIZE)
    d = desc.encode("ascii")[:31]
    b[0x10:0x10 + len(d)] = d
    for i, v in enumerate(trans):
        struct.pack_into("<H", b, OFF_TRANS + 2 * i, v)
    for i, v in enumerate(group):
        struct.pack_into("<H", b, OFF_GROUP + 2 * i, v)
    for i, v in enumerate(pack):
        b[OFF_PACK + i] = v
    for i, v in enumerate(ucode):
        struct.pack_into("<I", b, OFF_UCODE + 4 * i, v)
    struct.pack_into("<H", b, 12, checksum(b))
    return bytes(b)


def check(path):
    b = open(path, "rb").read()
    errs = []
    if len(b) != SIZE:
        errs.append("size %d, expected %d" % (len(b), SIZE))
    if b[0:8] != MAGIC:
        errs.append("bad magic")
    if len(b) >= 16:
        if b[8] != VERSION:
            errs.append("version %d" % b[8])
        if struct.unpack_from("<H", b, 10)[0] != SIZE:
            errs.append("size field")
        if len(b) == SIZE and struct.unpack_from("<H", b, 12)[0] != checksum(b):
            errs.append("checksum")
    if errs:
        print("%s: INVALID (%s)" % (path, ", ".join(errs)))
        return 1
    desc = b[0x10:0x30].split(b"\0")[0].decode("ascii", "replace")
    kind = "genuine 8088" if b[9] & FLAG_8088 else "8086 (EU overlay on)"
    print("%s: valid, %s, \"%s\", checksum %04X" % (path, kind, desc, struct.unpack_from("<H", b, 12)[0]))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--jenner", help="Jenner's 8086_microcode_v2 directory (or its roms/)")
    ap.add_argument("--cpu", choices=["8088", "8086"], default="8088")
    ap.add_argument("--ucode-hex", help="z8086's ucode.hex (8086 microcode) instead of the 8086 bit images")
    ap.add_argument("-o", "--out")
    ap.add_argument("--check", help="verify a bundle")
    a = ap.parse_args()
    if a.check:
        sys.exit(check(a.check))
    if not a.jenner or not a.out:
        ap.error("--jenner and -o are required")
    d = roms_dir(a.jenner)
    ucode = decode_rom(d, a.cpu)
    src = "jenner-v2 %s" % a.cpu
    if a.ucode_hex:
        if a.cpu != "8086":
            sys.exit("--ucode-hex is z8086's 8086 microcode: use it with --cpu 8086")
        z = read_ucode_hex(a.ucode_hex)
        diff = sum(1 for i in range(512) if z[i] != ucode[i])
        print("ucode.hex against Jenner's 8086 bit images: %d words differ" % diff)
        ucode = z
        src = "z8086 ucode.hex 8086"
    trans = decode_translation(d, a.cpu)
    group = decode_group(d)
    pack = decode_pack(d)
    flags = FLAG_8088 if a.cpu == "8088" else FLAG_8086
    b = build(trans, group, pack, ucode, flags, src)
    with open(a.out, "wb") as f:
        f.write(b)
    check(a.out)


if __name__ == "__main__":
    main()
