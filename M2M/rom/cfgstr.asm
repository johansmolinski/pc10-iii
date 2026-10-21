; ****************************************************************************
; MiSTer2MEGA65 (M2M) QNICE ROM
;
; M2M-UPSTREAM cfg-strings (Megamiga 2026-10-13): text in the settings file
;
; The settings file (CFG_FILE in config.vhd) holds one byte per menu item
; (OPTM_SIZE bytes). Behind them it may hold text: lines "key=value" ending
; with a line feed, for settings a menu bit cannot hold (Megamiga: the
; Kickstart and hard disk files of a machine profile). A file of exactly
; OPTM_SIZE bytes is still valid (no text); older cores ignore nothing, they
; refuse a longer file, so a file with text stays with this core.
;
; HELP_MENU_INIT reads the text into CFGS_BUF (CFGS_LOAD, one character per
; word); the core reads and changes it with CFGS_GET and CFGS_SET; ROSM_SAVE
; writes it back when it changed (CFGS_DIRTY), resizing the file with the
; FAT32 write layer (FAT32$W_SETSIZE). Keys and values: printable ISO 8859-1,
; no "=" in a key, no line feed in either. CFGS_MAXC characters in all.
;
; Done by Megamiga in 2026 and licensed under GPL v3
; ****************************************************************************

; ----------------------------------------------------------------------------
; CFGS_LOAD: the text behind the menu bytes of the open settings file R8
; (positioned behind them) -> CFGS_BUF. Registers preserved.
; ----------------------------------------------------------------------------

CFGS_LOAD       SYSCALL(enter, 1)
                MOVE    CFGS_BUF, R0
                XOR     R1, R1                  ; R1: length
_CFGL_L         CMP     CFGS_MAXC, R1           ; full: ignore the rest
                RBRA    _CFGL_E, Z
                SYSCALL(f32_fread, 1)           ; R9: byte, R10: error/EOF
                CMP     0, R10
                RBRA    _CFGL_E, !Z
                MOVE    R9, @R0++
                ADD     1, R1
                RBRA    _CFGL_L, 1
_CFGL_E         MOVE    0, @R0
                MOVE    CFGS_LEN, R0
                MOVE    R1, @R0
                SYSCALL(leave, 1)
                RET

; ----------------------------------------------------------------------------
; CFGS_FIND: the line of key R8 (zero-terminated) -> R9 = its first character,
; R10 = the first character of its value, C=1; C=0 if there is none.
; Other registers preserved.
; ----------------------------------------------------------------------------

CFGS_FIND       INCRB
                MOVE    R11, R7
                MOVE    CFGS_BUF, R0            ; R0: start of a line
_CFGF_LINE      CMP     0, @R0
                RBRA    _CFGF_NO, Z
                MOVE    R0, R1                  ; compare the key
                MOVE    R8, R2
_CFGF_K         CMP     0, @R2
                RBRA    _CFGF_KE, Z
                CMP     @R1++, @R2++
                RBRA    _CFGF_K, Z
                RBRA    _CFGF_NEXT, 1
_CFGF_KE        CMP     0x003D, @R1             ; "=" right behind the key?
                RBRA    _CFGF_NEXT, !Z
                MOVE    R0, R9
                MOVE    R1, R10
                ADD     1, R10
                MOVE    R7, R11
                DECRB
                OR      0x0004, SR              ; C=1
                RET
_CFGF_NEXT      CMP     0, @R0                  ; to the next line
                RBRA    _CFGF_NO, Z
                CMP     0x000A, @R0++
                RBRA    _CFGF_NEXT, !Z
                RBRA    _CFGF_LINE, 1
_CFGF_NO        MOVE    R7, R11
                DECRB
                AND     0xFFFB, SR              ; C=0
                RET

; ----------------------------------------------------------------------------
; CFGS_GET: the value of key R8 -> the buffer R9 (zero-terminated, at most R10
; words including the zero). C=1 if the key is there, C=0 if not (the
; buffer is then empty). Registers preserved.
; ----------------------------------------------------------------------------

