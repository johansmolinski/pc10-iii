#!/usr/bin/env python3
"""Mutation check for tb/wait: each mutant breaks one property of the
wait-state generator (rtl/system/xt_wait.sv); the bench (three seeds) must fail
on every one.

usage: mut.py [-j N] [-m name]   (work dirs under $OUT/mut, default ~/pcxt-work/turbo/wait)
"""
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, '../../rtl/system/xt_wait.sv'))
OUT = os.environ.get('OUT', os.path.expanduser('~/pcxt-work/turbo/wait'))

MUTANTS = [
    ('I/O 4.77: 0', "            2'd0:    ws_n = 3'd1;", "            2'd0:    ws_n = 3'd0;"),
    ('I/O 4.77: 2', "            2'd0:    ws_n = 3'd1;", "            2'd0:    ws_n = 3'd2;"),
    ('I/O 7.16: 3', "            2'd1:    ws_n = 3'd4;", "            2'd1:    ws_n = 3'd3;"),
    ('I/O 9.54: bit 6 ignored', "default: ws_n = cfg[6] ? 3'd4 : 3'd6;", "default: ws_n = 3'd6;"),
    ('I/O 9.54: 5', "default: ws_n = cfg[6] ? 3'd4 : 3'd6;", "default: ws_n = cfg[6] ? 3'd4 : 3'd5;"),
    ('memory 4.77: 1', "            2'd0:    ws_n = 3'd0;", "            2'd0:    ws_n = 3'd1;"),
    ('memory 7.16: 1', "            2'd1:    ws_n = 3'd2;", "            2'd1:    ws_n = 3'd1;"),
    ('memory 9.54: bit 6 ignored', "default: ws_n = cfg[6] ? 3'd2 : 3'd4;", "default: ws_n = 3'd4;"),
    ('memory 9.54: 3', "default: ws_n = cfg[6] ? 3'd2 : 3'd4;", "default: ws_n = cfg[6] ? 3'd2 : 3'd3;"),
    ('memory: on-board RAM waits too', "else if (mem_cycle && !onboard && !cfg[5])", "else if (mem_cycle && !cfg[5])"),
    ('memory: fast bit ignored', "else if (mem_cycle && !onboard && !cfg[5])", "else if (mem_cycle && !onboard)"),
    ('memory: code fetches without waits', "wire mem_cycle = cpu_bus_type == ST_CODE || ", "wire mem_cycle = "),
    ('memory: writes without waits', " || cpu_bus_type == ST_MEMW;\nalways_comb", ";\nalways_comb"),
    ('INTA gets I/O waits', "wire io_cycle  = cpu_bus_type == ST_IOR || cpu_bus_type == ST_IOW;",
     "wire io_cycle  = cpu_bus_type == ST_IOR || cpu_bus_type == ST_IOW || cpu_bus_type == 3'd0;"),
    ('DMA-held states count', "wire [2:0] ws_dec = dma_ok && ws != 3'd0 ? ws - 3'd1 : ws;",
     "wire [2:0] ws_dec = ws != 3'd0 ? ws - 3'd1 : ws;"),
    ('wait states never count down', "wire [2:0] ws_dec = dma_ok && ws != 3'd0 ? ws - 3'd1 : ws;",
     "wire [2:0] ws_dec = ws;"),
    ('one state too many', "!(in_t3tw && ws_dec != 3'd0)", "!(in_t3tw && ws != 3'd0)"),
    ('T2 term missing', "assign cpu_ready = rdy_sync && !(cpu_bus_t == T2 && ws_n != 3'd0) &&",
     "assign cpu_ready = rdy_sync &&"),
    ('RDY ignored during board waits', "assign cpu_ready = rdy_sync && ", "assign cpu_ready = "),
    ('dma_ok from the old sample', "        dma_ok <= dma_rdy_sync;\n", "        dma_ok <= dma_ok & dma_rdy_sync;\n"),
]


def one(m):
    name, old, new = m
    src = open(SRC).read()
    if src.count(old) != 1:
        return name, 'PATTERN %d' % src.count(old)
    work = os.path.join(OUT, 'mut', re.sub(r'[^A-Za-z0-9]+', '_', name))
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    open(os.path.join(work, 'xt_wait.sv'), 'w').write(src.replace(old, new))
    obj = os.path.join(work, 'obj')
    cmd = ['verilator', '--cc', '--exe', '--build', '-O3', '-j', '2', '-Wno-fatal', '-Wno-lint', '-Wno-style',
           '--top-module', 'tb_wait', '--Mdir', obj, os.path.join(work, 'xt_wait.sv'),
           os.path.join(HERE, 'tb_wait.sv'), os.path.join(HERE, 'wait_run.cpp'), '-o', 'wait_run', '-CFLAGS', '-O2']
    if subprocess.run(cmd, capture_output=True, text=True).returncode != 0:
        return name, 'killed (does not build)'
    for seed in (1, 2, 3):
        p = subprocess.run([os.path.join(obj, 'wait_run'), '400000', str(seed)], capture_output=True, text=True)
        if p.returncode != 0:
            shutil.rmtree(work, ignore_errors=True)
            return name, 'killed (seed %d)' % seed
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
