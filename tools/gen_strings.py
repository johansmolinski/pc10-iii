#!/usr/bin/env python3
"""Generate the pc10-iii string instruction patches (MOVS/CMPS/SCAS/LODS/STOS)
for the MCL86 microcode listing and apply them with mcset semantics.

  gen_strings.py microcode.txt            print the words (ADDR=WORD)

Timing from the SingleStepTests 8088 suite (tools/sst_sched.py; the REP
analysis is in doc/history.md, 2026-10-21). Cycles counted from the opcode's
queue read; Q = the cycle the EU's bus request goes out (T1 - 3 on an idle
bus); "done" = the end of an EU transfer (a read's T4, a write's T3).
  first transfer   non-REP: opcode + q_one; first REP iteration: opcode + q_rep
  next iteration   q_it after the previous iteration's last transfer ended
  2nd transfer     MOVS: 1 after the read (2 with a segment prefix, no REP);
                   CMPS: 2 after the first read
  end              non-REP: e_one after the last transfer; REP: e_exh when
                   CX runs out, 5 when the Z condition stops CMPS/SCAS;
                   CX = 0 on entry: cycle 7
Iterations after the first are marked with flag bit 1 (scratch: PUSHF/LAHF
mask it), set before looping through the main loop, cleared at 0x0004.
"""
import re, sys

BASE = 0x1720          # patch area for these routines (to ~0x18F0)
OPS = {  # name: (header comment, q_one, q_rep, q_it, e_one, e_exh, mid)
    'MOVSB': ('0xA4 - MOVSB', 3, 10, 5, 3, 4, 'movs'),
    'MOVSW': ('0xA5 - MOVSW', 3, 10, 5, 3, 4, 'movs'),
    'CMPSB': ('0xA6 - CMPSB', 4, 11, 8, 4, 6, 'cmps'),
    'CMPSW': ('0xA7 - CMPSW', 4, 11, 8, 4, 6, 'cmps'),
    'SCASB': ('0xAE - SCASB', 5, 12, 9, 4, 6, None),
    'SCASW': ('0xAF - SCASW', 5, 12, 9, 4, 6, None),
    'LODSB': ('0xAC - LODSB', 3, 10, 7, 3, 6, None),
    'LODSW': ('0xAD - LODSW', 3, 10, 7, 3, 6, None),
    'STOSB': ('0xAA - STOSB', 3, 10, 5, 3, 4, None),
    'STOSW': ('0xAB - STOSW', 3, 10, 5, 3, 4, None),
}

def blocks(path):
    """Words of each op's block: list of (addr, word, comment)."""
    lines = open(path).read().split('\n')
    heads = {}
    for i, l in enumerate(lines):
        for n, o in OPS.items():
            if l.startswith('# ' + o[0]):
                heads[n] = i
    order = sorted(heads.items(), key=lambda kv: kv[1])
    out = {}
    for k, (n, start) in enumerate(order):
        end = order[k + 1][1] if k + 1 < len(order) else start + 400
        words, com, i = [], '', start
        while i < end:
            t = lines[i].split()
            if lines[i].startswith('#'):
                com = lines[i]
            elif len(t) == 5 and t[:4] == ['p', '00', '00000', '00001']:
                h = int(lines[i + 1].split()[4], 16); lo = int(lines[i + 2].split()[4], 16)
                words.append((int(t[4], 16), (h << 16) | lo, com))
                i += 2
            i += 1
        out[n] = words
    return out

