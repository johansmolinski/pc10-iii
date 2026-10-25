#!/usr/bin/env python3
"""Build the formatter boot floppy of tb/sys (doc/xta.md section 10):

  mkfmtboot.py OUT.img    a 360 KB floppy whose boot sector (fmtboot.S, GNU as)
                          starts the WD formatter in the Commodore BIOS 4.41 at
                          F800:0005 with a minimal INT 21h

GPL-3.0-or-later, pc10-iii.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def main(out):
    with tempfile.TemporaryDirectory(dir=os.path.dirname(os.path.abspath(out))) as t:
        o, b = os.path.join(t, 'fmtboot.o'), os.path.join(t, 'fmtboot.bin')
        subprocess.run(['as', '--32', '-o', o, os.path.join(HERE, 'fmtboot.S')], check=True)
        subprocess.run(['ld', '-m', 'elf_i386', '-Ttext', '0x7c00', '--oformat', 'binary', '-o', b, o], check=True)
        code = open(b, 'rb').read()
    if len(code) > 510:
        sys.exit('boot sector code is %d bytes (max 510)' % len(code))
    img = bytearray(368640)
    img[:len(code)] = code
    img[510:512] = b'\x55\xAA'
    open(out, 'wb').write(img)
    print('%s: 360 KB, boot sector %d bytes' % (out, len(code)))


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
