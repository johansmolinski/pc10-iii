# PC10-III core - hard disk (XTIDE card)

Status: 2026-10-22, branch `xtide`. RTL in `rtl/hdc/`, unit bench in
`tb/hdc/`, system runs with `tb/sys`.

An 8-bit ISA hard disk card compatible with the XTIDE family, driven by the
XTIDE Universal BIOS (XUB) in its option ROM socket. Two ATA drives (master
and slave) whose media are disk images; the MEGA65 glue serves them sector
by sector, like the floppy images.

## 1. Files

| File | What |
|---|---|
| `rtl/hdc/xtide_card.sv` | the card on the card bus: the register maps of three XTIDE variants, the data latch, the option ROM socket, IRQ |
| `rtl/hdc/ata_dev.sv` | the ATA drive pair: task file, commands, IDENTIFY, CHS/LBA, status/INTRQ, the timing model |
| `rtl/hdc/hdc_secbuf.sv` | the sector buffer (8 x 512 bytes, one RAMB36) and the sector-port engine |
| `tb/hdc/` | Verilator unit bench (`make run`) and mutants (`mut.py`) |
| `tb/sys/hd/mbr.S`, `mkhdimg.py` | the hard disk test image of the system bench |
| `tools/xubcfg.py` | configures an XUB binary for the card (device type, port), pads it and fixes the checksum |

All on `clk` (28.63636 MHz) with a 1 us enable inside `ata_dev` (clk x 11/315). One RAMB36
for the buffer; the ROM socket is the glue's (8 KB = 2, 16 KB = 4 RAMB36).

## 2. Which XTIDE

XUB (r6xx) drives these 8-bit cards:

| XUB device type | Card | Register map | 8088 read loop (per word) | 8088 write loop (per word) |
|---|---|---|---|---|
| 4 XTIDE rev 1 | the original XTIDE | regs at +0..7, data high latch at +8, control at +9..F | `in al,dx` `xor dl,bl` `stosb` twice (8 code bytes) | `lodsw` `xor` `xchg` `out` `xor` `mov` `out` (11 bytes) |
| 5 XTIDE rev 2 | rev 2, or rev 1 with A0/A3 swapped ("Chuck mod") | rev 1 with A0 and A3 swapped: data low/high at +0/+1 | `in ax,dx` `stosw` | `lodsw` `inc dx` `xchg` `out` `dec dx` `mov` `out` (9 bytes) |
| 7 XT-CF PIO8 | XT-CF (CompactFlash), XUB's default for `ide_xt.bin` | reg n at +2n, control block at +10h+2n; the drive in 8-bit mode | `in al,dx` `stosb` per byte | `lodsb` `out dx,al` per byte |
| 8 XT-CF PIO8 + BIU offload | XT-CF; A0 not decoded | as 7 | `in ax,dx` `stosw` | `lodsw` `out dx,ax` |
| 9 XT-CF PIO16 + BIU offload | Lo-tech 8-bit ISA IDE adapter | as 7, high-byte latch at +1 | `in ax,dx` `stosw` | `lodsw` `out dx,ax` |
| 10 XT-CF DMA | XT-CFv3 | as 7 plus a DRQ trigger at +1Eh | 8237 channel 3, 16-byte bursts | same |
| 11 JR-IDE/ISA | memory-mapped | registers and a 512-byte sector window in a 16 KB memory block | `rep movsw` from the window | `rep movsw` to it |

Estimated cost on the 5160 (4.77 MHz; a memory cycle 4 clocks, an I/O cycle
5 with the board's wait state, a code byte fetch 4; the bus-bound lower
bound, without DRAM refresh and loop overhead), and what this core's
cycle-exact 8088 measured in `tb/sys` (section 7: XUB's INT 13h loops on a
20-sector read and a 3-sector write; per sector inside a DRQ block):

