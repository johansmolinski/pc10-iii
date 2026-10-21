#!/usr/bin/env python3
"""Assemble the MCL86 microcode listing into a 4K x 32 ROM image.

The listing (rtl/cpu/mcl86/microcode.txt) is MicroCore Labs' programming
script: "p 00 00000 00001 AAAA" sets the word address, the next two
"p 01 00000 00001 HHHH" lines give the high and the low half of that word.
Lines with 00010 in the fourth field go to the tool's debug and trigger
registers, not to the ROM. Everything else is comment.

  mcasm.py microcode.txt microcode.hex         write a $readmemh image
  mcasm.py microcode.txt --check original.coe  compare with a Xilinx .coe
"""
import sys


def assemble(path):
    words = [0] * 4096
    addr = None
    halves = []
    for line in open(path):
        t = line.split()
        if len(t) != 5 or t[0] != 'p' or t[3] != '00001':
            continue
        if t[1] == '00':
            addr = int(t[4], 16)
            halves = []
        elif t[1] == '01':
            halves.append(int(t[4], 16))
            if len(halves) == 2:
                words[addr] = (halves[0] << 16) | halves[1]
    return words


def read_coe(path):
    text = open(path).read()
    if 'memory_initialization_vector' in text:
        text = text.split('memory_initialization_vector', 1)[1].split('=', 1)[1]
    vals = [v for v in text.replace(',', ' ').replace(';', ' ').split() if v]
    return [int(v, 16) for v in vals][:4096]


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    words = assemble(sys.argv[1])
    if sys.argv[2] == '--check':
        coe = read_coe(sys.argv[3])
        diffs = [i for i in range(4096) if coe[i] != words[i]]
        for i in diffs[:20]:
            print(f'{i:03X}: coe {coe[i]:08X} listing {words[i]:08X}')
        print(f'{len(diffs)} differences')
        sys.exit(1 if diffs else 0)
    with open(sys.argv[2], 'w') as f:
        for w in words:
            f.write(f'{w:08X}\n')


if __name__ == '__main__':
    main()
