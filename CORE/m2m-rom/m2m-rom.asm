; ****************************************************************************
; PC10-III for MEGA65
;
; QNICE firmware (the M2M "Shell" plus the core's callbacks)
;
; The Shell does almost everything: SD cards, the settings file, the menu, and
; the BIOS: /pc10/bios.rom is a mandatory auto-loaded ROM (globals.vhd), so the
; Shell loads it into the BIOS device (pc_bios.vhd) while the PC is held in
; reset, and goes fatal if the file is missing. PREP_START then checks the
; size (8..64 KB) and releases the BIOS gate of pc_bios.vhd, which is what lets
; the PC out of reset.
;
; Callbacks the Megamiga fork's Shell needs on top of the M2M template's:
; HANDLE_CORE_IO (core-io-hook), BROWSE_EXTRA (cfg-strings), CFG_SIGCHECK and
; CFG_SIGSET (the settings file signature); the FAT32 write layer (the Shell
; creates and resizes the settings file with it) is included flat, through
; fat32_wglue.asm, so there are no code banks (QNICE_CODE_BANKS = "").
;
; done by Johan Smolinski in 2026, based on the MiSTer2MEGA65 template
; (sy2002 and MJoergen) and the Megamiga firmware, licensed under GPL v3
; ****************************************************************************

#define RELEASE

; ----------------------------------------------------------------------------
; Firmware: M2M system
; ----------------------------------------------------------------------------

#include "../../M2M/rom/main.asm"
#include "../../M2M/rom/shell.asm"

; ----------------------------------------------------------------------------
; Firmware: Main Code
; ----------------------------------------------------------------------------

START_FIRMWARE  RBRA    START_SHELL, 1

; ----------------------------------------------------------------------------
; Core specific constants
; ----------------------------------------------------------------------------

#include "osm_const.asm"

PC_BIOS_CTRL    .EQU    0x0100                  ; pc_bios.vhd: control window
PC_BIOS_SIZELO  .EQU    0x0000                  ; offsets in it
PC_BIOS_SIZEHI  .EQU    0x0001
PC_BIOS_VALID   .EQU    0x0002
PC_BIOS_OVFL    .EQU    0x0003

; ----------------------------------------------------------------------------
; Core specific callback functions: Submenus
;
; SUBMENU_SUMMARY: R8 = 0 = the standard semantics (the selected item of the
; submenu's first group replaces the %s).
; ----------------------------------------------------------------------------

SUBMENU_SUMMARY XOR     R8, R8
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: File browsing and image mounting (none)
; ----------------------------------------------------------------------------

; FILTER_FILES: R8 = 0 = show every file
FILTER_FILES    XOR     R8, R8
                RET

; PREP_LOAD_IMAGE: no manual loads in this core
PREP_LOAD_IMAGE XOR     R8, R8
                XOR     R9, R9
                RET

; BROWSE_EXTRA (M2M-UPSTREAM cfg-strings): no browser entries that are no
; files. Output R8 = 0; R10..R12 preserved.
BROWSE_EXTRA    XOR     R8, R8
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Core startup
;
; PREP_START is called after the ROMs were auto-loaded and before the Shell
; releases the core's reset. The BIOS image is in pc_bios.vhd; check its size
; and release it.
;
; Output: R8: 0 = OK, else pointer to the error message (fatal)
;         R9: 0 = OK, else error code
; ----------------------------------------------------------------------------

PREP_START      INCRB
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    PC_DEV_BIOS, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    PC_BIOS_CTRL, @R0
                MOVE    M2M$RAMROM_DATA, R1     ; R1: the control registers

                MOVE    R1, R2                  ; more than 64 KB?
                ADD     PC_BIOS_OVFL, R2
                MOVE    @R2, R3
                AND     1, R3
                RBRA    _PCPS_BIG, !Z

                MOVE    R1, R2                  ; exactly 64 KB?
                ADD     PC_BIOS_SIZEHI, R2
                MOVE    @R2, R3
                AND     1, R3
                RBRA    _PCPS_HI, !Z

                MOVE    R1, R2                  ; less than 8 KB (0x2000)?
                ADD     PC_BIOS_SIZELO, R2
                MOVE    @R2, R3
                AND     0xE000, R3
                RBRA    _PCPS_SMALL, Z
                RBRA    _PCPS_OK, 1

_PCPS_HI          MOVE    R1, R2                  ; 64 KB: the low word is 0
                ADD     PC_BIOS_SIZELO, R2
                CMP     0, @R2
                RBRA    _PCPS_BIG, !Z

_PCPS_OK          MOVE    R1, R2                  ; release the BIOS: the PC
                ADD     PC_BIOS_VALID, R2       ; leaves reset with the
                MOVE    1, @R2                  ; Shell's un-reset
                XOR     R8, R8
                XOR     R9, R9
                RBRA    _PCPS_RET, 1

_PCPS_BIG         MOVE    ERR_BIOS_BIG, R8
                MOVE    1, R9
                RBRA    _PCPS_RET, 1
_PCPS_SMALL       MOVE    ERR_BIOS_SMALL, R8
                MOVE    2, R9

_PCPS_RET         DECRB
                RET

ERR_BIOS_BIG    .ASCII_W "/pc10/bios.rom is larger than 64 KB"
ERR_BIOS_SMALL  .ASCII_W "/pc10/bios.rom is smaller than 8 KB"

; ----------------------------------------------------------------------------
; Core specific callback functions: OSM selections
;
; OSM_SEL_PRE / OSM_SEL_POST: R8 = the selected group, R9 = the selected item
; (single-select: 1 = selected), R10 = the key. Output R8/R9: 0 = OK.
;
; "Reset the PC" is momentary: OSM_SEL_POST resets the PC through the CSR and
; unselects the item again (M2M$FORCE_MENU), like Megamiga's reload item.
; ----------------------------------------------------------------------------

OSM_SEL_PRE     XOR     R8, R8
                XOR     R9, R9
                RET

OSM_SEL_POST    INCRB
                CMP     PC_OPTM_G_RESET, R8
                RBRA    _PCOSP_RET, !Z

                MOVE    M2M$CSR, R0             ; reset the core..
                OR      M2M$CSR_RESET, @R0
                MOVE    0x2000, R1              ; ..for about a millisecond
_PCOSP_WAIT       SUB     1, R1
                RBRA    _PCOSP_WAIT, !Z
                AND     M2M$CSR_UN_RESET, @R0

                MOVE    OPTM_CUR_SEL, R8        ; momentary: unselect again
                MOVE    @R8, R8
                XOR     R9, R9
                RSUB    M2M$FORCE_MENU, 1
                RSUB    OPTM_SHOW, 1
                MOVE    OPTM_CUR_SEL, R8
                MOVE    @R8, R8
                MOVE    OPTM_SEL_SEL, R9
                RSUB    OPTM_SELECT, 1

_PCOSP_RET        XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Custom messages, background work, the
; settings file
; ----------------------------------------------------------------------------

; CUSTOM_MSG: R8 = 0 = no custom message
CUSTOM_MSG      XOR     R8, R8
                RET

; HANDLE_CORE_IO (M2M-UPSTREAM core-io-hook): the Shell's time slice for
; background work; nothing yet. Must preserve all registers.
HANDLE_CORE_IO  RET

; CFG_SIGCHECK (M2M-UPSTREAM cfg-strings): C=1 = the settings file R8 belongs
; to this menu. The PC core keeps no signature: every file of the right size
; is accepted (the Shell checks the size). Registers preserved.
CFG_SIGCHECK    OR      0x0004, SR
                RET

; CFG_SIGSET: a new settings file was created; nothing to add.
CFG_SIGSET      RET

; ----------------------------------------------------------------------------
; The FAT32 write layer, flat (the Shell creates and resizes the settings
; file with it)
; ----------------------------------------------------------------------------

#include "../../M2M/QNICE/monitor/fat32_wglue.asm"
#include "../../M2M/QNICE/monitor/fat32_write.asm"
#include "../../M2M/QNICE/monitor/fat32_wfile.asm"

; ----------------------------------------------------------------------------
; END_OF_ROM must stay the last ROM item (make_rom.sh checks it)
; ----------------------------------------------------------------------------

END_OF_ROM      .DW 0

; ----------------------------------------------------------------------------
; Variables: Need to be located in RAM
; ----------------------------------------------------------------------------

#ifdef RELEASE
                .ORG    0xA000                  ; RAM starts at 0xA000: the 4k device
                                                ; window takes 0x8000-0x8FFF (M2M-UPSTREAM
                                                ; rom-32k), the code window 0x9000-0x9FFF
                                                ; (code-banks; unused here)
#endif

#include "../../M2M/rom/shell_vars.asm"

; The menu heap (Megamiga hard rule 11): the menu structure plus OPTM_HEAP;
; for this 25-line menu the demand is ~600 words, the Shell checks it at boot
; (ERR_FATAL_HEAP1/2). The rest of the heap is the file browser's.
MENU_HEAP_SIZE  .EQU 1024

#ifndef RELEASE
HEAP_SIZE       .EQU 0
HEAP            .BLOCK 1
#else
; HEAP + MENU_HEAP_SIZE + HEAP_SIZE must stay below VAR$STACK_START -
; STACK_SIZE (check HEAP and VAR$STACK_START in m2m-rom.lis)
HEAP_SIZE       .EQU 19968
HEAP            .BLOCK 1

                .ORG    0xFED0                  ; as Megamiga: the FAT32 write layer's
                                                ; larger device handle (main_vars.asm)
#endif

STACK_SIZE      .EQU    1536
B_STACK_SIZE    .EQU    768

#include "../../M2M/rom/main_vars.asm"
