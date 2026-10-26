#!/usr/bin/env python3
"""Mutation check for tb/rtc: each mutant breaks one behaviour of the
real-time clock (rtl/system/msm6242.sv); the testbench must fail on every one.
A mutant first meets the fast-oscillator build (calendar, torture1-3), then,
if it survives, the exact one (bios, adjust, stoprest, irq, seed, hold).

usage: mut.py [-j N] [-m name]   (work dirs under $OUT/mut, default ~/pcxt-work/rtc/tb)
"""
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, '../../rtl/system/msm6242.sv'))
OUT = os.environ.get('OUT', os.path.expanduser('~/pcxt-work/rtc/tb'))

MUTANTS = [
    # counting
    ('seconds wrap at 58', "if (a.s10 == 3'd5 && a.s1 == 4'd9) begin r.t.s10", "if (a.s10 == 3'd5 && a.s1 == 4'd8) begin r.t.s10"),
    ('minutes wrap at 49', "if (a.mi10 == 3'd5 && a.mi1 == 4'd9)", "if (a.mi10 == 3'd4 && a.mi1 == 4'd9)"),
    ('24 h wrap at 24', "if (a.h10 == 2'd2 && a.h1 == 4'd3)", "if (a.h10 == 2'd2 && a.h1 == 4'd4)"),
    ('12 h: 11 -> 12 keeps AM/PM', "r.t.h1 = 4'd2;  r.t.pm = !a.pm;  c = a.pm;", "r.t.h1 = 4'd2;  r.t.pm = a.pm;  c = a.pm;"),
    ('12 h: day carry at noon', "r.t.h1 = 4'd2;  r.t.pm = !a.pm;  c = a.pm;", "r.t.h1 = 4'd2;  r.t.pm = !a.pm;  c = !a.pm;"),
    ('12 h: 12 -> 0', "r.t.h10[0] = 1'b0;  r.t.h1 = 4'd1;", "r.t.h10[0] = 1'b0;  r.t.h1 = 4'd0;"),
    ('leap: odd tens', "leap = y10[0] ? (y1 == 4'd2 || y1 == 4'd6) :", "leap = y10[0] ? (y1 == 4'd0 || y1 == 4'd6) :"),
    ('February always 29', "lp ? 5'd29 : 5'd28", "5'd29"),
    ('November 31 days', "5'd4, 5'd6, 5'd9, 5'd11:", "5'd4, 5'd6, 5'd9:"),
    ('day carry after the last day', "if (day >= {1'b0, mlen(", "if (day > {1'b0, mlen("),
    ('weekday stands', "r.t.w = (a.w >= 3'd6) ? 3'd0 : a.w + 3'd1;", "r.t.w = a.w;"),
    ('weekday counts to 7', "r.t.w = (a.w >= 3'd6) ? 3'd0 : a.w + 3'd1;", "r.t.w = a.w + 3'd1;"),
    ('month wrap at 13', "if (a.mo10 && a.mo1 == 4'd2) begin", "if (a.mo10 && a.mo1 == 4'd3) begin"),
    ('year 99 -> A0', "r.t.y10 = (a.y10 == 4'd9) ? 4'd0 : a.y10 + 4'd1;", "r.t.y10 = a.y10 + 4'd1;"),
    # HOLD, BUSY
    ('HOLD ignored', "wire  inc_1hz = (c1hz || ctest) && !hold;", "wire  inc_1hz = (c1hz || ctest);"),
    ('held carry lost', "wire  rel     = wr_cd && hold && !wd[0] && pend;", "wire  rel     = 1'b0;"),
    ('held carries add up', "if (rel) pend <= c1hz || ctest;", "if (rel) pend <= 1'b1;"),
    ('BUSY never set', "        busy <= 1'b1;\n        busy_cnt <= 3'd6;", "        busy_cnt <= 3'd6;"),
    ('BUSY clears while HOLD', "if (half && !hold) busy <= busy_cnt != 3'd0;", "if (half) busy <= busy_cnt != 3'd0;"),
    ('BUSY window 1 tick', "busy_cnt <= 3'd6;", "busy_cnt <= 3'd1;"),
    ('BUSY sampled at 32 kHz', "if (half && !hold) busy <=", "if (!hold) busy <="),
    # adjust, STOP, REST, TEST, 24/12
    ('adjust rounds at 40', "wire  adj_up  = t.s10 >= 3'd3;", "wire  adj_up  = t.s10 >= 3'd4;"),
    ('adjust keeps the divider', "        div[14:7] <= '0;\n        dirty <= 1'b1;", "        dirty <= 1'b1;"),
    ('adjust at once', "adj_cnt <= 3'd4;", "adj_cnt <= 3'd1;"),
    ('REST ignored', "    if (rest) div_n[14:7] = '0;\n", ""),
    ('STOP ignored', "if (div[1:0] == 2'd3 && !stop) div_n", "if (div[1:0] == 2'd3) div_n"),
    ('TEST at 4 kHz', "wire ctest  = tick && test && div[1:0] == 2'd3;", "wire ctest  = tick && test && div[2:0] == 3'd7;"),
    ('24/12 without REST', "if (rest) h24 <= wd[2];", "h24 <= wd[2];"),
    ('PM read in 24 h mode', "4'h5: rd = {1'b0, t.pm && !h24, t.h10};", "4'h5: rd = {1'b0, t.pm, t.h10};"),
    # the bus
    ('high nibble 0', "assign isa_din  = isa_dsel ? {4'hF, rd} : 8'h00;", "assign isa_din  = isa_dsel ? {4'h0, rd} : 8'h00;"),
    ('230h bit 6 ignored', "wire sel    = enable && !isa_aen", "wire sel    = !isa_aen"),
    ('write during the whole strobe', "wire wr_end = sel && !isa_iow_n && !(sel_nx && !isa_iow_n_next);", "wire wr_end = sel && !isa_iow_n;"),
    ('S10 4 bits', "4'h1: t.s10  <= wd[2:0];", "4'h1: t.s10  <= wd[2:0] | {2'b00, wd[3]};"),
    # STD.P / IRQ FLAG
    ('IRQ: writing 1 clears', "if (!wd[2]) begin irq <= 1'b0; irq_cnt <= 9'd0; end", "begin irq <= 1'b0; irq_cnt <= 9'd0; end"),
    ('IRQ: pulse never ends', "if (irq_cnt == 9'd1 && !ce[1]) irq <= 1'b0;", ""),
    ('IRQ: MASK ignored', "if (ev && !ce[0] && (!irq || !ce[1])) begin", "if (ev && (!irq || !ce[1])) begin"),
    ('IRQ: 1/32 s', "wire e64    = tick && div[8] && !div_n[8] && !rest;", "wire e64    = tick && div[9] && !div_n[9] && !rest;"),
    ('IRQ: minute event every second', "2'd2:    ev = adj_end ? adj_up : inc_now && st.cm;", "2'd2:    ev = adj_end ? adj_up : inc_now;"),
    # the seed
    ('seed: years + 10', "seed[47:44] - 4'd8 : seed[47:44] + 4'd2;", "seed[47:44] - 4'd9 : seed[47:44] + 4'd1;"),
    ('seed: weekday as is', "sv.w  = (seed[50:48] >= 3'd6) ? 3'd0 : seed[50:48] + 3'd1;", "sv.w  = seed[50:48];"),
    ('seed while HOLD', "wire seed_load = seed_new && !owned && !hold && seed_ok;", "wire seed_load = seed_new && !owned && seed_ok;"),
    ('seed after the PC set the clock', "wire seed_load = seed_new && !owned && !hold && seed_ok;", "wire seed_load = seed_new && !hold && seed_ok;"),
    ('seed: invalid taken', "wire seed_load = seed_new && !owned && !hold && seed_ok;", "wire seed_load = seed_new && !owned && !hold;"),
    ('seed: not waiting for stable data', "wire seed_new  = seed[64] != seed_tog && seed[63:0] == seed_q && seed_stable >= 4'd8;", "wire seed_new  = seed[64] != seed_tog;"),
    ('seed: 12 h noon as AM', "sv.pm  = hb >= 5'd12;", "sv.pm  = hb > 5'd12;"),
    ('seed keeps the divider', "        t <= sv;\n        div <= '0;", "        t <= sv;"),
    # write-back
    ('write-back during HOLD', "if (dirty && !hold && !stop && !adj", "if (dirty && !stop && !adj"),
    ('write-back during STOP', "if (dirty && !hold && !stop && !adj", "if (dirty && !hold && !adj"),
    ('no write-back for an adjust', "        div[14:7] <= '0;\n        dirty <= 1'b1;", "        div[14:7] <= '0;"),
    ('write-back for control registers', "if (ra <= 4'hC) dirty <= 1'b1;", "dirty <= 1'b1;"),
    ('now: 1980s as 2070s', "t.y10 - 4'd2 : t.y10 + 4'd8", "t.y10 - 4'd2 : t.y10 + 4'd7"),
    ('now: weekday as is', "now[63:56] = {5'd0, (t.w == 3'd0) ? 3'd6 : t.w - 3'd1};", "now[63:56] = {5'd0, t.w};"),
    ('now: hundredths x 2', "hu   = hp[21:15];", "hu   = hp[20:14];"),
    ('now: 12 AM as 12', "h  = (hb == 5'd12 ? 5'd0 : hb) + (t.pm ? 5'd12 : 5'd0);", "h  = hb + (t.pm ? 5'd12 : 5'd0);"),
]