CFGS_GET        INCRB
                MOVE    R9, R0
                MOVE    R10, R1
                MOVE    0, @R0
                MOVE    R9, R3
                MOVE    R10, R4
                RSUB    CFGS_FIND, 1
                RBRA    _CFGG_NO, !C
                SUB     1, R1                   ; room for the zero
_CFGG_L         CMP     0, R1
                RBRA    _CFGG_E, Z
                CMP     0, @R10
                RBRA    _CFGG_E, Z
                CMP     0x000A, @R10
                RBRA    _CFGG_E, Z
                MOVE    @R10++, @R0++
                SUB     1, R1
                RBRA    _CFGG_L, 1
_CFGG_E         MOVE    0, @R0
                MOVE    R3, R9
                MOVE    R4, R10
                DECRB
                OR      0x0004, SR              ; C=1
                RET
_CFGG_NO        MOVE    R3, R9
                MOVE    R4, R10
                DECRB
                AND     0xFFFB, SR              ; C=0
                RET

; ----------------------------------------------------------------------------
; CFGS_SET: key R8 := value R9 (both zero-terminated); an empty value removes
; the key. CFGS_DIRTY is set if the text changed. C=0 if there is no room
; (the key is then gone). Registers preserved.
; ----------------------------------------------------------------------------

CFGS_SET        SYSCALL(enter, 1)
                MOVE    R8, R6                  ; R6: key
                MOVE    R9, R7                  ; R7: value

                ; the same value already? Then nothing changes.
                RSUB    CFGS_FIND, 1
                RBRA    _CFGS_DEL, !C
                MOVE    R10, R0
                MOVE    R7, R1
_CFGS_SAME      CMP     0, @R1
                RBRA    _CFGS_SE, Z
                CMP     @R0++, @R1++
                RBRA    _CFGS_SAME, Z
                RBRA    _CFGS_RM, 1
_CFGS_SE        CMP     0x000A, @R0             ; the value ends there, too
                RBRA    _CFGS_OK, Z
                CMP     0, @R0
                RBRA    _CFGS_OK, Z

                ; remove the old line: move the rest of the text down
_CFGS_RM        MOVE    R9, R0                  ; R0: the line
                MOVE    R9, R1                  ; R1: behind it
_CFGS_R1        CMP     0, @R1
                RBRA    _CFGS_R2, Z
                CMP     0x000A, @R1++
                RBRA    _CFGS_R1, !Z
_CFGS_R2        MOVE    R1, R2                  ; R2: removed characters
                SUB     R0, R2
_CFGS_R3        MOVE    @R1++, R3               ; (including the zero)
                MOVE    R3, @R0++
                CMP     0, R3
                RBRA    _CFGS_R3, !Z
                MOVE    CFGS_LEN, R0
                SUB     R2, @R0
                MOVE    CFGS_DIRTY, R0
                MOVE    1, @R0
                RSUB    CFGS_FIND, 1            ; (a key appears only once)
                RBRA    _CFGS_RM, C

                ; append "key=value\n" unless the value is empty
_CFGS_DEL       CMP     0, @R7
                RBRA    _CFGS_OK, Z
                MOVE    R6, R8                  ; the length of the line
                SYSCALL(strlen, 1)
                MOVE    R9, R2
                MOVE    R7, R8
                SYSCALL(strlen, 1)
                ADD     R9, R2
                ADD     2, R2                   ; "=" and "\n"
                MOVE    CFGS_LEN, R0
                MOVE    @R0, R1
                ADD     R1, R2                  ; the new length
                CMP     R2, CFGS_MAXC
                RBRA    _CFGS_FULL, N           ; (R2 > CFGS_MAXC)
                MOVE    R2, @R0
                MOVE    CFGS_BUF, R0
                ADD     R1, R0                  ; the end of the text
                MOVE    R6, R1
