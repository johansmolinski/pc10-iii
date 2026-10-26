# Backlog

Features asked for but not started, in no fixed order unless noted. Work in
progress and finished increments are in `doc/history.md`.

## Drive B: type selector (asked 2026-10-26)

Drive B: selectable on one menu line, as a horizontal radio row like the
Megamiga menus (Megamiga's "menu rows", M2M exception 21: `M2M/rom/menu_rows.asm`,
`OPTM_ROWS` in config.vhd, Megamiga main cb4e6c3; this project's M2M copy
predates it and needs that port first):

    B:  v. 5.25"   v. 3.5"   int. drive

- **v. 5.25":** a virtual 40-track drive with an image file (160K-360K), as B:
  is today when it holds a 40-track image.
- **v. 3.5":** a virtual 80-track 720K drive with an image file.
- **int. drive:** the MEGA65's internal 3.5" floppy drive as B:, reading and
  writing real disks (Megamiga's Hardware Floppy, `CORE/vhdl/physical_fdd/`,
  is the model; the drive LED and drive sound already follow the internal
  drive). DD only: 1.44M needs the AT controller (doc/fdc.md section 7).

Open: the drive type as the FDC sees it (40 vs 80 tracks, today taken from
the image size: `drv_80trk`), what B:'s image line shows for the internal
drive, the settings file signature and the menu heap (doc/m2m-shell.md).

## Remember the hard disk across power-off (decided 2026-10-26)

The C: image is mounted again at power-up; **the floppies are not** (A: and
B: start empty, as today). Megamiga keeps such paths in the settings file's
text (M2M exception 17, `CFGS_*`, already in this project's M2M for the
menu signature): a key like `hdc=SD1:/pc10/hd20.img`, written when C: is
mounted or ejected (SPACE), applied at start-up before the PC leaves reset
(the extent map through PREP_LOAD_IMAGE's path); a missing or wrong-size file
leaves C: empty with a message.

## D: from a folder of the SD card, read-only (asked 2026-10-26)

A folder of the SD card as a hard disk that DOS reads without a driver: the
WD93024-X's **drive 1** on the same controller (the Commodore disk BIOS probes
drive 1 at every boot and counts it, doc/xta.md section 6), so DOS 3.21 sees
a second hard disk: D: (C: when no C: image is mounted).

- **Choosing the folder:** the menu line opens the file browser and the user
  picks a **subdirectory** (not the whole card or `pc10`, because of the size
  limit). The M2M browser selects files and enters folders, so it needs a
  "use this folder" entry: the core callback `BROWSE_EXTRA` (M2M exception 17,
  already used by Megamiga for partitions) can list one behind `<..>`.
- **A virtual FAT16 disk:** at the PC's reset the firmware walks the folder
  (and its subfolders) and builds the metadata of a FAT16 disk: MBR with one
  partition, boot sector, two FATs, root and subdirectories. The data sectors
  are the files themselves, read from the SD card through extent maps (as
  pc_fdd_sd.vhd does for the images). Nothing is copied.
- **Read-only:** writes end with a write-protect error (WD sense code); DOS
  reports it.
- **Names (decided 2026-10-26):** long names become 8.3 aliases by the FAT
  convention, `VeryLongName.file` -> `VERYLO~1.FIL`. The card's FAT32 already
  stores such a short name in every directory entry (the long name sits in
  extra LFN entries before it), so the first choice is to use the card's own
  short name: unique per folder, and the same name a PC shows for the file.
  Only where that is not usable, generate one: upper case, characters DOS does
  not allow dropped or `_`, the first 6 characters + `~1` (`~2`.. on a clash,
  then 5 characters + `~10`..), the first 3 characters of the last extension.
- **Limits:** the size of one drive type of the BIOS table (21.4 MB like C:;
  the WD's "dynamic configuration", geometry from sector 0, might allow up to
  DOS 3.21's 32 MB); files that do not fit are left out; a snapshot at reset
  (changes on the card appear after the next reset).
- **Where the metadata lives:** FATs and directories of a 21 MB FAT16 disk
  are some 40-60 KB plus the per-file extent maps: block RAM if it fits,
  else the HyperRAM.
- **Not remembered** across power-off (decided 2026-10-26): D: starts
  empty, like the floppies.
- **Open:** the drive type in the 322h configuration register (bits 3-2); test
  ready for drive 1 when nothing is mounted (today it answers OK,
  `DRV1_READY`); a menu line or a radio row next to C:.

## Other open items

- A changed SD card is not noticed (Megamiga re-checks the card generation).