| Mode | read, clocks/word | write, clocks/word | measured read | measured write |
|---|---|---|---|---|
| XTIDE rev 1 | >= 50 (8 code bytes, 2 I/O, 2 mem) | >= 62 | | |
| XTIDE rev 2 | >= 26 (2 code bytes, 2 I/O, 2 mem) | >= 54 | 1.82 ms = 34 clk/word, 280 KB/s | 3.59 ms = 67 clk/word, 143 KB/s |
| XT-CF PIO8 | >= 34 (two byte loops) | >= 34 | 2.44 ms = 46 clk/word, 210 KB/s | 2.48 ms = 46 clk/word, 206 KB/s |
| XT-CF / Lo-tech with BIU offload | >= 26 | >= 26 | 1.77 ms = 33 clk/word, 289 KB/s | 1.81 ms = 34 clk/word, 283 KB/s |
| JR-IDE `rep movsw` | ~25 (EU-bound, no code fetch) | ~25 | | |
| XT-CF DMA | 8237: a few clocks per byte | same | | |

(Rev 2 was measured with XUB's tiny build, which unrolls 8 words per loop
instead of 16; that costs it about 3%.)

**Choice: the XT-CF / Lo-tech register map (variant 0), used with XUB device
type 9 ("XT-CF PIO16 with BIU offload", the Lo-tech 8-bit IDE adapter).**
- It is the fastest PIO mode on an 8088 in both directions: `in ax,dx` /
  `stosw` and `lodsw` / `out dx,ax`, two code bytes per word (measured 289
  KB/s read, 283 KB/s write). Rev 2 reads as fast but writes at half the
  speed (the high byte must go to the latch first); XT-CF's 8-bit mode is
  ~30% slower. Only the memory-mapped JR-IDE (a few % faster, but a 16 KB
  memory window in the upper memory area) and DMA are faster.
- It talks to a plain 16-bit ATA drive: the card latches the high byte, the
  drive needs no 8-bit mode.
- The same decoder also runs XUB's default configuration of `ide_xt.bin`
  (type 7, XT-CF PIO8 at 300h) and type 8: the drive model implements SET
  FEATURES 01h (8-bit transfers), and in 8-bit mode the card treats +1 as
  the data register, as the XT-CF does (A0 not decoded). So an unconfigured
  XUB works out of the box, only slower.
- The hardware is small: an I/O decoder, two latches. DMA (type 10) would
  need DRQ3/DACK3 and the 8237's block/demand transfers, which are in the
  middle of the board-timing work; JR-IDE needs a memory window next to the
  ROM. Both are left for later.

The card also decodes the **XTIDE rev 1** (variant 1) and **rev 2** maps
(variant 2), a few multiplexers more, so a user's existing XUB image
configured for those cards works too, and so does XUB's tiny build (4 KB,
no XT-CF support). MartyPC implements a rev 2 card (`hdc/xtide.rs`), so
variant 2 also allows bus-trace comparisons with MartyPC. The variant is a
run-time input (`hdc_variant`), meant for the menu.

## 3. The card (`xtide_card`)

I/O ports (from `IO_BASE`, default 300h, AEN = 0):

| Variant | Ports | Command block n | Control block (alt. status / device control) | Data |
|---|---|---|---|---|
| 0 XT-CF / Lo-tech | 300-31F | 300h + 2n (A0 ignored) | 31Ch | 300h; 301h = high-byte latch (16-bit) or data (8-bit) |
| 1 XTIDE rev 1 | 300-30F | 300h + n | 30Eh | 300h; 308h = high-byte latch |
| 2 XTIDE rev 2 | 300-30F | rev 1 with A0 <-> A3 | 307h | 300h; 301h = high-byte latch |

16-bit transfers through the latch:
- read: the low address takes a word from the drive, returns its low byte
  and keeps the high byte for the latch address;
- write, variant 0 (`out dx,ax`: 300h then 301h): 300h stores the low byte,
  301h writes the word;
- write, variants 1/2 (XUB writes the high byte first): the latch address
  stores the high byte, 300h writes the word.
