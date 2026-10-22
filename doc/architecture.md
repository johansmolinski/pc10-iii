# PC10-III core - architecture

Status: 2026-10-22, the contract between the parallel work tracks (CPU,
system board, CGA, floppy, hard disk, MEGA65 shell). Change it only together
with every module it names.

## 1. Clocks

One clock domain for the whole PC: **`clk` = 100.2273 MHz = 7 x 14.31818 MHz**
(MMCM from the board's 100 MHz: M = 55.125, D = 5, O = 11, VCO 1102.5 MHz;
exact, 2205/22 MHz). Everything PC-side runs on `clk` with clock enables:

| Enable | Rate | Period in `clk` | Use |
|---|---|---|---|
| `ce_14m` | 14.31818 MHz (OSC) | 7 | CGA dot clock, composite, the master phase |
| `cpu_step` | 4.77273 MHz (CLK88) | 21 | biu88/EU step (the 8088 clock edge) |
| `rdy_ce` | 4.77273 MHz | 21, 2 before `cpu_step` | the 8284's RDY sample (READY) |
| `ce_pclk` | 1.19318 MHz (PCLK) | 84 | 8253 counters (OSC/12) |

- All enables derive from **one modulo-84 counter** (`pc_clocks.sv`), so the
  OSC/CLK88/PCLK phase relation is fixed like the 8284 + 74LS175 on the
  5160 board. *Area 5150* depends on the CPU-CGA phase; the counter's reset
  phase is a parameter.
- The 8088 CLK has a 1/3 duty cycle: high for 7 `clk`, low for 14. Logic that
  the IBM schematic clocks on the falling CLK edge uses `cpu_fall`
  (7 `clk` after `cpu_step`).
- `ce_14m` falls on `cpu_step` and on `cpu_fall` (7 and 21 are multiples of 7).
- MCL86's EU runs on `clk`: 21 microinstructions per 8088 clock, exactly the
  ratio the CPU work was tuned for (`AGENTS.md`).
- Turbo (FE2010A 7.16/9.54 MHz) is not part of this contract yet.

## 2. Module tree

```
pc_system          (rtl/system/pc_system.sv)  the PC: everything below
 +- pc_clocks       clock enables
 +- cpu8088         rtl/cpu/cpu8088.sv: MCL86 EU + biu88 behind 8088 max-mode pins
 +- xt_board        rtl/system/xt_board.sv: the 5160 system board logic
 |   +- 8288 function (bus commands from S2-S0)
 |   +- 8237 DMA, page register, refresh (8253 ch1 -> DRQ0)
 |   +- 8253 PIT, 8255 PPI, 8259 PIC, NMI mask, speaker
 |   +- ready / wait-state logic (DMA hold, IOCHRDY)
 |   +- keyboard interface (shift register, IRQ1, clear via PB7)
 +- the "ISA slots": modules on the card bus (section 3)
     +- system RAM (planar, behind the abstract memory port)
     +- BIOS ROM (F0000-FFFFF, behind the ROM port)
     +- cga_card    rtl/video/cga/cga_card.sv     (CGA_FIT)
     +- mda_card    rtl/video/mda/mda_card.sv     (MDA_FIT: MDA or Hercules)
     +- fdc_card    rtl/fdc/fdc_card.sv: the diskette adapter (765), doc/fdc.md
     +- xtide_card  rtl/hdc/xtide_card.sv: XTIDE hard disk card + option ROM socket, doc/hdc.md
     +- later: COM/LPT
```

## 3. The card bus (ISA, as seen inside `pc_system`)

The bus a card sees, all on `clk`. Signals are levels, valid for the many
`clk` cycles a real ISA cycle lasts; cards detect edges themselves.

