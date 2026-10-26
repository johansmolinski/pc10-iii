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

## Other open items

- A changed SD card is not noticed (Megamiga re-checks the card generation).