def main():
    path = sys.argv[1]
    bl = blocks(path)
    w = {}
    a = BASE
    # shared: arm the end at absolute cycle 7 (CX = 0 on entry)
    ARM_E007 = a
    for x in (0x5FFFE007, 0x5DDF2000, 0x4DDFCFFF, 0x10300000):
        w[a] = x; a += 1
    for n, (hdr, q_one, q_rep, q_it, e_one, e_exh, mid) in OPS.items():
        words = bl[n]
        waits = [i for i, (ad, x, c) in enumerate(words) if 'Write' in c and 'clock' in c]
        isol = [i for i, (ad, x, c) in enumerate(words) if x == 0x4E8FC000]
        # CX_IS_ZERO wait (first), START wait (second); the last REP isolate is REP_END
        cx0 = words[waits[0]][0]
        start = words[waits[1]][0]
        rend = words[isol[-1]][0]
        for i in waits[:2]:
            assert words[i][1] & 0xFFFF0000 == 0x5FFF0000, n
            assert words[i + 1][1] & 0xFFFFFF00 == 0x11000300, n
        # START routine
        a = (a + 7) & ~7
        S = a
        def rel(v):
            return [0x5FFF0000 | v, 0x5DDF3060, 0x4DDFC003, 0x10300000]
        code = [0x4E8F0002, None, 0x4E8FC000, None] + rel(0x4000 | q_one)
        rep1 = S + len(code); code += rel(0x4000 | q_rep)
        it = S + len(code); code += rel(0x2000 | q_it)
        code[1] = 0x10010000 | it
        code[3] = 0x10010000 | rep1
        for x in code: w[a] = x; a += 1
        # END routine
        a = (a + 7) & ~7
        E = a
        def endw(n_):
            return [0x0000C000 | n_, 0x5FFFF000, 0x5DDF2000, 0x4DDFCFFF, 0x10000040]
        if mid == 'cmps' or n.startswith('SCAS'):
            code = [0x4E8FC000, None,                 # 0 REP bits; 1 jz ONE
                    0x4E8F4000, None,                 # 2 REPZ bit;  3 jz CHKNZ
                    0x4E8F0040, None, None,           # 4 ZF; 5 jz COND; 6 jmp CXCHK
                    0x4E8F0040, None,                 # 7 CHKNZ: ZF; 8 jnz COND
                    0x5E2F0000, None, 0x588F0002, 0x10000006]   # 9 CXCHK: CX; 10 jz EXH; 11 marker; 12 loop
            cond = E + len(code); code += endw(5)
            exh = E + len(code); code += endw(e_exh)
            one = E + len(code); code += endw(e_one)
            code[1] = 0x10020000 | one
            code[3] = 0x10020000 | (E + 7)
            code[5] = 0x10020000 | cond
            code[6] = 0x10000000 | (E + 9)
            code[8] = 0x10010000 | cond
            code[10] = 0x10020000 | exh
        else:
            code = [0x4E8FC000, None, 0x5E2F0000, None, 0x588F0002, 0x10000006]
            exh = E + len(code); code += endw(e_exh)
            one = E + len(code); code += endw(e_one)
            code[1] = 0x10020000 | one
            code[3] = 0x10020000 | exh
        for x in code: w[a] = x; a += 1
        # MID routine
        if mid:
            mword = [ad for ad, x, c in words if x == 0x11000750][0]
            a = (a + 7) & ~7
            M = a
            if mid == 'movs':
                code = [0x11000750,                    # CALL STORE_SEG_PREFIX
                        0x4E8FC002, None,              # REP bits or marker -> since-done 1
                        0x4E8F0008, None]              # saved override -> since-done 2
                r1 = M + len(code); code += rel(0x2001)
                r2 = M + len(code); code += rel(0x2002)
                code[2] = 0x10010000 | r1
                code[4] = 0x10010000 | r2
                code.insert(5, 0x10000000 | r1)        # no override: since-done 1
                # fix addresses after the insert
                r1 += 1; r2 += 1
                code[2] = 0x10010000 | r1
                code[4] = 0x10010000 | r2
                code[5] = 0x10000000 | r1
            else:
                code = [0x11000750] + rel(0x2002)
            for x in code: w[a] = x; a += 1
            w[mword] = 0x11000000 | M
        w[cx0] = 0x11000000 | ARM_E007
        w[cx0 + 1] = 0x00000000
        w[start] = 0x11000000 | S
        w[start + 1] = 0x00000000
        w[rend] = 0x10000000 | E
        print(f'# {n}: CX0 {cx0:04X} START {start:04X} END {rend:04X} -> S {S:04X} E {E:04X}', file=sys.stderr)
    w[0x0004] = 0x488F0FDD          # clear flag bit 1 (the REP iteration marker) too
    assert a < 0x1F00, hex(a)
    print(' '.join(f'{ad:04X}={x:08X}' for ad, x in sorted(w.items())))

main()
