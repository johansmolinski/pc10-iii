#!/usr/bin/env python3
"""Mutation check for tb/pit: each mutant breaks one behaviour of the 8253's
read/write sequencing (rtl/system/kf/KF8253/KF8253_Counter.sv); pit_run must
fail on every one. The first mutant is the KF8253 as it came (the byte
sequence restarted only when the RL bits change).

usage: mut.py [-j N]   (work dirs under $OUT/mut, default ~/pcxt-work/pit/tb)
"""
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
KF = os.path.normpath(os.path.join(HERE, '../../rtl/system/kf/KF8253'))
SRC = os.path.join(KF, 'KF8253_Counter.sv')
OUT = os.environ.get('OUT', os.path.expanduser('~/pcxt-work/pit/tb'))

MUTANTS = [
    ('original: sequence restarts only on an RL change',
     "    assign update_select_read_write = update_counter_config;\n",
     "    assign update_select_read_write = (select_read_write != internal_data_bus[5:4]) & update_counter_config;\n"),
    ('control word keeps the latch',
     "        else if (update_counter_config)\n            count_latched_flag <= 1'b0;\n", ""),
    ('latch command ignored',
     "            count_latched_flag <= 1'b1;\n        else if ((count_latched_flag == 1'b1) && (read_negedge)) begin",
     "            count_latched_flag <= 1'b0;\n        else if ((count_latched_flag == 1'b1) && (read_negedge)) begin"),
    ('latch released after the LSB',
     "                count_latched_flag <= (read_count_step == 1'b0) ? 1'b0 : 1'b1;",
     "                count_latched_flag <= 1'b0;"),
    ('read sequence does not toggle',
     "            read_count_step <= (read_count_step) ? 1'b0 : 1'b1;",
     "            read_count_step <= read_count_step;"),
    ('read sequence MSB first',
     "                `RL_SELECT_LSB_MSB  : read_count_step <= 1'b1;",
     "                `RL_SELECT_LSB_MSB  : read_count_step <= 1'b0;"),
    ('write sequence MSB first',
     "                `RL_SELECT_LSB_MSB  : write_count_step <= 1'b1;",
     "                `RL_SELECT_LSB_MSB  : write_count_step <= 1'b0;"),
    ('LSB-only read gives the MSB',
     "            read_counter_data <= count_latched[15:8];\n        else",
     "            read_counter_data <= count_latched[7:0];\n        else"),
]


def one(m):
    name, old, new = m
    src = open(SRC).read()
    if src.count(old) != 1:
        return name, 'PATTERN %d' % src.count(old)
    work = os.path.join(OUT, 'mut', re.sub(r'[^A-Za-z0-9]+', '_', name))
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    open(os.path.join(work, 'KF8253_Counter.sv'), 'w').write(src.replace(old, new))
    obj = os.path.join(work, 'obj')
    cmd = ['verilator', '--cc', '--exe', '--build', '-O3', '-j', '2', '-Wno-fatal', '-Wno-lint', '-Wno-style',
           '-I' + KF, '--top-module', 'KF8253', '--Mdir', obj,
           os.path.join(KF, 'KF8253_Control_Logic.sv'), os.path.join(work, 'KF8253_Counter.sv'),
           os.path.join(KF, 'KF8253.sv'), os.path.join(HERE, 'pit_run.cpp'), '-o', 'pit_run', '-CFLAGS', '-O2']
    if subprocess.run(cmd, capture_output=True).returncode != 0:
        return name, 'killed (does not build)'
    for t in ('seq', 'zen', 'random'):
        if subprocess.run([os.path.join(obj, 'pit_run'), t], capture_output=True).returncode != 0:
            shutil.rmtree(work, ignore_errors=True)
            return name, 'killed by ' + t
    return name, 'SURVIVED'


def main():
    j = 4
    a = sys.argv[1:]
    if a[:1] == ['-j']:
        j = int(a[1])
    with ThreadPoolExecutor(j) as ex:
        res = list(ex.map(one, MUTANTS))
    for n, r in res:
        print('%-50s %s' % (n, r))
    bad = [n for n, r in res if not r.startswith('killed')]
    print('%d of %d killed' % (len(res) - len(bad), len(res)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
