#!/usr/bin/env python3
"""Configure an XTIDE Universal BIOS image for the PC10-III's XTIDE card
(rtl/hdc, doc/hdc.md), the way XTIDECFG.COM does it on a PC: set the first
controller's device type and port, then pad the image to its ROM size and
fix the checksum byte.

usage: xubcfg.py IN.bin OUT.bin [--device D] [--port P] [--no-slave] [--info]

  --device  xtcf-pio8      XT-CF, 8-bit PIO (IN AL,DX)                  type 7
            xtcf-biu       XT-CF, 8-bit PIO with BIU offload (IN AX,DX) type 8
            lotech         Lo-tech 8-bit IDE, 16-bit PIO (IN AX,DX)     type 9 (default)
            rev1           XTIDE rev 1                                  type 4
            rev2           XTIDE rev 2 / rev 1 with A0-A3 swapped       type 5
  --port    base port (default 300h)
  --no-slave  do not detect a slave drive (saves XUB's 0.5 s timeout)

Card variant (pc_system hdc_variant) for each device: xtcf-* and lotech = 0,
rev1 = 1, rev2 = 2.

The offsets are those of XUB r6xx (ROMVARS in Inc/RomVars.inc: ideVars0 at
4Eh, 18 bytes per controller); the script checks the "XUB" signature and that
the first controller looks like an XT build's before it changes anything.

GPL-3.0-or-later, pc10-iii. (The XTIDE Universal BIOS itself is
GPL-2.0-or-later, https://www.xtideuniversalbios.org/.)
"""
import argparse
import sys

DEVICES = {                 # name: (XUB device byte, card variant)
    'xtcf-pio8': (0x0E, 0),
    'xtcf-biu': (0x10, 0),
    'lotech': (0x12, 0),
    'rev1': (0x08, 1),
    'rev2': (0x0A, 2),
}
NAMES = {v[0]: k for k, v in DEVICES.items()}

ROMVARS_FLAGS = 0x40
IDEVARS0 = 0x4E             # ROMVARS.ideVars0
IDE_BASE, IDE_CTRL, IDE_DEV = 0, 2, 4
DRVPARAMS_SLAVE = 12        # IDEVARS.drvParamsSlave (DRVPARAMS.wFlags first)
FLG_DO_NOT_DETECT = 0x80


def port(s):
    s = s.lower()
    return int(s[:-1], 16) if s.endswith('h') else int(s, 0)


def info(d):
    w = lambda o: d[o] | (d[o + 1] << 8)
    title = bytes(d[12:44]).split(b'\0')[0].decode('ascii', 'replace')
    ver = bytes(d[44:62]).split(b'\0')[0].decode('ascii', 'replace')
    b = IDEVARS0
    dev = d[b + IDE_DEV]
    print('%s %s, ROM size %d KB, flags %04X' % (title, ver, d[2] // 2, w(ROMVARS_FLAGS)))
    print('controller 0: port %03Xh, control %03Xh, device %02Xh (%s), slave %s' % (
        w(b + IDE_BASE), w(b + IDE_CTRL), dev, NAMES.get(dev, '?'),
        'not detected' if d[b + DRVPARAMS_SLAVE] & FLG_DO_NOT_DETECT else 'detected'))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('inp')
    ap.add_argument('out', nargs='?')
    ap.add_argument('--device', choices=DEVICES, default='lotech')
    ap.add_argument('--port', type=port, default=0x300)
    ap.add_argument('--no-slave', action='store_true')
    ap.add_argument('--info', action='store_true')
    a = ap.parse_args()

    d = bytearray(open(a.inp, 'rb').read())
    if d[0:2] != b'\x55\xAA' or d[6:9] != b'XUB':
        sys.exit('%s: not an XTIDE Universal BIOS image' % a.inp)
    if a.info or not a.out:
        info(d)
        return
    size = d[2] * 512
    if size % 2048 or len(d) > size:
        sys.exit('%s: ROM size %d does not fit the image (%d bytes)' % (a.inp, size, len(d)))
    b = IDEVARS0
    if d[b + IDE_DEV] not in NAMES and d[b + IDE_DEV] != 0x00:
        sys.exit('%s: unexpected device byte %02Xh at %Xh (not an r6xx XT build?)' % (a.inp, d[b + IDE_DEV],
                                                                                     b + IDE_DEV))
    dev, variant = DEVICES[a.device]
    d[b + IDE_BASE:b + IDE_BASE + 2] = a.port.to_bytes(2, 'little')
    d[b + IDE_CTRL:b + IDE_CTRL + 2] = (a.port + 8).to_bytes(2, 'little')    # XTIDE rev 1/2 control block
    d[b + IDE_DEV] = dev
    if a.no_slave:
        d[b + DRVPARAMS_SLAVE] |= FLG_DO_NOT_DETECT
    else:
        d[b + DRVPARAMS_SLAVE] &= ~FLG_DO_NOT_DETECT & 0xFF
    # pad with zeros, the last byte makes the sum 0 (XUB's Tools/checksum.pl)
    d += bytes(size - len(d))
    d[-1] = 0
    d[-1] = (-sum(d)) & 0xFF
    assert sum(d) & 0xFF == 0
    open(a.out, 'wb').write(d)
    info(d)
    print('written %s: %d bytes; card variant %d (hdc_variant)' % (a.out, len(d), variant))


if __name__ == '__main__':
    main()
