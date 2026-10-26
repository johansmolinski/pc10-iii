#!/usr/bin/env python3
"""Build the speed-test boot floppy of tb/sys (doc/turbo.md section 6):

  mkspeedtest.py OUT.img    a 360 KB floppy whose boot sector (speedtest.S, GNU as)
                          counts loops between two timer ticks at each FE2010A speed
  mkspeedtest.py OUT.img fdtest.S   the floppy read test instead (fdtest.S)

GPL-3.0-or-later, pc10-iii.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def main(out, src='speedtest.S'):
    with tempfile.TemporaryDirectory(dir=os.path.dirname(os.path.abspath(out))) as t:
        o, b = os.path.join(t, 'speedtest.o'), os.path.join(t, 'speedtest.bin')
        subprocess.run(['as', '--32', '-o', o, os.path.join(HERE, src)], check=True)
        e = os.path.join(t, 'speedtest.elf')
        # (an ELF first and only .text out of it: newer binutils add note sections)
        subprocess.run(['ld', '-m', 'elf_i386', '-Ttext', '0x7c00', '-o', e, o], check=True)
        subprocess.run(['objcopy', '-O', 'binary', '-j', '.text', e, b], check=True)
        code = open(b, 'rb').read()
    if len(code) > 510:
        sys.exit('boot sector code is %d bytes (max 510)' % len(code))
    img = bytearray(368640)
    img[:len(code)] = code
    img[510:512] = b'\x55\xAA'
    open(out, 'wb').write(img)
    print('%s: 360 KB, boot sector %d bytes' % (out, len(code)))


if __name__ == '__main__':
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    main(*sys.argv[1:])
