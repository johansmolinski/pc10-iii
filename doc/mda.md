# IBM MDA and Hercules card (`rtl/video/mda/`)

Status 2026-10-22: the display part of the IBM Monochrome Display and
Printer Adapter, built from IBM's logic diagrams, plus a Hercules Graphics
Card mode. Verified in simulation against a C++ model of the same reading
(section 9). GLaBIOS boots on it in `tb/sys`. Not on hardware yet. The
printer port of the real card is not built.

## 1. Files and ports

| File | Contents |
|---|---|
| `rtl/video/mda/mda_card.sv` | the card: dot clock, character counter, CPU slot, registers, video RAM, character ROM, attribute logic, outputs |
| `rtl/video/cga/cga_crtc.sv` | the MC6845, shared with the CGA, unchanged |
| `tb/mda/` | testbench (section 9) |

`mda_card` has the card-bus ports of `doc/architecture.md` section 3 that
the MDA uses (no IRQ, no DRQ: the printer's IRQ7 is not built), and:

| Port | Use |
|---|---|
| `cga_fitted` | Hercules: a CGA is in the machine, B8000-BFFFF belongs to it (section 7) |
| `font_we`, `font_addr[12:0]`, `font_data` | character ROM load port, the same 8 KB image as the CGA's (section 5) |
| `vid_ce` | one pulse per dot, in the middle of the dot |
| `vid_video`, `vid_intens` | the monitor's two video inputs (section 6) |
| `vid_hsync`, `vid_vsync` | horizontal and vertical drive, active high |
| `vid_hblank`, `vid_vblank` | a display window counted from the syncs |

Parameters: `HERC` (0 = MDA, 1 = Hercules), `DOT_INC`/`DOT_MOD` (the dot
clock, section 2), `HRES_STOP` (section 3.5), `AP_X/AP_W/AP_Y/AP_H`
(144/738/16/354, the window).

## 2. The dot clock

The MDA has its own 16.257 MHz crystal (the Hercules card 16.000 MHz),
asynchronous to the PC's 14.318 MHz. The core has one clock,
`clk` = 100.2273 MHz = 2205/22 MHz, and 16.257 MHz is not a divisor of it
(6.165 clk per dot).

**Choice:** a fractional accumulator inside the card, on `clk`. Each clk it
adds `DOT_INC`; when it passes `DOT_MOD` that clk is a rising dot clock
edge; when it passes `DOT_MOD`/2 it is a falling edge.

| Card | Dot clock | `DOT_INC` / `DOT_MOD` | clk per dot |
|---|---|---|---|
| MDA | 16.257000 MHz | 59609 / 367500 (= 16.257 x 22 / 2205) | 6.165 |
| Hercules | 16.000000 MHz | 704 / 4410 (= 16 x 22 / 2205) | 6.264 |

- The average frequency is exact (no drift: 367500 clk give exactly
  59609 dots).
- Each dot lasts 6 or 7 clk (59.9 or 69.8 ns instead of 61.5 ns): a jitter
  of at most one clk (10 ns) on each edge. Inside the card this changes
  nothing, because the card's logic only counts edges. On the video output
  it is a 1-clk uncertainty of the dot edges, which the shell's scaler
  removes anyway (it samples the dots at `vid_ce`).
- The CPU side stays exact on `clk`: the board samples IOCHRDY at its
  `cpu_fall` as the real 8284 samples the asynchronous card. Because the
  ratio is not periodic over a short time (the pattern repeats only after
  367500 clk), the dot phase seen by the CPU walks through all values as on
  a real PC.
- A separate clock domain (an MMCM at 16.257 MHz) was not taken: the MMCM
  cannot make 16.257 MHz exactly from 100 MHz either, and it would need
  clock-domain crossings for the bus and the VRAM. A fractional enable
  keeps the card in the PC's clock domain like every other card.

The accumulator starts at 0 with reset, so the CPU-to-MDA phase after reset
is fixed. On a real PC it is random.

## 3. The card from the logic diagrams

Source: IBM "Monochrome Display and Printer Adapter" Technical Reference
(6361511), logic diagram sheets 1-10. A scan is at minuszerodegrees.net
(`OA - IBM Monochrome Display and Printer Adapter.pdf`); it is not in this
repository. The chip numbers below are IBM's.

### 3.1 Character timing (sheet 3)

- U24 (74LS153) selects the dot clock: the 16.257 MHz oscillator when mode
  bit 0 (high resolution) is set, else TEST OSC (not connected). Its other
  half makes ROM A11 = RA3.
- U1 (74LS174) is a 9-state counter clocked by the dot clock: five stages,
  stage 1 fed with NOR(4Q, 5Q). States (Q1..Q5): 00000, 10000, 11000,
  11100, 11110, 01111, 00111, 00011, 00001.
- U5 (74LS112) delays 5Q by half a dot (falling edge). The character clock
  CCLK = 5Q OR 5Q-delayed: high for 4.5 dots, low for 4.5.
- The 6845's CLK is -CCLK, so it steps when CCLK rises. In the HDL, `ph` 0
  is the dot that starts with that edge (the state 01111).

### 3.2 Display pipeline (sheets 2, 3, 5, 7, 10)

- During CCLK low the RAM is addressed by the 6845 (MA0-MA10: 2 K words,
  character code and attribute in two 2114 banks of 2 KB).
- When CCLK rises: U34 latches the character code, U31 the attribute (the
  word at the address the 6845 had), and the 6845 steps. In the same edge
  (Q5) U30 takes U31's old attribute and U29 the decoded attribute of the
  character before (fg/bg decoders U48/U49, underline decoder U47 with the
  current RA, and the 9th dot). The shift register U32 (74LS166) is loaded
  with the glyph row of that character at the end of the dot before, and
  shifts it out MSB first; the 9th dot is the serial input.
- U55 (74LS174) samples the 6845's DISPEN and CURSOR twice (two
  characters) and HSYNC and VSYNC once when CCLK rises; U101 adds one more
  character to HSYNC (`+HSYNC DLY` = HSYNC delayed one or two characters).