- 8-bit mode (after SET FEATURES 01h): every access to 300h (and 301h in
  variant 0) moves one byte.

Read and write latches are separate. The card answers only registers that
exist: the command block, alternate status; the rest of the window reads
FFh (nothing drives the bus).

**Option ROM socket**: MEMR at C8000-CBFFF (16 KB, `ROM_BASE`) reads the
glue's ROM (`hdc_rom_addr` = SA13-SA0, `hdc_rom_rdata` one clk later, as the
BIOS ROM). DMA memory reads see it too (memory decoders ignore AEN). Writes
are ignored (no flash programming). An 8 KB XUB in the 16 KB socket: the
glue fills the rest with FFh. The BIOS's option ROM scan (C8000-F4000, 2 KB
steps, checksum) finds it.

**IRQ**: none by default (`IRQ = 0`): XUB's XT builds poll. A parameter wires
INTRQ to IRQ2-7 (IRQ5 is the XT's hard disk line) for software that wants it.

**`hdc_enable` = 0**: the card is not in a slot: no I/O, no ROM.

The card never inserts wait states (`isa_ready` = 1): data are always ready
(section 4), and a real XTIDE has none either.

## 4. The drives (`ata_dev`)

An ATA-2 style PIO device pair. Both drives see every register write (one
task file); a command runs on the drive selected (DEV bit) when it was
written, one command at a time.

Commands:

| Code | Command | Notes |
|---|---|---|
| 20h/21h | READ SECTORS | |
| 30h/31h | WRITE SECTORS | |
| C4h/C5h | READ/WRITE MULTIPLE | ABRT without SET MULTIPLE |
| C6h | SET MULTIPLE MODE | 0 (off), 1, 2, 4, 8; anything else ABRT (XUB tries 128, 64, ... and settles on 8) |
| 40h/41h | READ VERIFY SECTORS | range check only |
| 91h | INITIALIZE DEVICE PARAMETERS | heads = DH[3:0] + 1, sectors = SC; cylinders = capacity / (heads x sectors), at most 65535; SC = 0 ABRT |
| ECh | IDENTIFY DEVICE | |
| EFh | SET FEATURES | 01h/81h 8-bit transfers on/off; 02h/82h, 03h, 55h/AAh, 66h/CCh accepted; the rest ABRT |
| 1xh, 7xh | RECALIBRATE, SEEK | no-ops |
| 90h | EXECUTE DEVICE DIAGNOSTIC | code 01h, signature |
| E0-E3h, E6h, 94-97h, 99h | standby, idle, sleep | no-ops |
| E5h, 98h | CHECK POWER MODE | SC = FFh (active) |
| others | | ABRT |

LBA48, DMA, READ/WRITE BUFFER and the security/SMART sets are not there
(IDENTIFY says so).

**Addressing**: LBA28 (DH bit 6) or CHS with the current geometry:
LBA = (C x heads + H) x sectors + S - 1. A CHS address outside the current
geometry, or an LBA beyond the image, ends the command with IDNF (in a
multi-sector command at the first missing sector, after the ones before
it). The current geometry starts as the image's default (the glue's
`hd_cyls/heads/spt`) and changes with INITIALIZE DEVICE PARAMETERS.

**Task file after a command**: a data command leaves the address of the
last sector transferred and SC = 0; after an error the failing sector and
the sectors left (counting it); in CHS mode converted back with the current
geometry. A CHS address that does not exist stays as written.

**Status**: BSY = 80h exactly (other bits 0); during a data block
DRDY|DSC|DRQ (58h); otherwise DRDY|DSC (50h) plus ERR and DF from the last
command. Errors: ABRT (04h), IDNF (10h), UNC (40h, a backend read error), a
backend write error = DF + ERR + ABRT.

**INTRQ**: set with each DRQ block of a read (also IDENTIFY), with each
block of a write except the first, and at the end of a write or non-data
command, or an error; cleared by reading Status (not the alternate status)
and by a new command; masked by nIEN.