FAST_TESTS = ['torture1', 'torture2', 'calendar', 'torture3', 'torture4']
EXACT_TESTS = ['seed', 'bios', 'adjust', 'stoprest', 'irq', 'hold']


def build(work, fast):
    obj = os.path.join(work, 'obj_fast' if fast else 'obj')
    cmd = ['verilator', '--cc', '--exe', '--build', '-O3', '-j', '2', '-Wno-fatal', '-Wno-lint', '-Wno-style',
           '--top-module', 'msm6242', '--Mdir', obj]
    if fast:
        cmd += ['-GOSC_NUM=1', '-GOSC_DEN=8', '-CFLAGS', '-DOSC_NUM=1u', '-CFLAGS', '-DOSC_DEN=8u']
    cmd += [os.path.join(work, 'msm6242.sv'), os.path.join(HERE, 'rtc_run.cpp'), '-o', 'rtc_run',
            '-CFLAGS', '-O3', '-CFLAGS', '-I' + HERE]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        return None
    return os.path.join(obj, 'rtc_run')


def killed_by(binary, tests):
    for t in tests:
        p = subprocess.run([binary, t], capture_output=True, text=True)
        if p.returncode != 0:
            return t
    return None


def one(m):
    name, old, new = m
    src = open(SRC).read()
    if src.count(old) != 1:
        return name, 'PATTERN %d' % src.count(old)
    work = os.path.join(OUT, 'mut', re.sub(r'[^A-Za-z0-9]+', '_', name))
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    open(os.path.join(work, 'msm6242.sv'), 'w').write(src.replace(old, new))
    for fast, tests in ((True, FAST_TESTS), (False, EXACT_TESTS)):
        b = build(work, fast)
        if b is None:
            return name, 'killed (does not build)'
        t = killed_by(b, tests)
        if t:
            shutil.rmtree(work, ignore_errors=True)
            return name, 'killed by %s%s' % ('fast ' if fast else '', t)
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
