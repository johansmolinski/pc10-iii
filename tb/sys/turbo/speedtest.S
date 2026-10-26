# speedtest.S - a boot sector that measures the FE2010A's speeds (doc/turbo.md
# section 6): for each 63h value of the table below it counts the iterations of
# four loops between two BIOS timer ticks (0040:006C, the 8253's channel 0 at
# 1.19318 MHz / 65536 = 18.2 Hz, independent of the CPU clock):
#   0 registers only (code in the on-board RAM)
#   1 IN AL,61h (an I/O cycle per iteration)
#   2 a read of the video memory (B800:0000, the PVC4: memory bus)
#   3 a read of the ROM (F000:0000, memory bus [A])
# It writes 63h itself and 0040:0012 (the speed the Commodore BIOS restores on
# its service exits, (12h & C0h) | 01h, F000:C6B5) and calls no BIOS service
# while it measures. Results: per value one POST code (port 80h) with the 63h
# value, then the four counts as two POST codes each (high, low byte), and the
# same on the screen at the end. Built by mkspeedtest.py into a 360 KB floppy.
# GPL-3.0-or-later, pc10-iii.

    .code16
    .arch i8086,jumps
    .intel_syntax noprefix
    .text
    .globl _start
_start:
    cli
    xor ax, ax
    mov ds, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    mov ax, 0x40
    mov es, ax
    mov si, offset cfgs
    mov di, 0x0600                  # results
next_cfg:
    lodsb
    cmp al, 0xFF
    je report
    mov [di], al
    inc di
    out 0x80, al
    mov ah, al
    and ah, 0xC0
    or ah, 0x01
    mov es:[0x12], ah
    out 0x63, al
    xor bp, bp
kind:
    call measure
    mov [di], cx
    add di, 2
    mov al, ch
    out 0x80, al
    mov al, cl
    out 0x80, al
    inc bp
    cmp bp, 4
    jb kind
    jmp next_cfg

# CX = iterations of loop BP between two ticks
measure:
    mov bx, es:[0x6C]
1:  cmp bx, es:[0x6C]
    je 1b
    mov bx, es:[0x6C]
    xor cx, cx
    push ds
    cmp bp, 1
    je l_io
    cmp bp, 2
    je l_vid
    cmp bp, 3
    je l_rom
l_reg:
    inc cx
    cmp bx, es:[0x6C]
    je l_reg
    pop ds
    ret
l_io:
    in al, 0x61
    inc cx
    cmp bx, es:[0x6C]
    je l_io
    pop ds
    ret
l_vid:
    mov ax, 0xB800
    mov ds, ax
2:  mov al, ds:[0]
    inc cx
    cmp bx, es:[0x6C]
    je 2b
    pop ds
    ret
l_rom:
    mov ax, 0xF000
    mov ds, ax
3:  mov al, ds:[0]
    inc cx
    cmp bx, es:[0x6C]
    je 3b
    pop ds
    ret

# the results on the screen: one line per value, "vv: rrrr iiii vvvv oooo"
report:
    mov al, 0x01                    # back to 4.77 MHz
    mov es:[0x12], al
    out 0x63, al
    mov si, 0x0600
    mov bp, offset cfgs
r_line:
    cmp byte ptr [bp], 0xFF
    je halt
    inc bp
    lodsb
    call hex2
    mov al, ':'
    call putc
    mov dl, 4
r_cnt:
    mov al, ' '
    call putc
    lodsw
    push ax
    mov al, ah
    call hex2
    pop ax
    call hex2
    dec dl
    jnz r_cnt
    mov al, 13
    call putc
    mov al, 10
    call putc
    jmp r_line
halt:
    mov al, 0xEE                    # done
    out 0x80, al
4:  jmp 4b

hex2:
    push ax
    mov cl, 4
    shr al, cl
    call hex1
    pop ax
hex1:
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe putc
    add al, 7
putc:
    push bx
    mov ah, 0x0E
    xor bx, bx
    int 0x10
    pop bx
    ret

# 63h bits 7-5 (the BIOS has set the lock, bits 0-4 stay)
cfgs:
    .byte 0x00, 0x40, 0x60, 0x80, 0xC0, 0xA0, 0x00, 0xFF
