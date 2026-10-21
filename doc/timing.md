# Timing closure outside the CPU

Status: 2026-10-21, branch `board-timing`. The CPU (`rtl/cpu`) is closed on
its own branch (`cpu-timing`); this is everything else in `pc_system` and the
glue that failed 100.2273 MHz in build `pc10-real-d` (doc/m2m-shell.md
section 11).

The rule: **no change of behaviour**, not even by one `clk` where anything
outside the changed piece could see it. Every change in `pc_system` is a
retiming that keeps the value of every signal the rest of the design sees in
every `clk`, or one whose difference is provably never used (the 8253
decrements, the DACK next value). The glue's RAM answers 2 clocks later,
which the board does not see (section 2.10). No multicycle constraints.

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

`dma_acknowledge_ff_next` uses a copy of the state decoder with READY = 1
(`next_state_r1`): READY only decides between S4 and staying in S2/S3/SW, and
the one case where that matters for the DACK flip-flop (`next_state == S2` in
S2, compressed timing, verify, not ready) reloads it with
`dma_acknowledge_internal`, the value it already holds (loaded on entering S2;
the internal value only changes in SI). So the card's IOCHRDY no longer feeds
DACK and the bus address register through the 8237's state decoder.

### 2.2 Board: bus address select and page as registers (`xt_board.sv`)

`bus_addr = dma_owns && !(&dack_n) ? {dma_page, dma_addr} : cpu_addr`, with
`dma_owns = dma_wait & aen` and `dma_page` the 74LS670 output selected by
DACK2/DACK3. The select and the page are now registers `dma_sel_q`,
`dma_page_q`, loaded from the same expressions on the D inputs of `dma_wait`
and `aen` (now written as `*_next` combinational signals), DACK
(`dma_acknowledge_next`) and the page registers (`page_next`). `dma_addr`
(the 8237's `transfer_address`) and `cpu_addr` are registers, so `bus_addr`
is one LUT3 behind registers.

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

### 2.7 765: op decodes as registers (`upd765.sv`)

`op == OP_RTRK` and `op == OP_RD || op == OP_RDDEL` are registers loaded
together with `op` (reset and the command byte) from `dec_op`.

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
