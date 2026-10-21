#!/usr/bin/env python3
"""Build a test character ROM for tb/cga (no IBM content).

The 8x8 glyphs 00-7F come from GLaBIOS (GPL-3.0; the font itself is VileR's,
CC BY-SA 4.0, https://int10h.org/oldschool-pc-fonts/), read at test time from
the GLaBIOS source outside this repository. Glyphs 80-FF are the inverted
glyphs 00-7F. The image has the layout of IBM's 5788005 ROM: the 8x8 font at
0x1800, the "thin" font at 0x1000 (here: each row with its right edges
removed, so the two are visibly different), 0x0000-0x0FFF zero.

usage: mkfont.py GLABIOS.ASM out.bin
"""
import re
import sys


def main():
    src, out = sys.argv[1], sys.argv[2]
    lines = open(src, encoding='latin-1').read().splitlines()
    start = next(i for i, l in enumerate(lines) if l.startswith('GFX_CHARSET LABEL BYTE'))
    glyphs = []
    for l in lines[start:]:
        m = re.match(r'\s*DB\s+((?:0[0-9A-F]{2}H,\s*){7}0[0-9A-F]{2}H)', l)
        if m:
            glyphs.append([int(x.strip()[1:3], 16) for x in m.group(1).split(',')])
            if len(glyphs) == 128:
                break
    assert len(glyphs) == 128, len(glyphs)
    rom = bytearray(8192)
    for c in range(256):
        g = glyphs[c & 0x7F]
        for r in range(8):
            b = g[r] ^ (0xFF if c & 0x80 else 0)
            rom[0x1800 + c * 8 + r] = b
            rom[0x1000 + c * 8 + r] = b & ~(b >> 1) & 0xFF
    open(out, 'wb').write(rom)


if __name__ == '__main__':
    main()
