; prepload_test.asm - PREP_LOAD_IMAGE of CORE/m2m-rom/m2m-rom.asm (the image checks of A:, B:
; and C:) on the QNICE emulator's headless batch mode. run_prepload.sh extracts the function
; with FD_SEL and its tables into prepload_fn.asm and the core's constants into
; prepload_const.asm; FD_SETUP (the extent map, FAT32) is a stub that records its arguments.
; M2M$RAMROM_DEV/4KWIN are RAM words here, the device window 0x8000 is RAM, so the device and
; the drive's MODE register are visible.
;
; Cases: C: of 21,411,840 bytes taken (FD_SETUP with drive 2, the handle; device C_DEV_PC_HDC);
; C: one sector shorter or longer, another high word, a 360K image: "not a PC20-III image";
; A: 360K and B: 720K taken (drives 0, 1); A: of the hard disk's size: the floppy message;
; another menu group, another context: nothing done; FD_SETUP failing: its message. Every
; call: the drive is switched off first (MODE := 0) and R10..R12 are preserved. Prints
; "PREPLOAD TEST: PASS" or "FAIL <case>".

#include "sysdef.asm"
#include "monitor.def"
#include "prepload_const.asm"

M2M$RAMROM_DEV  .EQU    0xA000                  ; RAM words standing in for the registers
M2M$RAMROM_4KWIN .EQU   0xA001
CTX_LOAD_ROM    .EQU    0x0200
FD_MODE_ADDR    .EQU    0x8000

                .ORG    0x9000

                MOVE    1, R7                   ; 1: C: of the right size
                MOVE    0x0146, R1
                MOVE    0xB800, R2
                MOVE    PC_OPTM_G_HDC, R3
                RSUB    CALL, 1
                CMP     0, R8
                RBRA    FAIL, !Z
                MOVE    2, R1                   ; FD_SETUP(handle, 2), device C:
                RSUB    SETUP_ONCE, 1
                MOVE    M2M$RAMROM_DEV, R0
                CMP     PC_DEV_HDC, @R0
                RBRA    FAIL, !Z

                MOVE    2, R7                   ; 2: one sector short
                MOVE    0x0146, R1
                MOVE    0xB600, R2
                RSUB    HD_BAD, 1
                MOVE    3, R7                   ; 3: one sector more
                MOVE    0x0146, R1
                MOVE    0xBA00, R2
                RSUB    HD_BAD, 1
                MOVE    4, R7                   ; 4: another high word
                MOVE    0x0046, R1
                MOVE    0xB800, R2
                RSUB    HD_BAD, 1
                MOVE    5, R7                   ; 5: a 360K image as C:
                MOVE    0x0005, R1
                MOVE    0xA000, R2
                RSUB    HD_BAD, 1

                MOVE    6, R7                   ; 6: A: 360K
                MOVE    0x0005, R1
                MOVE    0xA000, R2
                MOVE    PC_OPTM_G_FDA, R3
                RSUB    CALL, 1
                CMP     0, R8
                RBRA    FAIL, !Z
                MOVE    0, R1
                RSUB    SETUP_ONCE, 1
                MOVE    M2M$RAMROM_DEV, R0
                CMP     PC_DEV_FDA, @R0
                RBRA    FAIL, !Z

                MOVE    7, R7                   ; 7: B: 720K
                MOVE    0x000B, R1
                MOVE    0x4000, R2
                MOVE    PC_OPTM_G_FDB, R3
                RSUB    CALL, 1
                CMP     0, R8
                RBRA    FAIL, !Z
                MOVE    1, R1
                RSUB    SETUP_ONCE, 1
                MOVE    M2M$RAMROM_DEV, R0
                CMP     PC_DEV_FDB, @R0
                RBRA    FAIL, !Z

                MOVE    8, R7                   ; 8: A: of the hard disk's size
                MOVE    0x0146, R1
                MOVE    0xB800, R2
                MOVE    PC_OPTM_G_FDA, R3
                RSUB    CALL, 1
                CMP     3, R8
                RBRA    FAIL, !Z
                CMP     ERR_FD_SIZE, R9
                RBRA    FAIL, !Z
                RSUB    SETUP_NONE, 1

                MOVE    9, R7                   ; 9: another group: nothing
                MOVE    0x0146, R1
                MOVE    0xB800, R2
                MOVE    PC_OPTM_G_MEM, R3
                MOVE    FD_MODE_ADDR, R4
                MOVE    0x0055, @R4
                RSUB    CALL_NOMODE, 1
                CMP     0, R8
                RBRA    FAIL, !Z
                CMP     0, R9
                RBRA    FAIL, !Z
                RSUB    SETUP_NONE, 1
                MOVE    FD_MODE_ADDR, R0
                CMP     0x0055, @R0
                RBRA    FAIL, !Z

                MOVE    10, R7                  ; 10: another context: nothing
                MOVE    CTX_ARG, R0
                MOVE    0x0100, @R0
                MOVE    PC_OPTM_G_HDC, R3
                RSUB    CALL_NOMODE, 1
                CMP     0, R8
                RBRA    FAIL, !Z
                RSUB    SETUP_NONE, 1
                MOVE    CTX_ARG, R0
                MOVE    CTX_LOAD_ROM, @R0

                MOVE    11, R7                  ; 11: FD_SETUP fails (fragmented)
                MOVE    SETUP_RET, R0
                MOVE    1, @R0
                MOVE    PC_OPTM_G_HDC, R3
                RSUB    CALL, 1
                CMP     0, R8
                RBRA    FAIL, Z
                CMP     ERR_FD_FRAG, R9
                RBRA    FAIL, !Z
                MOVE    2, R1
                RSUB    SETUP_ONCE, 1

                MOVE    S_PASS, R8
                SYSCALL(puts, 1)
                HALT

