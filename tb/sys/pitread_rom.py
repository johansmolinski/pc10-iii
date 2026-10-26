#!/usr/bin/env python3
"""pitread_rom.py OUT.ROM - a 64 KB test ROM (F000:0000, no BIOS) for one IOR
strobe per IN (doc/history.md 2026-10-26, "8253 control word, IOR in T2").

It starts the refresh (counter 1 = 18, DMA channel 0) and then latches and
reads the 8253's counter 0 (OUT 43h,00h; IN 40h; IN 40h) 1,000 times at each
FE2010A speed (63h = 01h, 41h, 81h, 01h: 4.77, 7.16, 9.54, 4.77 MHz; POST code
= the 63h value). With IOR in T1, a refresh granted in Ti cut about one IN in
4,000 and the IN's strobe came back after the transfer: xt_board's check
"a second IOR strobe in one CPU bus cycle" stops the run. Ends with POST AF.
Built from pitrd.S (GNU as, .code16; listed below), hand-checked:

    cli; xor ax,ax; mov ss,ax; mov sp,7000h; mov ds,ax
    mov al,36h; out 43h,al; xor al,al; out 40h,al; out 40h,al   counter 0: mode 3
    mov al,54h; out 43h,al; mov al,18; out 41h,al               counter 1: refresh
    out 0Dh,al; mov al,0FFh; out 0,al; out 0,al; out 1,al; out 1,al
    mov al,58h; out 0Bh,al; xor al,al; out 8,al; out 0Ah,al     8237 channel 0
    mov si,speeds
  next: mov al,cs:[si]; inc si; cmp al,0FFh; je done
    out 63h,al; out 80h,al; mov cx,1000
  1: xor al,al; out 43h,al; in al,40h; mov ah,al; in al,40h; loop 1b
    jmp next
  done: mov al,0AFh; out 80h,al; hlt; jmp $
  speeds: db 01h, 41h, 81h, 01h, 0FFh

  make FE=1 PVC4=1 OBJ=obj_pvc4
  python3 -I pitread_rom.py /tmp/pitread.rom
  ./obj_pvc4/sys_run -b /tmp/pitread.rom -d 5D -s 0.07    (POST 01 41 81 01 AF)

GPL-3.0-or-later, pc10-iii.
"""
import sys

CODE = bytes.fromhex(
    'fa31c08ed0bc00708ed8b036e64330c0e640e640b054e643b012e641e60db0ffe6'
    '00e600e601e601b058e60b30c0e608e60abe59002e8a04463cff7415e663e680b9'
    'e80330c0e643e44088c4e440e2f4ebe3b0afe680f4ebfe01418101ff')

if len(sys.argv) != 2:
    sys.exit(__doc__)
rom = bytearray([0xFF] * 65536)
rom[0:len(CODE)] = CODE
rom[0xFFF0:0xFFF5] = bytes([0xEA, 0x00, 0x00, 0x00, 0xF0])   # FFFF0: jmp far F000:0000
open(sys.argv[1], 'wb').write(rom)
