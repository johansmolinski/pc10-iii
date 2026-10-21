; ****************************************************************************
; MiSTer2MEGA65 (M2M) QNICE ROM
;
; Variables for shell.asm and its direct includes:
; options.asm
;
; done by sy2002 in 2023 and licensed under GPL v3
; ****************************************************************************


#include "dirbrowse_vars.asm"
#include "keyboard_vars.asm"
#include "screen_vars.asm"

#include "menu_vars.asm"

; reset handling
WELCOME_SHOWN   .BLOCK 1                        ; we need to trust that this
                                                ; is 0 on system coldstart

; option menu
OPTM_ICOUNT     .BLOCK 1                        ; amount of menu items
OPTM_SCOUNT     .BLOCK 1                        ; amount of submenus
OPTM_START      .BLOCK 1                        ; initially selected menu item
OPTM_SELECTED   .BLOCK 1                        ; last options menu selection
OPTM_MNT_STATUS .BLOCK 1                        ; drive mount status; all drvs
OPTM_DTY_STATUS .BLOCK 1                        ; cache dirty status; all drvs

; OPTM_HEAP is used by the option menu to save the modified filenames of
; disk images used by mounted drives: Filenames need to be abbreviated by
; "..." if they are too long. See also HELP_MENU and HANDLE_MOUNTING.
;
; OPTM_HEAP also stores the replacement strings for %s within submenu
; headlines/entry points and the replacem. strings for %s for CRT/ROM loading
;
; Each reserved memory block for one string is @SCR$OSM_O_DX in size.
;
; Memory map:
;
; VDrive strings:   <amount of virtual drives> x @SCR$OSM_O_DX
; Submenu strings:  <amount of submenus> x @SCR$OSM_O_DX
; CRT/ROM strings:  <amount of manual loadable CRTs/ROMs> x @SCR$OSM_O_DX
;
; OPTM_HEAP_LAST points to a scratch buffer that can hold a modified filename
; for saving/restoring while the cache dirty "Saving" message is shown.
; See also OPTM_CB_SHOW. 
OPTM_HEAP       .BLOCK 1
OPTM_HEAP_LAST  .BLOCK 1
OPTM_HEAP_SIZE  .BLOCK 1                        ; size of this scratch buffer

; Temporary variables (only to be used in a very narrow local scope)
SCRATCH_HEX     .BLOCK 5
SCRATCH_DWORD   .BLOCK 2

