# Turbo: the FE2010A's 7.16 and 9.54 MHz

Status: **done in simulation** (2026-10-26, branch `turbo`; doc/clock-plan.md
step 5). Not verified on hardware. `[A]` marks an assumption, `[Q]` an open
question.

The PC10-III runs its 8088 at 4.77, 7.16 or 9.54 MHz. The FE2010A makes all
three from the board's 28.63636 MHz oscillator (the core's clock), selected by
its configuration register at port 63h. The core does what the chip does:
63h bits 7-6 pick the divider (6, 4 or 3), and the chipset's wait-state
generator adds the turbo wait states of its table. The Commodore BIOS 4.41
switches with Ctrl-Alt-S/T/D, and SPEED.EXE works as on the real machine. The
"IBM XT (8255)" chipset choice has no port 63h register, so it stays at
4.77 MHz like a 5160.

## 1. Sources

- **Sergey Kiselev, micro_8088** `Documentation/Faraday-XT_Controller-FE2010A.md`
  (github.com/skiselev/micro_8088). These are reverse-engineered notes, measured
  on his boards; no Faraday FE2010A data sheet has been found. The table in
  section 3 is the version of 2023-02-01 (commit 409101c, "Update wait states
  configuration"). The 2018 version had 6 I/O wait states in every 9.54 MHz row,
  and GLaBIOS and dosdays.co.uk still copy that.
  - Its git history (commit 24afb92, 2017-12-01): "setting bit 7 switches CPU
    clock frequency to 9.54 MHz, regardless of bit 6" (with the 28.63636 MHz
    crystal), and "CPU clock duty cycle is 50% (excluding 4.77 MHz setting with
    28.63636 MHz crystal, where duty cycle is 33%)".
- **The FE2010 data sheet** (same repository, `Faraday-XT_Controller-FE2010.pdf`,
  pp. 9 and 18), the FE2010A's predecessor. It says: "1 wait state on all CPU
  I/O and DMA operations"; the 8237 equivalent, with channel 0 for refresh;
  the 8284A equivalent "also generates the clock for the timer"; and the lock
  bit, which only a reset clears.
- **Kiselev's 8088_bios** (`src/bios.asm`, `cpu.inc`, `messages.inc`) and
  **GLaBIOS** (`GLABIOS.ASM`) both write 63h. Their constants: 40h = 7.15 MHz,
  60h = 7.15 MHz "fast", 80h = 9.54 MHz, C0h = 9.54 MHz "fast". The messages
  give I/O wait states and "upper memory" wait states.
- **86Box** (`kbc_xt.c`, Tulip TC8 only) stores 63h but has no turbo. Once the
  lock is set it locks the whole register, unlike Kiselev's notes. **MAME**
  `compc.cpp` marks the pc10iii not working and has no turbo. PCem and MartyPC
  have no FE2010A.
- **The PC10-III / PC20-III user's manual** (archive.org,
  "commodorepc10iiipc20iiiusersmanualenglish"): "8088-1 ... three speeds -
  4.77, 7.16 and 9.54 MHz", "pre set to the standard 4.77 MHz speed",
  `SPEED -s/-t/-d`, and "CTRL-ALT-S for standard speed (4.77 MHz) / CTRL-ALT-T
  for turbo speed (7.16 MHz) / CTRL-ALT-D for double speed (9.54 MHz)".
  zimmers.net `PC-8088-Information.txt` adds: "The computer always starts at
  4.77MHz when first powered on". The service manual (archive.org PN-314860-01)
  shows a 28.636 MHz oscillator on the PC10-III schematic (part 325566-12).
- **TopBench** results for a PC10-III (gist kubilus1/b8d58bb3...): the score
  goes 4 / 6 / 8. The opcode time is 1773 / 1175 / 882 us (x 1.51, x 2.01),
  memory EA 1966 / 1302 / 970 us (x 1.51, x 2.03), CGA video memory 2298 /
  1744 us (x 1.32 at 7.16 MHz).
- **Our own disassembly** of the Commodore BIOS 4.41 (318085-08) and of both
  SPEED.EXE versions (`~/pcxt-work/pvc4/bios.dis`, `~/pcxt-work/turbo/`; not in
  the repository).

