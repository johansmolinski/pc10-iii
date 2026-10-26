# covox.S - COVOX.COM, a hardware check of the Covox Speech Thing on LPT1's data
# latch (doc/ports.md section 5), GNU as: a sine of 32 samples per period for about
# 3 s (the pitch follows the CPU speed: about 400 Hz at 4.77 MHz), then a falling
# sweep, then the latch back at 80h. Silence before and after: the core's DC blocker.
# Build: tb/sys/ports/mkportsdisk.py. GPL-3.0-or-later, pc10-iii.
        .code16
        .arch   i8086
        .text
        .globl  _start
_start:
        push    %ds
        mov     $0x40, %ax
        mov     %ax, %ds
        mov     0x08, %dx               # LPT1
        pop     %ds
        or      %dx, %dx
        jnz     have
        mov     $s_no, %dx
        mov     $9, %ah
        int     $0x21
        int     $0x20
have:   mov     %dx, port
        mov     $s_on, %dx
        mov     $9, %ah
        int     $0x21
        # the tone: 55 ticks (3 s), delay 12 per sample
        mov     $12, %bp
        mov     $55, %di
        call    tone
        # the sweep: the delay grows 4 .. 40, 4 ticks each
        mov     $4, %bp
sw:     mov     $4, %di
        call    tone
        add     $4, %bp
        cmp     $40, %bp
        jbe     sw
        mov     port, %dx
        mov     $0x80, %al
        out     %al, %dx
        int     $0x20

# play the table with delay BP per sample for DI timer ticks
tone:   push    %ds
        mov     $0x40, %ax
        mov     %ax, %es
        pop     %ds
        mov     %es:0x6C, %ax
        add     %di, %ax
        mov     %ax, endt
        mov     port, %dx
t0:     mov     $table, %si
        mov     $32, %bx
t1:     lodsb
        out     %al, %dx
        mov     %bp, %cx
t2:     loop    t2
        dec     %bx
        jnz     t1
        mov     %es:0x6C, %ax
        cmp     endt, %ax
        jne     t0
        ret

port:   .word   0
endt:   .word   0
table:  .byte   128, 148, 166, 184, 199, 211, 220, 226, 228, 226, 220, 211, 199, 184, 166, 148
        .byte   128, 108, 90, 72, 57, 45, 36, 30, 28, 30, 36, 45, 57, 72, 90, 108
s_no:   .ascii  "No LPT1\r\n$"
s_on:   .ascii  "Covox on LPT1: a tone, then a sweep\r\n$"
