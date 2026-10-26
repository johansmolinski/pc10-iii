; ****************************************************************************
; PC10-III for MEGA65: the real-time clock's write-back (doc/rtc.md section 5)
;
; PC_RTC_WB, called at the top of HANDLE_CORE_IO: when the PC has set its
; clock (the MSM6242B at 2C0h, rtl/system/msm6242.sv; pc_rtc.vhd holds the
; time and the request), the time goes to the MEGA65's battery RTC through
; M2M's RTC device (M2M/vhdl/i2c/rtc_controller.vhd, device 0x0006): stop the
; internal timer (the command is taken only while the I2C bus is idle; if the
; command register does not read 0 afterwards, the next call tries again),
; write its registers 0x00-0x07, copy them into the RTC with auto-start
; (0x0C) and acknowledge the request. It never waits for the I2C transfer
; (about 1 ms): a request behind it finds the bus busy and waits its turn.
; All registers and the RAMROM selection are preserved.
;
; done by Johan Smolinski in 2026, licensed under GPL v3
; ****************************************************************************

PC_M2M_RTC      .EQU    0x0006                  ; M2M's RTC device (qnice_wrapper.vhd)
PC_M2M_RTC_REG  .EQU    0x8000                  ; its registers 0x00-0x07 (window 0)
PC_M2M_RTC_CMD  .EQU    0x8008                  ; its command register
PC_RTC_ST       .EQU    0x8000                  ; pc_rtc.vhd: bit 0 pending / done
PC_RTC_TIME     .EQU    0x8001                  ; pc_rtc.vhd: the eight registers

PC_RTC_WB       INCRB
                MOVE    M2M$RAMROM_DEV, R0      ; keep the RAMROM selection
                MOVE    @R0, R6
                MOVE    M2M$RAMROM_4KWIN, R1
                MOVE    @R1, R7

                MOVE    PC_DEV_RTC, @R0         ; a write-back pending?
                MOVE    0, @R1
                MOVE    PC_RTC_ST, R2
                MOVE    @R2, R3
                AND     1, R3
                RBRA    _PCRTC_RET, Z

                MOVE    PC_M2M_RTC, @R0         ; stop M2M's internal timer
                MOVE    PC_M2M_RTC_CMD, R3
                MOVE    0, @R3
                CMP     0, @R3                  ; stopped and the I2C bus idle?
                RBRA    _PCRTC_RET, !Z

                XOR     R4, R4                  ; R4: register 0..7
_PCRTC_LOOP     MOVE    PC_DEV_RTC, @R0
                MOVE    PC_RTC_TIME, R5
                ADD     R4, R5
                MOVE    @R5, R5                 ; R5: the PC's byte
                MOVE    PC_M2M_RTC, @R0
                MOVE    PC_M2M_RTC_REG, R2
                ADD     R4, R2
                MOVE    R5, @R2
                ADD     1, R4
                CMP     8, R4
                RBRA    _PCRTC_LOOP, !Z
                MOVE    0x000C, @R3             ; into the RTC, then run again

                MOVE    PC_DEV_RTC, @R0         ; done
                MOVE    PC_RTC_ST, R2
                MOVE    1, @R2

_PCRTC_RET      MOVE    R6, @R0
                MOVE    R7, @R1
                DECRB
                RET
