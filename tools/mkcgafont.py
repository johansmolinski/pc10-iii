#!/usr/bin/env python3
"""Generate CORE/font/cga_default.hex, the CGA font the core has without a user ROM.

The 8x8 glyphs 00-7F are GLaBIOS's graphics character set (GLaBIOS is GPL-3.0; the font
bitmaps are VileR's, CC BY-SA 4.0, https://int10h.org/oldschool-pc-fonts/), read from the
GLaBIOS source. 80-FF stay empty (GLaBIOS has no upper half; load an IBM character ROM as
/pc10/cga.rom for it). Layout of IBM's 5788005 ROM: the 8x8 font at 0x1800, a thin copy at
0x1000 (each row with its right edges removed, as tb/cga/mkfont.py does), and at 0x0000-0x0FFF
the MDA font, the 8 rows stretched to 14 (rows 0-7 at char * 8 + row, 8-13 at 0x0800 +; the
PC10-III's PVC4 uses it in its mono personality, doc/pvc4.md 5.2).
Output: 8192 lines, one byte in hex each (tdp_ram's ROM_FILE_HEX format).

usage: tools/mkcgafont.py GLABIOS.ASM CORE/font/cga_default.hex
"""
import re
import sys

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
for c in range(128):
    for r in range(8):
        b = glyphs[c][r]
        rom[0x1800 + c * 8 + r] = b
        rom[0x1000 + c * 8 + r] = b & ~(b >> 1) & 0xFF
    for r in range(14):
        rom[(0x800 if r >= 8 else 0) + c * 8 + (r & 7)] = glyphs[c][r * 8 // 14]
with open(out, 'w') as f:
    for b in rom:
        f.write('%02X\n' % b)