**IDENTIFY**: word 0 = 0040h (fixed disk), 1/3/6 default C/H/S, 20-22
buffer, 10-19 serial `PC10III-DISK-000000x` (x = 0/1), 23-26 firmware `0.1`,
27-46 model `PC10-III XTIDE disk image`, 47 = 8008h (READ/WRITE MULTIPLE up
to 8), 49 = 0200h (LBA), 51 = 0200h (PIO mode 2 timing), 53 = 1, 54-58 the
current geometry and capacity, 59 the multiple setting, 60-61 the LBA
capacity. Everything else 0 (no ATA version claimed, no power management,
no LBA48).

**Absent drives** (ATA): with the master present and the slave absent, the
slave's Status and Alternate Status read 00h and its commands are ignored,
so XUB gives up on it after its 0.5 s detection timeout. With no drive at
all, every register reads 7Fh (the pull-down on DD7 of a real cable: BSY =
0), so XUB does not wait for a busy bus.

**Resets**: RESET DRV and SRST (device control bit 2) reset both drives:
BSY while SRST is held and for `RESET_US` after it, then the signature (SC
= SN = 1, cylinder 0, DH = 0), error register 01h (diagnostic passed). A
sector transfer in flight is finished first. SRST also turns 8-bit mode off
(XUB re-enables it after a reset, as the XT-CF needs). The multiple mode and
the geometry survive SRST; RESET DRV and a new medium (`hd_present` rising)
restore the defaults.

### Timing model

What the CPU sees is deterministic for a given backend:

| Event | Time | Source |
|---|---|---|
| BSY after a command write | the next clk | ATA: within 400 ns |
| non-data command, IDENTIFY, first DRQ of a write | `CMD_US` = 5 us (IDENTIFY: or the 512 clk = 18 us of writing its sector into the buffer, if longer) | plausible for a fast drive / CF card; MartyPC answers at once |
| first DRQ of a read | `CMD_US`, or later when the backend is slower | the backend's latency |
| between DRQ blocks | `BLK_US` = 2 us, plus any wait for the backend | |
| end of a write | when the backend has stored every sector | write-through, like the FDC |
| reset (RESET DRV, SRST) | `RESET_US` = 1 ms after it ends | real drives take up to 31 s; XUB polls |

Reads are prefetched up to 8 sectors ahead of the host, writes committed up
to 8 sectors behind it (the buffer is a ring of 8 slots). A backend that
delivers a sector faster than the host transfers one (about 1.4 ms on a
4.77 MHz 8088) is invisible apart from the first sector's latency; a slower
one stretches the BSY gaps between blocks. The CPU never waits on the bus.

## 5. Sector port

The floppy's protocol (doc/fdc.md section 5) with the address widened:

| Signal | Dir (card) | Meaning |
|---|---|---|
| `hd_sp_req` | out | a transfer is requested; held until `hd_sp_done` |
| `hd_sp_write` | out | 0 = read the sector into the card, 1 = store the card's data |
| `hd_sp_drive` | out | 0 = master, 1 = slave |
| `hd_sp_lba[27:0]` | out | the sector (LBA28) |
| `hd_sp_rd_valid`, `hd_sp_rd_data` | in | read data, one byte per strobe, any spacing |
| `hd_sp_wr_valid`, `hd_sp_wr_data`, `hd_sp_wr_ready` | out/out/in | write data, taken when ready |
| `hd_sp_done`, `hd_sp_err` | in | the transfer is over / failed |

Same rules: one transfer at a time, fields stable while `req` is high, a
new request at the earliest one clk after `req` dropped, write bytes at
most every second clk, a read with fewer than 512 bytes (or a write whose
bytes were not all taken) counts as failed. The floppy's C/H/S fields are
not there: a hard disk image is linear.

