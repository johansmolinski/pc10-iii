# xtadma.S - a test "BIOS" for tb/sys (make XTA=1): the PC20-III hard disk's
# DMA path without the Commodore BIOS's 40 s of POST. It programs channel 3
# of the 8237 as the WD SuperBIOS does (mode 47h/4Bh, address, page 82h,
# count, unmask after the CCB) and runs on the drive:
#   0Fh write sector buffer (DMA, memory -> drive, 512 bytes from 1000:0000)
#   0Eh read sector buffer  (DMA, drive -> memory, to 2000:0000)
#   0Eh again by PIO (mask FCh), to 2000:0000; its completion byte and the
#       byte count / 256 (02) go to port 80h
# and compares the buffers. The DMA commands run 16 times with DRAM refresh
# (8237 channel 0 every 15 us) interleaving. Each command's completion byte goes to port
# 80h (sys_run prints it as a POST code), then the 8237's status (port 08h),
# then the comparison: 00 = equal, EE = different. A timeout writes the
# drive's status (321h) to port 80h every ~0.2 s. Built by mkxtadma.py as an
# 8 KB image (F000:E000, reset vector at FFFF0). GPL-3.0-or-later, pc10-iii.

    .code16
    .arch i8086,jumps
    .intel_syntax noprefix
    .text
    .globl _start
_start:
    cli
    cld
    mov ax, 0x0030
    mov ss, ax
    mov sp, 0x0100
    # the pattern at 1000:0000, 2000:0000 cleared
    mov ax, 0x1000
    mov es, ax
    xor di, di
    mov cx, 512
    mov al, 0x5A
1:  stosb
    add al, 7
    loop 1b
    mov ax, 0x2000
    mov es, ax
    xor di, di
    mov cx, 512
    xor al, al
    rep stosb
    # the 8237: master clear, enabled, channel 3 masked; refresh as a BIOS
    # sets it up: channel 0 mode 58h (read, autoinit, single), count FFFFh,
    # the 8253's channel 1 in mode 2 with 18 (15 us)
    out 0x0D, al
    xor al, al
    out 0x08, al
    mov al, 0x58
    out 0x0B, al
    mov al, 0xFF
    out 0x01, al
    out 0x01, al
    xor al, al
    out 0x0A, al
    mov al, 0x54
    out 0x43, al
    mov al, 18
    out 0x41, al
    mov bp, 16                      # 16 rounds of 0Fh / 0Eh
round:
    # 0Fh: memory -> drive, mode 4Bh, 1000:0000
    mov al, 0x4B
    mov bl, 0x01
    call dma3
    mov si, offset ccb_wbuf
    call xta
    # 0Eh: drive -> memory, mode 47h, 2000:0000
    mov al, 0x47
    mov bl, 0x02
    call dma3
    mov si, offset ccb_rbuf
    call xta
    dec bp
    jnz round
    # 0Eh again by PIO (mask FCh), as the BIOS reads sector 0: to 2000:0000
    mov ax, 0x2000
    mov es, ax
    xor di, di
    mov cx, 512
    xor al, al
    rep stosb
    call pio_rbuf
    # compare
    mov ax, 0x1000
    mov ds, ax
    mov ax, 0x2000
    mov es, ax
    xor si, si
    xor di, di
    mov cx, 512
    repe cmpsb
    mov al, 0x00
    je 1f
    mov al, 0xEE
1:  out 0x80, al
halt:
    hlt
    jmp halt

# channel 3: mode AL, page BL, address 0000h, count 511
dma3:
    out 0x0B, al
    out 0x0C, al
    xor al, al
    out 0x06, al
    out 0x06, al
    mov al, bl
    out 0x82, al
    mov al, 0xFF
    out 0x07, al
    mov al, 0x01
    out 0x07, al
    ret

# a command: mask 03, select, the CCB at CS:SI, unmask channel 3, wait for
# the interrupt bit, mask FC, the completion byte and the 8237's status to 80h
xta:
    mov dx, 0x323
    mov al, 0x03
    out dx, al
    dec dx
1:  out dx, al
    dec dx
    in al, dx
    inc dx
    and al, 0x0D
    cmp al, 0x0D
    jne 1b
    mov cx, 6
2:  mov dx, 0x321
3:  in al, dx
    test al, 1
    jz 3b
    mov dx, 0x320
    lods al, byte ptr cs:[si]
    out dx, al
    loop 2b
    mov al, 0x03
    out 0x0A, al
    mov dx, 0x321
4:  mov cx, 0x4000
5:  in al, dx
    test al, 0x20
    jnz 6f
    loop 5b
    out 0x80, al                # timeout: the status
    jmp 4b
6:  mov dx, 0x323
    mov al, 0xFC
    out dx, al
    mov dx, 0x320
    in al, dx
    out 0x80, al
    in al, 0x08
    out 0x80, al
    ret

# 0Eh by PIO: mask FCh, the CCB, 512 bytes each after REQ to ES:0000, the
# completion byte to port 80h (a timeout: the status and the byte count)
pio_rbuf:
    mov dx, 0x323
    mov al, 0xFC
    out dx, al
    dec dx
1:  out dx, al
    dec dx
    in al, dx
    inc dx
    and al, 0x0D
    cmp al, 0x0D
    jne 1b
    mov si, offset ccb_rbuf
    mov cx, 6
2:  mov dx, 0x321
3:  in al, dx
    test al, 1
    jz 3b
    mov dx, 0x320
    lods al, byte ptr cs:[si]
    out dx, al
    loop 2b
    xor di, di
4:  mov dx, 0x321
    mov cx, 0x4000
5:  in al, dx
    test al, 1
    jnz 6f
    loop 5b
    out 0x80, al
    mov ax, di
    out 0x80, al
    jmp 4b
6:  and al, 0x0E
    cmp al, 0x0E
    je 7f
    mov dx, 0x320
    in al, dx
    stosb
    jmp 4b
7:  mov dx, 0x320
    in al, dx
    out 0x80, al
    mov ax, di
    mov al, ah
    out 0x80, al
    ret

ccb_wbuf: .byte 0x0F, 0, 0, 0, 0, 0
ccb_rbuf: .byte 0x0E, 0, 0, 0, 0, 0

    .org 0x1FF0
    .byte 0xEA                  # jmp far F000:E000
    .word 0xE000, 0xF000
    .org 0x2000
