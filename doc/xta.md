# The PC20-III hard disk (plan)

Status: plan, 2026-10-25. Nothing built yet.

## 1. What the real machine has

The service manual (German PC10/20-III technical manual, chapter 7.0 "Adding a
Hard Disk to a PC10", page 7-1/7-2; rendered pages in `~/pcxt-work/manual/`,
p44/p45, not in the repository):

- The PC20-III has a 3.5" 20 MB drive **without a controller card**: it plugs
  into motherboard connector **CN202** with a **40-conductor** ribbon cable.
  Commodore sold the same drive as an upgrade kit for the PC10-III; jumper
  **JMP208** must be moved for it (position B = Commodore hard disk, position
  A = none / a controller card in a slot). "The special drive may only be used
  when no other hard disk controllers/disks are in the system."
- Low-level format: `DEBUG`, `G=FA00:5` prints "WX2 Format Revision 1.08
  (C) Copyright Western Digital Corp. 1986" and asks for drive, interleave (3)
  and "dynamically configuring" (answer N for the Commodore drive).
- The BIOS ROM (318085-xx, 32 KB) carries the disk BIOS in its lower half:
  "IDE Superbios Rev. 1.0 (C) Copyright Western Digital Corp. 1988", the WX2
  format program at FA00:5, "Hard disk not found".

So the drive is a Western Digital **XT-IDE / XTA** drive: the controller is on
the drive and speaks the IBM XT fixed-disk controller interface (the Xebec
1210 / WD1002S-WX2 register set and command blocks), and the motherboard has
only the host side (buffers, address decode, DMA/IRQ wiring). Not an MFM card
and not the later XTIDE. The ROM's disk code confirms the interface:

- I/O base **320h** (kept in BIOS data byte 0040:004C), status read at 322h;
- **DMA channel 3** (8237 ports 06h/07h, page register 82h, mask 0Ah,
  mode 0Bh), **IRQ 5** (PIC mask through 21h);
- it also touches D4h/D6h (the AT's second 8237) - to be understood.

## 2. The interface (to be confirmed from the ROM, then from references)

IBM XT fixed-disk controller (Xebec / WD1002-WX2 compatible), 8-bit:

| Port | Read | Write |
|---|---|---|
| 320h | data (status byte, sense bytes, sector data in PIO) | data (command block, parameters) |
| 321h | hardware status (REQ, I/O, C/D, BSY, interrupt) | controller reset |
| 322h | drive configuration (jumpers / drive type) | controller select |
| 323h | - | DMA and interrupt enable mask |

Command control block (6 bytes): opcode, head/drive, sector/cylinder high,
cylinder low, block count, control (step rate, retries). Commands: test
drive ready (00), recalibrate (01), request sense (03), format drive (04),
verify (05), format track (06), format bad track (07), read (08), write (0A),
seek (0B), initialize drive characteristics (0C), read ECC burst length (0D),
read/write sector buffer (0E/0F), diagnostics (E0, E3, E4), the WD
"dynamic configuration" variants. Exact list, status/sense codes and the
handshake (REQ, C/D, I/O phases) come from the ROM disassembly (ground truth:
it is the code that has to run) and are cross-checked with:

- MartyPC's Xebec controller (`devices/hdc/xebec.rs`, MIT) - also a timing
  reference;
- 86Box `hdc_xta.c` (WD XTA drives incl. the WDXT-150) and `hdc_st506_xt.c`
  (Xebec, WD1002A-WX1/-27X; GPL);
- WD's WD1002S-WX2 / WDXT-GEN documentation if it can be found.

## 3. Design

- `rtl/hdc/xta_card.sv`: the motherboard host side + the drive's embedded
  controller as one card on the board's card bus (doc/architecture.md section
  3): register decode at 320h-323h (JMP208 = enable, a menu setting), the
  command/status state machine with the bus phases, a 512-byte sector buffer
  (`hdc_secbuf.sv` from the XTIDE work), DMA requests on DRQ3 (the 8237 path
  the floppy uses on DRQ2), IRQ5.
- The drive: geometry of the original 20 MB drive (to find: cylinders x heads
  x 17 sectors; the WX2 tables in the ROM name it), plus the WD "dynamic
  configuration" for other sizes if the BIOS supports it. Timing modelled on
  a real drive: 3600 rpm, 17 sectors per track, interleave 3 (the format
  default), step/seek times, the controller's command overhead - so disk
  benchmarks of the era give period numbers, as the floppy does.
- Backend: the image on the SD card through the existing sector engine port
  (as `pc_fdd_sd.vhd` does for the floppies; doc/hdc.md section 8 describes
  the XTIDE plan for the same port). A raw image (cylinders x heads x 17 x
  512, no header); the shell's file browser picks it, the menu shows it.
- Writes go back to the SD card (write-through, as the floppies).
- The drive LED shows its activity (the MEGA65 drive LED; colour to agree).
- The existing XTIDE card (`rtl/hdc`) stays in the repository; it is not the
  machine's own disk and is not wired into the shell.

## 4. Steps

1. Disassemble the ROM's disk BIOS (F8000-F9FFF) and the WX2 format program
   (FA00:5): ports, handshake, every command and parameter it uses, the drive
   table, what JMP208 changes (how "Hard disk not found" is decided).
2. Collect the references (MartyPC, 86Box, WD documents) and write the
   register/command specification here, with the timing.
3. `xta_card.sv` + a unit testbench against a command-level model; mutants.
4. tb/sys: the Commodore BIOS finds the drive ("Hard disk not found" gone),
   the WX2 low-level format runs, FDISK/FORMAT from a DOS floppy, then a boot
   from C:. A blank image and a prepared image.
5. Shell: menu (image, JMP208 on/off), SD backend, LED, settings signature.
6. Build, hardware test.

## 5. Open questions

- The exact drive model of the PC20-III and its geometry.
- Whether the PC10-III's CN202 host logic adds anything beyond the standard
  XT controller ports (the schematics in the manual's chapter 9 show the
  motherboard: check CN202's signals).
- Which BIOS the user runs without the Commodore ROM: GLaBIOS has no disk
  BIOS; the WD BIOS is part of Commodore's ROM. A free option ROM for this
  interface (if any) would be needed for GLaBIOS users.
