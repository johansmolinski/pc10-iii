#!/usr/bin/env python3
"""Mutation check for tb/ports: each mutant breaks one behaviour of the serial
port (uart8250.sv), the parallel port (lpt_ppc1.sv), the bus mouse
(cbm_mouse.sv) or the audio mixer (pc_audio_mix.sv); the block's testbench
must fail on every one (its tests run in order and stop at the first failure).

usage: mut.py [-j N] [-m name]   (work dirs under $OUT/mut, default ~/pcxt-work/ports/tb)
"""
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, '../../rtl/system'))
OUT = os.environ.get('OUT', os.path.expanduser('~/pcxt-work/ports/tb'))

BLOCKS = {
    'uart': ('uart8250.sv', 'uart8250', ['regs', 'intr', 'msr', 'rx', 'baud', 'format', 'random']),
    'lpt': ('lpt_ppc1.sv', 'lpt_ppc1', ['regs', 'status', 'ctrl', 'irq', 'random']),
    'mouse': ('cbm_mouse.sv', 'cbm_mouse', ['detect', 'count', 'buttons', 'timing', 'irq', 'random']),
    'mix': ('pc_audio_mix.sv', 'pc_audio_mix', ['silence', 'speaker', 'decay', 'gain', 'range']),
}

MUTANTS = [
    # ---- the 8250
    ('uart', 'a scratch register reading 00h', "default: rd = 8'hFF;            // no scratch register", "default: rd = 8'h00;"),
    ('uart', 'IER reads its high nibble as 1', "3'd1: rd = dlab ? dlm : {4'h0, ier};", "3'd1: rd = dlab ? dlm : {4'hF, ier};"),
    ('uart', 'DLAB ignored for DLL reads', "3'd0: rd = dlab ? dll : rbr;", "3'd0: rd = rbr;"),
    ('uart', 'baud divisor + 1', "bcnt + 16'd1 >= divisor;\n", "bcnt >= divisor;\n"),
    ('uart', 'baud clock 1.832 MHz', "BAUD_NUM = 32'd12672,", "BAUD_NUM = 32'd12600,"),
    ('uart', 'divisor write keeps the counter', "3'd0: if (dlab) begin dll <= wd; bcnt <= '0; end", "3'd0: if (dlab) begin dll <= wd; end"),
    ('uart', '5-bit 1.5 stop bits as 2', "nbits == 4'd5 ? 6'd24 : 6'd32;", "6'd32;"),
    ('uart', '2 stop bits as 1', "wire [5:0] stop_len = !lcr[2] ? 6'd16 :", "wire [5:0] stop_len = 1'b1 ? 6'd16 :"),
    ('uart', 'odd and even parity swapped', "par = stick ? !eps : (^d) ^ !eps;", "par = stick ? !eps : (^d) ^ eps;"),
    ('uart', 'stick parity inverted', "par = stick ? !eps : (^d) ^ !eps;", "par = stick ? eps : (^d) ^ !eps;"),
    ('uart', 'no word mask', "tsr <= wmask(thr);", "tsr <= thr;"),
    ('uart', 'MSB first', "tx_line <= tsr[0]; end", "tx_line <= tsr[7]; end"),
    ('uart', 'BREAK ignored', "assign sout   = loop || (tx_line && !lcr[6]);", "assign sout   = loop || tx_line;"),
    ('uart', 'SOUT not high in loopback', "assign sout   = loop || (tx_line && !lcr[6]);", "assign sout   = tx_line && !lcr[6];"),
    ('uart', 'RTS active in loopback', "assign rts_n  = loop || !mcr[1];", "assign rts_n  = !mcr[1];"),
    ('uart', 'loopback RTS -> DSR', "{mcr[3], mcr[2], mcr[0], mcr[1]}", "{mcr[3], mcr[2], mcr[1], mcr[0]}"),
    ('uart', 'loopback ignores the TSR', "wire         rx_in = loop ? tx_line : s_sin[1];", "wire         rx_in = s_sin[1];"),
    ('uart', 'no false-start check', "if (rx_in) rs <= R_IDLE;                 // a false start", "if (1'b0) rs <= R_IDLE;"),
    ('uart', 'start checked at a quarter bit', "                    if (rph == 4'd7) begin\n                        if (rx_in)", "                    if (rph == 4'd3) begin\n                        if (rx_in)"),
    ('uart', 'no overrun', "oe  <= (oe && !(rd_end && ra == 3'd5)) || (dr && !(rd_end && ra == 3'd0 && !dlab));", "oe  <= oe && !(rd_end && ra == 3'd5);"),
    ('uart', 'overrun keeps the old character', "                        rbr <= rsr;\n", "                        if (!dr) rbr <= rsr;\n"),
    ('uart', 'no parity error', "if (pen && rpar != par(rsr)) pe <= 1'b1;", "if (1'b0) pe <= 1'b1;"),
    ('uart', 'no framing error', "if (!rx_in) fe <= 1'b1;", "if (1'b0) fe <= 1'b1;"),
    ('uart', 'no break', "if (!rx_in && rsr == 8'h00 && !(pen && rpar)) bi <= 1'b1;", "if (1'b0) bi <= 1'b1;"),
    ('uart', 'no wait for mark after a break', "rs <= rx_in ? R_IDLE : R_MARK;", "rs <= R_IDLE;"),
    ('uart', 'LSR read keeps the errors', "3'd5: begin oe <= 1'b0; pe <= 1'b0; fe <= 1'b0; bi <= 1'b0; end", "3'd5: ;"),
    ('uart', 'RBR read keeps DR', "3'd0: if (!dlab) dr <= 1'b0;", "3'd0: ;"),
    ('uart', 'IIR read keeps THRE', "3'd2: if (iir == 4'b0010) thre_int <= 1'b0;", "3'd2: ;"),
    ('uart', 'IIR read always clears THRE', "3'd2: if (iir == 4'b0010) thre_int <= 1'b0;", "3'd2: thre_int <= 1'b0;"),
    ('uart', 'THRE only when ETBEI is enabled (16550)', "if (wd[1] && thre) thre_int <= 1'b1;", "if (wd[1] && !ier[1] && thre) thre_int <= 1'b1;"),
    ('uart', 'THR write keeps the THRE interrupt', "thr <= wd; thre <= 1'b0; temt <= 1'b0; thre_int <= 1'b0;", "thr <= wd; thre <= 1'b0; temt <= 1'b0;"),
    ('uart', 'RDA before RLS', "wire [3:0] iir = src_rls ? 4'b0110 : src_rda ? 4'b0100 :", "wire [3:0] iir = src_rda ? 4'b0100 : src_rls ? 4'b0110 :"),
    ('uart', 'MS before THRE', "src_thre ? 4'b0010 :\n                 src_ms ? 4'b0000 : 4'b0001;", "src_ms ? 4'b0000 :\n                 src_thre ? 4'b0010 : 4'b0001;"),
    ('uart', 'no 8250 pulse (16450)', "assign intr   = pending && pulse == '0;", "assign intr   = pending;"),
    ('uart', 'TERI on the leading edge', "if (mst_q[2] && !mst[2]) dmsr[2] <= 1'b1;", "if (!mst_q[2] && mst[2]) dmsr[2] <= 1'b1;"),
    ('uart', 'MSR read keeps the deltas', "if (rd_end && ra == 3'd6) dmsr <= 4'h0;", ""),
    ('uart', 'IRQ without OUT2', "assign irq4   = intr && !out2_n && com == 2'b10;", "assign irq4   = intr && com == 2'b10;"),
    ('uart', 'COM bases swapped', "wire [9:0] base = com == 2'b10 ? 10'h3F8 : 10'h2F8;", "wire [9:0] base = com == 2'b01 ? 10'h3F8 : 10'h2F8;"),
    ('uart', 'com 11 answers', "wire       on   = com == 2'b01 || com == 2'b10;", "wire       on   = com != 2'b00;"),
    ('uart', 'AEN ignored', "wire sel    = on && !isa_aen && isa_addr", "wire sel    = on && isa_addr"),
    ('uart', 'read effects at the strobe start', "wire rd_end = sel && !isa_ior_n && !(sel_nx && !isa_ior_n_next);", "wire rd_end = sel && !isa_ior_n;"),
    ('uart', 'reset keeps IER', "        ier <= 4'h0;  lcr <= 8'h00;  mcr <= 5'h00;\n", "        lcr <= 8'h00;  mcr <= 5'h00;\n"),
    ('uart', 'TEMT with THR full', "if (thre && !wthr) temt <= 1'b1;", "temt <= 1'b1;"),
    ('uart', 'no DSR delta', "if (mst[1] != mst_q[1]) dmsr[1] <= 1'b1;", ""),
    # ---- the parallel port
    ('lpt', 'BUSY not inverted', "rd = {!busy, ack_n,", "rd = {busy, ack_n,"),
    ('lpt', 'status bits 2-0 read 0', "err_n, 3'b111};", "err_n, 3'b000};"),
    ('lpt', 'control bits 7-5 read 0', "default: rd = {3'b111, ctrl};", "default: rd = {3'b000, ctrl};"),
    ('lpt', 'STROBE not inverted', "assign strobe_n = !ctrl[0];", "assign strobe_n = ctrl[0];"),
    ('lpt', '/INIT inverted', "assign init_n   = ctrl[2];", "assign init_n   = !ctrl[2];"),
    ('lpt', 'SLCT IN not inverted', "assign selin_n  = !ctrl[3];", "assign selin_n  = ctrl[3];"),
    ('lpt', 'IRQ7 from ACK inverted', "ctrl[4] && ack_n;", "ctrl[4] && !ack_n;"),
    ('lpt', 'IRQ7 without IRQ EN', "assign irq7     = lpt != 2'b00 && ctrl[4] && ack_n;", "assign irq7     = lpt != 2'b00 && ack_n;"),
    ('lpt', 'reset clears the data latch', "    if (wr_end && isa_addr[1:0] == 2'd0) dlatch <= isa_dout;", "    if (reset) dlatch <= 8'h00; else if (wr_end && isa_addr[1:0] == 2'd0) dlatch <= isa_dout;"),
    ('lpt', 'reset keeps the control register', "if (reset) ctrl <= 5'h00;", "if (1'b0) ctrl <= 5'h00;"),
    ('lpt', 'base + 3 answers', " && isa_addr[1:0] != 2'd3;", ";"),
    ('lpt', '378h and 278h swapped', "lpt == 2'b10 ? 10'h378 : 10'h278;", "lpt == 2'b10 ? 10'h278 : 10'h378;"),
    ('lpt', 'lpt 00 answers', "wire sel    = lpt != 2'b00 && !isa_aen", "wire sel    = !isa_aen"),
    ('lpt', 'AEN ignored', "wire sel    = lpt != 2'b00 && !isa_aen && ", "wire sel    = lpt != 2'b00 && "),
    ('lpt', 'control 4 bits', "ctrl <= isa_dout[4:0];", "ctrl <= {1'b0, isa_dout[3:0]};"),
    # ---- the bus mouse
    ('mouse', 'X counts the wrong way', "wire [1:0] sx = step(sxp[2], sxp[1], sxq[2], sxq[1]);", "wire [1:0] sx = step(sxq[2], sxq[1], sxp[2], sxp[1]);"),
    ('mouse', 'Y from the X lines', "wire [1:0] sy = step(syp[2], syp[1], syq[2], syq[1]);", "wire [1:0] sy = step(sxp[2], sxp[1], syq[2], syq[1]);"),
    ('mouse', 'one synchronizer stage', "wire [1:0] sx = step(sxp[2], sxp[1], sxq[2], sxq[1]);", "wire [1:0] sx = step(sxp[1], sxp[0], sxq[1], sxq[0]);"),
    ('mouse', 'counting while held', "        if (!ctrl[3]) begin\n", "        if (1'b1) begin\n"),
    ('mouse', 'no clear at the release', "if (ctrl[3] && !isa_dout[7]) begin cx <= 8'h00; cy <= 8'h00; end", ""),
    ('mouse', 'clear at any write without bit 7', "if (ctrl[3] && !isa_dout[7]) begin", "if (!isa_dout[7]) begin"),
    ('mouse', 'nibbles swapped', "ctrl[1] ? cnt[7:4] : cnt[3:0]", "ctrl[1] ? cnt[3:0] : cnt[7:4]"),
    ('mouse', 'counters swapped', "wire [7:0] cnt = ctrl[2] ? cy : cx;", "wire [7:0] cnt = ctrl[2] ? cx : cy;"),
    ('mouse', 'left and right buttons swapped', "rd = {sl[1], sm[1], sr[1], 1'b0,", "rd = {sr[1], sm[1], sl[1], 1'b0,"),
    ('mouse', 'status bit 3 not inverted', "default: rd = {4'h0, !irq2, 3'b111};", "default: rd = {4'h0, irq2, 3'b111};"),
    ('mouse', 'IRQ ignores 23Eh bit 4', "wire irq_on = enable && !ctrl[0];", "wire irq_on = enable;"),
    ('mouse', 'IRQ ignores 230h bit 4', "wire irq_on = enable && !ctrl[0];", "wire irq_on = !ctrl[0];"),
    ('mouse', 'square wave 65.5 ms', "parameter int          SQ_BITS = 19", "parameter int          SQ_BITS = 20"),
    ('mouse', 'square wave from 14.3 MHz', "OSC_NUM = 32'd176,", "OSC_NUM = 32'd158,"),
    ('mouse', 'answers without 230h bit 4', "wire sel    = enable && !isa_aen &&", "wire sel    = !isa_aen &&"),
    ('mouse', '23Fh answers', "isa_addr[9:0] <= 10'h23E;", "isa_addr[9:0] <= 10'h23F;"),
    ('mouse', '23Dh 4 bits', "dummy <= isa_dout;", "dummy <= {4'h0, isa_dout[3:0]};"),
    ('mouse', 'reset keeps 23Eh', "ctrl <= 4'h0;  dummy <= 8'h00;", "dummy <= 8'h00;"),
    # ---- the mixer
    ('mix', 'no DC blocker', "y  <= y + ((YW'(x) - YW'(x1)) <<< F) - dec;", "y  <= YW'(x) <<< F;"),
    ('mix', 'the decay stops short of 0', "(dk0 == 0 ? 1 : dk0)", "dk0"),
    ('mix', 'pole 1 - 2^-8', "parameter int K        = 10,", "parameter int K        = 8,"),
    ('mix', 'Covox x64', "* 14'sd32;", "* 14'sd64;"),
    ('mix', 'speaker 1000h', "(speaker ? 16'sh2000 : 16'sh0000)", "(speaker ? 16'sh1000 : 16'sh0000)"),
    ('mix', 'the DAC taken as signed', "$signed({1'b0, dac} - 9'sd128)", "$signed({dac[7], dac})"),
    ('mix', 'x1 never updated', "        x1 <= x;\n", ""),
    ('mix', 'a click at power-up', "x1 = -14'sd4096;", "x1 = '0;"),
    ('mix', 'the decay with the wrong sign', "wire signed [YW - 1:0] dec = y < 0 ? -dk : dk;", "wire signed [YW - 1:0] dec = dk;"),
]


