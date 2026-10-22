#!/usr/bin/env python3
"""Build (or check) the hard disk test image of tb/sys (doc/hdc.md section 7).

  mkhdimg.py build OUT.img      20 MB, ST-225 geometry 615/4/17: the MBR test
                                program (mbr.S, assembled with GNU as), a
                                FAT16 partition from cylinder 1 (mtools) and
                                the test data in the rest of cylinder 0
  mkhdimg.py check ORIG.img NEW.img
                                after a tb/sys run: the sectors the MBR wrote
                                hold the expected data and nothing else changed

Cylinder 0 (outside the partition):
  C0 H0 S1  LBA 0       the MBR
  C0 H0 S2  LBA 1       a text, printed by the MBR
  C0 H1 S10 LBA 26-45   20 sectors of a pattern, read and summed by the MBR
  C0 H2 S16 LBA 49-51   written by the MBR (3 sectors, pattern 5Ah + 3i)
  C0 H3 S9  LBA 60      written by the MBR (a copy of itself)

GPL-3.0-or-later, pc10-iii.
"""
import os
import subprocess
import sys
import tempfile

C, H, S = 615, 4, 17
SECTORS = C * H * S
PART_LBA = H * S                       # cylinder 1
HERE = os.path.dirname(os.path.abspath(__file__))


def lba(c, h, s):
    return (c * H + h) * S + s - 1


def chs_bytes(c, h, s):
    return bytes([h, s | ((c >> 8) & 3) << 6, c & 0xFF])


def read_pattern():
    d = bytearray()
    for l in range(lba(0, 1, 10), lba(0, 1, 10) + 20):
        d += bytes(((l * 7 + i * 13 + (i >> 8)) & 0xFF) for i in range(512))
    return d


def write_pattern():
    return bytes(((0x5A + 3 * i) & 0xFF) for i in range(3 * 512))


def build(out):
    rp = read_pattern()
    expsum = sum(rp[i] | (rp[i + 1] << 8) for i in range(0, len(rp), 2)) & 0xFFFF
    with tempfile.TemporaryDirectory(dir=os.path.dirname(os.path.abspath(out))) as t:
        o, b = os.path.join(t, 'mbr.o'), os.path.join(t, 'mbr.bin')
        subprocess.run(['as', '--32', '--defsym', 'EXPSUM=%d' % expsum, '-o', o, os.path.join(HERE, 'mbr.S')],
                       check=True)
        subprocess.run(['ld', '-m', 'elf_i386', '-Ttext', '0x7c00', '--oformat', 'binary', '-o', b, o], check=True)
        code = open(b, 'rb').read()
    if len(code) > 446:
        sys.exit('MBR code is %d bytes (max 446)' % len(code))
    img = bytearray(SECTORS * 512)
    mbr = bytearray(512)
    mbr[:len(code)] = code
    # one FAT16 partition (< 32 MB: type 04h), active, cylinder 1 to the end
    pe = bytes([0x80]) + chs_bytes(1, 0, 1) + bytes([0x04]) + chs_bytes(C - 1, H - 1, S) + \
        PART_LBA.to_bytes(4, 'little') + (SECTORS - PART_LBA).to_bytes(4, 'little')
    mbr[446:462] = pe
    mbr[510:512] = b'\x55\xAA'
    img[0:512] = mbr
    text = b'PC10-III test sector C0 H0 S2\0'
    img[512:512 + len(text)] = text
    a = lba(0, 1, 10) * 512
    img[a:a + len(rp)] = rp
    open(out, 'wb').write(img)
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
    part = '%s@@%d' % (out, PART_LBA * 512)
    subprocess.run(['mformat', '-i', part, '-T', str(SECTORS - PART_LBA), '-h', str(H), '-s', str(S),
                    '-H', str(PART_LBA), '-v', 'PC10TEST', '::'], check=True, env=env)
    with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as f:
        f.write('PC10-III XTIDE test disk (tb/sys/hd/mkhdimg.py)\r\n')
        rd = f.name
    subprocess.run(['mcopy', '-i', part, rd, '::README.TXT'], check=True, env=env)
    os.unlink(rd)
    print('%s: %d sectors, CHS %d/%d/%d, MBR %d bytes, expected sum %04X' % (out, SECTORS, C, H, S, len(code),
                                                                          expsum))


def check(orig, new):
    a = open(orig, 'rb').read()
    b = open(new, 'rb').read()
    ok = True
    if len(a) != len(b):
        print('FAIL: sizes differ')
        return False
    w0 = lba(0, 2, 16)
    exp = bytearray(a)
    exp[w0 * 512:(w0 + 3) * 512] = write_pattern()
    t = lba(0, 3, 9)
    exp[t * 512:(t + 1) * 512] = a[0:512]
    for l in range(len(a) // 512):
        if b[l * 512:(l + 1) * 512] != exp[l * 512:(l + 1) * 512]:
            what = 'written by the MBR' if l in (w0, w0 + 1, w0 + 2, t) else 'not written'
            print('FAIL: LBA %d (%s) differs from the expected data' % (l, what))
            ok = False
    changed = [l for l in range(len(a) // 512) if a[l * 512:(l + 1) * 512] != b[l * 512:(l + 1) * 512]]
    print('changed sectors: %s' % changed)
    print('check %s' % ('OK: LBA 49-51 hold the pattern, LBA 60 the MBR, nothing else changed' if ok else 'FAILED'))
    return ok


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'build':
        build(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == 'check':
        sys.exit(0 if check(sys.argv[2], sys.argv[3]) else 1)
    else:
        sys.exit(__doc__)
