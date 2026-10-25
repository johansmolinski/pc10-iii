# fmtboot.S - a boot sector that starts the WD formatter of the Commodore BIOS
# 4.41 (G=F800:5, doc/xta.md section 7) without DOS: tb/sys has no DOS and no
# DEBUG. The formatter prints and reads through INT 21h; this sector installs
# an INT 21h with the five functions it uses (01h read a key with echo, 02h
# print DL, 06h direct console I/O with DL = FFh as the key check, 09h print
# a '$' string, 0Ah buffered line input), gives it DEBUG's frame (DS = ES =
# SS = a free segment, SP = FFFEh: the formatter keeps its variables at
# SS:0100-0330), and jumps to F800:0005. Built by mkfmtboot.py into a 360 KB
# floppy image. GPL-3.0-or-later, pc10-iii.

    .code16
    .arch i8086,jumps
    .intel_syntax noprefix
    .text
    .globl _start
_start:
    jmp short start
    nop
    .fill 59, 1, 0                  # (no BPB: the BIOS boots the sector as it is)
start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    cld
    mov word ptr [0x84], offset int21
    mov word ptr [0x86], 0
    mov si, offset m_hello
    call puts
    mov ax, 0x2000
    mov ds, ax
    mov es, ax
    cli
    mov ss, ax
    mov sp, 0xFFFE
    sti
    .byte 0xEA                      # jmp far F800:0005
    .word 0x0005, 0xF800

int21:
    sti
    cmp ah, 0x09
    je f09
    cmp ah, 0x02
    je f02
    cmp ah, 0x06
    je f06
    cmp ah, 0x0A
    je f0a
    cmp ah, 0x01
    je f01
    iret

f02:
    push ax
    mov al, dl
    call putc
    pop ax
    iret

f01:
    mov ah, 0
    int 0x16
    call putc
    iret

f09:
    push si
    push ax
    mov si, dx
1:  lodsb
    cmp al, '$'
    je 2f
    call putc
    jmp 1b
2:  pop ax
    pop si
    iret

# DL = FFh: a key in AL and ZF = 0, or AL = 0 and ZF = 1; else print DL
f06:
    cmp dl, 0xFF
    jne f02
    mov ah, 1
    int 0x16
    jz 1f
    mov ah, 0
    int 0x16
    push bp
    mov bp, sp
    and word ptr [bp + 6], 0xFFBF
    pop bp
    iret
1:  xor al, al
    push bp
    mov bp, sp
    or word ptr [bp + 6], 0x0040
    pop bp
    iret

# DS:DX: [0] = buffer size, [1] = characters read, [2..] the line and CR
f0a:
    push bx
    push cx
    push si
    push ax
    mov si, dx
    mov cl, [si]
    xor bx, bx
1:  mov ah, 0
    int 0x16
    cmp al, 13
    je 3f
    cmp al, 8
    je 4f
    mov ah, bl
    inc ah
    cmp ah, cl
    jae 1b
    mov [bx + si + 2], al
    inc bx
    call putc
    jmp 1b
4:  test bx, bx
    jz 1b
    dec bx
    mov al, 8
    call putc
    mov al, ' '
    call putc
    mov al, 8
    call putc
    jmp 1b
3:  mov [bx + si + 2], al
    mov [si + 1], bl
    call putc
    mov al, 10
    call putc
    pop ax
    pop si
    pop cx
    pop bx
    iret

putc:
    push ax
    push bx
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    pop bx
    pop ax
    ret
puts:
    lodsb
    test al, al
    jz 1f
    call putc
    jmp puts
1:  ret

m_hello: .asciz "fmtboot: INT 21h stub, starting the formatter at F800:0005\r\n"
