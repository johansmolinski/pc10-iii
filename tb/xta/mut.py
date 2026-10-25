#!/usr/bin/env python3
"""Mutation check for tb/xta: each mutant breaks one modelled behaviour of
the PC20-III hard disk (xta_card.sv); the testbench must fail on every one.

usage: mut.py [-j N] [-m name]   (work dirs under $OUT/mut, default ~/pcxt-work/xta;
                                 -m: only the mutants whose name contains it)
"""
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, '../../rtl/hdc'))
OUT = os.environ.get('OUT', os.path.expanduser('~/pcxt-work/xta'))
FILES = ['hdc_secbuf.sv', 'xta_card.sv']

X = 'xta_card.sv'
MUTANTS = [
    ('configuration register', X, "2'd2: isa_din <= CONFIG;", "2'd2: isa_din <= CONFIG & 8'hBF;"),
    ('select without REQ', X, "req   <= 1'b1;\n                    irq_l <= 1'b0;",
     "req   <= 1'b0;\n                    irq_l <= 1'b0;"),
    ('BSY during reset', X, "P_IDLE, P_RESET: st_bsy = 1'b0;", "P_IDLE: st_bsy = 1'b0;"),
    ('select during reset', X, "2'd2: if (phase != P_RESET) begin", "2'd2: if (1'b1) begin"),
    ('reset keeps the mask', X, "req   <= 1'b0;  irq_l <= 1'b0;  mask <= 2'b00;\n                    h_act",
     "req   <= 1'b0;  irq_l <= 1'b0;\n                    h_act"),
    ('CCB REQ at once', X, "tmr   <= 22'(CCB_US);", "tmr   <= 22'd0;"),
    ('data in without I/O', X, "P_DIN:           st_io  = 1'b1;", "P_DIN:           ;"),
    ('IRQ not masked', X, "wire irq_o  = enable && irq_l && mask[1];", "wire irq_o  = enable && irq_l;"),
    ('DRQ not masked', X, "req && mask[0] && (phase", "req && (phase"),
    ('DRQ over the strobe', X, "d_take <= 1'b1;  req <= 1'b0;", "d_take <= 1'b1;"),
    ('completion keeps IRQ', X, "irq_l <= 1'b0;\n                phase <= P_FREE;", "phase <= P_FREE;"),
    ('slow bus free', X, "parameter int         FREE_US   = 2,", "parameter int         FREE_US   = 900,"),
    ('completion drive bit', X, "din_q <= {2'b00, c_drv, 3'b000, err, 1'b0};", "din_q <= {6'b000000, err, 1'b0};"),
    ('drive 1 initialize fails', X, "return !(k == K_SENSE || k == K_INIT ||", "return !(k == K_SENSE ||"),
    ('drive 1 never ready', X, "(c_drv ? !(DRV1_READY && kind == K_TEST) : !drive_ready)",
     "(c_drv ? 1'b1 : !drive_ready)"),
    ('cylinder 615 legal', X, "c_cyl >= 10'(LCYL)", "c_cyl > 10'(LCYL)"),
    ('sector 1-based', X, "l0 <= 16'((c_cyl * 4 + 10'(c_head)) * 17) + (kind == K_FMTT ? 16'd0 : 16'(c_sec));",
     "l0 <= 16'((c_cyl * 4 + 10'(c_head)) * 17) + (kind == K_FMTT ? 16'd0 : 16'(c_sec) - 16'd1);"),
    ('sector advance', X, "q_l <= q_l + 16'd1;", "q_l <= q_l + 16'd2;"),
    ('past the end', X, "q_bad <= q_l + 16'd1 >= 16'(LMAX);", "q_bad <= 1'b0;"),
    ('interleave layout', X, "kd = 5'(k / 9);  km = 5'(k % 9);", "kd = 5'd0;  km = k;"),
    ('format keeps interleave', X, "ilv     <= ccb[4][4:0];", "ilv     <= ilv;"),
    ('physical track length', X, "if (q_k == 5'(PSPT - 1)) begin", "if (q_k == 5'(PSPT - 2)) begin"),
    ('spindle slots', X, "sidx   <= sidx == 5'd26 ? 5'd0 : sidx + 5'd1;", "sidx   <= sidx == 5'd25 ? 5'd0 : sidx + 5'd1;"),
    ('seek root bits', X, "m_bit  <= 4'd8;", "m_bit  <= 4'd7;"),
    ('seek constant', X, "parameter int         SEEK_A_US = 2760,", "parameter int         SEEK_A_US = 2000,"),
    ('read buffer arms early', X, "(is_rd ? hdone == mi : hdone > mi)", "(is_rd ? hdone + 9'd1 >= mi : hdone > mi)"),
    ('write arms before data', X, "(is_rd ? hdone == mi : hdone > mi)", "(is_rd ? hdone == mi : hdone >= mi)"),
    ('byte gap', X, "parameter int         BYTE_CLK  = 31,", "parameter int         BYTE_CLK  = 10,"),
    ('overhead', X, "parameter int         CMD_US    = 300,", "parameter int         CMD_US    = 200,"),
    ('diagnostic time', X, "parameter int         DIAG_US   = 2500,", "parameter int         DIAG_US   = 1000,"),
    ('read ahead overruns', X, "rd_iss < rd_host + 9'd4", "rd_iss < rd_host + 9'd5"),
    ('write behind overruns', X, "16'(mdone) - (w_lba - w_base) < 16'd4", "16'(mdone) - (w_lba - w_base) < 16'd5"),
    ('format from the ring', X, "x_slot  <= w_fix ? buf_slot : ring0 + w_rel[1:0];", "x_slot  <= ring0 + w_rel[1:0];"),
    ('long sectors 512', X, "wire [9:0] sec_len = is_long ? 10'd516 : 10'd512;", "wire [9:0] sec_len = 10'd512;"),
    ('sense not cleared', X, "            S_XFER: if (!h_act && !g_run) begin\n                if (kind == K_SENSE) begin",
     "            S_XFER: if (!h_act && !g_run) begin\n                if (1'b0) begin"),
    ('sense cylinder high', X, "2'd2:    sense_b = {sn_c[9:8], sn_s};", "2'd2:    sense_b = {2'b00, sn_s};"),
    ('backend read error lost', X, "if (rd_bad[ring0 + hdone[1:0]]) begin", "if (1'b0) begin"),
    ('write fault lost', X, "if (w_bad)\n", "if (1'b0)\n"),
    ('spin-up at once', X, "if (spin_ms <= 16'd1) spun <= 1'b1;", "spun <= 1'b1;"),
    ('write long data', X, "if (!h_in && h_src == H_SEC && !h_cnt[9]) begin", "if (!h_in && h_src == H_SEC) begin"),
]


def run(i, m):
    name, f, old, new = m
    d = os.path.join(OUT, 'mut', 'm%02d' % i)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, 'rtl'))
    for fn in FILES:
        t = open(os.path.join(RTL, fn)).read()
        if fn == f:
            assert t.count(old) == 1, (name, old, t.count(old))
            t = t.replace(old, new)
        open(os.path.join(d, 'rtl', fn), 'w').write(t)
    b = subprocess.run(['verilator', '--cc', '--exe', '--build', '-O3', '-j', '2', '-Wno-fatal', '-Wno-lint',
                        '-Wno-style', '--Mdir', os.path.join(d, 'obj'), '--top-module', 'xta_card', '-GSPINUP_MS=5']
                       + [os.path.join(d, 'rtl', fn) for fn in FILES]
                       + [os.path.join(HERE, 'xta_run.cpp'), '-o', 'xta_run', '-CFLAGS', '-O2'],
                       capture_output=True, text=True)
    if b.returncode:
        return name, 'BUILD ERROR\n' + b.stderr[-2000:]
    try:
        r = subprocess.run([os.path.join(d, 'obj', 'xta_run')], capture_output=True, text=True, timeout=900)
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
