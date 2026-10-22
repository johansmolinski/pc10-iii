#!/usr/bin/env python3
"""Mutation check for tb/mda: each mutant breaks one modelled behaviour of
the card; the testbench must fail on every one of them.

usage: mut.py [-j N] [-m name]   (work dirs under $OUT/mut, default ~/pcxt-work/mda;
                                 -m: only the mutants whose name contains it)
"""
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, '../../rtl/video'))
OUT = os.environ.get('OUT', os.path.expanduser('~/pcxt-work/mda'))

C = 'mda_card.sv'
# (name, old, new, tests, hercules build)
MUTANTS = [
    ('slot sample one dot early', "wire        ev_cap = rise && ph_n == last;",
     "wire        ev_cap = rise && ph_n == last - 4'd1;", 'waits', 0),
    ('slot end at ph 3', "wire        ev_ack = fall && ph == 4'd4;", "wire        ev_ack = fall && ph == 4'd3;",
     'waits', 0),
    ('slot end on the rising edge', "wire        ev_ack = fall && ph == 4'd4;",
     "wire        ev_ack = rise && ph == 4'd4;", 'waits', 0),
    ('6845 without slot', "wire           req = mem_any || crtc_io;", "wire           req = mem_any;", 'waits', 0),
    ('3B8-3BF with slot', "wire        crtc_io = (io_rd || io_wr) && !isa_addr[3];",
     "wire        crtc_io = (io_rd || io_wr);", 'waits', 0),
    ('dot clock rate', "parameter int DOT_INC   = HERC ? 704  : 59609,", "parameter int DOT_INC   = HERC ? 704  : 59610,",
     'text', 0),
    ('no hres stop', "parameter bit HRES_STOP = !HERC,", "parameter bit HRES_STOP = 1'b0,", 'hres', 0),
    ('DE one stage', "de1  <= de;    de2  <= de1;", "de1  <= de;    de2  <= de;", 'text', 0),
    ('cursor one stage', "cur1 <= c_cur; cur2 <= cur1;", "cur1 <= c_cur; cur2 <= c_cur;", 'text', 0),
    ('HSYNC not stretched', "wire        hs_out = (hs1 || hs2) && hs_ok;", "wire        hs_out = hs1 && hs_ok;",
     'text', 0),
    ('status HSYNC not stretched', ": {4'hF, vq, 2'b00, hs1 || hs2};", ": {4'hF, vq, 2'b00, hs1};", 'status', 0),
    ('status video unregistered', ": {4'hF, vq, 2'b00, hs1 || hs2};", ": {4'hF, de2 && d_vid, 2'b00, hs1 || hs2};",
     'status', 0),
    ('no horizontal drive gate', "wire        hs_out = (hs1 || hs2) && hs_ok;",
     "wire        hs_out = (hs1 || hs2);", 'hdrive', 0),
    ('9th dot for E0-FF', "wire       box    = s1.chr[7:5] == 3'b110;", "wire       box    = s1.chr[7:5] == 3'b111;",
     'text', 0),
    ('underline row 13', "s2.ul    <= fg_in == 3'd1 && ra[3:0] == 4'd12;",
     "s2.ul    <= fg_in == 3'd1 && ra[3:0] == 4'd13;", 'text', 0),
    ('reverse bg 6', "s2.rvv   <= fg_in == 3'd0 && bg_in == 3'd7;", "s2.rvv   <= fg_in == 3'd0 && bg_in == 3'd6;",
     'text', 0),
    ('no display fg only', "s2.nod   <= fg_in == 3'd0 && bg_in == 3'd0;", "s2.nod   <= fg_in == 3'd0;", 'text', 0),
    ('no background intensity', ": alpha ? s2.att[3] : s2.att[7] && !m_blink;", ": alpha ? s2.att[3] : 1'b0;",
     'torture', 0),
    ('foreground intensity bit', ": alpha ? s2.att[3] : s2.att[7] && !m_blink;",
     ": alpha ? s2.att[2] : s2.att[7] && !m_blink;", 'text', 0),
    ('blink under cursor', "wire        hide  = blink_cnt[4] && s2.att[7] && m_blink && !cur2;",
     "wire        hide  = blink_cnt[4] && s2.att[7] && m_blink;", 'blink', 0),
    ('cursor blink rate', "wire        curs  = cur2 && blink_cnt[3];", "wire        curs  = cur2 && blink_cnt[2];",
     'blink', 0),
    ('character blink rate', "wire        hide  = blink_cnt[4] &&", "wire        hide  = blink_cnt[3] &&", 'blink', 0),
    ('blink count at VSYNC start', "if (vs1 && !c_vs) blink_cnt", "if (!vs1 && c_vs) blink_cnt", 'blink', 0),
    ('video unregistered', "assign vid_video  = vq;", "assign vid_video  = de2 && d_vid;", 'text', 0),
    ('video enable ignored', "wire [7:0] att_in = m_en ? s1.att : 8'h00;", "wire [7:0] att_in = s1.att;",
     'torture', 0),
    ('font A11 not row 3', "assign fr_addr = {ra[3], s1.chr, ra[2:0]};", "assign fr_addr = {1'b0, s1.chr, ra[2:0]};",
     'text', 0),
    ('glyph bit order', "s2.glyph[3'd7 - ph[2:0]]", "s2.glyph[ph[2:0]]", 'text', 0),
    ('VRAM 2 KB mirror', "assign cpu_off = isa_addr[11:0];", "assign cpu_off = {1'b0, isa_addr[10:0]};",
     'waits', 0),
    ('mode bit 5 ignored', "mode <= {HERC && (cfg[1] ? io_d[7] : mode[7]), 1'b0, io_d[5], 1'b0,",
     "mode <= {HERC && (cfg[1] ? io_d[7] : mode[7]), 1'b0, 1'b1, 1'b0,", 'torture', 0),
    ('no write after an early strobe end', "assign va_we     = wr_slot || wr_early;",
     "assign va_we     = wr_slot;", 'waits', 0),
    ('HGC graphics without 3BF', "HERC && (cfg[0] ? io_d[1] : mode[1]), io_d[0]};",
     "HERC && io_d[1], io_d[0]};", 'hgc', 1),
    ('HGC B8000 with a CGA', "cfg[1] && !cga_fitted;", "cfg[1];", 'hgc', 1),
    ('HGC status bit 7 polarity', "? {!vs1, 3'b000, vq, 2'b00, hs1 || hs2}",
     "? {vs1, 3'b000, vq, 2'b00, hs1 || hs2}", 'hgc', 1),
    ('HGC row bits swapped', "assign a_gfx = {m_page, ra[1:0], ma[11:0], 1'b0};",
     "assign a_gfx = {m_page, ra[0], ra[1], ma[11:0], 1'b0};", 'hgcgfx', 1),
    ('HGC page ignored', "assign a_gfx = {m_page, ra[1:0], ma[11:0], 1'b0};",
     "assign a_gfx = {1'b0, ra[1:0], ma[11:0], 1'b0};", 'hgcgfx', 1),
]