## 2. Port 63h (FE2010A configuration register, write only)

| Bit | Function |
|---|---|
| 0 | parity checker off |
| 1 | 8087 NMI |
| 2, 4 | on-board RAM size (bit 4/bit 2: 0/1 256K, 1/0 512K, 0/0 640K) |
| 3 | lock: bits 0-4 and the switch register (62h) until reset |
| 5 | fast: no memory bus wait states |
| 6 | 7.16 MHz (with bit 7: fewer wait states) |
| 7 | 9.54 MHz (overrides bit 6) |

- **After the lock, bits 5-7 stay writable** (Kiselev: "bits 0 - 4 of this
  register and the switch register are locked"). GLaBIOS locks the register and
  then changes speed through it, and so does the Commodore BIOS: it sets the lock
  at the end of its memory configuration (`out 63h` with `| 48h`, F000:C3B2)
  and its hot keys write 00h/40h/80h later. 86Box's whole-register lock would
  make the hot keys dead.
- **Reset: 4.77 MHz** (the register clears; the manual, zimmers, 2088MOD.TXT).
- **Both 6 and 7 set: 9.54 MHz** (Kiselev, measured).
- Reads: the register is write only. The core returns its value, as before
  (xt_board.sv) [A: what the real chip returns is unknown].

## 3. Wait states (xt_wait.sv)

Kiselev's table (2023-02-01), wait states per CPU cycle:

| 7 6 5 | CPU clock | I/O | on-board RAM | memory bus |
|---|---|---|---|---|
| 0 0 x | 4.77 MHz | 1 | 0 | 0 |
| 0 1 0 | 7.16 MHz | 4 | 0 | 2 |
| 0 1 1 | 7.16 MHz | 4 | 0 | 0 |
| 1 0 0 | 9.54 MHz | 6 | 0 | 4 |
| 1 1 0 | 9.54 MHz | 4 | 0 | 2 |
| 1 0 1 | 9.54 MHz | 6 | 0 | 0 |
| 1 1 1 | 9.54 MHz | 4 | 0 | 0 |

The Commodore BIOS only ever writes 00h, 40h and 80h with the lock set, so
bit 5 is always 0 on a PC10-III. That gives 4.77: I/O 1; 7.16: I/O 4, memory
bus 2; 9.54: I/O 6, memory bus 4. On-board RAM has no wait states at any
speed, which matches TopBench's 1.51 / 2.01 x opcode times.

- **Which cycles:** I/O = IN/OUT (status IOR/IOW). Memory bus = every memory
  cycle (code fetch, read, write) whose address is not in the on-board RAM,
  which is RAM below 63h's RAM size. That covers the video memory (the PVC4 at
  B0000-BFFFF), option ROMs, and the BIOS ROM [A: Kiselev's "Memory Bus WS",
  which his BIOS calls "upper memory"; whether the FE2010A's own ROM chip
  select gets them is not known]. INTA and HALT get none [A], as on the 5160.
