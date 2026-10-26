#!/usr/bin/env python3
"""Mutation check for tb/intfd: each mutant breaks one behaviour of drive B:
as the real drive (fdd_intdrv.sv, fdd_phys.sv, fdd_mfm_rd.sv, fdd_mfm_wr.sv);
the testbench must fail on every one of them.

usage: mut.py [-j N] [-m name]   (work dirs under $OUT/mut, default ~/pcxt-work/intfd;
                                 -m: only the mutants whose name contains it)
"""
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, '../../rtl/fdc'))
OUT = os.environ.get('OUT', os.path.expanduser('~/pcxt-work/intfd'))
FILES = ['upd765.sv', 'fdc_secbuf.sv', 'fdc_card.sv', 'fdd_mfm_rd.sv', 'fdd_mfm_wr.sv',
         'fdd_phys.sv', 'fdd_intdrv.sv']

P = 'fdd_phys.sv'
R = 'fdd_mfm_rd.sv'
W = 'fdd_mfm_wr.sv'
I = 'fdd_intdrv.sv'
MUTANTS = [
    # the head
    ('step direction', P, "dir_q       <= want < cur;", "dir_q       <= !(want < cur);"),
    ('homing ignores TRK0', P, "if (trk0 || home_cnt == 7'(HOME_MAX)) begin", "if (home_cnt == 7'(HOME_MAX)) begin"),
    ('homing at the step rate', P, "mv_cnt >= ($bits(mv_cnt))'(homing_step ? T_HOME : T_RATE)",
     "mv_cnt >= ($bits(mv_cnt))'(T_RATE)"),
    ('steps of A: followed', P, "else if (step && select_b) begin", "else if (step) begin"),
    ('no target reset at the PC reset', P, "if (reset || pc_reset)\n        target <= 7'd0;",
     "if (reset)\n        target <= 7'd0;"),
    ('no rehome on a wrong cylinder', P, "rehome  <= 1'b1;", "rehome  <= 1'b0;"),
    ('side pin inverted', P, "assign f_side1_n = !side;", "assign f_side1_n = side;"),
    ('selected while an image', P, "assign sel = enable && (motor_b || req_busy || mv_need);",
     "assign sel = (motor_b || req_busy || mv_need);"),
    # the medium
    ('present without index pulses', P, "assign present = pres_cnt != '0;", "assign present = enable;"),
    ('wp not from the drive', P, "wp_q <= wpt;", "wp_q <= 1'b0;"),
    # finding a sector
    ('ID CRC not checked', P, "if (crc_byte(crc, rb_data) == 16'h0000) begin", "if (1'b1) begin"),
    ('ID C not compared', P, "if (id[0] == q_cyl && id[1]", "if (id[1]"),
    ('ID H not compared', P, "id[1] == {7'd0, q_head} &&", "1'b1 &&"),
    ('ID R not compared', P, "id[2] == q_sec && id[3] == 8'd2", "id[3] == 8'd2"),
    ('search: one index pulse', P, "if (idx_cnt == 2'd2) begin", "if (idx_cnt == 2'd0) begin"),
    ('data mark window short', P, "parameter int DAM_US     = 2500,", "parameter int DAM_US     = 300,"),
    ('data CRC not checked', P, "q_err <= crc_byte(crc, rb_data) != 16'h0000;", "q_err <= 1'b0;"),
    # writing
    ('gap 2 too long', P, "parameter int GAP2_US    = 702", "parameter int GAP2_US    = 1500"),
    ('no write protection check', P, "if ((q_write && wp_q) || q_cyl > 8'd79) begin", "if (q_cyl > 8'd79) begin"),
    ('precompensation from cylinder 0', P, "parameter int PRECOMP_CYL = 40,", "parameter int PRECOMP_CYL = 0,"),
    ('precompensation inverted', W, "if (gb < ga)      fire_at <= 6'(LAUNCH - PRECOMP);",
     "if (gb < ga)      fire_at <= 6'(LAUNCH + PRECOMP);"),
    ('A1 with its clock', W, "if (kind == 2'd1) w[5] = 1'b0;", ""),
    ('MFM clock rule', W, "w[2 * i + 1] = !(q || b[i]);", "w[2 * i + 1] = !b[i];"),
    ('index mark C2 with its clock', W, "if (kind == 2'd2) w[7] = 1'b0;", ""),
    # format
    ('format: every commit writes the track', P,
     "if (fmt_valid && fmt_cyl == q_cyl && fmt_head == q_head)", "if (1'b0)"),
    ('format: remembered across commands', P, "if (!cmd_active) fmt_valid <= 1'b0;", ""),
    ('format: GAP3 long', P, "if (fcnt == 10'(GAP3 - 1)) begin", "if (fcnt == 10'(GAP3 + 39)) begin"),
    ('format: fill byte', P, "nb_data = q_fmt ? fill : cb;", "nb_data = q_fmt ? 8'hE5 : cb;"),
    # the read chain
    # (no runt filter: equivalent here - the DPLL takes a second edge in the same cell as the
    # same '1'; the filter is Megamiga's, kept for edges that would reach the next cell)
    ('DPLL without phase pull', R, "vph   = 14'(signed'(15'(vph)) - (err >>> 1));", "vph   = vph;"),
    ('sync pattern', R, "if (sr_n == 16'h4489 || cnt == 4'd15) begin", "if (sr_n == 16'h44A9 || cnt == 4'd15) begin"),
    # routing
    ('routing not held', I, "wire  route = req_d ? route_q : (sp_drive && enable);",
     "wire  route = sp_drive && enable;"),
    ('B: as 40 tracks', I, "enable ? 8'd80 : i_img_tracks[15:8]", "enable ? 8'd40 : i_img_tracks[15:8]"),
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
                        '-Wno-style', '-Wno-MULTIDRIVEN', '--Mdir', os.path.join(d, 'obj'), '--top-module', 'tb_intfd']
                       + [os.path.join(d, 'rtl', fn) for fn in FILES]
                       + [os.path.join(HERE, 'tb_intfd.sv'), os.path.join(HERE, 'intfd_run.cpp'),
                          '-o', 'intfd_run', '-CFLAGS', '-O2'],
                       capture_output=True, text=True)
    if b.returncode:
        return name, 'BUILD ERROR\n' + b.stderr[-2000:]
    try:
        r = subprocess.run([os.path.join(d, 'obj', 'intfd_run')], capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired:
        return name, 'killed  (timeout)'
    first = next((l for l in r.stdout.splitlines() if l.startswith('FAIL')), '')
    shutil.rmtree(os.path.join(d, 'obj'), ignore_errors=True)
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
        print('%-36s %s' % (name, r))
        survived += not r.startswith('killed')
    print('%d mutants, %d not killed' % (len(res), survived))
    sys.exit(1 if survived else 0)
