# PC XT core and Amiga bridgeboard - ideas and decisions

Status: **discussion only** (2026-10-20/21). Nothing is built, no repository
exists. This file collects the decisions and research so a later session can
start from them. Points marked *(unverified)* come from memory or from one
secondary source and must be checked before they are relied on.

## 1. The user's decisions

- **Accuracy: cycle exact, or the project does not happen.** "Maximum
  compatibility" means the bus-cycle level of the real machine, measured
  against ground truth (section 4), not "runs most software".
- **Identity: the Commodore PC line** (PC10/PC20/PC30, above all the
  PC10-III). It fits the Commodore-centric MEGA65 better than a plain IBM
  clone.
- **A separate core**, not part of Megamiga, but built on **our modified M2M
  fork** (the exceptions listed in AGENTS.md).
- **R3 if possible**, so first-batch MEGA65s run it too.
- **640 KB** conventional memory ("640k should be enough for everyone").
- **Bridgeboard:** if there is the slightest chance to fit an A2088/A2088T
  in Megamiga, the PC core must be built from components that serve both.
  Recommendation accepted for discussion: **the A2088 (XT) first**
  (section 7).

## 2. Building blocks to evaluate (licences still to check)

| Block | Candidate | Note |
|---|---|---|
| 8088 CPU | MCL86 (MicroCore Labs) | microcoded, claims cycle accuracy, has run in a real PC's 8088 socket; must pass SingleStepTests (section 4) or we write our own |
| XT chipset | KFPC-XT (kitune-san), as used by the MiSTer PCXT core | one module per chip (KF8237, KF8253, KF8259, KF8255, KF8288): a good base for an FE2010A module |
| System | MiSTer PCXT core | reference for integration; check for an existing MEGA65 port first |
| BIOS | bring your own (IBM, Commodore 380788), or GLaBIOS / Super PC/Turbo XT BIOS as free options | like Kickstart today |
| Hard disk | XTIDE Universal BIOS + an ATA device behind our `ide_engine` / firmware ATA server | reuses Megamiga's HDF path |

Licences to check: PCXT, KFPC-XT, MCL86, XTIDE Universal BIOS, GLaBIOS.
MartyPC is used only as a test reference, never as shipped code.

Megamiga parts that carry over:
- profiles as files;
- disk images through the FAT32 layer;
- `sd-host` with both slots;
- the sector engine;
- the PMOD serial port (as COM1/COM2: serial mouse, null modem);
- the Hardware Floppy front-end, which needs a new IBM-MFM decoder for PC
  disks.

## 3. R3 feasibility

A cycle-exact PC wants its memory in **block RAM**: one-cycle access and no
refresh or arbitration latency to hide. The R3 has the same XC7A200T (365
RAMB36 tiles) as the R6.

| Use | Tiles |
|---|---|
| 640 KB conventional memory | 160 |
| Video RAM (CGA 16 KB, up to 64 KB for Hercules/PVC4) + character ROM | ~6-18 |
| System BIOS + XTIDE BIOS | ~4-18 |
| M2M + QNICE (ROM, RAM, code banks, OSM, scalers) | ~60-70 |
| **Total** | **~230-270** |

Even a full 1 MB address space (upper memory blocks included) fits: about
256 + 70 tiles.

Rules and work for R3:
- **No QNICE port on the 160-tile main RAM** (hard rule 4). Load ROMs and
  disks through a byte FIFO, like the Kickstart loader.
- Our M2M fork's **R3 board top was never adapted**:
  - `sd-host` (exception 18): bidirectional SD pins, the engine port, two
    slots;
  - the PMOD routing (exception 13).

  Both need doing.
- HyperRAM stays where M2M uses it (the HDMI framebuffer). R3 has no SDRAM.
  Nothing in the PC core may need SDRAM, but the bridgeboard in Megamiga
  (R4+) will keep the PC RAM in SDRAM. So **the island's memory interface
  must be abstract** (section 8).
