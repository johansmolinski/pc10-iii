# The 8088 at 100 MHz (timing closure of rtl/cpu)

Branch `cpu-timing`, 2026-10-21/22. The CPU (MCL86 EU + biu88 + microcode ROM)
meets 100.2273 MHz on the R6 part without changing what it does on any clock
the EU or an 8088 clock sample sees.

## 1. Simulation and hardware disagreed (fixed first)

biu88 keeps its state with blocking assignments in one clocked block. Its
outputs (BIU_CYC, PFQ_*, BIU_DONE, the pins, ...) were those registers, read
by the EU and the board in other processes on the same clock edge. Verilator
runs such a reader after the writer and gives it the NEW value; the FPGA gives
it the old one (a flip-flop output). So the simulation (SingleStepTests and
tb/sys, which the microcode was tuned against) was not the hardware:

- `rtl/cpu/mcl86/biu88.v` with every output through a nonblocking copy
  (simulation = hardware, nothing else changed) differs from the old
  simulation in 19 of 323 SST files: totals length 2327739 -> 2348574,
  trace 2322518 -> 2343353 (D8-DF +2700 each, 8E +177, D0.3 -181, 81.3 -1183,
  F6.0 -52, F6.1 -65, F6.5/F6.7/F7.4-7 a few).
- tb/sys: the bus trace differs from 8088 clock 63 on, the instruction trace
  from the 5th instruction (one core clock later); after 0.4 s the BIOS is
  elsewhere (0000:2702 instead of F000:E892).

The commit "biu88: outputs through nonblocking copies" makes the simulation
the hardware; it is the baseline of everything below. The microcode tuning
should be re-checked against it (the hardware has always behaved like this).

## 2. What was too deep

Out-of-context run of the old CPU (`tools/ooc`, R6 part, 9.977 ns): WNS
-5.0..-6.6 ns. A step (the 8088 clock edge) ran do_cycle, the request phases
and the EU's events of that clock in one combinational chain (~22 LUTs); the
EU's events alone (queue reads -> fetch-on-queue-read -> request -> bus
start) were ~20 LUTs from the microcode ROM; the EU's adder was a ripple of
LUTs.

## 3. What changed (rtl/cpu/mcl86/biu88.v, eu.v, eu_rom.v, rtl/cpu/cpu8088.xdc)

biu88 (the header comment "Timing structure" has the details):

- **Fast part / bus part.** Everything the EU sees (queue, view, counters,
  done, return data, QS, registers) is exact on every clock; at a step it
  takes a few facts of the bus state from before the step (push at T4,
  resume points, `cb_pred`). The bus state (T-states, address cycle, fetch
  policy, request phases) is updated by the EU's events on their clock,
  except around a step:
- **Step window.** The step's bus work runs two clocks later (`win2`) from a
  copy of the bus state and of the fast values it reads (`bd*`, `sn_*`, taken
  on the clock before the step), followed by the events of the step's clock
  (`p1_*`) and the next (`pw_*`): multicycle paths of 3 and 2 clocks
  (`rtl/cpu/cpu8088.xdc`). The events of `win2` are applied one clock later
  (`p2_*`, `pend`) together with that clock's: queue reads of two clocks in a
  row merge (fetch-on-queue-read is idempotent, CANCEL_DELAY accumulates); a
  recorded request is applied alone and the next clock (which cannot make a
  request, a request is an edge) is recorded in turn.
- **Late decisions.** Whether the EU reads the queue (EU_QREAD) is known late
  in the clock. The queue-read decisions (`f_chain`) are flat logic, worked
  out for each EU_QREAD value and for each value of the compares they depend
  on (scheduled read due, end counter); the bus part's result is worked out
  for the six combinations of queue read none/without/with CANCEL_DELAY and
  request held/not, kept as six candidate registers (`k*`, `l*`), and the
  3-bit choice (`ksel`) is the only register the late decisions reach. The
  bus state is the chosen candidate (8:1 mux of registers).
