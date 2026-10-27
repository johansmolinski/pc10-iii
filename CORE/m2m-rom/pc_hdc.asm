; ****************************************************************************
; PC10-III for MEGA65: the hard disk C: across power-off
;
; The settings file's text (M2M-UPSTREAM cfg-strings, M2M/rom/cfgstr.asm)
; remembers the image of C: by its path with the card in front (M2M-UPSTREAM
; sd-host, two slots: "SD0:" = the bottom tray, "SD1:" = the back slot):
;
;   hdc=SD1:/pc10/hd20.img
;
; PREP_LOAD_IMAGE writes it when C: is mounted (HDC_SAVE; a failed mount
; removes it, the drive is off then), the SPACE eject in HANDLE_CORE_IO
; removes it, and the Shell writes the file when the menu closes (ROSM_SAVE:
; CFGS_DIRTY). PREP_START mounts it again before the PC leaves reset
; (HDC_RESTORE) through PREP_LOAD_IMAGE, as the menu does, so the BIOS finds
; the drive at its first look. The floppies A: and B: are not remembered.
; After Megamiga's machine profiles (B2_PROF_REMEMBER, B2_PROF_SAVED,
; _PR_PATHOF, PROF_NAME; Megamiga 0.6.1).
;
; Variables (m2m-rom.asm): HDC_PEND, HDC_PATH (HDC_PLEN words, the last one
; HDC_PATH_Z), HDC_FDH, HDC_DE.
;
; Code bank 0 (M2M-UPSTREAM code-banks, since 2026-10-27): the entry points
; B0_HDC_SAVE, B0_HDC_RESTORE and B0_HDC_PEND_APPLY are called through the
; stubs HDC_SAVE, HDC_RESTORE and HDC_PEND_APPLY in the fixed ROM (FAR_CALL,
; m2m-rom.asm). Its texts are used only while it runs (CFGS_SET copies the
; key and the value).
;
; done by Johan Smolinski in 2026 and licensed under GPL v3
; ****************************************************************************

HDC_PLEN        .EQU    128                     ; HDC_PATH: at most 127 characters

HDC_KEY         .ASCII_W "hdc"
HDC_NONE        .DW     0                       ; the empty value removes the key
HDC_UP          .ASCII_W ".."
HDC_S_ERR       .ASCII_W "\nC: not mounted:\n"
HDC_S_NF        .ASCII_W "Not found"

; ----------------------------------------------------------------------------
; HDC_SAVE: R8 = 0: C: was mounted from the open file R10 (the Shell opened it
; from the current directory of its card's device handle); else C: is empty.
; The key follows: the file's path, or no key (also if the path cannot be
; found or is longer than 127 characters). The names come from directory
; listings (HDC_FDH, HDC_DE): the entry with the file's first cluster in the
; current directory, then each directory by its cluster in its parent (".."),
; up to the root. The current directory is kept, and the sector buffer is
; nobody's afterwards if HDC_FDH had it. While HDC_RESTORE mounts (HDC_PEND
; not 0) the key stays as it is: it opened the file by its path, so the
; current directory is not the file's. All registers preserved.
; ----------------------------------------------------------------------------

B0_HDC_SAVE     SYSCALL(enter, 1)
                MOVE    HDC_PEND, R3            ; HDC_RESTORE mounts: the key
                CMP     0, @R3                  ; stays
                RBRA    _HSV_RET, !Z
                MOVE    HDC_NONE, R3            ; R3: the value: none..
                CMP     0, R8
                RBRA    _HSV_SET, !Z            ; (C: is empty)
                MOVE    @R10, R6                ; R6: the device (FDH_DEVICE = 0)
                ADD     FAT32$FDH_START_CLUS_LO, R10
                MOVE    @R10++, R4              ; R5:R4: the cluster to find
                MOVE    @R10, R5
                MOVE    R6, R0                  ; R0: the current directory of
                ADD     FAT32$DEV_AD_1STCLUS_LO, R0 ; the device, R2:R1: the
                MOVE    @R0++, R1               ; one there now (put back at
                MOVE    @R0, R2                 ; the end)
                SUB     1, R0
                MOVE    HDC_PATH_Z, R7          ; R7: the path, from its end
                MOVE    0, @R7

_HSV_DIR        MOVE    R6, R8                  ; the current directory: the
                MOVE    HDC_FDH, R9             ; entry with the cluster
                SYSCALL(f32_od, 1)              ; (hidden ones too)
                CMP     0, R9
                RBRA    _HSV_END, !Z
