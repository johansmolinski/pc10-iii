; rows_test.asm - M2M/rom/menu_rows.asm (OPTR_PRINT, OPTR_POS) on the QNICE emulator's headless
; batch mode, with a stub screen (SCR$PRINTSTRXY writes into SCREEN, 40 x 25). run_rows.sh
; extracts menu.asm's OPTM_IR_* offsets and OPTM_NL into rows_menu.asm.
;
; The menu: a headline, " A:%s", the row without a label " B:%s" + " int. drive" (groups 2
; and 0x82: a row is bits 6..0 of the group id), " C:%s", a row with a label " CPU: 68000" +
; " 68020" (group 5), " Close". OPTM_X = 1, OPTM_Y = 0, OPTM_DX = 28.
;
; Case 1, " int. drive" shown: " B:%s" at the classic place, "int. drive" at the right edge
; of the frame (marker column 15), B:'s highlight up to one blank in front of it (width 14);
; the labelled row as before (label line, options from marker column 1). Case 2, hidden
; (OPTM_CORE_HIDE): no "int. drive" text, B:'s highlight the whole width, the hidden option
; still has its ordinal and layout. Both: OPTR_POS of B: and int. drive. Prints
; "ROWS TEST: PASS" or "ROWS TEST: FAIL <case>".

#include "sysdef.asm"
#include "monitor.def"

                .ORG    0x8000

                MOVE    T_HIDE, R0              ; 1: shown
                MOVE    0xFFFF, @R0
                RSUB    DRAW, 1
                MOVE    X_ROWS1, R8
                RSUB    CMPSCR, 1
                RBRA    FAIL1, !C
                MOVE    X_LAY1, R8
                RSUB    CMPLAY, 1
                RBRA    FAIL2, !C
                MOVE    2, R8                   ; OPTR_POS of " B:%s": x 2, y 3, 14
                RSUB    OPTR_POS, 1
                CMP     2, R8
                RBRA    FAIL3, !Z
                CMP     3, R9
                RBRA    FAIL3, !Z
                CMP     14, R10
                RBRA    FAIL3, !Z
                MOVE    3, R8                   ; of " int. drive": x 17, y 3, 11
                RSUB    OPTR_POS, 1
                CMP     17, R8
                RBRA    FAIL4, !Z
                CMP     3, R9
                RBRA    FAIL4, !Z
                CMP     11, R10
                RBRA    FAIL4, !Z

                MOVE    T_HIDE, R0              ; 2: " int. drive" (flat 3) hidden
                MOVE    3, @R0
                RSUB    DRAW, 1
                MOVE    X_ROWS2, R8
                RSUB    CMPSCR, 1
                RBRA    FAIL5, !C
                MOVE    X_LAY2, R8
                RSUB    CMPLAY, 1
                RBRA    FAIL6, !C
                MOVE    2, R8                   ; B: the whole width (26)
                RSUB    OPTR_POS, 1
                CMP     26, R10
                RBRA    FAIL7, !Z

                MOVE    S_PASS, R8
                SYSCALL(puts, 1)
                HALT

FAIL1           MOVE    1, R0
                RBRA    FAIL, 1
FAIL2           MOVE    2, R0
                RBRA    FAIL, 1
FAIL3           MOVE    3, R0
                RBRA    FAIL, 1
FAIL4           MOVE    4, R0
                RBRA    FAIL, 1
FAIL5           MOVE    5, R0
                RBRA    FAIL, 1
FAIL6           MOVE    6, R0
                RBRA    FAIL, 1
FAIL7           MOVE    7, R0
FAIL            MOVE    S_FAIL, R8
                SYSCALL(puts, 1)
                MOVE    R0, R8
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)
                MOVE    SCREEN, R0              ; the screen, rows 0-7
                MOVE    8, R1
_FD_1           MOVE    40, R2
_FD_2           MOVE    @R0++, R8
                SYSCALL(putc, 1)
                SUB     1, R2
                RBRA    _FD_2, !Z
                SYSCALL(crlf, 1)
                SUB     1, R1
                RBRA    _FD_1, !Z
                MOVE    OPTR_LAY, R0            ; the layout, ordinals 0-7
                MOVE    16, R1
_FD_3           MOVE    @R0++, R8
                SYSCALL(puthex, 1)
                MOVE    S_SP, R8
                SYSCALL(puts, 1)
                SUB     1, R1
                RBRA    _FD_3, !Z
                SYSCALL(crlf, 1)
                HALT

; DRAW: a blank screen, then OPTR_PRINT of the menu
DRAW            MOVE    SCREEN, R0
                MOVE    1000, R1
_DR_1           MOVE    0x0020, @R0++
                SUB     1, R1
                RBRA    _DR_1, !Z
                MOVE    OPTM_X, R0
                MOVE    1, @R0
                MOVE    OPTM_Y, R0
                MOVE    0, @R0
                MOVE    OPTM_DX, R0
                MOVE    28, @R0
                MOVE    OPTM_DATA, R0
                MOVE    T_REC, @R0
                MOVE    T_ITEMS, R8
                MOVE    T_MASK, R9
                RSUB    OPTR_PRINT, 1
                RET

; CMPSCR: C=1 when screen rows 1-7 equal the 7 strings at R8 (40 characters each)
; (RET is a MOVE: it changes Z, not C)
CMPSCR          MOVE    SCREEN, R0
                ADD     40, R0
                MOVE    280, R1
