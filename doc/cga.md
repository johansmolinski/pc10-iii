# IBM CGA card (`rtl/video/cga/`)

Status 2026-10-22: complete for RGBI output, verified in simulation (section
9) against a C++ model of MartyPC's CGA. GLaBIOS boots with it in `tb/sys`
(instead of `cga_stub.sv`), without a font. Not yet on hardware; composite
decoding not done (the raw signals are there, section 7).

## 1. Files and ports

| File | Contents |
|---|---|
| `rtl/video/cga/cga_card.sv` | the card: bus interface, wait states, registers, video RAM, character ROM, sequencer, attribute logic, output pipeline |
| `rtl/video/cga/cga_crtc.sv` | the Motorola MC6845 |
| `tb/cga/` | testbench (section 9) |
| `tools/ooc/cga_ooc.tcl` | Vivado out-of-context build of the card alone |

`cga_card` has the card-bus ports of `doc/architecture.md` section 3 that a
CGA uses (no IRQ, no DRQ), plus `isa_dsel` (the card drives `isa_din`, as
`xt_board.sv` expects), and:

| Port | Use |
|---|---|
| `ce_14m` | the 14.31818 MHz enable from `pc_clocks` |
| `font_we`, `font_addr[12:0]`, `font_data[7:0]` | character ROM load port (section 6.5) |
| `font_thin` | jumper P3: the thin font |
| `lpen_trig`, `lpen_sw` | light pen (tie to 0) |
| `vid_rgbi[3:0]`, `vid_hsync`, `vid_vsync`, `vid_hblank`, `vid_vblank` | video, one dot per `ce_14m` (section 6.6) |
| `comp_*` | raw signals for a composite model (section 7) |

Parameters: `CE_DELAY` (1), `DC_RESET` (0), `RD_LEAD` (6), `WR_LEAD` (3),
`SNOW` (1), and the display window `AP_X/AP_W/AP_Y/AP_H` (128/768/17/245).

Size (Vivado 2022.2, xc7a200t-2, out of context, `tools/ooc/cga_ooc.tcl`):
480 LUTs, 415 flip-flops, 6 BRAM tiles (16 KB video RAM, 8 KB character
ROM). Timing at 100.2273 MHz met with +2.15 ns; the worst path is the
6845's character-clock update (the light pen copy of MA). Reports:
`~/pcxt-work/ooc/cga-ooc-a/`. (Measured before the move to 28.63636 MHz,
which added the display delay line of section 2: about 90 flip-flops more.)

## 2. Clocking: when things happen

Everything runs on `clk` with `ce_14m` (architecture.md section 1). MartyPC
is the reference, and its CPU-CGA interaction has a simple time model: when
the CPU does something at an instant t (in 14.318 MHz ticks), the CGA is
first "caught up" to t, then the access acts. So:
- an I/O read returns the CGA's state after all its updates at t;
- an I/O write acts after the CGA's update at t, i.e. from the next dot on;
- the wait states of a memory access depend on the CGA's phase at the end of
  T2.

In the card, the dot clock is `ce_14m` delayed by `CE_DELAY` = 1 clk, one
clk before the next `ce_14m` (`clk` = 28.63636 MHz, 2 per tick). In
`pc_clocks`, `cpu_step` and `cpu_fall` always fall on a `ce_14m` clk, and the
board's registers change at the end of those clks. The card has therefore
finished its update for an instant one clk before the board's edge of the
same instant:
- what the board samples at that edge (READY, read data) is the state after
  the update (`rdy_ce` is in the clk of the card's tick and samples the state
  before it, the one for the instant before);
- a strobe the board changes at that edge reaches the card after the update.

Between the board's edge and the card's next tick there is one clk, so
everything the card does on a bus event must be done at the end of that clk
(on the 100 MHz clock, `CE_DELAY` 6, there were 5 clk; doc/clock-plan.md):
- the board ends its commands at the edge where T4 begins (it knows the
  T4 a clk before, `xt_board.sv` `cyc_end`), and an I/O access acts in the
  strobe's last clk, which the card knows from the card bus's next-clk values
  (`isa_aen_next`, `isa_addr_next`, `isa_ior_n_next`, `isa_iow_n_next`): a
  CRTC, mode, colour or light pen access is done at the edge where T4
  begins, before the next tick, as MartyPC applies it;
