# Timing closure outside the CPU

Status: 2026-10-21, branch `board-timing`. The CPU (`rtl/cpu`) is closed on
its own branch (`cpu-timing`); this is everything else in `pc_system` and the
glue that failed 100.2273 MHz in build `pc10-real-d` (doc/m2m-shell.md
section 11).

**Since 2026-10-23 the PC runs on 28.63636 MHz** (branch `clk28`,
doc/clock-plan.md): sections 1-4 are the history of the 100 MHz design;
section 5 says what of it is left and what the slower clock changed.

The rule: **no change of behaviour**. Every change in `pc_system` is a
retiming that keeps the value of every signal the rest of the design sees in
every `clk`, or one whose difference is provably never used (the 8253
decrements, the DACK flip-flop's next value), each checked against the
original expression in simulation. Two exceptions, both invisible to the PC:
the glue's RAM answers 2 clocks later (section 2.10), and in the first `clk`
of a PC reset the registered bus address can differ from the original while
everything that reads it is being reset (section 2.11). No multicycle
constraints.

## 1. What failed (pc10-real-d) and why

| From -> to | Worst | The path |
|---|---|---|
| board -> board | -1.474 | 8237 `dack_sense_active_high` -> DACK (XOR with `dma_acknowledge_ff`) -> bus address select -> `isa_addr` -> CGA `sel_mem`/`mem_any`/`slot` -> `isa_ready` -> 8237 `next_state` -> `next_word` -> CE of the 64 address/count registers (15 levels) |
| board -> board | -1.323 | 8253 counter 2 `count` -> BCD `decrement` twice -> mode 3 `count_next == 0` -> `count_period` -> `counter_out` (hidden behind the first in the per-endpoint report) |
| FDC -> FDC | -1.427 | `dor[0]` (drive select) -> geometry mux -> LBA multiplier (2 DSPs) -> `sp_lba` |
| CPU -> FDC | -1.061 | BIU `latch` (bus status) -> `cpu_iow` -> `isa_iow_n` -> 765 |
| board -> FDC | -0.982 | DACK / AEN -> bus address -> FDC decode -> `cpu_rd` -> 765 (10 levels) |
| FDC -> FDC | -0.561 | 765 `op` (fanout 53) -> `cur_tag` compare -> `res`, `fetch_pend` |
| CPU -> board | -0.557 | BIU `latch` -> `io_wr_n` -> 8259 |
| glue | -0.750 | `pc_ram` `r_addr` -> per-bank copies (one register, fanout 20, across the die) |
| board -> BIOS ROM | -0.112 | DACK -> bus address -> `rom_addr` (block RAM address pins) |

Most of it is one thing: the bus address (`bus_addr`, = `isa_addr`,
`ram_addr`, `rom_addr`) was three LUT levels behind the 8237's DACK polarity
XOR, and every card decodes it.

## 2. The changes

### 2.1 8237: DACK as a register (`KF8237_Timing_And_Control.sv`)

`dma_acknowledge` was `dack_sense_active_high ? dma_acknowledge_ff :
~dma_acknowledge_ff`. It is now a register whose D input is the same XOR of
the two registers' D inputs (`dack_sense_next`, `dma_acknowledge_ff_next`,
written out from their always blocks: master clear, command register write,
the CLK-falling-edge update). A register loaded with f(D of A, D of B) holds
f(A, B) in every clk (after reset both give 4'b1111). The D input is
exported as `dma_acknowledge_next` for the board.

The DACK flip-flop (and its next value) is loaded only on the transitions out
of S1 and S4, written out from those cases of the state decoder, where READY
plays no part. The original also loaded it in two other cases that change
nothing:
- `next_state == SI -> 0` in SI: it is 0 already there (cleared when SI is
  entered, from S4 or by reset or master clear);
- `next_state == S2 -> dma_acknowledge_internal` in S2 (compressed timing,
  verify, not ready): it holds that value already (loaded on entering S2; the
  internal value only changes in SI).

So neither the card's IOCHRDY nor the DMA requests and mask bits (SI -> S0)
feed DACK and the bus address register. The hold request and the high
address strobe use a copy of the state decoder with READY = 1
(`next_state_r1`), exact there: READY never makes the next state S0 or SI
and does nothing in S1.

### 2.2 Board: the bus address as a register (`xt_board.sv`)

`bus_addr = dma_owns && !(&dack_n) ? {dma_page, dma_addr} : cpu_addr`, with
`dma_owns = dma_wait & aen` and `dma_page` the 74LS670 output selected by
DACK2/DACK3, is a register now, loaded with the same expression on the D
inputs of the registers it is made of: `dma_wait`, `aen` (written as
`*_next` combinational signals), DACK (`dma_acknowledge_next`), the page
registers (`page_next`), the 8237's transfer address
(`address_out_next`, exported from `KF8237_Address_And_Count_Registers`) and
the address latch (`cpu_addr_next = bus_t == T1 ? cpu_ad : cpu_addr`). Every
card, the RAM and the ROM decode a register.

The page registers and the NMI mask take their data from `cpu_dout` instead
of `bus_wdata`: they are written only by CPU I/O writes, which need AEN low,
where `bus_wdata` is `cpu_dout` (checked). This keeps the CGA's read data
(an input of `bus_wdata` during DMA) out of the page register's D input.

### 2.3 Board: one command register per bus status

The 8288 function had `cmd_rd`/`cmd_wr` and decoded the CPU's live bus status
(`bus_type` = biu88 `latch`) into MEMR/MEMW/IOR/IOW/INTA; that status comes
straight out of the BIU's EU-driven logic. Now `cmd_memr`, `cmd_memw`,
`cmd_ior`, `cmd_iow`, `cmd_inta` are set under the same conditions with the
status decoded at the set (CLK falling edge in T1/T2) and cleared as before
(reset or a T-state outside T1-Tw). Equal in every clk because the status
only changes when a cycle starts (T1 entered from Ti, T4 or Tinit) and at
the T4 step (to passive): both times the T-state of the clk before is not
T1-Tw, so the command registers are 0 when the status changes. This is a
property of biu88; the simulation check (section 3) catches a CPU change that
breaks it.

### 2.4 8237: READY last in `next_word`

`next_word = next_state == S4 && mode != cascade`, with READY at the input of
the state decoder. Written out: `next_state` is S4 without READY only in
cascade mode (S1 -> S4, S4 -> S4), where `next_word` is 0 anyway; with READY
it is S4 from S2 (compressed timing, verify), S3 (verify) and SW. So
`next_word = ready && !cascade && (S2 && compressed && verify || S3 && verify
|| SW)`: the same function, READY one LUT before the address and count
registers' clock enables.

### 2.5 8253: registered decrements (`KF8253_Counter.sv`)

`dec_count = decrement(count, bcd)` and `dec2_count = decrement(dec_count,
bcd)` (BCD-capable, long) are registers computed from `count` and
`select_bcd` of the previous clk. They are only used through `count_next` and
`count_period`, and those only in a clk with `start_counting && count_edge`
(the count, its latch, `prev_count_period`, `counter_out`). In such a clk
`count` and `select_bcd` are those of the previous clk:
- `count` changes only at a count edge (one clk in 84, from `pit_clk`) while
  counting, or is forced to 0 while `start_counting` is 0;
- `start_counting` rises only at `write_counter`, a one-clk pulse at the end
  of an I/O write strobe; it falls at the control word write or the first
  byte of an LSB/MSB count, also such pulses. Two I/O writes are at least a
  bus cycle (4 CPU clocks, 84 clk) apart, so a count forced to 0 by a falling
  `start_counting` has been 0 for many clks when it rises again;
- `select_bcd` changes only at the control word write, which drops
  `start_counting`.

### 2.6 FDC: the LBA per drive (`fdc_card.sv`)

`x_lba` was computed from the geometry of the drive the DOR selects, so the
DOR's select bit sat in front of two cascaded DSPs. Now the LBA is computed
for both drives (kept apart with `keep`: synthesis shares one multiplier
behind a mux otherwise) and the select bit picks one at the end, and as
`C * (H * S) + h * S + s - 1` with the sectors per cylinder `H * S` (at most
3 * 63 = 189, 8 bits) from the geometry alone: one 8 x 8 multiplication
instead of two in a row. The same value for every input (no term exceeds
16 bits; checked against the original formula in every clk). The geometry
keeps its multicycle constraint (CORE.xdc).

### 2.7 765 and the card: registered decodes (`upd765.sv`, `fdc_card.sv`)

- `op == OP_RTRK` and `op == OP_RD || op == OP_RDDEL` are registers loaded
  together with `op` (reset and the command byte) from `dec_op`.
- The drive inputs from the glue (geometry, presence, write protection, the
  80-track flag) are registered where they enter the card, and the sectors
  per cylinder of each drive with them. The glue is asynchronous to the PC
  (QNICE domain, `cdc_stable`, under a 4-clock multicycle constraint), so
  this is indistinguishable from a glue one clk slower; tb/fdc, which
  changes the geometry between its tests, gives the identical log and images.
- Everything of the selected drive the 765 uses is a register loaded from the
  next values (the DOR and the cylinders with their D inputs written out,
  and the drive inputs): the cylinder (`drv_cyl`, into the tag compares),
  drive select, presence, write protection, heads, sectors per track and
  `cylinder < tracks` (`geo_cyl_ok`, the track format check, replacing the
  765's `geo_tracks` input). Neither the DOR's select bits (fanout about 100)
  nor the geometry multiplexers are in front of the 765 any more.

### 2.8 Glue: the PC reset

`main_pc_reset` (mega65.vhd) drives about 2300 loads, many of them the KF
chips' asynchronous clears; synthesis ignores its `max_fanout` there.
`FORCE_MAX_FANOUT 100` in CORE.xdc lets physical optimization replicate the
register (same D input, same timing).

### 2.9 Glue: `pc_ram` pipeline

The 160 block RAMs cover most of the die. The request register next to the
board now feeds one register set per group of 5 banks (keep), then one per
bank; the bank outputs go through the block RAMs' output registers into the
multiplexer register. Read data and `ram_ack` come 6 clocks after `ram_en`
instead of 4 (tb/shell `tb_glue` checks 6).

### 2.10 Why the RAM latency is invisible

`xt_board` issues one RAM request in the first clk of a MEMR/MEMW strobe and
takes the read data into `ram_q` at `ram_ack`. Strobes are at least one bus
cycle (84 clk) apart. The CPU samples the data at the CLK edge that ends T3,
55 clk after MEMR falls (MEMR falls 7 clk into T1); a DMA memory read starts
in S2 and the I/O write that takes the data ends in S4, 42 clk later. Before
either, `ram_q` is not used (the bus trace's data column samples `cpu_din`
at every CPU clock edge; the first edge after MEMR falls is 13 clk later,
still after the 6-clock answer). tb/sys has a RAM latency option (`-L n`,
default 1) and gives the identical traces with `-L 6` (section 3).

### 2.11 The first clk of a PC reset

The KF chips reset asynchronously, the board and the cards synchronously. In
the first `clk` of a PC reset the original bus address was already the
CPU's (DACK cleared at once), while the register of section 2.2 still holds
the address of the clk before (the DMA's, if a DMA cycle was running); the
FDC's registered strobe edges (section 2.13) likewise miss the 8237's strobes
going inactive. In that clk nothing that keeps state reads them: no strobe starts (the CPU's
command registers are unchanged, the 8237's strobes go inactive), the board,
the cards and the 765 take their synchronous reset branches, which ignore the
bus, and the KF chips are held in reset; from the next clk on the address is
equal again. Registered bus strobes were tried as well (build bt-f/bt-g) and
dropped: going inactive at once at a reset ends a CPU strobe one clk early,
which lets the CGA commit a pending VRAM write (`acc_abort`) that the
original drops.

### 2.12 Board: CPU read data

The priority chain that picks the CPU's read data (INTA, the board's chips,
RAM/ROM, the card bus, 0xFF) now only decides the source, and the block RAM
data (BIOS ROM, RAM register, the cards' `isa_din`) go through one 4:1
multiplexer at the end. The same function.

### 2.13 FDC and CGA: address decode and strobe edges one clk ahead

The FDC decodes its I/O address (3F2, 3F4/3F5) and detects the IOR/IOW
edges (its `ior_fall`, `iow_fall`, `iow_rise`, `ior_rise`, which drive the
765) into registers, from values of the next clk the board now provides on
the card bus (doc/architecture.md section 3): `isa_addr_next`/`isa_aen_next`
(the D inputs of the bus address register and AEN) and
`isa_ior_n_next`/`isa_iow_n_next` (the command registers', AEN's and the
8237's I/O strobes' D inputs; the 8237 exports the latter). The registers
equal the combinational decode and edges in every clk (checked) - the
strobes' next values only miss the 8237's asynchronous clear in a reset's
first clk, when the FDC and the 765 are in reset (section 2.11). Parameter
`REG_DECODE` (1 in `pc_system`, 0 in tb/fdc, whose bus model has no next
values). A0 for the 765's register select likewise.

The CGA's IOCHRDY (into the 8237's READY and the board's READY flip-flop)
uses its memory select (B8000-BFFFF and MEMR or MEMW) from a register loaded
from `isa_addr_next` and `isa_memr_n_next`/`isa_memw_n_next`; the card's own
access state keeps the combinational select. Parameter `REG_READY` (1 in
`pc_system`, 0 in tb/cga). In a reset's first clk the registered select can
miss the 8237's strobes going inactive; both readers of IOCHRDY are in reset
then.

The 765's `xslot` (about 100 loads) gets `max_fanout 24`.

## 3. Verification

- **Simulation checks** (`ifndef SYNTHESIS`, `$fatal`): every retimed signal
  is compared with its original expression in every clk (outside a reset):
  DACK, the DACK flip-flop's next value and its written-out transitions, the
  READY-free state decode where it is used, `next_word`, the bus address, the
  next-clk strobes, the five command strobes, the CPU write data of the
  page/NMI registers, the CPU read data, the 8253 decrements in each clk that
  uses them, the FDC's LBA, address decode, strobe edges and selected-drive
  values, the 765 op decodes, the CGA's registered memory select. They ran in
  all simulations below and never fired; mutants (a wrong next value in the
  bus address register, a missing SW term in `next_word`) stop the simulation
  within the first 0.15 s.
- **tb/sys** (GLaBIOS 0.4.2 8X; main `832b94e` against this branch, both
  built with the same Verilator on the build host): the bus trace (`-t`:
  every 8088 clock, T-state, status, address, data, QS, CS:IP) and the
  instruction trace (`-i ... 0`) are byte-identical (SHA-256), and so is the
  output (POST, FDC requests, CS:IP every 50 ms, the screen at the end):

  | Run | Simulated | Result |
  |---|---|---|
  | GLaBIOS, RAM latency 1 | 1.0 s | identical (banner on screen) |
  | GLaBIOS, RAM latency 6 (`-L 6`) | 1.0 s | identical to main with latency 1 |
  | GLaBIOS + `hello360.img` in A:, RAM latency 1 | 20 s | identical: boots from the floppy at 9.2 s ("Booted from floppy A: (pc10-iii FDC+DMA)") |
  | the same with RAM latency 6 | 20 s | identical to main with latency 1 |

- **tb/fdc** `make run`: PASS, 208 checks; the log and both written disk
  images are identical to main's.
- **tb/cga** `make run`: PASS, the log identical to main's; the images too,
  except `crtc3_window.ppm`, which differs between two runs of main's own
  bench (`write_images` writes `ww * wh * 3` bytes of a window whose rows
  vary in width: it reads past the end of its vector).
- **tb/shell** `run.sh`: PASS (`tb_glue` with the 6-clock RAM, `tb_fdd`, the
  stand-in).

## 4. Results

R6 builds on the build host (Vivado 2022.2, `tools/remote/rbuild.sh`), worst
setup slack between the blocks on `main_clk` (final checkpoint, reports in
`~/pcxt-work/builds/<name>/`, `block_pairs.txt`):

| From -> to | pc10-real-d | bt-j (this branch) | bt-x (experiment) |
|---|---|---|---|
| board -> board | -1.474 | +0.177 | +1.595 |
| FDC -> FDC | -1.427 | +0.246 | +0.952 |
| CPU -> FDC | -1.061 | +3.838 | +5.078 |
| board -> FDC | -0.982 | +0.801 | +0.954 |
| CPU -> board | -0.557 | +3.173 | +4.676 |
| board -> BIOS ROM | -0.112 | +3.325 | +3.005 |
| `pc_ram` | -0.750 | +0.955 | +1.711 |
| BIOS ROM -> CPU (`data_bus`) | -1.061 | -0.067 | (relaxed) |
| board -> CPU (`rdy_sync` -> BIU) | -3.643 | -3.626 | (relaxed) |
| clocks -> CPU (`c21` -> BIU) | -3.558 | -3.816 | (relaxed) |
| CPU -> CPU | -5.710 | -6.133 | (relaxed) |
| failing endpoints | 582 | 228, all in `rtl/cpu` | 0 |

- **bt-j** (`ba8deaf`): every path that ends outside the CPU passes. What
  fails ends in biu88: the CPU's own paths, the board's READY flip-flop and
  the clock enables into the BIU's T-state logic (20-23 levels, all inside the
  BIU), and the BIOS ROM's data into the BIU's `data_bus` (-0.067: block RAM
  with cascade, one LUT in the board, four in the BIU).
- **bt-x** is bt-f's sources (`864b7ef`, with the registered strobes that
  were dropped later) plus an experiment-only constraint relaxing all paths
  into the CPU to 2 clocks: WNS **+0.199** for the whole design, every
  other path >= +0.95 ns.
- In between (bt-a .. bt-i, rounds of this branch) the worst path ending
  outside the CPU moved by up to +-0.9 ns from build to build at the same
  logic depth: with the CPU 5-6 ns short, placement and routing serve it
  first, and logic that talks to it (the board, the FDC next to it) gets what
  is left. The later rounds took the cards' bus inputs out of their deep
  paths (registered decodes, strobe edges, selected-drive values) for that
  reason; the margins of bt-j (+0.18 / +0.25) should grow once the CPU closes
  (bt-x).
- If the BIOS ROM -> BIU path stays after the CPU work: the ROM's block RAM
  output register (one more clock of `rom_rdata` latency) takes about 1.5 ns
  off it; the board uses ROM data at the earliest 13 clk after the address is
  stable, so that would not be visible either (as with the RAM, section 2.10).

| | pc10-real-d | bt-j |
|---|---|---|
| LUTs | 26381 | 26524 |
| FFs | 18716 | 19089 |
| Block RAM tiles | 238.5 | 238.5 |

## 5. The PC on 28.63636 MHz (2026-10-23, branch `clk28`)

The PC runs on the PC10-III's master clock, 28.63636 MHz = 2 x OSC
(doc/clock-plan.md, doc/architecture.md section 1): a clock is 34.9 ns
instead of 10 ns, and the whole PC side closes out of context with a large
margin (doc/history.md, 2026-10-23). What that changes here:

- **No exceptions.** `rtl/cpu/cpu8088.xdc` (3-clock multicycle paths between
  the EU and biu88) is gone; the EU's enable is one clk after the step
  (`EU_DELAY` 1), so biu88 -> EU is a single-clock path anyway. CORE.xdc
  lost the floppy geometry's 4-clock multicycle, the PC reset's
  `FORCE_MAX_FANOUT` and the main/video clock pair (one clock now).
- **The RAM answers after 2 clocks** (`pc_ram.vhd`: request register, the
  banks' block RAM registers, a multiplexer), not 6. Section 2.10 holds as
  before: the board takes the data at `ram_ack`; tb/sys gives the identical
  trace with `-L 2`.
- **What stays**: the retimings of section 2 (registered bus address, DACK,
  command registers, the 8253 decrements, the FDC's and the CGA's registered
  decodes, the 765's op decodes, the FDC's per-drive LBA). They are exact
  (checked in simulation) and cost little; at 28.6 MHz they are not needed
  for timing, but taking them out is a change of its own.
- **The order within an OSC tick.** On the 100 MHz clock a tick had 7 clk:
  the board's edge (sub-slot 0), 5 clk in which registered follow-ups of a
  bus event happened (a command ending one clk after T4 began, the CPU's
  command one clk after AEN fell, the CGA's I/O access one clk after the
  strobe, DRQ0 two registers deep), `rdy_ce` (5) and the CGA's dot tick (6).
  At 28.63636 MHz a tick has 2 clk: the board's edge and the tick, with
  `rdy_ce` in the tick's clk. Every follow-up that the next tick (or the
  next CPU edge) saw on the 100 MHz clock must therefore happen at the
  board's edge itself:
  - the commands end at the edge where T4 begins (`cyc_end`, from a mirror of
    biu88's "this T3/Tw is the last" flag, checked in simulation);
  - the 8237 ends its strobes one clk before the edge that ends S4
    (`cpu_prestep`), and the CPU's commands come back with AEN (no `aen_d`);
    the memory keeps driving a DMA read's data in that clk (`dma_mem_src`),
    as the trace shows it;
  - the 8237's DREQ register takes DRQ0's D input;
  - the CGA acts on I/O in the strobe's last clk (from `isa_*_next`), counts
    the tick in which an access starts, and computes its dots 3 ticks late
    (doc/cga.md section 2).
  The MartyPC system trace (DRQ0_SKEW 7, 1.27 s) is byte-identical to the
  100 MHz design's (SHA-256), the `-d EE` trace too; SST and the card benches
  as before (doc/history.md).
- **Real time** stays real time: the FDC's and the XTIDE's 1 us enables count
  11/315 per clk; the XTIDE's CMD_US for IDENTIFY now runs while the card
  writes the sector (512 clk = 18 us at 28.6 MHz, 5 us before). The MDA's
  crystal is 59609/105000 (Hercules 352/630) of clk: a dot is 1.76 clk, so a
  falling dot edge after the rising one in the same clk is taken in the next
  clk (`fall_pend`, doc/mda.md section 2).
