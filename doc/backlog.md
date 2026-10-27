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

## An IBM CGA card instead of the onboard video (asked 2026-10-26)

A menu choice **Video: onboard (PVC4) / IBM CGA card**: the PC10-III with an
IBM CGA (or a faithful clone) in an expansion slot, the onboard video off.
Authentic: the service manual (SM 5-1, doc/pvc4.md section 7) describes it:
with an expansion adapter of the same kind as the straps (colour for a
colour-strapped PVC4) the onboard video stays disabled. The Commodore BIOS 4.41
does it by itself: at F000:E431 it writes to B800:7Bh with the onboard video
off (230h bit 7 = venb' = 1) and reads back; a card that answers keeps the
onboard video off. Why: demos and games written for the IBM 5150 + CGA
(8088 MPH, Area 5150) depend on the IBM card's timing (its wait states, its
6845, snow), which the PVC4 does not have (8088 MPH's hardware check fails
and the demo hangs in its sprite part on pc10-real-u, 2026-10-26; analysis in
doc/history.md when done).

- **The model exists:** `cga_card.sv` + `cga_crtc.sv` (doc/cga.md, verified
  against MartyPC: wait states, snow, CRTC), `pc_system`'s `CGA_FIT` next to
  `PVC4_FIT`. Today the video output is chosen at build time
  (`PVC4_FIT ? pvc : cga`); with both fitted it must follow the BIOS's choice
  at run time (230h bit 7: venb' = 1 -> the CGA's picture, through the same
  RGBI path and the same 59.92 Hz HDMI/analog timing).
- **Menu:** a line in the video submenu; a change restarts the PC (a card is
  plugged in with the power off), like colour <-> mono. With the CGA card the
  PVC4 stays colour-strapped (DIP switch 2 on): a mono-strapped PVC4 plus a
  CGA would be two displays at once (SM 5-1 allows it), and the core has one
  output. So "IBM CGA card" implies colour, and the Display line's mono
  entries do not apply.
- **Font:** the CGA card has its own character ROM (IBM layout, 8 KB). The
  kit's `char.rom` is the PC10-III's 32 KB Commodore layout (`font_cbm`); the
  CGA needs an IBM-layout image (`font_addr_hi` = 0): a separate SD file
  (e.g. `/pc10/cga.rom`, the user's own dump) or the 8x8 glyphs taken from
  the Commodore ROM by the loader. To decide; no IBM ROM in the repo.
- **Resources:** about 480 LUTs, 415 flip-flops, 6 BRAM tiles (doc/cga.md);
  BRAM is at 260.5/365.
- **Tests:** tb/sys with both fitted: the BIOS's probe finds the CGA and
  leaves the PVC4 off (230h bit 7, 40:70h); 8088 MPH's hardware check and
  CGA_COMP's video RAM speed (340 KB/s on an IBM CGA) in simulation, then on
  the hardware.
- **Later:** CGA composite colour (doc/plan.md section 4), the colours
  8088 MPH and Area 5150 are drawn for; on RGB they look like
  black-and-white stripes.

## Composite colour (asked 2026-10-26)

An NTSC composite colour monitor as a menu choice: the CPU draws dot patterns
in 640x200 (or 320x200) that a composite monitor shows as 16 or more
"artefact" colours (8088 MPH, Area 5150, many games of the time with a
"composite" option: Sierra AGI, Microsoft Flight Simulator, Ultima...). On RGB
they look like black-and-white stripes. The MEGA65 has no composite output, so
the core models the composite signal digitally and decodes it to RGB for HDMI
and the analog RGB output, as emulators do (doc/plan.md section 4).

- **Both video sources have a composite output:**
  - **the IBM CGA card** (the backlog item above): the card already exports
    the raw signals (doc/cga.md section 7: `comp_cphase`, `comp_hsync`,
    `comp_burst`, `comp_vsync`, `comp_bw`, `comp_mode`). Old CGA (1981) and
    new CGA (1983 on) differ only here (the new one adds R, G, B to the
    luminance): a menu choice, as 8088 MPH has a setting for each.
  - **the PC10-III's onboard PVC4:** CMPVD and CSYNCN to the RCA jack CN603
    through Q601 (doc/pvc4.md section 5, today "not modelled"). To research
    first: how the PVC4 forms CMPVD (data sheet DS 4-5): colour or mono
    composite, the chroma phases, whether its artefact colours match the
    IBM CGA's.
- **The model:** the composite signal at 4 samples per colour carrier cycle
  (14.318 MHz = 4 x 3.579545 MHz, the CGA's dot clock, fixed to the dot
  phase; the power-up phase offset of a real card is a parameter), then an
  NTSC decoder: luma/chroma separation (a filter over a few carrier cycles),
  I/Q demodulation against the burst phase, YIQ -> RGB, at the dot rate into
  the existing video path. References for the behaviour: reenigne's CGA
  composite analysis, MartyPC's and 86Box's decoders, Graphics Gremlin's
  `cga_composite.v` (CC BY-SA 4.0: behaviour only, no code). Licence check
  before taking anything.
- **Menu:** `Monitor: RGB / composite` (with the CGA card: old / new CGA). The
  mode register's "black and white" bit (bit 2) kills the colour burst: the
  monitor then shows grey levels, as a real one does.
- **Tests:** a TB that compares the decoded colours of the 16 RGBI colours and
  the standard artefact palettes (640x200 with each colour register value)
  with reference values (MartyPC / reenigne's tables), then 8088 MPH's
  composite parts and a Sierra game on the hardware.
- **Cost:** a few DSPs for the filter and the YIQ matrix, a little logic; no
  extra memory.

## Before release 0.1: serial port, parallel port, bus mouse (asked 2026-10-26) - DONE

Done 2026-10-26 (branch `ports`, build `pc10-ports-c`; doc/ports.md,
doc/history.md): the INS8250 at 3F8h/2F8h, the parallel port (IBM's printer
adapter for the PPC1) at 3BCh/378h/278h, both on the PMOD headers behind one
menu item ("Ports and mouse > PMOD: serial + printer"), the Covox Speech Thing
on the parallel port's latch mixed with the speaker, the 5720's bus mouse with
an Amiga or Atari ST mouse in joystick port 1. Left open (doc/ports.md section
9): the PPC1's own details, the right/middle buttons of a passive mouse (a
MEGA65 limitation: active adapters only), the 1351 in proportional mode.

## Other open items

- A changed SD card is not noticed (Megamiga re-checks the card generation).
