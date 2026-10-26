#!/usr/bin/env python3
"""Mutation check for tb/clk: each mutant breaks one property of the clock
enables (rtl/system/pc_clocks.sv); the bench (tests ref, fixed, switch, PHASE 0
and 5) must fail on every one.

usage: mut.py [-j N] [-m name]   (work dirs under $OUT/mut, default ~/pcxt-work/turbo/clk)
"""
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, '../../rtl/system/pc_clocks.sv'))
OUT = os.environ.get('OUT', os.path.expanduser('~/pcxt-work/turbo/clk'))

MUTANTS = [
    ('7.16 MHz on /5', "s == 2'd1 ? 3'd4 : 3'd3", "s == 2'd1 ? 3'd5 : 3'd3"),
    ('9.54 MHz on /4', "s == 2'd1 ? 3'd4 : 3'd3", "s == 2'd1 ? 3'd4 : 3'd4"),
    ('4.77 MHz on /4', "return s == 2'd0 ? 3'd6", "return s == 2'd0 ? 3'd4"),
    ('9.54 MHz fall at +2 (= rdy_ce)', "return s[1] ? 3'd1 : 3'd2;", "return 3'd2;"),
    ('7.16 MHz 25% duty', "return s[1] ? 3'd1 : 3'd2;", "return s == 2'd0 ? 3'd2 : 3'd1;"),
    ('switch only at PCLK phase 0', "wire        bound = cnt_n == 5'd0 || cnt_n == 5'd12;",
     "wire        bound = cnt_n == 5'd0;"),
    ('switch every 6 clk', "wire        bound = cnt_n == 5'd0 || cnt_n == 5'd12;",
     "wire        bound = cnt_n == 5'd0 || cnt_n == 5'd6 || cnt_n == 5'd12 || cnt_n == 5'd18;"),
    ('switch anywhere', "wire        bound = cnt_n == 5'd0 || cnt_n == 5'd12;", "wire        bound = 1'b1;"),
    ('c6 wraps at 7', "c6_n  = c6 == per(spd) - 3'd1 ?", "c6_n  = c6 == 3'd6 ?"),
    ('speed 3 runs as 3', "spd_n = bound ? (speed == 2'd3 ? 2'd2 : speed) : spd;", "spd_n = bound ? speed : spd;"),
    ('speed 3 runs as 1', "spd_n = bound ? (speed == 2'd3 ? 2'd2 : speed) : spd;",
     "spd_n = bound ? (speed == 2'd3 ? 2'd1 : speed) : spd;"),
    ('reset keeps the speed', "        spd_n = 2'd0;\n", "        spd_n = spd;\n"),
    ('rdy_ce 2 clk before the step', "rdy_ce      <= c6_n == per(spd_n) - 3'd1;", "rdy_ce      <= c6_n == per(spd_n) - 3'd2;"),
    ('cpu_prestep fixed at 5', "cpu_prestep <= c6_n == per(spd_n) - 3'd1;", "cpu_prestep <= c6_n == 3'd5;"),
    ('ce_477 = cpu_step', "ce_477      <= cnt_n == 5'd0 || cnt_n == 5'd6 || cnt_n == 5'd12 || cnt_n == 5'd18;",
     "ce_477      <= c6_n == 3'd0;"),
    ('ce_477 every 4', "ce_477      <= cnt_n == 5'd0 || cnt_n == 5'd6 || cnt_n == 5'd12 || cnt_n == 5'd18;",
     "ce_477      <= cnt_n[1:0] == 2'd0;"),
]

TESTS = ['ref', 'fixed', 'switch']


def build(work, phase):
    obj = os.path.join(work, 'obj%d' % phase)
    cmd = ['verilator', '--cc', '--exe', '--build', '-O3', '-j', '2', '-Wno-fatal', '-Wno-lint', '-Wno-style',
           '--top-module', 'tb_clk', '--Mdir', obj, '-GPHASE=%d' % phase,
           os.path.join(work, 'pc_clocks.sv'), os.path.join(HERE, 'tb_clk.sv'),
           os.path.join(HERE, 'clk_run.cpp'), '-o', 'clk_run', '-CFLAGS', '-O2']
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        return None
    return os.path.join(obj, 'clk_run')


def one(m):
    name, old, new = m
    src = open(SRC).read()
    if src.count(old) != 1:
        return name, 'PATTERN %d' % src.count(old)
    work = os.path.join(OUT, 'mut', re.sub(r'[^A-Za-z0-9]+', '_', name))
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    open(os.path.join(work, 'pc_clocks.sv'), 'w').write(src.replace(old, new))
    for phase in (0, 5):
        b = build(work, phase)
        if b is None:
            return name, 'killed (does not build)'
        for t in TESTS:
            p = subprocess.run([b, t], capture_output=True, text=True)
            if p.returncode != 0:
                shutil.rmtree(work, ignore_errors=True)
                return name, 'killed by %s (PHASE %d)' % (t, phase)
    return name, 'SURVIVED'


def main():
    j = 6
    sel = None
    a = sys.argv[1:]
    while a:
        if a[0] == '-j':
            j = int(a[1]); a = a[2:]
        elif a[0] == '-m':
            sel = a[1]; a = a[2:]
        else:
            print(__doc__); return 2
    muts = [m for m in MUTANTS if sel is None or sel in m[0]]
    os.makedirs(os.path.join(OUT, 'mut'), exist_ok=True)
    survived = 0
    with ThreadPoolExecutor(j) as ex:
        for name, res in ex.map(one, muts):
            print('%-40s %s' % (name, res), flush=True)
            survived += not res.startswith('killed')
    print('%d of %d mutants killed' % (len(muts) - survived, len(muts)))
    return 1 if survived else 0


sys.exit(main())
