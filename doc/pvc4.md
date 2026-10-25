# The Paradise PVC4: the PC10-III's onboard video (`rtl/video/pvc4/`)

Status 2026-10-25, branch `pvc4`: the chip as a specification (sections 1-8),
the model (`rtl/video/pvc4/pvc4.sv`), its integration (`pc_system`
`PVC4_FIT`, the 230h register `rtl/system/cbm_cfg230.sv`, the shell's
`pc_system_flat`) and the tests (section 9). Not on hardware; no Vivado run.

The PC10-III has neither an IBM CGA nor an MDA: its video is a Western
Digital / Paradise Systems **PVC4** ("Paradise Video Controller", "virtually
a video card on a chip") on the main board, with 64 KB of DRAM, a 32 KB
character ROM and its own 16.257 MHz oscillator. The data sheet promises
"100% IBM CGA and MDA compatibility", Hercules, Plantronics ColorPlus and
AT&T 6300 compatibility, and "flicker-free operation in all video modes":
**no snow**. Until this branch the core showed the IBM CGA model with IBM's
snow (doc/cga.md section 6.4), which the user saw during the Commodore BIOS's
RAM count.

Facts are marked with their source; **[A]** marks an assumption, **[Q]** an
open question.

Sources:
- **DS**: *Paradise Video Controller PVC4* data sheet, Paradise Systems
  1987/1988/1989, 47 pages (scan `~/pcxt-work/docs/PVC4.pdf`, not in the
  repository). Page numbers are the sheet's own.
- **SM**: *Commodore PC10-III / PC20-III technical manual* (service manual,
  `~/pcxt-work/manual/p*.png`, not in the repository): chapter 2.2 (DIP
  switches, 2-3), chapter 5 (Autoconfig, 5-1..5-5), chapter 6 (video modes,
  6-1..6-6), the video schematic sheet 9-6 "PC10/CR VIDEO", drawing 312626
  (pages p63 and p84 of the scan, two copies of the same sheet).
- **BIOS**: the Commodore BIOS 4.41 (318085-08), disassembled for reading
  only (`~/pcxt-work/pvc4/bios.dis`, not in the repository).
- 86Box `src/video/vid_cga_colorplus.c` (GPL, read for the Plantronics
  colour rules only; 86Box has no PVC4 and no PC10-III machine).

## 1. The chip

100-pin flat pack, 2 um CMOS, 6700 gates (DS 1). It contains a 6845-like
CRTC, the CGA/MDA/Hercules/Plantronics/AT&T attribute and pixel logic, the
DRAM controller and the bus interface with address decoding (DS 1, 6).

Pins (DS 7-9) that matter for the model:

| Pins | Function |
|---|---|
| CLOCK0, CLOCK1, CLOCK2 | video clock inputs, "14.318", "16.257", "24.000 MHz" (DS 7) |
| A0-A19, D0-D7, DIR | system bus; D through an external buffer (on the PC10-III a 74LS245, U604) |
| MEMRDN, MEMWRN, IORDN, IOWRN, AEN, RESET | bus strobes, active low; RESET active high |
| READY | "Memory access complete", 12 mA, high = ready; tri-stated after the strobe (DS 15, parameters 19, 28) |
| MA0-MA7, MD0-MD7, RAS01N, CAS0N, CAS1N, WE01N | the DRAM (multiplexed address, one or two banks) |
| CA0-CA7, CA13, RA0-RA3, CD0-CD7 | character ROM: character address, row address, data |
| RD, GR, BL, IT, MONO, HSYNC, VSYNC | video out (TTL); MONO and IT are the monochrome video and intensity |
| CMPVD, CSYNCN | composite video and composite sync (DS 4-5) |
| LPNSTN, LPNSWN | light pen strobe and switch |
| SPPIN | printer port chip select for a Paradise PPC1/PPC2 |

## 2. Registers

"X" is B in the monochrome mapping and D in the colour mapping (DS 3, 24).

| Port | R/W | Register |
|---|---|---|
| 3X0-3X7 | W/R | 6845 index (even) and data (odd) (DS 43) |
| 3X8 | R/W | mode register; two reads in succession unlock 3XA/3XB (DS 30) |
| 3D9 | W | CGA colour ("border control") register (DS 33-35) |
| 3B9 | R/W | any access sets the light pen latch (DS 35) |
| 3XA | R | status register (DS 28-29) |
| 3XA | W | Configuration register, after the unlock (DS 26-27) |
| 3XB | W | Paradise register, after the unlock; locked, any access clears the light pen latch (DS 24) |
| 3DC | R/W | any access sets the light pen latch (DS 36) |
| 3DD | W | Plantronics ColorPlus register (DS 37-38) |
| 3DE | W | AT&T / M24 register (DS 41-42) |
| 3BF | W | Hercules register (DS 39-40) |

### 2.1 The unlock (DS 3, 4, 30)

"To write to a locked register, the CPU must read the register at 3X8 twice,
then write to the target register. Note that these three I/O operations must
be consecutive. Any intervening I/O access will cause the target register to
remain locked" (DS 4), with interrupts disabled for the sequence. "Any
unlocked register is relocked after it has been written to, or if any other
PVC4 video port is accessed" (DS 30). The model counts every CPU I/O cycle
(AEN low) on the bus, at any address, as "an I/O access" **[A]** (DS 4 says
any, DS 30 says any PVC4 port; the BIOS sequence of DS 4 satisfies both). A
third read of 3X8 keeps it unlocked **[A]**.

### 2.2 Paradise register 3XB (DS 24-25)

| Bit | 1 | 0 |
|---|---|---|
| 7 | monochrome I/O mapping (3Bx) | colour mapping (3Dx) |
| 6 | Olivetti M24 monochrome monitor | M24 colour monitor |
| 5 | 9-dot alpha characters | 8-dot |
| 4 | the high-speed clock (CLOCK2) | the normal clock (CLOCK1 MDA, CLOCK0 CGA) |
| 3 | Plantronics and AT&T registers disabled | enabled |
| 2 | mode register bit 3 (video enable) works | **"flicker override": video enable forced to 1, "display is turned on"** |
| 1 | CRTC R0-R11 write protected | writable (the bit text says R0-R12, the figure R0-R11) |
| 0 | 80-column character clock forced | mode register bit 0 selects 40/80 |

Loaded at reset from the pull-ups/downs on MA7-MA0 (1 = pull-up).

### 2.3 Configuration register 3XA (DS 26-27)

| Bit | 1 | 0 |
|---|---|---|
| 7 | one bank, 64K x 8 | two banks, 2 x 16K x 8 |
| 6 | IBM CGA 200-line mode | AT&T/M24 400-line mode |
| 5 | not used | |
| 4 | CSYNCN = composite sync | CSYNCN = display enable |
| 3 | MONO pin = composite intensity (I+R+G+B) | MONO pin = monochrome video |
| 2 | border (overscan) colour enabled | disabled |
| 1-0 | printer decode: 00 3BC-3BF, 01 278-27F, 10 378-37F, 11 off (SPPIN) | |

Loaded at reset from MD7-MD0. 3XA reads the status register.

### 2.4 Status register 3XA (DS 28-29)

| Bit | Mono (3BA) | Colour (3DA) |
|---|---|---|
| 7 | 0 = vertical retrace | 1 |
| 6, 5 | 1 | 1 |
| 4 | 1 = normal IBM mode, 0 = AT&T/M24 colour mode | same |
| 3 | monochrome video data | 1 = vertical retrace |
| 2 | 1 = light pen switch off | same |
| 1 | light pen trigger set | same |
| 0 | horizontal retrace ("HSYNC, display in horizontal retrace") | 1 = border or blanking (display enable inactive) |

Mono bit 7 is the Hercules card's VSYNC bit (programs detect a Hercules card
with it); bits 6-4 read 111, not the HGC's 000 **(DS)**: a program that
checks the HGC+/InColor ID in bits 6-4 sees an unknown card.

