; ****************************************************************************
; MiSTer2MEGA65 (M2M) QNICE ROM
;
; Variables for Options Menu (menu.asm): Need to be located in RAM
;
; done by sy2002 in 2023 and licensed under GPL v3
; ****************************************************************************

; screen coordinates
OPTM_X          .BLOCK 1
OPTM_Y          .BLOCK 1
OPTM_DX         .BLOCK 1
OPTM_DY         .BLOCK 1

; currently active (sub)menu level; 0 means main menu
OPTM_MENULEVEL  .BLOCK 1

; selected menu item in main menu before diving into a submenu
OPTM_MAINSEL    .BLOCK 1

; M2M-UPSTREAM nested-submenus: parent level of every (sub)menu level (index =
; submenu id 1..OPTM_MAXSUB-1, 0 = main menu) and the region stack that
; _OPTM_STRUCT uses while it assigns the ids
OPTM_PARENTS    .BLOCK OPTM_MAXSUB
OPTM_SSTACK     .BLOCK OPTM_MAXNEST
OPTM_SSTACKE    .BLOCK 1                        ; end marker of OPTM_SSTACK

; currently selected menu item (real-time)
OPTM_CUR_SEL    .BLOCK 1

; pointer to initialization record (see menu.asm for more details)
OPTM_DATA       .BLOCK 1

; single-select vs multi-select item flag
OPTM_SSMS       .BLOCK 1

; ptr to the _OPTM_STRUCT menu struct. (only valid while OPTM_RUN is running)
OPTM_STRUCT     .BLOCK 1

; temporary variable
OPTM_TEMP       .BLOCK 1

; M2M-UPSTREAM menu-rows (menu_rows.asm): the screen layout of the visible
; items that OPTR_PRINT drew last, two words per ordinal (OPTR_MAX = 40):
; row | column << 8, highlight width (0 = full); and its drawing state
OPTR_LAY        .BLOCK 80
OPTR_GRP        .BLOCK 1                        ; group id of the open row
OPTR_COL        .BLOCK 1                        ; its next marker column
OPTR_LBL        .BLOCK 1                        ; its label text..
OPTR_LBLN       .BLOCK 1                        ; ..and its length (0: none)