- So the character the 6845 addressed in character period k is shown in
  period k+2 with DISPEN and CURSOR of period k, while the syncs are one
  period behind the 6845 (and HSYNC one period longer).
- U101 (74S74) registers the video dot on the dot clock: `+VIDEO` is one
  dot late. The intensity output is not registered on the card (the HDL
  registers it too, so both are aligned; a 1-dot difference to the real
  card).

### 3.3 Attributes (sheet 5)

With fg = attribute bits 2-0, bg = bits 6-4:

| Signal | Rule |
|---|---|
| no display | fg = 000 and bg = 000 (00, 08, 80, 88) |
| reverse | fg = 000 and bg = 111 (70, 78, F0, F8) |
| underline | fg = 001 and row 12 (all 9 dots) |
| hidden (blink) | blink phase and bit 7 and mode bit 5 and not the cursor cell |
| cursor | 6845 CURSOR (delayed) and the card's cursor blink phase |

```
dots   = glyph dot OR underline, unless "no display" or "hidden"
alpha  = cursor OR dots                                   (+ALPHA DOTS)
video  = alpha XOR reverse                                (+B&W VIDEO)
intens = alpha ? bit 3 : (bit 7 AND NOT mode bit 5)       (U63, U46)
```

Both outputs are 0 outside the display (DISPEN delayed).
- Mode bit 3 (video enable) clears U31, so every character becomes
  attribute 00 ("no display"); the cursor still shows.
- With blink disabled (mode bit 5 clear) attribute bit 7 is a background
  intensity: 0xF0 gives a bright background, 0x80 a "dark" cell (intensity
  without video).
- The 9th dot (U42/U26 on sheet 7): bit 0 of the glyph row for characters
  C0-DF, else 0.

### 3.4 Blink (sheet 5)

U28 (74LS393) counts the end of each vertical sync: bit 3 is the cursor
blink (16 frames per cycle), the next counter's bit 0 the character blink
(32 frames per cycle). Reset clears both. The 6845's own cursor blink
(R10 bits 6-5) works on top.

### 3.5 Mode register, status, decode (sheets 4, 7)