Per drive inputs: `hd_present`, `hd_sectors` (LBA capacity, 28 bits),
`hd_cyls` / `hd_heads` (1-16) / `hd_spt` (1-63): the default geometry.

**Geometry from an image** (what tb/sys does, and the plan for the shell):
1. a geometry given by the user (or later a VHD footer / a `.geo` sidecar);
2. else the MBR's partition table: heads = largest end head + 1, sectors =
   its end sector (what DOS's FDISK wrote with the BIOS geometry);
3. else 16 heads x 63 sectors;
then cylinders = sectors / (heads x spt), at most 65535. `hd_sectors` is the
image size / 512 (sectors beyond C x H x S stay reachable by LBA).

## 6. XTIDE Universal BIOS

**Licence**: GPL-2.0-or-later ("either version 2 of the License, or (at your
option) any later version", the header of every source file; `license.txt`
in the repository is the GPLv2 text). It is compatible with this core's
GPL-3.0-or-later, and a configured binary may be shipped (in a release, or
preloaded in the bitstream) as long as the corresponding source goes with
it: the unmodified r638 sources plus the configuration (a few bytes in
ROMVARS, written by `tools/xubcfg.py` or XTIDECFG). The binary is a
separate program that the emulated PC runs, not part of the RTL.

**Source and binaries** (downloaded 2026-10-22, kept outside the repository
in `~/pcxt-work/xtide/`):
- binaries: https://www.xtideuniversalbios.org/binaries/r638/ (built
  automatically from each commit; `r638/` = revision 638, 2026-06-09):
  `ide_xt.bin` (8 KB class, XT builds with XT-CF and JR-IDE support),
  `ide_xtl.bin` (large, 12 KB, with the boot menu), `ide_tiny.bin` (4 KB, no
  XT-CF), `ide_xtp*.bin` (V20/V30: 186 instructions, not for an 8088),
  `xtidecfg.com`. The binaries are neither padded nor checksummed; XTIDECFG
  (or our tool) does that when it saves.
- source: https://www.xtideuniversalbios.org/svn/xtideuniversalbios/trunk/
  (Subversion, browsable over HTTP; `XTIDE_Universal_BIOS/`,
  `Assembly_Library/`, `license.txt`), built with NASM.

**Configuration** with `tools/xubcfg.py` (or XTIDECFG.COM on a PC):

```sh
tools/xubcfg.py ide_xt.bin xub.rom --device lotech           # type 9 at 300h, card variant 0 (recommended)
tools/xubcfg.py ide_xt.bin xub.rom --device xtcf-pio8        # XUB's default: variant 0 in 8-bit mode
tools/xubcfg.py ide_tiny.bin xub.rom --device rev2 --no-slave  # 4 KB build, card variant 2
tools/xubcfg.py xub.rom --info
```

It sets the first controller's port and device type (ROMVARS at offset 4Eh:
port, control port, device byte), optionally the slave's "do not detect"
flag, pads to the ROM size in the header and makes the byte sum 0. The
offsets are XUB r6xx's; the tool checks the signature and the device byte
first. XTIDECFG works as well: Configure XTIDE Universal BIOS -> Primary IDE
Controller -> Device type "XT-CF (PIO16 w/ BIU offload)" or "Lo-tech 8-bit
IDE", base port 300h; then save to a file.

Which build: `ide_xt.bin` for an 8088. It has the hotkey bar: XUB shows it
for at least 4 s before it boots (`MIN_TIME_TO_DISPLAY_HOTKEY_BAR`), which
also costs 4 s in simulation; `ide_tiny.bin` boots at once but supports only
the rev 1/rev 2 maps (card variant 1/2) and has no hotkeys. `ide_xtl.bin`
adds the boot menu (12 KB).

## 7. Verification

### tb/hdc (unit bench)

