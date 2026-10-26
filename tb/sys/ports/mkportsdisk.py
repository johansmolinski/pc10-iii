#!/usr/bin/env python3
"""Build the ports test floppy of tb/sys (doc/ports.md section 7):

  mkportsdisk.py DOS.img MOUSE.COM-or-ZIP OUT.img

DOS.img: a bootable MS-DOS 3.21 360 KB disk (the Colt disk 1); the second argument:
Microsoft's MOUSE.COM, or a zip holding it (PC1020-3.ZIP: DOS/MOUSE.COM). The disk gets
MOUSE.COM, MTEST.COM (mtest.S, GNU as), COVOX.COM (covox.S: a tone and a sweep on
LPT1's data latch, for the hardware) and an AUTOEXEC.BAT that runs MOUSE and MTEST. Nothing of
DOS or of the driver is in this repository: the user supplies them.

GPL-3.0-or-later, pc10-iii.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))


def main(dos, mouse, out):
    with tempfile.TemporaryDirectory(dir=os.path.dirname(os.path.abspath(out))) as t:
        coms = []
        for src, name in (('mtest.S', 'MTEST.COM'), ('covox.S', 'COVOX.COM')):
            o, e, b = (os.path.join(t, n) for n in (src + '.o', src + '.elf', name))
            subprocess.run(['as', '--32', '-o', o, os.path.join(HERE, src)], check=True)
            subprocess.run(['ld', '-m', 'elf_i386', '-Ttext', '0x100', '-o', e, o], check=True)
            subprocess.run(['objcopy', '-O', 'binary', '-j', '.text', e, b], check=True)
            coms.append(b)
        m = os.path.join(t, 'MOUSE.COM')
        if zipfile.is_zipfile(mouse):
            with zipfile.ZipFile(mouse) as z:
                n = [x for x in z.namelist() if x.upper().endswith('MOUSE.COM')]
                if not n:
                    sys.exit('%s: no MOUSE.COM' % mouse)
                open(m, 'wb').write(z.read(n[0]))
        else:
            shutil.copy(mouse, m)
        a = os.path.join(t, 'AUTOEXEC.BAT')
        open(a, 'wb').write(b'echo off\r\nmouse\r\nmtest\r\n')
        shutil.copy(dos, out)
        os.chmod(out, 0o644)
        subprocess.run(['mcopy', '-o', '-i', out, m] + coms + [a, '::'], check=True)
    print('%s: MOUSE.COM, MTEST.COM, COVOX.COM, AUTOEXEC.BAT added' % out)


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
