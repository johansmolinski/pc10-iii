#!/usr/bin/env python3
"""mkblankhd.py - make an empty hard disk image for drive C: of the PC10-III
core (the PC20-III's 20 MB drive, a WD93024-X: 615 cylinders, 4 heads,
17 sectors of 512 bytes = 41,820 sectors = 21,411,840 bytes).

  mkblankhd.py [--force] FILE

The image is all zeros; the core takes a new image as a low-level formatted
drive, so FDISK and FORMAT C: /S of MS-DOS make it bootable (README.md, "The
hard disk C:"). The core refuses any other size. Write the image on the
computer and copy it to the SD card, or write it on the card directly; either
way the file must not be too fragmented (at most 511 pieces), which a
freshly written file on a FAT32 card never is.

The tool contains nothing but the size: no partition table, no boot sector,
no DOS.
"""

import argparse
import os
import sys

CYLINDERS, HEADS, SECTORS = 615, 4, 17
SIZE = CYLINDERS * HEADS * SECTORS * 512        # 21,411,840


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("file", help="the image to write, e.g. hd20.img")
    ap.add_argument("--force", action="store_true", help="overwrite an existing file")
    a = ap.parse_args()
    if os.path.exists(a.file) and not a.force:
        sys.exit("%s exists: not overwritten (--force overwrites it, and everything on it)" % a.file)
    chunk = bytes(1 << 20)
    left = SIZE
    with open(a.file, "wb") as f:
        while left:
            n = min(left, len(chunk))
            f.write(chunk[:n])
            left -= n
    if os.path.getsize(a.file) != SIZE:
        sys.exit("%s: written %d bytes, expected %d" % (a.file, os.path.getsize(a.file), SIZE))
    print("%s: %d bytes (%d x %d x %d sectors), empty" % (a.file, SIZE, CYLINDERS, HEADS, SECTORS))


if __name__ == "__main__":
    main()
