#!/usr/bin/env python3
"""Compare a cycle trace of tb/sys (sys_run -t) with MartyPC's normalized one
(tools/martypc/marty2norm.py). Aligns both on the first T1 of the code fetch
from FFFF0 and reports the first clock where the T-state, bus type, the T1
address or the queue status differ.
  ctrace_diff.py ours.txt ref_cycles.txt [-n context]
"""
import sys

def ours(p):
    out = []
    for l in open(p):
        f = l.split()
        if len(f) < 6: continue
        t = 'T1' if f[1] == 'T0' else f[1]
        out.append((t, f[2], f[3] if t == 'T1' else '', f[5], l.rstrip()))
    return out

def ref(p):
    out = []
    for l in open(p):
        if l.startswith('#'): continue
        f = l.split()
        out.append((f[1], f[2], f[3] if f[1] == 'T1' else '', f[5], l.rstrip()))
    return out

def main():
    a, b = ours(sys.argv[1]), ref(sys.argv[2])
    ctx = int(sys.argv[sys.argv.index('-n') + 1]) if '-n' in sys.argv else 12
    i0 = next(i for i, x in enumerate(a) if x[0] == 'T1' and x[2] == 'FFFF0')
    for k in range(min(len(a) - i0, len(b))):
        x, y = a[i0 + k], b[k]
        if x[:4] != y[:4]:
            print(f'first difference at reference clock {k} (ours line {i0 + k}):')
            for j in range(max(0, k - ctx), min(len(b), k + 4)):
                mark = '>' if j == k else ' '
                print(f'{mark} ref  {b[j][4][:110]}')
                print(f'{mark} ours {a[i0 + j][4][:110]}')
            return 1
    print(f'{min(len(a) - i0, len(b))} clocks identical')
    return 0

sys.exit(main())
