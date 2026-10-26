#!/usr/bin/env python3
"""INIT_xx strings of firmware block RAMs, for patch_firmware.tcl.

Usage: patch_firmware.py <ref.hex> <new.hex> <shapes> <out>
shapes: one line per cell: name data_bits slice_begin slice_end addr_begin addr_end bits
out:    one line per cell and image: name ref|new INIT_00 ... (64 hex digits each)
"""
import sys

def words(f):
    return [int(l, 16) for l in open(f) if l.strip()]

ref, new = words(sys.argv[1]), words(sys.argv[2])
with open(sys.argv[3]) as f, open(sys.argv[4], "w") as out:
    for line in f:
        name, wd, sb, se, ab, ae, nbits = line.split()
        wd, sb, se, ab, ae, nbits = map(int, (wd, sb, se, ab, ae, nbits))
        n = se - sb + 1
        for tag, w in (("ref", ref), ("new", new)):
            v = 0                                  # the whole bit stream as one integer
            for a in range(ab, ae + 1):
                x = (w[a] if a < len(w) else 0) >> sb & ((1 << n) - 1)
                if x:
                    v |= x << ((a - ab) * wd)
            inits = ["%064X" % (v >> (256 * k) & ((1 << 256) - 1)) for k in range(nbits // 256)]
            out.write("%s %s %s\n" % (name, tag, " ".join(inits)))