def run(i, m):
    name, old, new, tests, herc = m
    d = os.path.join(OUT, 'mut', 'm%02d' % i)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, 'rtl'))
    t = open(os.path.join(RTL, 'mda', C)).read()
    assert t.count(old) == 1, (name, old)
    open(os.path.join(d, 'rtl', C), 'w').write(t.replace(old, new))
    cmd = ['verilator', '--cc', '--exe', '--build', '-O3', '-j', '2', '-Wno-fatal', '-Wno-lint', '-Wno-style',
           '--public-flat-rw', '--Mdir', os.path.join(d, 'obj'), '--top-module', 'mda_card',
           os.path.join(RTL, 'cga', 'cga_crtc.sv'), os.path.join(d, 'rtl', C), os.path.join(HERE, 'mda_run.cpp'),
           '-o', 'mda_run', '-CFLAGS', '-I' + HERE + (' -DHERC_BUILD=1' if herc else '')]
    if herc:
        cmd[1:1] = ["-GHERC=1'b1"]
    b = subprocess.run(['nice'] + cmd, capture_output=True, text=True)
    if b.returncode:
        return name, 'BUILD ERROR\n' + b.stderr[-2000:]
    r = subprocess.run(['nice', os.path.join(d, 'obj', 'mda_run'), '-f', FONT, '-o', d] + tests.split(),
                       capture_output=True, text=True)
    first = next((l for l in r.stdout.splitlines() if l.startswith('FAIL')), '')
    return name, ('killed  ' + first[:90]) if r.returncode else 'SURVIVED'


if __name__ == '__main__':
    FONT = os.path.join(OUT, 'testfont.bin')
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
