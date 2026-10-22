#!/usr/bin/env python3
"""Mutation check for tb/hdc: each mutant breaks one modelled behaviour of
the XTIDE card; the testbench must fail on every one of them.

usage: mut.py [-j N] [-m name]   (work dirs under $OUT/mut, default ~/pcxt-work/xtide;
                                 -m: only the mutants whose name contains it)
"""
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, '../../rtl/hdc'))
OUT = os.environ.get('OUT', os.path.expanduser('~/pcxt-work/xtide'))
FILES = ['hdc_secbuf.sv', 'ata_dev.sv', 'xtide_card.sv']

C = 'xtide_card.sv'
A = 'ata_dev.sv'
B = 'hdc_secbuf.sv'
MUTANTS = [
    ('rev2 = rev1 decode', C, "{o[0], o[2:1], o[3]} : o[3:0]", "o[3:0] : o[3:0]"),
    ('lo-tech write order', C, "dat_wr    = wr_hi;", "dat_wr    = wr_lo;"),
    ('xt-cf 01h not data in 8-bit', C, "rd_hi && variant == 2'd0 && mode8;", "rd_hi && 1'b0;"),
    ('rev1 read latch', C, "if (!mode8) lat_rd <= dat_q[15:8];", "if (1'b0) lat_rd <= dat_q[15:8];"),
    ('multiple block step', A, "blk_end <= min9(c_total, blk_end + c_mult);",
     "blk_end <= min9(c_total, blk_end + 9'd1);"),
    ('write ends before the backend', A, "if (e_done == c_total) begin", "if (1'b1) begin"),
    ('ring overrun', A, "9'(e_next - h_sec) < 9'(SLOTS)", "9'(e_next - h_sec) <= 9'(SLOTS)"),
    ('capacity check', A, "if (e_lba >= cap_c) begin", "if (e_lba > cap_c) begin"),
    ('chs sector base', A, "m_acc <= 28'(r_sect - 8'd1);", "m_acc <= 28'(r_sect);"),
    ('status keeps INTRQ', A, "ipend <= 1'b0;                  // reading Status", "ipend <= ipend;  // reading Status"),
    ('srst keeps 8-bit mode', A, "g_mode8 <= 2'b00;           // a reset", "// a reset"),
    ('set multiple any count', A, "(r_nsect & (r_nsect - 8'd1)) == 8'd0", "1'b1"),
    ('identify capacity', A, "8'd60: id_word = hd_sectors[c_dev][15:0];", "8'd60: id_word = hd_sectors[c_dev][16:1];"),
    ('drq before prefetch', A, "if (pf_ok) begin", "if (1'b1) begin"),
    ('write irq first block', A, "if (h_sec != 9'd0) ipend <= 1'b1;", "ipend <= 1'b1;"),
    ('irq at end of read', A, "(c_kind != C_READ && c_kind != C_IDENT)) ipend", "1'b1) ipend"),
    ('absent slave status', A, "status = 8'h00;   // device 0 answers", "status = 8'h50;   // device 0 answers"),
    ('blk gap 4 us', C, "parameter int          BLK_US   = 2,", "parameter int          BLK_US   = 4,"),
    ('chs end address', A, "r_sect <= m_rem[7:0] + 8'd1;", "r_sect <= m_rem[7:0];"),
    ('secbuf short read ok', B, "x_err <= sp_err || (!sp_write && cnt + 10'(sp_rd_valid) < 10'd512)",
     "x_err <= sp_err || (1'b0 && cnt + 10'(sp_rd_valid) < 10'd512)"),
]


def run(i, m):
    name, f, old, new = m
    d = os.path.join(OUT, 'mut', 'm%02d' % i)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, 'rtl'))
    for fn in FILES:
        t = open(os.path.join(RTL, fn)).read()
        if fn == f:
            assert t.count(old) == 1, (name, old)
            t = t.replace(old, new)
        open(os.path.join(d, 'rtl', fn), 'w').write(t)
    b = subprocess.run(['verilator', '--cc', '--exe', '--build', '-O3', '-j', '2', '-Wno-fatal', '-Wno-lint',
                        '-Wno-style', '--Mdir', os.path.join(d, 'obj'), '--top-module', 'xtide_card', '-GIRQ=5']
                       + [os.path.join(d, 'rtl', fn) for fn in FILES]
                       + [os.path.join(HERE, 'hdc_run.cpp'), '-o', 'hdc_run', '-CFLAGS', '-O2'],
                       capture_output=True, text=True)
    if b.returncode:
        return name, 'BUILD ERROR\n' + b.stderr[-2000:]
    try:
        r = subprocess.run([os.path.join(d, 'obj', 'hdc_run')], capture_output=True, text=True, timeout=600)
    except subprocess.TimeoutExpired:
        return name, 'killed  (timeout)'
    first = next((l for l in r.stdout.splitlines() if l.startswith('FAIL')), '')
    return name, ('killed  ' + first[:100]) if r.returncode else 'SURVIVED'


if __name__ == '__main__':
    jobs = 4
    args = sys.argv[1:]
    if '-j' in args:
        jobs = int(args[args.index('-j') + 1])
    sel = [(i, m) for i, m in enumerate(MUTANTS)
           if '-m' not in args or args[args.index('-m') + 1] in m[0]]
    with ThreadPoolExecutor(jobs) as ex:
        res = list(ex.map(lambda a: run(*a), sel))
    survived = 0
    for name, r in res:
        print('%-30s %s' % (name, r))
        survived += not r.startswith('killed')
    print('%d mutants, %d not killed' % (len(res), survived))
    sys.exit(1 if survived else 0)