_CS_1           CMP     @R8++, @R0++
                RBRA    _CS_N, !Z
                SUB     1, R1
                RBRA    _CS_1, !Z
                OR      0x0004, SR
                RET
_CS_N           AND     0xFFFB, SR
                RET

; CMPLAY: C=1 when OPTR_LAY's first 16 words equal the 16 words at R8
CMPLAY          MOVE    OPTR_LAY, R0
                MOVE    16, R1
_CL_1           CMP     @R8++, @R0++
                RBRA    _CS_N, !Z
                SUB     1, R1
                RBRA    _CL_1, !Z
                OR      0x0004, SR
                RET

; ---------------------------------------------------------------------------- stubs

; SCR$PRINTSTRXY: the string R8 at x|y = R9|R10 into SCREEN; registers preserved
SCR$PRINTSTRXY  INCRB
                MOVE    SCREEN, R0
                MOVE    R10, R1
_SP_1           CMP     0, R1
                RBRA    _SP_2, Z
                ADD     40, R0
                SUB     1, R1
                RBRA    _SP_1, 1
_SP_2           ADD     R9, R0
                MOVE    R8, R1
_SP_3           CMP     0, @R1
                RBRA    _SP_4, Z
                MOVE    @R1++, @R0++
                RBRA    _SP_3, 1
_SP_4           DECRB
                RET

OPT_LINE_AT     RET

; OPTM_CORE_HIDE: C=1 for the flat index in T_HIDE
OPTM_CORE_HIDE  INCRB
                MOVE    T_HIDE, R0
                CMP     @R0, R8
                RBRA    _OCH_N, !Z
                OR      0x0004, SR
                DECRB
                RET
_OCH_N          AND     0xFFFB, SR
                DECRB
                RET

ERR_F_NEWLINE   .EQU    0x0001
FATAL           MOVE    S_FATAL, R8
                SYSCALL(puts, 1)
                HALT

#include "rows_menu.asm"
#include "menu_rows.asm"

; ---------------------------------------------------------------------------- data

; (config.vhd's items end in a backslash and an "n", OPTM_NL: qasm would make "\n" a newline)
T_ITEMS         .ASCII_P " PC10-III"
                .DW     0x005C, 0x006E
                .ASCII_P " A:%s"
                .DW     0x005C, 0x006E
                .ASCII_P " B:%s"
                .DW     0x005C, 0x006E
                .ASCII_P " int. drive"
                .DW     0x005C, 0x006E
                .ASCII_P " C:%s"
                .DW     0x005C, 0x006E
                .ASCII_P " CPU: 68000"
                .DW     0x005C, 0x006E
                .ASCII_P " 68020"
                .DW     0x005C, 0x006E
                .ASCII_P " Close"
                .DW     0x005C, 0x006E, 0x0000
T_MASK          .DW     8, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000
T_GROUPS        .DW     0x1000, 0x0001, 0x8002, 0x8082, 0x0003, 0x0005, 0x0005, 0x00FF
T_LINES         .DW     0, 0, 2, 2, 0, 2, 2, 0

; the init record: only OPTM_IR_GROUPS and OPTM_IR_LINES are read
T_REC           .BLOCK  OPTM_IR_GROUPS
                .DW     T_GROUPS
                .DW     0
                .DW     T_LINES
                .BLOCK  4

;                        0         1         2         3
;                        0123456789012345678901234567890123456789
X_ROWS1         .ASCII_P "   PC10-III                             "
                .ASCII_P "   A:%s                                 "
                .ASCII_P "   B:%s           int. drive            "
                .ASCII_P "   C:%s                                 "
                .ASCII_P "   CPU                                  "
                .ASCII_P "    68000  68020                        "
                .ASCII_P "   Close                                "
X_ROWS2         .ASCII_P "   PC10-III                             "
                .ASCII_P "   A:%s                                 "
                .ASCII_P "   B:%s                                 "
                .ASCII_P "   C:%s                                 "
                .ASCII_P "   CPU                                  "
                .ASCII_P "    68000  68020                        "
                .ASCII_P "   Close                                "

; OPTR_LAY: per ordinal (column << 8) + row, width (0 = the whole width)
X_LAY1          .DW     0x0000, 0, 0x0001, 0, 0x0002, 14, 0x0F02, 11
                .DW     0x0003, 0, 0x0105, 6, 0x0805, 6, 0x0006, 0
X_LAY2          .DW     0x0000, 0, 0x0001, 0, 0x0002, 0, 0x0F02, 11
                .DW     0x0003, 0, 0x0105, 6, 0x0805, 6, 0x0006, 0

S_PASS          .ASCII_W "ROWS TEST: PASS\n"
S_FAIL          .ASCII_W "ROWS TEST: FAIL "
S_FATAL         .ASCII_W "ROWS TEST: FAIL FATAL\n"
S_SP            .ASCII_W " "

; ---------------------------------------------------------------------------- variables

T_HIDE          .BLOCK  1
SCREEN          .BLOCK  1000
OPTM_X          .BLOCK  1
OPTM_Y          .BLOCK  1
OPTM_DX         .BLOCK  1
OPTM_DATA       .BLOCK  1
OPTR_LAY        .BLOCK  80
OPTR_GRP        .BLOCK  1
OPTR_COL        .BLOCK  1
OPTR_LBL        .BLOCK  1
OPTR_LBLN       .BLOCK  1
OPTR_FST        .BLOCK  1
