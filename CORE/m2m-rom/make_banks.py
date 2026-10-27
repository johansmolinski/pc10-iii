#!/usr/bin/env python3
"""Megamiga (M2M-UPSTREAM code-banks): the code bank image m2m-banks.rom.

Usage: make_banks.py <m2m-rom.out> <m2m-rom.rom> <rom words> <m2m-banks.rom>

The QNICE address space is 64K words, so the firmware outgrew the 32K-word ROM.
The code window 0x9000-0x9FFF shows one of CODE_BANKS 4K-word banks, selected
by M2M$CODE_BANK (see M2M/vhdl/QNICE/qnice.vhd). The banks are assembled
together with the rest of the firmware: after END_OF_ROM, every bank is a
section that starts with ".ORG 0x9000" and its marker word 0x4B00 + n (bank
n, in source order), then the variables follow at 0xA000.

qasm2rom serializes the .out records in source order and ignores addresses
(line N of the .rom is the word of line N of the .out), so this script sorts
the records after the ROM image into the banks: a record whose address does
not grow starts the next bank. Records at 0xA000 and above are variables.
Anything else (the device window 0x8000-0x8FFF, a bank over 0x9FFF) is an
error. The image always has CODE_BANKS * 4096 lines (zero words where nothing
was assembled), the size of the block ROM behind the window.
"""
import sys

CODE_BANKS = 8
BANK_WORDS = 4096
WIN = 0x9000
VARS = 0xA000
MARKER = 0x4B00


def die(msg):
    print("ERROR: make_banks.py: " + msg)
    sys.exit(1)


out_f, rom_f, rom_words, banks_f = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
recs = [l.split() for l in open(out_f) if l.strip()]
words = [l.strip() for l in open(rom_f) if l.strip()]
if len(recs) != len(words):
    die("%s and %s differ in length" % (out_f, rom_f))

banks = []                  # per bank: {offset: word}
prev = None
for i in range(rom_words, len(recs)):
    a = int(recs[i][0], 16)
    if a >= VARS:
        prev = None
        continue
    if not WIN <= a < VARS:
        die("address 0x%04X (.out line %d) is neither in a code bank nor a variable" % (a, i + 1))
    if prev is None or a <= prev:
        if len(banks) == CODE_BANKS:
            die("more than %d code banks" % CODE_BANKS)
        banks.append({})
    banks[-1][a - WIN] = words[i]
    prev = a

used = []
for n, b in enumerate(banks):
    first = b.get(0)
    if first is None or int(first, 2) != MARKER + n:
        die("code bank %d does not start with its marker word 0x%04X at 0x9000" % (n, MARKER + n))
    used.append(max(b) + 1)

with open(banks_f, "w") as f:
    for n in range(CODE_BANKS):
        b = banks[n] if n < len(banks) else {}
        for o in range(BANK_WORDS):
            f.write(b.get(o, "0" * 16) + "\n")

print("Code banks: %d/%d%s" % (len(banks), CODE_BANKS,
      "".join(" [%d: %d/%d words]" % (n, u, BANK_WORDS) for n, u in enumerate(used))))
