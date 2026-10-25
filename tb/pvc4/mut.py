#!/usr/bin/env python3
"""Mutation check for tb/pvc4: each mutant breaks one behaviour of the chip;
the testbench must fail on every one of them.

usage: mut.py [-j N] [-m name]   (work dirs under $OUT/mut, default ~/pcxt-work/pvc4/tb;
                                 -m: only the mutants whose name contains it)
"""
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, '../../rtl/video'))
OUT = os.environ.get('OUT', os.path.expanduser('~/pcxt-work/pvc4/tb'))

C = 'pvc4.sv'
# (name, old, new, tests)
MUTANTS = [
    # CPU access (the memory sequence)
    ('CPU part 4 T', 'parameter int CPU_T = 5,', 'parameter int CPU_T = 4,', 'waits'),
    ('no request synchroniser', 'end else if (seq_start && req_s) begin', 'end else if (seq_start) begin', 'waits'),
    ('colour sequence at phase 8', "tick && dn == 4'd0;", "tick && dn == 4'd8;", 'waits'),
    ('mono sequence every character', "ev_e && (gfx_c || !cpar || !m_hires)", "ev_e", 'waits'),
    ('mono sequencer on the divided clock', "wire   vtick     = mono ? osc_rise : tick;",
     "wire   vtick     = mono ? rise : tick;", 'waits'),
    ('write at the sequence start', 'assign va_we  = cpu_do && mem_wr;',
     "assign va_we  = busy && vtick && cpu_cnt == 4'd0 && mem_wr;", 'waits'),
    ('READY without the strobe decode', 'assign isa_ready = !(mem_any_q && !done);',
     'assign isa_ready = !(mem_any_q && !done && !busy);', 'waits'),
    # registers
    ('unlock after one read', "if (io_rd_end && io_a == 4'h8) ulk <= ulk == 2'd2 ? 2'd2 : ulk + 2'd1;",
     "if (io_rd_end && io_a == 4'h8) ulk <= 2'd2;", 'regs'),
    ('unlock not broken by other I/O', "            else ulk <= 2'd0;",
     "            else if (io_rd_end || io_wr_end) ulk <= 2'd0;", 'regs'),
    ('Paradise register without unlock', "wire  wr_par  = io_wr_end && io_a == 4'hB && ulk == 2'd2;",
     "wire  wr_par  = io_wr_end && io_a == 4'hB;", 'regs'),
    ('3X8 not readable', "            isa_din  = mr;", "            isa_din  = 8'hFF;", 'regs'),
    ('3DD not cleared in alpha', "if (!mr_nx[1] || par_nx[7] || par_nx[3]) pl <= '0;",
     "if (par_nx[7] || par_nx[3]) pl <= '0;", 'regs'),
    ('3BF not cleared by colour', "if (!par_nx[7]) hgc <= 2'b00;", "", 'regs'),
    ('CRTC lock ignored', "wire        crtc_locked  = lock_c && crtc_sel <= 5'd11;",
     "wire        crtc_locked  = 1'b0;", 'regs'),
    ('R8 written', "assign crtc_din = crtc_sel == 5'd8  && !crtc_wa ? 8'h00 :",
     "assign crtc_din = crtc_sel == 5'd31 && !crtc_wa ? 8'h00 :", 'regs'),
    ('R10 bit 6 kept', "crtc_sel == 5'd10 && !crtc_wa ? {2'b00, io_d[5:0]} : io_d;",
     "crtc_sel == 5'd10 && !crtc_wa ? io_d : io_d;", 'regs'),
    ('mono light pen at 3BC', "((io_rd_end || io_wr_end) && io_a == (mono ? 4'h9 : 4'hC));",
     "((io_rd_end || io_wr_end) && io_a == 4'hC);", 'regs'),
    ('status bit 4 constant', "wire [7:0] c_status = {3'b111, cnf[6],", "wire [7:0] c_status = {3'b111, 1'b1,", 'regs'),
    ('enable ignored', "wire        memr  = enable && !isa_memr_n;", "wire        memr  = !isa_memr_n;", 'regs'),
    ('mono status bit 7 polarity', "wire [7:0] m_status = {!vs1,", "wire [7:0] m_status = {vs1,", 'mstatus'),
    # colour display
    ('no flicker override', "wire  [5:0] mode_now = {mode[5:4], mode[3] || !par[2], mode[2:0]};",
     "wire  [5:0] mode_now = mode;", 'flicker'),
    ('border control ignored', "wire [3:0] overscan = !r.bdr ? 4'h0 :", "wire [3:0] overscan = 1'b0 ? 4'h0 :", 'torture'),
    ('Plantronics 320 colour order', "return {p1[0], p0[1], p0[0], p1[1]};", "return {p1[1], p0[1], p0[0], p1[0]};",
     'plant'),
    ('Plantronics 640 planes swapped', "pa = r_en ? pal4({word1[bit_a], word[bit_a]}, r.cc, r_bw) : 4'h0;",
     "pa = r_en ? pal4({word[bit_a], word1[bit_a]}, r.cc, r_bw) : 4'h0;", 'plant'),
    ('Plantronics plane swap ignored', "plo ? a[14] ^ (sw && gr) : 1'b0", "plo ? a[14] : 1'b0", 'plant'),
    ('force80 ignored', "if (dc == 4'd0 && !tick) hclk <= (hs_mode && post ? mode_reg[0] : mode[0]) || force80;",
     "if (dc == 4'd0 && !tick) hclk <= (hs_mode && post ? mode_reg[0] : mode[0]);", 'torture'),
    # mono display
    ('9-dot strap ignored', "            w9    <= c9dot;", "            w9    <= 1'b1;", 'mono8'),
    ('9th dot for E0-FF', "wire        box     = s1.chr[7:5] == 3'b110;", "wire        box     = s1.chr[7:5] == 3'b111;",
     'mono'),
    ('underline row fixed', "s2.ul    <= mfg_in == 3'd1 && ra == ul_row;",
     "s2.ul    <= mfg_in == 3'd1 && ra == 5'd13;", 'mono'),
    ('no mono divide', "wire            rise = m_hires ? osc_rise : osc_rise && !mdiv;",
     "wire            rise = osc_rise;", 'mono40'),
    ('mono video enable not forced', "wire [7:0]  matt_in = en_eff ? s1.att : 8'h00;",
     "wire [7:0]  matt_in = mr[3] ? s1.att : 8'h00;", 'mtorture'),
    ('HGC bank from RA0', "mbank <= gfx_c && ra[1];", "mbank <= gfx_c && ra[0];", 'hgc'),
    ('HGC page ignored', "wire [14:0] a_mgfx  = {m_page, ra[0], ma[11:0], 1'b0};",
     "wire [14:0] a_mgfx  = {1'b0, ra[0], ma[11:0], 1'b0};", 'hgc'),
    # character generator
    ('CBM A11 from the mapping', "if (cbm) return {a14, a13, ch[7], a11, ch[6:0], row};",
     "if (cbm) return {a14, a13, ch[7], ~monoro, ch[6:0], row};", 'cbm'),
    ('CBM A13 ignored', "if (cbm) return {a14, a13, ch[7], a11, ch[6:0], row};",
     "if (cbm) return {a14, 1'b0, ch[7], a11, ch[6:0], row};", 'cbm'),
    ('CBM A14 ignored', "if (cbm) return {a14, a13, ch[7], a11, ch[6:0], row};",
     "if (cbm) return {1'b1, a13, ch[7], a11, ch[6:0], row};", 'cbm'),
    ('CBM char bit 7 at A11', "if (cbm) return {a14, a13, ch[7], a11, ch[6:0], row};",
     "if (cbm) return {a14, a13, a11, ch[7], ch[6:0], row};", 'cbm'),
    ('CBM data not reversed', "wire  [7:0]  font_wd = font_cbm ?", "wire  [7:0]  font_wd = 1'b0 ?", 'cbm'),
    ('IBM data reversed too', "wire  [7:0]  font_wd = font_cbm ?", "wire  [7:0]  font_wd = 1'b1 ?", 'cmode3'),
]


