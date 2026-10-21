# Timing closure outside the CPU

Status: 2026-10-21, branch `board-timing`. The CPU (`rtl/cpu`) is closed on
its own branch (`cpu-timing`); this is everything else in `pc_system` and the
glue that failed 100.2273 MHz in build `pc10-real-d` (doc/m2m-shell.md
section 11).

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

The DACK flip-flop's next value (and the flip-flop itself) uses a copy of the
state decoder with READY = 1 (`next_state_r1`), and only its transitions out
of S1 and S4:
- READY only decides between S4 and staying in S2/S3/SW. The one case where
  that matters for the flip-flop (`next_state == S2` in S2: compressed
  timing, verify, not ready) reloads it with `dma_acknowledge_internal`, the
  value it already holds (loaded on entering S2; the internal value only
  changes in SI).
- In SI and S0 the flip-flop is 0 already (cleared when SI is entered, from
  S4 or by reset or master clear), so the original "next_state == SI -> 0"
  in SI changes nothing.

So neither the card's IOCHRDY nor the DMA requests and mask bits (SI -> S0)
feed DACK and the bus address register. The hold request and the high
address strobe use `next_state_r1` too; there it is exact (READY never makes
the next state S0 or SI and does nothing in S1).

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
- The selected drive's cylinder (`cyl[pd]`, the 765's `drv_cyl`, which goes
  into its tag compares and the track format check) is a register loaded
  with `cyl_next[dor_next[0]]` (the DOR and the cylinders with their D inputs
  written out).
- The track format check gets `drv_cyl < img_tracks[pd]` from the card
  (`geo_cyl_ok`) instead of the tracks.

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
the address of the clk before (the DMA's, if a DMA cycle was running). In
that clk nothing that keeps state reads it: no strobe starts (the CPU's
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

### 2.13 FDC: address decode one clk ahead

The FDC decodes its I/O address (3F2, 3F4/3F5) into registers from
`isa_addr_next`/`isa_aen_next`, new on the card bus (doc/architecture.md
section 3): the D inputs of the board's bus address register and AEN. The
register equals the combinational decode in every clk (checked). Parameter
`REG_DECODE` (1 in `pc_system`, 0 in tb/fdc, whose bus model has no next
values).

The 765's `xslot` (about 100 loads) gets `max_fanout 24`.

## 3. Verification

- **Simulation checks** (`ifndef SYNTHESIS`, `$fatal`): every retimed signal
  is compared with its original expression in every clk - DACK and its next
  value without READY, the bus address, the five command strobes, the CPU
  write data of the page/NMI registers, `next_word`, the 8253 decrements in
  each clk that uses them, the FDC LBA, the 765 op decodes. They ran in all
  simulations below and never fired.
- **tb/sys** (GLaBIOS 0.4.2 8X; main `832b94e` against this branch, same
  Verilator on the build host): the bus trace (`-t`: every 8088 clock,
  T-state, status, address, data, QS, CS:IP) and the instruction trace
  (`-i ... 0`) are byte-identical (SHA-256), and so is the screen at the end
  (the GLaBIOS banner):

  | Run | Simulated | Result |
  |---|---|---|
  | GLaBIOS, RAM latency 1 | 1.0 s | identical |
  | GLaBIOS, RAM latency 6 | 1.0 s | identical to main with latency 1 |
  | GLaBIOS + `hello360.img` in A: | 20 s | see section 4 |

- **tb/fdc** `make run`: PASS, 208 checks; its log and both written disk
  images are identical to main's.
- **tb/shell** `run.sh`: PASS (`tb_glue` with the 6-clock RAM, `tb_fdd`, the
  stand-in).

## 4. Results