| Signal | Dir (card) | Meaning |
|---|---|---|
| `isa_addr[19:0]` | in | SA19-SA0 (CPU address after ALE, or DMA address) |
| `isa_dout[7:0]` | in | data from the CPU/DMA (writes) |
| `isa_din[7:0]` | out | the card's read data, ORed (0 when not selected) |
| `isa_dsel` | out | the card drives `isa_din` (none: the bus reads 0xFF) |
| `isa_memr_n`, `isa_memw_n` | in | MEMR/MEMW |
| `isa_ior_n`, `isa_iow_n` | in | IOR/IOW |
| `isa_aen` | in | 1 = DMA owns the bus (I/O decoders must ignore it) |
| `isa_ale` | in | ALE |
| `isa_ready` | out | IOCHRDY, ANDed; a card pulls it low to insert waits |
| `isa_irq[7:2]` | out | IRQ2-IRQ7, ORed |
| `isa_drq[3:1]` | out | DRQ1-DRQ3 |
| `isa_dack_n[3:0]` | in | DACK0-DACK3 (0 = refresh) |
| `isa_tc` | in | terminal count |
| `isa_reset` | in | RESET DRV |
| `isa_addr_next`, `isa_aen_next`, `isa_memr_n_next`, `isa_memw_n_next`, `isa_ior_n_next`, `isa_iow_n_next` | in | the values these signals will have in the next `clk` (the strobes' except in the first `clk` of a reset). Optional: for a card that registers its decode or strobe edges (the FDC, the CGA's IOCHRDY; doc/timing.md) |

A card's read data must be valid within 2 `clk` of the strobe going low and
held while it stays low.

Memory map of the cards: CGA B8000-BBFFF (mirrored to BFFFF), the XTIDE
card's option ROM C8000-CBFFF (16 KB; the BIOS's option ROM scan finds it).
I/O: FDC 3F0-3F7, XTIDE 300-31F (variant 0) or 300-30F (variants 1/2).

Bus timing (`xt_board.sv`, the 8288 function; marked CAL there, cards such as
the CGA depend on it):
- MEMR/IOR/INTA go low at the CLK falling edge (`cpu_fall`) in T1, MEMW/IOW
  at the falling edge in T2; all go high in the `clk` where T4 begins (+1).
- MEMW/IOW are the 8288's **advanced** write commands (AMWC/AIOWC), as on
  the 5160 (IBM wires AMWC/AIOWC to -MEMW/-IOW, MWTC/IOWC are unused; so does
  KFPC-XT, built from the 5160 logic). MartyPC asserts MRDC and AMWC/AIOWC
  from T2 (`cpu_808x/cycle.rs`; MWTC/IOWC from T3; its raw trace shows
  `I:.A.` from T2), and its CGA table gives reads and writes the same wait
  states from the phase at T2. Our MEMW/IOW are "from T2" in that sense; the
  normal commands would start at the falling edge in T3, after the RDY sample
  that decides T3. Our reads start one CPU clock earlier than MRDC/IORC (in
  T1): a deviation, kept because the cards' wait logic and the MartyPC trace
  are calibrated on it (open point).
- READY: the 5160's 8284 synchronizes RDY in two stages (rising CLK edge,
  then falling edge) and the 8088 samples READY at the next rising edge, the
  one that ends T3/Tw. So RDY at the rising edge that ends T2 decides whether
  T3 is the last state, RDY at the edge that ends T3 whether the first Tw is,
  and so on. `xt_board.sv` samples `isa_ready` on `rdy_ce` (`pc_clocks`, 2
  `clk` before `cpu_step`: the edge, less the RDY setup time) into the
  register that drives READY_IN, so READY_IN is stable over the clock before
  the step and the step's own (biu88 reads it on the step's clock, and its
  copy `p1_ready` two clocks later). biu88 decides at that step whether the
  T3/Tw it enters is the last (MartyPC: wait states fixed at T2).
