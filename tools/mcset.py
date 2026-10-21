#!/usr/bin/env python3
"""Change microcode words in the MCL86 listing in place.

  mcset.py microcode.txt ADDR=HHHHLLLL [ADDR=HHHHLLLL ...]

ADDR and the word are hex. The listing keeps its comments; only the two data
lines after "p 00 00000 00001 ADDR" change. An address the listing does not
have yet is appended at its end. Prints old -> new for each word.
"""
import sys


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path = sys.argv[1]
    want = {}
    for arg in sys.argv[2:]:
        a, w = arg.split('=')
        want[int(a, 16)] = int(w, 16)
    lines = open(path).read().split('\n')
    i = 0
    done = set()
    while i < len(lines):
        t = lines[i].split()
        if len(t) == 5 and t[0] == 'p' and t[1] == '00' and t[3] == '00001':
            addr = int(t[4], 16)
            if addr in want:
                hi = lines[i + 1].split()
                lo = lines[i + 2].split()
                old = (int(hi[4], 16) << 16) | int(lo[4], 16)
                new = want[addr]
                hi[4] = f'{new >> 16:04X}'
                lo[4] = f'{new & 0xFFFF:04X}'
                lines[i + 1] = ' '.join(hi)
                lines[i + 2] = ' '.join(lo)
                print(f'{addr:04X}: {old:08X} -> {new:08X}')
                done.add(addr)
                i += 3
                continue
        i += 1
    for addr in sorted(set(want) - done):
        new = want[addr]
        lines.extend(['#', f'p 00 00000 00001 {addr:04X}',
                      f'p 01 00000 00001 {new >> 16:04X}',
                      f'p 01 00000 00001 {new & 0xFFFF:04X}'])
        print(f'{addr:04X}: (new) -> {new:08X}')
    open(path, 'w').write('\n'.join(lines))


if __name__ == '__main__':
    main()
