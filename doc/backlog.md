# Backlog

Features asked for but not started, in no fixed order unless noted. Work in
progress and finished increments are in `doc/history.md`.

## Drive B: image or the internal drive (asked 2026-10-26, simplified)

The drive type of an image needs no choice: pc_fdd_sd.vhd already sets the
drive's tracks from the image size (`drv_80trk`: 40 tracks for 160K-360K, 80
for 720K), live at every mount, no reset. What remains is a choice of two,
as a horizontal radio row like the Megamiga menus (Megamiga's "menu rows",
M2M exception 21: `M2M/rom/menu_rows.asm`, `OPTM_ROWS` in config.vhd, Megamiga
main cb4e6c3; this project's M2M copy predates it and needs that port first)
or a plain toggle:

    B:  image   int. drive

- **image:** as today (the " B:%s" line).
- **int. drive:** the MEGA65's internal 3.5" floppy drive as B:, reading and
  writing real disks (Megamiga's Hardware Floppy, `CORE/vhdl/physical_fdd/`,
  is the model; the drive LED and drive sound already follow the internal
  drive). An 80-track DD drive: 720K disks; 1.44M needs the AT controller
  (doc/fdc.md section 7).

To verify first: **720K on this machine has never been tested.** The
Commodore BIOS 4.41 has no floppy type setting (SETUP only switches the
on-board FDC), and DOS 3.21 may need `DEVICE=DRIVER.SYS` (on the Colt disk;
it adds a new drive letter) to use an 80-track drive; a tb/sys run with a
720K image in B: under DOS 3.21 answers it. The hardware switch itself
(image <-> internal drive, 40 <-> 80 tracks) needs no reset; DOS rereads a
disk's boot sector when it suspects a change.

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
  extra LFN entries before it), so D: uses the card's own
  short name: unique per folder, and the same name a PC shows for the file.
  No fallback of our own (decided 2026-10-26): every FAT32 entry has one.
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

## Sound Blaster 2.0 with the CMS chips (asked 2026-10-26)

An 8-bit ISA Sound Blaster 2.0 (DSP 2.01) with the two Philips SAA1099 in its
C/MS sockets (the SB 1.0 shipped with them; the 1.5 and 2.0 kept the sockets
for an upgrade kit). One card gives AdLib music, Game Blaster music and digital
sound: nearly every sound option of the 1987-1991 games that run on an 8088.

- **Ports** (base 220h, as the card's default):
  - CMS: 220h-223h (chip 1 data/address, chip 2 data/address);
  - DSP: 226h reset, 22Ah read data, 22Ch write command/data + write status,
    22Eh read-buffer status (reading it acknowledges the interrupt);
  - FM (OPL2): 388h-389h (AdLib) and 228h-229h.
- **IRQ 7** (IRQ 5 is the hard disk controller's), **DMA channel 1** (free:
  0 = refresh, 2 = floppy, 3 = hard disk; `isa_drq[1]` of xt_board.sv).
- **DSP:** the 2.01 command set: direct DAC (10h), single-cycle and auto-init
  8-bit DMA (14h, 1Ch, 48h block size), high-speed DMA (90h/91h), time
  constant (40h), the ADPCM modes (74h-7Fh, a few games use them), halt/continue
  (D0h/D4h), speaker on/off (D1h/D3h), version E1h = 2.01, E0h, F2h (IRQ test);
  direct ADC (20h) returns silence (no input). The SB's own MIDI port (30h-38h)
  only if it is cheap: almost no game uses it.
- **Clocks, exact from the core clock:** OPL2 3.579545 MHz = 28.63636 MHz / 8,
  SAA1099 7.15909 MHz = / 4.
- **Cores to look at** (licence check first; the core is GPLv3): Jotego's jtopl
  (OPL2, GPL-3), the SAA1099 and the Sound Blaster DSP of the MiSTer cores
  (ao486, PCXT).
- **Mixer:** PC speaker + OPL2 + CMS (the SAA1099s are stereo; check whether
  the SB 1.x/2.0 output mixes them to mono) + DAC into main.vhd's 16-bit
  outputs, without clipping. The PC speaker's low-pass (the framework's audio
  filter, today off) is a separate small item.
- **Menu:** a line to switch the card on/off (a card that is off answers
  nothing, like an empty slot).
- **Tests:** a TB per part (OPL2 register/timer/status reads, as games detect
  the AdLib by its timers; DSP reset/version/DMA/IRQ; SAA1099 registers), then
  on the hardware: a game's setup that probes the card (Sierra SCI0: AdLib,
  Game Blaster and Sound Blaster drivers), digital sound by DMA.

## Other open items

- A changed SD card is not noticed (Megamiga re-checks the card generation).
