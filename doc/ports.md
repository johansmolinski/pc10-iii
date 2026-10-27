# The PC10-III's serial port, parallel port and bus mouse (and a Covox)

Status 2026-10-26, branch `ports`: the three on-board ports that the Commodore
gate array 5720 decodes (section 1), the serial port (section 2), the
parallel port (section 3), the bus mouse (section 4), the Covox Speech Thing
on the parallel port's latch and the audio mixer (section 5), the MEGA65 side:
the PMOD headers, the joystick port and the menu (section 6), the tests
(section 7), the hardware test (section 8), open questions (section 9). On
hardware (pc10-real-v, pc10-bline-b, 2026-10-27): the POST, the mouse in
MTEST and the Covox; the serial and printer ports are not tested (no PMOD
adapter), section 8.

Facts are marked with their source; **[A]** marks an assumption, **[Q]** an
open question.

Sources:
- **TM**: the *Commodore PC-1 Technical Manual* (10/87), pp. 1-27..1-31: the
  5720 "MIO - Mouse and I/O chip" (I/O map, mode register 230h, the mouse
  registers), J8 the mouse port; the PC10-III carries the same chip
  (318087-01; research `~/pcxt-work/research/models/commodore-8088-models.md`
  section 3).
- **SM**: the PC10-1/10-2/10-III service manual 314860-01: parts list U402
  8250 (380205-01, INS8250AN or WD8250PL), U403 PPC1 (318091-01), U404 1488,
  U405 1489; "MOUSE PORT built in for 1352 mouse"; the Rev 6c schematic
  (312628): the 8250's INTR is COMINT into the 5720, the PPC1 drives IRQ7 itself.
- **BIOS**: the Commodore BIOS 4.41 (318085-08), disassembled for reading only
  (`~/pcxt-work/pvc4/bios.dis`, not in the repository; offsets F000:xxxx).
- **MAME**: `src/devices/machine/ins8250.cpp` (BSD-3): the INS8250's flaws
  against the 8250A/16450 (behaviour only, no code).
- **Megamiga**: `~/git/pub/AExp` main: its PMOD serial port (M2M exception 13
  `pmod-pins`, `mega65.vhd`, CORE.xdc), the raw joystick lines (exception 6
  `raw-joyports`) and the POT-line mouse buttons (`main.vhd`).

## 1. The 5720 and 230h

The 5720 decodes BA9-BA0 with AEN (TM p. 1-28): COM at 2F8h-2FFh or
3F8h-3FFh, LPT at 3BCh-3BFh, 378h-37Bh or 278h-27Bh, the mouse at
23Ch-23Eh, enabled by the mode register 230h (`rtl/system/cbm_cfg230.sv`,
doc/pvc4.md section 7):

| 230h bits | 1-0 LPT | 3-2 COM | 4 mouse |
|---|---|---|---|
| 00 | off | off | off |
| 01 | 3BCh | 2F8h | on, and IRQ2 |
| 10 | 378h | 3F8h | |
| 11 | 278h | off | |

All bits are 0 after reset (TM). `pc_system` builds the three ports with the
PVC4 (`PVC4_FIT`, the PC10-III board); the 5160 configuration has none of
them. Interrupts: the mouse IRQ2, the serial port IRQ4 at 3F8h and IRQ3 at
2F8h (the IBM assignment; the 5720 routes COMINT [A]), the parallel port
IRQ7.

The BIOS 4.41's POST (F000:CA55..CF5x) probes the expansion bus first and
then enables the on-board ports where nothing answered:
- **LPT** (CA8E): 230h with the LPT bits clear, the probe CB8C at 3BCh, 378h
  and 278h (expansion cards): 0Ch to the data port, 0Dh to the control port,
  the data port read back (0Ch: a port). Then SETUP's choice (40:A1h bits 3-2:
  3BCh, 378h, 278h, none; the table at F000:CBE8) for the on-board port, unless
  a card answers there ("LPT configuration conflict"), and the probe again:
  "Onboard   LPT    at 03BCh", the equipment word +40h per port. (The POST
  also writes its checkpoint codes to 3BCh and 378h, CA35, and toggles control
  bit 3 there, CA40.)
- **COM** (CBF6): the probe CCBC writes the divisor latch (LCR 80h, DLL 01h,
  then MCR 00h, DLL AAh) and reads DLL back. Only one on-board port: SETUP's
  40:A1h bits 5-4 pick 3F8h (0) or 2F8h (1); "Onboard   COM    at 03F8h",
  equipment +200h.