- a memory access starts in the clk after the strobe falls, which is the
  tick's clk: it counts that tick (`el` starts at 1);
- the 80-column clock switch at lchar phase 0 takes a mode that a pending
  text/graphics change gives in the same clk (`post`, the only non-tick clk
  of phase 0);
- the display fetch after a character clock (5 clk) ends after the next two
  ticks, so the dots are computed `DLY` = 3 ticks late, from a delay line of
  the dot logic's inputs and a copy of the fetched character made when the
  character clock's record leaves the delay line. The picture is the same,
  3 ticks later (`tb/cga` compares with the model at `LAT` 6 instead of 3).

`CE_DELAY` must stay 1 at 28.63636 MHz (0 would update the card at the
board's own edge, after the board has sampled it).

The card's lchar phase `dc` (MartyPC: `cycles & 15`) runs from reset with
`DC_RESET`. Together with `pc_clocks`' `PHASE` it fixes the CPU-CGA phase
(16 x 3 relations). On a real PC the CGA is not reset, so this relation is
whatever power-on gave; *Area 5150* depends on it (doc/plan.md section 4).
Both are parameters of the `pc_system` instances.

## 3. MC6845 (`cga_crtc.sv`)

The counter logic is MartyPC's `Crtc6845::tick()` (which follows the Amstrad
CPC "CRTC Compendium"), one call per character clock. IBM used the Motorola
part. Modelled:

- **Registers and masks**: R4/R6/R7 7 bits, R5/R9/R11 5 bits, R8 2 bits,
  R10 7 bits, R12/R14 6 bits. R3: HSYNC width in bits 3-0, **0 = 16
  characters** (Motorola; the colour-burst trick of *8088 MPH*). The VSYNC
  width bits 7-4 do not exist on the Motorola part: VSYNC is always 16 lines.
  Readable: R14-R17; the others read 0xFF (as MartyPC). The address register
  is 5 bits (MC6845 data sheet; MartyPC compares the whole byte).
- **Register writes mid-frame**: the coincidence circuits compare the
  counters with the live registers at every character clock (C0 = R0, R1,
  R2; C9 = R9; C4 = R4, R6, R7), so a write takes effect at the next
  character clock wherever the beam is. A write in the same clk as a
  character clock acts after it.
- **Start address**: R12/R13 latched at the start of each frame (C4 = C9 =
  0); MA reloaded from the row start at every line end, row start updated at
  C0 = R1 on the last line of a row.