_CFGS_A1        CMP     0, @R1
                RBRA    _CFGS_A2, Z
                MOVE    @R1++, @R0++
                RBRA    _CFGS_A1, 1
_CFGS_A2        MOVE    0x003D, @R0++
                MOVE    R7, R1
_CFGS_A3        CMP     0, @R1
                RBRA    _CFGS_A4, Z
                MOVE    @R1++, @R0++
                RBRA    _CFGS_A3, 1
_CFGS_A4        MOVE    0x000A, @R0++
                MOVE    0, @R0
                MOVE    CFGS_DIRTY, R0
                MOVE    1, @R0
_CFGS_OK        SYSCALL(leave, 1)
                OR      0x0004, SR              ; C=1
                RET
_CFGS_FULL      SYSCALL(leave, 1)
                AND     0xFFFB, SR              ; C=0
                RET

; ----------------------------------------------------------------------------
; CFGS_SIZE: before ROSM_SAVE writes: make the settings file R8 (CONFIG_FILE)
; OPTM_ICOUNT + CFGS_LEN bytes long (FAT32$W_SETSIZE; ROSM_SAVE then seeks to
; the start). The sector buffer of its device is released first. On an
; error the text is dropped (CFGS_LEN = 0) and the file keeps its size.
; Registers preserved.
; ----------------------------------------------------------------------------

CFGS_SIZE       SYSCALL(enter, 1)
                MOVE    R8, R0                  ; R0: the file handle
                MOVE    @R0, R8                 ; the buffer of its device
                CMP     0, @R8                  ; (written back, then
                RBRA    _CFGZ_1, Z              ; nobody's)
                RSUB    FAT32$FLUSH_OWNER, 1
                MOVE    @R0, R8
                ADD     FAT32$DEV_BUFFERED_FDH, R8
                MOVE    0, @R8
_CFGZ_1         MOVE    OPTM_ICOUNT, R10        ; R11:R10: the new size
                MOVE    @R10, R10
                MOVE    CFGS_LEN, R1
                ADD     @R1, R10
                XOR     R11, R11
                MOVE    R0, R1                  ; the same as now?
                ADD     FAT32$FDH_SIZE_LO, R1
                CMP     @R1++, R10
                RBRA    _CFGZ_SET, !Z
                CMP     0, @R1
                RBRA    _CFGZ_RET, Z
_CFGZ_SET       MOVE    CFGS_PB, R1             ; the parameter block: the
                MOVE    R0, R2                  ; device, no date (the entry
                ADD     FAT32$FDH_DEVICE, R2    ; keeps its date)
                MOVE    @R2, @R1++
                MOVE    FAT32$PB_SIZE, R2
                SUB     1, R2
_CFGZ_Z         MOVE    0, @R1++
                SUB     1, R2
                RBRA    _CFGZ_Z, !Z
                MOVE    R0, R8
                MOVE    CFGS_PB, R9
                RSUB    FAT32$W_SETSIZE, 1      ; (a FAR_CALL stub)
                CMP     0, R9
                RBRA    _CFGZ_RET, Z
                MOVE    CFGS_LEN, R1            ; failed: no text
                MOVE    0, @R1
_CFGZ_RET       SYSCALL(leave, 1)
                RET

; ----------------------------------------------------------------------------
; CFGS_WRITE: the text into the settings file R8 behind the menu bytes that
; ROSM_SAVE has just written. Registers preserved.
; ----------------------------------------------------------------------------

CFGS_WRITE      SYSCALL(enter, 1)
                MOVE    CFGS_BUF, R0
                MOVE    CFGS_LEN, R1
                MOVE    @R1, R1
_CFGW_L         CMP     0, R1
                RBRA    _CFGW_RET, Z
                MOVE    @R0++, R9
                SYSCALL(f32_fwrite, 1)
                CMP     0, R9
                RBRA    _CFGW_RET, !Z
                SUB     1, R1
                RBRA    _CFGW_L, 1
_CFGW_RET       SYSCALL(leave, 1)
                RET