- A card that pulls IOCHRDY low on the strobe therefore stretches both kinds
  of cycle: MEMR/IOR are 33 `clk` old at the first sample, MEMW/IOW 12
  (IBM's rule for the I/O channel: "drive it low immediately upon detecting a
  valid address and a read or write command"). Until 2026-10-22 IOCHRDY was
  sampled at `cpu_fall` in T2, the edge where MEMW starts: no write could
  wait (the CGA and MDA wrote at the strobe end as a workaround).
- The DMA wait (`aen | dma_wait`) and the I/O wait state are unchanged: the
  DMA term changes only on `cpu_step`, so `rdy_ce` sees the value `cpu_fall`
  saw (checked in simulation); every CPU I/O cycle gets one wait state,
  counted only where the DMA wait is over (MartyPC's cycle.rs).
- Read data is taken in the `clk` where T4 begins.
- `ce_14m` coincides with `cpu_step` and `cpu_fall` (pc_clocks, any PHASE);
  the card state that `rdy_ce` samples is the one after the dot update for
  the `ce_14m` 1 tick before the step (a CGA must release IOCHRDY 2 ticks
  before its slot, doc/cga.md section 4).

## 4. `pc_system` ports (what the MEGA65 glue sees)

```systemverilog
module pc_system #(
    parameter int RAM_KB  = 640,
    parameter bit CGA_FIT = 1'b1,     // the CGA is in the machine
    parameter int MDA_FIT = 0         // 0 none, 1 IBM MDA, 2 Hercules (doc/mda.md)
) (
    input  logic        clk,          // 100.2273 MHz
    input  logic        reset,        // synchronous, active high, >= 1 CPU clock

    // System RAM, owned by the glue (BRAM on the PC core, SDRAM in Megamiga).
    // Byte port; read data is expected 1 clk after ram_en (BRAM), but the
    // board waits for ram_ack so slower memory may answer later.
    output logic [19:0] ram_addr,
    output logic        ram_en,       // one-clk request
    output logic        ram_we,
    output logic [7:0]  ram_wdata,
    input  logic [7:0]  ram_rdata,
    input  logic        ram_ack,      // read data valid / write done

    // BIOS ROM window F0000-FFFFF (64 KB), owned by the glue (QNICE loads it)
    output logic [15:0] rom_addr,
    input  logic [7:0]  rom_rdata,    // 1 clk latency

    // Video (CGA): on clk with the 14.31818 MHz enable
    output logic        vid_ce,       // = ce_14m
    output logic [3:0]  vid_rgbi,     // {I, R, G, B}; the glue makes colour 6 brown
    output logic        vid_hsync,    // active high
    output logic        vid_vsync,    // active high
    output logic        vid_hblank,
    output logic        vid_vblank,

    // MDA / Hercules video (MDA_FIT != 0), doc/mda.md section 6: one dot per
    // mda_ce (16.257 MHz / Hercules 16.000 MHz on average, 6 or 7 clk);
    // 882 x 370 dots per frame, 18.43 kHz, 49.8 Hz
    output logic        mda_ce,
    output logic        mda_video,    // +VIDEO
    output logic        mda_intens,   // +INTENSITY
    output logic        mda_hsync,    // active high
    output logic        mda_vsync,    // active high
    output logic        mda_hblank,
    output logic        mda_vblank,

    // character ROM, loaded by the glue: 8 KB in the layout of IBM's
    // 5788005 (CGA: 8x8 font at 0x1800, thin font at 0x1000, char * 8 + row;
    // MDA: 0x0000-0x0FFF, rows 0-7 at char * 8 + row, rows 8-15 at 0x0800 +)
    input  logic        font_we,
    input  logic [12:0] font_addr,
    input  logic [7:0]  font_data,
    input  logic        font_thin,    // jumper P3: the thin font

    // Floppy drives A: and B: (rtl/fdc, doc/fdc.md sections 5-6): image
    // geometry per drive, LED outputs, the sector port to the image backend
    input  logic [1:0]       drv_80trk, img_present, img_wp,
    input  logic [1:0][7:0]  img_tracks,
    input  logic [1:0][1:0]  img_heads,
    input  logic [1:0][5:0]  img_spt,
    output logic [1:0]       drv_motor,
    output logic             fdc_active,
    output logic        sp_req, sp_write, sp_drive,
    output logic [7:0]  sp_cyl,  output logic sp_head,  output logic [7:0] sp_sector,
    output logic [15:0] sp_lba,
    input  logic        sp_rd_valid,  input logic [7:0] sp_rd_data,
    output logic        sp_wr_valid,  output logic [7:0] sp_wr_data,
    input  logic        sp_wr_ready, sp_done, sp_err,

    // Hard disk card (rtl/hdc, doc/hdc.md): the XTIDE card's option ROM
    // socket C8000-CBFFF, owned by the glue like the BIOS ROM (QNICE loads
    // it; 0xFF where no image is), two drives and their sector port (the
    // floppy's protocol with an LBA28 address, doc/hdc.md section 5)
    input  logic             hdc_enable,      // the card is in a slot
    input  logic [1:0]       hdc_variant,     // 0 XT-CF/Lo-tech, 1 XTIDE rev 1, 2 XTIDE rev 2
    output logic [13:0]      hdc_rom_addr,
    input  logic [7:0]       hdc_rom_rdata,   // 1 clk latency
    input  logic [1:0]       hd_present,      // [0] master, [1] slave
    input  logic [1:0][27:0] hd_sectors,      // LBA capacity
    input  logic [1:0][15:0] hd_cyls,         // default geometry for IDENTIFY / CHS
    input  logic [1:0][4:0]  hd_heads,        // 1-16
    input  logic [1:0][5:0]  hd_spt,          // 1-63
    output logic             hd_active,       // LED: a command runs or a sector moves
    output logic        hd_sp_req, hd_sp_write, hd_sp_drive,
    output logic [27:0] hd_sp_lba,
    input  logic        hd_sp_rd_valid,  input logic [7:0] hd_sp_rd_data,
    output logic        hd_sp_wr_valid,  output logic [7:0] hd_sp_wr_data,
    input  logic        hd_sp_wr_ready, hd_sp_done, hd_sp_err,

    // Keyboard: XT (set 1) scan codes from the glue
    input  logic [7:0]  kbd_code,
    input  logic        kbd_valid,    // one-clk strobe; dropped if kbd_busy
    output logic        kbd_busy,     // the board has not taken the last code

    // Audio
    output logic        speaker,      // 8253 OUT2 AND port B bit 1

    // Configuration (from the OSM)
    input  logic [7:0]  dip_sw1       // SW1 of the 5160 as the 8255 reads it
                                      // (1 = switch off); bit 0 = switch 1;
                                      // bits 5-4: 11 MDA/Hercules, 10 CGA 80,
                                      // 01 CGA 40 (the primary display)
);
```

Notes (2026-10-21, from the shell build):
- `ram_ack` may come later than 1 clk (the shell answers after 6: the request
  is pipelined on its way to and from 160 BRAM tiles, doc/timing.md);
  `xt_board` takes read data at `ram_ack`, well before the CPU samples it at
  the end of T3.
- The keyboard self-test answer (0xAA after the BIOS holds the clock low for
  more than ~10 ms) comes from `xt_board`; the glue only sends scan codes.
- The CGA's 59.92 Hz against HDMI's 60 Hz drops or repeats a frame about
  every 13 s; a 59.92 Hz HDMI mode would be a new framework exception.
- Timing closure (open): the CPU alone misses 100.2 MHz by 6.6 ns (BIU) and
  2.6 ns (EU); the BIU's state only advances on `cpu_step`, so it can be
  restructured into multicycle paths without changing its behaviour.

Notes (2026-10-22, hard disk):
- The option ROM socket belongs to the XTIDE card (a real XTIDE carries its
  EEPROM): the card decodes MEMR at C8000-CBFFF and returns `hdc_rom_rdata`,
  read one clk after `hdc_rom_addr` like the BIOS ROM. With `hdc_enable` = 0
  neither the ROM nor the I/O ports answer.
- The shell does not wire the card yet: `CORE/sv/pc_system_flat.sv` ties
  `hdc_enable` to 0 and the drives off (doc/hdc.md section 8 is the plan).
- `tb/sys` serves the hard disk from image files (`-X`, `-H`, `-J`, `-V`).

Notes (2026-10-22, MDA):
- The MDA has its own crystal: the card makes 16.257 MHz from `clk` with a
  fractional accumulator (doc/mda.md section 2), so `mda_ce` is not a
  `pc_clocks` enable.
- Both video cards can be fitted (as in a real PC with two monitors). A
  Hercules card never answers at B8000-BFFFF when `CGA_FIT` is set.
- The floppy ports (`drv_*`, `img_*`, `sp_*`) are in `pc_system.sv`;
  doc/fdc.md.

Not yet in the contract: serial/parallel, composite video, turbo. They get
added here when their module exists.

## 5. Verification

- CPU: SingleStepTests (`tb/sst`), see `AGENTS.md`.
- System: `tb/sys/` - Verilator model of `pc_system` with RAM/ROM models,
  runs a BIOS, dumps CGA frames as PNG and a bus trace. The bus trace is the
  thing to compare cycle by cycle against MartyPC.
- Cards: each card has its own TB under `tb/` (`tb/cga`, `tb/mda`,
  `tb/fdc`).
