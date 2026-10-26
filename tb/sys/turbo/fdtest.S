# fdtest.S - a boot sector that reads the floppy through INT 13h at each speed
# (doc/turbo.md section 6): for 63h = 40h, 80h, 00h it resets the drive and
# reads cylinders 0-3, head 0, sectors 1-9 (AH=02h, AL=9) to 1000:0000. POST
# codes (port 80h): the 63h value, then per read the status (AH) and the 16-bit
# sum of the 4608 bytes (two codes); EEh at the end. The same image gives the
# same sums at every speed. Built by mkspeedtest.py (fdtest.S as the source).
# The codes also go to the screen (2026-10-26, for the MEGA65, which has no
# port 80h display): one line per speed, "vv: ss/hhhh ss/hhhh ss/hhhh ss/hhhh"
# (vv = 63h, ss = the read's status, 00 = OK, hhhh = the sum), then "done".
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
    push ax
    call code
    mov al, ':'
    call putc
    pop ax
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
    push ax
    mov al, ' '
    call putc
    pop ax
    call code
    mov al, '/'
    call putc
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
    call code
    mov al, dl
    call code
    inc ch
    cmp ch, 4
    jb cyl
    call crlf
    jmp next_cfg
done:
    mov al, 0xEE
    out 0x80, al
    mov si, offset s_done
3:  cs lodsb
    or al, al
    jz 2f
    call putc
    jmp 3b
2:  jmp 2b

# a POST code to port 80h and in hex to the screen (AX, CL changed)
code:
    out 0x80, al
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
crlf:
    mov al, 13
    call putc
    mov al, 10
    jmp putc

s_done:
    .asciz "done"

cfgs:
    .byte 0x40, 0x80, 0x00, 0xFF
