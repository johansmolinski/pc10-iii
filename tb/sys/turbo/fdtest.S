# fdtest.S - a boot sector that reads the floppy through INT 13h at each speed
# (doc/turbo.md section 6): for 63h = 40h, 80h, 00h it resets the drive and
# reads cylinders 0-3, head 0, sectors 1-9 (AH=02h, AL=9) to 1000:0000. POST
# codes (port 80h): the 63h value, then per read the status (AH) and the 16-bit
# sum of the 4608 bytes (two codes); EEh at the end. The same image gives the
# same sums at every speed. Built by mkspeedtest.py (fdtest.S as the source).
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
    mov si, offset cfgs
next_cfg:
    cs lodsb
    cmp al, 0xFF
    je done
    out 0x80, al
    mov ah, al
    and ah, 0xC0
    or ah, 0x01
    push ds
    mov bx, 0x40
    mov ds, bx
    mov ds:[0x12], ah
    pop ds
    out 0x63, al
    xor ax, ax                      # reset the drive
    xor dx, dx
    int 0x13
    xor ch, ch                      # cylinder 0
cyl:
    mov ax, 0x1000
    mov es, ax
    xor bx, bx
    mov ax, 0x0209
    mov cl, 1
    xor dx, dx
    push cx
    int 0x13
    pop cx
    mov al, ah
    out 0x80, al
    # the sum of the 4608 bytes
    push ds
    push si
    mov ax, 0x1000
    mov ds, ax
    xor si, si
    xor dx, dx
    mov bx, 4608
1:  lodsb
    xor ah, ah
    add dx, ax
    dec bx
    jnz 1b
    pop si
    pop ds
    mov al, dh
    out 0x80, al
    mov al, dl
    out 0x80, al
    inc ch
    cmp ch, 4
    jb cyl
    jmp next_cfg
done:
    mov al, 0xEE
    out 0x80, al
2:  jmp 2b

cfgs:
    .byte 0x40, 0x80, 0x00, 0xFF
