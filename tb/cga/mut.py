#!/usr/bin/env python3
"""Mutation check for tb/cga: each mutant breaks one modelled behaviour of
the card; the testbench must fail on every one of them.

usage: mut.py [-j N] [-m name]   (work dirs under $OUT/mut, default ~/pcxt-work/cga;
                                 -m: only the mutants whose name contains it)
"""
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, '../../rtl/video/cga'))
OUT = os.environ.get('OUT', os.path.expanduser('~/pcxt-work/cga'))

C = 'cga_card.sv'
R = 'cga_crtc.sv'
MUTANTS = [
    ('read lead', C, "parameter int RD_LEAD  = 6,", "parameter int RD_LEAD  = 5,", 'waits'),
    ('write lead', C, "parameter int WR_LEAD  = 3,", "parameter int WR_LEAD  = 4,", 'waits'),
    ('slot phase', C, "dc == 4'd14 && el", "dc == 4'd13 && el", 'waits'),
    ('ce delay 7', C, "parameter int CE_DELAY = 6,", "parameter int CE_DELAY = 7,", 'status waits'),
    ('ce delay 2', C, "parameter int CE_DELAY = 6,", "parameter int CE_DELAY = 2,", 'torture'),
    ('hsync not lchar-aligned', C, "        post_lclk <= cclk && dn == 4'd0;",
     "        post_lclk <= cclk;", 'mode3'),
    ('card vsync 4 lines', C, "card_vb <= c_vs && vsc < 5'd3;", "card_vb <= c_vs && vsc < 5'd4;", 'mode4'),
    ('status DE', C, "c_vs || !de};", "!de};", 'status'),
    ('lores pair', C, "            pb = pa;\n", "            pb = pa ^ 4'd1;\n", 'mode4'),
    ('640 bit order', C, "word[4'd14 - {col, 1'b0}]", "word[4'd15 - {col, 1'b0}]", 'mode6'),
    ('overscan in 640', C, "wire [3:0] overscan = m_640 ? 4'h0 : cc[3:0];",
     "wire [3:0] overscan = cc[3:0];", 'torture'),
    ('palette bw', C, "if (m_bw && m_gfx && !m_640)", "if (1'b0 && m_gfx)", 'mode5'),
    ('mode not deferred', C, "if (gfx_class(io_d[5:0]) != gfx_class(mode_reg))", "if (1'b0)", 'torture'),
    ('clock switch anywhere', C, "if (dc == 4'd0 && !tick) hclk <= m_hires;", "if (!tick) hclk <= m_hires;",
     'torture'),
    ('blink rate', C, "if (blink_cnt == 4'd15)     txt_blink_on", "if (blink_cnt[2:0] == 3'd7) txt_blink_on",
     'blink'),
    ('snow hchar', C, "snow_pend && dc == 4'd8 && mode_char[0]", "snow_pend && dc == 4'd0 && mode_char[0]",
     'snow'),
    ('glyph row live', C, "assign fr_addr = {1'b1, ~font_thin, chr, ra_q};",
     "assign fr_addr = {1'b1, ~font_thin, chr, ra[2:0]};", 'crtc'),
    ('thin font base', C, "assign fr_addr = {1'b1, ~font_thin, chr, ra_q};",
     "assign fr_addr = {1'b1, 1'b1, chr, ra_q};", 'thin'),
    ('crtc vsync 15 lines', R, "if (x.vsc == 5'd16) begin", "if (x.vsc == 5'd15) begin", 'status'),
    ('crtc hsync width 0', R, "x.hsc      = r3;", "x.hsc      = r3 == 4'd0 ? 4'd1 : r3;", 'torture'),
    ('crtc last line', R, "x.last_line = c9_r9 && !x.prev_last && !x.in_hsync;",
     "x.last_line = c9_r9 && !x.in_hsync;", 'crtc'),
    ('crtc vta compare', R, "if (x.vtac > {1'b0, r5}) x = f_frame_end(x);",
     "if (x.vtac >= {1'b0, r5}) x = f_frame_end(x);", 'mode0'),
    ('crtc cursor end', R, "if (f_ra(x) == r11 && x.mode != M_VTA) x.cur_act = 1'b0;",
     "if (f_ra(x) == r11) x.cur_act = 1'b0;", 'cursor'),
    ('crtc start latch', R, "if (x.vcc == 7'd0 && x.vlc == 5'd0) x.vma = x.sal;",
     "if (x.vcc == 7'd0 && x.vlc == 5'd0) x.vma = start_address;", 'torture'),
    ('crtc light pen', R, "r17 <= s_next.vma[7:0];", "r17 <= s.vma[7:0] + 8'd1;", 'torture'),
]


def run(i, m):
    name, f, old, new, tests = m
    d = os.path.join(OUT, 'mut', 'm%02d' % i)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, 'rtl'))
    for fn in (C, R):
        t = open(os.path.join(RTL, fn)).read()
        if fn == f:
            assert t.count(old) == 1, (name, old)
            t = t.replace(old, new)
        open(os.path.join(d, 'rtl', fn), 'w').write(t)
    b = subprocess.run(['verilator', '--cc', '--exe', '--build', '-O3', '-j', '2', '-Wno-fatal', '-Wno-lint',
                        '-Wno-style', '--public-flat-rw', '--Mdir', os.path.join(d, 'obj'),
                        '--top-module', 'cga_card', os.path.join(d, 'rtl', R), os.path.join(d, 'rtl', C),
                        os.path.join(HERE, 'cga_run.cpp'), '-CFLAGS', '-I' + HERE, '-o', 'cga_run'],
                       capture_output=True, text=True)
    if b.returncode:
        return name, 'BUILD ERROR\n' + b.stderr[-2000:]
    r = subprocess.run([os.path.join(d, 'obj', 'cga_run'), '-f', FONT, '-o', d] + tests.split(),
                       capture_output=True, text=True)
    first = next((l for l in r.stdout.splitlines() if l.startswith('FAIL')), '')
    return name, ('killed  ' + first[:90]) if r.returncode else 'SURVIVED'


if __name__ == '__main__':
    FONT = os.path.join(OUT, 'testfont.bin')
    jobs = os.cpu_count()
    args = sys.argv[1:]
    if '-j' in args:
        jobs = int(args[args.index('-j') + 1])
    sel = [(i, m) for i, m in enumerate(MUTANTS)
           if '-m' not in args or args[args.index('-m') + 1] in m[0]]
    with ThreadPoolExecutor(jobs) as ex:
        res = list(ex.map(lambda a: run(*a), sel))
    survived = 0
    for name, r in res:
        print('%-26s %s' % (name, r))
        survived += not r.startswith('killed')
    print('%d mutants, %d not killed' % (len(res), survived))
    sys.exit(1 if survived else 0)
