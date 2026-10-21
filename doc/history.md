# Engineering log

Newest entry last. Each entry: what changed, why, and the harness totals
(`tb/sst`, `make run`) before and after.

## 2026-10-21 - Start: MCL86 and the SingleStepTests harness

**Decision (user, 2026-10-21):** no cycle-exact 8088 in HDL exists, so we
start from MicroCore Labs' MCL86 (MIT) and correct it against the test suite
("start with this CPU anyway and we'll correct it as we go").

What MCL86 is, from its datasheet and sources:
- a 32-bit microsequencer at 100 MHz (about 21 microinstructions per 8088
  clock) that executes its own microcode, not Intel's;
- a sample 8088 BIU whose states are counted in 100 MHz core clocks;
- instruction timing that comes from a counter the microcode loads with a
  per-instruction count and waits on at the end ("cycle compatible, not cycle
  exact ... within a clock or two"; MUL/DIV take a fixed mid-range time);
- no queue status outputs. The EU dispatches on the opcode byte by peeking
  at the queue and removes it from the queue only at the END of the
  instruction (strobe with QS code 01).

The harness (`tb/sst`):
- Verilator, C++ bus model with 8288 and memory, MCL86 at 100 MHz with
  CLK = 4.7727 MHz;
- registers loaded by a program on the bus (POPF, MOV, JMP FAR), as
  Arduino8088 does on the real chip;
- three verdicts per test: state, length and full per-cycle trace;
- the first-byte event (QS=F) for MCL86 is its opcode dispatch;
- after the end point the bus drains for 40 cycles, because MCL86 starts the
  next instruction while a write is still queued in its BIU.

Suite: SingleStepTests 8088 v2 (AMD D8088, maximum mode), 323 files, 3,007,000
tests. Half of them start with a full queue, which the bus loader cannot set
up; those get the state verdict only.

**Baseline, unmodified MCL86** (`BIU=max`, results
`~/pcxt-work/results/mcl86-baseline.txt`):

| tests | state | plain (empty queue) | length | trace |
|---|---|---|---|---|
| 3,007,000 | 2,897,088 (96.3%) | 1,503,500 | 164,375 (10.9%) | 12 (0.0%) |

Whole files fail on state where MCL86's function is wrong or the test is
outside what it does, among them:
- string instructions with REP (A4/A5/AA/AB...);
- the shifts by CL with count >= 32 or so (D2.6/D3.6, undefined SETMO);
- DIV/IDIV (F6.6/F6.7/F7.6/F7.7, about a quarter right);
- E8/9A/CE (CALL, CALL FAR, INTO), D4/D5 (AAM/AAD).

To be looked at per file.

## 2026-10-21 - biu88: a cycle-stepped 8088 BIU for MCL86

`rtl/cpu/mcl86/biu88.v` replaces `biu_max.v`. It steps once per 8088 clock and
follows MartyPC's 8088 BIU model (MIT):
- T-states, the Tr/Ts/T0/Td/Ta address cycle;
- fetch decisions at Ti, T2 and T4, the queue policy delay, pause and
  suspend;
- early and late EU requests, the prefetch abort;
- word transfers as two byte cycles.

It keeps MCL86's EU interface. Two MCL86 conventions had to be mapped:
- **Opcodes and subsequent bytes:** the EU dispatches on the opcode by
  peeking at the queue. The opcode is read at the dispatch (input
  `eu_dispatch` = `eu.new_instruction`) and "held" outside the 4-byte queue
  until the EU's strobe pops it. A strobe with QS code 11 reads a subsequent
  byte there and then.
- **Cycle counter:** it counts core clocks for legacy microcode. With bit 13
  set it counts 8088 clocks:
  - bit 12 = 0 is absolute: "cycle n of this instruction, 0 = the dispatch
    cycle";
  - bit 12 = 1 is relative: "n cycles from now".

Harness changes:
- `BIU=biu88` is the default, `BIU=max` the original.
- Test-only queue preload port (`tb_preload` ...): it installs the
  prefetched queue at the loader's JMP FAR, so all tests are now graded on
  cycles.
- Pins are sampled on the clock before the CLK edge.
- QS comes from the new QS pins.
- `ROMHEX`/`OBJ` give a dev build its own ROM image, so microcode can be
  tried while a full run reads the committed one.

Microcode, the first retimed words (all marked "pc10-iii" in the listing):
- **Main loop:** the queue test and dispatch moved up into the five NOP slots
  after the interrupt polls. The instruction-end-to-next-dispatch path must
  fit into one 8088 clock (about 21 microinstructions at 100 MHz); with the
  NOPs it sometimes slipped a cycle.
- NOP 3 cycles, prefixes 2, the flag instructions (CLC/STC/CMC/CLD/STD/CLI)
  2: all in absolute cycle mode.
- JMP FAR: end at 15 (not exact yet: its operand reads and the flush need
  their own sync points).

Per file with this state (dev runs):
- 90 NOP, 40 INC AX, F8 CLC: every test exact, on all cycles (10,000 / 10,000
  / 1,000);
- B8 MOV AX,imm: 5,000 of 10,000. MCL86 pops both immediate bytes in one
  cycle, while the 8088 reads them one per cycle, two and three cycles after
  the opcode.

Full-suite numbers are in the entries below.

**Method for the remaining instructions:**
1. For each opcode, read its real schedule from the test traces: queue reads
   (QS one cycle later), bus requests (T1 minus the address cycle), the
   flush, the end.
2. Put a counter sync in front of each of these points in the microcode:
   absolute for the instruction's own routine, relative inside shared
   procedures.
3. Measure the file; keep only changes that raise its counts without
   lowering any other file.

**Known risk, turbo speeds:**
- The EU needs about 17 microinstructions from an instruction's end to the
  next dispatch, and more inside busy cycles.
- At 100 MHz that fits 4.77 MHz (21 per clock). 7.16 MHz (14) does not fit
  without a much shorter ending path, and 9.54 MHz (10.5) not at all.
- MCL86 reaches about 180 MHz on Kintex-7 by its datasheet; Artix-7 is
  slower.
- So the PC10-III's turbo modes and the A2088T will probably need a
  cycle-stepped EU. The 4.77 MHz IBM/A2088 timing does not.

## 2026-10-21 - SYNC, 8K microcode ROM, BIU-timed instruction ends

Full-suite runs (`~/pcxt-work/results/`):

| run | what | state | length | trace |
|---|---|---|---|---|
| mcl86-baseline | original MCL86 BIU | 96.3% | 10.9% | 12 tests |
| biu88-a | biu88, first version, original microcode | 96.3% | 5.1% | 12 |
| biu88-b | + queue preload, first retimed words | 96.3% | 30.8% | 534,464 (17.8%) |
| biu88-c | + SYNC, 8K ROM, MOV/ALU immediates | 96.3% | 28.7% | 739,815 (24.6%) |
| biu88-d | + BIU-timed ends, main loop rework | 96.3% | 31.3% | 782,551 (26.0%) |
| biu88-e | + ModR/M read at 1, ALU-imm end armed after the read, harness write fix | see below | | |

In biu88-c, length fell while trace rose: the fetch-byte procedure's SYNC to
cycle 2 also delayed the ModR/M read, which the 8088 does in cycle 1. Fixed
after -d: CALC_EA has its own entry (0x1018) with SYNC 1.

What changed, and why:
- **SYNC microinstruction** (eu.v): type 0 with a non-zero immediate. Bit 15
  = 0 waits for cycle n of the instruction, bit 15 = 1 waits n cycles from
  the start of the wait. The sequencer and the ROM output freeze while it
  waits; type 0 with immediate 0 is still a NOP. A counter-based wait costs 4
  words, a SYNC one.
- **8K-word ROM** (`eu_rom.v`, EU8Kx32 with read enable): the EU's
  addresses and jump targets were 13 bits already. New code lives at 0x1000+
  ("patch area" at the end of the listing). Patched routines jump there and
  back. The ROM had only 797 free words, mostly scattered.
- **The read is the EU's first use of a queue byte**, not its pop. MCL86
  keeps a byte on top of its queue view until a later strobe, often long
  after it used it; the high byte of an immediate word stays until the next
  fetch. The EU now signals its use (`EU_QREAD`: a jump through the opcode
  table = F; the ModR/M jump or any PFQ_TOP_BYTE operand = S). The BIU reads
  the byte then and keeps up to two "taken" bytes for the EU's view.
- **The BIU times the end of an instruction:**
  - A cycle-mode counter load marks the end: when it runs out, the BIU reads
    the next opcode in that cycle (QS=F), even if the EU is still busy.
  - MCL86 needs about 40 microinstructions (2 cycles at 100 MHz) for an
    ADD AX,imm after its last operand byte, flags included; the 8088 reads
    the next opcode 1 cycle later.
  - The EU's dispatch then takes the pre-read byte. Its SYNC counts from the
    BIU's read (`BIU_CYC`).
  - The harness takes the trace window from the QS pins and the registers at
    the EU's dispatch.
- **Main loop:**
  - one test for NMI/INTR/single step (the three polls moved to 0x1010);
  - the wait for the counter right before the dispatch test;
  - WAIT_CLOCKS (0x03F2) no longer waits.

  That puts 8 microinstructions between an instruction's end and the next
  dispatch.
- `tools/sst_sched.py` prints the real schedule of an opcode file, relative
  to the opcode read: queue reads, T1 of EU bus cycles, flush, end. Examples:
  - MOV r16,imm: `S2 S3 end 4`;
  - POP AX: `R5 R9 end 12`;
  - ADD r8,[bx]: `S1 R9 end 15`;
  - ADD r8,[bx+d8]: `S1 S5 R13 end 19`.

d to e:
- **Ends follow the last operand read.** An end armed at an absolute cycle
  fires too early when the operand comes late from an empty queue: the BIU
  then reads the operand as the next opcode. On the 8088 the next opcode
  read follows the last operand read: 2 cycles after an immediate byte, 1
  after an immediate word's high byte.
  - The ALU AL/AX,imm routines now call wrappers (0x1020 byte, 0x1026 word)
    that run the fetch procedure, then load a relative end counter.
  - The BIU keeps the first end armed in an instruction and ignores later
    loads until the next opcode is read and dispatched.
- **Harness:** a write counts for the test only if its bus cycle started
  before the EU dispatched the next instruction. Test 662 of 83.3 (SBB) writes
  into the code right behind itself, and the drain then ran that code; its
  write was flagged as stray.
- d's per-file losses against c were lucky traces under old timing (DAA, DAS,
  STOSB/W, shifts by CL), lost because WAIT_CLOCKS no longer waits. They come
  back when those routines are retimed.

