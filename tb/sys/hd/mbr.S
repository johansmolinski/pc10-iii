# mbr.S - the master boot record of the tb/sys hard disk test image
# (mkhdimg.py, doc/hdc.md section 7). Loaded by the XTIDE Universal BIOS's
# INT 19h at 0000:7C00 with DL = 80h, it tests the BIOS disk services:
#   - INT 13h AH=08h (parameters)
#   - AH=02h one sector (C0 H0 S2, a text) and 20 sectors from C0 H1 S10
#     (across a head boundary), checked against a sum the image builder
#     passes as EXPSUM
#   - AH=03h three sectors at C0 H2 S16 (across a head boundary), read back
#     and compared; a copy of this sector to C0 H3 S9
# and prints the results on the screen. The image builder checks the
# written sectors in the image afterwards. GPL-3.0-or-later, pc10-iii.

    .code16
    .arch i8086,jumps
    .intel_syntax noprefix
    .text
    .globl _start
_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    cld
    mov [drive], dl
    mov si, offset m_hello
    call puts
    mov al, dl
    call hex8
    call crlf

    # AH=08h: CX = cylinders/sectors, DX = heads/drives
    mov ah, 0x08
    mov dl, [drive]
    int 0x13
    jc fail
    mov si, offset m_geo
    call puts
    mov ax, cx
    call hex16
    mov al, ' '
    call putc
    mov ax, dx
    call hex16
    call crlf

    # AH=02h C0 H0 S2: a text sector
    mov bx, 0x8000
    mov ax, 0x0201
    mov cx, 0x0002
    xor dh, dh
    call disk
    mov si, offset m_s1
    call puts
    mov si, 0x8000
    call puts
    call crlf

    # AH=02h 20 sectors from C0 H1 S10, sum of the words
    mov bx, 0x8000
    mov ax, 0x0214
    mov cx, 0x000A
    mov dh, 1
    call disk
    mov si, 0x8000
    mov cx, 20 * 256
    xor dx, dx
1:  lodsw
    add dx, ax
    loop 1b
    mov si, offset m_r20
    call puts
    mov ax, dx
    call hex16
    cmp dx, EXPSUM
    call okbad

    # AH=03h 3 sectors at C0 H2 S16, a pattern; read back to A000 and compare
    mov di, 0x9000
    mov cx, 3 * 512
    xor ax, ax
1:  mov al, ah
    add al, 0x5A
    stosb
    add ah, 3
    loop 1b
    mov bx, 0x9000
    mov ax, 0x0303
    mov cx, 0x0010
    mov dh, 2
    call disk
    mov bx, 0xA000
    mov ax, 0x0203
    mov cx, 0x0010
    mov dh, 2
    call disk
    mov si, 0x9000
    mov di, 0xA000
    mov cx, 3 * 512
    repe cmpsb
    pushf
    mov si, offset m_w3
    call puts
    popf
    call okbad

    # AH=03h this sector to C0 H3 S9
    mov bx, 0x7C00
    mov ax, 0x0301
    mov cx, 0x0009
    mov dh, 3
    call disk
    mov si, offset m_done
    call puts
halt:
    hlt
    jmp halt

# INT 13h with the drive in DL; prints the function and AH on an error
disk:
    mov dl, [drive]
    push ax
    int 0x13
    pop dx
    jnc 1f
fail:
    push ax
    mov si, offset m_err
    call puts
    pop ax
    call hex16
    jmp halt
1:  ret

# " OK" if ZF, else " BAD"
okbad:
    mov si, offset m_ok
    jz 1f
    mov si, offset m_bad
1:  call puts
crlf:
    mov al, 13
    call putc
    mov al, 10
putc:
    push bx
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    pop bx
    ret
puts:
    lodsb
    test al, al
    jz 1f
    call putc
    jmp puts
1:  ret
hex16:
    push ax
    mov al, ah
    call hex8
    pop ax
hex8:
    push ax
    push cx
    mov cl, 4
    shr al, cl
    pop cx
    call hex4
    pop ax
hex4:
    and al, 15
    add al, '0'
    cmp al, '9'
    jbe putc
    add al, 7
    jmp putc

m_hello: .asciz "MBR test, drive "
m_geo:   .asciz "AH=08 CX DX "
m_s1:    .asciz "S2: "
m_r20:   .asciz "read 20, sum "
m_w3:    .asciz "write 3, read back"
m_ok:    .asciz " OK"
m_bad:   .asciz " BAD"
m_err:   .asciz " error AX "
m_done:  .asciz "done\r\n"
drive:   .byte 0
