#!/usr/bin/env python3
"""Build the PC20-III hard disk DMA test ROM of tb/sys (doc/xta.md section 10):

  mkxtadma.py OUT.bin     8 KB (F000:E000-FFFF), xtadma.S assembled with GNU as;
                          run: sys_run -b OUT.bin -d 5D -jmp208 B -xl -s 0.03
                          (make FE=1 PVC4=1 XTA=1): POST codes 00 08 / 00 08 / 00

GPL-3.0-or-later, pc10-iii.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def main(out):
    with tempfile.TemporaryDirectory(dir=os.path.dirname(os.path.abspath(out))) as t:
        o = os.path.join(t, 'xtadma.o')
        subprocess.run(['as', '--32', '-o', o, os.path.join(HERE, 'xtadma.S')], check=True)
        subprocess.run(['ld', '-m', 'elf_i386', '-Ttext', '0xe000', '--oformat', 'binary', '-o', out, o], check=True)
    n = os.path.getsize(out)
    if n != 8192:
        sys.exit('%s: %d bytes, expected 8192' % (out, n))
    print('%s: 8 KB test ROM' % out)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
