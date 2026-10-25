; cfgsig_test.asm - CFG_SIGCHECK / CFG_SIGSET of CORE/m2m-rom/m2m-rom.asm (the settings file
; signature) on the QNICE emulator's headless batch mode, with M2M's cfgstr.asm. run_cfgsig.sh
; extracts the two functions and the signature strings into cfgsig_fn.asm.
;
; Cases: no text (an old file): C=0; CFG_SIGSET on it: the text "menu=<sig>\n", CFGS_DIRTY;
; then C=1; the signature among other lines: C=1; another value (shorter, longer, a prefix):
; C=0; registers R8..R12 preserved by both. Prints "CFGSIG TEST: PASS" or "FAIL <case>".

#include "sysdef.asm"
#include "monitor.def"

CFGS_MAX        .EQU    512
CFGS_MAXC       .EQU    511

                .ORG    0x8000

                MOVE    T_EMPTY, R8             ; 1: an old file, no text
                RSUB    SETBUF, 1
                RSUB    CHECK, 1
                RBRA    FAIL1, C
                MOVE    CFGS_DIRTY, R0
                MOVE    0, @R0
                RSUB    SAVEREGS, 1             ; 2: the signature is added
                RSUB    CFG_SIGSET, 1
                RSUB    CMPREGS, 1
                CMP     0, R7
                RBRA    FAIL2, !Z
                MOVE    CFGS_DIRTY, R0
                CMP     1, @R0
                RBRA    FAIL2, !Z
                MOVE    CFGS_BUF, R8
                MOVE    T_SIGNED, R9
                SYSCALL(strcmp, 1)
                CMP     0, R10
                RBRA    FAIL2, !Z
                RSUB    CHECK, 1                ; 3: now it is this menu's file
                RBRA    FAIL3, !C
                MOVE    T_AMONG, R8             ; 4: among other lines
                RSUB    SETBUF, 1
                RSUB    CHECK, 1
                RBRA    FAIL4, !C
                MOVE    T_OTHER, R8             ; 5: another layout
                RSUB    SETBUF, 1
                RSUB    CHECK, 1
                RBRA    FAIL5, C
                MOVE    T_LONGER, R8            ; 6: the signature as a prefix of the value
                RSUB    SETBUF, 1
                RSUB    CHECK, 1
                RBRA    FAIL6, C
                MOVE    T_KEY, R8               ; 7: a key that ends in "menu"
                RSUB    SETBUF, 1
                RSUB    CHECK, 1
                RBRA    FAIL7, C

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
                HALT

; CHECK: CFG_SIGCHECK with R8..R12 checked; its C flag is returned
CHECK           RSUB    SAVEREGS, 1
                RSUB    CFG_SIGCHECK, 1
                RBRA    _CHK_C, C
                RSUB    CMPREGS, 1
                CMP     0, R7
                RBRA    FAIL_REGS, !Z
                AND     0xFFFB, SR
                RET
_CHK_C          RSUB    CMPREGS, 1
                CMP     0, R7
                RBRA    FAIL_REGS, !Z
                OR      0x0004, SR
                RET
FAIL_REGS       MOVE    0x00EE, R0
                MOVE    R8, R1
                MOVE    S_FAIL, R8
                SYSCALL(puts, 1)
                MOVE    R0, R8
                SYSCALL(puthex, 1)
                MOVE    R1, R8
                SYSCALL(puthex, 1)
                MOVE    R9, R8
                SYSCALL(puthex, 1)
                MOVE    R10, R8
                SYSCALL(puthex, 1)
                MOVE    R11, R8
                SYSCALL(puthex, 1)
                MOVE    R12, R8
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)
                HALT

; SAVEREGS: R8..R12 := known values; CMPREGS: R7 = 0 if they are unchanged (a RET sets Z)
SAVEREGS        MOVE    0x1238, R8
                MOVE    0x1239, R9
                MOVE    0x123A, R10
                MOVE    0x123B, R11
                MOVE    0x123C, R12
                RET
CMPREGS         MOVE    1, R7
                CMP     0x1238, R8
                RBRA    _CMP_R, !Z
                CMP     0x1239, R9
                RBRA    _CMP_R, !Z
                CMP     0x123A, R10
                RBRA    _CMP_R, !Z
                CMP     0x123B, R11
                RBRA    _CMP_R, !Z
                CMP     0x123C, R12
                RBRA    _CMP_R, !Z
                XOR     R7, R7
_CMP_R          RET

; SETBUF: CFGS_BUF := the string R8, CFGS_LEN := its length
SETBUF          MOVE    R8, R0
                MOVE    CFGS_BUF, R1
                XOR     R2, R2
_SETB_1         MOVE    @R0++, R3
                MOVE    R3, @R1++
                CMP     0, R3
                RBRA    _SETB_2, Z
                ADD     1, R2
                RBRA    _SETB_1, 1
_SETB_2         MOVE    CFGS_LEN, R0
                MOVE    R2, @R0
                RET

T_EMPTY         .DW      0
T_SIGNED        .ASCII_P "menu="
                .ASCII_P CFG_SIG_TEXT
                .DW      0x000A, 0
T_AMONG         .ASCII_P "a=b"
                .DW      0x000A
                .ASCII_P "menu="
                .ASCII_P CFG_SIG_TEXT
                .DW      0x000A
                .ASCII_P "z=1"
                .DW      0x000A, 0
T_OTHER         .ASCII_P "menu=1"
                .DW      0x000A, 0
T_LONGER        .ASCII_P "menu="
                .ASCII_P CFG_SIG_TEXT
                .ASCII_P "0"
                .DW      0x000A, 0
T_KEY           .ASCII_P "xmenu="
                .ASCII_P CFG_SIG_TEXT
                .DW      0x000A, 0
S_PASS          .ASCII_W "CFGSIG TEST: PASS\n"
S_FAIL          .ASCII_W "CFGSIG TEST: FAIL "

#include "cfgsig_fn.asm"
#include "cfgstr.asm"

; what cfgstr.asm's file functions (CFGS_SIZE, not called here) refer to
FAT32$PB_SIZE   .EQU    1
FAT32$FLUSH_OWNER RET
FAT32$W_SETSIZE RET
OPTM_ICOUNT     .BLOCK  1
CFGS_PB         .BLOCK  1

CFGS_LEN        .BLOCK  1
CFGS_DIRTY      .BLOCK  1
CFGS_RESET      .BLOCK  1
CFGS_BUF        .BLOCK  CFGS_MAX
