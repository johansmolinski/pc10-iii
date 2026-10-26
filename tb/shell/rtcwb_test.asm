; rtcwb_test.asm - PC_RTC_WB of CORE/m2m-rom/pc_rtc.asm (the real-time clock's write-back) on
; the QNICE emulator's headless batch mode. run_rtcwb.sh copies the function with its device
; addresses moved into RAM (the devices' registers become plain memory at 0xC000, M2M's RTC
; at 0xC100, the RAMROM selection at 0xC200/0xC201), so the test sees what it writes.
;
; Cases: nothing pending: nothing written; pending: M2M's command register 0 then 0x0C, its
; registers 0x00-0x07 = the eight bytes, the request acknowledged (1 written to offset 0);
; both: R0-R12 (all banks the caller sees) and the RAMROM selection preserved.
; Prints "RTCWB TEST: PASS" or "RTCWB TEST: FAIL <case>".

#include "sysdef.asm"
#include "monitor.def"

                .ORG    0x8000

                MOVE    0xC200, R0              ; the RAMROM selection
                MOVE    0x1234, @R0++
                MOVE    0x0567, @R0
                MOVE    0xC000, R0              ; nothing pending
                MOVE    0, @R0++
                MOVE    9, R1
_FILL           MOVE    R1, @R0++               ; 0xC001.. = 9, 8, .. (not written back)
                SUB     1, R1
                RBRA    _FILL, !Z
                MOVE    0xC100, R0              ; M2M's RTC: 0xEEEE
                MOVE    9, R1
_FILL2          MOVE    0xEEEE, @R0++
                SUB     1, R1
                RBRA    _FILL2, !Z

                RSUB    SETREGS, 1
                RSUB    PC_RTC_WB, 1
                RSUB    CMPREGS, 1
                MOVE    1, R12
                CMP     0, R11
                RBRA    FAIL, !Z
                MOVE    0xC100, R0              ; untouched
                MOVE    9, R1
_CHK1           CMP     0xEEEE, @R0++
                RBRA    FAIL, !Z
                SUB     1, R1
                RBRA    _CHK1, !Z
                MOVE    0xC200, R0
                MOVE    2, R12
                CMP     0x1234, @R0++
                RBRA    FAIL, !Z
                CMP     0x0567, @R0
                RBRA    FAIL, !Z

                MOVE    0xC000, R0              ; pending, the time 0x56, 0x47, ..
                MOVE    1, @R0++
                MOVE    T_TIME, R1
                MOVE    8, R2
_SET            MOVE    @R1++, @R0++
                SUB     1, R2
                RBRA    _SET, !Z
                MOVE    0xC000, R0
                MOVE    0x8001, @R0             ; (only bit 0 counts)
                RSUB    SETREGS, 1
                RSUB    PC_RTC_WB, 1
                RSUB    CMPREGS, 1
                MOVE    3, R12
                CMP     0, R11
                RBRA    FAIL, !Z
                MOVE    0xC100, R0              ; the eight registers
                MOVE    T_TIME, R1
                MOVE    8, R2
                MOVE    4, R12
_CHK2           CMP     @R1++, @R0++
                RBRA    FAIL, !Z
                SUB     1, R2
                RBRA    _CHK2, !Z
                MOVE    5, R12
                CMP     0x000C, @R0             ; the command: copy, auto-start
                RBRA    FAIL, !Z
                MOVE    6, R12
                MOVE    0xC000, R0
                CMP     1, @R0                  ; acknowledged
                RBRA    FAIL, !Z
                MOVE    7, R12
                MOVE    0xC200, R0
                CMP     0x1234, @R0++
                RBRA    FAIL, !Z
                CMP     0x0567, @R0
                RBRA    FAIL, !Z

                MOVE    S_PASS, R8
                SYSCALL(puts, 1)
                HALT

FAIL            MOVE    S_FAIL, R8
                SYSCALL(puts, 1)
                MOVE    R12, R8
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)
                HALT

; R0-R7 of this bank and R8-R10 get known values; CMPREGS: R11 = 0 if all are unchanged
SETREGS         MOVE    0x1110, R0
                MOVE    0x1111, R1
                MOVE    0x1112, R2
                MOVE    0x1113, R3
                MOVE    0x1114, R4
                MOVE    0x1115, R5
                MOVE    0x1116, R6
                MOVE    0x1117, R7
                MOVE    0x1118, R8
                MOVE    0x1119, R9
                MOVE    0x111A, R10
                RET
CMPREGS         XOR     R11, R11
                CMP     0x1110, R0
                RBRA    _CR_F, !Z
                CMP     0x1111, R1
                RBRA    _CR_F, !Z
                CMP     0x1112, R2
                RBRA    _CR_F, !Z
                CMP     0x1113, R3
                RBRA    _CR_F, !Z
                CMP     0x1114, R4
                RBRA    _CR_F, !Z
                CMP     0x1115, R5
                RBRA    _CR_F, !Z
                CMP     0x1116, R6
                RBRA    _CR_F, !Z
                CMP     0x1117, R7
                RBRA    _CR_F, !Z
                CMP     0x1118, R8
                RBRA    _CR_F, !Z
                CMP     0x1119, R9
                RBRA    _CR_F, !Z
                CMP     0x111A, R10
                RBRA    _CR_F, !Z
                RET
_CR_F           MOVE    1, R11
                RET

T_TIME          .DW     0x0056, 0x0047, 0x0023, 0x0011, 0x0014, 0x0003, 0x0084, 0x0006
S_PASS          .ASCII_W "RTCWB TEST: PASS\n"
S_FAIL          .ASCII_W "RTCWB TEST: FAIL "

PC_DEV_RTC      .EQU    0x0106
M2M$RAMROM_DEV  .EQU    0xC200
M2M$RAMROM_4KWIN .EQU   0xC201

#include "pc_rtc_moved.asm"
