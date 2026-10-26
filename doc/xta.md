# The PC20-III hard disk (XTA)

Status: 2026-10-26, branch `xta-shell`. The interface, the commands and the
timing come from the Commodore BIOS 4.41 (318085-08), the PC10-III
schematics, Western Digital's drive manual and three emulators (sections
1-8). The card is built (`rtl/hdc/xta_card.sv`, section 9) and tested
(section 10); the MEGA65 shell serves it from an image on the SD card
(section 11).

The BIOS ROM is Commodore's copyrighted code. Its disassembly stays outside
the repository (`~/pcxt-work/xta/`: `rom.dis`, `disk.lst`, `fmt.lst`,
`main.lst`, made with `objdump -D -b binary -m i8086 --adjust-vma=0x8000`).
This document describes what the code does, in our own words. Addresses are
`F000:xxxx` (the ROM maps F8000-FFFFF).

## 1. Sources

| Source | What it gives | Licence / where |
|---|---|---|
| Commodore PC BIOS 4.41, 318085-08 | the disk BIOS that has to run (WD "IDE SuperBIOS Rev. 1.0", 8 KB at F8000-F9FFF) and its formatter | the user's ROM, `~/pcxt-work/roms/` |
| PC10/20-III technical manual (German/English): chapter 7 (p44-45), schematic 312626 sheet 2 "FDD_HDD_BIOS" (p80), CPU base assembly 312677 (p77) | CN202, JMP206-208, the host-side logic, the drive's part number | `~/pcxt-work/manual/` |
| Western Digital, *WD93024/93034/93044-X Technical Reference Manual* 0098S, 10/89, as transcribed by the PC-DISK database (DCI AG) | the drive: geometry, translation, rotation, seek times, the J8 jumpers, the configuration register | http://computermuseum.informatik.uni-stuttgart.de/pcdisk/h/ASCII/4809.TXT (copy in `~/pcxt-work/xta/ref/wd4809.txt`) |
| kobolt, *pc20iii* (a Commodore PC 20-III emulator, MIT), `xthdc.c` | a working model of the PC20-III's WD93024-X with Commodore BIOS 4.38: 615/4/17, configuration register FFh | https://codeberg.org/kobolt/pc20iii (`~/pcxt-work/xta/ref/pc20iii/`) |
| 86Box `hdc_xta.c` (WDXT-140/150 XTA, BSD-3) and `hdc_st506_xt.c` (GPL, read only) | the XTA register set, the CCB, status bits, sense codes, the WDXT-150 switch tables | `~/pcxt-work/xta/ref/` |
| MartyPC `devices/hdc/xebec.rs` (MIT) | the IBM/Xebec bus phases, the completion byte, when the interrupt clears | `~/pcxt-work/xta/ref/xebec.rs` |

The emulators model the interface only. None of them models the drive's
timing, so the timing comes from WD's figures (section 8).

## 2. The machine side: CN202 and the jumpers

From the schematic sheet "FDD_HDD_BIOS" (312626, sheet 2):

- **CN202**, 40 pins (odd pins carry signals, even pins are ground), is a
  buffered piece of the I/O channel and nothing more:
  - a 74LS244 (U202), always enabled, drives SA0, SA1, -IOW, -IOR, -DACK3,
    -HDCS and RESET to the drive;
  - a 74LS245 (U204) passes the data bus. Its direction comes from -IOR
    (with IOR-DLY). It is enabled by -DACK3 AND -HDCS **through JMP208**: one
    74LS08 gate acts as a negative OR, so the buffer is on while either
    signal is low. In JMP208's other position the enable is pulled high
    (4.7 kOhm), which cuts the drive off the data bus;
  - the drive's IRQ (pin 31) reaches IRQ5 through JMP206, and its DRQ
    reaches DRQ3 through JMP207;
  - CN203 and 470 Ohm to +5 V go to one more pin. That pin is not
    identified; it is probably the LED or a pull-up.
  - CN202 carries no AEN, no TC and no clock. -HDCS comes from the
    Commodore I/O chip (the "5720", U602 on the video sheet, which also
    makes the FDC, COM, LPT and RTC selects; it qualifies them with AEN).
    During DMA cycles the drive sees DACK3 without -HDCS.
- **JMP208 position B** = the Commodore hard disk (the buffer follows the
  decode); **position A** = none (buffer off). In position A the ports
  320h-323h read FFh, which is what the BIOS sees today: `Hard disk not
  found` (section 6). JMP206 and JMP207 connect IRQ5 and DRQ3; without them
  a controller card in a slot could use those lines.
- The decoded range of -HDCS is not legible. The BIOS uses only 320h-323h
  (324h-327h belong to a second controller, which the PC10-III cannot have).
