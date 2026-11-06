# PC10-III for MEGA65 0.1.1

The second release of the cycle-exact Commodore PC10-III (IBM PC/XT
compatible). It adds the **MEGA65 R3 and R3A** next to the R6, an **IBM CGA
card** in an expansion slot, and a fix for HDMI after the reset button.
Everything else is as in 0.1 (its notes and the README describe the core).

## New

- **MEGA65 R3 and R3A:** `PC10-III-0.1.1-R3.cor` for the R3 and R3A next to
  `PC10-III-0.1.1-R6.cor` for the R6. The core keeps the PC's memory in the
  FPGA and needs no SDRAM, so it runs on the first MEGA65s. Tested on an
  R3A: it boots from the SD card in the back slot, with HDMI and VGA, and
  HDMI comes back after the reset button; sound from the 3.5 mm jack and
  the battery clock (a different chip on the R3) work.
- **An IBM CGA card in a slot:** `Display` > `IBM CGA card` puts IBM's
  Color/Graphics Adapter into an expansion slot of the PC10-III, as the
  service manual allows; the Commodore BIOS then leaves the onboard video
  off by itself. The card has IBM's timing: its wait states, its 6845 and
  its snow, for programs written for an IBM PC with that card. Tested on an
  R6: it works and it snows. The choice restarts the PC.
- **HDMI after the reset button:** HDMI comes back after a reset. In 0.1 a
  reset could leave static vertical bars on HDMI until the MEGA65 was
  switched off (VGA was fine). A framework fix taken over from Megamiga and
  upstream.

## Updating from 0.1

Flash the new `.cor` for your board. The menu has one entry more (the CGA
card), so the core's settings file from 0.1 is not taken over: the menu
settings go back to their defaults once on the first start; the hard disk C:
is still mounted. The files in `/pc10` stay as they are; `ucode.bin`, the
ROMs and the disks are the same as in 0.1.

## Installing

1. Copy the package's `pc10` folder to the root of a FAT32 SD card. It holds
   `ucode.bin`, the 8088 microcode (see below), the Commodore BIOS 4.41 and
   character ROM (`bios.rom`, `char.rom`), MS-DOS 3.21 (`dos321-1.img`,
   `dos321-2.img`) and `ports.img`, a test disk for the mouse and the Covox
   (`pc10/EXTRAS-NOTICE.txt`: whose they are). That is all the core needs.
2. For a hard disk: `blank-hd20.img` from the package, then FDISK and
   `FORMAT C: /S` from DOS disk 1.
3. Flash the `.cor` for your board into a core slot: `PC10-III-0.1.1-R6.cor`
   on an R6, `PC10-III-0.1.1-R3.cor` on an R3 or R3A. With a JTAG adapter
   the `.bit` of the same name loads directly.

The README has the details, and where the ROMs and DOS come from if you
prefer your own.

## The microcode

`pc10/ucode.bin` is Intel's 8088 microcode, made with `tools/mkucode.py`
from Andrew Jenner's public archive. It is Intel's property, not part of the
core and not covered by its GPL-3.0; it is shipped as a separate file so that
the core works out of the box, and it will be withdrawn if Intel asks
(`pc10/UCODE-NOTICE.txt`). The core's source and bitstreams contain none of
it. You can make the same file yourself:
`python3 tools/mkucode.py --jenner 8086_microcode_v2.zip -o ucode.bin`.

## Known limitations

- **R3/R3A, not tested yet:** the MEGA65's internal drive as B:, the PMOD
  ports. The original R3 (not R3A) has not
  been tried at all; its PCB cannot detect a card in the internal SD slot,
  so use the back slot there.
- **"Cannot mount SD card"** right after loading the core by JTAG over
  another core: the card can be left in a state that only losing power
  clears. Switch the MEGA65 off and on.
- R4 and R5 have no bitstream yet.
- **8088 MPH** hangs in its sprite part on the onboard video. With the IBM
  CGA card it has not been tried yet.
- Floppy images are not remembered across power-off; no 1.2M/1.44M disks.
- `FORMAT B:` on the internal drive makes a 360K disk (MS-DOS 3.21 sets up
  the PC10-III's drives as 360K drives); 720K disks formatted elsewhere work.
- C: has the PC20-III's 20 MB only.
- The monochrome display is shown on HDMI only.
- The serial and printer ports on the PMOD headers are not tested on
  hardware yet.

## Package

| File | |
|---|---|
| `PC10-III-0.1.1-R6.cor`, `PC10-III-0.1.1-R6.bit` | the core for the R6: for the flash menu, for JTAG |
| `PC10-III-0.1.1-R3.cor`, `PC10-III-0.1.1-R3.bit` | the core for the R3 and R3A |
| `pc10/ucode.bin`, `pc10/UCODE-NOTICE.txt` | the 8088 microcode and its notice |
| `pc10/bios.rom`, `pc10/char.rom` | the Commodore BIOS 4.41 and character ROM |
| `pc10/dos321-1.img`, `pc10/dos321-2.img` | Commodore MS-DOS 3.21, disks 1 and 2 |
| `pc10/ports.img` | a test disk for the mouse and the Covox (MOUSE.COM, MTEST, COVOX) |
| `pc10/EXTRAS-NOTICE.txt` | whose the ROMs and disks are |
| `doc/img/pc10-logo-horizontal.svg` | the logo the README shows |
| `blank-hd20.img` | an empty hard disk for C: (21,411,840 bytes) |
| `README.md`, `LICENSE`, `RELEASE-NOTES.md` | the README, GPL-3.0, these notes |
| `tools/mkucode.py`, `tools/mkblankhd.py` | the microcode bundle and empty hard disks, made yourself |

The Commodore ROMs and MS-DOS are Commodore's and Microsoft's, not covered
by the core's GPL-3.0; they are included so that the core runs out of the
box, and will be removed if their owners ask.