def run(i, m):
    name, old, new, tests = m
    d = os.path.join(OUT, 'mut', 'm%02d' % i)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, 'rtl'))
    t = open(os.path.join(RTL, 'pvc4', C)).read()
    assert t.count(old) == 1, (name, old)
    open(os.path.join(d, 'rtl', C), 'w').write(t.replace(old, new))
    cmd = ['verilator', '--cc', '--exe', '--build', '-O3', '-j', '2', '-Wno-fatal', '-Wno-lint', '-Wno-style',
           '--public-flat-rw', '--Mdir', os.path.join(d, 'obj'), '--top-module', 'pvc4',
           os.path.join(RTL, 'cga', 'cga_crtc.sv'), os.path.join(d, 'rtl', C), os.path.join(HERE, 'pvc4_run.cpp'),
           '-o', 'pvc4_run', '-CFLAGS', '-I' + HERE]
    b = subprocess.run(['nice'] + cmd, capture_output=True, text=True)
    if b.returncode:
        return name, 'BUILD ERROR\n' + b.stderr[-2000:]
    r = subprocess.run(['nice', os.path.join(d, 'obj', 'pvc4_run'), '-f', FONT, '-o', d] + tests.split(),
                       capture_output=True, text=True)
    first = next((l for l in r.stdout.splitlines() if l.startswith('FAIL')), r.stdout.splitlines()[-1:] or [''])
    if isinstance(first, list):
        first = first[0] if first else ''
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
        print('%-34s %s' % (name, r))
        survived += not r.startswith('killed')
    print('%d mutants, %d not killed' % (len(res), survived))
    sys.exit(1 if survived else 0)
