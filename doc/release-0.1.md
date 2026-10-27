# PC10-III for MEGA65 0.1

The first release: a cycle-exact Commodore PC10-III (IBM PC/XT compatible)
for the **MEGA65 R6**. It runs the Commodore BIOS 4.41 and Commodore MS-DOS
3.21 from floppy images and from the hard disk. Everything below was tested
on a MEGA65.

## What is in it

- **The 8088, cycle exact:** nand2mario's z8086 execution unit running
  Intel's own 8088 microcode (loaded from the SD card), with a bus interface
  unit that steps like the real chip's. It matches the hardware-generated
  SingleStepTests 8088 suite on every cycle of 3,006,693 of its 3,007,000
  tests.
- **The Faraday FE2010A chipset** of the PC10-III, with the turbo: 4.77, 7.16
  and 9.54 MHz with its wait states (Ctrl-Alt-S / T / D, SETUP, SPEED.EXE).
  Or an IBM XT's 8255 for IBM-compatible BIOSes.
- **The onboard Paradise PVC4 video:** colour (CGA, Plantronics) or
  monochrome (MDA, Hercules) in green, amber or white; the Commodore
  character ROM with its USA/Europe and Scandinavian sets.
- **640, 512, 256 or 128 KB.**
- **Floppy drives A: and B:** images of 160K to 720K, read and write.
  <!-- intfd: cut the next sentence if it misses 0.1 -->
  B: can also be the MEGA65's internal 3.5" drive with real 720K disks.
- **The hard disk C:**, the PC20-III's 20 MB WD93024-X, as an image on the SD
  card, remembered across power-off.
  <!-- dfolder: cut the next sentence if it misses 0.1 -->
  A folder of the SD card as a second, read-only hard disk.
- **The battery clock**, set from and written back to the MEGA65's clock.
  <!-- ports: cut the next item if it misses 0.1 -->
- **Serial and printer ports** on the PMOD headers, **the bus mouse** with an
  Amiga or Atari ST mouse in joystick port 1, **a Covox** on the printer port.
- **The PC speaker**, the keyboard with a MEGA layer for End, PgUp, PgDn,
  Ins, Del and keypad -, the drive LED, drive sound on the internal drive.
- **HDMI** 720p 60 Hz, 480p 59.94 Hz or 720p 50 Hz, and **analog** VGA or
  15 kHz RGB.

## Installing

1. Copy the package's `pc10` folder to the root of a FAT32 SD card. It holds
   `ucode.bin`, the 8088 microcode (see below).
2. Download the Commodore BIOS 4.41 and character ROM from zimmers.net and
   rename them to `/pc10/bios.rom` and `/pc10/char.rom`:
   - https://www.zimmers.net/anonftp/pub/cbm-pc/firmware/pc10/cbm-pc10c-bios-v4.41-318085-08.bin
     (md5 `598a1adee2a9ddaa5b0d4b73190ff990`)
   - https://www.zimmers.net/anonftp/pub/cbm-pc/firmware/pc10/cbm-pc10c-char-318086-03-e53c.bin
     (md5 `3dff8618da06c084bb2302a338501f8c`)
3. MS-DOS 3.21 (Commodore Colt), two 360K images:
   https://www.zimmers.net/anonftp/pub/cbm-pc/software/Commodore_COLT_MS-DOS_v3.21.zip
4. For a hard disk: `blank-hd20.img` from the package, then FDISK and
   `FORMAT C: /S` from DOS disk 1.
5. Flash `PC10-III-0.1-R6.cor` into a core slot (or load the `.bit` by JTAG).

The README has the details: the menu, the keys, the hard disk set-up step by
step, the limitations.

## The microcode

`pc10/ucode.bin` is Intel's 8088 microcode, made with `tools/mkucode.py`
from Andrew Jenner's public archive. It is Intel's property, not part of the
core and not covered by its GPL-3.0; it is shipped as a separate file so that
the core works out of the box, and it will be withdrawn if Intel asks
(`pc10/UCODE-NOTICE.txt`). The core's source and bitstream contain none of
it. You can make the same file yourself:
`python3 tools/mkucode.py --jenner 8086_microcode_v2.zip -o ucode.bin`.

## Known limitations

- MEGA65 R6 only; R3, R4 and R5 have no bitstream yet.
- 8088 MPH hangs in its sprite part (being investigated; the demo is written
  for IBM's CGA card, which the PC10-III does not have).
- Floppy images are not remembered across power-off; no 1.2M/1.44M disks.
  <!-- intfd: cut the next item if intfd misses 0.1 -->
- `FORMAT B:` on the internal drive makes a 360K disk: MS-DOS 3.21 sets up
  the PC10-III's floppy drives as 360K drives, as on the real machine; 720K
  disks formatted elsewhere work.
- C: has the PC20-III's 20 MB only.
- The monochrome display is shown on HDMI only.

## Package

| File | |
|---|---|
| `PC10-III-0.1-R6.cor` | the core, for the flash menu |
| `PC10-III-0.1-R6.bit` | the bitstream, for JTAG |
| `pc10/ucode.bin`, `pc10/UCODE-NOTICE.txt` | the 8088 microcode and its notice |
| `blank-hd20.img` | an empty hard disk for C: (21,411,840 bytes) |
| `README.md`, `LICENSE`, `RELEASE-NOTES.md` | the README, GPL-3.0, these notes |
| `tools/mkucode.py`, `tools/mkblankhd.py` | the microcode bundle and empty hard disks, made yourself |

No Commodore ROM or DOS is included.
