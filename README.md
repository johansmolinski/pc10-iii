# PC10-III for MEGA65

A cycle-exact Commodore PC10-III (IBM PC/XT compatible) for the MEGA65, by
Johan Smolinski, built on the MiSTer2MEGA65 framework (the
[Megamiga](https://github.com/johansmolinski/Megamiga) fork of it).

The PC10-III was Commodore's XT of 1988: an 8088 at 4.77, 7.16 or 9.54 MHz,
the Faraday FE2010A chipset, 640 KB, onboard video (a Paradise PVC4: CGA, MDA
and Hercules compatible), a battery clock, and serial, parallel and mouse
ports on the board; the PC20-III added a 20 MB hard disk. The core rebuilds
that machine bus cycle by bus cycle. Its 8088 runs Intel's own microcode, one
micro-instruction per clock as the real chip does, and matches the
hardware-generated [SingleStepTests 8088](https://github.com/SingleStepTests/8088)
suite on every cycle of 3,006,693 of its 3,007,000 tests (and in registers
and memory on all of them).

**Version 0.1** is the first release. It runs the Commodore BIOS 4.41 and
Commodore MS-DOS 3.21 from floppy images and from the hard disk; every feature
below was tested on a MEGA65. It is built for the **MEGA65 R6** only (see
[Boards](#boards)).

- [Features](#features)
- [Boards](#boards)
- [Installing](#installing)
- [First start](#first-start)
- [Using the core](#using-the-core)
- [Known limitations](#known-limitations)
- [Credits](#credits)
- [For developers](#for-developers)
- [Licence](#licence)

## Features

- **The 8088**, cycle exact: nand2mario's z8086 execution unit running Intel's
  8088 microcode, in front of a bus interface unit that steps like the real
  chip's. The microcode is loaded from the SD card at every start
  ([The microcode](#the-microcode)).
- **The PC10-III's chipset**, the Faraday FE2010A, with its turbo: 4.77, 7.16
  and 9.54 MHz with the FE2010A's wait states, switched with the Commodore
  BIOS's Ctrl-Alt-S / T / D, its SETUP or SPEED.EXE. Or, chosen in the menu,
  an IBM PC/XT's 8255 (5160) for IBM-compatible BIOSes, at 4.77 MHz.
- **The onboard video**, the Paradise PVC4: colour (CGA compatible, with the
  Plantronics ColorPlus modes, no snow) or monochrome (MDA and Hercules
  compatible) in green, amber or white; the Commodore character ROM with its
  USA/Europe and Scandinavian character sets.
- **640, 512, 256 or 128 KB** of memory.
- **Floppy drives A: and B:** as disk images on the SD card (160K, 180K,
  320K, 360K, 720K), read and write, with write protection.
  <!-- in-flight: branch intfd (cut the next sentence if it misses 0.1) -->
  Or drive B: as the MEGA65's internal 3.5" drive, reading and writing real
  720K disks ([B: as the internal drive](#b-as-the-internal-drive)).
- **The hard disk C:**, the PC20-III's 20 MB drive (a Western Digital
  WD93024-X, which the Commodore BIOS drives itself), as an image on the SD
  card, read and write; the image is remembered across power-off.
  <!-- in-flight: branch dfolder (cut the next sentence if it misses 0.1) -->
  And a folder of the SD card as a second, read-only hard disk
  ([A folder of the SD card as a hard disk](#a-folder-of-the-sd-card-as-a-hard-disk)).
- **The battery clock** (an MSM6242B, as on the board): set from the MEGA65's
  battery clock at power-up, and written back to it when DOS's SETCLOCK or the
  BIOS SETUP sets the time.
- **The PC speaker.**
  <!-- in-flight: branch ports (cut the next item if it misses 0.1) -->
- **The ports of the board** ([Ports, mouse and Covox](#ports-mouse-and-covox)):
  the serial port (an 8250) and the printer port on the MEGA65's PMOD
  headers; the bus mouse with an Amiga (or Atari ST) mouse in joystick port 1,
  as the PC10-III's own mouse was an Amiga mouse; a Covox Speech Thing on the
  printer port, into the MEGA65's sound.
- **The keyboard** as an 83-key XT keyboard, with a MEGA layer for the keys
  the MEGA65 lacks (End, PgUp, PgDn, Ins, Del, keypad -).
- **The drive LED**: yellow while a floppy drive is selected, red while the
  hard disk works. **Drive sound**: the MEGA65's internal drive plays the
  motor and the head steps of the floppy images.
- **Video out**: HDMI (720p 60 Hz, 480p 59.94 Hz or 720p 50 Hz) and, at the
  same time, analog VGA, or 15 kHz RGB with separate or composite sync for a
  CRT.

## Boards

Release 0.1 is built for the **MEGA65 R6** only. The project's goal is every
board from R3 on: the core keeps the PC's memory in the FPGA's block RAM and
needs no SDRAM, so it fits the R3. But there is no R3, R4 or R5 bitstream
yet: the framework's R3 board top lacks what the core needs for the SD cards
(doc/m2m-shell.md section 12), and R4/R5 builds have not been made or tested.

## Installing

### What you need

| File on the SD card | What | Where from |
|---|---|---|
| `/pc10/ucode.bin` | the 8088's microcode, **required** | the release package, or made yourself ([The microcode](#the-microcode)) |
| `/pc10/bios.rom` | the Commodore BIOS 4.41, **required** | zimmers.net ([The Commodore ROMs](#the-commodore-roms)) |
| `/pc10/char.rom` | the Commodore character ROM, recommended | zimmers.net |
| disk images | MS-DOS and your programs | [MS-DOS](#ms-dos), [The hard disk C:](#the-hard-disk-c) |
| `/pc10/pc10cfg` | the settings | the core creates it |

The core stops at start-up with a message if `ucode.bin` or `bios.rom` is
missing or not valid. Without `char.rom` it uses a free font of its own that
has only the first 128 characters (no line-drawing characters).

The SD card must be FAT32 (cards up to 32 GB). The core's file browser
starts in `/pc10`; disk images can be anywhere on the card.

### The microcode

The core's 8088 needs Intel's 8088 microcode, which is not part of the core:
neither its source nor its bitstream contains any of it. The release package
has it as the separate file `pc10/ucode.bin`, with the notice
`pc10/UCODE-NOTICE.txt`: the microcode is Intel's property, it is not covered
by the core's licence (GPL-3.0), and it will be withdrawn from the package if
Intel asks. Copy the package's `pc10` folder to the root of the SD card.

You can also make the file yourself, byte for byte the same, from Andrew
Jenner's public archive of the 8086/8088 microcode (which he read off Ken
Shirriff's die photos), with Python 3 and `tools/mkucode.py` (in the package's
`tools` folder and in this repository):

```sh
curl -O https://www.reenigne.org/misc/8086_microcode_v2.zip
python3 tools/mkucode.py --jenner 8086_microcode_v2.zip -o ucode.bin
```

The result is 6144 bytes with the md5 `38d6a32ee095f280af7fc9c704e13d8c`;
copy it to `/pc10/ucode.bin`.

### The Commodore ROMs

The BIOS and the character ROM are Commodore's and are not included. Bo
Zimmerman's archive has them:
[zimmers.net/anonftp/pub/cbm-pc/firmware/pc10/](https://www.zimmers.net/anonftp/pub/cbm-pc/firmware/pc10/).
The core was tested with these two files; download them and rename them:

| Download | Rename to | Size | md5 |
|---|---|---|---|
| [cbm-pc10c-bios-v4.41-318085-08.bin](https://www.zimmers.net/anonftp/pub/cbm-pc/firmware/pc10/cbm-pc10c-bios-v4.41-318085-08.bin) | `/pc10/bios.rom` | 32768 | `598a1adee2a9ddaa5b0d4b73190ff990` |
| [cbm-pc10c-char-318086-03-e53c.bin](https://www.zimmers.net/anonftp/pub/cbm-pc/firmware/pc10/cbm-pc10c-char-318086-03-e53c.bin) | `/pc10/char.rom` | 32768 | `3dff8618da06c084bb2302a338501f8c` |

For example, on Linux or macOS:

```sh
Z=https://www.zimmers.net/anonftp/pub/cbm-pc/firmware/pc10
curl -o bios.rom $Z/cbm-pc10c-bios-v4.41-318085-08.bin
curl -o char.rom $Z/cbm-pc10c-char-318086-03-e53c.bin
md5sum bios.rom char.rom          # macOS: md5 bios.rom char.rom
```

The character ROM holds two national character sets, USA/Europe and
Scandinavian (with æ, Æ, ø, Ø); the menu's
`Scandinavian charset` picks one, as switch 1 of the PC10-III's CONFIG DIP
switch does.

### MS-DOS

The core was tested with Commodore MS-DOS 3.21 (the Commodore Colt's, the
DOS of the PC10-III's time): two 360K disk images in
[Commodore_COLT_MS-DOS_v3.21.zip](https://www.zimmers.net/anonftp/pub/cbm-pc/software/Commodore_COLT_MS-DOS_v3.21.zip)
on zimmers.net. Unpack it and copy the two images to the SD card, e.g. as:

| File in the zip | Rename to (e.g.) | md5 |
|---|---|---|
| `Commodore COLT - MS-DOS v3.21 (Commodore Electronics, Ltd.)(1988).img` | `/pc10/dos321-1.img` | `84f150330ce70cbda19107409eb59c6b` |
| `Commodore - Microsoft MS-DOS v3.21 (Disk 2) (GW BASIC Interpreter) (Commodore Electronics, Ltd.; Microsoft Corporation) (1988).img` | `/pc10/dos321-2.img` | `baf1fdc71abe10d3dca0bd3bb4d9958f` |

Disk 1 boots and has FDISK, FORMAT, SYS, SETCLOCK, SPEED and the other
commands; disk 2 has GW-BASIC.

### The hard disk C:

C: needs an image of exactly 21,411,840 bytes (615 cylinders, 4 heads, 17
sectors: the PC20-III's drive); the core refuses any other size. An empty
image of zeros is a low-level formatted drive for the core, so DOS can
partition and format it right away:

1. Take `blank-hd20.img` from the release package, or make one with
   `python3 tools/mkblankhd.py hd20.img`, and copy it to the SD card, e.g. as
   `/pc10/hd20.img`.
2. In the menu (Help key), select ` C:` and choose the image. Mount disk 1 of
   MS-DOS in ` A:`. Then select `Reset the PC`: the BIOS looks for the hard
   disk when it starts.
3. At the `A>` prompt: `fdisk`, then Enter (create a DOS partition) and Enter
   (use the whole disk and make it active). FDISK restarts the PC.
4. `format c: /s` and `y`. This takes a few minutes.
5. `copy a:*.* c:` copies the DOS commands, and the AUTOEXEC.BAT that reads
   the clock (`setclock -r`) and sets 7.16 MHz (`speed -t`).
6. Eject A: (Space on the ` A:` line of the menu) and reset: DOS starts from
   C:.

The core remembers the image across power-off and mounts it again at the next
start. The image must not be stored in more than 511 pieces on the card; a
file copied to a FAT32 card in one go never is.

### Flashing the core

The package has the core as `PC10-III-0.1-R6.cor` and as a bitstream,
`PC10-III-0.1-R6.bit`. Flash the `.cor` file into a core slot with the
MEGA65's flash menu (hold NO SCROLL while switching on; the MEGA65 User's
Guide explains it), or, with a JTAG adapter, load the `.bit` file directly
with the [m65 tool](https://github.com/MEGA65/mega65-tools):
`m65 -q PC10-III-0.1-R6.bit`.

## First start

1. Start the core. Its welcome screen says "Press Space to continue".
2. The Commodore BIOS tests the memory (the count runs up to 640 KB) and looks
   for the disks.
3. Press **Help** to open the menu, select ` A:`, choose `dos321-1.img`, close
   the menu and press Ctrl-Alt-Del (or select `Reset the PC`): DOS asks for the
   date and the time (prefilled from the clock) and shows `A>`.

The menu's settings are saved in `/pc10/pc10cfg` when the menu closes.

## Using the core

### Keys

The MEGA65's keys are where a PC keyboard has them; the others:

| MEGA65 | PC |
|---|---|
| MEGA + 1 .. 0 | F1 .. F10 |
| F1 F3 F5 F7 F9 F11 F13, RUN/STOP | F1 .. F7, F8 |
| cursor keys | keypad 8 2 4 6 (the XT's cursor keys) |
| CLR/HOME | Home (keypad 7) |
| MEGA + CLR/HOME | End (keypad 1) |
| MEGA + cursor up / down | PgUp / PgDn (keypad 9 / 3) |
| INST/DEL | Backspace |
| MEGA + INST/DEL | Del (keypad .) |
| MEGA + pound | Ins (keypad 0) |
| MEGA + - | keypad - |
| + (right of 0) | keypad + |
| arrow up | keypad * / PrtSc |
| arrow left, pound | `` ` ``, `\` |
| @ * : ; | [ ] ; ' |
| RESTORE | Num Lock |
| NO SCROLL | Scroll Lock |
| HELP | opens the core's menu |

Ctrl, Alt, Shift, Caps Lock, Esc, Tab and Return are the PC's. Not mapped:
keypad 5. The help page (`Help` in the menu) has the same list.

The Commodore BIOS's keys: **Ctrl-Alt-S / T / D** set 4.77 / 7.16 / 9.54 MHz
(each with a beep of its own pitch), **Ctrl-Alt-Esc** starts its SETUP,
Ctrl-Alt-Del restarts the PC.

### The menu

Help opens it:

| Line | What |
|---|---|
| ` A:` ` B:` | the floppy images: choose one in the file browser; Space on a mounted line ejects it |
| ` C:` | the hard disk image (21,411,840 bytes); Space ejects it |
| `A: write protected`, `B: write protected` | the images' write protection |
| `Drive sound (int. drive)` | the MEGA65's internal drive plays the image drives' motor and steps (default on) |
| `Chipset` | `PC10-III (FE2010A)` (default) or `IBM XT (8255)`; a change restarts the PC |
| `Memory` | 640 / 512 / 256 / 128 KB |
| `HDMI` | 720p 60 Hz (default), 480p 59.94 Hz 4:3, 720p 50 Hz |
| `Display` | colour (default), or monochrome in green, amber or white; colour <-> monochrome restarts the PC |
| `Scandinavian charset` | the character ROM's national set (CONFIG switch 1), at once |
| `Analog: 15 kHz RGB`, `Analog: CSYNC` | the analog output: 15 kHz instead of VGA; composite sync |
| `Help` | the help page |
| `Reset the PC` | resets the PC (like the MEGA65's reset button) |

<!-- in-flight: intfd adds int. drive, ports the submenu (cut what misses 0.1) -->
With the features below: `int. drive` beside ` B:<No Disk>`
([B: as the internal drive](#b-as-the-internal-drive)) and the submenu
`Ports and mouse` ([Ports, mouse and Covox](#ports-mouse-and-covox)).

When a new version of the core changes the menu's lines, its settings return
to their defaults once (the hard disk C: stays remembered).

### Floppy disks A: and B:

Images of 160K, 180K, 320K and 360K are 5.25" disks in a 40-track drive;
720K images are 3.5" disks in an 80-track drive. Reads and writes go straight
to the image file on the SD card (a write is on the card when DOS reports it
done). The floppy images are not remembered across power-off: A: and B:
start empty.

<!-- in-flight: branch intfd. Cut this whole subsection if it misses 0.1. -->
#### B: as the internal drive

While B: holds no image its menu line reads ` B:<No Disk>         int. drive`:
`int. drive` (move there with the cursor right key, select it with Return or
Space) makes B: the MEGA65's internal 3.5" drive, reading and writing real
720K (DD) disks; selecting it again switches it off. A: stays an image. The
switch needs no reset: the drive steps its head to track 0 at once and follows
the PC's seeks from then on. `int. drive` is hidden while B: holds an image
(Space on ` B:` ejects it), and loading an image into B: switches it off. With
the real drive, the disk's own write protection tab counts. The drive sound is
off while B: is the drive.

- HD (1.44M) disks cannot be used: they need an AT's controller.
- The PC sees the disk through the same floppy controller model as an image:
  standard DOS disks work; copy-protected disks and odd formats do not.
<!-- intfd: FORMAT B: = 360K confirmed on hardware (pc10-intfd-c); the user's decision: no DRIVER.SYS route, this note -->
- `FORMAT B:` under MS-DOS 3.21 makes a 360K disk (40 tracks), and
  `FORMAT B: /T:80 /N:9` says "Parameters not supported": DOS 3.21 sets up
  the PC10-III's floppy drives as 360K drives, as on the real machine. Disks
  formatted as 720K elsewhere are read and written as 720K.

### The hard disk C:

Setting it up: [The hard disk C:](#the-hard-disk-c) under Installing. Mount or
eject the image, then reset the PC: the BIOS looks for the drive when it
starts. Without an image the PC is a PC10-III without a hard disk ("Hard disk
not found" at start-up is normal then). The image is remembered with its card
and path (in the settings file) and mounted again at the next power-on; if it
is missing then, the core says so for 5 seconds and starts without it.

<!-- in-flight: branch dfolder. Cut this whole subsection if it misses 0.1; check every detail against the branch's doc first. -->
#### A folder of the SD card as a hard disk

A folder of the SD card can be a second hard disk for DOS, read-only: choose
the folder in the menu, and at the next reset of the PC DOS sees its files as
drive D: (C: when no hard disk image is mounted).

- Read-only: DOS reports writes as write-protect errors.
- Long names appear as their 8.3 short names, the ones the card's own
  directory keeps for them (e.g. `VERYLO~1.FIL`), as a PC shows them.
- A snapshot at the PC's reset: changes on the card appear after the next
  reset. Up to the size of the PC20-III's drive (about 21 MB); files that do
  not fit are left out.
- Not remembered across power-off.

### Speed

In the PC10-III chipset mode the 8088 runs at 4.77, 7.16 or 9.54 MHz, with
the FE2010A's wait states: Ctrl-Alt-S / T / D, SPEED.EXE on the DOS disk
(its AUTOEXEC.BAT runs `speed -t`, 7.16 MHz), or SETUP's default speed. The
IBM XT (8255) chipset stays at 4.77 MHz.

### SETUP and the clock

The Commodore BIOS's SETUP (Ctrl-Alt-Esc) saves and exits with End
(MEGA + CLR/HOME).

The PC's clock chip starts with the time of the MEGA65's battery clock. As on
the real machine, DOS's `time` and `date` set only DOS's clock; `setclock -w`
(on DOS disk 1) and SETUP write the clock chip, and the core writes that time
back into the MEGA65's battery clock, so it persists. `setclock -r` reads it
at boot.

### Video

- **Colour:** the PVC4's CGA personality, 59.92 Hz: on HDMI 720p 60 Hz
  (default) or 480p 59.94 Hz 4:3.
- **Monochrome** (MDA, Hercules): 49.8 Hz; on HDMI, 720p 50 Hz is the mode for
  it. The analog output cannot show it.
- **Analog:** VGA (31 kHz, the picture line-doubled) next to HDMI, or with
  `Analog: 15 kHz RGB` the PC's own 15.7 kHz for an RGB monitor or a CRT, and
  `Analog: CSYNC` for composite sync.

### Sound

The PC speaker, on HDMI and the audio jack.

<!-- in-flight: branch ports. Cut this whole subsection (and the Features item) if it misses 0.1. -->
### Ports, mouse and Covox

The PC10-III's ports, as its Commodore BIOS finds them at start-up (COM at
3F8h, LPT at 3BCh, the mouse at 23Ch):

- **Serial port** (an 8250) and **printer port**: on the MEGA65's PMOD
  headers, when `Ports and mouse > PMOD: serial + printer` is on (off by
  default: then the headers are unpowered and every pin is high-Z). Serial
  on PMOD1 lo (/CTS, TXD, RXD, /RTS), the printer on PMOD1 hi (/STROBE,
  BUSY, /ACK, /INIT) and PMOD2 (D0-D7). The pins are 3.3 V and not 5 V
  tolerant: use a 3.3 V USB-UART module or an RS-232 level shifter (MAX3232)
  for the serial port, 5 V buffers for a printer, and never RS-232 levels on
  the header. The serial layout is Megamiga's, so its adapters fit.
  doc/ports.md section 6.1 has the wiring.
- **Mouse:** an Amiga mouse (the PC10-III came with Commodore's 1352, an Amiga
  mouse) in joystick port 1; `Ports and mouse > Mouse: Atari ST` for an
  Atari ST mouse. It needs Microsoft's bus mouse driver, MOUSE.COM, which is
  not on the DOS disks. The MEGA65 cannot read the right and middle buttons
  of a passive mouse; they work with an active adapter.
- **Covox Speech Thing:** what a program writes to the printer port also goes
  to the MEGA65's sound, as with a Covox in the port, with or without the
  PMOD headers.

### Two SD cards

The MEGA65 has two SD card slots, the bottom tray (SD0) and the back (SD1).
The core uses both: disk images can be on either card, and the file browser's
`<..>` at a card's top lists the cards. The settings file is looked for on
the back card first, then in the tray, and `/pc10/bios.rom`, `ucode.bin` and
`char.rom` are read from the same card. Keep the `/pc10` folder on one card.

## Known limitations

- MEGA65 R6 only ([Boards](#boards)).
- **8088 MPH** does not run through: it hangs in its sprite part. This is
  being investigated. The demo is written for IBM's CGA card, whose timing the
  PC10-III's onboard video does not have.
- No IBM CGA card in place of the onboard video, no composite colour, no sound
  card: they are on the list for later versions (doc/backlog.md).
- Floppy images are not remembered across power-off (C: is); a changed SD card
  is not noticed; no 1.2M or 1.44M disks (they need an AT's controller).
- C: takes only the PC20-III's 20 MB size. With slow SD cards, writing and
  formatting can be slower than on the real drive.
- HDMI: the 59.92 Hz colour picture on 60 Hz repeats a frame about every
  13 seconds.
- The analog output cannot show the monochrome display.
- The BIOS's SETUP needs more than 320 KB of memory: with 256 KB it crashes
  (its stack is at segment 5000h).
- Without `char.rom` only the first 128 characters exist.
- The `IBM XT (8255)` chipset is for IBM-compatible BIOSes such as the free
  [GLaBIOS](https://github.com/640-KB/GLaBIOS); it was tested in simulation
  only, and GLaBIOS has no hard disk BIOS (C: needs the Commodore BIOS).
- The turbo's speeds and wait states follow published research on the
  FE2010A; they were measured on the MEGA65, not yet compared with a real
  PC10-III (doc/turbo.md).

## Credits

- The core: Johan Smolinski, 2026.
- The 8088's execution unit: [z8086](https://github.com/nand2mario/z8086) by
  nand2mario (Apache 2.0; `rtl/cpu/z8086/NOTICE`).
- The 8088's microcode: Intel's; read off Ken Shirriff's die photos and
  published by Andrew Jenner
  ([8086 microcode disassembled](https://www.reenigne.org/blog/8086-microcode-disassembled/)),
  decoded as in his XTCE.
- The cycle reference: [MartyPC](https://github.com/dbalsom/martypc) by Daniel
  Balsom (MIT), and the [SingleStepTests 8088](https://github.com/SingleStepTests/8088)
  suite.
- The 8237, 8253, 8255 and 8259: kitune-san's KFPC-XT chips (MIT), in the
  versions of the [MiSTer PCXT core](https://github.com/MiSTer-devel/PCXT_MiSTer).
- The FE2010A: Sergey Kiselev's notes
  ([micro_8088](https://github.com/skiselev/micro_8088)).
- The framework: [MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) by
  sy2002 and MJoergen, with [QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA),
  in the [Megamiga](https://github.com/johansmolinski/Megamiga) fork, whose
  SD card engine, menu and drive sound the core uses.
  <!-- in-flight: branch intfd (cut the next sentence if it misses 0.1) -->
  The internal drive's read and write chains are sy2002's Hardware Floppy
  from [AExp](https://github.com/sy2002/AExp) (via Megamiga).
- The default font: VileR's ([int10h.org](https://int10h.org/oldschool-pc-fonts/),
  CC BY-SA 4.0), from [GLaBIOS](https://github.com/640-KB/GLaBIOS)
  (`CORE/font/README.md`).
- The Commodore firmware and DOS disks: Commodore's, archived by Bo Zimmerman
  at [zimmers.net](https://www.zimmers.net/). They are not part of the core.

## For developers

### The microcode in simulation

The testbenches read the bundle from `~/pcxt-work/ucode/8088.bin` (or
`$PC10_UCODE`, or `make Z86_UCODE=...`). `tools/mkucode.py --cpu 8086` builds
an 8086 bundle; the core then replaces the interrupt microcode that differs on
the 8088 with its own overlay (doc/z8086.md). `--jenner` takes the zip file or
its unpacked contents.

### Testing the CPU

Needs Verilator 5, Python 3, the microcode bundle and the test suite:

```sh
git clone https://github.com/SingleStepTests/8088 ~/pcxt-work/ext/sst8088
cd tb/sst
make convert          # JSON -> harness format, ~3.7 GB in ~/pcxt-work/sst-txt
make run              # all opcode files, one job per CPU core
./obj_z86/sst_run -f ~/pcxt-work/sst-txt/90.txt   # first failure in detail
```

Each line of `make run` gives, per opcode file:
- `state`: tests with the right registers and memory;
- `plain`: tests that start with an empty queue;
- `length` and `trace`: of those, the ones with the right cycle count and
  the right trace on every cycle.

### Building the core

The MEGA65 shell, its build (Vivado 2022.2, `CORE/build_all.sh`, the remote
build), the firmware and its tests: [doc/m2m-shell.md](doc/m2m-shell.md)
sections 10-11. The plan and its research: [doc/plan.md](doc/plan.md); the
engineering log: [doc/history.md](doc/history.md); what is asked for next:
[doc/backlog.md](doc/backlog.md).

### A release package

```sh
python3 tools/make_release.py --bit <build>/mega65_r6.bit --out <dir> \
    --jenner 8086_microcode_v2.zip --version 0.1
```

It checks `CORE_VERSION` in `CORE/vhdl/config.vhd` and the bitstream's board,
makes the `.cor` file with the MEGA65's `coretool` (or `bit2core`), builds
`pc10/ucode.bin` and checks it against the genuine 8088 bundle, and writes
`<dir>/PC10-III-<version>/` and `PC10-III-<version>-R6.zip`: the core, the
bitstream, `pc10/ucode.bin` with `pc10/UCODE-NOTICE.txt`
(from `tools/release/`), `blank-hd20.img`, this README, the licence, the
release notes (`doc/release-<version>.md`) and the two tools. It refuses any
other file: no Commodore ROM or DOS goes into a package.

### Repository

- `rtl/cpu/`: the 8088: z8086's execution unit with Intel's microcode loaded
  at start-up, and `biu88`, our cycle-stepped bus interface unit
  ([doc/z8086.md](doc/z8086.md)). No microcode in the repository or the
  bitstream (AGENTS.md rule 4).
- `rtl/system/`: the board (`xt_board.sv`: FE2010A or 8255, the KF chips),
  clocks and turbo, the 230h register, the clock chip.
- `rtl/video/`: the PVC4 ([doc/pvc4.md](doc/pvc4.md)); the IBM CGA and MDA
  cards ([doc/cga.md](doc/cga.md), [doc/mda.md](doc/mda.md)), not in the
  MEGA65 build.
- `rtl/fdc/`, `rtl/hdc/`: the floppy controller ([doc/fdc.md](doc/fdc.md)),
  the PC20-III's hard disk ([doc/xta.md](doc/xta.md)) and an XTIDE card
  ([doc/hdc.md](doc/hdc.md), not in the MEGA65 build).
- `CORE/`: the MEGA65 shell (M2M, [doc/m2m-shell.md](doc/m2m-shell.md)).
- `tb/`: the testbenches (`sst`: the CPU; `sys`: the whole PC; one per part).
- `tools/`: `mkucode.py` (the microcode bundle), `mkblankhd.py` (an empty
  C:), `make_release.py` (a release package), `ctrace_diff.py` (the cycle
  trace comparison with MartyPC), `gen_xpr.py` (the Vivado project).

## Licence

GPL-3.0 (see `LICENSE`), like the MiSTer2MEGA65 framework. z8086 is Apache
2.0 (`rtl/cpu/z8086/LICENSE`, `NOTICE`), the KF chips MIT
(`rtl/system/kf/`), the default font CC BY-SA 4.0 (`CORE/font/README.md`).
Intel's microcode (`ucode.bin`) is none of these: it is Intel's
(`tools/release/UCODE-NOTICE.txt`).
