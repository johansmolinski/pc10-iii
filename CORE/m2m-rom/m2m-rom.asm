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

; PREP_LOAD_IMAGE: the floppy images of A: and B: (menu lines " A:%s",
; " B:%s", manual ROM loads 0 and 1 into C_DEV_PC_FDA/FDB). Nothing is loaded:
; pc_fdd_sd.vhd reads and writes the file on the SD card through its extent
; map (FD_SETUP), and the file pointer is left at the end, so the Shell only
; does the CSR handshake.
;
; Input:  R8: file handle, R9: context (CTX_*), R10: menu group
; Output: R8: 0 = OK, else an error code; R9: image type (0) or the error text
PREP_LOAD_IMAGE INCRB
                CMP     CTX_LOAD_ROM, R9
                RBRA    _PCPL_OK, !Z
                XOR     R1, R1                  ; R1: drive 0 = A:, 1 = B:
                CMP     PC_OPTM_G_FDA, R10
                RBRA    _PCPL_D, Z
                MOVE    1, R1
                CMP     PC_OPTM_G_FDB, R10
                RBRA    _PCPL_OK, !Z

_PCPL_D         MOVE    R8, R0                  ; R0: the file handle
                MOVE    R1, R8                  ; the drive is off while it
                MOVE    FD_REGWIN, R9           ; changes (no disk)
                RSUB    FD_SEL, 1
                MOVE    FD_MODE, R2
                MOVE    0, @R2
                MOVE    FD_STAT, R2             ; a transfer that was already
                MOVE    64, R4                  ; past the mode check still uses
_PCPL_W1        XOR     R3, R3                  ; the old map: wait for its end
_PCPL_W2        MOVE    @R2, R5                 ; (bounded, ~1 s)
                AND     1, R5
                RBRA    _PCPL_W3, Z
                SUB     1, R3
                RBRA    _PCPL_W2, !Z
                SUB     1, R4
                RBRA    _PCPL_W1, !Z
_PCPL_W3

                MOVE    R0, R2                  ; the size: one of the formats
                ADD     FAT32$FDH_SIZE_LO, R2   ; (sectors = size / 512)
                MOVE    @R2, R2                 ; R2: size lo
                MOVE    R0, R3
                ADD     FAT32$FDH_SIZE_HI, R3
                MOVE    @R3, R3                 ; R3: size hi
                MOVE    R2, R4
                AND     0x01FF, R4
                RBRA    _PCPL_BAD, !Z
                MOVE    R3, R4
                AND     0xFF80, R4              ; >= 8 MB
                RBRA    _PCPL_BAD, !Z
                AND     0xFFFB, SR              ; R2: sectors
                SHR     9, R2
                AND     0xFFFD, SR
                SHL     7, R3
                OR      R3, R2
                MOVE    FD_SIZES, R3
_PCPL_SZ        CMP     0, @R3
                RBRA    _PCPL_BAD, Z
                CMP     R2, @R3++
                RBRA    _PCPL_SZ, !Z

                MOVE    R0, R8                  ; R8: handle, R9: drive
                MOVE    R1, R9
                RSUB    FD_SETUP, 1             ; R8: 0, 1 = too fragmented,
                CMP     0, R8                   ; 2 = FAT32 error
                RBRA    _PCPL_OK, Z
                MOVE    ERR_FD_FRAG, R9
                CMP     1, R8
                RBRA    _PCPL_RET, Z
                MOVE    ERR_FD_FAT, R9
                RBRA    _PCPL_RET, 1

_PCPL_BAD       MOVE    3, R8
                MOVE    ERR_FD_SIZE, R9
                RBRA    _PCPL_RET, 1

_PCPL_OK        XOR     R8, R8
                XOR     R9, R9
_PCPL_RET       DECRB
                RET

FD_SIZES        .DW     320, 360, 640, 720, 1440, 0     ; 160K..720K in sectors
ERR_FD_SIZE     .ASCII_W "Not a 160K-720K disk image"
ERR_FD_FRAG     .ASCII_W "Image too fragmented"
ERR_FD_FAT      .ASCII_W "FAT32 error mapping the image"

; FD_SEL: point the RAMROM window at one drive's device
; Input: R8: drive 0/1, R9: window (FD_REGWIN or FD_MAPWIN); registers preserved
FD_SEL          INCRB
                MOVE    FD_DEV_TAB, R0
                ADD     R8, R0
                MOVE    M2M$RAMROM_DEV, R1
                MOVE    @R0, @R1
                MOVE    M2M$RAMROM_4KWIN, R1
                MOVE    R9, @R1
                DECRB
                RET

FD_DEV_TAB      .DW     PC_DEV_FDA, PC_DEV_FDB
FD_REGWIN       .EQU    0x0000
FD_MAPWIN       .EQU    0x0001
FD_MODE         .EQU    0x8000                  ; bit 0 on, bit 1 the card in slot 1
FD_SECT         .EQU    0x8001                  ; sectors lo, hi; BASE lo, hi; SHIFT
FD_STAT         .EQU    0x8008                  ; bit 0: a transfer is running
FD_MAP          .EQU    0x8000
FD_MAPW         .EQU    2048                    ; map words: 511 extents

