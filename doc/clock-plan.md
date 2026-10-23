# Clock plan: the PC on the PC10-III's master clock

Status: **done** (2026-10-23, branch `clk28`; section 6 says what was done
and where it went beyond this plan). Sections 1-5 are the assessment of
2026-10-22 (phase C of the z86 work), written while the whole PC ran on
`clk` = 100.2273 MHz = 7 x OSC with clock enables. Since the 8088 is z8086's
EU with biu88 at one step per 8088 clock (doc/z8086.md), nothing in the PC
needs a clock faster than the real machine's. This note is what it takes to
run the PC on the PC10-III's own master clock. Turbo (section 5, step 5) is
still open.

## 1. The master clock

**What is known.** The PC10-III's chipset is the Faraday FE2010A. No Faraday
datasheet could be found; the best description is Sergey Kiselev's
reverse-engineered notes for his Micro 8088 board
(github.com/skiselev/micro_8088, `Documentation/Faraday-XT_Controller-FE2010A.md`):

- the FE2010A takes either a 14.31818 MHz or a 28.63636 MHz crystal, selected
  by pin 16 (XSEL: pulled up = 14.31818, grounded = 28.63636);
- with 14.31818 MHz it makes 4.77 and 7.15 MHz CPU clocks, with 28.63636 MHz
  4.77, 7.15 and 9.54 MHz;
- "when running at 9.54 MHz, the CPU clock duty cycle is 50% (instead of
  33%)";
- configuration register 0x63: bit 5 fast mode (0 RAM wait states), bit 6
  7.15 MHz, bit 7 9.54 MHz; turbo speeds add I/O wait states (4 at 7.15 MHz,
  4 or 6 at 9.54 MHz in the table, which the notes give only partly);
- the 8253's inputs are an internal 1.19 MHz clock.