`make run`: Verilator, the card with IRQ5, a C++ model of the 5160's I/O
and memory cycles, the ROM (1 clk) and a backend with random latency (2-60
us per sector) and byte spacing, two images (master 615/4/17 = 20 MB,
the ST-225 geometry; slave 64/16/63 + 100 sectors beyond C x H x S). All
tests run for each of the three register maps:

- reset: BSY for 1 ms, signature, diagnostic code;
- IDENTIFY: geometry, capacity, multiple, LBA, model/serial strings, per drive;
- READ/WRITE SECTORS in LBA mode (1-256 sectors), data against the model,
  the task file after the command;
- CHS: a read across a head and a cylinder boundary, IDNF for S = 0, S > spt,
  H >= heads (the address stays); INITIALIZE DEVICE PARAMETERS 16 x 63 (41
  cylinders), IDENTIFY words 54-58, a write in that geometry, back to the
  default;
- MULTIPLE: ABRT before SET MULTIPLE, SET MULTIPLE 128/16/3 ABRT, 8 and 4
  accepted, READ MULTIPLE 20 (blocks 8+8+4), 13 (m = 4), 256 through the
  ring, WRITE MULTIPLE 21 and 9, the number of interrupts per command;
- timing and INTRQ: IDENTIFY DRQ ~18 us after the command (10 us at 100 MHz), alternate status
  vs status, no interrupt at the end of a read, one per block, the first
  sector after the backend's 50 us, later ones `BLK_US` after the block's
  last strobe (prefetched), nIEN, no INTRQ before a write's first block, the
  end of a write only after the backend stored it (300 us), a backend
  slower than the host (2.5 ms per sector, the ring fills);
- errors: IDNF past the end (after the sectors that exist), a backend read
  error in the 3rd of 5 sectors (UNC, two sectors delivered, task file at the
  failing sector), a short backend read, an error inside a READ MULTIPLE
  block (no DRQ), a backend write error (DF ERR ABRT), invalid commands and
  features, INITIALIZE with 0 sectors, VERIFY in and past the range;
- SRST in the middle of a read, the signature, a read after it;
- 8-bit mode: reads and writes with byte transfers (300h/301h on the XT-CF
  map), SRST and SET FEATURES 81h back to 16-bit;
- the slave (its last sectors beyond C x H x S, the drive bit on the port),
  an absent slave (status 00h, commands ignored), no drives (7Fh), a new
  medium (default geometry);
- the ROM socket (data within 2 clk and stable, the window edges, disabled
  card), AEN, the I/O window edges;
- 40 + 15 + 15 random reads/writes on both drives, mixed block sizes.

Result: **3184 checks, 0 failed** (1.8 s of PC time, ~50 s wall).

`mut.py` (20 mutants, 4 in parallel): the rev 2 swap, the Lo-tech write
order, 301h as data in 8-bit mode, the rev 1 read latch, the MULTIPLE block
step, a write ending before the backend, ring overrun, the capacity check,
the CHS sector base, Status clearing INTRQ, SRST and 8-bit mode, the SET
MULTIPLE check, IDENTIFY capacity, DRQ before the prefetch, INTRQ before a
write's first block, INTRQ at the end of a read, the absent slave's status,
the block gap, the CHS end address, a short backend read: **20 of 20
killed**.

### tb/sys (the whole PC)

Four runs on the Fedora host (`tb/sys`, built with `RAM_KB=128` so that
GLaBIOS's memory test takes ~0.25 s instead of ~5 s; GLaBIOS 0.4.2 8X; the
image `~/pcxt-work/xtide/hdtest.img` from `tb/sys/hd/mkhdimg.py build`; 10 s
of PC time each, ~35 minutes; backend latency 20 us per sector):

```sh
make RAM_KB=128 OBJ=obj128
tools/xubcfg.py ide_xt.bin xub_xt_lotech.bin --device lotech
./obj128/sys_run -b GLABIOS_0.4.2_8X.ROM -s 10 -X xub_xt_lotech.bin -V 0 -d 6C \
    -H in.img -W out.img -S 1000,2000,3000
tb/sys/hd/mkhdimg.py check hdtest.img out.img
```