- A design that runs on R3 runs on R4/R5/R6 unchanged.

## 4. What "cycle exact" requires

The bar is set by *8088 MPH* and *Area 5150* (reenigne and others):

1. **The 8088 to the bus cycle:**
   - the 4-byte prefetch queue;
   - how execution and bus fetches interleave;
   - the timing of every instruction;
   - interrupt latency.
2. **DMA refresh:** 8253 channel 1 triggers 8237 channel 0 every ~15 µs,
   which steals bus cycles. The demos count on where they land.
3. **One 14.31818 MHz master clock**, with the right phases:
   - the CPU runs at ÷3 = 4.77 MHz;
   - the 8253 at ÷12;
   - the CGA from the same crystal.

   *Area 5150* depends on the CPU-CGA phase. Plan for a 14.31818 MHz clock
   domain (MMCM) next to M2M's clocks.
4. **IBM CGA, exactly:**
   - the 6845 CRTC;
   - CPU-vs-display collisions (80-column "snow");
   - the PC speaker as a sample player;
   - **composite colour**, which *8088 MPH*'s palettes depend on. The
     MEGA65 has no composite output, so we model the NTSC composite signal
     digitally and decode it to RGB for HDMI/VGA, as emulators do (a
     per-pixel filter at 14.3 MHz, old vs. new CGA).

Ground truth, which fits our TB + mutant workflow:

- **SingleStepTests 8088** (Daniel Balsom / GloriousCow): thousands of tests
  per opcode. Each has the start and end CPU state and a **cycle-by-cycle bus
  trace** including queue status, captured from real hardware. "Passes all"
  is the CPU gate.
- **SingleStepTests/v20**: the same for the NEC V20 (native mode; the 8080
  mode is planned there). Codeberg mirror: <https://codeberg.org/virtualxt/v20>.
- **MartyPC**: open-source, cycle-accurate at system level, runs both demos.
  It's the reference for differential tests: run the same program in MartyPC
  and in a Verilator simulation of the core, then compare bus traces cycle by
  cycle.
- Ken Shirriff's 8086 microcode reverse-engineering and reenigne's notes
  cover the hard corners.
- If MCL86 fails and we write our own CPU: check the legal side of using
  Intel's microcode vs. a behavioural model of it.

## 5. The Commodore problem: no cycle reference

Cycle-exact references exist only for the **IBM 5150/5160 with an IBM CGA**.
The PC10-III differs exactly where exactness lives:

- **The Faraday FE2010A** puts the clock (8284), bus controller (8288),
  8237, 8253, 8259, an 8255 subset, DRAM control and refresh, and a
  configuration register (port 0x63: speed, etc.) in one chip. Its refresh
  and wait-state timing is not documented at cycle level *(as far as we
  know)*.
- **Paradise PVC4 onboard video** (CGA/MDA/Hercules/Plantronics
  *(unverified)*) is not an IBM CGA. *8088 MPH* checks for IBM CGA
  behaviour.

Plan: **one core, several personalities.**

- **IBM 5160 + IBM CGA (or MDA/Hercules):** cycle exact, verified against
  MartyPC and the demos.
- **Commodore PC10-III:**
  - FE2010A behaviour: 4.77 / 7.16 / 9.54 MHz *(PC10-III speeds and its
    8088-1 CPU unverified)*, the configuration register;
  - PVC4 video;
  - the Commodore BIOS (bring your own).
- **PC10-III with an IBM CGA card:** period-correct, since the onboard video
  could be disabled and an ISA card fitted. A Commodore machine that runs the
  demos.

The IBM personality is the same function blocks as the FE2010A with IBM glue.
So there is **one chipset module with modes**, not two designs.