- The drive is Commodore part **312711-01** ("HARD DISK DRIVE", fitted in
  the PC20-III variants of assembly 312677, mounted with 6-32 screws).
  kobolt identifies it as a **Western Digital WD93024-X** (he took it from
  his own PC 20-III). The manual ("20 MB 3.5 inch drive", "special
  Commodore drive" on CN202) and the ROM's WD SuperBIOS agree.

## 3. The drive: WD93024-X

A 3.5" drive with the XT controller on board (WD calls it an "intelligent
storage peripheral"; other sources say "XTA" or "XT-IDE"). The drive itself
answers the four ports of the IBM PC/XT fixed disk adapter.

| | |
|---|---|
| Physical geometry | 782 cylinders, 2 heads, 27 sectors/track (RLL 2,7), 512 bytes |
| Translate mode (J8 1-2 open) | **615 cylinders, 4 heads, 17 sectors** = 41,820 sectors = 21,411,840 bytes |
| Rotation | **3329 rpm** (18.02 ms per revolution) |
| Average latency | 9 ms |
| Seek | track-to-track 5 ms, average 39 ms typ., 63 ms max. |
| Data rate | 0.938 MB/s (internal and external) |
| Landing zone | physical cylinder 862 (park with WD's PARKIDE) |
| Precompensation | cylinder 784 |
| Interleave | 3:1 standard (preformatted at the factory); 2:1 with DMA demand mode |

The J8 jumpers (WD manual):
- pins 1-2: physical mode (jumper fitted) or translate mode (open);
- pins 3-4: DMA demand mode. It needs SuperBIOS 2.1 or later; ours is 1.0
  and always programs single transfers;
- pins 5-6: IRQ2 instead of IRQ5.

WD's manual says: "The control processor firmware sets the configuration
register (host port 322) according to the interrupt selection". So **port
322h is the drive's configuration register**: the drive's firmware sets it
from J8. It is not a switch on the host side.

The PC20-III's drive runs in **translate mode**:
- the BIOS tables (section 4) give 615/4/17 for it;
- kobolt's emulator uses 615/4/17 with the configuration register at FFh;
- the WD manual gives 615/4/17 as the WD93024-X's translated geometry.

In physical mode the same BIOS would take 782/2/27 from its second table
(section 4).

The drive's translation is not documented. The plan uses the obvious one:
logical sector number L = (C x 4 + H) x 17 + S (S 0-based) is physical
sector L, which is physical cylinder L / 54, head (L / 27) mod 2, sector
L mod 27. The 41,820 logical sectors then use physical cylinders 0-774.

## 4. Registers (I/O 320h-323h)

| Port | Read | Write |
|---|---|---|
| 320h | data: completion byte, sense bytes, sector data (PIO) | data: command block (CCB), drive parameters, sector data (PIO) |
| 321h | status | controller reset (any value) |
| 322h | configuration register | select (any value): starts a command |
| 323h | - | mask: bit 0 enables DMA, bit 1 enables the interrupt |

**Status (321h)**:

| Bit | Name | Meaning |
|---|---|---|
| 0 | REQ | a byte may move |
| 1 | I/O | 1 = drive to host |
| 2 | C/D | 1 = command/status, 0 = data |
| 3 | BSY | busy |
| 4 | DRQ | DMA requested |
| 5 | IRQ | interrupt pending |
| 7-6 | | 0 |

The phases, as the BIOS checks them:

| Phase | Status (bits 3-0) |
|---|---|
| idle (bus free), during a reset | 0000 |
| selected, waiting for a CCB byte | BSY C/D REQ = 1101 (0Dh) |
| command executing | BSY C/D = 1100 |
| data out (host to drive): drive parameters, sector data | BSY REQ = 1001 |
| data in (drive to host) | BSY I/O REQ = 1011 |
| status: the completion byte is ready | BSY C/D I/O REQ = 1111 (0Fh), plus bit 5 when interrupts are enabled |

**Configuration (322h)**, as BIOS 4.41 decodes it:

| Bits | Meaning |
|---|---|
| 1-0 | drive 0's type: the index into the drive table (0-3) |
| 3-2 | drive 1's type |
| 5-4 | 11: 17 sectors, table 1 (MFM-style drives, translate mode); 01: 27 sectors, table 2 (RLL, physical mode); 10: "dynamic configuration" (the geometry is read from the disk's sector 0, section 5.4); 00: table 2 with the cylinders scaled by 1.529 (26/17) |
| 6 | 1 = IRQ5 (INT 0Dh), 0 = IRQ2 (INT 0Ah) |
| 7 | 1 = PC/XT. 0 = AT: the BIOS then also programs the AT's second 8237 (port D6h = C0h, port D4h = 00h: cascade mode for channel 4). This is the D4h/D6h access seen in the ROM |

The drive tables have 16 bytes per type: cylinders, heads, reduced write
current cylinder, precompensation cylinder, ECC burst length (11), control
byte, landing zone. Their geometries:

| Type | Table 1 (bits 5-4 = 11), control byte 05 | Table 2 (otherwise), control byte 07 |
|---|---|---|
| 0 | 612 / 4 | 820 / 4 |
| 1 | 306 / 4 | 615 / 4 |
| 2 | 977 / 5 (WD93044-X translated) | 782 / 4 (WD93044-X physical) |
| 3 | **615 / 4 (WD93024-X translated)** | 782 / 2 (WD93024-X physical) |

**The PC20-III's drive: 322h = FFh** (translate mode, type 3, IRQ5, XT;
bits 3-2 unused). kobolt found the same value necessary with BIOS 4.38. An
empty CN202, or JMP208 in position A, also reads FFh. What tells the BIOS
that nothing is there is the status register: FFh has DRQ and IRQ set
(section 6).

**Mask (323h)**: bit 0 lets the drive request DMA (DRQ3), bit 1 lets it
interrupt (IRQ5 and status bit 5). The BIOS writes:
- 02h for commands without data;
- 03h for DMA commands;
- FCh (both off) for PIO commands, and before it reads the completion byte.

## 5. Commands

### 5.1 The handshake

1. (Optional) the mask to 323h. Then a write to 322h selects the drive. The
   BIOS repeats the select until the status shows BSY C/D REQ (up to
   10 x 65536 tries).
2. Six CCB bytes to 320h, each sent after REQ, with BSY and C/D set and I/O
   clear.
3. Then, depending on the command: the drive parameters (8 bytes out, PIO),
   sector data (DMA when the mask's bit 0 is set, or PIO byte by byte after
   REQ), or nothing.
4. Completion is the status phase (0Fh). The BIOS waits for it in one of
   two ways:
   - PIO commands: it polls REQ and the phase;
   - with the interrupt enabled: it polls status bit 5 (IRQ). It also
     unmasks IRQ5 in the PIC. Its INT 0Dh handler only sends EOI, masks DMA
     channel 3 and masks IRQ5 again.
5. The BIOS writes FCh to 323h, reads the completion byte from 320h, and
   expects BSY to drop within 100 polls of 321h. That is about 0.7 ms on a
   4.77 MHz 8088, so the drive must free the bus quickly after the
   completion byte.

A write to 321h resets the controller at any time. A write to 322h restarts
the command phase.

### 5.2 Command control block (6 bytes)

| Byte | Bits |
|---|---|
| 0 | opcode |
| 1 | bit 5 drive (0/1), bits 4-0 head |
| 2 | bits 7-6 = cylinder bits 9-8; bits 5-0 = sector, **0-based** (the BIOS subtracts 1 from INT 13h's CL) |
| 3 | cylinder bits 7-0 |
| 4 | block count (sectors), or the interleave for the format commands |
| 5 | control: bits 2-0 step option (the BIOS sends 5 from table 1, 7 from table 2), bit 7 no retries, bit 6 no ECC retries (the BIOS uses neither) |

### 5.3 Opcodes and what BIOS 4.41 does with them

INT 13h AH=01 (status) runs request sense. AH=08, 15h and 16h answer from
the tables and send no command.

| Op | Command | INT 13h AH (BIOS) | Data | Mask |
|---|---|---|---|---|
| 00 | test drive ready | 10h | - | 02 |
| 01 | recalibrate | 11h; also inside the reset sequence | - | 02 (none at detection) |
| 03 | request sense | 01; after every error | 4 bytes in, PIO | FC |
| 04 | format drive (CCB byte 4 = interleave) | 07 | the sector buffer's data is written to every sector | 02; the BIOS waits forever |
| 05 | verify | 04 | - | 02 |
| 06 | format track | 05 | as 04 | 02 |
| 07 | format bad track | 06 | as 04 | 02 |
| 08 | read | 02; PIO for sector 0 (section 5.4) | n x 512 bytes in | 03 (DMA), FC (PIO) |
| 0A | write | 03 | n x 512 bytes out | 03 |
| 0B | seek | 0Ch | - | 02 |
| 0C | initialize drive characteristics | 00, 09, 0Dh (resets) | 8 bytes out, PIO | FC |
| 0D | read ECC burst length | after sense 98h | 1 byte in, PIO | FC |
| 0E | read sector buffer | 0Eh | 512 bytes in, DMA | 03 |
| 0F | write sector buffer | 0Fh (the formatter, before 04) | 512 bytes out, DMA | 03 |
| E0 | RAM diagnostic | 12h | - | 02 |
| E3 | drive diagnostic | 13h | - | 02 |
| E4 | controller diagnostic | 14h (detection) | - | 02 |
| E5 | read long (512 + 4 ECC bytes) | 0Ah | 516 bytes in, DMA | 03 |
| E6 | write long | 0Bh | 516 bytes out, DMA | 03 |

**Initialize drive characteristics (0C)**: after the CCB come, in data-out
phase, the cylinders (high, low), the heads, the reduced write current
cylinder (high, low), the precompensation cylinder (high, low) and the ECC
burst length. For the PC20-III that is 02 67 04 02 68 02 68 0B. (The BIOS
sends the landing zone as the cylinder count; the table has 615 there.)
- The BIOS sends 0C for drive 0 **and for drive 1** in every reset (INT 13h
  AH=00, 09, 0Dh) and returns drive 1's result. So **0C must succeed for
  drive 1 too**; otherwise the reset fails and the disk is "not found".
- A translate-mode drive ignores the values, because its geometry is fixed.
  kobolt's and 86Box's models accept them without checking.

**DMA** (as the BIOS programs it):
- channel 3, mode 47h for reads (single transfer, increment, write to
  memory) or 4Bh for writes;
- address through port 06h, page through 82h, count through 07h =
  n x 512 - 1 (516 per sector for the long commands);
- a transfer that would cross 64 KB returns AH=09 without touching the
  drive;
- the channel is unmasked (0Ah = 03h) only after the CCB has been sent.

The drive gets no TC: it ends the data phase after its own byte count.

### 5.4 Completion byte, sense bytes, errors

The completion byte has bit 1 = error and bit 5 = drive. Reading it clears
the interrupt (MartyPC, 86Box). After an error the BIOS sends request sense
and reads four bytes:

| Byte | |
|---|---|
| 0 | bit 7 address valid, bits 5-0 error code |
| 1 | bit 5 drive, bits 4-0 head |
| 2 | cylinder bits 9-8 in bits 7-6, sector in bits 5-0 |
| 3 | cylinder bits 7-0 |

How BIOS 4.41 turns the error code into the INT 13h status (AH):

| Sense | Meaning (Xebec / IBM) | AH |
|---|---|---|
| 00 | no error | 00 |
| 01 | no index | 20h (controller failure) |
| 02 | no seek complete | 40h (seek failed) |
| 03 | write fault | 20h |
| 04 | drive not ready | 80h (timeout) |
| 06 | no track 0 | 20h |
| 08 | seek in progress | 40h |
| 10h | ID field ECC error | 10h |
| 11h | uncorrectable data error | 10h |
| 12h | address mark not found | 02 |
| 14h | sector not found | 04 |
| 15h | seek error | 40h |
| 18h (98h) | corrected ECC error: the BIOS then reads the burst length (0D) and returns AH=11h, AL = burst | 11h |
| 19h | bad track | 0Bh |
| 20h | invalid command | 01 |
| 21h | illegal disk address | 02 |
| 30h-32h | RAM / ROM / ECC generator diagnostics | 20h, 20h, 10h |
| others | | BBh |
| (no answer) | a timeout in the handshake | 80h; a failed sense gives FFh |

**Sector 0 is special** in this BIOS. Before every INT 13h write of one
sector to C0/H0/S1 (an MBR), the BIOS reads the disk's sector 0 by PIO
(read command, mask FC, the sector byte by byte after REQ). If that sector
ends with 55AA or AABB, the BIOS copies its bytes 1ADh-1B7h into the new
MBR, unless the new MBR already carries AABB. (Those bytes are WD's
"dynamic configuration" parameters: cylinders, heads, RWC, WPC, ECC/control,
landing zone.) So PIO reads must work even on a DMA machine.

## 6. Detection: how "Hard disk not found" is decided

The main BIOS scans C8000-C9FFF for option ROMs. Only if it found none
there does it scan F8000-F9FFF, the WD code (55 AA, 8 KB, entry at +3, the
formatter at +5); a controller card with its own BIOS at C800 therefore
replaces the built-in disk BIOS. On a cold boot it first waits until
6 s after the timer started ("Waiting for hard disk spin up..."). The WD
code then does this:

1. It installs INT 0Dh (as 322h bit 6 says), moves the old INT 13h to INT
   40h, installs its own INT 13h, INT 19h (boot) and INT 41h (the table that
   322h bits 5-4 select), presets the BIOS tick counter (0 on a cold boot,
   178 ticks on a warm one) and unmasks the timer.
2. It writes 321h (reset), waits about 5 ms and reads 321h. **Bit 4 or 5 set
   means no drive** (an empty bus reads FFh).
3. It selects the drive and sends a recalibrate (opcode 01; the mask is not
   written, so no interrupt), polls for the status phase (up to ~30 s) and
   reads the completion byte without checking it.
4. It selects again until the drive answers with BSY C/D REQ. Then INT 13h
   AH=14h (controller diagnostic, E4): a failure means no drive.
5. For DL = 80h:
   - INT 13h AH=10h (test ready, opcode 00), repeated until it succeeds or
     the tick counter reaches 446. That is 24.5 s after step 1 on a cold
     boot and 14.7 s on a warm one: the **spin-up wait**.
   - Then AH=00 (reset: controller reset, recalibrate drives 0 and 1,
     initialize drives 0 and 1). A failure means no drive.
   - Then AH=11h (recalibrate). Success counts one more drive.
6. The same for DL = 81h, with the tick counter set to 357 on a cold boot.
   If test ready fails for drive 1, the absent second drive costs the rest
   of the wait: **4.9 s cold, up to ~14 s warm**.
7. With a drive count of 0 it prints "Hard disk not found".

So the drive must:
- show 00h in 321h shortly after a reset (no DRQ, no IRQ);
- accept a select;
- finish recalibrate, E4, test ready and initialize (for both drives);
- recalibrate drive 0 without an error;
- fail either test ready or recalibrate on drive 1.

INT 13h AH=08 then reports 613 as the last cylinder (the BIOS keeps the
last cylinder, 614, for diagnostics), 4 heads, 17 sectors and 1 drive. DOS
sees 614 x 4 x 17 = 41,752 sectors (21.4 MB).

## 7. The formatter (IDE SuperBIOS)

In BIOS 4.41 the formatter is started with **`G=F800:5`** in DEBUG. It needs
DOS, because it prints through INT 21h. The manual's `G=FA00:5` and its
banner "WX2 Format Revision 1.08 (C) 1986" belong to an older ROM; in 4.41,
FA00:5 points into the middle of other code. The banner here is "IDE
Superbios Rev. 1.0 (C) Copyright Western Digital Corp. 1988".

The dialogue:
- current drive C: (RETURN keeps it);
- current interleave: **default 4** in translate mode, 5 otherwise
  (1-16 or 1-25 allowed);
- "Are you dynamically configuring the drive": N for the Commodore drive,
  as the manual says;
- "Are you virtually configuring the drive" (a split into C: and D:): N;
- "Do you want to format bad tracks": a list of cylinder/head pairs, each
  formatted with INT 13h AH=06;
- "Press "y" to begin formatting drive C with interleave 04".

Then it:
- fills the controller's buffer (AH=0Fh, write sector buffer);
- formats the whole drive (AH=07, opcode 04, CCB byte 4 = interleave) and
  waits without a timeout;
- writes an MBR with AABB, but only for dynamic or virtual configurations;
- prints "Format Successful" and "System will now restart", waits for a
  key and jumps to FFFF:0000.

## 8. Timing (what the real drive does)

| Item | Value | Source |
|---|---|---|
| Revolution | 60 / 3329 s = 18.023 ms (516,124 clk at 28.63636 MHz) | WD |
| Sector slot | 1/27 revolution = 667.5 us (512 data bytes take 546 us at 0.938 MB/s; the rest is ID, ECC and gaps) | WD (data rate, 27 sectors) |
| Track-to-track seek | 5 ms | WD |
| Seek over d cylinders | 5 + 2.24 x (sqrt(d) - 1) ms: 5 ms (d = 1), 39 ms (d = 261 = 1/3 stroke), 65 ms (d = 781) | a fit to WD's 5/39/63 ms |
| Head switch | within the track's gap (no extra time) | assumption |
| Command overhead | a few hundred us per command (CAL: not published) | assumption |
| Buffer | one sector: a sector that was read goes to the host before the next one is read; a sector to write is taken from the host before its slot comes | WD's interleave statement (3:1 with single-transfer DMA, 2:1 in demand mode) |
| Interleave | the physical order of the 27 sectors on a track, from the last format (factory: 3) | WD |
| Spin-up | unknown (the BIOS allows 24.5 s) | |

Checking the interleave: a single-transfer DMA of 512 bytes on a 4.77 MHz
XT takes about 1 ms (one byte per DMA cycle, plus the CPU's cycle between
them). So after a sector has been read (one slot), the next one can come at
the earliest about 2.5 slots later, which means interleave 3. With demand
mode (~0.5 ms), 2 is enough. That is what WD states, so the model uses a
one-sector buffer. Sequential reads at 3:1 give 9 sectors per revolution =
256 KB/s at most; at the formatter's default of 4, 192 KB/s.

## 9. The model (`rtl/hdc/xta_card.sv`)

One card on the card bus: the CN202 host side and the drive's controller.
Steps 2 and 3 are done (2026-10-25); section 10 has the tests.

### 9.1 Host side

- Ports 320h-323h: `!AEN` and `isa_addr[9:2]` = 320h >> 2, as the 5720's
  -HDCS (the decoded range is not legible, section 2). A DMA cycle is DACK3
  with AEN, whatever the address: the board's DACK3 can outlast AEN into the
  CPU's next I/O cycle (a first version took the BIOS's status poll after a
  DMA byte for a DMA read and hung the boot sector read).
- One data byte per CPU bus cycle: the board model resumes a CPU command
  that AEN cut (a DMA transfer in the cycle's last wait state, below) with
  a second strobe; the card counts a cycle from ALE's rising edge, repeats
  the first strobe's byte on a resumed read and ignores a resumed write.
  Only the CPU's strobes (AEN low) count; a refresh cycle's IOW does not.
- `enable` = JMP208 in position B. Off, the card does nothing: the ports
  float (FFh), no IRQ, no DRQ. This is also an empty CN202.
- IRQ5 (parameter `IRQ`, JMP206) and DRQ3 (`DMA`, JMP207) are fixed wires.
- `present`: a medium. Without one the drive answers but is never ready
  (sense 04h). [A] (the real drive always has its disk; this is the
  shell's "no image").
- `active`: the LED. On while BSY is set or a write is still going to the
  image. [A] (the drive's J6 LED is not documented).

### 9.2 Bus phases and registers

As in sections 4 and 5. Details the sources leave open:

- A select (322h) starts the command phase from any phase except the
  reset: BSY C/D REQ at once (the BIOS re-selects in a tight loop, so the
  answer must come within a few us). It aborts a running command; data
  already written to the "platter" still go to the image. [A]
- REQ drops at the start of each CCB byte's strobe and comes back after
  `CCB_US` (12 us). [A]
- After the sixth byte: BSY C/D for `CMD_US` (300 us), then the command.
  [A]
- Data phases: BSY I/O REQ (in) or BSY REQ (out); between sectors the
  phase stays, with REQ low. [A] A byte may move by PIO (320h) or by DMA
  (DACK3) whenever REQ is set; DRQ3 = REQ and mask bit 0, only for sector
  data (08, 0A, 0E, 0F, E5, E6). REQ/DRQ drop at the strobe's start and come
  back `BYTE_CLK` (31 clk, 1.08 us = WD's 0.938 MB/s) after it, but not
  before 2 clk after the strobe's end. The PC10-III's 8237 needs ~2.1-2.5 us
  per byte while the CPU polls the status (1.1-1.3 ms per sector), so the
  DMA, not the drive, sets the host rate.
- Status phase: BSY C/D I/O REQ, the interrupt latch set. Status bit 5 and
  IRQ5 = the latch AND mask bit 1; status bit 4 = DRQ3. Reading the
  completion byte clears the latch; BSY drops `FREE_US` (2 us) later.
- 321h write: controller reset, `RESET_US` (1 ms) with status 00h; it
  clears the mask, the sense and the interrupt. RESET DRV does the same.
  [A]
- 322h read: `CONFIG` = FFh. 323h is not readable (FFh).
- Sense: cleared at the start of every command but request sense, and by
  request sense itself (all four bytes 00h). [A]

### 9.3 Commands

| Op | As modelled |
|---|---|
| 00 | OK when ready. Drive 1: OK (`DRV1_READY` = 1, kobolt's model; 0 = not ready, a 4.9 s / ~14 s boot wait) [A] |
| 01 | seek to physical cylinder 0 |
| 03 | 4 sense bytes (PIO) |
| 04 | formats all 1,564 physical tracks (index to index, one revolution each); the sector buffer goes to all 41,820 sectors; CCB byte 4 becomes the interleave |
| 05 | like 08 without data and without the image |
| 06, 07 | format the 1 or 2 physical tracks that hold logical track (C, H); its 17 sectors get the buffer. 07 does not mark the track bad [A] |
| 08, E5 | read; E5 adds 4 ECC bytes of 00h [A] |
| 0A, E6 | write; E6 drops the 4 ECC bytes [A] |
| 0B | seek to the cylinder of (C, H, 0) |
| 0C | takes 8 bytes and ignores them (translate mode: fixed geometry); works for drive 1 |
| 0D | 1 byte, 00h (the drive never corrects) |
| 0E, 0F | the sector buffer: the slot used last |
| E0, E3, E4 | `DIAG_US` (2.5 ms), OK [A] |
| other | error 20h |

Errors (sense code, address valid bit 7):
- 04h (not ready, no address): no medium, spinning up, or drive 1 for a
  command that needs the drive (all but 03, 0C, 0D, 0E, 0F, E0, E4);
- 21h with the address: C >= 615, H >= 4, S >= 17 in the CCB; a multi-sector
  command that runs past LBA 41,819 (the sectors before it move, then the
  error with the first missing sector's address); 21h without address for
  a format interleave of 0 or > 26 [A];
- 11h with the address: the backend failed a read (the sectors before it
  were delivered);
- 03h (write fault) with the address of the first sector the backend failed
  to write (reported after the whole command). [A]
The block count 0 means 256 sectors. [A]

### 9.4 The drive's timing

| Item | Model | Parameter |
|---|---|---|
| Rotation | 27 slots per revolution, exactly 516,124 clk (3329 rpm); the spindle starts with RESET DRV [A] (its phase is arbitrary anyway) | `REV_CLK` |
| Translation | logical sector L = physical sector L: track L / 27, cylinder L / 54, index k = L mod 27 on the track [A] | |
| Interleave | sector k of a track sits in slot ((k mod 27/g) x i + k div (27/g)) mod 27, g = gcd(i, 27): the usual layout (place, step i, one slot on when occupied). One value for the whole drive, set by every format (04, 06, 07) [A]; 3 at power-on (WD's factory format) | `ILV_INIT` |
| Seek | SEEK_A_US + SEEK_B_US x isqrt(256 d) us = 2760 + 140 x isqrt(256 d): 5.0 / 38.9 / 65.3 ms for d = 1 / 261 / 781 | `SEEK_A_US`, `SEEK_B_US` |
| Head switch | free [A] | |
| One-sector buffer | a read waits for its slot's start only once the host has taken the previous sector; the data come at the slot's end. A write waits until the host has sent the sector; the host may send the next one at the end of its slot. The seek to the next sector's cylinder starts at the end of the previous slot (during the host transfer) | |
| Format | one revolution per track from the index; the next track (head switch) misses the index and waits one more [A]: 72 ms per cylinder, 56.4 s for the drive at any interleave | |
| Overheads | `CMD_US` 300, `CCB_US` 12, `FREE_US` 2, `RESET_US` 1000, `DIAG_US` 2500 us [A] | |
| Spin-up | 5 s after the first RESET DRV and after a new medium; later resets do not stop the drive [A] | `SPINUP_MS` |

With single-transfer DMA on the 4.77 MHz PC (1.1-1.3 ms per sector in
tb/sys, less than the two slots of 1.33 ms) the drive reaches interleave 3: a sequential read takes 3 slots per sector,
9 sectors per revolution, 256 KB/s; interleave 4 (the formatter's default)
192 KB/s, interleave 1 one revolution per sector (28 KB/s).

### 9.5 Sector buffer and backend

`hdc_secbuf` with four slots (2 KB, one block RAM) and the XTIDE card's
sector port (doc/hdc.md section 5; `sp_lba` < 41,820, no drive bit). For
reads the backend runs up to four sectors ahead of the host, for writes and
formats up to four behind the platter. The drive's timing above stays the
same as long as the backend needs less than about one slot (667 us) per
sector; a slower backend delays the data (the TB checks a 3 ms backend for
data, not timing). A write or format command ends only once the image holds
every sector (write-through, as the floppy's). A new command waits until
the previous command's writes are done.

### 9.6 `pc_system`

Parameter `XTA_FIT` (default 0: not built; every existing build and gate is
unchanged). Ports (doc/architecture.md section 4):
`xta_enable` (JMP208), `xta_present`, `xta_active`, `xta_sp_req`,
`xta_sp_write`, `xta_sp_lba[27:0]`, `xta_sp_rd_valid`, `xta_sp_rd_data`,
`xta_sp_wr_valid`, `xta_sp_wr_data`, `xta_sp_wr_ready`, `xta_sp_done`,
`xta_sp_err`. The card's IRQ and DRQ are ORed with the FDC's and the
XTIDE card's. The stand-in, `pc_system_flat.sv` and the OOC top tie the
ports off (card not fitted).

### 9.7 A board finding: DMA in a CPU read's last wait state

The BIOS polls 321h while its DMA transfers run. The board model fixes a
cycle's wait states one state ahead (biu88, as MartyPC) and its DMA wait
reaches READY together with AEN, so the 8237 can take the bus (AEN) in the
last Tw of the CPU's IN. AEN cuts the IOR, the card stops driving, and the
CPU took the open bus at the step that starts T4: FFh, which has the
interrupt bit set, so the BIOS read garbage as the completion byte. On the
5160 the DMA wait goes to the 8284 with HOLDA, one clock before AEN, and the
CPU waits. `xt_board.sv` now keeps the data the command had when AEN cut it
and gives them to the CPU at that step; the timing is unchanged (the
MartyPC trace gates stay identical, section 10.3). [Q] The 5160's own
behaviour (a wait instead) would change the refresh timing against
MartyPC; it affects every card's I/O read data during DMA, the FDC's too.

## 10. Verification

### 10.1 tb/xta (unit bench)

`make run` (Verilator; `make run ARGS=-f` also formats the whole drive): the
card with the PC10-III's I/O cycles (ALE, IOR from T1, IOW from T2, the
board's wait state; some cycles resumed after a refresh cycle, as the board
does), channel 3 of the 8237 in single-transfer mode (DACK3 outlasting AEN;
a normal and a fast mode), a backend with random latency (20-300 us per
sector, a write takes its bytes after the latency) and injectable read and
write errors, and two models:
- `Ref`, the command level: completion byte, sense bytes, data in, the
  image and the sector buffer after each command;
- the timing: the spindle (REV_CLK, 27 slots), the interleave's layout
  (the classic placement algorithm, not the card's closed form), the seek
  formula and the one-sector buffer predict when each sector's first byte
  appears on DRQ3 (reads) or when the next sector's does (writes), within
  3 us; verify and format by their completion time; the drive's byte rate
  with a DMA faster than the drive.

Tests: power-on and reset, JMP208 open, AEN, the window; the BIOS's
detection sequence (reset, recalibrate without a mask write, E4, test
ready, reset with recalibrate and initialize for both drives, drive 1's
failures and sense, E0/E3 times, a cut CCB, the mask, a completion read
with the interrupt still enabled); spin-up and media; PIO and DMA reads
and writes of 1-256 sectors across head and cylinder boundaries, read long
/ write long, verify; seeks over 0-614 cylinders and recalibrate; the
sector buffer (DMA, PIO, fast DMA, after reads and writes), the ECC burst
length; format track at interleave 1 (a revolution per sector), 2 (too
fast for single-transfer DMA), 5 and 4, format bad track, bad interleaves;
errors (invalid commands, C/H/S out of range, past the end, backend read
and write errors, a select in a running DMA read, a 3 ms backend); 25
random reads and writes.

Results (final RTL): **2,742,243 checks, 0 failed** (seed 1, 7.5 s of PC
time, ~45 s wall; seed 7 the same); with `-f` the full format takes
**56.40 s** of PC time as the model predicts (43,174,827 checks, 0 failed).
`mut.py`: **45 mutants, 45 killed** (fedora, `-j 6`). The bench grew with
them: the first version missed 3 (the interrupt latch at the completion
read, a read arming one sector early, write-behind overrunning the slots),
and the system runs below found 2 bus faults that became 5 more mutants.

### 10.2 tb/sys (the PC20-III with the Commodore BIOS 4.41)

`make FE=1 PVC4=1 XTA=1`, `sys_run -b cbm-pc10c-bios-v4.41-318085-08.bin
-d 5D -A image -xl` (on fedora; ~90 s wall per simulated second).

- **DMA test ROM** (`tb/sys/hd/xtadma.S`, 8 KB, `mkxtadma.py`): with DRAM
  refresh running, 16 rounds of 0Fh/0Eh by DMA (each 512 DACK3 cycles and
  TC on channel 3, 1.07-1.29 ms per sector while the CPU polls the status)
  and 0Eh by PIO; the buffers compare equal.
- **Detection, cold boot** (`hdtest.img` from `mkhdimg.py build`): the disk
  BIOS starts at 1.5 s: controller reset, recalibrate (04: still spinning
  up; the BIOS ignores it), E4, test ready + request sense until the drive
  is ready at 5.0 s, then reset (recalibrate 0 OK, 1 fails 22h/04h), the PIO
  read of sector 0, initialize 0 and 1, recalibrate, test ready of drive 1
  (OK). No "Hard disk not found"; "System RAM 640 KBytes OK".
- **Boot from C:** at 45.6 s INT 19h resets the drive and reads sector 0 by
  DMA (512 DACK3 cycles); the MBR test prints `MBR test, drive 80`,
  `AH=08 CX DX 6591 0301` (last cylinder 613, 17 sectors, 4 heads, one
  drive), the text of C0 H0 S2, `read 20, sum F600 OK` (10,240 DACK3 cycles
  in 62.6 ms), `write 3, read back OK`, `done`. `mkhdimg.py check` on the
  written image: only LBA 49-51 and 59 changed, as expected. 60 s of PC
  time in 5,535 s wall.
- **JMP208 open** (`-jmp208 A`): "Hard disk not found", no drive command:
  the PC10-III as before.
- **The WD formatter** (`tb/sys/hd/fmtboot.S`: a boot floppy with a
  5-function INT 21h that jumps to F800:0005; `-k` types the answers): the
  banner and "Current Drive is C:" appear; the answers are Enter (drive),
  Enter (interleave 4), N (dynamic), N (virtual), y (start), then N (bad
  tracks, asked after the format; "virtually" is asked only after a Y to
  "dynamically"). The formatter writes the sector buffer (0Fh, DMA) and
  formats the drive (04h, interleave 4) at 50.50 s; the command ends at
  106.86 s (**56.36 s**, the timing model's 56.4 s), the screen shows
  "Formatting . . .", "Do you want to format bad tracks - answer Y/N N",
  "Format Successful", "System will now restart", "Insert DOS diskette in
  drive A:". The image: 41,820 sector writes, every sector the same 512
  bytes (the buffer, taken from 0000:0130 as noted in section 13). 125 s
  of PC time in 11,377 s wall.
- **DOS** (2026-10-26, `sys_run -e 'text|keys' ... -E text`: keys typed when
  the cursor's line shows a text): Commodore MS-DOS 3.21 (the PC10-III's own,
  not in the repository) from A: with a blank image: FDISK creates the
  partition (whole disk, active) and restarts; `format c: /s` verifies about
  0.38 s per cylinder, ~235 s of PC time for the drive (history 2026-10-26).
- `-w` (the warm-boot flag in RAM) does not help with this BIOS: it still
  tests the memory and then fails "Bad DMA port = 0004h" (a power-on state
  that is not a warm one); the runs above are cold boots.

Two faults found here, both invisible to the unit bench at first:
- DACK3 outlasts AEN into the CPU's next I/O cycle: the card took the
  BIOS's status poll for a DMA read and returned a buffer byte (the boot
  sector read hung). Fix: a DMA cycle is DACK3 with AEN.
- The board's DMA in a CPU read's last wait state (section 9.7): the status
  poll read FFh, and the resumed strobe moved a second data byte. Fixes:
  `xt_board.sv` keeps the cut command's data; the card moves one byte per
  bus cycle.

### 10.3 Gates

Every existing build is unchanged (`XTA_FIT` = 0): on fedora
`gates.sh xta-f` against `merge-a` (main): `g_tr.sha`, `g_tre.sha`,
`g_trL2.sha` identical, `g_fd.log` identical but for the wall time, tb/fdc
(232 checks), tb/hdc (3,182 checks), tb/cga, tb/mda PASS with identical
logs. Locally tb/shell (`bash tb/shell/run.sh`, fedora lacks M2M/QNICE)
and tb/pvc4 (`make run`) PASS.

## 11. The MEGA65 shell

Built since 2026-10-26 (branch `xta-shell`; doc/m2m-shell.md sections 4
and 8 have the shell's side in its context).

- **`pc_system_flat`**: `XTA_FIT` = 1, the `xta_*` ports through
  `main.vhd` to `mega65.vhd`. `rtl/hdc/xta_card.sv` is in `gen_xpr.py`,
  `CORE/CORE-R6.xpr` and the OOC run (`tools/ooc/pc_ooc.tcl`, where the card
  is fitted too). The stand-in `CORE/stub/pc_system.sv` has the ports and
  ties them off.
- **The image**: a raw file of exactly 21,411,840 bytes (41,820 sectors,
  615 x 4 x 17 x 512, kobolt's format; LBA = (C x 4 + H) x 17 + S - 1 in
  INT 13h terms). Any other size is refused by the firmware ("Not a PC20-III
  hard disk image: C: needs exactly 21,411,840 bytes") and is no disk for
  the backend. Menu line ` C:%s` (line 4, manual ROM 2).
- **JMP208 = an image is mounted** (the user's decision): `xta_enable` and
  `xta_present` are the same signal, `pc_fdd_sd.vhd`'s `hd_present_o`. A
  machine without an image is a PC10-III: the ports float, the BIOS says
  "Hard disk not found" without the 24 s wait. No separate menu item.
- **Changing the mount while the PC runs** needs nothing more: the BIOS
  looks for the drive only when it starts, so the user mounts the image and
  then resets the PC (menu "Reset the PC", or the reset button). While the
  firmware maps a new image the drive is off (no disk, JMP208 open) for a
  moment; a command that runs then fails (sense 04h, or a write fault for
  writes behind). A new image is a new medium: the drive spins up for 5 s
  (the BIOS waits for it). The image is not remembered over a power cycle
  (the floppies are not either; doc/m2m-shell.md section 12).
- **Backend** (`CORE/vhdl/pc_fdd_sd.vhd`, the floppies' engine): drive 2 =
  C:, QNICE device `C_DEV_PC_HDC` (0x0105) with the floppies' registers and
  windows, its own extent map (2048 words: **at most 511 extents**, as for
  the floppies; a more fragmented file is refused with "Image too
  fragmented": copy it to a freshly formatted card, or defragment). A
  second main-side sector port (the hd_sp_* protocol: `xta_sp_lba` 28 bits,
  an LBA above 65535 or >= 41,820 ends with `sp_err`) and an arbiter: one
  request at a time through the one engine, the FDC's and the hard disk's
  in turn when both ask (round robin), the answer only to the port being
  served; a request that its port drops before `sp_done` (RESET DRV during
  a transfer) is abandoned. Write-through as for the floppies: `sp_done`
  of a write comes when the block is on the card. C: is never
  write-protected.
- **Latency**: each sector is one single-block SD transfer (native 4-bit
  bus at 25 MHz, or SPI): the request's clock crossing and the extent walk
  take a few us, the block about 50-300 us to read on typical cards, then
  18 us to stream it to the card at one byte per clock. That is inside the
  drive's ~0.6 ms slot (section 9.5), so reads keep the modelled timing.
  Single-block writes can take a few ms on SD cards (their programming
  time): then a write or format command takes longer than the real drive
  (the data stay correct). A FDC request in front adds at most one floppy
  transfer. Not measured on hardware yet.
- **LED**: the MEGA65's drive LED is red while `xta_active` is set (the
  drive busy, or a write still going to the image), yellow while a floppy
  drive is selected (a floppy wins). No drive sound for the hard disk.
- **Settings file**: menu signature `menu=6` (the 50-line menu).
- **A ready image**: a blank file of the right size (zeros: the model
  counts it as formatted, section 13) is enough for DOS FDISK and FORMAT;
  `tb/sys/hd/mkhdimg.py build` makes the MBR test image; the WD formatter
  (section 7: DEBUG `g=f800:5`, or the boot floppy of `tb/sys/hd/mkfmtboot.py`)
  does the drive's low-level format (its interleave is not kept over a
  power cycle: the model starts at 3).

## 12. Steps

1. Disassembly, references, this specification: **done** (2026-10-25).
2. `xta_card.sv` with the drive model, the `pc_system` parameter, the tb/sys
   options: **done**.
3. tb/xta unit bench and mutants: **done**.
4. tb/sys with the Commodore BIOS: detection and boot from C: **done**;
   the WD formatter **done** (section 10.2).
5. Shell: menu (image, JMP208), SD backend, LED, settings signature:
   **done** (2026-10-26, section 11).
6. Build: **done** (build `pc10-xta-a`); hardware test: open.

## 13. Open questions

- **[Q] Drive 1 on a single drive.** Does the WD93024-X answer test ready
  for drive 1 with "not ready", or with success? The model says success
  (`DRV1_READY` = 1, kobolt); "not ready" costs 4.9 s on every cold boot
  and up to ~14 s on Ctrl-Alt-Del. Initialize (0C) succeeds for drive 1
  either way.
- [Q] The configuration register's bits 7 and 3-2 on the real drive (FFh fits
  everything the BIOS does).
- [Q] The translation (assumed linear) and how the drive applies an
  interleave given for 17-sector tracks to its 27-sector tracks (assumed:
  directly), whether it is one value per drive or per track; whether format
  writes the buffer's data or a fixed pattern (assumed: the buffer, as
  86Box). The formatter writes its buffer from 0000:0130 (ES = 0), so with
  DEBUG it formats the interrupt vectors 4Ch-CBh into every sector.
- [Q] Command overhead, spin-up time, reset time, the per-byte REQ time,
  track skew (none modelled: a cylinder step during a sequential read costs
  one revolution).
- An unformatted (blank) drive: a new image counts as formatted with zeros.
- -HDCS's decoded range and the CN203 pin.
- GLaBIOS has no disk BIOS: without the Commodore ROM the drive needs an
  option ROM (a WDXT-150 BIOS would work, but it is WD's code).
- [Q] The shell forgets the C: image at power-off (as the floppies'):
  remember its path in the settings file's text (M2M exception 17, as
  Megamiga's profiles do), so the PC20-III boots from C: without a menu
  visit? Chosen for now: not remembered (the simple option, the same as A:
  and B:).
- [Q] Images of other sizes (a smaller file with the sectors beyond it
  failing, section 11 of the plan) are refused: the drive has one size.
- The SD card's single-block write time on real cards (section 11's
  latency): not measured.