; FD_SETUP: hand an image file to pc_fdd_sd.vhd (after Megamiga's ADF_TB_SETUP):
; the extent map, the number of sectors, the block of cluster 0
; (DEV_CLUSTER - (2 << shift)), the cluster size and the card; the mode goes
; last. The handle is moved to the end of the file.
; Input:  R8: file handle, R9: drive 0/1
; Output: R8: 0 = OK, 1 = more extents than the map holds, 2 = FAT32 error;
;         R9 clobbered, R10..R12 preserved (the RAMROM selection is changed)
FD_SETUP        MOVE    R10, @--SP
                MOVE    R11, @--SP
                MOVE    R12, @--SP
                INCRB
                MOVE    R8, R0                  ; R0: handle
                MOVE    R9, R1                  ; R1: drive

                MOVE    R1, R8                  ; the extent map
                MOVE    FD_MAPWIN, R9
                RSUB    FD_SEL, 1
                MOVE    R0, R8
                MOVE    FD_MAP, R9
                MOVE    FD_MAPW, R10
                RSUB    FAT32$FILE_MAP, 1
                MOVE    1, R7                   ; R7: the result
                CMP     FAT32$ERR_MAPSIZE, R9
                RBRA    _FDSU_RET, Z
                MOVE    2, R7
                CMP     0, R9
                RBRA    _FDSU_RET, !Z

                MOVE    R1, R8                  ; the registers
                MOVE    FD_REGWIN, R9
                RSUB    FD_SEL, 1

                MOVE    R0, R2                  ; sectors = size >> 9
                ADD     FAT32$FDH_SIZE_LO, R2
                MOVE    @R2, R2
                MOVE    R0, R3
                ADD     FAT32$FDH_SIZE_HI, R3
                MOVE    @R3, R3
                AND     0xFFFB, SR
                SHR     9, R2
                MOVE    R3, R4
                AND     0xFFFD, SR
                SHL     7, R4
                OR      R4, R2                  ; R2: sectors lo
                AND     0xFFFB, SR
                SHR     9, R3                   ; R3: sectors hi
                MOVE    FD_SECT, R4
                MOVE    R2, @R4++
                MOVE    R3, @R4++               ; R4: BASE

                MOVE    @R0, R2                 ; R2: device handle
                MOVE    R2, R3                  ; (FAT32$FDH_DEVICE = 0)
                ADD     FAT32$DEV_SECT_PER_CLUS, R3
                MOVE    @R3, R3                 ; R3: sectors per cluster
                XOR     R5, R5                  ; R5: shift
_FDSU_SH        CMP     R3, 1
                RBRA    _FDSU_SHD, !N           ; R3 <= 1: done
                AND     0xFFFB, SR
                SHR     1, R3
                ADD     1, R5
                RBRA    _FDSU_SH, 1
_FDSU_SHD       MOVE    2, R6                   ; base = DEV_CLUSTER - (2 << shift)
                AND     0xFFFD, SR
                SHL     R5, R6
                MOVE    R2, R3
                ADD     FAT32$DEV_CLUSTER_LO, R3
                MOVE    @R3++, R11              ; R12:R11: DEV_CLUSTER
                MOVE    @R3, R12
                SUB     R6, R11
                SUBC    0, R12
                MOVE    R11, @R4++              ; base lo, hi, shift
                MOVE    R12, @R4++
                MOVE    R5, @R4

                MOVE    R2, R8                  ; the card (M2M-UPSTREAM sd-host:
                RSUB    SDC$SLOT, 1             ; the engine port's controller)
                MOVE    1, R6                   ; on
                CMP     0, R8
                RBRA    _FDSU_S0, Z
                OR      2, R6                   ; slot 1
_FDSU_S0        MOVE    FD_MODE, R3             ; mode last
                MOVE    R6, @R3

                MOVE    R0, R8                  ; the handle to the end
                MOVE    R0, R9
                ADD     FAT32$FDH_SIZE_LO, R9
                MOVE    @R9, R9
                MOVE    R0, R10
                ADD     FAT32$FDH_SIZE_HI, R10
                MOVE    @R10, R10
                SYSCALL(f32_fseek, 1)
                MOVE    2, R7
                CMP     0, R9
                RBRA    _FDSU_RET, !Z
                XOR     R7, R7
_FDSU_RET       MOVE    R7, R8
                DECRB
                MOVE    @SP++, R12
                MOVE    @SP++, R11
                MOVE    @SP++, R10
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

_PCPS_HI        MOVE    R1, R2                  ; 64 KB: the low word is 0
                ADD     PC_BIOS_SIZELO, R2
                CMP     0, @R2
                RBRA    _PCPS_BIG, !Z

_PCPS_OK        MOVE    R1, R2                  ; right-align the image (pc_bios
                ADD     PC_BIOS_SIZEHI, R2      ; reads the RAM without an adder)
                CMP     0, @R2
                RBRA    _PCPS_AL, !Z            ; 64 KB: already in place
                MOVE    @R1, R8                 ; R8: size (PC_BIOS_SIZELO = 0)
                RSUB    BIOS_ALIGN, 1
_PCPS_AL        RSUB    FONT_START, 1           ; the CGA font (optional)
                CMP     0, R8
                RBRA    _PCPS_RET, !Z
                MOVE    M2M$RAMROM_DEV, R0      ; back to the BIOS device
                MOVE    PC_DEV_BIOS, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    PC_BIOS_CTRL, @R0
                MOVE    R1, R2                  ; release the BIOS: the PC
                ADD     PC_BIOS_VALID, R2       ; leaves reset with the
                MOVE    1, @R2                  ; Shell's un-reset
                XOR     R8, R8
                XOR     R9, R9
                RBRA    _PCPS_RET, 1

_PCPS_BIG       MOVE    ERR_BIOS_BIG, R8
                MOVE    1, R9
                RBRA    _PCPS_RET, 1
_PCPS_SMALL     MOVE    ERR_BIOS_SMALL, R8
                MOVE    2, R9

_PCPS_RET       DECRB
                RET

ERR_BIOS_BIG    .ASCII_W "/pc10/bios.rom is larger than 64 KB"
ERR_BIOS_SMALL  .ASCII_W "/pc10/bios.rom is smaller than 8 KB"

; BIOS_ALIGN: move the BIOS image (R8 = its size, 0 < size < 65536, loaded at
; offset 0) to the top of the 64 KB window, so that it ends at FFFFF like a ROM
; in the top socket, and fill the space below it with 0xFF (an empty socket).
; Byte by byte from the top down (the regions may overlap); about 0.2 s.
; Registers preserved (own bank); the RAMROM selection is changed.
BIOS_ALIGN      INCRB
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    PC_DEV_BIOS, @R0
                MOVE    R8, R1                  ; R1: bytes to move
                MOVE    R8, R2
                SUB     1, R2                   ; R2: source
                MOVE    0xFFFF, R3              ; R3: destination
_BA_MOVE        MOVE    R2, R8
                RSUB    _BA_ADDR, 1
                MOVE    @R8, R4
                MOVE    R3, R8
                RSUB    _BA_ADDR, 1
                MOVE    R4, @R8
                SUB     1, R2
                SUB     1, R3
                SUB     1, R1
                RBRA    _BA_MOVE, !Z
                MOVE    R3, R1                  ; R1: bytes to fill = R3 + 1
                ADD     1, R1                   ; (R3 = 65535 - size)
_BA_FILL        MOVE    R3, R8
                RSUB    _BA_ADDR, 1
                MOVE    0x00FF, @R8
                SUB     1, R3
                SUB     1, R1
                RBRA    _BA_FILL, !Z
                DECRB
                RET

; _BA_ADDR: R8 = byte address 0..65535 -> its 4K window selected, R8 = the
; address in the RAMROM window (same register bank as the caller: R5, R6 used)
_BA_ADDR        MOVE    R8, R5
                AND     0xFFFB, SR              ; (C = 0: shift in zeros)
                SHR     12, R5
                MOVE    M2M$RAMROM_4KWIN, R6
                MOVE    R5, @R6
                AND     0x0FFF, R8
                ADD     M2M$RAMROM_DATA, R8
                RET

; FONT_START: if /pc10/cga.rom was loaded (pc_font.vhd's size is not 0), check
; it (2 KB or 8 KB) and have it copied into the CGA card; without it the free
; default font stays.
; Output: R8/R9: 0 = OK, else the fatal message / code (own register bank)
FONT_START      INCRB
                MOVE    M2M$RAMROM_DEV, R0
                MOVE    PC_DEV_FONT, @R0
                MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    PC_BIOS_CTRL, @R0       ; (its control window is 0x0100 too)
                MOVE    M2M$RAMROM_DATA, R1
                MOVE    @R1, R2                 ; R2: size
                CMP     0, R2
                RBRA    _FTST_OK, Z             ; not loaded: the default
                MOVE    R1, R3                  ; larger than 8 KB?
                ADD     1, R3
                MOVE    @R3, R3
                AND     1, R3
                RBRA    _FTST_BAD, !Z
                CMP     0x0800, R2
                RBRA    _FTST_GO, Z
                CMP     0x2000, R2
                RBRA    _FTST_BAD, !Z
_FTST_GO        MOVE    R1, R3                  ; copy it into the card
                ADD     2, R3
                MOVE    1, @R3
_FTST_OK        XOR     R8, R8
                XOR     R9, R9
                RBRA    _FTST_RET, 1
_FTST_BAD       MOVE    ERR_FONT, R8
                MOVE    3, R9
_FTST_RET       DECRB
                RET

ERR_FONT        .ASCII_W "/pc10/cga.rom must be 2 KB or 8 KB"

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