- **Mouse** (CD30-CD71, section 4): "Onboard   MOUSE  at 023Ch". The BIOS keeps
  no mouse in the equipment word.

## 2. The serial port: an INS8250 (`rtl/system/uart8250.sv`)

The parts list allows an INS8250AN or a WD8250PL (SM). The model is the
INS8250 (the user's decision 2026-10-26: not a 16450/16550):

- Registers as the data sheet (DLAB, RBR/THR/DLL, IER/DLM, IIR, LCR, MCR,
  LSR, MSR); **no scratch register**: offset 7 reads FFh, writes are lost
  (MAME: the scratch register came with the 8250A). IIR bits 7-4 read 0.
- **Baud clock:** the 8250's crystal input is 1.8432 MHz, made from the core
  clock by an exact fractional accumulator (315/11 MHz x 12672 / 196875); the
  divisor counts those ticks into the 16x clock. A write to DLL or DLM restarts
  the counter (data sheet); divisor 0 stops it [A].
- **Transmitter:** THR to the shift register at the next 16x tick when it is
  idle or ends its stop bits (back to back); 5-8 bits LSB first, parity odd /
  even / stick, 1, 1.5 (5-bit) or 2 stop bits; BREAK (LCR bit 6) holds SOUT low.
- **Receiver:** start bit seen on a 16x tick, confirmed 8 ticks later (else a
  false start), every bit sampled 16 ticks later; RBR, DR and the error bits at
  the middle of the first stop bit; OE when DR was still set (the old character
  is lost; not when RBR is read in that very clk); BI for an all-zero character
  (RBR 00h, FE too); after a framing error or a break it waits for SIN high
  before a new start bit [A].
- **Interrupts** in the 8250's priority: line status (OE/PE/FE/BI, cleared by
  reading LSR), received data (DR, cleared by reading RBR), THR empty (set when
  THR moves on, and **on every IER write with ETBEI = 1 while THRE is set**;
  cleared by writing THR or by reading IIR while it shows THRE), modem status
  (the deltas, cleared by reading MSR).
- **The INS8250's flaw** (MAME: "the original 8250 pulses the interrupt line if
  a higher priority interrupt is cleared"): when the highest pending source is
  cleared while a lower one stays pending, INTR drops for 8 clk (280 ns [A]) and
  rises again, so the edge-triggered 8259 sees the next interrupt. (On a
  16450 INTR stays high, and a handler that does not loop on IIR loses it.)
- **Loopback** (MCR bit 4): SOUT high, the shift register's output into the
  receiver (BREAK is not looped [A]), SIN ignored, DTR/RTS/OUT1/OUT2 pins
  inactive, MSR from MCR: DTR -> DSR, RTS -> CTS, OUT1 -> RI, OUT2 -> DCD.
- **The interrupt on the bus** only while the OUT2 pin is low (IBM's
  convention, which DOS software relies on; the Rev 6c schematic shows ~OUT2
  wired, its gate is inside the 5720 [A]); so no interrupt in loopback.
- **Reset:** IER, LCR, MCR, LSR (60h), the MSR deltas cleared; RBR, THR and the
  divisor keep their values.
- **Read side effects** (DR, the LSR errors, the deltas, THRE by IIR) act in the
  last clk of the IOR strobe, the clk whose data the board takes.

The modem inputs (`pc_ports.vhd`, section 6):
- **PMOD off** = a port with nothing plugged in: the 1489 receivers read an
  open input as "off", so RXD is mark and CTS, DSR, DCD and RI are inactive
  (MSR bits 7-4 = 0). The BIOS still finds the port (as on a real machine with
  no cable).
- **PMOD on:** RXD and CTS from the header; DSR and DCD follow the PC's own
  DTR (the DTR-DSR-DCD loop of a null-modem cable: the BIOS's INT 14h send
  waits for DSR and CTS, terminal programs for DCD); RI inactive. An
  unconnected CTS pin reads active (pull-down in CORE.xdc), so a two-wire
  adapter (TXD, RXD) works with the BIOS.

## 3. The parallel port (`rtl/system/lpt_ppc1.sv`)