def build(work, block, src):
    f, top, _ = BLOCKS[block]
    obj = os.path.join(work, 'obj')
    cmd = ['verilator', '--cc', '--exe', '--build', '-O2', '-j', '2', '-Wno-fatal', '-Wno-lint', '-Wno-style',
           '--top-module', top, '--Mdir', obj, src, os.path.join(HERE, block + '_run.cpp'),
           '-o', 'run', '-CFLAGS', '-O2', '-CFLAGS', '-I' + HERE]
    p = subprocess.run(cmd, capture_output=True, text=True)
    return None if p.returncode != 0 else os.path.join(obj, 'run')


def one(m):
    block, name, old, new = m
    f, top, tests = BLOCKS[block]
    src = open(os.path.join(RTL, f)).read()
    if src.count(old) != 1:
        return block, name, 'PATTERN %d' % src.count(old)
    work = os.path.join(OUT, 'mut', block + '_' + re.sub(r'[^A-Za-z0-9]+', '_', name))
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    ms = os.path.join(work, f)
    open(ms, 'w').write(src.replace(old, new))
    b = build(work, block, ms)
    if b is None:
        return block, name, 'killed (does not build)'
    for t in tests:
        p = subprocess.run([b, t], capture_output=True, text=True)
        if p.returncode != 0:
            shutil.rmtree(work, ignore_errors=True)
            return block, name, 'killed by %s' % t
    return block, name, 'SURVIVED'


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
    muts = [m for m in MUTANTS if sel is None or sel in m[0] + ' ' + m[1]]
    os.makedirs(os.path.join(OUT, 'mut'), exist_ok=True)
    survived = 0
    with ThreadPoolExecutor(j) as ex:
        for block, name, res in ex.map(one, muts):
            print('%-6s %-44s %s' % (block, name, res), flush=True)
            survived += not res.startswith('killed')
    print('%d of %d mutants killed' % (len(muts) - survived, len(muts)))
    return 1 if survived else 0


sys.exit(main())