- Compares without adders in series (`ge_s`: both values of a step's
  increment, `sp_*` kept ready; `ge_sum`: x >= (a + b) mod 4096 as
  x >= a and (x - a) mod 4096 >= b, with the carry of a + b), the end counter
  kept as `cz`, request_begin/request_advance's immediate bus start as one
  condition (`request_go`), the three passes request_advance needs.
- Outputs are nonblocking registers (`o_*`) or the candidate mux (`v_*`):
  race-free in simulation.

eu.v: the adder as one carry chain (`adder_sum`, the carries recovered as
a ^ b ^ sum); EU_QREAD from registers as directly as possible (the SYNC term
left out: a SYNC is type 0, EU_QREAD needs type 1 or >1; `eu_alu_last_nz`
kept with `eu_alu_last_result`; the two IDIV terms with `eu_q_at_0E75/0F01`,
the address of the word in `eu_rom_data`). eu_rom.v: `rom_style = "block"`
(timing-driven synthesis moved the ROM into ~3500 LUTs in some runs, which
spread the placement).

The microcode and the EU/BIU interface are unchanged.

**Visible difference:** the bus pins (and `bus_t`/`bus_type`) show a step's
result up to two core clocks later than before (during the two clocks after
a step, and while a recorded clock is pending). The 8088 clock samples (the
next step, 20/21 clocks later) and everything the EU sees are the same.
Board logic that acts on every core clock sees the T-state change later
(e.g. xt_board's command end at `!in_cycle`); nothing in the gates changed.

## 4. Verification

- Lockstep (not in the repo: `~/pcxt-work/scratch/timing/eq`): the new CPU
  and the reference (the race-free old biu88 + old eu.v) side by side on the
  same inputs, every EU/BIU interface signal, the EU's registers and the fast
  BIU state compared on every core clock, the bus state and pins outside the
  step windows. All 3,007,000 SST tests: no mismatch.
- SST (`tb/sst`, `make run`): per-file table identical to the race-free
  baseline (`~/pcxt-work/results/timing-hw.txt` vs `timing-final.txt`).
- tb/sys (GLABIOS 0.4.2, 0.4 s): bus trace (`-t`) and instruction trace
  (`-i ... 0`) byte-identical to the race-free baseline.

## 5. Timing (OOC, `tools/ooc`, Vivado 2022.2, R6 part, 9.977 ns)

| run | WNS | WHS | LUT | FF | BRAM |
|---|---|---|---|---|---|
| old CPU (cpu-ooc-a: clock after synthesis) | -6.567 | +0.096 | 1856 | 869 | 8 RAMB36 |
| old CPU, this script, default directives | -5.019 | +0.132 | 4820 (ROM in LUTs) | | 0 |
| new, default directives (`rooc.sh <name>`) | **+0.407** | +0.108 | 3123 | 2228 | 8 RAMB36 |
| new, the shell's directives (`rooc.sh <name> explore`) | +0.212 | +0.145 | 3130 | 2228 | 8 RAMB36 |

Reports: `~/pcxt-work/ooc/timing-ooc-final3` (default) and
`timing-ooc-final3-x` (explore). By region (default run): EU -> EU +0.66,
EU -> BIU +0.89, BIU -> EU +3.2, BIU -> BIU +0.41, step window (multicycle)
+4.4. Worst paths: the candidate choice (`ksel`) through the bus state's mux
into the step's facts and the queue-read decisions, and through the mux
into the six candidates (12-15 LUT levels, ~80 % of the delay routing).
The margin is thin: during the work, changes of a few LUTs moved the result
by +-0.2 ns, and so did other place_design directives.

Integration notes:
- Add `rtl/cpu/cpu8088.xdc` to the project scoped to cpu8088
  (`SCOPED_TO_REF cpu8088`), as the OOC run reads it.
- `pc_clocks.cpu_step` is `c21 == 0`, a LUT; the OOC run has `step` from a
  register. Registering it (`c21 == 20` one clock early) keeps the CPU's
  `step` paths as measured here.