### 2.5 Mode register 3X8 (DS 30-31)

Read/write, cleared at reset. Bit 7 Hercules display page, 6 not used, 5
blink, 4 640x200, 3 video enable, 2 B&W, 1 graphics, 0 high-resolution dot
clock (80 columns; "14 or 16 MHz", else "7 or 8 MHz"). Bit 1 can be set in
the monochrome mapping only with 3BF bit 0, bit 7 only with 3BF bit 1 (DS
39-40: "cannot be set", "alpha mode forced").

### 2.6 3D9, 3DD, 3DE, 3BF

- 3D9 (DS 33-35): the CGA's colour register; bit 4 also intensifies the
  Plantronics 640x200 foreground. "Cleared at reset" (the IBM CGA model
  starts at 30h).
- 3DD Plantronics (DS 37-38): bit 6 swaps the CPU's view of the planes
  (B8000 = plane 1, BC000 = plane 0), bit 5 640x200x4, bit 4 320x200x16 (bit
  4 wins). Cleared "by alpha mode (mode register bit 1 = 0), mono mode, or
  Plantronics disable (Paradise bit 3 = 1)".
- 3DE AT&T/M24 (DS 41-42): bit 6 underline for colour alpha ("blue on black
  gives a white underlined character"), bit 3 page select in simulated
  200-line mode, bit 2 alternate character set (ROM plane 1, the CA13
  pin), bit 0 400-line mode. Enabled only with Paradise bit 3 = 0; reset
  clears it.
- 3BF Hercules (DS 39-40): bit 0 allows graphics, bit 1 allows page 2 and
  maps B8000-BFFFF. Cleared by reset and by the colour mapping.

### 2.7 CRTC (DS 43-45)

6845-compatible, R0-R17 as the 6845 with these differences: R8 does not
exist ("supports only the non-interlace mode"); R10 has the start line and
only an on/off bit 5 (no blink-rate bit 6); R11 is the cursor end while the
CRTC is unlocked and the **underline scan line** while it is locked; R14-R15
read/write, R16-R17 read. The model uses the IBM cards' 6845
(`cga_crtc.sv`, MartyPC's) behind these differences: R8 always 0, R10 bit 6
cleared, writes to R0-R11 dropped while Paradise bit 1 is set, R11 then
loads the underline row. The underline row's reset value is not in the data
sheet; 12 (the IBM MDA's) **[A]**.

## 3. Clocks (DS 4, 7, 11, 25, 32)

Three clock inputs and a multiplexer; the clock selection table (DS 32):

| PAR4 | MR1 | PAR5 | CNF6 | PAR7 | clock |
|---|---|---|---|---|---|
| 1 | x | x | x | x | CLOCK2 |
| x | 0 | 1 | 0 | x | CLOCK2 |
| 0 | 1 | x | x | 1 | CLOCK1 |
| 0 | x | 0 | x | 1 | CLOCK1 |
| 0 | x | x | 1 | 1 | CLOCK1 |
| 0 | 1 | x | 0 | x | CLOCK1 |
| 0 | x | 0 | 0 | x | CLOCK1 |
| 0 | x | x | 1 | 0 | CLOCK0 |

Mode register bit 0 = 0 (with Paradise bit 0 = 0) divides the selected clock
by 2 (40 columns). The selected clock is also "the source for ... [the]
internal state machine" (DS 25). The DRAM timing parameters are in units of
T = "40 ns in Olivetti mode (High Speed), 60 ns in CGA or Plantronics mode,
70 ns in MDA or Hercules mode" (DS 11; the two low-speed values look
swapped: 14.318 MHz is 69.8 ns, 16.257 MHz 61.5 ns).

**On the PC10-III** (SM 9-6): CLOCK0 = the board's OSC (14.31818 MHz,
through R625), CLOCK1 = the 16.257 MHz oscillator OSC601 through the
ferrite FB602, **CLOCK2 = the same 16.257 MHz oscillator** (before the
ferrite). There is no 24 MHz oscillator on this sheet, so Paradise bit 4
changes nothing on the PC10-III. With CNF6 = 1 (section 7) the table
reduces to: colour mapping CLOCK0, mono mapping CLOCK1.

The model: the colour personality ticks on `ce_14m` (CE_DELAY 1, as
`cga_card.sv`); the mono personality on a fractional accumulator, 16.257 MHz
= 59609/105000 x 28.63636 MHz (as `mda_card.sv`), divided by 2 (every second
oscillator rise is a falling dot edge) with mode bit 0 = 0 and Paradise bit
0 = 0. The mono personality never stops its clock (the IBM MDA does without
mode bit 0; the PVC4 divides instead).

**[Q] ALPHA132.** SM 6-2 lists "ALPHA132: 132 x 43 alpha (8 x 8 cell),
monochrome, 48.7 Hz, 18.52 kHz, max. dot clock 24.000 MHz", which needs
CLOCK2 = 24 MHz (24 MHz / 18.52 kHz = 1296 dots per line = 162 8-dot
characters; 16.257 MHz gives 878). The schematic has no 24 MHz oscillator,
and the BIOS has no mode for it (no access to 3XB at all). Either another
board revision has the oscillator, or the manual describes the chip, not
the board. The model supports the mechanism (8-dot mono characters with
Paradise bit 5 = 0, any CRTC table) at 16.257 MHz; a 24 MHz CLOCK2 would be
a parameter (`M_INC`/`M_MOD` are per chip, not per clock input yet).

## 4. CPU access, wait states, no snow

The facts (DS 15-16, 22-23):
- READY goes low within 30 ns of MEMRDN or MEMWRN low (parameters 18, 25),
  stays low at most 2000 ns (17, 26), and goes high when read data is valid
  (21: data set-up to READY high 0 ns); it is tri-stated within 27 ns after
  the strobe (19, 28). Write data must be valid at most 4T after MEMWRN
  falls (14), i.e. the chip latches it later than that.
- The DRAM runs **memory sequences**: a CPU read/write (one RAS cycle with
  one CAS) followed by a display refresh page-mode read of four bytes
  ("D0 D1 D2 D3"; one bank: COL, COL+1, COL+2, COL+3) (DS 22, "Low speed, one
  RAM bank memory sequence"; DS 23 the same for two banks and high speed).
  In the two-bank low-speed diagram the CPU part is 5 T and the display part
  11 T, 16 T per sequence (the one-bank drawing is less exact, about 17 T).
- I/O reads: data valid 80 ns after IORDN (29); I/O writes need the data T
  before IOWRN rises (35). No READY on I/O: the CRTC is inside the chip.

Why there is no snow: the CPU and the display never share a memory cycle.
The IBM CGA lets the CPU take the display's cycle in 80-column text and
shows the CPU's byte instead (doc/cga.md 6.4); the PVC4 gives the CPU its own
part of every sequence and makes it wait with READY until then.

The model **[A]**, from these facts:
- a sequence is 16 video clocks in the colour personality (one per lchar of
  the 14.318 MHz clock, the IBM CGA's CPU-slot rate; four bytes per lchar
  are exactly what 80-column text and the Plantronics modes need), and two
  characters (18 dots with 9-dot characters, 16 with 8-dot) or one Hercules
  graphics character (16 dots) in the mono personality;
- the sequencer runs on the **undivided** clock in the 40-column modes too
  (in the colour personality an lchar is 16 clocks in every mode; with the
  mono clock divided by 2 a sequence is one character, 18 clocks): a
  sequencer on the divided clock would hold READY up to 2.2 us, beyond the
  data sheet's 2000 ns (a first version did, and the Commodore BIOS's video
  RAM probe, which runs before the mode register's bit 0 is set, saw up to
  13 wait states);
- the colour sequence starts when the lchar phase becomes 0, the mono one
  when CCLK rises on an even character (on every character when divided);
- MEMR/MEMW (decoded) is synchronised on the video clock: a sequence serves
  the request if the request was seen at an earlier video clock edge; the
  CPU part is `CPU_T` = 5 video clocks; at its end the write is done (the
  data was valid for more than 4T), READY goes high (read data is valid: the
  model's RAM has it all along) and stays high until the strobe ends. One
  access per strobe.
- READY is low from the first clk of the strobe (from the card bus's
  next-clk values, registered, as `cga_card.sv` REG_READY).

Resulting wait states with this board's bus timing (`tb/pvc4` test `waits`,
3,000 random accesses each; MEMR starts at the falling CLK edge in T1, MEMW
in T2, doc/architecture.md section 3):

| | Colour 80 col. | Colour 40 col. | Mono (16.257 MHz) | Mono, clock / 2 |
|---|---|---|---|---|
| reads | 1-6 Tw, mean 3.97 | 1-6, 3.90 | 1-6, 3.61 | 1-6, 3.59 |
| writes | 2-7 Tw, mean 5.20 | 2-7, 5.19 | 2-7, 4.96 | 2-7, 5.04 |
| longest READY low | 1502 ns | 1502 ns | 1502 ns | 1502 ns |

(the data sheet's limit is 2000 ns).

For comparison, the IBM CGA under MartyPC's table gives 3-8 Tw for both
(doc/cga.md section 4), the IBM MDA 1-3 reads / 2-4 writes (doc/mda.md 4.2).
**[Q]** These numbers are a model, not a measurement: the PVC4's request
synchroniser, the position of the CPU part in the sequence and the
40-column behaviour (does the state machine run on the divided clock?) are
not in the data sheet. A logic-analyser capture of READY on a PC10-III (or a
timing loop like `tb/sys/cgawait_rom.py` run on a real one) would settle it.

## 5. Display

The data sheet describes the registers, not the display pipeline. The model
takes the pipelines of this repository's IBM cards, which are verified
against MartyPC (CGA) and IBM's logic diagrams (MDA):
- **colour personality** = `cga_card.sv` (doc/cga.md sections 5-6): the same
  lchar sequencer, mode deferral, blink counters, attribute and palette
  logic, the same output timing (912 x 262, 59.92 Hz, the window 768 x 245);
- **mono personality** = `mda_card.sv` (doc/mda.md sections 3, 6, 7): the
  same character counter, two-stage pipeline, attribute decoder, blink
  counters, Hercules graphics; 882 x 370 at 16.257 MHz (18.43 kHz, 49.8 Hz).

The PVC4's own differences (all from DS unless marked):
- **flicker override** (Paradise bit 2 = 0): the display sees video enable =
  1 whatever mode register bit 3 says (colour and mono);
- **border control** (Configuration bit 2): 0 = no overscan colour;
- **Plantronics** (3DD): 320x200x16: plane 0 gives c1 c0, plane 1 c3 c2 for
  each of 4 pixels per byte, RGBI = (I, R, G, B) = (c2, c1, c0, c3) (SM 6-6);
  640x200x4: plane 0 bit = c0, plane 1 bit = c1; colour 0 is 3D9 bits 3-0,
  1-3 the CGA's 320x200 palette with 3D9 bits 4/5 and the B&W bit **[A]**
  (86Box; the data sheet calls 3D9 bit 5 "reserved" in 640 mode); planes at
  B8000 and BC000, each addressed as CGA graphics (SM 6-5);
- **9- or 8-dot characters** in the mono personality (Paradise bit 5); the
  9th dot repeats bit 0 for C0-DF as on the MDA **[A]**;
- **underline row** from R11 while locked, default 12 **[A]**;
- **no** MDA horizontal-drive gate (U45 on the IBM card) **[A]**;
- the mono clock does not stop without mode bit 0 (section 3);
- 3BA bits as section 2.4 (the IBM MDA has 1111 in bits 7-4, the HGC 0000
  in 6-4).

Not modelled: the AT&T/M24 400-line mode (3DE bit 0, CNF6 = 0) and its page
select and underline bits (3DE is stored; bit 2 drives CA13): the PC10-III
straps the chip to IBM 200-line mode (CNF6 = 1) and its monitors (CGA
15.7 kHz, MDA 18.4 kHz) cannot show 400 lines at 15/18 kHz, so the PC10-III
cannot use it (a program could set CNF6 = 0 through the unlock; the result
is undocumented). Composite video (CMPVD, CSYNCN; the PC10-III has an RCA
jack CN603 driven by Q601), the Olivetti monitor type, the light pen inputs
(tied off as on the IBM card models), the printer port enable (PPEN/SPPIN).

### 5.1 Video RAM (SM 9-6; DS 26)

Two 64K x 4 DRAMs (U605, U606): 64 KB, one bank (Configuration bit 7 = 1).
The model's physical address is B0000 + offset: mono B0000-B7FFF (32 KB,
linear, the Hercules page 0; MDA text software sees no 4 KB mirror **[A]**),
B8000-BFFFF with 3BF bit 1; colour B8000-BBFFF mirrored at BC000 (the CGA's
16 KB), or 32 KB in the Plantronics modes. So a Hercules page 1 and the
colour memory are the same RAM **[A]**. The FPGA keeps it as two 32 KB block
RAMs split by A14, so the display reads both Plantronics planes in one clk.

### 5.2 Character generator (SM 9-6, DS 1, 19)

"Supports up to four 256-character fonts with external character generator
ROM" (DS 1); the ROM is read once per character (period at least 8T,
address to data 200 ns, DS 17). The PC10-III's ROM U607 is a 27256
(32 KB). Its address lines:

