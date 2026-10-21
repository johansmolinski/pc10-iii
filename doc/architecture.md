# PC10-III core - architecture

Status: 2026-10-21, the contract between the parallel work tracks (CPU,
system board, CGA, MEGA65 shell). Change it only together with every module
it names.

## 1. Clocks

One clock domain for the whole PC: **`clk` = 100.2273 MHz = 7 x 14.31818 MHz**
(MMCM from the board's 100 MHz: M = 55.125, D = 5, O = 11, VCO 1102.5 MHz;
exact, 2205/22 MHz). Everything PC-side runs on `clk` with clock enables:

| Enable | Rate | Period in `clk` | Use |
|---|---|---|---|
| `ce_14m` | 14.31818 MHz (OSC) | 7 | CGA dot clock, composite, the master phase |
| `cpu_step` | 4.77273 MHz (CLK88) | 21 | biu88/EU step (the 8088 clock edge) |
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
     +- cga_card    rtl/video/cga/cga_card.sv
     +- later: MDA/Hercules, FDC (765), XTIDE, COM/LPT
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

A card's read data must be valid within 2 `clk` of the strobe going low and
held while it stays low.

Bus timing (`xt_board.sv`, the 8288 function; marked CAL there, cards such as
the CGA depend on it):
- MEMR/IOR/INTA go low at the CLK falling edge (`cpu_fall`) in T1, MEMW/IOW
  at the falling edge in T2; all go high in the `clk` where T4 begins (+1).
- READY: `isa_ready` is synchronized at `cpu_fall`; the BIU samples READY as
  it enters T3 and each Tw (it says whether that state is the last one);
  every CPU I/O cycle gets one wait state.
- Read data is taken in the `clk` where T4 begins.
- `ce_14m` coincides with `cpu_step` and `cpu_fall` (pc_clocks, any PHASE).

## 4. `pc_system` ports (what the MEGA65 glue sees)

```systemverilog
module pc_system #(
    parameter int RAM_KB = 640
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

    // CGA character ROM, loaded by the glue: 8 KB in the layout of IBM's
    // 5788005 (8x8 font at 0x1800, thin font at 0x1000; char * 8 + row)
    input  logic        font_we,
    input  logic [12:0] font_addr,
    input  logic [7:0]  font_data,
    input  logic        font_thin,    // jumper P3: the thin font

    // Keyboard: XT (set 1) scan codes from the glue
    input  logic [7:0]  kbd_code,
    input  logic        kbd_valid,    // one-clk strobe; dropped if kbd_busy
    output logic        kbd_busy,     // the board has not taken the last code

    // Audio
    output logic        speaker,      // 8253 OUT2 AND port B bit 1

    // Configuration (from the OSM)
    input  logic [7:0]  dip_sw1       // SW1 of the 5160 as the 8255 reads it
                                      // (1 = switch off); bit 0 = switch 1
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

Not yet in the contract: floppy, hard disk, serial/parallel, MDA,
composite video, turbo. They get added here when their module exists.

## 5. Verification

- CPU: SingleStepTests (`tb/sst`), see `AGENTS.md`.
- System: `tb/sys/` - Verilator model of `pc_system` with RAM/ROM models,
  runs a BIOS, dumps CGA frames as PNG and a bus trace. The bus trace is the
  thing to compare cycle by cycle against MartyPC.
- Cards: each card has its own TB under `tb/`.