No data sheet of the Paradise PPC1 was found, so it is IBM's printer adapter
(the user's decision):

| Offset | Read | Write |
|---|---|---|
| 0 | the data latch | the data latch |
| 1 | {/BUSY, /ACK, PE, SLCT, /ERROR, 1, 1, 1} | - |
| 2 | {1, 1, 1, IRQ EN, SLCT IN, /INIT, AUTO FD, STROBE} | the control register (bits 4-0) |
| 3 | nothing answers | - |

- Status bit 7 is the BUSY pin inverted, bits 6-3 the pins as they are, bits
  2-0 read 1 [A]. Control bits 0, 1 and 3 drive their active-low pins
  inverted, bit 2 /INIT as written. No bidirectional mode (bit 5 ignored) [A].
- **IRQ7** (IBM): while IRQ EN is set, the /ACK pin drives the interrupt line:
  the 8259 sees the edge when /ACK goes back high at the end of the printer's
  acknowledge, and once when IRQ EN is set with /ACK high [A].
- **Reset:** the control register is cleared (STROBE inactive, /INIT low: the
  printer is held in reset until the BIOS writes 08h or 0Ch, IBM's 74LS174);
  the data latch keeps its value (IBM's 74LS374), 00h at power-up.
- **The status lines that are not on the PMOD** (PE, SLCT, /ERROR) read
  "printer ready"; with the PMOD off BUSY and /ACK too. The port exists either
  way and the BIOS lists LPT1. (Printing with the PMOD off goes nowhere, as
  with a cable to nothing: there is no "print to file", the user's decision.)

## 4. The bus mouse (`rtl/system/cbm_mouse.sv`)

The 5720's mouse interface (TM pp. 1-29..1-31), for the Amiga 1352 mouse that
Commodore sold with the PC10-III ("MOUSE PORT built in for 1352 mouse", SM),
on the 9-pin J8 (TM: 1 vertical quad, 2 horizontal quad, 3 vertical pulse,
4 horizontal pulse, 5 middle, 6 left, 9 right; the Amiga calls the same pins
V, H, VQ, HQ):

| Port | Access | Bits |
|---|---|---|
| 23Ch | read | 7 left, 6 middle, 5 right (0 = pressed; see below), 4 = 0, 3-0 the selected counter nibble |
| 23Dh | read/write | a plain 8-bit register ("the MicroSoft driver uses this register to recognize the mouse interface") |
| 23Eh | write | 4 interrupt disable, 5 high nibble, 6 vertical counter, 7 inputs disabled; its falling edge clears both counters |
| 23Eh | read | 7-4 = 0, 3 = IRQ2 inverted (a 32.8 ms square wave; 1 while the interrupt is disabled), 2-0 = 1 |

All three answer only while 230h bit 4 is set, which also enables IRQ2.
23Eh is cleared by reset (interrupt enabled, low nibble of X).

- **Counters:** two 8-bit up/down counters, one count per edge of either
  quadrature line, decoded as the Amiga's Denise does (Minimig's `userio.v`):
  +1 for "quad" rising with "pulse" high and the three rotations of it, -1 for
  the mirror; nothing when both lines change in the same clk (userio.v counts
  +1 there). + is right and down, as the PC's bus mouse reports. The counters
  wrap; they keep counting while 230h bit 4 is clear [A]. While 23Eh bit 7 is
  set the inputs are ignored (moves are lost), its falling edge clears the
  counters: the Microsoft driver's hold - read four nibbles - release.
  The lines pass two synchronizer flip-flops (plus the framework's two).
- **Buttons:** read live [A]. The TM's table gives bit 5 = left and bit 7 =
  right, but Commodore's own MOUSE.COM (Microsoft 6.11, `PC1020-3.ZIP`) reads
  bit 7 as the left button, as on Microsoft's bus mouse card: with the TM's
  order tb/sys saw the right button reported as the left one (and the left as
  the right). The model follows the driver: 7 left, 6 middle, 5 right [Q:
  the TM's table or the board's J8 wiring].
- **The interrupt:** a square wave of 32.768 ms on IRQ2 (16 MHz / 2^19: the
  period the manual gives, from a 16 MHz clock like the floppy controller's
  OSC201 [A]; made from the core clock by an exact fractional accumulator),
  while 230h bit 4 is set and 23Eh bit 4 is clear. The edge-triggered 8259
  sees one interrupt per period. 23Eh bit 3 lets the driver find the IRQ (the
  Microsoft bus mouse card's port C, where the low nibble shows the IRQ lines).
- **The BIOS 4.41's detection** (F000:CD30-CD71): two reads of 23Eh for DEh
  (an InPort card's signature; the 5720 answers 07h/0Fh or, disabled, nothing
  = FFh), then 91h to 23Fh (the Microsoft card's 8255 mode word; the 5720 does
  not decode 23Fh), 66h to 23Dh, 99h to 232h (another value on the bus), and
  23Dh back: 66h = a mouse. The first pass runs with 230h bit 4 clear, so only
  an expansion card answers; then (CD8C) the BIOS sets 230h bit 4 and tries
  again: "Onboard   MOUSE  at 023Ch". SETUP's "On Board Mouse Interrupt" and
  the 231h register belong to boards we have no record of (research section
  4); without 231h the BIOS uses IRQ2.

## 5. The Covox Speech Thing and the mixer (`rtl/system/pc_audio_mix.sv`)

The parallel port's data latch as an unsigned 8-bit DAC, the Covox Speech
Thing in the port (the user's decision for 0.1): inside the core, so it plays
whether the PMOD is on or off. `main.vhd` mixes it with the PC speaker:

- **The speaker** as before: 0 or +2000h, a DC-coupled square wave.
- **The Covox:** (d - 128) x 32, so the full range is +-4096, about the
  speaker's swing, through a **DC blocker**: a first-order high-pass
  y = x - x' + y' - y'/2^10 at clk / 600 = 47.7 kHz (the corner at 7.4 Hz). A
  latch that stands still is silence whatever its value: the BIOS leaves its
  POST codes and the printer probe's 0Ch there, DOS's printing moves it (a
  Covox in a real port hears printing too, as clicks). y keeps 8 fraction bits;
  its decay is rounded toward zero but at least one unit, so a resting latch
  ends at exactly 0 (after 0.2 s for a full-scale step). The power-up value
  of x' is the latch's 00h, so there is no click at power-up.
- **No clipping:** the high-pass's impulse response has an L1 norm of 2, so
  |y| <= 8192 and the sum stays within -8192..+16384 (tb/ports measures
  -8160..+16352 for its worst cases).
- Why not "the DAC's change from its last value" alone: a latch that moves
  once (a POST code, a printed character) would leave a step that never
  returns; the DC blocker returns it to 0 within a fraction of a second, below
  the range where Covox software plays (4-22 kHz sample rates).

## 6. The MEGA65 side (`CORE/vhdl/pc_ports.vhd`)

### 6.1 The PMOD headers

The board tops (R4, R5, R6) route the two PMOD headers into `MEGA65_Core`:
Megamiga's M2M exception 13 `pmod-pins`, already in this project's vendored
framework (doc/m2m-provenance.md), so nothing in `M2M/` changes. The R3 top is
not adapted (doc/m2m-shell.md section 12). One menu item, **Ports and mouse >
PMOD: serial + printer** (default off), powers both headers (`pmod1_en_o`,
`pmod2_en_o`) and drives the outputs; off, every pin is high-Z and both headers
are unpowered, exactly as Megamiga's serial port.

| Header | [0] | [1] | [2] | [3] |
|---|---|---|---|---|
| PMOD1 lo | /CTS in | TXD out | RXD in | /RTS out |
| PMOD1 hi | /STROBE out | BUSY in | /ACK in | /INIT out |
| PMOD2 lo | D0 out | D1 out | D2 out | D3 out |
| PMOD2 hi | D4 out | D5 out | D6 out | D7 out |

- PMOD1 lo is Megamiga's layout (the MegaST's): the Digilent PmodUSBUART pinout
  and MAX3232 modules fit it, and an adapter made for Megamiga works here.
- The printer's fourth line is /INIT (out) rather than SELECT (in): the BIOS
  resets the printer with it at start-up and INT 17h AH=1; most printers
  pull it inactive themselves when it is not connected.
- CORE.xdc: pull-ups on RXD (lo[2]) and /ACK (hi[2]), pull-downs on /CTS
  (lo[0]) and BUSY (hi[1]): an input with nothing connected reads idle, "clear
  to send" and "not busy". The inputs pass a 2-FF synchronizer.
- **Electrical:** every pin is 3.3 V LVCMOS, not 5 V tolerant.
  - **Serial:** a 3.3 V USB-UART module (PmodUSBUART, CP2102, FT232 at 3.3 V)
    directly, or an RS-232 level shifter module (MAX3232, supplied from the
    PMOD's 3.3 V) for a real RS-232 port: TXD -> T1IN, R1OUT -> RXD, /RTS ->
    T2IN, R2OUT -> /CTS. **Never connect RS-232 levels (+-12 V) to the header.**
    A null-modem link to another PC: TXD/RXD and RTS/CTS crossed, GND; DSR
    and DCD come from our own DTR (section 2).
  - **Printer** (Centronics, 5 V TTL): the printer's inputs (D0-D7, /STROBE,
    /INIT) usually have pull-ups to 5 V, which would push current into the
    3.3 V pins: drive them through a 5 V buffer with TTL inputs (74HCT541 or
    74AHCT541 for D0-D7, a 74AHCT125 for /STROBE and /INIT, supplied with 5 V,
    e.g. from a USB supply). The printer's outputs (BUSY, /ACK) must not reach
    the pins at 5 V: a 74LVC125/74LVC245 supplied from the PMOD's 3.3 V (5 V
    tolerant inputs), or a divider per line (2.2 kOhm series, 3.3 kOhm to GND:
    5 V -> 3.0 V). A bare series resistor that relies on the FPGA's clamp
    diodes is not recommended. DB25 side: D0-D7 pins 2-9, /STROBE 1, /ACK 10,
    BUSY 11, /INIT 16, GND 18-25.
  - The Covox needs no adapter: it is inside the core (section 5).

### 6.2 The mouse: joystick port 1

An Amiga quadrature mouse (the 1352 or any Amiga mouse; the PC10-III's own) in
the MEGA65's joystick port 1. Its lines reach the core raw: Megamiga's M2M
exception 6 `raw-joyports` (the framework's 1 ms debouncer, which swallows
quadrature pulses, is a 2-FF synchronizer) is already in the vendored
framework. The PC core used the joystick ports for nothing before; the
framework now passes port 1 to the core from reset (`JOY_1_AT_RESET` = true
in config.vhd; `JOY_1_AT_OSD` stays false: the mouse is ignored while the menu
is open).

| DB9 pin | Amiga | Atari ST | M2M line |
|---|---|---|---|
| 1 | V | XB | up |
| 2 | H | XA | down |
| 3 | VQ | YA | left |
| 4 | HQ | YB | right |
| 6 | left button | left button | fire |
| 9 | right button | right button | POT X |
| 5 | middle button | - | POT Y |

- **Ports and mouse > Mouse: Amiga / Atari ST** (default Amiga): the Atari ST
  choice swaps pins 1 and 4, the known adapter wiring between the two mice
  [A: the direction of the ST's vertical axis is to be checked on hardware].
  Cheap (a multiplexer), so it is a menu choice.
- **Buttons:** left = pin 6. Right (pin 9) and middle (pin 5) are POT lines,
  which the MEGA65 can only sense, not pull up: **a passive mouse's right and
  middle buttons are invisible on every board revision** (Megamiga's finding
  from the schematics). They work with an active adapter that drives the lines
  (mouSTer and friends), with Megamiga's presence latch: a line counts as a
  button only after it was seen driven high; one held "pressed" for 30 s
  disarms (an unplugged adapter); the PC's reset disarms. There is no keyboard
  substitute (every MEGA65 key is a PC key).
- The 1351 (proportional mode) is not supported.

### 6.3 The menu and the settings file

```
 Ports and mouse          submenu, main menu line 44
   PMOD: serial + printer   (default off) both PMOD headers on: COM, LPT
   Mouse: Amiga             (default)
   Mouse: Atari ST
```

On the branch: 58 menu lines (50 before), settings signature `menu=7`, the
menu heap 1238 words for 1248 (`MENU_HEAP_SIZE`; 20 + 714 item characters + 1
+ 4 x 58 + 1 + (5 submenus + 3 manual ROMs + 1) x 30), `HEAP_SIZE` 19328
(-160). Merged with intfd's row "Drive B" (2026-10-27): 60 lines, the submenu
at lines 45-52, signature `menu=8` (a settings file of an older menu is reset
to the defaults once), `MENU_HEAP_SIZE` 1280 (demand 1276: 744 item
characters, 4 x 60), `HEAP_SIZE` 19296; HEAP/stack addresses unchanged. With
` int. drive` beside ` B:%s` (2026-10-27): 59 lines, the submenu at lines
44-51, signature `menu=9`. No firmware code: the HDL reads the two menu bits.

## 7. Tests

- **tb/ports** (`make run`, `python3 mut.py`; Verilator): one bench per block,
  each with a reference model compared in every clk (read data and select,
  pins, interrupts):
  - `uart_run`: `uart_model.h` (the transmitter as a frame waveform per
    character, the receiver from the start tick and computed sample ticks, the
    IIR from a priority list), compared every clk; regs (reset values, DLAB,
    no scratch, IIR read-only, the BIOS's probe, the decode for 230h 00/01/10/11
    and AEN), baud (bit times on SOUT for divisors 1-1047 within 1 clk of
    16 x div / 1.8432 MHz, frame lengths, divisor 0, a DLL write restarting the
    counter), format (all 40 frame formats decoded from SOUT by a separate line
    decoder, back-to-back frame lengths, loopback), rx (frames built by the
    bench: every format at -3/0/+3 % baud, parity and framing errors, break,
    overrun, false start, a burst), intr (THRE on enabling and on a second IER
    write, the clears, all four sources in priority, the 8250's INTR pulses,
    OUT2 and loopback gating, IRQ3/IRQ4), msr (deltas from the pins, TERI only
    on the trailing edge, loopback mapping, outputs in loopback, BREAK, reset),
    random (400,000 operations, 34 M clk).
  - `lpt_run`: the decode at the three bases (base + 3 and AEN not), the BIOS's
    probe, all 32 status combinations, the control register and its pins,
    reset (control cleared, data kept), IRQ7 (enable edge, the end of /ACK),
    random.
  - `mouse_run`: the model counts with userio.v's conditions; the BIOS's
    detection sequence, the Microsoft driver's read (moves in all directions,
    wrap, moves lost while held, no clear without the hold's falling edge,
    fast moves every 3 clk, counting while disabled), the buttons, the steps
    timed inside read strobes (the synchronizer depth), IRQ2's period (938,356
    clk +-1) and half period, its enables, status bit 3, reset, random.
  - `mix_run`: silence for any resting latch (also from power-up), the
    speaker's levels unchanged, the range for full-scale steps, square waves
    and random input (-8160..+16352), the output within 4 LSB of a
    double-precision model, the gain at 1 kHz (1.001) and 5 Hz (0.565, the
    model 0.559), the decay to exactly 0 (9159 samples, 0.19 s).
  - `mut.py`: 86 of 86 mutants killed (44 of the 8250, 15 of the parallel
    port, 18 of the mouse, 9 of the mixer). The first run left two: a DLL
    write that keeps the divisor counter (the benches always wrote DLM after
    DLL, which restarts it too: a DLL-only test added) and a mouse with one
    synchronizer stage (a count one clk early: the timing test with steps
    inside the read strobes added).
- **tb/shell** (`run.sh`, ghdl): `tb_ports.vhd` for `pc_ports.vhd`: PMOD off
  (unpowered, every pin high-Z, an unplugged port, a ready printer, an
  external driver on the pins ignored), on (the pin directions, the outputs,
  the inputs two clocks late through the synchronizer, DSR/DCD = DTR), off
  again; the mouse lines for both mappings; the POT buttons (passive mouse,
  active adapter, watchdog, reset). `mut_ports.py`: 25 of 25 killed.
- **tb/sys** (`make FE=1 PVC4=1 RAM_KB=256`, the Commodore BIOS 4.41; fedora
  `~/pcxt-work/ports/`): the POST (20 s, no disk) lists `Onboard   LPT    at 03BCh`, `Onboard   COM    at
  03F8h`, `Onboard   MOUSE  at 023Ch`, `Onboard   RTC    at 02C0h`; the BIOS
  data area: COM 03F8 0000 0000 0000, LPT 03BC 0000 0000, equipment 426D (1
  serial, 1 parallel port); the printer probe's strobe with 0Ch seen on the
  port log (`-SL`). The mouse: tb/sys showed the
  TM's button bits swapped (fixed for pc10-ports-c); that run's numbers were
  not recorded.
- **Gates** (fedora `gates.sh ports-a`; the 5160 configuration has no
  ports): g_tr a72753ca..., g_tre bd612823..., g_trL2 a72753ca...: identical
  to merge-c/turbo-b; g_fd identical but for the wall time and the new BDA
  line at the end; tb/fdc 232 checks, tb/hdc 3,182 checks, tb/cga, tb/mda,
  tb/shell PASS.

## 8. Hardware test (build pc10-ports-c)

The kit (`~/pcxt-work/kits/pc10-ports-c/`): the bitstream and `sd/pc10/ports.img`,
the Colt MS-DOS 3.21 disk 1 with Microsoft's MOUSE.COM (from `PC1020-3.ZIP`),
MTEST.COM, COVOX.COM and an AUTOEXEC.BAT that runs `mouse` and `mtest`
(`tb/sys/ports/mkportsdisk.py`). The other SD files as before.

1. **Start-up:** the 58-line menu has a new settings signature: the menu's
   options return to their defaults once (check C: and the chipset/display).
   The POST lists `Onboard LPT at 03BCh`, `Onboard COM at 03F8h`, `Onboard
   MOUSE at 023Ch`, `Onboard RTC at 02C0h` (simulated: section 7).
2. **Mouse:** an Amiga mouse in joystick port 1, **Ports and mouse > Mouse:
   Amiga**. Boot `ports.img` in A: (or copy MOUSE.COM and MTEST.COM to C:).
   `mouse` prints the Microsoft driver's banner and "installed"; `mtest`
   prints the port tables, the INT 33h reset (AX FFFF and the buttons), then
   a line `mouse X Y B` whenever the position or the buttons change: right
   and down must count up, smoothly, also for fast moves. The left button
   ends it. The right button needs an active adapter (a passive mouse's
   right button is invisible to the MEGA65, section 6.2). With an Atari ST
   mouse: **Mouse: Atari ST**, and check both axes' directions.
3. **Covox:** `covox` plays a tone for 3 s (about 400 Hz at 4.77 MHz, higher
   at the turbo speeds) and a falling sweep, then silence; no PMOD needed.
   Printing with the PMOD off (`dir > prn`) clicks in the speaker: the Covox
   hears the printer data, as a real one in the port.
4. **Serial** (PMOD on: **Ports and mouse > PMOD: serial + printer**): a
   3.3 V USB-UART on PMOD1 lo (its RX on lo[1] TXD, its TX on lo[2] RXD, GND),
   a terminal on the host at 9600 8N1. On the PC: `mode com1:9600,n,8,1`,
   then `dir > com1` (the listing on the host; DOS sends through the BIOS's
   INT 14h, which waits for DSR and CTS: DSR comes from the core's DTR loop,
   CTS from the pin or its pull-down). Receiving is best tested with a DOS
   terminal program (the BIOS's INT 14h receive times out after about a
   second). `mtest` sends "OK" at 9600 directly. RTS/CTS: lo[3]
   and lo[0] if the adapter has them.
5. **Printer** (PMOD on, a 5 V printer through the buffers of section 6.1):
   `dir > prn`, `copy file prn`. Without a printer the BIOS still sends
   (BUSY reads "not busy").
6. **PMOD off:** a module's power LED goes out, nothing is driven.

**Results** (the user, 2026-10-27, builds pc10-real-v and pc10-bline-b):

- 1: the POST lists LPT, COM, MOUSE and RTC.
- 2: MOUSE.COM installs and MTEST follows the mouse (an Amiga mouse). Not
  tried yet: a program with a mouse cursor; the Atari ST mouse (its axis
  directions stay open, section 6.2).
- 3: COVOX.COM plays its tone and sweep.
- 4-6: not tested: no serial/printer PMOD adapter. Release 0.1 says so
  (README, doc/release-0.1.md).

## 9. Open questions

- **[Q]** The PPC1's own behaviour (a bidirectional mode, status bits 2-0, the
  IRQ7 polarity): no data sheet found; IBM's printer adapter is built.
- **[Q]** Whether the 5720 gates COMINT with OUT2 (IBM's convention is built)
  and how the 231h register of BIOS 4.37+ (SETUP's mouse IRQ 2/3/4, on-board
  game port) reached the hardware.
- **[Q]** The button bits of 23Ch: the TM's order (5 left, 7 right) or the
  Microsoft driver's (7 left, 5 right, built).
- **[Q]** The 5720's quadrature decoding (one count per edge is built, as the
  Amiga) and its sampling clock; the source of the 32.8 ms (16 MHz / 2^19 is
  built).
- **[A]** The Atari ST mouse's mapping (pins 1 and 4 swapped).
- A keyboard substitute for the right button of a passive mouse.
