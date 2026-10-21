#!/usr/bin/env python3
"""Generate the retimed CALC_EA memory modes (run once, 2026-10-21).

  gen_ea_modes.py microcode.txt microcode.txt [MR=n ...]

Reads CALC_EA's 24 memory-mode routines (jump table at 0x0800, 8 words per
{MOD,RM}) and appends copies at 0x1100 + 16 * index to the listing:
  - r2 gets the request release (0xA00n: n cycles after the last queue read)
    instead of the old EA clock count; 0x0780 loads it into the BIU;
  - a SYNC before the displacement fetch reads it 2 + pre cycles after the
    ModR/M byte.
pre/post are MartyPC's per-mode EA costs (cpu_808x/modrm.rs). The release is
2 + pre for modes without displacement, 1 + post after the last
displacement byte otherwise; MR=n overrides it for one mode. Prints the
mcset.py arguments that point the table slots at the copies.
"""
import sys
src, out = sys.argv[1], sys.argv[2]
REL = {}  # (mod,rm) -> release override
for a in sys.argv[3:]:
    k, v = a.split('=')
    REL[k] = int(v)
words = {}
cur = None; halves = []
for line in open(src):
    t = line.split()
    if len(t) == 5 and t[0] == 'p' and t[3] == '00001':
        if t[1] == '00': cur = int(t[4], 16); halves = []
        else:
            halves.append(int(t[4], 16))
            if len(halves) == 2: words[cur] = (halves[0] << 16) | halves[1]
PRE = {0: 4, 1: 5, 2: 5, 3: 4, 4: 2, 5: 2, 6: 2, 7: 2}
POST = {1: 3, 2: 2}
lines = ['#', '# ---- EA modes with SYNC and request release (generated)']
sets = {}
def w(a, v, c=''):
    if c: lines.extend(['#', '# ' + c])
    lines.extend([f'p 00 00000 00001 {a:04X}', f'p 01 00000 00001 {v >> 16:04X}', f'p 01 00000 00001 {v & 0xFFFF:04X}'])
k = 0
for mod in range(3):
    for rm in range(8):
        base = 0x800 + (mod << 6) + (rm << 3)
        orig = []
        a = base
        while True:
            orig.append(words.get(a, 0)); a += 1
            if orig[-1] == 0x10000780: break
        nb = 0x1100 + 16 * k; k += 1
        disp = mod in (1, 2) or (mod == 0 and rm == 6)
        if mod == 0 and rm == 6:
            pre, post = 0, 1
        elif mod == 0:
            pre, post = PRE[rm], 0
        else:
            pre, post = PRE[rm], POST[mod]
        rel = (1 + post) if disp else (2 + pre)
        rel = REL.get(f'{mod}{rm}', rel)
        new = []
        for x in orig:
            if (x >> 16) == 0x5BFF:
                new.append((0x5BFF0000 | rel, f'r2 = release (since the last queue read): {rel} cycle(s) after the last queue read'))
                continue
            if x in (0x110002A5, 0x110002E5):
                new.append((0x00004000 | (2 + pre), f'SYNC: the displacement is read {2 + pre} cycles after the ModR/M byte'))
            new.append((x, ''))
        for i, (x, c) in enumerate(new):
            w(nb + i, x, c)
        sets[base] = 0x10000000 | nb
lines.append('#')
open(out, 'a').write('\n'.join(lines) + '\n')
print(' '.join(f'{a:04X}={v:08X}' for a, v in sets.items()))