FAIL            MOVE    S_FAIL, R8
                SYSCALL(puts, 1)
                MOVE    R7, R8
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)
                HALT

; HD_BAD: C: with the size R1:R2 must be refused with ERR_HD_SIZE, FD_SETUP not called
HD_BAD          MOVE    PC_OPTM_G_HDC, R3
                RSUB    CALL, 1
                CMP     3, R8
                RBRA    FAIL, !Z
                CMP     ERR_HD_SIZE, R9
                RBRA    FAIL, !Z
                RSUB    SETUP_NONE, 1
                RET

; CALL: the handle's size := R1 (hi) : R2 (lo), MODE := 0x55, PREP_LOAD_IMAGE(handle,
; CTX_ARG, group R3) with R10..R12 checked; then MODE must be 0 (the drive switched off)
CALL            MOVE    FD_MODE_ADDR, R4
                MOVE    0x0055, @R4
                RSUB    CALL_NOMODE, 1
                MOVE    FD_MODE_ADDR, R4
                CMP     0, @R4
                RBRA    FAIL, !Z
                RET
CALL_NOMODE     MOVE    HANDLE, R0
                ADD     FAT32$FDH_SIZE_LO, R0
                MOVE    R2, @R0
                MOVE    HANDLE, R0
                ADD     FAT32$FDH_SIZE_HI, R0
                MOVE    R1, @R0
                MOVE    SETUP_CNT, R0
                MOVE    0, @R0
                MOVE    HANDLE, R8
                MOVE    CTX_ARG, R9
                MOVE    @R9, R9
                MOVE    R3, R10
                MOVE    0x4711, R11
                MOVE    0x4712, R12
                RSUB    PREP_LOAD_IMAGE, 1
                CMP     R3, R10
                RBRA    FAIL, !Z
                CMP     0x4711, R11
                RBRA    FAIL, !Z
                CMP     0x4712, R12
                RBRA    FAIL, !Z
                RET

; SETUP_ONCE: FD_SETUP was called once, for the handle and drive R1
SETUP_ONCE      MOVE    SETUP_CNT, R0
                CMP     1, @R0
                RBRA    FAIL, !Z
                MOVE    SETUP_DRV, R0
                CMP     R1, @R0
                RBRA    FAIL, !Z
                MOVE    SETUP_HDL, R0
                CMP     HANDLE, @R0
                RBRA    FAIL, !Z
                RET
SETUP_NONE      MOVE    SETUP_CNT, R0
                CMP     0, @R0
                RBRA    FAIL, !Z
                RET

; the stub: R8 handle, R9 drive -> R8 = SETUP_RET; R9 clobbered, R10..R12 preserved
FD_SETUP        MOVE    R9, @--SP
                MOVE    SETUP_HDL, R9
                MOVE    R8, @R9
                MOVE    @SP++, R8
                MOVE    SETUP_DRV, R9
                MOVE    R8, @R9
                MOVE    SETUP_CNT, R8
                ADD     1, @R8
                MOVE    SETUP_RET, R8
                MOVE    @R8, R8
                RET

S_PASS          .ASCII_W "PREPLOAD TEST: PASS\n"
S_FAIL          .ASCII_W "PREPLOAD TEST: FAIL "

#include "prepload_fn.asm"

HANDLE          .BLOCK  FAT32$FDH_STRUCT_SIZE
SETUP_CNT       .BLOCK  1
SETUP_HDL       .BLOCK  1
SETUP_DRV       .BLOCK  1
SETUP_RET       .DW     0
CTX_ARG         .DW     CTX_LOAD_ROM