- 3B8 (U58, 74LS175): bits 0 (high resolution), 2 (unused output), 3
  (video enable), 5 (blink). Latched at the end of the strobe; cleared by
  reset. Without bit 0 there is no dot clock: the 6845 and the CPU slot
  stop, and the next VRAM or 6845 access waits forever (IBM: "the system
  unit's microprocessor will stop running"). `HRES_STOP` = 0 turns this off
  (default: on for the MDA, off for the Hercules card).
- 3BA status (U60): bit 0 = `+HSYNC DLY`, bit 3 = `+VIDEO` (U101), bits
  1-2 = 0. Bits 7-4 are not driven on the MDA; the card returns 1s there
  (an undriven XT bus reads high).
- U45: horizontal drive goes to the monitor only after video has been
  enabled once since reset (protects the 5151).
- I/O decode: A9-A4 = 3Bx with AEN low; A15-A10 ignored. 3B0-3B7 = 6845
  (A0: index/data; reads of the index port give FF). 3B8 mode, 3BA status.
  3B9, 3BB not used. 3BC-3BE are the printer port: not built.
- Memory decode: A19-A15 = B0000-B7FFF with MEMR or MEMW (no AEN), 4 KB
  mirrored eight times.

## 4. CPU access and wait states

### 4.1 The slot (sheet 3: U3, U4, U5, U26, U36)

A request is a VRAM access (-CPU MSEL) or a 6845 access (6845 chip select
and any I/O strobe). 3B8-3BF do not request.

1. U4a samples the request at the rising edge of 4Q (the start of the last
   dot of a character, `ph` 8).
2. If it was there, the CPU owns the RAM address during the next CCLK-high
   half (U26: +CACS CCLK); a write gets -WE (U6) in that half.
3. U4b sets XACK when CCLK falls (the middle of `ph` 4); IOCHRDY (U36,
   driven only while the request is there) goes high.
4. When the strobe ends both flip-flops are preset again: one access per
   request.

So IOCHRDY rises 5.5 to 14.5 dots (338 to 892 ns) after the strobe. The
MDA has no snow: the display and the CPU have separate halves of each
character.

### 4.2 Resulting wait states

The board (`xt_board.sv`) asserts MEMR and IOR at the falling CLK edge in
T1, MEMW and IOW at the falling edge in T2, and synchronizes IOCHRDY at each
falling CLK edge. Since commit 8bf11db the BIU (`biu88.v`) samples READY as
T3 and each Tw begin: the falling edge *before* a state decides whether it
is the last. Every CPU I/O cycle gets one extra wait from the board. That
gives (measured in `tb/mda`, test `waits`, 3,000 accesses; the same in a
`tb/sys` run of a test ROM):

| Access | Wait states | Mean |
|---|---|---|
| VRAM read (MEMR) | 1-4 | 2.4 |
| VRAM write (MEMW) | 0 | 0 |
| 6845 read (IOR, incl. the board's 1) | 1-4 | 2.5 |
| 6845 write (IOW, incl. the board's 1) | 2-5 | 3.6 |
| 3BA read | 1 (the board's) | 1.0 |

Reads fit IBM's "at least one wait state will be inserted": IOCHRDY is never
high at the falling edge in T2 (the request is at most 209 ns old there).

**Writes get no wait states with this board.** MEMW goes low at the
falling edge in T2, and that same edge already decides whether T3 is the
last state; IOCHRDY cannot be low there for any card that starts its wait
from MEMW. On the MDA the write would then be lost (the RAM write enable
needs the slot while MEMW is low), and GLaBIOS showed a blank screen. The
card therefore writes at the end of the strobe when the strobe ends before
the slot (`wr_early`, the same fallback the CGA has). With a board that
lets a write strobe insert waits (a real PC does: the CGA's write waits in
MartyPC's table were measured on hardware), the write happens in the slot
and the fallback is never used. **This is a board issue to settle in
`xt_board.sv`/`biu88.v`** (the CGA's writes are affected the same way; its
TB still models the older "READY at the end of T3" sampling).

### 4.3 MartyPC

MartyPC's MDA (`devices/mda/mmio.rs`) uses the CGA's `WAIT_TABLE`, indexed
with the MDA's own clock count plus the CPU's elapsed system ticks, and
converts the result as system ticks: 3-8 wait states, mean about 5.8 for the
same accesses. That is the CGA's slot logic (16 ticks of 14.318 MHz), not
the MDA's (one slot per 9 dots of 16.257 MHz). The MDA's IO ports get no
waits in MartyPC. The card follows the schematic; the TB prints MartyPC's
numbers for comparison only.

## 5. Character ROM

The MDA's ROM is a 8K x 8 MK36000 (sheet 10, U33), the same part number
and content as the CGA's 5788005:
- A2-A0 = RA2-RA0, A10-A3 = character code (U34), A11 = RA3 (U24), A12 =
  the test jumper (0).
- So the MDA font is in 0x0000-0x0FFF: rows 0-7 at char x 8 + row, rows
  8-13 at 0x0800 + char x 8 + row - 8 (rows 14-15 there too, used only with
  R9 > 13). The CGA fonts are at 0x1000 (thin) and 0x1800.
- D7 is the leftmost dot (U32 loads D7 into H and shifts H out first).

The card keeps a 4 KB copy written through the load port (`font_addr` <
0x1000); the CGA keeps its own. One 8 KB load from the glue serves both.

## 6. Video outputs

- `vid_video` and `vid_intens` are the monitor's +VIDEO and +INTENSITY.
  The IBM 5151 shows video with intensity as bright, video alone as
  normal. Intensity without video (attributes 78/F8 inside the glyph, 80/88
  and the background of 8x attributes with blink off) is the open case:
  MartyPC shows it as a dark level for 78/F8. Suggested levels: 00 black,
  01 dark (about 1/4), 10 normal (2/3), 11 bright.
- `vid_hsync`/`vid_vsync`: horizontal and vertical drive (the connector's
  vertical is active low; here both are active high).
- Text mode (BIOS mode 7): 882 dots (98 x 9) per line, 370 lines per frame,
  18.432 kHz, 49.82 Hz. The text (720 x 350) is at dots 154-873 from the
  start of HSYNC and lines 20-369 from the start of VSYNC. HSYNC lasts 144
  dots, VSYNC 16 lines.
- Hercules graphics: 864 dots (54 x 16) per line, 370 lines, 18.52 kHz,
  50.05 Hz (16 MHz); the picture (720 x 348) at dots 144-863, lines 22-369.
  Hercules text: 882 x 370 at 16 MHz = 18.14 kHz, 49.03 Hz.
- `vid_hblank`/`vid_vblank`: a window from the sync starts, dots `AP_X` to
  `AP_X + AP_W - 1` and lines `AP_Y` to `AP_Y + AP_H - 1`; the default
  738 x 354 at 144/16 holds both pictures with a margin (in Hercules
  graphics the line ends at 864, so the window is 720 wide there).
- Outputs change on the rising dot clock edge; `vid_ce` is the falling
  edge, half a dot later, where they are stable.

## 7. Hercules

From MartyPC (`devices/mda/`) and the HGC's documented behaviour:
- 64 KB at B0000-BFFFF in two 32 KB pages; B0000-B7FFF always,
  B8000-BFFFF when 3BF bit 1 is set.
- 3BF (configuration switch, write only, cleared by reset): bit 0 allows
  graphics (3B8 bit 1 keeps its old value otherwise), bit 1 allows page 2
  (3B8 bit 7 likewise) and maps B8000-BFFFF.
- 3B8 bit 1: graphics; bit 7: display page (graphics only).
- Graphics: 16-dot characters, two bytes per 6845 address at
  (RA1-0 x 0x2000 + MA x 2) + page x 0x8000, MSB first; video only, no
  intensity, no cursor. 720 x 348 with the 6845 table 35 2D 2E 07 5B 02 57
  57 02 03.
- 3BA bit 7: 0 during vertical sync (the HGC detection that GLaBIOS does);
  bits 6-4 = 0 (the original HGC; HGC+ and InColor have IDs there).
- Assumptions, no schematic: the HGC's CPU slot is taken to be the MDA's
  (one per character, also with 16-dot characters); the dot clock is not
  stopped by 3B8 bit 0; text addressing is the MDA's 4 KB (MartyPC).
- No light pen.

**Coexistence with a CGA:** both can be fitted (MDA at B0000/3Bx, CGA at
B8000/3Dx). A Hercules card with page 2 enabled would collide with the CGA
at B8000-BFFFF; the real card's "half" mode (3BF bit 1 clear) is the user's
answer to that. Here the rule is fixed by `cga_fitted`: with a CGA in the
machine the Hercules card never answers at B8000-BFFFF (page 2 can still be
displayed but the CPU cannot reach it). MartyPC gives the CGA priority
there too.

## 8. Integration (`pc_system`)

- Parameters `CGA_FIT` (default 1) and `MDA_FIT` (0 none, default; 1 MDA;
  2 Hercules). A card that is not fitted drives nothing on the bus and is
  removed by synthesis.
- New outputs `mda_ce`, `mda_video`, `mda_intens`, `mda_hsync`,
  `mda_vsync`, `mda_hblank`, `mda_vblank`; the font port is shared.
- **DIP switches (the glue):** SW1 switches 5-6 select the primary display;
  `dip_sw1` bits 5-4 as the 8255 reads them: 11 = monochrome 80x25 (MDA or
  Hercules), 10 = CGA 80x25, 01 = CGA 40x25, 00 = none/EGA. With both cards
  fitted the BIOS initializes the one the switches name. The glue sets
  bits 5-4 = 11 when the MDA is the selected display.

## 9. Verification (`tb/mda`)

`make -C tb/mda run` builds the card twice (MDA, Hercules), builds a test
font (GLaBIOS's 8x8 glyphs stretched to 14 rows for the MDA part, the
CGA part as in `tb/cga`; no IBM content) and runs all tests; images go to
`~/pcxt-work/mda/`. `python3 tb/mda/mut.py` runs the mutants.

The bus is a model of `xt_board.sv`'s timing (as in `tb/cga`). Next to the
card runs `mda_model.h`, a C++ model written from the schematic reading
above, stepped on the same clk with the same accumulator; its 6845 is
MartyPC's (`Crtc6845` from `tb/cga/cga_model.h`). Compared: IOCHRDY at
every clk, every dot (video, intensity, both syncs, both window signals),
every read.

| Test | What | Result |
|---|---|---|
| `waits` | 3,000 random VRAM reads/writes (all of B0000-B7FFF), 6845 and 3BA accesses | IOCHRDY equal at every clk; waits as in section 4.2; 2,031 reads equal |
| `text` | IBM BIOS mode 7 (3B8 = 01, 6845 table 61 50 52 0F 19 06 19 19 02 0D 0B 0C, 3B8 = 29), all 256 characters, attributes 07 0F 01 09 70 78 87 F0 00 7F 8F 71, cursor; 2 frames | 654,680 dots equal; 882 dots x 370 lines; text at dots 154-873, lines 20-369 |
| `attrs` | the attribute decoder against MartyPC's `MDA_ATTR_TABLE`, blink on and off (512 cases) | equal except the 128 cases of background intensity with blink off (section 10) |
| `status` | 3BA back-to-back for one frame, half the screen lit | 19,136 reads equal; bit 0 in 16.3 % (16/98) |
| `torture` | 3 runs x 4 frames: ~2,250 random 6845, 3B8, VRAM writes and reads each (one run with HSYNC running past C0 = 0) | 3.9 M dots, ~7,800 reads equal |
| `blink` | 70 frames, then 34 frames with VSYNC at row 10 | 34 M dots equal; the picture changes every 8 frames, 4 kinds of frames |
| `hdrive` | no horizontal drive before the first video enable (U45) | 0 HSYNC dots, then 144 per line |
| `hres` | 3B8 = 28 (no high resolution), then a VRAM read | the read still waits after 20,000 clk |
| `hgc` | 3BF gating of 3B8 bits 1/7, B8000 mapping with and without a CGA, status bit 7 | as section 7; bit 7 clear in 4.3 % (16/370) |
| `hgctext` | mode 7 on the Hercules card (16 MHz) | 654,680 dots equal |
| `hgcgfx` | 720 x 348 graphics, page 0 and page 1 | 963,040 dots equal; 864 dots x 370 lines; picture at lines 22-369 |

Runtime about 3 minutes (`make -C tb/mda run`).

Mutants (`mut.py`, 34): each breaks one behaviour (slot sample and end
points, 6845 without slot, 3B8 with slot, dot clock rate, the HRES stop, the
U55 stages, the HSYNC stretch, the status bits, the horizontal drive gate,
the 9th dot, underline row, reverse, no-display, both intensities, blink
under the cursor, both blink rates, the U28 counting edge, the U101 delay,
video enable, ROM A11, bit order, the 4 KB mirror, the blink-enable bit; for
the Hercules card the 3BF gating, the CGA coexistence, status bit 7, the
row bits and the page). All are killed. The first run found a hole: the
blink counter's edge (end vs. start of VSYNC) is invisible while VSYNC is
in the blanking; the blink test now also runs with VSYNC inside the
display.

What this shows: the HDL does what the C++ model does at every clk, dot and
read. Both come from the same reading of the schematic, so a misreading
would be in both; the attribute decoder is checked against MartyPC's table
independently.

**System** (`tb/sys`, `make MDA=1`, `sys_run -m -F font -o image`):
GLaBIOS 0.4.2 8X with the MDA fitted (next to the CGA) and the
mono DIP setting (`dip_sw1` = 7D): POST sets 3B8 = 01 at 0.09 ms, mode 7
(6845 table, 3B8 = 29) at 518 ms, and the banner is on the MDA at 0.8 s
simulated (`~/pcxt-work/mda/sys_mda.png`: "GLaBIOS [.] Reboot the Past",
"(C) 2022-26 640KB Released under GPLv3", "Ver: 0.4.2-8X" in the last
row, cursor blinking). The first run showed a blank screen: the board's
write timing (section 4.2). A test ROM in `tb/sys` gave the wait states of
section 4.2 (reads 2-3, 6845 writes 2-3, VRAM writes 0) with the real
`xt_board.sv` and `biu88.v`. HGCRESULT

## 10. Differences and open points

Deliberate differences from the real card:
- a write whose strobe ends before the slot is still done, at the strobe
  end (section 4.2);
- the intensity output is registered with the video dot (section 3.2).

Deliberate differences from MartyPC:
- wait states from the schematic (section 4.3), also on 6845 accesses;
- background intensity with blink off, and "intensity without video" as
  its own level (MartyPC: no background intensity);
- the cursor is shown with video disabled (U31 is cleared, the cursor path
  is after it);
- the status bits: MDA bits 7-4 read 1 (MartyPC 0111); Hercules bit 0 is
  the delayed HSYNC like the MDA's (MartyPC: not display enable);
- blink counters count the card's VSYNC, from reset;
- Hercules: B8000-BFFFF is not mapped (not mirrored) without 3BF bit 1;
- the 6845 is the CGA's model: the start address is latched at frame start
  only (MartyPC's 6845).

Open points:
- reading 3B8 latches the floating data bus into the mode register on the
  real card (U50 decodes any I/O strobe); not modelled (MartyPC neither);
- the printer port (3BC-3BE, IRQ7) is not built;
- the dot-level phase of the shift register load against the CPU slot and
  the half-dot offsets inside a character follow from the reading above but
  are not measured;
- Hercules: no schematic was read; slot timing, status bits 6-4, light
  pen, text page addressing are assumptions (section 7);
- the 5151's response to intensity without video;
- the board's READY sampling against MEMW (section 4.2): with it, VRAM
  writes never wait.

## 11. For the shell (MEGA65 glue)

- Video: 18.43 kHz / 49.8 Hz, 882 x 370 dots per frame at 16.257 MHz; the
  visible 720 x 350 (Hercules graphics 720 x 348). A 15 kHz-style analog
  output does not apply (the 5151 is an 18 kHz TTL monitor). For HDMI the
  frame should be scaled from the `mda_hblank/mda_vblank` window; 720 x 350
  doubled vertically fits 720 x 700 in a 576p/720p frame. 49.8 Hz against a
  50 Hz HDMI mode drops or repeats a frame about every 5 s.
- Sample the dots at `mda_ce`; the dot rate is not a fixed number of clk
  (6 or 7).
- Two intensity bits per dot: map (video, intensity) to four green (or
  amber/white) levels (section 6).
- Font: the user's 8 KB IBM ROM through the existing font port; the MDA
  part is the first 4 KB.
- DIP: `dip_sw1` bits 5-4 = 11 when the MDA/Hercules is the display.
- Resources (estimate, no Vivado run yet): MDA 2 RAMB36 (4 KB VRAM, 4 KB
  font), Hercules 17 RAMB36 (64 KB VRAM + font).