- **Vertical total adjust**: after the last line of row R4, R5 extra lines
  (MartyPC's counter: the frame ends when the count exceeds R5).
- **Last-line management** (Compendium 12.4.1): a last line is not accepted
  when the previous line was one, nor when HSYNC is active at C0 = 0.
- **VSYNC**: starts at the line where C4 becomes R7, 16 HSYNC ends long.
- **Cursor**: on between line R10 and line R11 of the row at MA = R14:R15;
  R10 bits 6-5: 00 on, 01 off, 10 blink every 8 fields, 11 every 16 fields,
  toggled at VSYNC start. The CGA also blinks it (section 6.3).
- **Interlace**: R8 = 01 (sync) and 11 (sync and video) with the half-line
  field and RA built from the field parity, as MartyPC. (On a CGA the
  monitor sync logic defeats real interlace; not tried here.)
- **Light pen**: R16/R17 = the current MA when the latch is set.
- **Skew**: the Motorola 6845 has none.

The memory address is 14 bits (the chip's MA0-MA13); MartyPC keeps a u16 and
an 8-bit row counter, so the two differ only when MA passes 0x3FFF or C4
passes 127 within a frame.

## 4. Wait states (IOCHRDY)

**Source:** MartyPC `devices/cga/mmio.rs` (`get_read_wait`,
`get_write_wait`) and `mod.rs` (`WAIT_TABLE`), applied by the CPU in
`cpu_808x/cycle.rs` at T2 and converted in `bus/memory.rs` /
`bus/mod.rs`:

```
phase = (CGA ticks at the end of T2 + 1) & 15
ticks = WAIT_TABLE[phase] = 14 13 12 11 10 9 24 23 22 21 20 19 18 17 16 15
Tw    = ceil(ticks / 3)       = 5 5 4 4 4 3 8 8 8 7 7 7 6 6 6 5
```

The same table for reads and writes. Read as a rule: **the access ends at
the CGA's CPU slot, the instant the lchar phase becomes 14, and needs at
least 9 ticks after the phase reference** (phase + table = 14 or 30 for every
entry). With D = slot - (end of T2) in ticks (10 to 25), Tw = ceil((D - 1) /
3): the last T3/Tw is the one whose start is at most 1 tick after the slot
and at most 1 tick before it, i.e. the slot falls between 1 tick before that
state and 1 tick into it.

**The board side** (doc/architecture.md section 3): `xt_board.sv` samples
IOCHRDY on `rdy_ce`, 1 clk before the rising CLK edge that ends a state, and
biu88 decides at that edge whether the next T3/Tw is the last. In the card's
time that sample sees the state after the dot update 1 tick before the edge,
so a state is the last one when IOCHRDY was high 1 tick before it began. For
MartyPC's count IOCHRDY must therefore go high **2 ticks before the slot**
(lchar phase 12).

**Implementation** (`cga_card.sv`, "CPU memory access"): when the card sees
MEMR or MEMW fall in the B8000-BFFFF window it pulls `isa_ready` low and
counts dot ticks (`el`). `isa_ready` goes high at the first instant with
`dc = 12` and at least `LEAD + 7` ticks since the strobe was seen (`rel_due`,
then held in `rel`); the access itself (VRAM write, snow capture) happens 2
ticks later at the slot, `dc = 14` with `LEAD + 9` ticks, still inside the
strobe (the board ends it with T4, at least 2 ticks after the slot). `LEAD`
converts the strobe's time to MartyPC's reference (end of T2 + 1 tick):
- `RD_LEAD` = 6: `xt_board.sv` asserts MEMR at the falling CLK edge in T1,
  5 ticks before the end of T2;
- `WR_LEAD` = 3: MEMW (the 8288's advanced write, AMWC) at the falling edge
  in T2, 2 ticks before its end.

If the board's command edges or its READY sample move (they are marked CAL
in `xt_board.sv`), these parameters and the release phase move with them.

**No write fallback any more.** Until 2026-10-22 the board sampled IOCHRDY
at the falling edge in T2, the edge where MEMW starts, so a write could not
wait and the card wrote at the end of the strobe when the slot had not come.
Now every strobe outlasts the slot: the CPU's (above), and the 8237's (it
samples IOCHRDY at the end of SW and ends MEMW with the step in S4, 2 ticks
later, when the slot is due). The one exception is a refresh DMA while the
CPU waits: the board grants HOLDA in T3/Tw and AEN takes the CPU's command
away (the 8288's AEN) until the transfer is over. The card drops the access
then (its select is gone) and starts a new one when the strobe returns; that
one writes, or captures the snow byte, at its own slot. A strobe that ends
before the slot with AEN low would lose the access, as on the real card; the
simulation stops with `$fatal` then. (The old fallback wrote at the cut and
again at the restarted access.)

**Verified** (section 9, test `waits`): reads and writes at all 16 phases,
at least 8 of each, give MartyPC's number of wait states; in `tb/sys` the
`-C` oracle checks every CPU access of a GLaBIOS boot (section 9).

**MartyPC's limit here:** the phase is computed from the CGA's tick count at
the start of the instruction plus the CPU cycles since the last data
transfer (`instr_elapsed`, reset after every transfer). Memory transfers do
not advance the CGA, so the second and later VRAM accesses of one
instruction (MOVSW, a word access = two byte transfers, a read and a write
in MOVSB) get a phase that is too early by the cycles before the first
transfer. The card computes every access from its real time. Expect
differences against MartyPC traces there; real hardware decides.

## 5. Registers and I/O decode

I/O: A9-A4 = 3Dx and AEN low (A15-A10 ignored, like the real card).

| Port | Write | Read |
|---|---|---|
| 3D0/2/4/6 | 6845 address | 0x00 |
| 3D1/3/5/7 | 6845 data | R14-R17, else 0xFF |
| 3D8 | mode (bits 5-0) | 0x00 |
| 3D9 | colour (bits 5-0) | 0x00 |
| 3DA | - | status |
| 3DB | clear light pen latch | 0x00, clears the latch |
| 3DC | set light pen latch | 0x00, sets the latch |
| 3DD-3DF | - | not driven (`isa_dsel` low) |

I/O accesses act when the strobe ends (MartyPC: at the end of the last
T3/Tw). Status: bits 7-4 = 1, bit 3 = 6845 VSYNC (all 16 lines), bit 2 =
light pen switch open, bit 1 = light pen latch, bit 0 = not display enable
(also set during VSYNC). DE and VSYNC are the 6845's, as of the last
character clock.

Memory: B8000-BFFFF, 16 KB mirrored once (A14 ignored).

**Mode register (3D8):** a write that changes between text and graphics
(graphics = bit 1 set and bit 0 clear) is held until the next start of the
6845's HSYNC, all bits together; other writes act at once. This is MartyPC's
`handle_mode_register` ("need to measure this on real hardware", its
comment). The 80-column bit switches the character clock only on an lchar
boundary.

## 6. Display

### 6.1 Sequencer

`dc` counts dots modulo 16 (one lchar). In 80-column text the character
clock is every 8 dots (hchar), otherwise every 16. At each character clock
the 6845 steps; in the next clk the card:
- applies a pending text/graphics mode change if the 6845's HSYNC just
  started;
- on lchar boundaries, updates the card syncs: card HSYNC = 6845 HSYNC,
  card VSYNC = 6845 VSYNC during its first 3 lines (MartyPC
  `calculate_blanking`; the CGA gates the 16-line VSYNC to 3 for the monitor);
- fetches from video RAM: character and attribute at (MA & 0x1FFF) x 2,
  graphics bytes at ((MA & 0xFFF) | (RA0 << 12)) x 2, and the glyph row
  (character ROM at char x 8 + RA2-0, RA as of the character clock: the
  real card loads the ROM output into its shift register there).

The fetched data are shown during the next character period, like MartyPC's
`set_char_addr` followed by drawing.

### 6.2 Dots

Each dot is computed with the registers as they are at the end of the dot (a
mode or colour write acts from the next dot on). In 40-column and graphics
modes dots come in pairs (the 7 MHz pixel), computed at the end of the
pair.

Inside the display area (6845 DE):

| Mode | Dot |
|---|---|
| text (bit 1 clear) | cursor: foreground; video off (bit 3 clear): 0; blinking char in the off phase: background; else glyph bit ? fg : bg |
| 320x200 (bit 1, bit 4 clear) | pixel 0: colour register bits 3-0; 1-3: palette (bit 5: green/red/brown or cyan/magenta/white; with bit 2: red/cyan/white; colour bit 4: intense); video off: colour register bits 3-0 |
| 640x200 (bit 4) | 1: colour register bits 3-0, 0: black; video off: black |
| 80-col clock + graphics, bit 4 clear | border colour (MartyPC) |
| 80-col clock + 640x200 | 8 dots per hchar from the first byte (MartyPC) |

Text attributes: foreground bits 3-0; background bits 7-4, or 6-4 with blink
enabled (mode bit 5), where bit 7 blinks the character.

Outside the display area: black during the card HSYNC or VSYNC, else the
border colour (colour register bits 3-0; black in 640x200).

### 6.3 Blink and cursor

The CGA divides its VSYNC: the cursor toggles every 8 fields, blinking
characters every 16. The cursor shows when the 6845 says so and the CGA's
cursor phase is on (with R10 = 10/11 this gives MartyPC's on-off-off
patterns). Blinking characters are not blanked in the cell with the
6845's cursor (U28 on the CGA, MartyPC `is_blink_enabled`).

### 6.4 Snow

In 80-column text mode the CPU slot takes the display's memory cycle: the
byte of the CPU access (written or read) is shown as character and attribute
of the first odd hchar (lchar phase 8) after the slot. `SNOW = 0` turns it
off. This is a model, not a measurement: MartyPC puts snow on odd hchars too
but with a stale time stamp (its VRAM accesses do not advance the CGA) and
shows (old byte, written byte) for writes and (byte, byte ^ 0xAA) for reads;
its snow is off by default.

### 6.5 Character ROM

8 KB, the layout of IBM's character ROM (5788005, 2364): the normal 8x8
font at 0x1800, the thin 8x8 font at 0x1000 (byte = char x 8 + row; the
MDA font at 0x0000-0x0FFF is not used). The glue loads the user's ROM image
unchanged through `font_we/font_addr/font_data` (one byte per clk, any time;
a 2 KB 8x8-only dump goes to 0x1800). `font_thin` = jumper P3. No IBM
content is in this repository.

### 6.6 Video outputs

`vid_*` change once per dot, one clk before `ce_14m` (so `vid_ce = ce_14m`
in `pc_system` samples them stably), three dots after the 6845's state.
- `vid_rgbi` = {I, R, G, B}; colour 6 is RGBI 0110, the monitor makes it
  brown.
- `vid_hsync`, `vid_vsync`: the card syncs of 6.1, active high (the RGBI
  monitor's sync inputs in MartyPC's model). A standard mode gives 912
  dots x 262 lines, 59.92 Hz.
- `vid_hblank`, `vid_vblank`: a monitor-like visible window, counted from
  the start of `vid_hsync` (dots) and `vid_vsync` (lines): dots `AP_X` to
  `AP_X + AP_W - 1`, lines `AP_Y` to `AP_Y + AP_H - 1`. The default is
  MartyPC's "Full" aperture, 768 x 245 (the whole picture of *Area 5150*);
  MartyPC's "Accurate" is 704 x 224 at 160/26, "Cropped" 640 x 200 at
  192/38. Without HSYNC/VSYNC the counters stop and everything is blanked.
  There is no monitor PLL: a mode with odd sync timing moves the window with
  the syncs.

## 7. Composite (raw signals only)

For a later NTSC composite model (*8088 MPH*'s colours) the card exports,
aligned with `vid_rgbi`:
- `comp_cphase[1:0]`: colour carrier phase of the dot = dot index mod 4
  within the lchar. The carrier is 14.318/4 = 3.58 MHz from the same clock,
  so the relation is fixed; whether a real card always powers up with this
  4:16 alignment is not verified, a composite model should take an offset.
- `comp_hsync`: the CGA's composite HSYNC, lchars 2-5 after the 6845's
  HSYNC began (needs an HSYNC width of at least 6);
- `comp_burst`: lchars 7-8, not during VSYNC, not with mode bit 2 (the
  "black and white" bit kills the burst);
- `comp_vsync`: 3 lines, starting at the composite trigger of the first line
  in the 6845's VSYNC;
- `comp_bw`, `comp_mode`.

The composite sync/burst counter structure follows the description of the
IBM CGA circuit in Graphics Gremlin's `cga_composite.v` (Eric Schlaepfer,
CC BY-SA 4.0; behaviour only, no code taken).

**Old vs. new CGA:** the two board revisions differ only in the composite
output. The old CGA (1981) forms composite luminance from the intensity bit
and the chroma signal; the new CGA (1983 on) adds resistors so that R, G
and B also contribute, which changes the luminance of colours 1-6 and the
artefact colours *8088 MPH* uses (it has a setting for each). RGBI output is
identical. A composite decoder needs a parameter for this; the card's raw
signals are the same for both.

## 8. Differences

### 8.1 Deliberate differences from MartyPC

Where MartyPC is inconsistent or an emulator shortcut, the card does what
the hardware does, as far as known (the C++ model of section 9 does the
same, marked DEV):
- **Character clock at reset**: MartyPC starts with the 80-column clock
  whatever the mode (its default divisor 1) until the 80-column bit changes;
  the card follows the mode.
- **Graphics bytes** are fetched at the character clock; MartyPC reads VRAM
  while drawing. Differs only when the CPU writes the byte being displayed.
- **Glyph row** taken with RA at the character clock; MartyPC uses the
  6845's RA while drawing, which differs when an R8 (interlace) write changes
  RA in the middle of a character (found by the `crtc` test).
- **Drawing rules**: MartyPC has two drawing paths (whole characters, and
  single dots while catching up to an I/O access) that differ in corner
  cases. The card follows the character path everywhere: the cursor shows
  with video disabled; 80-column clock with graphics shows the border colour;
  blanking uses the card syncs (not the 6845's).
- **Blink counters** count the card's VSYNC; MartyPC counts the monitor
  model's vertical flybacks.
- **Snow** (6.4), **register widths** (section 3), **5-bit 6845 address
  register**.
- **3D6/3D7** mirror the 6845 (A2, A1 not decoded, as MartyPC's own comment
  says); MartyPC does not map them.
- **Cursor at reset**: R10 = 0 means "cursor on, no blink"; MartyPC starts
  with the cursor disabled until R10 is written.

### 8.2 Known or possible differences from real hardware

- The mode-register deferral (section 5) and the snow position are
  MartyPC-derived assumptions, not measurements.
- The 6845 model is MartyPC's: the start address is latched at frame start
  only, and the cursor/last-line rules come from the Amstrad CPC
  documentation of other 6845 variants.
- `vid_hblank/vid_vblank` are a window, not a monitor (no flywheel, no
  overscan-dependent sync behaviour; MartyPC models a 15 kHz monitor's PLL
  in `FifteenHertzMonitor`).
- The CPU-CGA phase after reset is fixed by parameters, on a real PC it is
  random per power-on.
- Composite output not done.

## 9. Verification (`tb/cga`)

`make -C tb/cga run` (2-3 minutes) builds the card with Verilator, builds a
test font from GLaBIOS (outside the repository: VileR's 8x8 glyphs, CC BY-SA
4.0, chars 80-FF inverted, a thinned copy as the thin font), runs all tests
and writes images to `~/pcxt-work/cga/`. `python3 tb/cga/mut.py` runs the
mutant set.

The testbench drives the card bus with a model of `xt_board.sv`'s bus
timing and biu88's READY rule: `pc_clocks` enables (2 clk per tick, 6 per
CPU clock), 8288 command edges (ending at the edge where T4 begins), the card
bus's next-clk values, IOCHRDY sampled on `rdy_ce` (1 clk before the step), the next T3/Tw's
lastness decided at the step from it, one wait state on every I/O cycle. Next to the card runs
`cga_model.h`, a C++ transliteration of MartyPC's CGA and 6845 written from
the Rust sources (not from the HDL), ticked at the board's 14.318 MHz
instants; I/O accesses act on it at the end of the CPU bus cycle, VRAM
accesses at the slot MartyPC's table gives. The card's lchar phase is checked
against the model at every tick.

| Test | What | Result |
|---|---|---|
| `waits` | a sweep of 256 reads and writes over the 16 phases, then random gaps until every phase has at least 8 reads and 8 writes (416 accesses): wait states vs. `WAIT_TABLE` | all equal (the card of 2026-10-21, which released at the slot, gives one wait more at 11 of the 16 phases with the board rule of 2026-10-22: 370 of 544 accesses differ) |
| `mode0`-`mode6` | IBM BIOS mode set (6845 tables from the IBM PC/XT BIOS `VIDEO_PARMS`, also in GLaBIOS `INT_1D`; mode bytes 2C 28 2D 29 2A 2E 1E; colour 30/3F), VRAM filled over the bus, 2 frames dot by dot (colour, HSYNC, VSYNC), line and frame period | all equal, 912 dots, 238,944 dots = 262 lines |
| `status` | 3DA read back-to-back for one frame, each read vs. the model; bit 3 / bit 0 fractions vs. 16/262 and 1 - (640 x 200)/(912 x 262); then a frame with VSYNC inside the displayed rows | 31,872 reads equal |
| `torture` | 4 runs x 5 frames (modes 3 and 4): ~1,900 random writes each to all 6845 registers, 3D8, 3D9, 3DB/3DC, reads of R14-R17 and 3DA, at random times | ~4.8 M dots and ~8,000 reads equal |
| `crtc` | 4 runs, 6845 geometries of a few rows and lines, ~4,200 random register writes each (R4 also set to the current row), 3DA after each | ~2.9 M dots and ~17,000 reads equal |
| `cursor` | cursor lines wrapping across rows and through VTA (R10 > R11), all four R10 modes | 2.9 M dots equal |
| `snow` | 2 frames of 80-column text with random VRAM writes | dot-exact |
| `blink` | 34 frames mode 3 with blinking characters and cursor | dot-exact |
| `thin` | thin font, mode 1 | dot-exact |

Mutants (`mut.py`, 27): each breaks one behaviour (wait lead, release phase and lead, slot,
`CE_DELAY` 2 and 7, the card HSYNC alignment, the glyph row latch, the 3-line VSYNC, status bits, pixel
pairs, the 640 bit order, palettes, the mode deferral, the clock switch, blink
rate, snow position, thin font, and in the 6845 the VSYNC length, HSYNC
width 0, last-line management, VTA, cursor end in VTA, start-address latch,
light pen). All are killed. The first mutant run found three holes, now
closed: the 34-frame blink test compared only the last frames, and the
status and 6845 tests never had VSYNC inside the display, a repeated last
line, or a cursor running through VTA.

What this shows: the HDL does what the C++ model does, at every dot and every
bus access, for these stimuli. Both are written from MartyPC, so a
misreading of MartyPC common to both would not show; the wait-state table is
compared with MartyPC's numbers directly. Comparison with MartyPC itself
(traces of a real program) belongs to `tb/sys` (architecture.md section 5).

**In the system** (`tb/sys`, `sys_run -C`): every CPU memory cycle in
B8000-BFFFF is checked against MartyPC's count from the card's phase at the
end of T2, with the real `xt_board.sv` and `biu88.v` (cycles stretched by a
refresh DMA are counted apart). GLaBIOS 0.4.2 (4 s): 13,371 writes, all
equal, no reads; `tb/sys/cgawait_rom.py` (a test ROM with reads and writes
at pseudo-random delays): 2,001 reads and 2,001 writes over all 16 phases,
all equal.

## 10. For the integrator

- **pc_system ports**: the instance in `pc_system.sv` must connect
  `font_we/font_addr/font_data/font_thin` (new `pc_system` ports for the
  glue, architecture.md section 4) and tie `lpen_trig`/`lpen_sw` to 0;
  `comp_*` stay open until there is a composite model.
- **Font**: QNICE loads the user's 8 KB IBM character ROM (or a 2 KB 8x8 font
  at 0x1800). Until then text modes show background colour only.
- **IOCHRDY**: `isa_ready` goes into the board's READY logic as
  `xt_board.sv` does (`rdy_sync` on `rdy_ce`). Keep the command edges and the
  sample, or change `RD_LEAD`/`WR_LEAD` and the release phase with them
  (section 4).
- **CPU-CGA phase**: `DC_RESET` and `pc_clocks`' `PHASE` (section 2).
- `tb/sys` reads `u_cga.vram` hierarchically; the card keeps that array
  (16384 x 8, byte = offset in B8000), so
  `make CGA="../../rtl/video/cga/cga_crtc.sv ../../rtl/video/cga/cga_card.sv"`
  builds the system simulation with the real card (done 2026-10-21: GLaBIOS
  boots; no font there yet).
