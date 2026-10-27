# PC10-III core - architecture

Status: 2026-10-25 (the PC on 28.63636 MHz, doc/clock-plan.md; the PVC4), the contract
between the parallel work tracks (CPU, system board, CGA, floppy, hard disk,
MEGA65 shell). Change it only together with every module it names.

## 1. Clocks

One clock domain for the whole PC: **`clk` = 28.63636 MHz = 2 x 14.31818
MHz**, the PC10-III's master clock (its FE2010A takes a 28.63636 MHz crystal;
doc/clock-plan.md). MMCM from the board's 100 MHz: M = 55.125, D = 5,
O = 38.5, VCO 1102.5 MHz; exact, 315/11 MHz. The same net is M2M's video
clock. Everything PC-side runs on `clk` with clock enables:

| Enable | Rate | Period in `clk` | Use |
|---|---|---|---|
| `ce_14m` | 14.31818 MHz (OSC) | 2 | CGA dot clock, composite, the master phase |
| `cpu_step` | 4.77273 MHz (CLK88) | 6 | biu88 step (the 8088 clock's rising edge) |
| `cpu_fall` | 4.77273 MHz | 6, 2 after `cpu_step` | the falling CLK edge (8288 commands, 8237) |
| `rdy_ce` | 4.77273 MHz | 6, 1 before `cpu_step` | the 8284's RDY sample (READY) |
| `cpu_prestep` | 4.77273 MHz | 6, 1 before `cpu_step` | the 8237's strobe end in S4 (section 3) |
| `ce_pclk` | 1.19318 MHz (PCLK) | 24 | 8253 counters (OSC/12) |

An enable is high for one `clk`; what it enables happens at the clock edge
that ends that `clk`.

- All enables derive from **one modulo-24 counter** and the CPU clock's own
  modulo-6 counter (`pc_clocks.sv`), so the OSC/CLK88/PCLK phase relation is
  fixed like the 8284 + 74LS175 on the 5160 board. *Area 5150* depends on the
  CPU-CGA phase; the counter's reset phase is a parameter (OSC ticks).
- The 8088 CLK has the 8284's 1/3 duty cycle: high for 2 `clk`, low for 4.
  Logic that the IBM schematic clocks on the falling CLK edge uses `cpu_fall`.
- `ce_14m`, `cpu_step` and `cpu_fall` are in even `clk`s: the edges that end
  them are OSC rising edges. `rdy_ce`, `cpu_prestep` and the CGA's dot tick
  (`cga_card.sv` CE_DELAY = 1) are in odd ones, half an OSC period later.
  With only one `clk` between the board's edge and the card's tick, nothing
  the board does on a CPU edge may take a `clk` longer before a card sees it
  (the commands' end, the DMA hand-over, section 3; the CGA's own bus logic,
  doc/cga.md section 2; doc/timing.md section 5).
- The 8088 (`cpu8088`, doc/z8086.md): biu88 steps at `cpu_step`; z8086's EU
  executes one microinstruction per 8088 clock, at `cpu_step` + 1 `clk` (its
  clock enable, `EU_DELAY`). Both change state only there; every path between
  them is an ordinary single-clock path (no multicycle constraints).
- Turbo (doc/turbo.md, 2026-10-26): in the PC10-III chipset mode the
  FE2010A's port 63h bits 7-6 divide the CPU clock by 4 (7.16 MHz, CLK high
  2 `clk`, `cpu_fall` step + 2) or by 3 (9.54 MHz, `cpu_fall` step + 1);
  `rdy_ce`/`cpu_prestep` stay the `clk` before the step. A new speed starts
  where the modulo-24 counter is 0 or 12 (every period starts there: no
  shortened clock, OSC and PCLK keep their phase). `ce_477` is a fixed
  4.77 MHz enable (= `cpu_step` at 4.77 MHz) for real-time logic that used to
  count CPU clocks (the keyboard's delays). Everything else that is real time
  (8253, OSC, dot clocks, FDC/XTIDE timers) was on the fixed enables already.

## 2. Module tree

```
pc_system          (rtl/system/pc_system.sv)  the PC: everything below
 +- pc_clocks       clock enables (and the FE2010A's turbo divider)
 +- cpu8088         rtl/cpu/cpu8088.sv: z8086 EU (Intel's 8088 microcode, loaded at
 |                   start-up) + biu88 behind 8088 max-mode pins (doc/z8086.md)
 +- xt_board        rtl/system/xt_board.sv: the 5160 system board logic
 |   +- 8288 function (bus commands from S2-S0)
 |   +- 8237 DMA, page register, refresh (8253 ch1 -> DRQ0)
 |   +- 8253 PIT, 8259 PIC, NMI mask, speaker
 |   +- ports 60-63: the 5160's 8255 PPI or the PC10-III's FE2010A port logic
 |       (input fe2010a, taken in reset; the menu's "Chipset")
 |   +- ready / wait-state logic (DMA hold, IOCHRDY; xt_wait.sv: the board's
 |       wait states, the FE2010A's turbo table)
 |   +- keyboard interface (shift register, IRQ1, clear via PB7)
 +- the "ISA slots": modules on the card bus (section 3)
     +- system RAM (planar, behind the abstract memory port)
     +- BIOS ROM (F0000-FFFFF, behind the ROM port)
     +- cga_card    rtl/video/cga/cga_card.sv     (CGA_FIT)
     +- mda_card    rtl/video/mda/mda_card.sv     (MDA_FIT: MDA or Hercules)
     +- pvc4        rtl/video/pvc4/pvc4.sv        (PVC4_FIT: the PC10-III's onboard
     |               video, the Paradise PVC4, doc/pvc4.md)
     +- cbm_cfg230  rtl/system/cbm_cfg230.sv      (PVC4_FIT: the Commodore
     |               configuration register 230h, the 5720's)
     +- msm6242     rtl/system/msm6242.sv         (PVC4_FIT: the PC10-III's real-time
     |               clock, an MSM6242B at 2C0h-2CFh while 230h bit 6 is set; doc/rtc.md)
     +- fdc_card    rtl/fdc/fdc_card.sv: the diskette adapter (765), doc/fdc.md
     +- xtide_card  rtl/hdc/xtide_card.sv: XTIDE hard disk card + option ROM socket, doc/hdc.md
     +- xta_card    rtl/hdc/xta_card.sv           (XTA_FIT: the PC20-III's hard disk, a
     |               WD93024-X on CN202, doc/xta.md)
     +- uart8250    rtl/system/uart8250.sv        (PVC4_FIT: the PC10-III's INS8250 at
     |               3F8h/2F8h, IRQ4/IRQ3, 230h bits 3-2; doc/ports.md)
     +- lpt_ppc1    rtl/system/lpt_ppc1.sv        (PVC4_FIT: the parallel port at
     |               3BCh/378h/278h, IRQ7, 230h bits 1-0)
     +- cbm_mouse   rtl/system/cbm_mouse.sv       (PVC4_FIT: the 5720's bus mouse at
                     23Ch-23Eh, IRQ2, 230h bit 4)
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

Memory map of the cards: CGA B8000-BBFFF (mirrored to BFFFF); the PVC4
B8000-BFFFF (colour) or B0000-B7FFF and, with 3BF bit 1, B8000-BFFFF
(mono), I/O 3D0-3DF or 3B0-3BF, and 230h; the XTIDE
card's option ROM C8000-CBFFF (16 KB; the BIOS's option ROM scan finds it).
I/O: FDC 3F0-3F7, XTIDE 300-31F (variant 0) or 300-30F (variants 1/2), the
PC20-III's hard disk 320-323 (DMA 3, IRQ 5).

Bus timing (`xt_board.sv`, the 8288 function; marked CAL there, cards such as
the CGA depend on it):
- MEMR/IOR/INTA go low at the CLK falling edge (`cpu_fall`) in T1, MEMW/IOW
  at the falling edge in T2; all go high at the CLK edge where T4 begins
  (`cyc_end`: the board knows in the `clk` before that edge that the CPU
  enters T4, from READY at the edge that started the running T3/Tw; on the
  100 MHz clock they went high one `clk` after that edge).
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
  and so on. `xt_board.sv` samples `isa_ready` on `rdy_ce` (`pc_clocks`, 1
  `clk` = 35 ns before `cpu_step`: the edge, less the RDY setup time) into
  the register that drives READY_IN, so READY_IN is stable over the step's
  clock (biu88 reads it there). biu88 decides at that step whether the T3/Tw
  it enters is the last (MartyPC: wait states fixed at T2).
- A card that pulls IOCHRDY low on the strobe therefore stretches both kinds
  of cycle: MEMR/IOR are 9 `clk` old at the first sample, MEMW/IOW 3
  (IBM's rule for the I/O channel: "drive it low immediately upon detecting a
  valid address and a read or write command"). Until 2026-10-22 IOCHRDY was
  sampled at `cpu_fall` in T2, the edge where MEMW starts: no write could
  wait (the CGA and MDA wrote at the strobe end as a workaround).
- The DMA wait (`aen | dma_wait`) and the board's wait states: the DMA term
  changes only on `cpu_step`, so `rdy_ce` sees the value `cpu_fall` saw
  (checked in simulation). The board's wait states (`xt_wait.sv`) count only
  where the DMA wait is over (MartyPC's cycle.rs): one on every CPU I/O cycle
  at 4.77 MHz; at the FE2010A's turbo speeds its table (doc/turbo.md section
  3): I/O 4 (7.16) or 6 (9.54; 4 with 63h bit 6), memory cycles outside the
  on-board RAM 2 or 4 (none with 63h bit 5), on-board RAM none.
- In the FE2010A mode the DMA takes the bus only between CPU bus cycles (the
  FE2010's RQ/GT): the hold flip-flop takes a T3/Tw only when it is the last.
  Otherwise the turbo wait states let a refresh split a CPU command into two
  strobes (doc/turbo.md section 3). The 5160 mode keeps MartyPC's rule.
- After a DMA transfer the CPU's commands come back with AEN low (`cmd_en`
  in `xt_board.sv`). AEN falls at the CLK edge that ends S4, and the 8237
  ends its strobes one `clk` before that edge (`cpu_prestep`, KF8237), so a
  CPU command the DMA held starts after a high phase: without it, it would
  continue the 8237's strobe of the same kind (a refresh's IOW running into
  the CPU's OUT; the FDC dropped the DOR write, 2026-10-22). A strobe line
  never changes owner while it is low (checked in simulation), so a strobe
  that starts with AEN high is the DMA's to its end. (On the 100 MHz clock
  the gap was the `clk` after AEN fell; at 28.63636 MHz that `clk` is after
  the cards' next dot tick, so the gap moved before the edge. The memory
  still drives a DMA read's data in that last `clk`.)
- DRQ0 (refresh): the 8237's own DREQ register takes the 74LS74's D input,
  so a request that the 8253 raises at a rising CLK edge is seen at the
  falling edge 2 `clk` later, as on the 100 MHz clock.
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
    parameter int MDA_FIT = 0,        // 0 none, 1 IBM MDA, 2 Hercules (doc/mda.md)
    parameter int DRQ0_SKEW = 0,      // simulation only
    parameter bit FE2010A = 1'b0,     // the PC10-III's FE2010A port logic (xt_board)
    parameter bit PVC4_FIT = 1'b0,    // the PC10-III's onboard PVC4 and 230h (doc/pvc4.md)
    parameter bit XTA_FIT = 1'b0      // the PC20-III's hard disk on CN202 (doc/xta.md)
) (
    input  logic        clk,          // 28.63636 MHz
    input  logic        reset,        // synchronous, active high, >= 1 CPU clock
    input  logic        fe2010a,      // the chipset (xt_board): 1 = the PC10-III's
                                      // FE2010A port logic, 0 = the 5160's 8255;
                                      // taken while reset is high

    // The 8088's microcode bundle (tools/mkucode.py, doc/z8086.md), owned by
    // the glue (QNICE loads /pc10/ucode.bin, pc_ucode.vhd): the file, one byte
    // per clk at offset ucl_addr, while reset is high. The PC must stay in
    // reset until it has been loaded (the CPU's tables keep it over resets).
    input  logic        ucl_we,
    input  logic [12:0] ucl_addr,
    input  logic [7:0]  ucl_data,

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
    // mda_ce (16.257 MHz / Hercules 16.000 MHz on average, 1 or 2 clk);
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
    // PVC4 (doc/pvc4.md section 8): a 32 KB Commodore character ROM image
    // (font_addr_hi = bits 14-13, font_cbm = 1; the IBM cards take only
    // font_addr_hi = 0), the CONFIG switches 1 and 2 (1 = off), MONO and the
    // mono personality (vid_ce is then its 16.257 MHz dot)
    input  logic [1:0]  font_addr_hi,
    input  logic        font_cbm,
    input  logic [1:0]  cbm_dip,
    output logic        vid_mono,
    output logic        vid_monomode,

    // Floppy drives A: and B: (rtl/fdc, doc/fdc.md sections 5-6): image
    // geometry per drive, LED outputs, the sector port to the image backend
    input  logic [1:0]       drv_80trk, img_present, img_wp,
    input  logic [1:0][7:0]  img_tracks,
    input  logic [1:0][1:0]  img_heads,
    input  logic [1:0][5:0]  img_spt,
    output logic [1:0]       drv_motor,
    output logic             fdc_active,
    output logic [1:0]       drv_select,   // drive LED / drive sound (doc/fdc.md section 6)
    output logic             drv_step, drv_step_in,
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

    // The PC20-III's hard disk (XTA_FIT, rtl/hdc/xta_card.sv, doc/xta.md):
    // JMP208, the medium (a raw image of 41,820 sectors), the drive's LED,
    // its sector port (the hd_sp_* protocol, LBA < 41820, no drive bit)
    input  logic        xta_enable,       // JMP208 in position B (0: 320-323 float)
    input  logic        xta_present,      // an image is mounted
    output logic        xta_active,       // LED: busy or writing back
    output logic        xta_sp_req, xta_sp_write,
    output logic [27:0] xta_sp_lba,
    input  logic        xta_sp_rd_valid,  input logic [7:0] xta_sp_rd_data,
    output logic        xta_sp_wr_valid,  output logic [7:0] xta_sp_wr_data,
    input  logic        xta_sp_wr_ready, xta_sp_done, xta_sp_err,

    // The PC10-III's real-time clock (PVC4_FIT, rtl/system/msm6242.sv,
    // doc/rtc.md): seeded from M2M's main_rtc_i (MiSTer's 65-bit format, BCD,
    // years since 2000, bit 64 a toggle per new value); rtc_set = one clk when
    // the PC has set the clock, rtc_time = the clock in the register order of
    // M2M's RTC device (hundredths .. year since 2000, weekday 0 = Monday)
    input  logic [64:0] rtc_seed,
    output logic        rtc_set,
    output logic [63:0] rtc_time,

    // Keyboard: XT (set 1) scan codes from the glue
    // The PC10-III's serial port, parallel port and bus mouse (PVC4_FIT,
    // doc/ports.md): the 8250's pins (TTL polarity; inputs asynchronous), the
    // parallel port's pins (inputs synchronized by the glue; lpt_data is also the
    // Covox's DAC), the 9-pin mouse port's lines (Amiga H/HQ/V/VQ, asynchronous)
    output logic        ser_txd, ser_rts_n, ser_dtr_n,
    input  logic        ser_rxd, ser_cts_n, ser_dsr_n, ser_dcd_n, ser_ri_n,
    output logic [7:0]  lpt_data,
    output logic        lpt_strobe_n, lpt_autofd_n, lpt_init_n, lpt_selin_n,
    input  logic        lpt_busy, lpt_ack_n, lpt_pe, lpt_slct, lpt_err_n,
    input  logic        mouse_xp, mouse_xq, mouse_yp, mouse_yq,
    input  logic [2:0]  mouse_btn_n,  // {right, middle, left}, 0 = pressed

    input  logic [7:0]  kbd_code,
    input  logic        kbd_valid,    // one-clk strobe; dropped if kbd_busy
    output logic        kbd_busy,     // the board has not taken the last code

    // Audio
    output logic        speaker,      // 8253 OUT2 AND port B bit 1

    // Configuration (from the OSM)
    input  logic [7:0]  dip_sw1       // SW1 of the 5160 as the 8255 reads it
                                      // (1 = switch off); bit 0 = switch 1;
                                      // bits 5-4: 11 MDA/Hercules, 10 CGA 80,
                                      // 01 CGA 40 (the primary display); with
                                      // the FE2010A bits 5-4 are its VID pins
                                      // (01 = CGA 80 for the Commodore BIOS),
                                      // the rest the switch register's reset
                                      // value (the shell: 5D FE2010A, 6D 8255)
);
```

Notes (2026-10-21, from the shell build):
- `ram_ack` may come later than 1 clk (the shell answers after 2 since
  2026-10-23, after 6 on the 100 MHz clock, doc/timing.md);
  `xt_board` takes read data at `ram_ack`, well before the CPU samples it at
  the end of T3.
- The keyboard self-test answer (0xAA after the BIOS holds the clock low for
  more than ~10 ms) comes from `xt_board`; the glue only sends scan codes.
- The CGA's 59.92 Hz against HDMI's 60 Hz drops or repeats a frame about
  every 13 s; a 59.92 Hz HDMI mode would be a new framework exception.
- Timing closure: at 100.2273 MHz it took multicycle paths in the CPU and
  the retimings of doc/timing.md; since 2026-10-23 the PC runs on 28.63636
  MHz without exceptions (doc/clock-plan.md section 6).

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

Notes (2026-10-25, PVC4):
- With `PVC4_FIT` the PC10-III's onboard video replaces the CGA on `vid_*`
  (`CGA_FIT`/`MDA_FIT` remain, as expansion cards; the shell's
  `pc_system_flat` sets `PVC4_FIT` = 1, `CGA_FIT` = 0). In its colour
  personality `vid_ce` = `ce_14m`; in its mono personality `vid_ce` is a
  16.257 MHz dot from a fractional accumulator, as `mda_ce`.
- A card that is not fitted sees no bus strobes (the CGA too since then).
- The PVC4's power-up straps come from `cbm_dip[1]` (DIP switch 2) and are
  sampled at `reset`.

Notes (2026-10-25, PC20-III hard disk):
- `XTA_FIT` = 0 (the default) removes the card. The shell's
  `pc_system_flat` sets it to 1 (since 2026-10-26, doc/xta.md section 11):
  `xta_enable` (JMP208) and `xta_present` are both "an image of exactly
  41,820 sectors is mounted as C:", the sector port goes to
  `CORE/vhdl/pc_fdd_sd.vhd` (drive 2, its second sector port, served in
  turn with the FDC's), `xta_active` to the drive LED (red).
- `tb/sys` serves the drive from an image file (`make XTA=1`, `-A`,
  `-jmp208`, `-WA`, `-xl`).

Notes (2026-10-26, real-time clock):
- The chip has no reset: it keeps time across PC resets like the battery-backed
  original; its 32.768 kHz is an exact fractional accumulator on `clk`.
- Without `PVC4_FIT` there is no RTC (`rtc_set` 0, `rtc_time` 0); with it, the
  chip answers only while 230h bit 6 is set (the Commodore BIOS sets it in
  every POST; GLaBIOS on the IBM chipset never does, so 2C0h stays open there).
- The shell: `pc_system_flat` passes `main_rtc_i` in and the write-back out to
  `CORE/vhdl/pc_rtc.vhd` (doc/m2m-shell.md section 8). tb/sys: `-R` seeds it.

Notes (2026-10-26, serial, parallel, mouse; doc/ports.md):
- With `PVC4_FIT` (the PC10-III board) the 5720's ports exist: the INS8250,
  the parallel port, the bus mouse, each answering only where 230h enables it;
  their interrupts are ORed into `isa_irq` (IRQ2 mouse, IRQ3/IRQ4 serial,
  IRQ7 parallel). Without `PVC4_FIT` there are none (outputs idle).
- The shell: `pc_system_flat` passes the pins to `CORE/vhdl/pc_ports.vhd` (the
  PMOD headers, joystick port 1); `main.vhd` mixes `lpt_data` (a Covox) with
  the speaker (`rtl/system/pc_audio_mix.sv`). tb/sys: `-M` mouse moves, `-SL`.

Not yet in the contract: composite video.

## 5. Verification

- CPU: SingleStepTests (`tb/sst`), see `AGENTS.md`.
- System: `tb/sys/` - Verilator model of `pc_system` with RAM/ROM models,
  runs a BIOS, dumps CGA frames as PNG and a bus trace. The bus trace is the
  thing to compare cycle by cycle against MartyPC.
- Cards: each card has its own TB under `tb/` (`tb/cga`, `tb/mda`,
  `tb/fdc`, `tb/hdc`, `tb/xta`, `tb/rtc`, `tb/ports`).
