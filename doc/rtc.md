# The PC10-III's real-time clock: an OKI MSM6242B at 2C0h (`rtl/system/msm6242.sv`)

Status 2026-10-26, branch `rtc`: the chip on the board (sections 1-3), the
model (section 4), how the Commodore BIOS 4.41 and SETCLOCK use it (sections
5-6), the MEGA65 side: the seed from the battery RTC and the write-back into
it (section 7), the tests (section 8), open questions (section 9). Not on
hardware yet.

On hardware the user saw `RTC timeout` from MS-DOS 3.21's AUTOEXEC
(`setclock -r`): nothing answered at 2C0h, the bus read FFh, and the BUSY bit
(bit 1 of 2CDh) never cleared.

Facts are marked with their source; **[A]** marks an assumption, **[Q]** an
open question (a decision for the user: the most authentic option is built).

Sources:
- **DS**: OKI *MSM6242B Direct Bus Connected CMOS Real Time Clock/Calendar*,
  FEDL6242B-02 (23 pages; `~/pcxt-work/rtc/ds/fedl6242b.pdf`, not in the
  repository). Register table p. 10, functional description pp. 11-14.
- **EP**: Seiko Epson *RTC-72421/72423 Application Manual* ETM17E-02
  (`~/pcxt-work/rtc/ds/rtc72421_etm.pdf`): the same register set ("pins and
  functions compatible with the MSM6242 series"), with the details OKI leaves
  open (BUSY's duration, the 30 s adjust, REST).
- **SM**: the PC10/20-III technical manual (`~/pcxt-work/manual/p*.png`):
  chapter 5 (230h), schematic sheet 9-4 (p82: U401).
- **BIOS**: the Commodore BIOS 4.41 (318085-08), disassembled for reading only
  (`~/pcxt-work/rtc/bios_intel.dis`; offsets are F000:xxxx).
- **SC3**: `SETCLOCK.EXE` "Commodore RealTimeClock Utility V3.0" (1709 bytes,
  22.03.1988) from the Colt MS-DOS 3.21 disk 1 (`colt-dos321-1.img`), and
  **SC2**: V2.1 (12195 bytes, C, 1987) from `PC1020-3.ZIP`; disassemblies in
  `~/pcxt-work/rtc/`, not in the repository.

## 1. The chip on the board (SM sheet 9-4)

U401 "6242" in its 18-pin DIP:
- D3-D0 (pins 11-14) on the board's internal data bus bits 3-0; A3-A0 (pins
  7-4) on BADDR 3-0; RD' (8) = NIOR', WR' (10) = NIOW', CS0' (2) =
  RTCLOCKCS', a select from the Commodore gate array 5720 (U602), which also
  decodes the FDC, COM, LPT and hard disk selects and qualifies them with AEN
  (doc/xta.md section 2).
- CS1 (15) and ALE (3) on the battery-backed supply node (VCC through CR401,
  the battery BT601 through R402 and CR402; C403 4.7 uF, C404 0.1 uF): the
  address latch is transparent, and CS1 drops only when VCC fails (the
  chip's power-fail input).
- STD.P (1) goes only to a 10K pull-up (R411): **no interrupt** reaches the
  PC. (R411's other end reads like the CS1/VDD net; either way nothing else
  is connected.)
- XT/XT' (16/17): XTAL2 "32.XXKHZ" with C401 22 pF and the trimmer C402
  22-47 pF.

The enable (SM 5-5, `rtl/system/cbm_cfg230.sv`, doc/pvc4.md section 7): 230h
bit 6 ("rtc") turns the onboard RTC at 02C0h on. The BIOS sets it at every
POST (section 5).

## 2. The register set (DS p. 10)

| Address | Name | D3 | D2 | D1 | D0 | Range |
|---|---|---|---|---|---|---|
| 2C0h | S1 | s8 | s4 | s2 | s1 | 0-9 |
| 2C1h | S10 | * | s40 | s20 | s10 | 0-5 |
| 2C2h | MI1 | mi8 | mi4 | mi2 | mi1 | 0-9 |
| 2C3h | MI10 | * | mi40 | mi20 | mi10 | 0-5 |
| 2C4h | H1 | h8 | h4 | h2 | h1 | 0-9 |
| 2C5h | H10 | * | PM/AM | h20 | h10 | 0-2 or 0-1 |
| 2C6h | D1 | d8 | d4 | d2 | d1 | 0-9 |
| 2C7h | D10 | * | * | d20 | d10 | 0-3 |
| 2C8h | MO1 | mo8 | mo4 | mo2 | mo1 | 0-9 |
| 2C9h | MO10 | * | * | * | mo10 | 0-1 |
| 2CAh | Y1 | y8 | y4 | y2 | y1 | 0-9 |
| 2CBh | Y10 | y80 | y40 | y20 | y10 | 0-9 |
| 2CCh | W | * | w4 | w2 | w1 | 0-6 |
| 2CDh | CD | 30s ADJ | IRQ FLAG | BUSY | HOLD | |
| 2CEh | CE | t1 | t0 | ITRPT/STND | MASK | |
| 2CFh | CF | TEST | 24/12 | STOP | REST | |

`*` bits do not exist: ignored on writes, 0 on reads (DS note 1). BUSY is read
only; IRQ FLAG can only be written to 0 (DS note 3). The chip has **no RAM**:
nothing but the time and the three control registers.

## 3. The bus

- Decoded: 2C0h-2CFh, i.e. A9-A4 = 2Ch with AEN low, only while 230h bit 6
  is set **[A]** (the 5720's decode is not legible; the BIOS and SETCLOCK use
  exactly 2C0h-2CFh; the 10-bit decode makes 6C0h etc. aliases, as for every
  onboard device of the model). With bit 6 clear the chip is not selected:
  reads float (FFh), writes are ignored.
- Read data: D3-D0 from the chip, **D7-D4 = 1111** **[A]**: the chip drives
  only four lines; the other four float on the board's internal data bus
  (LS TTL inputs float high; no pull-up or pull-down is drawn). The BIOS and
  both SETCLOCKs mask every read with 0Fh, the POST compares whole bytes of
  S1 (equal either way).
- Writes act at the end of the IOW strobe (WR' rising edge); reads are
  combinational, no wait states (the chip's access time is far below an ISA
  cycle).

## 4. The model (`rtl/system/msm6242.sv`)

- **Oscillator:** 32.768 kHz from the PC's 28.63636 MHz clock by an exact
  fractional accumulator (clk = 315/11 MHz: + 11 x 32768 per clk, modulo
  315,000,000): exactly 32768 ticks per second of the PC's clock. A 15-bit
  divider makes the 1 Hz carry.
- **Counting** (DS 11): BCD digits as in section 2; seconds and minutes wrap
  at 59, hours at 23 (24 h) or 12, 1 .. 11 with PM/AM flipping at 11 -> 12
  (12 h; the day's carry at 11:59:59 PM -> 12 AM; DS's own example counts
  "PM12:00 -> PM1:00"); the weekday W counts 0-6 with the day; a day carry
  with the day >= the month's length gives day 1 of the next month (DS e: "Feb
  29 1985 ... changed to March 1 at the carry"), so an impossible date is
  corrected at the next midnight; months wrap 12 -> 1 with the year's carry;
  years 99 -> 00. Leap years: binary year mod 4 = 0 (DS: "Christian Era ...
  identifies a leap year automatically"; for the PC's 1980 base the years
  1980-2079 are right, 2000 included).
- Invalid digits (written by software): the counters compare for the digit
  values above, so e.g. seconds 75 count 76 .. 79 -> 00 without a minute
  carry (the 3-bit S10 wraps) **[A]** (DS c: "erroneous clock data").
- **HOLD and BUSY** (DS 12, EP 11): HOLD = 1 stops the 1 Hz carry into S1;
  one carry that arrives meanwhile is kept and applied when HOLD returns to 0
  (more are lost: EP "held just once"). BUSY is set when an increment
  executes and stays set for the increment's window: **6 ticks = 183 us**
  **[A]** (EP: "190 us max"). It is cleared only by a sample at 16.384 kHz
  with HOLD = 0 once the window is over (DS fig. 10 note: "the CLEAR of BUSY
  bit is performed when HOLD bit = 0 ... by sampling HOLD bit = 0 at
  approximate 16 kHz"); while HOLD stays 1 it keeps its value (EP: "the
  status of the BUSY bit remains as set while the HOLD bit is at 1 ... write
  0 to the HOLD bit each time"). BUSY with HOLD = 0 reads that sampled value
  **[A]** (EP: always 1; nobody reads it so).
- **30 s ADJ** (DS 12, EP 13): bit 3 of CD = 1 starts it; **4 ticks = 122
  us** **[A]** (DS: 125 us; EP: 76.3 us max) later the seconds go to 00, with
  a minute carry (rippling up to the year) from 30 s on, the divider is
  cleared from the 1/256 s stage up **[A]** (EP), and the bit reads 0 again.
- **CF** (DS 14): REST = 1 holds the divider's stages from 1/256 s up at 0
  **[A]** (EP: "clears the sub-second bits ... down to the 1/256-seconds
  counter"); STOP = 1 stops the divider from the 8192 Hz stage (DS: "only
  inhibits carries into the 8192 Hz divider stage"); the 24/12 bit takes a
  write only while REST is already 1 (DS: "REST bit must = 1 to write to the
  24/12 hour bit"); TEST = 1 clocks the seconds at 8192 Hz **[A]** (DS: 5.4163
  kHz from an internal stage; STOP and REST then do not stop counting).
  H10's PM/AM bit reads 0 in 24 h mode.
- **STD.P / IRQ FLAG** (DS 12-14): events every 1/64 s (the divider's 1/128
  s stage), second, minute or hour (t1 t0), at the moment the digit carries;
  MASK = 1 suppresses them; interrupt mode (ITRPT/STND = 1) keeps the flag
  until a 0 is written to it (a new event meanwhile is ignored), standard
  pulse mode clears it after 7.8125 ms (256 ticks; 1/64 s: a 50 % square
  wave); writing 1 to the flag does nothing. No pin of the model: STD.P is
  not wired (section 1). The flag's writes during CE changes (DS supplement)
  are not modelled.
- **Battery:** no reset input: the chip keeps time across PC resets ("Reset
  the PC", the reset button, a chipset/display change); its power-up state is
  the FPGA's initial values, 01.01.1980 00:00:00, 24 h mode, running **[A]**
  (a real chip with a new battery holds undefined data), replaced by the
  MEGA65's time as soon as M2M has read the battery RTC (section 7).

## 5. The Commodore BIOS 4.41

**POST** (F000:CE64): POST code E4, then 230h = (230h | 40h) & 7Fh with bit 7
from 40:70 (the onboard video's enable): **the RTC enable is always set**.
Then (CE80) it reads 2C0h, waits 10 x 65536 LOOPs (2.33 s at 4.77 MHz),
reads 2C0h again:
- different: the clock ticks. It prints `Onboard   RTC    at 02C0h`, reads the
  time with INT 1Ah AH=02, converts it from BCD (CF40) and sets the tick
  count 40:6C/6E (hours x 65536 + minutes x 1092 + seconds x 18). Hours above
  23 or minutes/seconds above 59: `Real Time Clock error, run SETUP`.
- equal: it writes 04h to 2CDh (HOLD off), 07h then 04h to 2CFh (REST and
  STOP with 24 h mode, then running in 24 h mode) and tries once more; a
  second failure skips the RTC silently.

So a booting PC10-III spends 2.33 s (at 4.77 MHz) in this probe.

**INT 1Ah** (table at F000:DDA4; AT-style functions): AH=00/01 the tick
count; **AH=02** read time (CH hours, CL minutes, DH seconds, BCD; DDEB),
**AH=03** set time (DE35), **AH=04** read date (CX = century and year, DH
month, DL day; DDF8), **AH=05** set date (DE44). The register access
(DEDA): `mov dx,2CDh`, then up to 50 times `out 07h` (HOLD = 1 with the IRQ
FLAG written 1, as DS asks) and `in`: BUSY = 0 -> go; after 50 it writes 04h
(HOLD off) and tries 50 more; then it fails with CF (INT 1Ah's IRET drops
that flag). Read: three register pairs (DE84, low nibble each) from 2C0h or
2C6h, then 04h to 2CDh. Write (DEB5): three pairs, then 04h. AH=03 does not
touch DL (daylight saving); AH=05 ignores CH: the year registers hold
**years since 1980** in BCD: read: year = Y + 1980, CH = 19h below 2000,
else 20h (DE13: `add ax,7BCh`); write: a BCD year below 80h is 20xx, else
19xx, minus 1980 (DE59). The BIOS never writes W, CE or TEST, and uses 24 h
mode only.

**SETUP** (F000:DBFC, "COMMODORE PC SETUP UTILITY": date, time, default
speed, onboard COM, LPT, mouse and its IRQ, FDC): date and time go to the RTC
through INT 1Ah. The configuration word is **not** in the RTC: the MSM6242B
has no RAM. On a hard disk system ("Press <End> to exit and save config to
disk") SETUP reads the master boot record (drive 80h, C0 H0 S1), checks the
signature `PC10` at offset 1B0h and writes the word from 40:A1h to offset
1B4h (F000:D7CD-D89E); the POST reads it from there into 40:A1h. A floppy
system activates the configuration for the session only ("Press <F10>").
An earlier note ("SETUP in RTC RAM") was wrong.
**Entering SETUP: Ctrl-Alt-Esc**, at any time the BIOS's INT 9 runs (POST
after the keyboard is up, DOS, programs that keep INT 9): INT 9 at F000:EAB9
tests Alt (40:17h bit 3) and Ctrl (bit 2), and with both down the make code
01h (Esc) acknowledges the keyboard and the 8259 (EC2A) and jumps to D762
(SS:SP = 5000:029D, the video mode from the equipment word, the
configuration from 40:A1h/40:A3h, the MBR, then the screen at DBFC). Nothing
else reaches D762: there is no POST prompt and no documented DEBUG entry
(`G=F000:D762` from DEBUG would do the same). With Alt and Ctrl, the make
codes of S, T and D set the speed instead (doc/turbo.md section 5). The
configuration word 40:A1h bits 1-0 are SETUP's default speed (0 4.77, 1 7.16,
2 9.54 MHz). tb/sys (2026-10-26, 640 KB, hello360 booted, Ctrl-Alt-Esc at
36 s): the screen "C O M M O D O R E   P C   S E T U P   U T I L I T Y" with
Date, Time, "Default system speed 4.77 MHz", On Board COM 3F8H, LPT 3BCH,
Mouse ENABLE, and the hard disk / floppy-only exit keys. SETUP's stack is at
segment 5000h (320 KB): on a 256 KB machine it crashes (tb/sys, 256 KB).

## 6. SETCLOCK

**V3.0** (SC3, the Colt DOS disk's; AUTOEXEC.BAT: `setclock -r`):
- wait (0031h): up to 5 times: 07h to 2CDh, then poll 2CDh until BUSY = 0
  for (k + 2) x 13 reads (k = 40:12h >> 6, 0-3: a speed setting; 26-65 reads,
  about 190-470 us at 4.77 MHz), else 04h to 2CDh and again; after 5 tries
  `RTC timeout` (the message on hardware: FFh reads have BUSY set).
- `-r`: reads S1..W (13 registers, low nibbles), 04h to 2CDh; DOS date =
  (Y10 x 10 + Y1 + 1980, MO10 & 1, D10 & 3), time = (H10 & 3, MI10 & 7, S10 &
  7) with INT 21h AH=2Bh/2Dh (`Date not set`, `Time not set` on refusal). It
  assumes 24 h mode (H10 & 3 drops PM).
- `-w`: INT 21h AH=2Ah/2Ch, years 1980-2079 (`Date out of range`), wait,
  07h to 2CFh (REST, STOP, 24 h), 00h to 2CEh, the 13 registers (W = DOS's
  weekday, 0 = Sunday), 04h to 2CFh, 04h to 2CDh.
- **A bug in V3.0:** `-w` stores DL (hundredths) as the seconds, not DH: the
  clock gets 0-99 "seconds"; 60-79 make a later `-r` fail with `Time not
  set` (S10 = 6 or 7), 80-99 become 0-19 (S10 has three bits). The model
  counts such values as the chip would (section 4); DOS's own time is right
  until the next boot.

**V2.1** (SC2, from PC1020-3.ZIP; a C program): the same `-r`/`-w` options;
not disassembled further.

## 7. The MEGA65 battery RTC

M2M's RTC (M2M/vhdl/i2c/rtc_controller.vhd, QNICE device 0x0006) keeps an
internal timer that runs on the QNICE clock and is loaded from the board's
I2C RTC after power-up (R6: an RV-3032-C7); the core gets it as
`main_rtc_i(64:0)`: bits 7-0 seconds, 15-8 minutes, 23-16 hours (24 h),
31-24 day, 39-32 month, 47-40 **years since 2000** (BCD), 55-48 weekday
(**0 = Monday**, rtc_controller's header), 63-56 40h, and bit 64, a toggle
that flips when a value has been read from the I2C RTC (after power-up, and
after QNICE's "copy RTC to internal" command, which this core's firmware
never gives).

**Seed** (msm6242.sv): when the toggle flips, the chip takes the value
- once all 64 bits have been stable for 8 clk (the vector crosses from the
  QNICE clock bit by bit),
- if every field is valid BCD in range (else it is ignored: an RTC without a
  battery reads zeros; M2M itself retries a read with day and month 0),
- not while HOLD is set (it waits: a CPU access in progress),
- and not after the PC has set the clock since power-up (the write-back below:
  the PC owns the time then, and the battery RTC already holds it) **[A]**.
Years: PC10 = (M2M + 20) mod 100: 2000-2079 are 20-99, **2080-2099 become
1980-1999** (the chip's own wrap); the weekday: W = M2M + 1 mod 7 (Sunday =
0, DOS's and SETCLOCK's numbering) **[A]**; hours in the chip's current mode
(12 h: 0 -> 12 AM, 12 -> 12 PM); the divider restarts (the second begins).

**Write-back:** the chip pulses `clk_set` for one clk when the PC has set the
clock (any write to S1..W, or a 30 s adjust) and HOLD, STOP and ADJ are all 0
again, i.e. at the end of the BIOS's INT 1Ah AH=03/05 (04h to 2CDh) and of
SETCLOCK -w (04h to 2CFh and 2CDh), or right after a write while the clock
runs. `now` is the clock in M2M's register order: hundredths (from the
divider), seconds, minutes, hours in 24 h form (converted from 12 h mode),
day, month, year since 2000 = (PC10 + 80) mod 100 (1985 becomes 2085, which
seeds back as 1985: a round trip), weekday 0 = Monday.
- `CORE/vhdl/pc_rtc.vhd` (QNICE device `C_DEV_PC_RTC` = 0x0106): a set takes
  `now` and flips a request toggle; both cross to the QNICE clock through
  `cdc_stable` (the time is held while the request is pending); window 0
  offset 0 reads bit 0 = pending, a write of 1 acknowledges; offsets 1-8 hold
  the eight bytes. A set while one is pending sends a second request, with
  the then current time, after the acknowledge.
- The firmware (`CORE/m2m-rom/pc_rtc.asm`, `PC_RTC_WB`, called first in
  `HANDLE_CORE_IO`): pending? Then rtc_controller's protocol: 00h to its
  command register (stops the internal timer; taken only while the I2C bus is
  idle) and read it back: not 0 -> try at the next call; else the eight bytes
  into its registers 0x00-0x07, 0Ch to the command register (copy to the RTC,
  then run), acknowledge. It does not wait for the I2C transfer (about 1 ms).
  Registers and the RAMROM selection are preserved; no RAM variables; 61
  words of ROM (the firmware: 32227 of 32768 words; HEAP 0xA51C unchanged).
- The core's main_rtc_i follows the written time without a toggle, so the
  chip does not reload its own time.

The MEGA65's RTC then holds the PC's time; the next power-up seeds it back.

**MS-DOS 3.21** (the Colt disk's IO.SYS, 1987-12-03): at boot it calls INT 1Ah
AH=02 with CX = DX = 0, twice 16K LOOPs apart; if a value comes back it takes
the date from AH=04 (days since 1980; IO.SYS 2BE8h, 2618h); the time comes
from the tick count the BIOS POST set from the RTC. IO.SYS never calls AH=03
or AH=05: **DOS's TIME and DATE do not reach the RTC** (as on the real
machine); `setclock -w` and the BIOS SETUP do, and only those persist.

## 8. Verification

**tb/rtc** (`make run`; Verilator, `rtc_run.cpp` with the reference model
`rtc_model.h` written from sections 3-4 and 7): the chip on card-bus I/O
cycles (IOR 21 clk, IOW 15 clk, the next-clk signals); every clk the model and
the chip are compared (the read data and select, `clk_set`, `now`); the tests
add checks against independent expectations: the calendar against the C
library's `gmtime`, the BIOS's INT 1Ah routines and SETCLOCK V3.0's sequences
(rewritten in C with their 8088 cycle gaps), the data sheet's HOLD/BUSY,
adjust, STOP/REST/TEST and IRQ behaviour. Two builds: `obj/` with the exact
oscillator, `obj_fast/` with 32.768 kHz = clk / 8 for the long runs.

| Test | What | Result |
|---|---|---|
| `bios` | power-up state, the seed, the POST probe, INT 1Ah AH=02/04 against the seed + elapsed time, AH=03/05 across midnight 31.12.1999 with one write-back each (1999 = M2M 2099), SETCLOCK -w/-r (1984: M2M 84, Sunday = 6), 230h bit 6 clear, AEN, aliases | PASS, 40 checks |
| `calendar` (fast) | 322 cases, 24 h and 12 h: every month's end of 1980, 1981, 1984, 1985, 1990, 1992, 2000, 2010, 2012, 2023, 2024, 2026, 28 February, 1999 -> 2000, 2079 -> 1980, 12 h by the hour, `now` in 24 h form; against gmtime | PASS, 370 checks |
| `calendar` (exact) | the first 6 cases, 12 h at 3 hours | PASS |
| `hold` | a held carry (+1 s at the release, only one in 2.5 s), BUSY 20 us / 300 us after a carry, kept while HOLD stays set, cleared by HOLD = 0; the BIOS and SETCLOCK at 11 phases around the carry | PASS; timeouts BIOS 5, SETCLOCK 3 (all inside BUSY's window) |
| `adjust` | 29 s, 30 s, 23:59:45 31.12 -> 1.1.; the bit's 125 us; a write-back | PASS |
| `stoprest` | STOP, REST (a whole second after the release), 24/12 only with REST, PM read, TEST (82 s in 10 ms) | PASS |
| `irq` | 1/64 s pulse (50 %), 1 s pulse 7.8 ms, interrupt mode kept until 0, MASK, minute, hour | PASS |
| `seed` | HOLD defers, invalid ignored, 12 h (midnight, noon, 11 PM), 2085 -> 1985, the data stable for 8 clk, ignored after the PC set the clock; write-backs (running, STOP, none for control registers), hundredths | PASS |
| `torture1-4` (fast) | 40 s each of random register traffic, seeds (some invalid), 230h on/off | PASS |

Altogether 2,836,999,846 clk compared with the model, 6.2 M CPU reads, 492
explicit checks. `mut.py` (54 mutants: counting, 12 h, leap years, month
lengths, weekday, HOLD/BUSY, adjust, STOP/REST/TEST, 24/12, the bus, the IRQ
flag, the seed's rules and conversions, the write-back's conditions and
conversions): **54 of 54 killed**. The first run left two: the calendar had no
year with odd tens that is a leap year (1992, 2012 added) and the strobe
mutant was equivalent (replaced by a write during the whole strobe).

**tb/shell** (`run.sh`): `tb_rtc.vhd`: pc_rtc.vhd with M2M's rtc_controller
(its I2C side a stub) and the firmware's sequence as a VHDL procedure;
`run_rtcwb.sh`: `PC_RTC_WB` itself on the QNICE emulator, its device
registers moved into RAM. `mut_rtc.py`: pc_rtc.vhd 8 of 8, PC_RTC_WB 7 of 7 killed.

**tb/sys** (the Commodore BIOS 4.41 and MS-DOS 3.21): fedora, `~/pcxt-work/rtc/sys{1,2,3}.log`, `make FE=1
PVC4=1 [RAM_KB=256]`, `sys_run -b cbm-pc10c-bios-v4.41 -d 5D -a
colt-dos321-1.img -R "2026-10-26 12:34:56" -rl -k ...`:
- **seeded, 640 KB** (85 s, 7,881 s wall): POST code E4 sets 230h bit 6
  (8.09 s, 230h = 59h), the probe ticks, `Onboard   RTC    at 02C0h`, INT 1Ah
  AH=02 at 10.60 s (HOLD 07h, BUSY 0, read, 04h); MS-DOS 3.21's IO.SYS reads
  AH=02 twice and AH=04 at 35.40 s, AUTOEXEC's `setclock -r` at 44.12 s: no
  `RTC timeout`; DATE at 70 s: `Current date is Mon 10-26-2026`, TIME at 73
  s: `Current time is 12:36:09.17` (seed 12:34:56 + 73 s).
- **seeded, 256 KB** (95 s): DATE/TIME as above at 55/58 s (`12:35:53.62`),
  then `time 23:59:50`, `date 12-31-99`, `setclock -w` (70.52 s: 07h to 2CDh,
  CF 07h, CE 00h, S1..W = 9 2 9 5 3 2 1 3 2 1 9 1 5, CF 04h, CD 04h): **one
  write-back**, `2099-12-31 23:59:29.00 weekday 4` (1999 = M2M 2099, Friday;
  the 29 "seconds" are DOS's hundredths: SETCLOCK V3.0's bug, section 6);
  `setclock -r` at 78.7 s, DATE `Fri 12-31-1999`, TIME `23:59:44.61` at 86 s
  (23:59:29 + 15.9 s).
- **not seeded, 256 KB** (70 s): the chip's power-up time: `Onboard RTC`,
  DATE `Tue  1-01-1980`, TIME `0:01:00.63` at 61 s.

## 9. Open questions

- **[Q]** The seed is ignored once the PC has set the clock until the next
  power-up (the MEGA65's RTC holds the PC's time then). Alternative: always
  take a new value (only the power-up read happens today).
- **[Q]** 2080-2099 on the MEGA65 are 1980-1999 on the PC (and back): the
  PC's chip cannot count beyond 2079.
- **[Q]** The weekday: from M2M's weekday (Monday = 0) to SETCLOCK's numbering
  (Sunday = 0). If the MEGA65's RTC holds a wrong weekday, so does W (nothing
  in the BIOS or DOS reads W).
- **[A]** The 5720's decode range of RTCLOCKCS' (2C0h-2CFh assumed), the
  floating high nibble (1111), the BUSY window (183 us), the adjust's
  duration (122 us), TEST's rate, REST/adjust clearing from 1/256 s.
- The BIOS's INT 1Ah access fails (CF, lost by its IRET) when it sets HOLD
  inside BUSY's window: its 50 retries keep HOLD at 1, and the 4-us HOLD = 0
  gap before the second round rarely meets a 16 kHz sample (DS's note
  recommends a longer idle time). On the real chip as in the model this hits
  about 0.02 % of the calls (tb/rtc's phase sweep shows it).