Making the Commodore personality exact needs **measurements on real
hardware**: a logic analyser on the bus, plus timing test programs. One
campaign on a PC10-III *or* an A2088T pins down the FE2010A for both targets.
**Open question to the user:** do they have one, or know someone who has?
Without it the PC10-III is "accurate to documentation", the IBM personality
"accurate to the cycle".

Other Commodore and PC models mentioned:
- the Tandy 1000 *(only as an idea)*;
- the A1060 Sidecar for the A1000, a complete XT;
- the A2286/A2386SX, which are 286/386 and out of scope.

## 6. Commodore XT bridgeboards for the Amiga

| | A2088 (XT) | A2088T |
|---|---|---|
| CPU | Intel 8088 4.77 MHz, 8087 socket | NEC V20 (PLCC), 4.77 / 7.15 / 9.54 MHz, Ctrl-S/T/D |
| Chipset | Faraday **FE2010** (U7) | almost certainly **FE2010A** (speed through port 0x63; a board photo would confirm it) |
| FDC | SMC **9268** (765-compatible): J3 internal = A:, J4 external 23-pin Amiga drive = B: | none supplied; the PC uses the Amiga's drives through Janus |
| RAM | 512 KB (256Kx1 + 64Kx4 DRAM) | 640 KB |
| BIOS | 16 KB, 380788-01, upgrade 380788-06 (autoconfig fix) | 16 KB XT BIOS |
| Display jumper J1 | mono / colour 40x25 / colour 80x25 / none | - |
| Hosts | A2000 (Zorro II + ISA slots in line) | A2000/A3000/A4000 |

The FE2010 and FE2010A differ at least in speed: an A2088 can run 9.54 MHz
(with a 28.63636 MHz oscillator) only with the FE2010A (turbo2088 readme).

The PC side has two personalities:
- the A2088: an 8088 at 4.77 MHz, exactly the IBM reference timing;
- the A2088T: the PC10-III chipset with a V20.

### Janus: the Amiga side

From WinUAE `x86.cpp`, which since WinUAE 4.1.0 emulates the A1060, A2088,
A2088T, A2286 and A2386SX with a PCem core. WinUAE treats the A2088T's CPU as
an 8088, so it is a functional reference for Janus, not a timing reference.

- **Autoconfig:** a Zorro II board, manufacturer **513** (0x0201),
  product **1** (the A2386 uses 0x67). The base comes from the write to
  0x48; a write to 0x4c shuts the board up.
- **A 512 KB window** in four 128 KB access modes (`addr >> 17`): byte,
  word, GFX (CGA-interleaved, de-interleaves the bitplanes) and I/O.
- **Shared memory**, as offsets in the window:

| Window | Size | Amiga offset | PC address |
|---|---|---|---|
| Buffer (disk etc.) | 64 KB | 0x00000 | A0000 / D0000 / E0000 (mode bits 5-6) |
| Colour video | 32 KB | 0x10000 | B8000 |
| Parameter RAM | 16 KB | 0x18000 | F0000 (XT); D0000 on AT boards |
| Mono video | 8 KB | 0x1C000 | B0000 |
| I/O registers | 8 KB | 0x1E000 | - |

- **I/O registers** (offsets in the I/O space):
  - 0x1FF1 Amiga interrupt status (cleared by a read);
  - 0x1FF3 PC interrupt status;
  - 0x1FF5 negate PC reset (a read releases the PC CPU);
  - 0x1FF7 mode register: bit 0 COM2, bit 1 LPT1, bit 3 MDA, bit 4 CGA,
    bits 5-6 buffer address;
  - 0x1FF9 interrupt mask;
  - 0x1FFB PC interrupt control (raises PC IRQ 1, 3 or 7);
  - 0x1FFD control register (reset bit);
  - 0x1FFF keyboard register (A2000), which feeds PC port 0x60
    (0x61F on the A1060).
- **Interrupts to the Amiga:** bit 4 keyboard acknowledge, bit 5 LPT1
  (0x37A), bit 6 COM2 (0x2F8), bit 7 system control (PC port 0x62).
  Writes to the video memory and to the CRTC ports set "delayed" bits,
  delivered at vsync.