| ROM | from |
|---|---|
| A0-A3 | RA0-RA3 (scan line) |
| A4-A10 | CA0-CA6 (character bits 0-6) |
| A11 | NOT DIP switch 2 (74LS04 U1): 0 = monochrome, 1 = colour |
| A12 | CA7 (character bit 7) |
| A13 | CA13 (the PVC4's alternate set, 3DE bit 2) |
| A14 | DIP switch 1 (R616 pull-up): 1 = off = USA/Europe, 0 = Scandinavian |

So the ROM holds 8 fonts of 256 characters x 16 rows: 2 national sets x 2
sets (CA13) x mono/colour; the switches pick a pair, the chip picks CA13.
A11 follows the switch, not the chip's mapping. **[Q]** whether
cbm-pc10c-char-318086-01/-02/-03 are three national versions of this 32 KB
ROM (and which is the "pc10sd" one) needs the files.

The model's font RAM is 32 KB, loaded through pc_system's font port
(`font_addr_hi` = A14-A13). `font_cbm` = 1: the Commodore layout above;
`font_cbm` = 0: an IBM 5788005 image (8 KB at 0x0000; colour glyphs from the
8x8 font at 0x1800, mono from the MDA font at 0x0000/0x0800), the shell's
free default font.

## 6. Video outputs

`pvc4.sv` (and `pc_system` with `PVC4_FIT`):
- colour personality: `vid_ce` = `ce_14m`, `vid_rgbi` = RGBI, syncs and the
  window exactly as `cga_card.sv`;
- mono personality: `vid_ce` = the 16.257 MHz falling dot edge (1 or 2 clk
  apart, as `mda_ce`), `vid_mono` = MONO (+VIDEO), `vid_rgbi` = {IT, MONO,
  MONO, MONO} (so an RGBI monitor shows grey levels), syncs and window as
  `mda_card.sv` (738 x 354 window, 882 x 370 dots per frame);
- `vid_monomode` = the mono personality (Paradise bit 7).

On the PC10-III both go to one DB9 (CN602, through a 74LS244): IT is pin 6
(the CGA's intensity and the MDA's intensity), MONO pin 7 (the MDA's video,
unused by an RGBI monitor) **(SM 9-6)**.

## 7. The PC10-III's wiring

**Straps** (SM 9-6, pull-ups 33K, RP604/RP605, R607/R608, R640):
- MA7 and MA5 through 33K (R608, R607) to the DIP switch 2 node (1K
  pull-up R606; the switch grounds it when ON = colour); MA6 has no resistor
  (the data sheet's inputs have a pull-up current, -0.5 to -20 uA, DS 10: 1
  **[A]**); MA4-MA0 pulled down. **Paradise register = E0h with switch 2 off
  (mono), 40h with it on (colour)**: mono or colour mapping and clock, 9-dot
  characters with mono, Plantronics/AT&T enabled, **flicker override on**,
  CRTC unlocked, 40 columns allowed.
- MD7, 6, 4, 2, 1, 0 pulled up, MD3 pulled down, MD5 open (1 **[A]**):
  **Configuration register = F7h**: one 64K bank, IBM 200 lines, composite
  sync on CSYNCN, mono video on the MONO pin, border on, printer decode off
  (the PC10-III's parallel port is the 5720's, not a PPC chip).

**The Commodore configuration register 230h** (SM 5-4, 5-5; in the 5720
gate array U602 on SM 9-6, `rtl/system/cbm_cfg230.sv`):

| bit | 7 | 6 | 5 | 4 | 3 | 2 | 1 | 0 |
|---|---|---|---|---|---|---|---|---|
| read | mono | rtc | X | mouse | com1 | com0 | lpt1 | lpt0 |
| write | venb' | rtc | X | mouse | com1 | com0 | lpt1 | lpt0 |

(the manual's table heads both bit 7 and bit 6 "bit6"; the text and the
BIOS make the first one bit 7). Read bit 7 = DIP switch 2 (1 = mono, the
5720's SW1 input); write bit 7 = venb': 0 = the onboard video is enabled.
The 5720's NOVID' output drives the enable of the PVC4's data buffer U604
and, through Q602, the PVC4's READY onto IOREADY (jumper JMPS12 can force
it on). Bits 6-0 read back what was written; they enable the onboard RTC
(02C0h), bus mouse (023Ch), serial port (com1/com0: off, 2F8h, 3F8h,
reserved) and parallel port (lpt1/lpt0: off, 3BCh, 378h, 278h). The model
builds the register, not the peripherals. Its reset value is not documented:
00h **[A]** (the BIOS writes it before anything depends on it).

With venb' = 1 the model's PVC4 sees no strobes at all **[A]**: on the board
it still sees them (only its data buffer and READY are cut) and would store
whatever is on its floating data pins; the difference is invisible to the
CPU, and the PC10-III disables the onboard video only when an expansion card
answers at its addresses.

**The BIOS** (4.41): at reset (F000:E05B) it writes 3B8 = 00 and 3D8 = FF,
230h = 00 (onboard video on) with the read-back handshake, programs the
40-column CGA table into 3B4/3B5 and the 80-column table into 3D4/3D5
(whichever mapping the straps chose answers), then 230h = 81h (onboard video
off, the parallel port at 3BCh) and waits for the read-back of 01h. At
F000:E431 it reads 230h, picks B000 (bit 7 set) or B800, writes the segment's
high byte to offset 7Bh and reads it back with the onboard video still off:
if the byte is there, an expansion card answers and the onboard video stays
off; else it writes 230h with bit 7 clear (enabled) and keeps bit 7 in
40:70h. It then sets the BIOS mode from the equipment bits as an IBM BIOS
does (INT 10h, VIDEO_PARMS at F000:F0A4 are IBM's). **It never writes 3XA or
3XB**: the straps decide everything, including the flicker override.

**DIP switches** (SM 2-3): switch 1 = character set (A14), switch 2 =
onboard video mono (off) / colour (on), switches 3-4 = default video mode
(off/off mono, off/on 80 x 25 colour, on/off 40 x 25 colour, on/on none),
read through the FE2010A's switch register like the 5160's SW1 bits 5-4
(`dip_sw1`).

**Expansion cards** (SM 5-1): with an expansion adapter of the same kind
(mono for a mono-strapped PVC4, colour for colour) the onboard video stays
disabled; an adapter of the other kind can coexist. `pc_system` keeps the
IBM cards as parameters next to the PVC4 (`CGA_FIT`, `MDA_FIT`); the BIOS's
probe then finds them. The SM warns that Hercules page 1 (B8000) collides
with an expansion CGA.

## 8. Integration and the shell

- `pc_system` parameter `PVC4_FIT` (default 0: the IBM CGA as before, every
  existing gate bit-identical). With 1: `pvc4` and `cbm_cfg230` are built,
  the straps come from `cbm_dip[1]` (switch 2), the ROM's A14/A11 from
  `cbm_dip`, the vid_* outputs from the PVC4. New ports: `font_addr_hi[1:0]`,
  `font_cbm`, `cbm_dip[1:0]` (inputs), `vid_mono`, `vid_monomode` (outputs).
  The IBM cards' font copies take only `font_addr_hi` = 0 writes. A card
  that is not fitted (CGA_FIT = 0) now sees no strobes (it used to see them
  with its outputs gated; its `$fatal` write checks fired once the PVC4 ended
  strobes before the CGA's slot).
- `CORE/sv/pc_system_flat.sv`: the PC10-III = FE2010A + PVC4, no CGA.
- `CORE/vhdl/main.vhd`: inputs `cbm_dip_i` and `mono_tint_i` (0 green, 1
  amber, 2 white), from the menu's "Display" (doc/m2m-shell.md section 8,
  `pc_chipset.vhd`: colour = "01", 5Dh/6Dh; mono = "11", 7Dh; a change
  restarts the PC). In the mono personality the dot becomes black,
  dim (intensity alone), normal or bright in that tint; colour RGBI as
  before. `font_cbm` comes from `pc_font.vhd` (a 16 or 32 KB
  `/pc10/char.rom`).
- **The menu** (2026-10-25): "Display" = DIP switch 2 with switches 3/4 and
  the mono tint; "Scandinavian charset" = DIP switch 1 (doc/m2m-shell.md
  section 8). The Commodore ROMs on zimmers.net confirm section 5's wiring:
  318086-02/-03 hold USA/Europe at A14 = 1, Scandinavian at A14 = 0, and
  the 9x14 mono font where A13 = A11 (8x8 colour where they differ).
  The ROM holds the leftmost dot in D0 (IBM: D7): the board wires its data
  lines to the PVC4 reversed, so `pvc4.sv` stores a Commodore image
  bit-reversed (found on hardware 2026-10-25: mirrored glyphs).

### 8.1 The video path through M2M

- **Colour personality**: identical to the CGA's (doc/m2m-shell.md section
  5): 14.318 MHz enable, 912 x 262, 59.92 Hz; HDMI 720p60/480p59.94, analog
  VGA through the line doubler or 15 kHz RGB.
- **Mono personality, HDMI**: ascal (M2M's `digital_pipeline`) samples a
  pixel at every `i_ce` and measures the active window from the blanks
  (input crop `iauto` = 0 with zero offsets = the measured size), so the
  irregular 1-2 clk dot enable and the 738 x 354 window (720 x 350 text,
  720 x 348 graphics; the PC10-III's Hercules table: 880 x 368 dots) need
  nothing new: ascal re-measures after the switch. Its input limit IHRES 1024
  is not reached. The frame rate is 49.8 Hz against the 60 Hz HDMI modes:
  ascal repeats about every fifth frame (no triple buffer: possible tearing).
  The menu's 720p 50 Hz HDMI mode (2026-10-25) is the clean answer.
- **Mono personality, analog**: the 5151-class monitor is an 18.4 kHz TTL
  monitor; M2M's analog path cannot pass it: the VGA line doubler needs the
  video clock at least twice the pixel rate (28.64 / 16.26 = 1.76), and its
  output would be 36.9 kHz / 49.8 Hz, which few VGA monitors take. With
  "Analog: 15 kHz RGB" (scandoubler off) the raw 18.4 kHz sync goes out,
  usable only on a multisync CRT. Options: a frame buffer for analog (ascal's
  output on the VGA connector at 31 kHz), or a dedicated 720 x 350 x 70 Hz
  VGA-like path (the IBM VGA's mono text mode timing) from a line buffer.
  **[Q]** the user's choice.

## 9. Verification

`make -C tb/pvc4 run` (about 1 minute) builds the chip with Verilator and a
test font (tb/mda/mkfont.py: GLaBIOS's 8x8 glyphs, no IBM or Commodore
content), runs all tests and writes images to `~/pcxt-work/pvc4/tb/`;
`python3 tb/pvc4/mut.py` runs the mutants.

The harness is tb/cga's and tb/mda's board model (pc_clocks enables, the
8288 command edges, READY sampled on rdy_ce, biu88's rule, the next-clk bus
values). Next to the chip runs `pvc4_model.h`, written from this document:
its colour part is tb/cga's MartyPC CGA model, its mono part tb/mda's MDA
model, each with the PVC4's differences, its CPU access the sequence rule of
section 4. Compared: READY at every clk, the instant of every VRAM write,
every read, every dot (colour: RGBI and the syncs, 6 ticks late as in
tb/cga; mono: video, intensity, RGBI, syncs and window at `vid_ce`).

| Test | What | Result |
|---|---|---|
| `regs` | straps at reset; 3XA/3XB locked; one read, an intervening I/O (61h, 3D9) break the unlock; the unlock writes; 3D8 read back; 3DA bits 7-4 with CNF6 = 1 and 0; 3DD kept in graphics, cleared by alpha mode and Paradise bit 3, 3DE likewise; the mapping switch (3DA no longer answers, 3BA bits 6-4 = 111); 3BF gating of 3B8 bits 1/7, page 2 at B8000 and its removal by the colour mapping; the CRTC lock (R1 kept, R11 = underline row, R12 written), R8 = 0, R10 bit 6 = 0; 3B9/3BB light pen; venb' = 1: no reads, no READY, no writes | 45 reads equal, all checks pass |
| `waits` | 3,000 random VRAM reads/writes at random gaps each in colour 80 and 40 columns, mono, mono with the clock / 2 | READY equal at every clk, write instants equal, ~1,500 reads each equal, every VRAM byte equal; wait states as section 4; longest READY low 1502 ns |
| `cmode0`-`cmode6` | IBM BIOS modes 0-6 | 477,888 dots each equal; 912 dots x 262 lines |
| `flicker` | mode 3 with 3D8 bit 3 = 0 | shown with Paradise bit 2 = 0 (116,233 lit dots), blank after it is set |
| `plant` | 320x200x16 and 640x200x4, plane swap | 477,888 dots each equal; 16 and 4 colours |
| `nosnow` | 2 frames of 80-column text with continuous VRAM writes | 477,888 dots equal (the model has no snow) |
| `status`, `mstatus` | 20,000 back-to-back reads of 3DA / 3BA | all equal; bit 0 43.1 % / 16.3 %, 3BA bit 7 0 in 4.1 % |
| `torture` | 4 runs x 5 frames, colour: random CRTC, mode, colour, 3DD, 3DE, light pen, Paradise (flicker, lock, force 80, Plantronics disable) and Configuration (border) writes, VRAM traffic | 4.8 M dots, ~31,600 reads equal |
| `mono`, `mono8` | mode 7 with 9-dot and 8-dot characters, all characters and the MDA attributes | 653,680 dots each equal; 882 / 784 dots x 370 lines |
| `mono40` | mono with mode bit 0 = 0 | equal; 8.1284 MHz dot rate |
| `mtorture` | 3 runs, mono: as torture plus 3BF, 9/8 dots, Hercules page/graphics switching | 4.1 M dots, ~24,000 reads equal |
| `hgc` | Hercules graphics with the PC10-III's CRTC table (SM 6-4), pages 0 and 1 | 648,680 dots each equal; 880 dots x 368 lines |
| `cbm` | the 32 KB Commodore layout: A14 both ways, CA13 (3DE bit 2) both ways, A11 against the mapping both ways | all dots equal |
| `blink` | 34 frames of mode 3 with blinking characters and the cursor | 8.1 M dots equal |

Mutants (`mut.py`, 37): CPU part 4 T, no request synchroniser, sequence
phase, mono sequence every character, the mono sequencer on the divided
clock, write at the sequence start, READY
released while busy, unlock after one read, unlock not broken by other I/O,
Paradise register without unlock, 3X8 not readable, 3DD/3BF clearing rules,
CRTC lock, R8, R10 bit 6, the mono light pen port, status bit 4, venb'
ignored, 3BA bit 7 polarity, no flicker override, border control, the
Plantronics colour order, plane order and plane swap, force-80 ignored, the
9-dot strap, the 9th-dot characters, the underline row, the mono /2, mono
video enable, Hercules bank and page, and four character ROM address
mistakes. All are killed. The first run left three: the write instant (no
test saw it; the harness now compares every VRAM write's clk), a mutant
equivalent in 8-dot mode (replaced by the 9th-dot character range), and A11
following the mapping instead of the switch (the `cbm` test now runs both
mappings against both switch positions).

What this shows: the HDL does what the model does for these stimuli. The
display parts of both come from the verified IBM card models, so a misreading
of the PVC4 data sheet common to both would not show; the wait states are a
model (section 4).

**System** (`tb/sys`, `make FE=1 PVC4=1 OBJ=obj_pvc4`, `sys_run -d 5D [-m]
-P n -F font -o image`): the Commodore BIOS 4.41 shows its banner and RAM
count on the colour and on the mono personality (the 230h handshake and the
expansion probe as section 7), GLaBIOS too (`make PVC4=1`, the IBM board);
numbers in doc/history.md 2026-10-25. The default build's gates are
byte-identical.

## 10. Open questions

- The CPU access timing (section 4): request synchroniser, the CPU part's
  position and length, 40-column/graphics behaviour, READY's release
  relative to the data. Needs a measurement on a PC10-III.
- ALPHA132 and CLOCK2 (section 3).
- The display pipeline's latency and the CGA mode-change deferral are the
  IBM card models', not measured on a PVC4.
- Reset values of the underline row and of 230h; MA6/MD5 open = 1.
- The Plantronics 640x200x4 palette bits (86Box's rule, the data sheet calls
  3D9 bit 5 reserved there).
- MDA text: is CPU memory mirrored every 4 KB (IBM MDA) or linear (HGC)?
  The model is linear.
- 3XB light pen clear on an unlocked write (the model: no).
- The character ROM images the user has (318086-01/-02/-03, pc10sd): size,
  national sets, which is which.
