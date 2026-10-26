; hdc_test.asm - the hard disk C: across power-off: CORE/m2m-rom/pc_hdc.asm (HDC_SAVE,
; HDC_RESTORE, HDC_PEND_APPLY) with the firmware's PREP_LOAD_IMAGE and HANDLE_CORE_IO and
; M2M's cfgstr.asm on the QNICE emulator's headless batch mode, with an SD card image
; (run_hdc.sh makes it: /root.txt, /pc10/hd20.img and "/pc10/Long Folder Name/My Hard
; Disk.img" of 21,411,840 bytes, /pc10/small.img of 1000, /pc10/a360.img of 368,640, x.img in
; two folders whose paths are 127 and 128 characters long). The monitor's FAT32 library does
; the file system work on the card; FD_SETUP, SDC$SLOT/SDC$MOUNT (slot 0: no card), the CSR
; functions and the screen are stubs that record their calls; M2M$RAMROM_DEV/4KWIN,
; M2M$KEYBOARD and M2M$CSR are RAM words, the device window 0x8000 is RAM.
;
; Cases 0x01-0x0A: a mount through PREP_LOAD_IMAGE (the browser's way: the file opened by
; its name in the current directory) writes "hdc=" with the card and the path, keeps the
; current directory and frees the sector buffer, leaves the file at its end; a long folder
; name; the other card; a refused image, a failing FD_SETUP, an A: mount; HDC_SAVE at the
; root, at 127 characters, at 128 (no key), for an empty drive. Cases 0x11-0x1C:
; HDC_RESTORE: the image mounted as the menu does (FD_SETUP, STATUS ok, the name pending,
; the key unchanged), a key in other case (kept as it is), a missing file, a wrong size, no
; card, bad card prefixes, no key, FD_SETUP failing (the message and no key in all failing
; cases). Cases 0x21-0x25: HDC_PEND_APPLY: no menu yet, the name in the line's buffer of
; OPTM_HEAP and nowhere else, a long name cut at OPTM_DX - 1, a path without "/". Cases
; 0x31-0x34: HANDLE_CORE_IO: SPACE on C: forgets the key, not on A:, not without a new
; press; the pending name applied. Registers checked throughout. Prints "HDC TEST: PASS"
; or "FAIL <case>".

#include "sysdef.asm"
#include "monitor.def"
#include "hdc_const.asm"