_HSV_ENT        MOVE    HDC_FDH, R8
                MOVE    HDC_DE, R9
                MOVE    FAT32$FA_ALL, R10
                SYSCALL(f32_ld, 1)
                CMP     0, R11
                RBRA    _HSV_END, !Z
                CMP     0, R10
                RBRA    _HSV_END, Z             ; the end: not there
                MOVE    HDC_DE, R8
                ADD     FAT32$DE_CLUS_LO, R8
                CMP     @R8++, R4
                RBRA    _HSV_ENT, !Z
                CMP     @R8, R5
                RBRA    _HSV_ENT, !Z

                MOVE    HDC_DE, R8              ; "/" and its name in front, if
                SYSCALL(strlen, 1)              ; "SDx:" still fits: R9 + 5
                ADD     5, R9                   ; must not exceed the room
                MOVE    R7, R10
                SUB     HDC_PATH, R10           ; R10: the room
                CMP     R9, R10
                RBRA    _HSV_END, N             ; (R9 > R10)
                SUB     5, R9
                SUB     R9, R7
                MOVE    R9, R10
                MOVE    R7, R9
                SYSCALL(memcpy, 1)              ; (R8: the name)
                MOVE    0x002F, @--R7

                MOVE    R0, R8                  ; R5:R4: this directory, to find
                MOVE    @R8++, R4               ; in its parent; the root (in
                MOVE    @R8, R5                 ; front of it: DEV_RD_1STCLUS):
                SUB     3, R8                   ; done
                CMP     @R8++, R4
                RBRA    _HSV_UP, !Z
                CMP     @R8, R5
                RBRA    _HSV_DONE, Z
_HSV_UP         MOVE    R6, R8                  ; cd .. (to the root for a
                MOVE    HDC_UP, R9              ; cluster 0)
                XOR     R10, R10
                SYSCALL(f32_cd, 1)
                CMP     0, R9
                RBRA    _HSV_DIR, Z
                RBRA    _HSV_END, 1

_HSV_DONE       MOVE    R6, R8                  ; the card in front
                RSUB    SDC$SLOT, 1
                ADD     0x0030, R8
                MOVE    0x003A, @--R7           ; "SDx:"
                MOVE    R8, @--R7
                MOVE    0x0044, @--R7
                MOVE    0x0053, @--R7
                MOVE    R7, R8                  ; to the start of HDC_PATH
                MOVE    HDC_PATH, R9
                MOVE    R9, R3                  ; R3: ..or the path
                SYSCALL(strcpy, 1)
_HSV_END        MOVE    R1, @R0++               ; the current directory back
                MOVE    R2, @R0
                MOVE    R6, R8                  ; the sector buffer: nobody's
                ADD     FAT32$DEV_BUFFERED_FDH, R8 ; if HDC_FDH has it
                CMP     HDC_FDH, @R8
                RBRA    _HSV_SET, !Z
                MOVE    0, @R8
_HSV_SET        MOVE    HDC_KEY, R8
                MOVE    R3, R9
                RSUB    CFGS_SET, 1
_HSV_RET        SYSCALL(leave, 1)
                RET

; ----------------------------------------------------------------------------
; HDC_RESTORE (PREP_START, the PC still in reset): mount the image the key
; names on C: through PREP_LOAD_IMAGE, as the menu does (the size, the extent
; map, JMP208); the menu line shows its name once the menu is opened
; (HDC_PEND stays 1 until then; HDC_SAVE leaves the key alone meanwhile). A
; path that cannot be opened, or an image that PREP_LOAD_IMAGE refuses, leaves
; C: empty: the reason is shown for 5 s and the key is removed. All registers
; preserved; the RAMROM selection changes.
; ----------------------------------------------------------------------------

