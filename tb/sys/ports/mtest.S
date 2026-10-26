# mtest.S - MTEST.COM, the ports test of tb/sys (doc/ports.md section 7), GNU as:
#   the BIOS data area's port tables and equipment word; the mouse driver (INT 33h:
#   reset, then the position and buttons whenever they change, until the left button
#   is pressed or 600 ticks); "OK" out of COM1 at 9600 8N1 (direct to the 8250, as
#   the BIOS's INT 14h waits for DSR/CTS, which an unplugged port does not give); a
#   character to LPT1 through INT 17h (its status); a 64-step ramp on LPT1's data
#   latch (the Covox). Ends with "MTEST END".
# Build: tb/sys/ports/mkportsdisk.py. GPL-3.0-or-later, pc10-iii.
        .code16
        .arch   i8086
        .text
        .globl  _start
_start:
        mov     $s_hdr, %dx
        mov     $9, %ah
        int     $0x21
        # the BIOS data area
        push    %ds
        mov     $0x40, %ax
        mov     %ax, %ds
        mov     0x00, %bx               # COM1
        mov     0x02, %cx               # COM2
        mov     0x08, %si               # LPT1
        mov     0x10, %di               # equipment
        pop     %ds
        mov     %bx, com1
        mov     %si, lpt1
        mov     $s_com, %dx
        call    puts
        mov     %bx, %ax
        call    phex
        mov     %cx, %ax
        call    phex
        mov     $s_lpt, %dx
        call    puts
        mov     %si, %ax
        call    phex
        mov     $s_eq, %dx
        call    puts
        mov     %di, %ax
        call    phex
        call    crlf
        # the mouse driver: reset (AX = FFFFh and the buttons when installed)
        mov     $s_m0, %dx
        call    puts
        xor     %ax, %ax
        int     $0x33
        push    %bx
        call    phex
        pop     %ax
        call    phex
        call    crlf
        # COM1: 9600 8N1, "OK"
        mov     com1, %dx
        or      %dx, %dx
        jz      no_com
        add     $3, %dx
        mov     $0x83, %al
        out     %al, %dx
        sub     $3, %dx
        mov     $12, %al
        out     %al, %dx
        inc     %dx
        xor     %al, %al
        out     %al, %dx
        add     $2, %dx
        mov     $0x03, %al
        out     %al, %dx
        mov     $'O', %al
        call    comout
        mov     $'K', %al
        call    comout
no_com:
        # LPT1 through the BIOS: 'P', the status in AH
        mov     $s_lp, %dx
        call    puts
        mov     $0x0050, %ax
        xor     %dx, %dx
        int     $0x17
        mov     %ah, %al
        xor     %ah, %ah
        call    phex
        call    crlf
        # the Covox: a ramp on the data latch
        mov     lpt1, %dx
        or      %dx, %dx
        jz      no_lpt
        xor     %al, %al
        mov     $64, %cx
ramp:   out     %al, %dx
        add     $4, %al
        loop    ramp
no_lpt:
        # the mouse: print the position and buttons when they change
        mov     $600, %si               # ticks
        movw    $0xFFFF, lastx
mloop:  mov     $3, %ax
        int     $0x33
        cmp     lastx, %cx
        jne     mshow
        cmp     lasty, %dx
        jne     mshow
        cmp     lastb, %bx
        je      mwait
mshow:  mov     %cx, lastx
        mov     %dx, lasty
        mov     %bx, lastb
        push    %dx
        push    %bx
        mov     %dx, %bp
        mov     $s_pos, %dx
        call    puts
        mov     %cx, %ax
        call    phex
        mov     %bp, %ax
        call    phex
        pop     %ax
        push    %ax
        call    phex
        call    crlf
        pop     %bx
        pop     %dx
        test    $1, %bl
        jnz     done
mwait:  push    %ds                     # one timer tick
        mov     $0x40, %ax
        mov     %ax, %ds
        mov     0x6C, %ax
tw:     cmp     0x6C, %ax
        je      tw
        pop     %ds
        dec     %si
        jnz     mloop
done:   mov     $s_end, %dx
        call    puts
        int     $0x20

comout: push    %dx
        push    %ax
        mov     com1, %dx
        add     $5, %dx
cw:     in      %dx, %al
        test    $0x20, %al
        jz      cw
        pop     %ax
        sub     $5, %dx
        out     %al, %dx
        pop     %dx
        ret

puts:   push    %ax
        mov     $9, %ah
        int     $0x21
        pop     %ax
        ret

crlf:   push    %dx
        mov     $s_crlf, %dx
        call    puts
        pop     %dx
        ret

# AX as four hex digits and a space
phex:   push    %ax
        push    %bx
        push    %cx
        push    %dx
        mov     %ax, %bx
        mov     $4, %cx
ph1:    push    %cx
        mov     $4, %cl                 # (the 8088 has no rotate by an immediate)
        rol     %cl, %bx
        pop     %cx
        mov     %bl, %dl
        and     $15, %dl
        add     $'0', %dl
        cmp     $'9', %dl
        jbe     ph2
        add     $7, %dl
ph2:    mov     $2, %ah
        int     $0x21
        loop    ph1
        mov     $' ', %dl
        mov     $2, %ah
        int     $0x21
        pop     %dx
        pop     %cx
        pop     %bx
        pop     %ax
        ret

com1:   .word   0
lpt1:   .word   0
lastx:  .word   0
lasty:  .word   0
lastb:  .word   0
s_hdr:  .ascii  "MTEST\r\n$"
s_com:  .ascii  "COM $"
s_lpt:  .ascii  "LPT $"
s_eq:   .ascii  "EQUIP $"
s_m0:   .ascii  "INT 33h reset: $"
s_lp:   .ascii  "INT 17h status: $"
s_pos:  .ascii  "mouse $"
s_end:  .ascii  "MTEST END\r\n$"
s_crlf: .ascii  "\r\n$"