Exact on every cycle of every test now:
- 90 NOP, 40-4F INC/DEC, F8-FD flag instructions;
- B0-BF MOV imm;
- all 18 ALU instructions with AL/AX and an immediate (04/05, 0C/0D, 14/15,
  1C/1D, 24/25, 2C/2D, 34/35, 3C/3D, A8/A9).

**Where the work is now:**
- Instructions with a ModR/M byte (about half the suite) need their ends
  and their bus requests timed.
- The ends live in each routine or in a shared ending; FETCH_EA and
  WRITEBACK_EA are shared by all of them.
- Bus requests must leave the EU at the cycle MartyPC's EU issues them (T1
  follows through the BIU's address cycle).
- The EA timing per mode is MartyPC's table: ModR/M at 1, then 1 +
  pre-displacement cycles, the displacement bytes one per cycle,
  post-displacement cycles, then the operand read. CALC_EA already branches
  per mode, so relative SYNCs go into its branches.

**Possible alternative, not decided:** a table-driven timing unit next to the
EU, MartyPC-style:
- per opcode and ModR/M mode, it holds the cycles of the queue reads, bus
  requests and the end, and releases the EU's queued requests at those
  cycles;
- the EU would then only compute values, and the 4.77 MHz-only limitation
  would ease, because the EU no longer paces anything;
- data-dependent timing (taken jumps, REP, MUL/DIV, shifts by CL) would need
  signals from the EU.

Raised with the user before choosing.

