#!/usr/bin/env python3
"""cgawait_rom.py OUT.ROM - an 8 KB test ROM (F000:E000) for the CGA wait-state
oracle (sys_run -C): CPU reads and writes of B8000-BFFFF from byte and word
moves, a REP MOVSB inside video memory and LODSB/STOSB, at loop periods that
walk the access through all 16 lchar phases. No BIOS: no refresh DMA, so every
cycle is compared. Hand-assembled; ends in HLT.

  python3 -I cgawait_rom.py /tmp/cgawait.rom
  sys_run -b /tmp/cgawait.rom -s 0.02 -q -C
"""
import sys

code = bytes([
    0xB8, 0x00, 0xB8,        # mov ax, 0B800h
    0x8E, 0xD8,              # mov ds, ax
    0x8E, 0xC0,              # mov es, ax
    0x31, 0xF6,              # xor si, si
    0xBF, 0x00, 0x20,        # mov di, 2000h
    0xB9, 0x00, 0x01,        # mov cx, 256
    # l1: byte read, byte write
    0x8A, 0x04,              # mov al, [si]
    0x46,                    # inc si
    0x88, 0x05,              # mov [di], al
    0x47,                    # inc di
    0xE2, 0xF8,              # loop l1
    0xB9, 0x00, 0x01,        # mov cx, 256
    # l2: word read, word write (two byte cycles each)
    0x8B, 0x04,              # mov ax, [si]
    0x46,                    # inc si
    0x89, 0x05,              # mov [di], ax
    0x90,                    # nop
    0xE2, 0xF8,              # loop l2
    0xB9, 0x00, 0x01,        # mov cx, 256
    0xF3, 0xA4,              # rep movsb
    0xB9, 0x00, 0x01,        # mov cx, 256
    # l3: lodsb, stosb
    0xAC,                    # lodsb
    0xAA,                    # stosb
    0x90, 0x90,              # nop, nop
    0xE2, 0xFA,              # loop l3
])
# l4: a byte read and a byte write, each after 1-16 turns of LOOP $ (17
# clocks, 51 ticks = 3 mod 16) picked by a pseudo-random DX, so reads and
# writes meet every lchar phase
DELAY = bytes([
    0x81, 0xC2, 0x65, 0x2B,  # add dx, 2B65h
    0xD1, 0xC2,              # rol dx, 1
    0x89, 0xD1,              # mov cx, dx
    0x83, 0xE1, 0x0F,        # and cx, 0Fh
    0x41,                    # inc cx
    0xE2, 0xFE,              # loop $
])
l4 = len(code) + 3
code += bytes([0xBB, 0x00, 0x04])        # mov bx, 1024
code += DELAY + bytes([
    0x8A, 0x04,              # l4: ... mov al, [si]
    0x46,                    # inc si
]) + DELAY + bytes([
    0x88, 0x05,              # mov [di], al
    0x47,                    # inc di
    0x4B,                    # dec bx
])
code += bytes([0x75, (l4 - (len(code) + 2)) & 0xFF])   # jnz l4
code += bytes([
    0xF4,                    # hlt
    0xEB, 0xFD,              # jmp $-1
])
rom = bytearray([0xFF] * 8192)
rom[0:len(code)] = code
rom[0x1FF0:0x1FF5] = bytes([0xEA, 0x00, 0xE0, 0x00, 0xF0])   # FFFF0: jmp far F000:E000
open(sys.argv[1], 'wb').write(rom)