; M2M-UPSTREAM sd-host (two slots): one device handle per SD card slot, shared
; by the file browser, the settings file, the auto-load ROMs and the core (see
; sdcards.asm). They replace HANDLE_DEV (the browser's) and CONFIG_DEVH (the
; settings file's), which both described the one active card.
SDC_DEV0        .BLOCK  FAT32$DEV_STRUCT_SIZE   ; slot 0: internal (bottom tray)
SDC_DEV1        .BLOCK  FAT32$DEV_STRUCT_SIZE   ; slot 1: external (back slot)
SDC_GEN         .BLOCK  2                       ; card generation per slot
SDC_MGEN        .BLOCK  2                       ; generation the handle has
SDC_MERR        .BLOCK  2                       ; its result (0 = FAT32 mounted)
SDC_PRES        .BLOCK  2                       ; card present (debounced)
SDC_RAW         .BLOCK  2                       ; card-detect seen last
SDC_RAWT        .BLOCK  2                       ; IO$CYC_MID when it changed
SDC_HOME        .BLOCK  1                       ; slot of the settings file,
                                                ; 0xFFFF = none
SDC_HGEN        .BLOCK  1                       ; its generation at the load
FB_SLOT         .BLOCK  1                       ; the card the browser shows
FB_CARDS        .BLOCK  1                       ; 1: it shows the card list
FB_GEN          .BLOCK  2                       ; generations its list is of

; Remember configuration handling:
; * M2M-UPSTREAM sd-host (two slots): the settings file is opened through the
;   device handle of its card (SDC_HOME, see sdcards.asm); there is no
;   separate CONFIG_DEVH any more.
; * File-handle for config file (saving/loading OSM settings) is valid (i.e.
;   not null) when SAVE_SETTINGS (config.vhd) is true and when the file
;   specified by CFG_FILE (config.vhd) exists and has exactly the size of
;   OPTM_SIZE (config.vhd). The convention "checking CONFIG_FILE for not null"
;   can be used as a trigger for various actions in the shell.
; * OLD_SETTINGS is used to determine changes in the 256-bit (16-word)
;   M2M$CFM_DATA register so that we can implement a smart saving mechanism:
;   When pressing "Help" to close the on-screen-menu, we only save the
;   settings to the SD card when the settings changed.
; * The card generation at the load (SDC_HGEN) protects the data integrity:
;   see ROSM_INTEGRITY in options.asm
CONFIG_FILE     .BLOCK  FAT32$FDH_STRUCT_SIZE
OLD_SETTINGS    .BLOCK  16
; M2M-UPSTREAM cfg-strings (cfgstr.asm): the text behind the menu bytes
CFGS_LEN        .BLOCK  1                       ; its length
CFGS_DIRTY      .BLOCK  1                       ; 1: changed since loaded/saved
CFGS_RESET      .BLOCK  1                       ; 1: the file was reset (signature)
CFGS_BUF        .BLOCK  CFGS_MAX                ; one character per word
CFGS_PB         .BLOCK  FAT32$PB_SIZE           ; FAT32 write layer parameters

; SD card "stability" workaround
SD_WAIT         .EQU   0x05F6                   ; 2 seconds @ 50 MHz
SD_CYC_MID      .BLOCK 1                        ; cycle counter for SD card..
SD_CYC_HI       .BLOCK 1                        ; .."stability workaround"
SD_WAIT_DONE    .BLOCK 1                        ; initial waiting done

; waiting time until M2M$SYS_CORE_H_FREQ is ready to be read: 2.5 seconds
LOG_HFREQ_WAIT  .EQU   0x0773                   ; 2.5 seconds @ 50 MHz
LOG_HFREQ_FLAG  .BLOCK 1                        ; info has been logged
LOG_CYC_MID     .BLOCK 1
LOG_CYC_HI      .BLOCK 1

LOG_HEAP_SHOWN  .BLOCK 1

; file browser persistent status
FB_HEAP         .BLOCK 1                        ; heap used by file browser
FB_STACK        .BLOCK 1                        ; local stack used by browser
FB_STACK_INIT   .BLOCK 1                        ; initial local browser stack
FB_MAINSTACK    .BLOCK 1                        ; stack of main program
FB_HEAD         .BLOCK 1                        ; lnkd list: curr. disp. head
FB_LASTCALLER   .BLOCK 1                        ; vdrive id/CRTROM id + mode

; context variables (see CTX_* constants in sysdef.asm)
SF_CONTEXT      .BLOCK 1                        ; context for SELECT_FILE
SF_CONTEXT_DATA .BLOCK 1                        ; optional add. data for ctx
SF_VIRTUAL      .BLOCK 1                        ; M2M-UPSTREAM cfg-strings: the
                                                ; chosen entry is no file but
                                                ; BROWSE_EXTRA's id + 1 (else 0)

; ----------------------------------------------------------------------------
; Virtual drive and manual/automatic CRT/ROM loading system
; ----------------------------------------------------------------------------

; Important: Make sure you have as many ".BLOCK FAT32$FDH_STRUCT_SIZE"
; statements listed one after another as the .EQU VDRIVES_MAX (below) plus
; the .EQU CRTROM_MAN_MAX demands and make sure that the HNDL_VD_FILES
; and HNDL_RM_FILES arrays in shell.asm point to the right amount of them
; as well, i.e. you need to edit shell.asm
; Autogenerated from globals.vhd and included from globals.asm
#include "../../CORE/m2m-rom/shell_fhandles.asm"

#include "../../CORE/m2m-rom/globals.asm"

; Virtual drive system (aka mounting disk/module/tape images):
; VDRIVES_NUM:      Amount of virtual, mountable drives; needs to correlate
;                   with the actual hardware in vdrives.vhd and the menu items
;                   tagged with OPTM_G_MOUNT_DRV in config.vhd
;                   VDRIVES_MAX must be equal or larger than the value stored
;                   in this variable
;                   Variable is initialized in VD_INIT in vdrives.asm
;
; VDRIVES_MAX:      Maximum amount of supported virtual drives.
;                   VD_INIT expects an .EQU and also the assembler does not
;                   allow this value to be a variable. Do not forget to
;                   adjust the file handles (see above) accordingly.
;                   Try to keep small for RAM preservation reasons.
;                   Autogen. from globals.vhd and included from globals.asm
;
; VDRIVES_DEVICE:   Device ID of the IEC bridge in vdrives.vhd
;
; VDRIVES_BUFS:     Array of device IDs of size VDRIVES_NUM that contains the
;                   RAM buffer-devices that will hold the mounted drives
;
; VDRIVES_FLUSH_*:  Array of high/low words of the amount of bytes that still
;                   need to be flushed to ensure that the cache is written
;                   completely to the SD card
;
; VDRIVES_ITERSIZ   Array of amount of bytes stored in one iteration of the
;                   background saving (buffer flushing) process
;
; VDRIVES_FL_*:     Array of current 4k window and offset within window of the
;                   disk image buffer in RAM
VDRIVES_NUM     .BLOCK  1
VDRIVES_DEVICE  .BLOCK  1
VDRIVES_BUFS    .BLOCK  VDRIVES_MAX
VDRIVES_FLUSH_H .BLOCK  VDRIVES_MAX
VDRIVES_FLUSH_L .BLOCK  VDRIVES_MAX
VDRIVES_ITERSIZ .BLOCK  VDRIVES_MAX
VDRIVES_FL_4K   .BLOCK  VDRIVES_MAX
VDRIVES_FL_OFS  .BLOCK  VDRIVES_MAX

; System to handle manually and automatically loaded cartridges and ROMs
; See also globals.vhd: There are multiple types of "byte streaming devices"
; that are able to receive the CRT/ROM data. All need to obey to a certain
; protocol that is: 4K windows 0x0000..0xFFFE can be used to recieve data and
; the 4K window 0xFFFF is used as a control and status register
; MAX values are autogen. from globals.vhd and included from globals.asm
CRTROM_MAN_NUM  .BLOCK 1                        ; amount of manual CRTs/ROMs
CRTROM_MAN_LDF  .BLOCK CRTROM_MAN_MAX           ; flag: has been loaded
CRTROM_MAN_DEV  .BLOCK CRTROM_MAN_MAX           ; byte streaming device ids
CRTROM_MAN_4KS  .BLOCK CRTROM_MAN_MAX           ; 4K start address within dev.
CRTROM_AUT_NUM  .BLOCK 1                        ; amount of automatic ROMSs
CRTROM_AUT_LDF  .BLOCK CRTROM_AUT_MAX           ; flag: has been loaded
CRTROM_AUT_DEV  .BLOCK CRTROM_AUT_MAX           ; byte streaming device ids
CRTROM_AUT_4KS  .BLOCK CRTROM_AUT_MAX           ; 4K start address within dev.
CRTROM_AUT_MOD  .BLOCK CRTROM_AUT_MAX           ; mode: mandatory or optional
CRTROM_AUT_NAM  .BLOCK CRTROM_AUT_MAX           ; startpos of filenames
CRTROM_AUT_FILE .BLOCK FAT32$FDH_STRUCT_SIZE    ; file handle to autoload ROMs