The PC10-III runs at 4.77, 7.16 and 9.54 MHz (Commodore's specification), and
9.54 MHz needs the 28.63636 MHz crystal, so its master clock is **28.63636
MHz = 2 x OSC** with the CPU clock at /6, /4 and /3. **Not verified** against a
PC10-III schematic or board photo (none found); to confirm: the crystal next to
the FE2010A on a PC10-III mainboard, and XSEL's strap.

**MMCM.** 28.63636 MHz is already made in `CORE/vhdl/clk.vhd`: CLKOUT0 =
VCO 1102.5 MHz / 38.5 (100 MHz x 55.125 / 5), M2M's video clock. The other
setting, 100 MHz x 31.5 / 5 / 22 (VCO 630 MHz, PFD 20 MHz, CLKOUT 22), gives
the same frequency exactly (both are 315/11 MHz); either is in the R6 part's
VCO range (600-1440 MHz, -2 speed grade). The simplest plan: **the PC and
M2M's video input run on the one 28.63636 MHz clock**; the current
`main.vhd` crossing from `main_clk` (pixel registers sampled in two
consecutive video clocks) disappears, `video_ce` becomes `ce_14m`. QNICE
(50 MHz), HyperRAM and HDMI stay as they are. A 100 MHz `main_clk` remains for
nothing in the PC; the SD engine port and the glue's RAMs would move to the
PC's clock or keep their own CDCs (section 4).

## 2. The enables at 28.63636 MHz

| Enable | Now (100.2273 MHz) | At 28.63636 MHz |
|---|---|---|
| `ce_14m` (OSC) | every 7 clk | every 2 clk |
| `cpu_step` (CLK88 rising) | every 21 | every 6 (4.77), 4 (7.16), 3 (9.54) |
| `cpu_fall` (CLK88 falling) | step + 7 | step + 2 (4.77, 1/3 duty); step + 2 (7.16, 50%, assumed); step + 1.5 (9.54, 50%: see below) |
| `rdy_ce` (RDY sample) | step - 2 | step - 1 (35 ns before the edge, about the 8284A's RDY setup time) |
| `ce_pclk` (PCLK/2 = 1.19318 MHz) | every 84 | every 24 |

- One modulo-24 counter (= OSC/12) gives OSC, CLK88 and PCLK at 4.77 MHz with
  the 5160's fixed phase relation, as the modulo-84 counter does now; the
  turbo speeds divide the same counter by 4 and 3 (24 is a multiple of 6, 4
  and 3, so PCLK keeps a fixed phase at every speed: the 8253 runs on OSC/12
  whatever the CPU speed, as on the FE2010A).
- **Duty cycles.** 4.77 MHz on /6: high 2 clk, low 4 = the 8284's 1/3; the
  falling edge (`cpu_fall`) exists on the grid. 7.16 MHz on /4: the FE2010A's
  duty is not documented; 50% (2/2) or 25% (1/3) are both on the grid. 9.54 MHz
  on /3 with 50% duty: the falling edge is 1.5 clk after the rising one, not on
  the grid. The board needs `cpu_fall` only as an ordering point (MEMR/IOR at
  the falling edge in T1, MEMW/IOW in T2, the DMA wait sample), so at 9.54 MHz
  it can be step + 1 or step + 2 without changing any CPU-clock-level timing;
  where a card times a strobe in OSC ticks (the CGA's RD_LEAD/WR_LEAD) the half
  OSC tick of difference matters and must be calibrated against a trace (no
  MartyPC reference at turbo speeds exists). A DDR-like falling-edge enable on
  the 28.636 MHz clock's falling edge is possible but not worth it.
- Switching speed (port 0x63) must happen at a CLK88 boundary that is common
  to both rates (a multiple of 12 clk), so that no CPU clock is shortened.

## 3. Constants in clk units, module by module

**rtl/system**
- `pc_clocks.sv`: the counters (84 -> 24, 21 -> 6/4/3, 7 -> 2), PHASE (now in
  0..83; *Area 5150*'s CPU-CGA phase is in OSC ticks, so the parameter keeps
  its meaning in OSC units), the turbo divider and its switch.
- `xt_board.sv`: everything is in CPU clocks or on the enables (bus commands
  at `cpu_fall`, READY on `rdy_ce`, AEN/DMA on `cpu_step`), except: `cmd_en`
  (the CPU's commands one clk after AEN falls: one clk = 35 ns is still the
  gap the cards need), `DRQ0_SKEW * 21` (simulation only: * 6), the 8237's
  strobes (on `cpu_step`/`cpu_fall`), the RAM request (`ram_en` -> `ram_ack`:
  the board takes read data at `ram_ack`, at the latest T4; at 28.6 MHz a T3 is
  6 clk, so the RAM may answer in at most ~10 clk, see `pc_ram`), the keyboard
  delays (`KBD_SEND` 4773, `KBD_RESET` 47727: CPU clocks at 4.77 MHz, i.e. 1 ms
  and 10 ms; at the turbo speeds they must count `ce_pclk` or OSC instead).
- `pc_system.sv`: the enables are passed through; nothing else.

**The CPU** (`rtl/cpu`)
- `cpu_z86.sv`: `EU_DELAY` 3 -> 1 (the EU's enable one clk after the step:
  biu88's outputs are registers set at the step, the EU reads them at step +
  1; at 9.54 MHz the next step is at + 3, so the EU's outputs have 2 clk to
  reach biu88).
- `cpu8088.xdc`: the 3-clock multicycle paths between EU and biu88
  registers go. Out of context (doc/history.md, phase B) the longest of them
  are EU -> EU 18.1 ns, EU -> biu88 18.1 ns, biu88 -> biu88 17.7 ns, biu88 ->
  EU 11.1 ns: single-cycle at 34.9 ns. The constraint would be wrong at
  28.6 MHz anyway (biu88 -> EU is EU_DELAY = 1 clk there).
- The SingleStepTests harness (`tb/sst/sst_run.cpp`): `STEP` = 4.7727/100.2273
  per core clock -> 1/6, no phase sweep needed (every CPU clock is 6 clk).

**Cards**
- CGA (`rtl/video/cga`): everything in OSC ticks (`ce_14m`) except `CE_DELAY`
  (6 clk: the dot tick one clk before the next `ce_14m`, so that the card's
  state for an instant is complete before the board samples at the CPU edge).
  At 2 clk per tick it becomes 1. `RD_LEAD` 6 / `WR_LEAD` 3 ticks: from the
  card seeing MEMR/MEMW fall to MartyPC's phase reference. At 4.77 MHz
  `cpu_fall` is 1 tick after the step on both clocks (7 clk at 100 MHz, 2 at
  28.6 MHz), so they stay; what moves is where inside a tick the card sees a
  strobe (CE_DELAY), to be checked with `tb/cga waits` and the `sys_run -C`
  oracle, both in ticks. The IOCHRDY release (2 ticks before the slot) is in
  ticks.
- MDA/Hercules (`rtl/video/mda`): its own crystal from a fractional
  accumulator on clk: `DOT_INC/DOT_MOD` 59609/367500 (16.257 MHz from
  100.2273) -> 16.257/28.636 (MDA: 16.257 MHz; a dot every 1.76 clk, still
  fewer dots than clocks), Hercules 704/4410 -> 16.000/28.636. The dots then
  jitter by one 35 ns clk instead of 10 ns; the monitor does not care, the
  HDMI scaler takes `mda_ce`.
- FDC (`rtl/fdc`): the 1 us enable `US_NUM/US_DEN` = 22/2205 (100.2273 MHz =
  2205/22) -> 11/315 (28.63636 MHz = 315/11). The 765's times are in us
  (`BYTE_US`, `RQM_DELAY_US`, `RESET_US`), the DMA on the board's enables.
  `REG_DECODE` (registered strobe edges, `isa_*_next`) keeps working.
- XTIDE (`rtl/hdc`): `ata_dev.sv` `US_NUM/US_DEN` the same; `CMD_US`, `BLK_US`,
  `RESET_US` in us.

**CORE**
- `clk.vhd`: one PC clock = the existing 28.63636 MHz output (section 1).
- `pc_ram.vhd`: the 6-clk pipeline (request copy, per-group and per-bank
  registers, output mux) was needed to spread 160 RAMB36 at 100 MHz; at
  28.6 MHz one register stage each way is plenty: latency 2 (the board would
  also accept 6: 6 clk = 210 ns, inside a T3 of 210 ns at 4.77 MHz but not
  inside one of 105 ns at 9.54 MHz with a READY sampled 1 clk before the
  edge; so it must shrink).
- `pc_bios.vhd`, `pc_font.vhd`, `pc_ucode.vhd`: 1-clk reads and copy engines,
  unchanged (the copies take 3.5x longer, still well under a millisecond).
- `pc_fdd_sd.vhd`: the request/answer toggles between the PC's clock and
  QNICE's (50 MHz) carry stable payloads; nothing depends on which clock is
  faster. The engine port is on QNICE's clock already.
- `main.vhd`: keyboard (`keyboard.vhd`, a holdoff of 7 clk between codes:
  fine), video (section 1: the crossing goes), audio (the speaker bit into
  PCM, any clock).
- `CORE.xdc`: the `main_clk` exceptions go; the 28.6 MHz clock is
  constrained by the MMCM. The CPU's `cpu8088.xdc` exceptions go.
- Timing: the whole PC closed at 100.2273 MHz with +0.065 ns (pc10-real-e);
  at 34.9 ns it closes by a large margin, so the multicycle constraints and
  the extra pipeline registers added for 100 MHz (pc_ram, `pc_clocks`'
  registered enables; biu88's old fast/bus split went with phase B) can be
  removed step by step.

## 4. What does not change

- Every CPU-clock-level behaviour: the SST traces and the MartyPC system trace
  are per 8088 clock; the board's READY, DMA and command timing is per CPU
  clock and per `cpu_fall`.
- The OSC-tick timing of the CGA (the snow, the wait states), as long as
  `ce_14m` keeps its phase to CLK88 (section 2).
- M2M's other clocks.

## 5. Order of work (suggested)

1. `pc_clocks` with a CLK_PER_OSC parameter (7 now, 2 later) and the turbo
   divider; the tb/sys trace at 4.77 MHz must stay byte-identical when only
   the master clock changes (the simulations run the same model at a
   different clk).
2. CPU: `EU_DELAY` 1, the SST harness at 6 clk per CPU clock; full suite.
3. Cards: FDC/XTIDE `US_*`, MDA `DOT_*`, CGA `CE_DELAY`; their testbenches
   (tb/cga `waits`, tb/mda, tb/fdc, tb/hdc) with the new clock.
4. CORE: clock, `pc_ram` latency, video crossing, constraints; a build.
5. Turbo: 0x63 in the board, wait states (the FE2010A's table), the 9.54 MHz
   falling edge; needs a reference (a PC10-III with a logic analyser, or the
   FE2010A's documentation if it turns up).

## 6. Done (2026-10-23, branch `clk28`)

The whole PC side runs on one 28.63636 MHz clock (MMCM as before: VCO
1102.5 MHz / 38.5; `main_clk` = M2M's video clock, one net). Steps 1-4 of
section 5; turbo (step 5) is not part of it.

- `pc_clocks.sv`: a modulo-24 counter (OSC/12) and the CPU clock's own
  modulo-6 counter (`CPU_DIV`, `CPU_HIGH` = 2: the 8284's 1/3 duty).
  `ce_14m` every 2, `cpu_step` every 6, `cpu_fall` = step + 2, `rdy_ce` =
  step - 1, a new `cpu_prestep` (the clk before the step), PCLK every 24.
  PHASE is in OSC ticks.
- CPU: `EU_DELAY` 1; `rtl/cpu/cpu8088.xdc` deleted (and its entry in
  `CORE/CORE-R6.xpr`, `tools/gen_xpr.py`).
- Board, beyond the plan: on the 100 MHz clock four things happened a clk or
  two after a CPU edge, still before anything else ticked; at 2 clk per OSC
  tick they would have come a tick (or a CPU clock) late (doc/timing.md
  section 5). The commands now end at the edge where T4 begins (`cyc_end`,
  the board mirrors biu88's "last T3/Tw" flag); the 8237 ends its strobes
  one clk before the edge that ends S4 (`cpu_prestep`) and the CPU's
  commands return with AEN (`aen_d` is gone); the 8237's DREQ register takes
  DRQ0's D input; `DRQ0_SKEW` counts CPU clocks of 6 clk.
- CGA, beyond `CE_DELAY` 1: I/O acts in the strobe's last clk (next-clk bus
  values, three new ports), an access counts the tick it starts in, the
  80-column switch takes a pending mode in the post clk, the composite VSYNC
  shift is one clk earlier, and the dots are computed 3 ticks late
  (the character fetch takes 5 clk, a tick 2; doc/cga.md section 2).
  RD_LEAD/WR_LEAD and the IOCHRDY release are unchanged (ticks).
- MDA: 59609/105000 (16.257 MHz), Hercules 352/630 (16.000 MHz); a falling
  dot edge that comes after the rising one in the same clk is taken in the
  next clk (`fall_pend`; without it the accumulator could pass it unseen).
- FDC/XTIDE: `US_NUM/US_DEN` 11/315; the XTIDE's IDENTIFY keeps CMD_US from
  the command (it was reloaded after writing the sector, 512 clk).
- CORE: `clk.vhd` one output; `main.vhd` registers RGBI, syncs, blanks and
  `vid_ce` together on that clock (no crossing); `pc_ram.vhd` latency 2;
  CORE.xdc: one clock, no multicycle, no `FORCE_MAX_FANOUT`. QNICE <-> main
  stays bounded to 20 ns. `pc_fdd_sd`, `pc_bios`, `pc_font`, `pc_ucode`,
  `keyboard`: unchanged (their copies take 3.5 times longer, under 0.3 ms).
- Testbenches: tb/sys (`CLK_HZ`), tb/sst (6 clk per CPU clock, integer),
  tb/cga (2/6 clk, the T4 end, next-clk values, `LAT` 6), tb/mda (the same,
  the model's accumulator), tb/fdc and tb/hdc (bus cycles in units of
  `C` = 6), tb/shell (clock period, RAM latency 2, longer copy waits, the
  stand-in's constants).
- Results: doc/history.md (2026-10-23).