- **How they count:** n wait states are n states after T2 that the board
  keeps from being the last (T1 T2 T3 Tw...Tw T4 has n + the card's Tw). A
  state that the DMA wait held does not count (the rule MartyPC has for the I/O
  wait state, already in the core since 2026-10-22). IOCHRDY from a card (the
  PVC4's video memory arbitration) is sampled in every state as before, so the
  board's and the card's waits overlap: the cycle ends when both are over.
- **DMA:** the 8237 function runs on the CPU clock at every speed (KF8237 on
  `cpu_step`/`cpu_fall`). The FE2010 does DMA with RQ/GT on the CPU's clock,
  and the ISA BCLK is the CPU clock [A: no hard source; Kiselev and nztdm on
  vcfed, Eddy Olk's floppy errors at turbo on the A2088]. The DMA transfers keep
  their own wait state (the 8237's SW state), with no turbo wait states added
  [Q].
- **DMA only between bus cycles** (FE2010A mode, xt_board.sv `hold_ok`). The
  core has the 5160's HOLD logic, as MartyPC does. It samples the status pins,
  which biu88 makes passive from T3 on, so a transfer can take the bus in a
  T3/Tw that is not the last. AEN then cuts the CPU's command, and the command
  comes back as a second strobe of the same cycle. With one I/O wait state
  that never reaches an I/O command, because the earliest AEN is at T4.
  - With the turbo's 4-6 I/O wait states it does. A second IOW to the FDC's
    data register is a second command byte: the first build's tb/sys runs
    showed "Drive A: Bad" at 9.54 MHz, and at 7.16 MHz a DOS program loaded
    as garbage. `+cutlog` counted the split strobes.
  - The FE2010 gives its DMA the bus through the 8088's RQ/GT, and the 8088
    grants that only in T4 or Ti (8086 data sheet), never in a running cycle.
    In the FE2010A mode the hold flip-flop therefore takes a T3/Tw only when it
    is the last one, which is also where the real 8088's status pins go
    passive.
  - The 5160 mode keeps MartyPC's rule (the gates). A DMA cycle that starts in
    the CPU's next T1 still finds the CPU's read strobe just begun, in both
    modes, as before.
- **Refresh:** DRQ0 from the 8253's channel 1, which runs at 1.19318 MHz
  whatever the CPU speed: refresh stays every 15 us [A: the FE2010A notes say
  "the timer inputs are internally connected to a 1.19 MHz clock"].
- **Not modelled:** the PT8010AF note that the FE2010A ignores IOCHRDY at
  9.54 MHz with bit 5 [Q]. The Commodore BIOS never sets bit 5.

## 4. Clocking (pc_clocks.sv)

The modulo-24 counter (OSC/12) stays as it was and gives OSC (`ce_14m`) and
PCLK, so the 8253, the cards' dot clocks, the FDC/XTIDE microsecond timers
and the keyboard keep their real rates at every speed. The CPU clock has its
own counter with a period of `per(spd)`:

| speed | 63h | divider | CLK high | `cpu_fall` | `rdy_ce`, `cpu_prestep` |
|---|---|---|---|---|---|
| 0 | 7-6 = 00 | /6 = 4.7727 MHz | 2 clk (1/3, the 8284's) | step + 2 | step + 5 |
| 1 | 01 | /4 = 7.1591 MHz | 2 clk (50%, Kiselev 2017) | step + 2 | step + 3 |
| 2 | 1x | /3 = 9.5455 MHz | 1.5 clk (50%) | step + 1 | step + 2 |

- **The switch** takes effect where the modulo-24 counter is 0 or 12. Every
  period (6, 4, 3) starts there, so no CPU clock is shortened or stretched, and
  the CPU clock keeps its phase to OSC and PCLK (c6 = cnt mod the period,
  checked in simulation). A write to 63h acts within 12 clk (0.42 us) of the
  register changing, inside the OUT that wrote it [A: the real chip's switch
  point is not documented; "glitch-free" is what the PC needs].
- **9.54 MHz falling edge:** 1.5 clk after the rising one, off the clk grid.
  `cpu_fall` is step + 1. The board needs it only as an ordering point (MEMR/IOR
  in T1, MEMW/IOW in T2, the 8237's strobes, the DMA hold flip-flop), and
  `rdy_ce` must stay a separate clk. At 9.54 MHz a write strobe is then in its
  first clk at the RDY sample that decides T3, so a card that signals IOCHRDY
  from the strobe's next-clk value (PVC4, CGA) is still seen. With the 4
  memory-bus wait states it is seen anyway.
- **At 9.54 MHz every second CPU edge falls in an odd clk**, half an OSC
  period off the OSC grid, where the cards' dot ticks are. This is the real
  machine's phase relation: 3 master clocks per CPU clock.
- **`ce_477`** is a fixed 4.77 MHz enable (cnt mod 6 = 0, = `cpu_step` at 4.77
  MHz). The keyboard interface's delays (`KBD_SEND` 1 ms, `KBD_RESET` 10 ms,
  formerly in CPU clocks) count it, so they stay real time.
- At speed 0 every enable is the /6 counter's, so 4.77 MHz is bit-identical
  (tb/clk `ref`, the gates).
- **Timing:** everything was already a single-cycle path at 28.6 MHz (34.9 ns;
  EU_DELAY 1, the EU at step + 1). At /3 the EU's outputs have 2 clk to reach
  biu88, which needs no constraint.

## 5. Speed control on the PC10-III

**The BIOS 4.41** (F000:xxxx):
- **Hot keys**, INT 9 (F000:EAB9): with Alt and Ctrl down, Esc goes to SETUP
  (EACB: keyboard acknowledge, EOI, `jmp D762`). Any other make code calls
  D40F: 1Fh (S) writes 00h, 14h (T) writes 40h, 20h (D) writes 80h to 63h
  (with the lock set, only bits 7-5 count), then beeps (D440: 200h speaker
  toggles with a 60h-iteration delay loop each, so the pitch follows the CPU
  clock), then stores the bits in 0040:0012 bits 7-6.
- **0040:0012** holds the speed: (12h & C0h) | 01h goes to 63h at the common
  exit of the BIOS services (F000:C6B5). INT 13h (floppy, A21C), INT 9 (EB72),
  INT 10h (F02E, F09E, F211), INT 14h (E78E) and CA21 jump there. So every
  BIOS call puts the speed back to 0012's. A program that writes 63h directly
  keeps its speed only until the next keystroke or BIOS call.
- **SETUP's default speed**: 40:A1h bits 1-0 (0 4.77, 1 7.16, 2 9.54).
  CA55 (end of POST) sets 0012 = (A1 & 3) ror 2 | 01h. On a hard disk system
  SETUP saves the word 40:A1h in the MBR at 1B4h (doc/rtc.md section 5), and
  the POST reads it back. On a floppy system the speed is for the session only.
  **SETUP itself is Ctrl-Alt-Esc**, from INT 9 at any time (F000:EACB -> D762,
  "COMMODORE PC SETUP UTILITY"; it sets SS:SP = 5000:029D). It is not entered
  at POST or through DEBUG; D762 is reached only from there.
- **POST:** 63h = 01h at reset (E077), 45h after the DMA set-up (E272, bit 6:
  7.16 MHz), and 45h/51h/41h during the RAM sizing (C301-C33B), all with bit
  6, then `| 02h` (8087), `& FDh`, `| 48h` (lock + 7.16 MHz, C3B2). Each BIOS
  service exit before CA55 puts 01h back (0012 is 0), so the POST runs at
  7.16 MHz in stretches (section 6 has the times), and at the default speed
  once CA55 has run.
- **SPEED.EXE** (C programs that poke 0040:0012 and never touch the port; the
  next BIOS service exit, e.g. DOS printing the next line through INT 10h,
  switches):
  - V1.2 (PC1020-3.ZIP, 1987-10-22, the PC10/20-III's): `-s` 01h, `-t` 41h,
    `-d` 81h; usage `SPEED -[std]`.
  - V1.2c (Colt MS-DOS 3.21 disk 1, 1988-01-25; AUTOEXEC.BAT `speed -t`):
    `-s` 01h, `-t` 41h; usage `SPEED -[st]` (the Colt has no 9.54 MHz).

**The shell:** no change. The real machine has no other speed control: it
starts at 4.77 MHz, SETUP stores the default in the hard disk's MBR, and the
hot keys and SPEED do the rest. A menu line for a default speed would not be
authentic, so there is none [Q: if wanted, it would have to act like SETUP's
word 40:A1h, not on the chip].

## 6. Tests

(Numbers: doc/history.md, 2026-10-26.)

- `tb/clk` (pc_clocks): `ref`: at speed 0 every enable equals the /6-only
  counter in every clk (PHASE 0 and 5, random resets); `fixed`: each speed's
  period, falling edge, rdy_ce/cpu_prestep, phase to PCLK, 4/6/8 CPU clocks per
  PCLK tick; `switch`: 2M clk of random requests, every CPU clock as long as
  its speed's, switches only at PCLK phase 0/12 within 13 clk, OSC/PCLK/ce_477
  unchanged. `mut.py`: 16 mutants.
- `tb/wait` (xt_wait): random bus cycles (all types, on-board or not, all
  speeds, 63h bits 6-5) against random IOCHRDY and DMA waits. It checks the
  table, the Tw count with the DMA rule, and READY against the logic of
  2026-10-22 in every clk at 4.77 MHz. `mut.py`: 20 mutants.
- `tb/sst -T 4` / `-T 3`: the SingleStepTests at 7.16/9.54 MHz clocking
  (every CPU clock 4 or 3 core clocks; the suite counts CPU clocks).
- `tb/sys`: `-cr` (CPU clocks per 50 ms), the log line `CPU clock x MHz`
  at every change, raw scan codes in `-k` (`\#hh`, Ctrl-Alt-D =
  `\#1d\#38\#20\#a0\#b8\#9d`) and pauses (`\.`, 250 ms); the speed-test boot
  floppy `tb/sys/turbo/mkspeedtest.py`.

### Results (2026-10-26)

**The speed test** (`tb/sys` run s1c, build turbo-b's RTL, 256 KB,
`speedtest.img` booted by the Commodore BIOS 4.41): iterations between two
timer ticks (54.9 ms) at 4.77 MHz, then the ratio to them, with the CPU clocks
per iteration in brackets.

| 63h | registers | 4 x IN 61h | 4 x B800 (PVC4) | 4 x F000 (ROM) |
|---|---|---|---|---|
| 00h 4.77 | 4841 (54.2 clk) | 2178 (120.4) | 1815 (144.4) | 2102 (124.7) |
| 40h 7.16 | 1.501 (54.1) | 1.390 (129.9) | 1.446 (149.9) | 1.440 (129.9) |
| 60h 7.16 fast | 1.501 (54.1) | 1.391 (129.8) | 1.446 (149.8) | 1.537 (121.7) |
| 80h 9.54 | 2.002 (54.1) | 1.761 (136.7) | 2.002 (144.3) | 1.820 (137.1) |
| C0h 9.54 | 2.002 (54.1) | 1.878 (128.2) | 2.002 (144.3) | 1.945 (128.2) |
| A0h 9.54 fast | 2.003 (54.1) | 1.762 (136.6) | 2.003 (144.2) | 2.076 (120.2) |
| 00h 4.77 again | 4840 | 2179 | 1815 | 2102 |

- Code in the on-board RAM scales exactly with the clock (1.50 / 2.00;
  TopBench on a real PC10-III: 1.51 / 2.01).
- The board's wait states show where the loop has an I/O or ROM cycle. Each
  of them costs less than its count because the 8088's prefetch overlaps part
  of it.
- The fast bit (bit 5) removes the ROM's wait states, and 9.54 MHz with bit 6
  has the shorter table.
- A "fast" loop can beat the clock ratio (ROM at A0h: 2.076): the refresh DMA
  (every 15 us of real time) costs fewer CPU clocks per second at a higher
  clock.
- The PVC4 loop's waits are real time (the chip's CPU slots), so its ratio
  depends on where they fall. TopBench's CGA card measured 1.32 at 7.16 MHz.

**The wait states counted per bus cycle** (`-cr`, the same run; cycles
without a DMA wait):
- 4.77 MHz: I/O 1 (25,652 cycles), on-board RAM 0, other memory 0 (the ROM)
  and 2-7 (the PVC4).
- 7.16 MHz: I/O 4 (24,523), on-board RAM 0, other memory 2 (2,116,556; 0 at
  60h) and 3-11 (the PVC4).
- 9.54 MHz: I/O 4 (15,015 at C0h) and 6 (29,116), on-board RAM 0, other memory
  0/2/4 and up to 14 (the PVC4).

**The POST** (Commodore BIOS 4.41, no keys): 4.77 MHz from reset, 7.16 MHz
from 0.23 s (E272: 45h) to the first BIOS service exit at 0.61 s (01h, since
0012 is still 0), and 7.16 MHz again during the RAM sizing from 7.91 to
10.21 s (C301-C3B4). The rest runs at 4.77 MHz, or at SETUP's default speed
once CA55 has run. The boot sector is read at 34.005 s with 640 KB (38.205 s
before the turbo) and at 22.605 s with 256 KB.

**The hot keys** (256 KB, hello360 booted; Ctrl-Alt-T/D/S/D/T one second
apart): the CPU clock changes 1.2 ms after the letter's make code (INT 9's
OUT 63h, then the beep). Over the next second it runs 7,158,861 clocks
(7.16 MHz), 9,545,152 (9.54), 4,773,054 (4.77) and 9,544,860 (9.54);
63h = 49h / 89h / 09h with the lock and parity bits kept.

**Floppy reads** (fdtest, 256 KB, the Colt DOS disk's cylinders 0-3, 9
sectors each): status 00h and the same sums at 7.16, 9.54 and 4.77 MHz
(6178h, B6C7h, 0B15h, D589h), and no split strobes (`+cutlog`). Before the
DMA rule of section 3 the same test returned status 20h at 7.16 and 9.54 MHz
and a wrong sum with status 00h.

**MS-DOS 3.21 at 9.54 MHz** (640 KB; the Colt disk 1 with the PC10-III's
SPEED.EXE V1.2 added as SPEED2.EXE; Ctrl-Alt-D at 32.0 s, before the boot):
- The boot is read at 9.54 MHz and reaches `A>` at 41.0 s.
- AUTOEXEC's `setclock -r` runs without "RTC timeout". Its `speed -t` switches
  to 7.16 MHz at 47.13 s, at the next BIOS service exit after SPEED wrote
  0012.
- `speed2 -d`: 9.54 MHz at 50.69 s. `ver` prints "MS-DOS Version 3.21".
  `speed2 -s`: 4.77 MHz at 55.07 s. `speed -t`: 7.16 MHz at 59.04 s.
- The wait-state histogram of the run: 9.54 MHz I/O 6 (13,056 cycles) and
  memory bus 4 (16,127,414 cycles, the ROM).

**SETUP** (640 KB, Ctrl-Alt-Esc after the boot): the "COMMODORE PC SETUP
UTILITY" screen with "Default system speed 4.77 MHz" (doc/rtc.md section 5).

**Build** pc10-turbo-b (REF=pc10-turbo-a, commit 8d35d5b): WNS +0.021 ns,
WHS +0.036 ns. Both are QNICE's own paths, the same as pc10-real-u's. On the
PC's clock (main_clk, 34.9 ns) WNS is +13.214 and WHS +0.043. BRAM 260.5/365
and LUTs 30,292 are unchanged (pc10-real-u: 30,299).

## 7. Open questions

- [Q] Does the FE2010A's BIOS ROM chip select get the memory bus wait states
  (assumed yes)?
- [Q] The wait states of DMA transfers at the turbo speeds (assumed: none
  added).
- [Q] Does the FE2010A really ignore IOCHRDY at 9.54 MHz with bit 5 set (the
  PT8010AF note)? This is not modelled, and the Commodore BIOS never sets bit 5.
- [Q] The 2018 and 2023 versions of Kiselev's table differ for 9.54 MHz with
  bit 6 (I/O 6 or 4). We use 2023.
- [Q] Where exactly in the CPU clock the FE2010A switches speed (we switch at
  a common period boundary, glitch-free), and the duty cycle at 7.16 MHz from
  the 28.6 MHz crystal (50%, from Kiselev's 2017 remark).
- [Q] What a read of port 63h returns (we return the register).
- [Q] RQ/GT itself: the 8088 floats the bus in T4/Ti and does not start the
  next T1, while our model keeps the 5160's HOLD with the DMA wait on READY
  and only moves the grant point. Timing at the CPU-clock level differs
  slightly from a real RQ/GT handover (no reference exists).
- [Q] A menu default speed (not authentic, so not added). SETUP's word in the
  hard disk's MBR is the real machine's way (not tested here with a PC20-III
  hard disk image).
- Measurements on a real PC10-III would settle all of these: the speed test
  floppy (`tb/sys/turbo/speedtest.S`), TopBench, a logic analyser on CLK.
