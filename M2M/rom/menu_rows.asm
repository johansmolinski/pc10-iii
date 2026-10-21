; ****************************************************************************
; MiSTer2MEGA65 (M2M) QNICE ROM
;
; M2M-UPSTREAM menu-rows: options of a radio group side by side on one line
;
; A radio group that config.vhd lists in OPTM_ROWS is drawn as a ROW: the
; text before ": " of its first item is a label line of its own, the options
; follow on the next line, side by side, each with its selection marker in
; front of it. The cursor highlights a single option; left/right move between
; the options of a row, up/down leave it (menu.asm), Return/Space select as
; always. Without rows the screen is exactly the classic one, line by line.
;
;   CPU: 68000                     CPU
;   CPU: 68020          ->          *68000  68020  68040
;   CPU: 68040
;
; Every option stays its own menu item: the flat indexes, the settings file,
; OPTM_SIZE, the callbacks and the core's view of the settings do not change.
; Only the screen position of an item does. menu.asm keeps working with the
; position of an item among the visible items of the current level (the
; "ordinal", formerly simply its row); OPTR_PRINT records where each ordinal is
; on screen (OPTR_LAY) while it draws the menu, and the screen callbacks below
; and OPT_SELECT / OPT_PRINTLINE in options.asm translate through OPTR_POS.
;
; The lines word of an item (options.asm builds it from SEL_OPTM_ROWS):
;   bit 0      separator line (config.vhd: OPTM_G_LINE)
;   bit 1      option of a row (OPTM_ROWS)
;   bit 2      greyed-out rule (OPTM_AVAIL): bits 6..3 = the items of the mother
;              group that make it available, bits 14..7 = the mother group;
;              unavailable items are drawn dimmed and the cursor skips them
;   bit 15     a separator line is drawn below the item (a headline) without
;              being a menu item of its own; a headline that directly follows
;              an option of a row gets one above it too (a section after rows,
;              e.g. Megamiga's "Zorro Boards")
;
; Rules for config.vhd (checked by ~/aexp-work/menu-rows/cfg/check.py):
; - the items of a row group are consecutive lines, the row's first item
;   carries the label ("CPU: 68000"), the others only the option (" 68020")
; - a row group is a radio group (no OPTM_G_SINGLESEL)
; - a row fits into the frame: 1 + sum(1 + len(option) + 1) - 1 <= OPTM_DX - 2
;
; Needs (from the includer): OPTM_* variables (menu_vars.asm), OPTM_NL,
; SCR$PRINTSTRXY, OPT_LINE_AT (a separator at screen row R8), ERR_F_NEWLINE
; and FATAL.
;
; done by Johan Smolinski in 2026 and licensed under GPL v3
; ****************************************************************************

OPTR_MAX        .EQU 40                         ; ordinals recorded in OPTR_LAY
                                                ; (2 words each; menu_vars.asm)

; ----------------------------------------------------------------------------
; OPTR_PRINT: the OPTM_FP_PRINT function
;
; Input:  R8: the menu item string, items separated by \n
;         R9: mask array: the amount of items, then one word per item whose
;             bit 15 says "shown on the current level"
; Output: none, all registers are preserved
; ----------------------------------------------------------------------------

OPTR_PRINT      SYSCALL(enter, 1)

                MOVE    @R9++, R0               ; R0: items left
                MOVE    R9, R1                  ; R1: mask of the item
                MOVE    R8, R2                  ; R2: text of the item
                MOVE    OPTM_DATA, R3
                MOVE    @R3, R3
                MOVE    R3, R4
                ADD     OPTM_IR_LINES, R3
                MOVE    @R3, R3                 ; R3: lines word (bit 1: row)
                ADD     OPTM_IR_GROUPS, R4
                MOVE    @R4, R4                 ; R4: group word
                XOR     R5, R5                  ; R5: screen row in the frame
                XOR     R6, R6                  ; R6: ordinal
                MOVE    OPTR_GRP, R7            ; no row open
                MOVE    0xFFFF, @R7
                MOVE    OPTR_COL, R7
                MOVE    0, @R7
                CMP     0, R0
                RBRA    _OPTR_P_END, Z

_OPTR_P_1       MOVE    R2, R8                  ; R11: length of the text
                MOVE    OPTM_NL, R9
                SYSCALL(strstr, 1)
                CMP     0, R10
                RBRA    _OPTR_P_F, Z            ; no \n: fatal
                MOVE    R10, R11
                SUB     R2, R11
                ADD     2, R10
                MOVE    R10, @--SP              ; the next item's text

                MOVE    @R3, R7                 ; an option of a row?
                AND     2, R7
                RBRA    _OPTR_P_NR, Z
                MOVE    @R4, R7                 ; R7: its group id
                AND     0x00FF, R7
                MOVE    OPTR_GRP, R8
                CMP     @R8, R7                 ; the row that is open?
                RBRA    _OPTR_P_MEM, Z

                RSUB    _OPTR_CLOSE, 1          ; no: a new row starts here
                MOVE    OPTR_GRP, R8
                MOVE    R7, @R8
                MOVE    OPTR_LBLN, R8           ; its label: the text in front
                MOVE    0, @R8                  ; of ": " (none: no label line)
                MOVE    R2, R12
                MOVE    R11, R9
_OPTR_P_L1      CMP     2, R9                   ; fewer than 2 characters left?
                RBRA    _OPTR_P_MEM, N
                CMP     0x003A, @R12            ; ":"
                RBRA    _OPTR_P_L2, !Z
                MOVE    R12, R8
                ADD     1, R8
                CMP     0x0020, @R8             ; " "
                RBRA    _OPTR_P_L2, !Z
                MOVE    R12, R8                 ; found: the label
                SUB     R2, R8
                MOVE    OPTR_LBLN, R9
                MOVE    R8, @R9
                MOVE    OPTR_LBL, R9
                MOVE    R2, @R9
                ADD     2, R12                  ; the option follows ": "
                RBRA    _OPTR_P_OPT, 1
_OPTR_P_L2      ADD     1, R12
                SUB     1, R9
                RBRA    _OPTR_P_L1, 1

_OPTR_P_MEM     MOVE    R2, R12                 ; the option: the text without
                CMP     0x0020, @R12            ; its leading blank (the marker
                RBRA    _OPTR_P_OPT, !Z         ; column of a classic line)
                ADD     1, R12
_OPTR_P_OPT     MOVE    R2, R9                  ; R12/R9: the option text
                ADD     R11, R9
                SUB     R12, R9

                CMP     @R1, 0x7FFF             ; shown?
                RBRA    _OPTR_P_NEXT, !N
                MOVE    OPTR_COL, R7            ; the first option shown in
                CMP     0, @R7                  ; this row: print the label
                RBRA    _OPTR_P_M2, !Z
                MOVE    1, @R7                  ; (options: marker column 1)
                MOVE    OPTR_LBLN, R8
                CMP     0, @R8
                RBRA    _OPTR_P_M2, Z
                MOVE    R9, @--SP
                MOVE    @R8, R9
                MOVE    OPTR_LBL, R8
                MOVE    @R8, R8
                XOR     R10, R10
                MOVE    R5, R11
                RSUB    OPTR_PUT, 1
                ADD     1, R5
                MOVE    @SP++, R9

_OPTR_P_M2      MOVE    OPTR_COL, R7            ; the option behind its marker
                MOVE    @R7, R10
                ADD     1, R10
                MOVE    R12, R8
                MOVE    R5, R11
                RSUB    OPTR_PUT, 1
                SUB     1, R10                  ; layout: the marker column,
                MOVE    R10, R8                 ; marker + text are highlighted
                ADD     1, R9
                RSUB    _OPTR_REC, 1
                ADD     1, R9                   ; the next option: one blank
                MOVE    OPTR_COL, R7            ; between this text and its
                ADD     R9, @R7                 ; marker
                ADD     1, R6
                RBRA    _OPTR_P_NEXT, 1

_OPTR_P_NR      RSUB    _OPTR_CLOSE, 1          ; a classic line
                CMP     @R1, 0x7FFF             ; shown?
                RBRA    _OPTR_P_NEXT, !N
                MOVE    @R3, R7                 ; a headline right behind a
                AND     0x8000, R7              ; row (not at the top) gets a
                RBRA    _OPTR_P_NA, Z           ; separator line above it too
                CMP     0, R6
                RBRA    _OPTR_P_NA, Z
                MOVE    R3, R7
                SUB     1, R7
                MOVE    @R7, R7
                AND     2, R7
                RBRA    _OPTR_P_NA, Z
                MOVE    OPTM_Y, R8
                MOVE    @R8, R8
                ADD     1, R8
                ADD     R5, R8
                RSUB    OPT_LINE_AT, 1
                ADD     1, R5
_OPTR_P_NA      MOVE    R2, R8
                MOVE    R11, R9
                XOR     R10, R10
                MOVE    R5, R11
                RSUB    OPTR_PUT, 1
                XOR     R8, R8                  ; layout: column 0, full width
                XOR     R9, R9
                RSUB    _OPTR_REC, 1
                ADD     1, R5
                ADD     1, R6
                MOVE    @R3, R7                 ; a separator line below it?
                AND     0x8000, R7              ; (a headline: no menu item of
                RBRA    _OPTR_P_NEXT, Z         ; its own; OPT_LINE_AT draws it)
                MOVE    OPTM_Y, R8
                MOVE    @R8, R8
                ADD     1, R8
                ADD     R5, R8
                RSUB    OPT_LINE_AT, 1
                ADD     1, R5

_OPTR_P_NEXT    MOVE    @SP++, R2               ; next item
                ADD     1, R1
                ADD     1, R3
                ADD     1, R4
                SUB     1, R0
                RBRA    _OPTR_P_1, !Z

_OPTR_P_END     RSUB    _OPTR_CLOSE, 1
                XOR     R8, R8                  ; the row behind the last item
                XOR     R9, R9                  ; (OPTM_SHOW draws a closing
                RSUB    _OPTR_REC, 1            ; line there in submenus)

                SYSCALL(leave, 1)
                RET

_OPTR_P_F       MOVE    ERR_F_NEWLINE, R8       ; fatal due to missing newline
                XOR     R9, R9
                RBRA    FATAL, 1

; OPTR_PRINT helpers that work in OPTR_PRINT's register bank (no INCRB):
; R5 = screen row, R6 = ordinal

; close the open row, if any: the next line starts below it (R8 changed)
_OPTR_CLOSE     MOVE    OPTR_COL, R8
                CMP     0, @R8                  ; was the row drawn?
                RBRA    _OPTR_CL_1, Z
                ADD     1, R5
                MOVE    0, @R8
_OPTR_CL_1      MOVE    OPTR_GRP, R8
                MOVE    0xFFFF, @R8
                RET

; record the layout of ordinal R6: row R5, column R8, width R9 (0 = full)
; (R7, R8 changed)
_OPTR_REC       CMP     OPTR_MAX, R6            ; inside the table?
                RBRA    _OPTR_REC_R, !N
                MOVE    R6, R7
                ADD     R6, R7
                ADD     OPTR_LAY, R7
                SWAP    R8, R8                  ; column: high byte
                ADD     R5, R8                  ; row: low byte
                MOVE    R8, @R7++
                MOVE    R9, @R7
_OPTR_REC_R     RET

; ----------------------------------------------------------------------------
; OPTR_PUT: print R9 characters at R8, at column R10 (0 = the marker column)
; of row R11 inside the frame. All registers are preserved.
; ----------------------------------------------------------------------------

OPTR_PUT        SYSCALL(enter, 1)

                MOVE    SP, R0                  ; R0: restore the stack
                MOVE    R10, R1                 ; R1: column
                SUB     R9, SP                  ; a copy with terminator
                SUB     1, SP
                MOVE    R9, R10
                MOVE    SP, R9
                SYSCALL(memcpy, 1)
                ADD     R10, R9
                MOVE    0, @R9
                MOVE    SP, R8
                MOVE    OPTM_X, R9
                MOVE    @R9, R9
                ADD     1, R9
                ADD     R1, R9
                MOVE    OPTM_Y, R10
                MOVE    @R10, R10
                ADD     1, R10
                ADD     R11, R10
                RSUB    SCR$PRINTSTRXY, 1
                MOVE    R0, SP

                SYSCALL(leave, 1)
                RET

; ----------------------------------------------------------------------------
; OPTR_POS: where the visible item number R8 (the ordinal) is on screen
;
; Input:  R8: ordinal
; Output: R8: x of its marker column, R9: y, R10: width of its highlight
;         (an ordinal outside OPTR_LAY gets the classic position)
; ----------------------------------------------------------------------------

OPTR_POS        INCRB

                MOVE    R8, R0                  ; R0: row, R1: column,
                XOR     R1, R1                  ; R2: width (0 = full)
                XOR     R2, R2
                CMP     OPTR_MAX, R8
                RBRA    _OPTR_POS_1, !N
                MOVE    R8, R3
                ADD     R8, R3
                ADD     OPTR_LAY, R3
                MOVE    @R3++, R0
                MOVE    @R3, R2
                MOVE    R0, R1
                SWAP    R1, R1
                AND     0x00FF, R1
                AND     0x00FF, R0
_OPTR_POS_1     MOVE    OPTM_X, R8
                MOVE    @R8, R8
                ADD     1, R8
                ADD     R1, R8
                MOVE    OPTM_Y, R9
                MOVE    @R9, R9
                ADD     1, R9
                ADD     R0, R9
                MOVE    R2, R10
                RBRA    _OPTR_POS_2, !Z
                MOVE    OPTM_DX, R10
                MOVE    @R10, R10
                SUB     2, R10

_OPTR_POS_2     DECRB
                RET

; ----------------------------------------------------------------------------
; OPTR_PRINTXY: the OPTM_FP_PRINTXY function
;
; menu.asm prints markers, "%s" texts and live texts at x|y = R9|R10 of the
; classic layout: y = OPTM_Y + 1 + ordinal, x = OPTM_X + 1 + offset. Print
; R8 at the same offset from the item's marker column in the row layout.
; All registers are preserved.
; ----------------------------------------------------------------------------

OPTR_PRINTXY    INCRB

                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    R10, R2
                MOVE    R10, R8                 ; R8: the ordinal
                MOVE    OPTM_Y, R9
                SUB     @R9, R8
                SUB     1, R8
                RSUB    OPTR_POS, 1
                MOVE    R9, R10                 ; y: the item's row
                MOVE    R1, R9                  ; x: plus the offset
                ADD     R8, R9
                MOVE    OPTM_X, R8
                SUB     @R8, R9
                SUB     1, R9
                MOVE    R0, R8
                RSUB    SCR$PRINTSTRXY, 1
                MOVE    R1, R9
                MOVE    R2, R10

                DECRB
                RET