| Run | XUB | card | SW1 | XUB boots C: at | result |
|---|---|---|---|---|---|
| a | `ide_xt.bin` r638, type 9 (Lo-tech) | variant 0 | 6Ch: no floppy drive | 6746 ms | MBR test OK, image check OK |
| b | same | variant 0 | 6Dh: two drives, no diskette | 8837 ms (+2 s: GLaBIOS's floppy POST) | OK, OK |
| c | `ide_xt.bin` r638, type 7 (XT-CF PIO8, XUB's default; 8-bit transfers) | variant 0 | 6Ch | 6746 ms | OK, OK |
| d | `ide_tiny.bin` r638, type 5 (rev 2), slave not detected | variant 2 | 6Ch | 4809 ms (no 4 s hotkey bar) | OK, OK |

The screen at the end of run a:

```
GLaBIOS [.] Reboot the Past
(C) 2022-26 640KB Released under GPLv3
Boot   [ COLD ]
RAM    [ 128 KB OK ]            Video  [ CGA ]
CPU    [ 8088 ]                 FPU    [ None ]
LPT    [ None ]                 COM    [ None ]
ROM    [ C800 ]                 Size   [ 8 KB ]
FDD    [ 0 ]
-=XTIDE Universal BIOS (XT)=- @ C800h
r638 (2026-06-09)
Released under GNU GPL v2
Master at 300h: PC10-III XTIDE disk image
Slave  at 300h: not found
Booting C.C
MBR test, drive 80
AH=08 CX DX 6691 0301
S2: PC10-III test sector C0 H0 S2
read 20, sum F600 OK
write 3, read back OK
done
```

- GLaBIOS's option ROM scan finds XUB at C800 (8 KB, checksum good); XUB
  identifies the master (the model string from IDENTIFY), gives up on the
  absent slave after its 0.5 s timeout, shows the hotkey bar for 4 s, and
  boots the MBR from C: (run b: with two floppy drives without diskettes).
- The MBR (`tb/sys/hd/mbr.S`): INT 13h AH=08h returns CX = 6691h, DX = 0301h
  = 615 cylinders, 17 sectors, 4 heads, one drive; AH=02h reads the text at
  C0 H0 S2 and 20 sectors from C0 H1 S10 across a head boundary (sum F600h,
  as the builder computed); AH=03h writes 3 sectors at C0 H2 S16 across a
  head boundary, reads them back and compares; it writes a copy of itself to
  C0 H3 S9.
- XUB used READ/WRITE MULTIPLE with 8-sector blocks (it settles on the
  IDENTIFY maximum); the backend saw the first 8 sectors of the 20-sector
  read at once (prefetch), then one every 1.77 ms as the host took them.
- `mkhdimg.py check` on the written-back images: exactly LBA 49-51 (the
  pattern) and 59 (the MBR, with its `drive` byte = 80h) changed, in all
  four runs.

Outputs: `~/pcxt-work/xtide/runs/run_[abcd].txt` and `out_[abcd].img`.

## 8. The MEGA65 shell (plan, not built)

What `CORE/` needs to serve the card (doc/m2m-shell.md is the floppy's
pattern; nothing of this is implemented yet: `pc_system_flat.sv` ties the
card off with `hdc_enable = 0`):

**Option ROM**: `pc_xub.vhd`, a 16 KB dual-port block RAM (4 RAMB36; 2 for
an 8 KB-only socket) like `pc_bios.vhd`: QNICE on port A, the PC on port B
(`hdc_rom_addr`, 1 clk). Loaded from `/pc10/xub.rom` as an optional
auto-load ROM (like `/pc10/char.rom`), FFh where the file ends. Without a
file: either an empty socket (no hard disk) or a configured r638
`ide_xt.bin` preloaded in the bitstream (allowed by the licence, section 6;
the release then names the source).

**Images**: a hard disk image is a raw file (`.img`, `.hdd`; no VHD footer
parsing at first). Menu lines `C:%s` and `D:%s` (manual loads, the file
browser) mount master and slave. `PREP_LOAD_IMAGE` resolves the file to an
extent map (`FAT32$FILE_MAP`) as for the floppies and computes the geometry
(section 5: the MBR's partition table, else 16 x 63; the firmware reads
sector 0 itself) and writes `hd_sectors/cyls/heads/spt` into the device.
Fragmented images need many extents: the floppy device holds 511; a 32 MB
image with 4 KB clusters can need more in the worst case, so either a
bigger map (2048 words is one RAMB36 per drive; 4 drives = 4 tiles) or a
"defragment the image" message when `FILE_MAP` overflows. Megamiga's
alternative also fits: a whole SD partition (MBR type 7Fh, `HDF_LINK`)
as the disk, one extent.

**Backend**: generalise `pc_fdd_sd.vhd` into one SD backend for four units
(A:, B:, master, slave) sharing the engine port: an arbiter between the
FDC's and the card's sector ports (both are one-transfer-at-a-time, so a
simple round robin at request boundaries), a per-unit extent map, the LBA
widened to 28 bits. One block per request (CMD17/CMD24) is fast enough: the
8088 takes ~1.4 ms per sector, the card prefetches 8 ahead, and an SD block
read is ~0.1-0.5 ms. Megamiga's `ide_engine.vhd` (multi-block CMD18/CMD25
with an extent map) would only matter for a turbo or a 286.
- write-through as for the floppies: the card's write ends when the block
  is on the SD card;
- write protection per drive from the menu (the backend refuses, the card
  reports DF ERR ABRT);
- the drive LED: `hd_active` (red/orange next to the floppy's yellow, as in
  Megamiga), or the M2M drive LED with a second colour.

**Menu** (config.vhd; the QNICE firmware has ~960 words free, so the mount
code goes into a code bank, Megamiga exception 16):

```
 Hard disk: on/off            hdc_enable (the card in a slot)
 C:%s                         master image
 D:%s                         slave image
 C: write protected / D: ...
```

`hdc_variant` stays 0 (the shipped XUB configuration) unless a user loads
their own `/pc10/xub.rom` for rev 1/2; a hidden or advanced menu item can
set it. The image paths should survive a power cycle (the settings file's
text lines, M2M exception 17, as Megamiga's profiles do).

**Timing**: the card's paths are short (registered strobe decode like the
FDC's, a 28-bit compare and adder per sector issue, the iterative
multiply/divide); the option ROM data go through one register (`isa_din`)
like the FDC's. No new clock domain: the sector port crosses into the QNICE
domain inside the backend, as the floppy's does.

## 9. Open points

- Not in a Vivado build yet (Verilator only; the shell ties the card off).
- DMA (XT-CF DMA, type 10) and JR-IDE (memory-mapped) are not implemented.
- INTRQ is not wired by default; with `IRQ = 5` it works per ATA, but no
  test with an interrupt-driven driver (XUB's XT builds poll).
- No ATAPI and no LBA48 (LBA28 reaches 128 GB; INT 13h's CHS functions
  8 GB, XUB's EBIOS more), no READ/WRITE BUFFER, no SMART/security/power
  management.
- The backend latency in `tb/sys` is a constant (20 us per sector); the SD
  card's real latency (0.1-1 ms per block) only lengthens the first sector
  of a command, the unit bench covers slow and random backends.
- The geometry rule (MBR, else 16 x 63) has to be implemented in the shell
  firmware; images made elsewhere with another geometry and no partition
  table need a way to say theirs (a menu item or a sidecar file).
- The timing constants are plausible, not measured on a real drive or CF
  card; the bus timing of the card itself is real (no wait states).
- The A2088 bridgeboard (Megamiga) has no XTIDE; there the Amiga's hard disk
  would be reached through Janus (doc/plan.md).
