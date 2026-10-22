#!/usr/bin/env python3
"""Build a test character ROM for tb/mda and tb/sys (no IBM content).

The 8 KB image has the layout of IBM's 5788005 ROM (doc/mda.md section 5):
  0x0000-0x07FF  MDA 9x14 font, rows 0-7   (char * 8 + row)
  0x0800-0x0FFF  MDA 9x14 font, rows 8-15  (char * 8 + row - 8)
  0x1000-0x17FF  CGA thin 8x8 font
  0x1800-0x1FFF  CGA 8x8 font
Glyphs 00-7F are GLaBIOS's 8x8 font (GPL-3.0; VileR's, CC BY-SA 4.0), read at
test time from the GLaBIOS source outside this repository; 80-FF are the
inverted 00-7F (so C0-DF have their right column set: the MDA's 9th dot).
The MDA rows stretch the 8 rows to 14 (rows 0-13); rows 14 and 15 are the
markers 0x81 and 0x18, shown only when R9 > 13. The CGA part is the same as
tb/cga/mkfont.py.

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
        inv = 0xFF if c & 0x80 else 0
        for r in range(8):
            b = g[r] ^ inv
            rom[0x1800 + c * 8 + r] = b
            rom[0x1000 + c * 8 + r] = b & ~(b >> 1) & 0xFF
        for r in range(16):
            b = (g[r * 8 // 14] ^ inv) if r < 14 else (0x81 if r == 14 else 0x18)
            rom[(0x800 if r >= 8 else 0) + c * 8 + (r & 7)] = b
    open(out, 'wb').write(rom)


if __name__ == '__main__':
    main()