M2M$RAMROM_DEV  .EQU    0xF000                  ; RAM words standing in for the registers
M2M$RAMROM_4KWIN .EQU   0xF001
M2M$KEYBOARD    .EQU    0xF002
M2M$CSR         .EQU    0xF003
M2M$CSR_OSM     .EQU    0x0004
M2M$KEY_SPACE   .EQU    0x0020
CTX_LOAD_ROM    .EQU    0x0200
CRTROM_CSR_STATUS .EQU  0x8000
CRTROM_CSR_PARSEST .EQU 0x8010
CRTROM_CSR_ST_IDLE .EQU 0x0000
CRTROM_CSR_ST_OK .EQU   0x0003
CRTROM_CSR_PT_OK .EQU   0x0002
CFGS_MAX        .EQU    512
CFGS_MAXC       .EQU    511
FD_MODE_ADDR    .EQU    0x8000
FD_STAT_ADDR    .EQU    0x8008
T_DX            .EQU    30                      ; SCR$OSM_O_DX (OPTM_DX + 2)

                .ORG    0x9000

                MOVE    0xFE00, SP
                MOVE    FD_STAT_ADDR, R0        ; no transfer running
                MOVE    0, @R0
                MOVE    M2M$CSR, R0
                MOVE    0, @R0
                MOVE    1, R7                   ; the card
                MOVE    T_DEV, R8
                MOVE    1, R9
                SYSCALL(f32_mnt_sd, 1)
                CMP     0, R9
                RBRA    FAIL, !Z

                ; --- 0x01: C: through PREP_LOAD_IMAGE, the browser's way
                MOVE    0x01, R7
                MOVE    T_M6, R8
                RSUB    SETTXT, 1
                MOVE    T_PC10, R8
                MOVE    S_HD20, R9
                RSUB    BROWSE, 1
                RSUB    PL_HDC, 1
                CMP     0, R8
                RBRA    FAIL, !Z
                MOVE    2, R1
                RSUB    SETUP_ONCE, 1
                MOVE    T_X1, R8
                RSUB    EXPECT, 1
                MOVE    CFGS_DIRTY, R0
                CMP     1, @R0
                RBRA    FAIL, !Z
                RSUB    AD_KEPT, 1
                MOVE    T_DEV, R0               ; the sector buffer is nobody's
                ADD     FAT32$DEV_BUFFERED_FDH, R0 ; (if HDC_FDH had it)
                CMP     HDC_FDH, @R0
                RBRA    FAIL, Z
                MOVE    HANDLE_RM_FILE3, R8     ; the file stays at its end
                SYSCALL(f32_fread, 1)
                CMP     FAT32$EOF, R10
                RBRA    FAIL, !Z

                ; --- 0x02: a long folder name, the key replaced
                MOVE    0x02, R7
                MOVE    T_LONG, R8
                MOVE    S_MYHD, R9
                RSUB    BROWSE, 1
                RSUB    PL_HDC, 1
                CMP     0, R8
                RBRA    FAIL, !Z
                MOVE    T_X2, R8
                RSUB    EXPECT, 1
                RSUB    AD_KEPT, 1

                ; --- 0x03: the other card
                MOVE    0x03, R7
                MOVE    T_SLOT, R0
                MOVE    0, @R0
                MOVE    T_PC10, R8
                MOVE    S_HD20, R9
                RSUB    BROWSE, 1
                RSUB    PL_HDC, 1
                CMP     0, R8
                RBRA    FAIL, !Z
                MOVE    T_X3, R8
                RSUB    EXPECT, 1
                MOVE    T_SLOT, R0
                MOVE    1, @R0

                ; --- 0x04: an image of the wrong size: refused, no key
                MOVE    0x04, R7
                MOVE    T_PC10, R8
                MOVE    S_SMALL, R9
                RSUB    BROWSE, 1
                RSUB    PL_HDC, 1
                CMP     3, R8
                RBRA    FAIL, !Z
                CMP     ERR_HD_SIZE, R9
                RBRA    FAIL, !Z
                RSUB    SETUP_NONE, 1
                MOVE    T_M6, R8
                RSUB    EXPECT, 1

                ; --- 0x05: A: mounted: the key stays
                MOVE    0x05, R7
                MOVE    T_X1, R8
                RSUB    SETTXT, 1
                MOVE    T_PC10, R8
                MOVE    S_A360, R9
                RSUB    BROWSE, 1
                MOVE    PC_OPTM_G_FDA, R10
                RSUB    PL_CALL, 1
                CMP     0, R8
                RBRA    FAIL, !Z
                MOVE    0, R1
                RSUB    SETUP_ONCE, 1
                MOVE    T_X1, R8
                RSUB    EXPECT, 1
                MOVE    CFGS_DIRTY, R0
                CMP     0, @R0
                RBRA    FAIL, !Z

                ; --- 0x06: FD_SETUP fails for C:: no key
                MOVE    0x06, R7
                MOVE    SETUP_RET, R0
                MOVE    1, @R0
                MOVE    T_PC10, R8
                MOVE    S_HD20, R9
                RSUB    BROWSE, 1
                RSUB    PL_HDC, 1
                CMP     1, R8
                RBRA    FAIL, !Z
                CMP     ERR_FD_FRAG, R9
                RBRA    FAIL, !Z
                MOVE    T_M6, R8
                RSUB    EXPECT, 1
                MOVE    SETUP_RET, R0
                MOVE    0, @R0

                ; --- 0x07: HDC_SAVE at the root
                MOVE    0x07, R7
                MOVE    T_ROOT, R8
                MOVE    S_ROOTTXT, R9
                RSUB    BROWSE, 1
                XOR     R8, R8
                RSUB    SAVE_CALL, 1
                MOVE    T_X7, R8
                RSUB    EXPECT, 1
                RSUB    AD_KEPT, 1

                ; --- 0x08: a path of 127 characters
                MOVE    0x08, R7
                MOVE    T_D111, R8
                MOVE    S_X, R9
                RSUB    BROWSE, 1
                XOR     R8, R8
                RSUB    SAVE_CALL, 1
                MOVE    T_X111, R8
                RSUB    EXPECT, 1
                RSUB    AD_KEPT, 1

                ; --- 0x09: 128 characters: no key
                MOVE    0x09, R7
                MOVE    T_D112, R8
                MOVE    S_X, R9
                RSUB    BROWSE, 1
                XOR     R8, R8
                RSUB    SAVE_CALL, 1
                MOVE    T_M6, R8
                RSUB    EXPECT, 1
                RSUB    AD_KEPT, 1

                ; --- 0x0A: HDC_SAVE for an empty drive (R8 not 0): no key, no walk
                MOVE    0x0A, R7
                MOVE    T_X1, R8
                RSUB    SETTXT, 1
                MOVE    T_DEV, R0               ; a current directory to keep
                ADD     FAT32$DEV_AD_1STCLUS_LO, R0
                MOVE    0x7777, @R0
                MOVE    1, R8
                RSUB    SAVE_CALL, 1
                MOVE    T_M6, R8
                RSUB    EXPECT, 1
                MOVE    T_DEV, R0
                ADD     FAT32$DEV_AD_1STCLUS_LO, R0
                CMP     0x7777, @R0
                RBRA    FAIL, !Z
                MOVE    T_ROOT, R8              ; a valid directory again
                RSUB    CD, 1

                ; --- 0x11: HDC_RESTORE: the long name, as the menu mounts it
                MOVE    0x11, R7
                MOVE    T_X2, R8
                RSUB    RS_CALL, 1
                MOVE    2, R1
                RSUB    SETUP_ONCE, 1
                MOVE    SETUP_HDL, R0           ; (the Shell's handle of C:)
                CMP     HANDLE_RM_FILE3, @R0
                RBRA    FAIL, !Z
                RSUB    RS_OK, 1
                MOVE    T_X2, R8
                RSUB    EXPECT, 1
                MOVE    CFGS_DIRTY, R0          ; (the same path: no change)
                CMP     0, @R0
                RBRA    FAIL, !Z
                MOVE    T_MSLOT, R0
                CMP     1, @R0
                RBRA    FAIL, !Z

                ; --- 0x12: another case: mounted, the key as it was
                MOVE    0x12, R7
                MOVE    T_R_CASE, R8
                RSUB    RS_CALL, 1
                MOVE    2, R1
                RSUB    SETUP_ONCE, 1
                RSUB    RS_OK, 1
                MOVE    T_R_CASE, R8
                RSUB    EXPECT, 1
                MOVE    CFGS_DIRTY, R0
                CMP     0, @R0
                RBRA    FAIL, !Z

                ; --- 0x13: a missing file
                MOVE    0x13, R7
                MOVE    T_R_NF, R8
                MOVE    HDC_S_NF, R9
                RSUB    RS_BAD, 1

                ; --- 0x14: the wrong size
                MOVE    0x14, R7
                MOVE    T_R_SMALL, R8
                MOVE    ERR_HD_SIZE, R9
                RSUB    RS_BAD, 1

                ; --- 0x15: no card in slot 0
                MOVE    0x15, R7
                MOVE    T_R_SD0, R8
                MOVE    HDC_S_NF, R9
                RSUB    RS_BAD, 1
                MOVE    T_MSLOT, R0
                CMP     0, @R0
                RBRA    FAIL, !Z

                ; --- 0x16-0x1A: bad card prefixes
                MOVE    0x16, R7
                MOVE    T_R_BAD, R6
_C16            MOVE    @R6++, R8
                MOVE    HDC_S_NF, R9
                RSUB    RS_BAD, 1
                ADD     1, R7
                CMP     0, @R6
                RBRA    _C16, !Z

                ; --- 0x1B: no key: nothing happens
                MOVE    0x1B, R7
                MOVE    T_M6, R8
                RSUB    RS_CALL, 1
                RSUB    SETUP_NONE, 1
                MOVE    T_CSRW_N, R0
                CMP     0, @R0
                RBRA    FAIL, !Z
                MOVE    T_PS_N, R0
                CMP     0, @R0
                RBRA    FAIL, !Z
                MOVE    HDC_PEND, R0
                CMP     0, @R0
                RBRA    FAIL, !Z
                MOVE    T_M6, R8
                RSUB    EXPECT, 1
                MOVE    CFGS_DIRTY, R0
                CMP     0, @R0
                RBRA    FAIL, !Z

                ; --- 0x1C: FD_SETUP fails at the start-up
                MOVE    0x1C, R7
                MOVE    SETUP_RET, R0
                MOVE    1, @R0
                MOVE    T_X1, R8
                MOVE    ERR_FD_FRAG, R9
                RSUB    RS_BAD, 1
                MOVE    SETUP_RET, R0
                MOVE    0, @R0

                ; --- 0x21: HDC_PEND_APPLY: no menu yet
                MOVE    0x21, R7
                MOVE    T_X2, R8                ; the long name pending
                RSUB    RS_CALL, 1
                RSUB    RS_OK, 1
                RSUB    HEAP_FILL, 1
                MOVE    OPTM_HEAP, R0
                MOVE    0, @R0
                RSUB    PA_CALL, 1
                MOVE    HDC_PEND, R0
                CMP     1, @R0
                RBRA    FAIL, !Z

                ; --- 0x22: the name in its buffer, the flag 0, nothing else touched
                MOVE    0x22, R7
                MOVE    OPTM_HEAP, R0
                MOVE    T_HEAP, @R0
                RSUB    PA_CALL, 1
                MOVE    HDC_PEND, R0
                CMP     0, @R0
                RBRA    FAIL, !Z
                MOVE    S_MYHD, R8
                RSUB    SLOT_IS, 1
                RSUB    PA_CALL, 1              ; once only
                MOVE    S_MYHD, R8
                RSUB    SLOT_IS, 1

                ; --- 0x23: a long name: OPTM_DX - 1 characters
                MOVE    0x23, R7
                RSUB    HEAP_FILL, 1
                MOVE    T_P_LONG, R8
                MOVE    HDC_PATH, R9
                SYSCALL(strcpy, 1)
                MOVE    HDC_PEND, R0
                MOVE    1, @R0
                RSUB    PA_CALL, 1
                MOVE    S_CUT, R8
                RSUB    SLOT_IS, 1

                ; --- 0x24: no "/" in the path: all of it
                MOVE    0x24, R7
                RSUB    HEAP_FILL, 1
                MOVE    S_HD20, R8
                MOVE    HDC_PATH, R9
                SYSCALL(strcpy, 1)
                MOVE    HDC_PEND, R0
                MOVE    1, @R0
                RSUB    PA_CALL, 1
                MOVE    S_HD20, R8
                RSUB    SLOT_IS, 1

                ; --- 0x25: other vdrive and submenu counts
                MOVE    0x25, R7
                MOVE    VDRIVES_NUM, R0
                MOVE    1, @R0
                MOVE    OPTM_SCOUNT, R0
                MOVE    1, @R0                  ; C:'s buffer: 1 + 1 + 2 = 4
                MOVE    T_SLOT_B, R0
                MOVE    120, @R0
                RSUB    HEAP_FILL, 1
                MOVE    HDC_PEND, R0
                MOVE    1, @R0
                RSUB    PA_CALL, 1
                MOVE    S_HD20, R8
                RSUB    SLOT_IS, 1
                MOVE    VDRIVES_NUM, R0
                MOVE    0, @R0
                MOVE    OPTM_SCOUNT, R0
                MOVE    4, @R0
                MOVE    T_SLOT_B, R0
                MOVE    180, @R0

                ; --- 0x31: SPACE on C: (mounted): the key goes
                MOVE    0x31, R7
                MOVE    PC_OSM_HDC_LN, R8
                RSUB    EJ_CALL, 1
                MOVE    T_M6, R8
                RSUB    EXPECT, 1
                MOVE    T_CSRW_N, R0            ; the line idle again
                CMP     1, @R0
                RBRA    FAIL, !Z
                MOVE    T_CSRW_VAL, R0
                CMP     CRTROM_CSR_ST_IDLE, @R0
                RBRA    FAIL, !Z

                ; --- 0x32: SPACE on A:: the key stays
                MOVE    0x32, R7
                MOVE    PC_OSM_FDA_LN, R8
                RSUB    EJ_CALL, 1
                MOVE    T_X1, R8
                RSUB    EXPECT, 1

                ; --- 0x33: SPACE held (no new press) on C:: the key stays
                MOVE    0x33, R7
                MOVE    PC_UNMNT_PREV, R0
                MOVE    M2M$KEY_SPACE, @R0
                MOVE    PC_OSM_HDC_LN, R8
                RSUB    EJ_CALL2, 1
                MOVE    T_X1, R8
                RSUB    EXPECT, 1

                ; --- 0x34: HANDLE_CORE_IO applies a pending name (menu closed)
                MOVE    0x34, R7
                RSUB    HEAP_FILL, 1
                MOVE    S_HD20, R8
                MOVE    HDC_PATH, R9
                SYSCALL(strcpy, 1)
                MOVE    HDC_PEND, R0
                MOVE    1, @R0
                MOVE    M2M$CSR, R0
                MOVE    0, @R0
                RSUB    SAVEREGS, 1
                RSUB    HANDLE_CORE_IO, 1
                RSUB    CMPREGS, 1
                MOVE    S_HD20, R8
                RSUB    SLOT_IS, 1

                MOVE    S_PASS, R8
                SYSCALL(puts, 1)
                HALT

FAIL            MOVE    S_FAIL, R8              ; the case, then (for a diagnosis) the
                SYSCALL(puts, 1)                ; calls of FD_SETUP, the CSR and the
                MOVE    R7, R8                  ; screen, HDC_PEND, the text
                SYSCALL(puthex, 1)
                MOVE    SETUP_CNT, R8
                RSUB    _FAIL_H, 1
                MOVE    T_CSRW_N, R8
                RSUB    _FAIL_H, 1
                MOVE    T_PS_N, R8
                RSUB    _FAIL_H, 1
                MOVE    HDC_PEND, R8
                RSUB    _FAIL_H, 1
                SYSCALL(crlf, 1)
                MOVE    CFGS_BUF, R8
                SYSCALL(puts, 1)
                HALT
_FAIL_H         MOVE    R8, R0
                MOVE    S_SP, R8
                SYSCALL(puts, 1)
                MOVE    @R0, R8
                SYSCALL(puthex, 1)
                RET

; ---------------------------------------------------------------------------- helpers

; SETTXT: the settings text := the string R8, CFGS_DIRTY := 0
SETTXT          MOVE    CFGS_BUF, R9
                SYSCALL(strcpy, 1)
                SYSCALL(strlen, 1)
                MOVE    CFGS_LEN, R0
                MOVE    R9, @R0
                MOVE    CFGS_DIRTY, R0
                MOVE    0, @R0
                RET

; EXPECT: the settings text must be the string R8
EXPECT          MOVE    CFGS_BUF, R9
                SYSCALL(strcmp, 1)
                CMP     0, R10
                RBRA    FAIL, !Z
                RET

; CD: the current directory := R8 (absolute); T_AD := its cluster
CD              MOVE    R8, R9
                MOVE    T_DEV, R8
                XOR     R10, R10
                SYSCALL(f32_cd, 1)
                CMP     0, R9
                RBRA    FAIL, !Z
                MOVE    T_DEV, R0
                ADD     FAT32$DEV_AD_1STCLUS_LO, R0
                MOVE    T_AD, R1
                MOVE    @R0++, @R1++
                MOVE    @R0, @R1
                RET

; BROWSE: what the file browser leaves: the directory R8 current, the file R9 opened by its
; name in it (HANDLE_RM_FILE3)
BROWSE          MOVE    R9, R2
                RSUB    CD, 1
                MOVE    T_DEV, R8
                MOVE    HANDLE_RM_FILE3, R9
                MOVE    R2, R10
                XOR     R11, R11
                SYSCALL(f32_fopen, 1)
                CMP     0, R10
                RBRA    FAIL, !Z
                RET

; AD_KEPT: the current directory is still T_AD
AD_KEPT         MOVE    T_DEV, R0
                ADD     FAT32$DEV_AD_1STCLUS_LO, R0
                MOVE    T_AD, R1
                CMP     @R0++, @R1++
                RBRA    FAIL, !Z
                CMP     @R0, @R1
                RBRA    FAIL, !Z
                RET

; PL_HDC / PL_CALL: PREP_LOAD_IMAGE(HANDLE_RM_FILE3, CTX_LOAD_ROM, C: / group R10), MODE
; 0x55 before (it must be 0 after: the drive switched off first), R10..R12 checked, R9 = 0
; when it succeeds
PL_HDC          MOVE    PC_OPTM_G_HDC, R10
PL_CALL         MOVE    R10, R3
                MOVE    FD_MODE_ADDR, R0
                MOVE    0x0055, @R0
                MOVE    SETUP_CNT, R0
                MOVE    0, @R0
                MOVE    HANDLE_RM_FILE3, R8
                MOVE    CTX_LOAD_ROM, R9
                MOVE    0x4711, R11
                MOVE    0x4712, R12
                RSUB    PREP_LOAD_IMAGE, 1
                CMP     R3, R10
                RBRA    FAIL, !Z
                CMP     0, R8                   ; OK: R9 = 0 (the image type)
                RBRA    _PLC_1, !Z
                CMP     0, R9
                RBRA    FAIL, !Z
_PLC_1
                CMP     0x4711, R11
                RBRA    FAIL, !Z
                CMP     0x4712, R12
                RBRA    FAIL, !Z
                MOVE    FD_MODE_ADDR, R0
                CMP     0, @R0
                RBRA    FAIL, !Z
                RET

; SAVE_CALL: HDC_SAVE(R8, HANDLE_RM_FILE3) with the text "menu=6" before, registers checked
SAVE_CALL       MOVE    R8, R2
                MOVE    T_M6, R8
                RSUB    SETTXT, 1
                RSUB    SAVEREGS, 1
                MOVE    R2, R8
                MOVE    HANDLE_RM_FILE3, R10
                RSUB    HDC_SAVE, 1
                CMP     R2, R8
                RBRA    FAIL, !Z
                CMP     HANDLE_RM_FILE3, R10
                RBRA    FAIL, !Z
                CMP     0x1239, R9
                RBRA    FAIL, !Z
                CMP     0x123B, R11
                RBRA    FAIL, !Z
                CMP     0x123C, R12
                RBRA    FAIL, !Z
                RET

; RS_CALL: the text := R8, then HDC_RESTORE (registers checked) with fresh records:
; HDC_PEND garbage, MODE 0x55, no FD_SETUP, no CSR write, no message
RS_CALL         RSUB    SETTXT, 1
                MOVE    HDC_PEND, R0
                MOVE    0x0055, @R0
                MOVE    FD_MODE_ADDR, R0
                MOVE    0x0055, @R0
                MOVE    SETUP_CNT, R0
                MOVE    0, @R0
                MOVE    T_CSRW_N, R0
                MOVE    0, @R0
                MOVE    T_PS_N, R0
                MOVE    0, @R0
                MOVE    T_MSLOT, R0
                MOVE    0xFFFF, @R0
                RSUB    SAVEREGS, 1
                RSUB    HDC_RESTORE, 1
                RSUB    CMPREGS, 1
                RET

; RS_OK: the start-up mount's effects: STATUS ok on C:'s device, the name pending, no message
RS_OK           MOVE    T_CSRW_N, R0
                CMP     1, @R0
                RBRA    FAIL, !Z
                MOVE    T_CSRW_DEV, R0
                CMP     PC_DEV_HDC, @R0
                RBRA    FAIL, !Z
                MOVE    T_CSRW_REG, R0
                CMP     CRTROM_CSR_STATUS, @R0
                RBRA    FAIL, !Z
                MOVE    T_CSRW_VAL, R0
                CMP     CRTROM_CSR_ST_OK, @R0
                RBRA    FAIL, !Z
                MOVE    HDC_PEND, R0
                CMP     1, @R0
                RBRA    FAIL, !Z
                MOVE    T_PS_N, R0
                CMP     0, @R0
                RBRA    FAIL, !Z
                MOVE    FD_MODE_ADDR, R0        ; (the stub FD_SETUP sets no mode)
                CMP     0, @R0
                RBRA    FAIL, !Z
                RET

; RS_BAD: HDC_RESTORE with the text R8 fails with the reason R9: the message (four strings:
; the title, the path, a new line, the reason), no STATUS ok, nothing pending, no key
RS_BAD          MOVE    R9, R2
                RSUB    RS_CALL, 1
                MOVE    T_CSRW_N, R0
                CMP     0, @R0
                RBRA    FAIL, !Z
                MOVE    HDC_PEND, R0
                CMP     0, @R0
                RBRA    FAIL, !Z
                MOVE    T_PS_N, R0
                CMP     4, @R0
                RBRA    FAIL, !Z
                MOVE    T_PS, R0
                CMP     HDC_S_ERR, @R0++
                RBRA    FAIL, !Z
                CMP     HDC_PATH, @R0++
                RBRA    FAIL, !Z
                ADD     1, R0
                CMP     R2, @R0
                RBRA    FAIL, !Z
                MOVE    T_M6, R8
                RSUB    EXPECT, 1
                RET

; HEAP_FILL: the menu's buffers := 0x00AA (T_HEAP, 300 words), the flag of C:'s buffer
; (T_SLOT_B) := 1
HEAP_FILL       MOVE    T_HEAP, R0
                MOVE    300, R1
_HF_L           MOVE    0x00AA, @R0++
                SUB     1, R1
                RBRA    _HF_L, !Z
                MOVE    T_HEAP, R0              ; the flag of C:'s buffer: not 0
                MOVE    T_SLOT_B, R1
                ADD     @R1, R0
                ADD     29, R0
                MOVE    1, @R0
                RET

; PA_CALL: HDC_PEND_APPLY, registers checked
PA_CALL         RSUB    SAVEREGS, 1
                RSUB    HDC_PEND_APPLY, 1
                RSUB    CMPREGS, 1
                RET

; SLOT_IS: C:'s buffer (T_HEAP + T_SLOT_B) holds the string R8 and its zero, the flag
; (word 29) is 0, the words in front of and behind the buffer are untouched
SLOT_IS         MOVE    T_HEAP, R9
                MOVE    T_SLOT_B, R0
                ADD     @R0, R9
                MOVE    R9, R4
                SYSCALL(strcmp, 1)
                CMP     0, R10
                RBRA    FAIL, !Z
                MOVE    R4, R0
                ADD     29, R0
                CMP     0, @R0++
                RBRA    FAIL, !Z
                CMP     0x00AA, @R0
                RBRA    FAIL, !Z
                CMP     0x00AA, @--R4
                RBRA    FAIL, !Z
                RET

; EJ_CALL: HANDLE_CORE_IO with the menu open, the cursor on line R8, SPACE pressed (a new
; press), the text "hdc=..." (T_X1) before; EJ_CALL2: without resetting PC_UNMNT_PREV
EJ_CALL         MOVE    PC_UNMNT_PREV, R0
                MOVE    0, @R0
EJ_CALL2        MOVE    OPTM_CUR_SEL, R0
                MOVE    R8, @R0
                MOVE    T_X1, R8
                RSUB    SETTXT, 1
                MOVE    M2M$CSR, R0
                MOVE    M2M$CSR_OSM, @R0
                MOVE    PC_SUB_ACTIVE, R0
                MOVE    0, @R0
                MOVE    M2M$KEYBOARD, R0        ; low active: SPACE down
                MOVE    0xFFDF, @R0
                MOVE    KEYB_PRESSED, R0
                MOVE    0, @R0
                MOVE    HDC_PEND, R0
                MOVE    0, @R0
                MOVE    T_CSRW_N, R0
                MOVE    0, @R0
                RSUB    SAVEREGS, 1
                RSUB    HANDLE_CORE_IO, 1
                RSUB    CMPREGS, 1
                MOVE    M2M$CSR, R0
                MOVE    0, @R0
                RET

; SAVEREGS: R8..R12 := known values; CMPREGS: they must be unchanged
SAVEREGS        MOVE    0x1238, R8
                MOVE    0x1239, R9
                MOVE    0x123A, R10
                MOVE    0x123B, R11
                MOVE    0x123C, R12
                RET
CMPREGS         CMP     0x1238, R8
                RBRA    FAIL, !Z
                CMP     0x1239, R9
                RBRA    FAIL, !Z
                CMP     0x123A, R10
                RBRA    FAIL, !Z
                CMP     0x123B, R11
                RBRA    FAIL, !Z
                CMP     0x123C, R12
                RBRA    FAIL, !Z
                RET

; SETUP_ONCE: FD_SETUP was called once, for drive R1; SETUP_NONE: not at all
SETUP_ONCE      MOVE    SETUP_CNT, R0
                CMP     1, @R0
                RBRA    FAIL, !Z
                MOVE    SETUP_DRV, R0
                CMP     R1, @R0
                RBRA    FAIL, !Z
                RET
SETUP_NONE      MOVE    SETUP_CNT, R0
                CMP     0, @R0
                RBRA    FAIL, !Z
                RET

; ---------------------------------------------------------------------------- stubs

; FD_SETUP: R8 handle, R9 drive -> R8 = SETUP_RET; R9 clobbered, R10..R12 preserved; on
; success the handle is moved to the end of the file, as the real one does
FD_SETUP        MOVE    R9, @--SP
                MOVE    SETUP_HDL, R9
                MOVE    R8, @R9
                MOVE    @SP++, R9
                MOVE    R8, @--SP
                MOVE    SETUP_DRV, R8
                MOVE    R9, @R8
                MOVE    SETUP_CNT, R8
                ADD     1, @R8
                MOVE    @SP++, R8
                MOVE    SETUP_RET, R9
                CMP     0, @R9
                RBRA    _FDS_ERR, !Z
                MOVE    R10, @--SP
                MOVE    R8, R9
                ADD     FAT32$FDH_SIZE_LO, R9
                MOVE    @R9, R9
                MOVE    R8, R10
                ADD     FAT32$FDH_SIZE_HI, R10
                MOVE    @R10, R10
                SYSCALL(f32_fseek, 1)
                MOVE    @SP++, R10
_FDS_ERR        MOVE    SETUP_RET, R8
                MOVE    @R8, R8
                MOVE    0x5A5A, R9              ; (clobbered, as its contract says)
                RET

; SDC$SLOT: the device's slot (T_SLOT); SDC$MOUNT: slot R8 (recorded) -> R8 = T_DEV, R9 = 0,
; but slot 0 has no card (R9 = 0xEE10); as the real one, any other slot mounts slot 1
SDC$SLOT        MOVE    T_SLOT, R8
                MOVE    @R8, R8
                RET
SDC$MOUNT       MOVE    T_MSLOT, R9
                MOVE    R8, @R9
                XOR     R9, R9
                CMP     0, R8
                RBRA    _SDCM_1, !Z
                MOVE    0xEE10, R9
_SDCM_1         MOVE    T_DEV, R8
                RET

CRTROM_CSR_W    MOVE    R0, @--SP
                MOVE    T_CSRW_N, R0
                ADD     1, @R0
                MOVE    T_CSRW_DEV, R0
                MOVE    R8, @R0
                MOVE    T_CSRW_REG, R0
                MOVE    R9, @R0
                MOVE    T_CSRW_VAL, R0
                MOVE    R10, @R0
                MOVE    @SP++, R0
                RET
CRTROM_CSR_R    MOVE    CRTROM_CSR_PT_OK, R10   ; every drive mounted
                RET

SCR$PRINTSTR    MOVE    R0, @--SP
                MOVE    R1, @--SP
                MOVE    T_PS_N, R0
                MOVE    @R0, R1
                ADD     1, @R0
                CMP     4, R1
                RBRA    _SPS_R, !N              ; (R1 >= 4)
                ADD     T_PS, R1
                MOVE    R8, @R1
_SPS_R          MOVE    @SP++, R1
                MOVE    @SP++, R0
                RET
FRAME_FULLSCR   RET
SCR$OSM_M_ON    RET
SCR$OSM_OFF     RET
WAIT333MS       RET
PC_RTC_WB       RET

; what cfgstr.asm's file functions (CFGS_SIZE, not called here) refer to
FAT32$PB_SIZE   .EQU    1
FAT32$FLUSH_OWNER RET
FAT32$W_SETSIZE RET

; ---------------------------------------------------------------------------- data

T_M6            .ASCII_P "menu=6"
                .DW      0x000A, 0
T_X1            .ASCII_P "menu=6"
                .DW      0x000A
                .ASCII_P "hdc=SD1:/pc10/hd20.img"
                .DW      0x000A, 0
T_X2            .ASCII_P "menu=6"
                .DW      0x000A
                .ASCII_P "hdc=SD1:/pc10/Long Folder Name/My Hard Disk.img"
                .DW      0x000A, 0
T_X3            .ASCII_P "menu=6"
                .DW      0x000A
                .ASCII_P "hdc=SD0:/pc10/hd20.img"
                .DW      0x000A, 0
T_X7            .ASCII_P "menu=6"
                .DW      0x000A
                .ASCII_P "hdc=SD1:/root.txt"
                .DW      0x000A, 0
T_R_CASE        .ASCII_P "menu=6"
                .DW      0x000A
                .ASCII_P "hdc=SD1:/PC10/HD20.IMG"
                .DW      0x000A, 0
T_R_NF          .ASCII_P "menu=6"
                .DW      0x000A
                .ASCII_P "hdc=SD1:/pc10/nothere.img"
                .DW      0x000A, 0
T_R_SMALL       .ASCII_P "menu=6"
                .DW      0x000A
                .ASCII_P "hdc=SD1:/pc10/small.img"
                .DW      0x000A, 0
T_R_SD0         .ASCII_P "menu=6"
                .DW      0x000A
                .ASCII_P "hdc=SD0:/pc10/hd20.img"
                .DW      0x000A, 0
T_R_B1          .ASCII_P "menu=6"
                .DW      0x000A
                .ASCII_P "hdc=/pc10/hd20.img"
                .DW      0x000A, 0
T_R_B2          .ASCII_P "menu=6"
                .DW      0x000A
                .ASCII_P "hdc=SD2:/pc10/hd20.img"
                .DW      0x000A, 0
T_R_B3          .ASCII_P "menu=6"
                .DW      0x000A
                .ASCII_P "hdc=SD1;/pc10/hd20.img"
                .DW      0x000A, 0
T_R_B4          .ASCII_P "menu=6"
                .DW      0x000A
                .ASCII_P "hdc=XD1:/pc10/hd20.img"
                .DW      0x000A, 0
T_R_B5          .ASCII_P "menu=6"
                .DW      0x000A
                .ASCII_P "hdc=SX1:/pc10/hd20.img"
                .DW      0x000A, 0
T_R_BAD         .DW      T_R_B1, T_R_B2, T_R_B3, T_R_B4, T_R_B5, 0
T_P_LONG        .ASCII_W "SD1:/x/ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.img"
S_CUT           .ASCII_W "ABCDEFGHIJKLMNOPQRSTUVWXYZ012"
T_ROOT          .ASCII_W "/"
T_PC10          .ASCII_W "/pc10"
T_LONG          .ASCII_W "/pc10/Long Folder Name"
S_HD20          .ASCII_W "hd20.img"
S_MYHD          .ASCII_W "My Hard Disk.img"
S_SMALL         .ASCII_W "small.img"
S_A360          .ASCII_W "a360.img"
S_ROOTTXT       .ASCII_W "root.txt"
S_X             .ASCII_W "x.img"
NEWLINE         .ASCII_W "\n"
S_PASS          .ASCII_W "HDC TEST: PASS\n"
S_FAIL          .ASCII_W "HDC TEST: FAIL "
S_SP            .ASCII_W " "

#include "hdc_names.asm"
#include "hdc_pl.asm"
#include "hdc_io.asm"
#include "pc_hdc.asm"
#include "cfgstr.asm"

; ---------------------------------------------------------------------------- variables

T_DEV           .BLOCK  FAT32$DEV_STRUCT_SIZE
HANDLE_RM_FILE3 .BLOCK  FAT32$FDH_STRUCT_SIZE
T_AD            .BLOCK  2
T_SLOT          .DW     1
T_MSLOT         .BLOCK  1
T_SLOT_B        .DW     180                     ; C:'s buffer: (0 + 4 + 2) x 30
SETUP_CNT       .BLOCK  1
SETUP_HDL       .BLOCK  1
SETUP_DRV       .BLOCK  1
SETUP_RET       .DW     0
T_CSRW_N        .BLOCK  1
T_CSRW_DEV      .BLOCK  1
T_CSRW_REG      .BLOCK  1
T_CSRW_VAL      .BLOCK  1
T_PS_N          .BLOCK  1
T_PS            .BLOCK  4
OPTM_HEAP       .BLOCK  1
VDRIVES_NUM     .DW     0
OPTM_SCOUNT     .DW     4
SCR$OSM_O_DX    .DW     T_DX
OPTM_CUR_SEL    .BLOCK  1
KEYB_PRESSED    .BLOCK  1
PC_UNMNT_PREV   .BLOCK  1
PC_SUB_ACTIVE   .BLOCK  1
OPTM_ICOUNT     .BLOCK  1
CFGS_PB         .BLOCK  1
CFGS_LEN        .BLOCK  1
CFGS_DIRTY      .BLOCK  1
CFGS_RESET      .BLOCK  1
CFGS_BUF        .BLOCK  CFGS_MAX
HDC_PEND        .BLOCK  1
HDC_PATH        .BLOCK  127
HDC_PATH_Z      .BLOCK  1
HDC_FDH         .BLOCK  FAT32$FDH_STRUCT_SIZE
HDC_DE          .BLOCK  FAT32$DE_STRUCT_SIZE
T_HEAP          .BLOCK  300