B0_HDC_RESTORE  SYSCALL(enter, 1)
                MOVE    HDC_PEND, R3            ; R3: HDC_PEND, 1: it mounts
                MOVE    1, @R3
                MOVE    HDC_KEY, R8
                MOVE    HDC_PATH, R9
                MOVE    HDC_PLEN, R10
                RSUB    CFGS_GET, 1
                RBRA    _HRS_NO, !C             ; nothing remembered
                MOVE    HDC_S_NF, R2            ; R2: the reason
                MOVE    R9, R0                  ; "SD0:" or "SD1:"
                CMP     0x0053, @R0++
                RBRA    _HRS_ERR, !Z
                CMP     0x0044, @R0++
                RBRA    _HRS_ERR, !Z
                MOVE    @R0++, R8
                SUB     0x0030, R8
                CMP     R8, 1
                RBRA    _HRS_ERR, N             ; (R8 > 1, also below "0")
                CMP     0x003A, @R0++
                RBRA    _HRS_ERR, !Z
                RSUB    SDC$MOUNT, 1            ; R8: the card's device handle
                CMP     0, R9
                RBRA    _HRS_ERR, !Z
                MOVE    HANDLE_RM_FILE3, R9     ; the Shell's handle of C:
                MOVE    R9, R1                  ; (manual ROM 2)
                MOVE    R0, R10                 ; the path behind the card
                XOR     R11, R11                ; ("/" separates)
                SYSCALL(f32_fopen, 1)
                CMP     0, R10
                RBRA    _HRS_ERR, !Z
                MOVE    R1, R8                  ; the menu's way
                MOVE    CTX_LOAD_ROM, R9
                MOVE    PC_OPTM_G_HDC, R10
                RSUB    PREP_LOAD_IMAGE, 1
                MOVE    R9, R2
                CMP     0, R8
                RBRA    _HRS_ERR, !Z
                MOVE    PC_DEV_HDC, R8          ; the menu line counts as loaded
                MOVE    CRTROM_CSR_STATUS, R9   ; (CRTROM_MLST_GET) and shows
                MOVE    CRTROM_CSR_ST_OK, R10   ; the name when the menu opens
                RSUB    CRTROM_CSR_W, 1         ; (HDC_PEND)
                RBRA    _HRS_RET, 1

_HRS_ERR        RSUB    FRAME_FULLSCR, 1        ; the reason for 5 s
                RSUB    SCR$OSM_M_ON, 1
                MOVE    HDC_S_ERR, R8
                RSUB    SCR$PRINTSTR, 1
                MOVE    HDC_PATH, R8
                RSUB    SCR$PRINTSTR, 1
                MOVE    NEWLINE, R8
                RSUB    SCR$PRINTSTR, 1
                MOVE    R2, R8
                RSUB    SCR$PRINTSTR, 1
                MOVE    15, R0
_HRS_W          RSUB    WAIT333MS, 1
                SUB     1, R0
                RBRA    _HRS_W, !Z
                RSUB    SCR$OSM_OFF, 1
_HRS_NO         MOVE    0, @R3                  ; nothing pending, C: is empty:
                MOVE    1, R8                   ; no key
                RSUB    B0_HDC_SAVE, 1
_HRS_RET        SYSCALL(leave, 1)
                RET

; ----------------------------------------------------------------------------
; HDC_PEND_APPLY (HANDLE_CORE_IO): the name of the image HDC_RESTORE mounted
; for the menu line " C:%s", as HANDLE_MOUNTING does after a load from the
; browser: the name behind the last "/" of HDC_PATH, at most OPTM_DX - 1
; characters (more than OPTM_DX - 2 give the Shell's ellipsis), in the line's
; buffer of OPTM_HEAP, its "%s is replaced" flag 0. OPTM_HEAP exists once the
; menu has been opened; that runs this in the menu's key loop before
; CRTROM_MLST_GET sees STATUS ok and redraws the line with the name. Cheap
; while nothing waits. All registers preserved.
; ----------------------------------------------------------------------------

B0_HDC_PEND_APPLY SYSCALL(enter, 1)
                MOVE    HDC_PEND, R0
                CMP     0, @R0
                RBRA    _HPA_RET, Z             ; nothing waits
                MOVE    OPTM_HEAP, R1
                CMP     0, @R1
                RBRA    _HPA_RET, Z             ; no menu yet
                MOVE    0, @R0
                MOVE    VDRIVES_NUM, R8         ; the buffer: (vdrives +
                MOVE    @R8, R8                 ; submenus + 2) x OPTM_DX
                MOVE    OPTM_SCOUNT, R9
                ADD     @R9, R8
                ADD     2, R8
                MOVE    SCR$OSM_O_DX, R9
                MOVE    @R9, R9
                SYSCALL(mulu, 1)                ; R10: the offset (R9 kept)
                MOVE    @R1, R2
                ADD     R10, R2                 ; R2: the buffer
                MOVE    HDC_PATH, R3            ; R4: behind the last "/"
_HPA_S          MOVE    R3, R4
_HPA_SL         CMP     0, @R3
                RBRA    _HPA_C, Z
                CMP     0x002F, @R3++
                RBRA    _HPA_SL, !Z
                RBRA    _HPA_S, 1
_HPA_C          MOVE    R2, R3
                ADD     R9, R2                  ; R2: behind the buffer
                SUB     1, R9                   ; R9: at most OPTM_DX - 1
_HPA_CL         CMP     0, @R4
                RBRA    _HPA_CE, Z
                MOVE    @R4++, @R3++
                SUB     1, R9
                RBRA    _HPA_CL, !Z
_HPA_CE         MOVE    0, @R3
                MOVE    0, @--R2                ; "%s is replaced" := 0
_HPA_RET        SYSCALL(leave, 1)
                RET
