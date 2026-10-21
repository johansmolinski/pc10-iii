#!/usr/bin/env python3
"""Compare an instruction trace of tb/sys (sys_run -i) with MartyPC's
(tools/martypc: instr.txt). Lines are aligned one to one; the first
difference in CS:IP or a register is printed with context.
  itrace_diff.py ours.txt martypc_instr.txt [-n context]
Flags compare as (F & 0x0FD5): MCL86 keeps prefix state in the other bits.
"""
import re, sys

REGS = ['AX', 'BX', 'CX', 'DX', 'SP', 'BP', 'SI', 'DI', 'DS', 'ES', 'SS', 'F']

def parse(line):
    m = re.search(r'([0-9A-F]{4}):([0-9A-F]{4})', line)
    if not m:
        return None
    r = dict(re.findall(r'\b([A-Z]{1,2})=([0-9A-F]{4})', line))
    r = {k: int(v, 16) for k, v in r.items() if k in REGS}
    r['F'] = r.get('F', 0) & 0x0FD5
    return (m.group(1), m.group(2), r, line.rstrip())

def load(p):
    out = []
    for l in open(p):
        if l.startswith('#'):
            continue
        x = parse(l)
        if x:
            out.append(x)
    return out

def main():
    a, b = load(sys.argv[1]), load(sys.argv[2])
    ctx = int(sys.argv[sys.argv.index('-n') + 1]) if '-n' in sys.argv else 4
    # ours reports IP+1 for the very first instruction (the reset JMP FAR)
    i = 1 if a and a[0][1] != b[0][1] else 0
    j = 1 if i else 0
    n = 0
    while i < len(a) and j < len(b):
        ca, cb = a[i], b[j]
        bad = (ca[0], ca[1]) != (cb[0], cb[1]) or any(ca[2].get(k) != cb[2].get(k) for k in cb[2])
        if bad:
            print(f'first difference at instruction {n} (ours line {i}, MartyPC line {j}):')
            for k in range(max(0, j - ctx), j + 2):
                if k < len(b): print('  ref ', b[k][3][:160])
            for k in range(max(0, i - ctx), i + 2):
                if k < len(a): print('  ours', a[k][3][:160])
            diffs = [k for k in cb[2] if ca[2].get(k) != cb[2].get(k)]
            print('  differs:', 'CS:IP' if (ca[0], ca[1]) != (cb[0], cb[1]) else '', diffs)
            return 1
        i += 1; j += 1; n += 1
    print(f'{n} instructions identical')
    return 0

sys.exit(main())