- **Video:** with MDA/CGA enabled, PC ports 0x3B0-0x3BF and 0x3D0-0x3DF land
  in the Amiga I/O space (e.g. 0x3B1 maps to 0x2A1 + (reg & 15) * 2). 0x3DA
  toggles for software that polls it. The Amiga's **PCColor / PCMono** draw
  the screen in a Workbench window. The board has **no video hardware**.
- **Hard disk:** a file on an Amiga partition (JLink / JDisk), so it works on
  Megamiga's IDE as it is.
- **Software:** janus.library (A2088T install disk v1.02, janus.library
  v33.4, 1989), the PC Janus disk, and a Commodore BIOS. All bring your own,
  run unmodified against the emulated hardware.

### Fit in Megamiga

Megamiga main-b (2026-10-20, R6):
- 117,105 LUTs (87.5%);
- 124.5 BRAM tiles;
- 116 DSPs;
- WNS +0.006 ns.

Estimate for an XT island (CPU + FE2010A + 9268 + Janus logic): **6-12K
LUTs**, so 93-96%. PC RAM goes in free SDRAM, the Janus windows in about 32
BRAM tiles (or SDRAM).

Tight but possible. Realistic options:
- a **separate Megamiga bitstream** in another flash slot ("A2000 +
  Bridgeboard") without something large such as the AP68040;
- or first freeing logic elsewhere.

It needs a profile with a Zorro II slot (A2000/A3000/A4000 style), and lives
on its own 14.31818 MHz clock like `ap040_island.v` on its 42 MHz. The PC
side's own timing is exact. Only accesses to the Janus windows carry
arbitration wait states, which nothing depends on.

## 7. Which bridgeboard: the A2088 first

How much of each board the full PC10-III core already contains:

| Component | PC10-III core | A2088 | A2088T |
|---|---|---|---|
| CPU | 8088 | 8088: same | V20: a second cycle-exact CPU |
| Chipset | FE2010A | FE2010: FE2010A minus the turbo modes | FE2010A: identical |
| FDC | 765-family | 9268: reused as is | through Janus + the Amiga's drive |
| RAM | 640 KB | 512 KB (a size parameter) | 640 KB |
| Clock | 4.77 / 7.16 / 9.54 | 4.77 | 4.77 / 7.15 / 9.54 |

Why the A2088 wins on reuse:
- **The CPU is the biggest single piece.** The cycle-exact 8088 is needed
  anyway: for the PC10-III, and for the IBM reference at 4.77 MHz that
  MartyPC and the demos verify. The A2088 runs that CPU at that speed.
- **The chipset difference is small** and runs in the easy direction: one
  FE2010A module with an FE2010 mode.
- **The FDC is reused as is.** The A2088T floppy path is new work only it
  needs:
  - the Amiga reads the PC disks, so Paula must see PC-format MFM;
  - our ADF engine serves Amiga-format images only;
  - so a PC image-to-MFM path is needed (the Hardware Floppy would work as
    is).
- **It's the smallest island,** which matters at 87.5% LUTs.

Its drawback: 4.77 MHz only. The A2088T then costs one big item, the **V20**
(verified against SingleStepTests/v20); its turbo speeds come free with the
FE2010A module. The V20 also becomes a CPU option in the PC core: a V20 in the
8088 socket was a common period upgrade, but it must be labelled as not the
stock machine. The V20 is a different microarchitecture (hardware
multiplier, different effective-address timing, 8080 mode), not an 8088 with
extra opcodes.

## 8. Architecture rules that keep both targets open

1. **The CPU behind the real 8088 pin interface:**
   - multiplexed address/data;
   - bus status S0-S2 (to the 8288 function);
   - queue status QS0/QS1;
   - READY, INTR/NMI, HOLD/HLDA (RQ/GT).

   So the 8088 and V20 are interchangeable and everything else is
   CPU-agnostic.
2. **The FE2010A as one module with modes** (FE2010A / FE2010 / IBM
   discrete-chip glue), built from per-chip blocks (KFPC-XT style).
3. **A 765-family FDC module** (9268): for the PC core's drives, the A2088's
   A:/B:, and possibly the Hardware Floppy with an IBM-MFM decoder.
4. **The XT island with an abstract memory port and an abstract ISA side:**
   - in the PC core: BRAM, its own video (CGA/MDA/PVC4), keyboard;
   - in Megamiga: SDRAM, plus Janus as the "ISA cards" (MDA/CGA trap,
     COM2/LPT1, the keyboard register).
5. **Its own 14.31818 MHz clock domain** in both targets.

## 9. Suggested phases

0. **Survey (read-only, the go/no-go gate):**
   - MCL86 against SingleStepTests 8088 in simulation: which opcodes are
     exact, where it fails;
   - the licences;
   - the R3 checklist: board top for sd-host + PMOD, the clocking plan, a
     BRAM budget against the real M2M baseline;
   - collect PC10-III / FE2010A / PVC4 documentation and list what can't be
     pinned down without real hardware.
1. **The cycle-exact 8088** (MCL86 if it passes, else our own) at 100% of
   SingleStepTests, in a ghdl/Verilator TB with mutants.
2. **The XT island:** FE2010A module (IBM and FE2010 modes), 9268 FDC, BIOS
   loading. Differential tests against MartyPC.
3. **The PC core on R3:**
   - IBM 5160 + CGA with composite decoding, MDA/Hercules;
   - keyboard, XTIDE on our sector engine, disk images, profiles.

   Target: *8088 MPH* and *Area 5150*.
4. **The PC10-III personality:** FE2010A turbo, PVC4, Commodore BIOS. Real
   hardware measurements if available.
5. **The A2088 in Megamiga:** the Janus Zorro II board on the same island,
   in a separate bitstream if the LUTs require it.
6. **The V20:** SingleStepTests/v20, then the A2088T and the PC core's V20
   option.

## 10. Open questions

- Does the user (or someone they know) have a PC10-III, A2088 or A2088T for
  measurements and board photos (FE2010 vs. FE2010A, A2088T FDC)?
- Which Megamiga feature could a bridgeboard bitstream drop (the AP68040?),
  or can logic be freed elsewhere?
- The PC10-III details: CPU (8088-1?), PVC4 modes, BIOS versions.
- Does an MCL86/PCXT MEGA65 port already exist?
- Video: MDA's 50 Hz / 18.4 kHz vs. CGA's 60 Hz on the analog output; HDMI
  modes for both.

## Sources

- [amiga-stuff.com: A2088](https://www.amiga-stuff.com/hardware/a2088.html)
  (chips, connectors, BIOS revisions; from Commodore Techtopics and the A2000
  schematics)
- [Amiga Hardware Database: A2088T](https://amiga.resource.cx/exp/a2088t)
- [XT bridgeboard guide (AMIGAplus Sonderheft 18)](https://discmaster.textfiles.com/file/4793/AMIGAplus%20Sonderheft%2018%20(1999)(ICP)(DE)[!].iso/PD/Anwendungen/BBGuide/xtbb.html)
- [turbo2088 readme](https://morphos.aminet.net/docs/hard/turbo2088.readme)
  (A2088 at 9.54 MHz needs the FE2010A)
- [WinUAE x86.cpp](https://raw.githubusercontent.com/tonioni/WinUAE/master/x86.cpp)
  (Janus emulation)
- [amiga-news: WinUAE 4.1.0](https://amiga-news.de/en/news/AN-2018-12-00019-EN.html)
  (PCem-based bridgeboards)
- [SingleStepTests V20](https://codeberg.org/virtualxt/v20)
