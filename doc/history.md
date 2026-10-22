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
| biu88-e | + ModR/M read at 1, ALU-imm end armed after the read, harness write fix | 96.4% | 32.6% | 819,712 (27.3%) |
| biu88-f | + register-form ends at the ModR/M read | 96.4% | 35.3% | 900,920 (30.0%) |
| biu88-g | + EA timing (displacement SYNC, request release), ALU writebacks | 96.4% | 47.0% | 1,071,852 (35.6%) |
| biu88-h | + PUSH/POP, PUSHF fix, conditional jumps | 96.7% | 60.4% | 1,570,430 (52.2%) |
| biu88-i | + JMP/CALL near, RET/RETF (+imm), harness NOP fetches, SUSP fix | 96.7% | 63.6% | 1,674,263 (55.7%) |
| biu88-j | + JMP/CALL FAR, loops, one read per cycle, idle start | 96.7% | 65.2% | 1,713,805 (57.0%) |
| biu88-k | + direct moves, port I/O, XLAT, LAHF, CWD, BCD adjusts | 96.7% | 71.3% | 1,897,857 (63.1%) |
| biu88-l | + ALU groups 80-83, ModR/M memory ends by class, MOV [m],r | 96.7% | 74.1% | 2,206,857 (73.4%) |
| biu88-m | + MOV r/m,imm, TEST imm, NOT/NEG, writeback fix | 96.7% | 76.3% | 2,288,302 (76.1%) |

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

## 2026-10-21 - ModR/M instructions: register forms, EA timing, writebacks

e to f, register operands:
- The 8088 reads the next opcode a fixed number of cycles after the ModR/M
  byte: ALU/TEST 2, MOV 1, XCHG 3.
- MCL86's CALC_EA decodes for longer than that, so the end is armed at the
  ModR/M read itself.
- Wrappers (0x1070-0x109C) pass the end value in r2. An armed ModR/M entry
  (0x1060) loads it into the end counter right after the peek, if mod = 11.
- End counter mode 0xA00n: n cycles after the last queue read.
- Result: all register forms of 00-3B, 84-8B exact.

f to g, memory operands:
- The 8088's schedule per addressing mode is fixed (`tools/sst_modes.py`
  groups it): e.g. [bx] read T1 at 9, [bx+d8] displacement at 5 and T1 at
  13, [bx+si+d] displacement at 7, [bx+di+d] at 8.
- MartyPC's EA costs fit exactly:
  - the displacement is read 2 + pre cycles after the ModR/M byte;
  - the operand request goes out 2 + pre cycles after the ModR/M byte
    without a displacement, 1 + post cycles after the last displacement byte
    with one.
- The 24 memory modes of CALC_EA were copied to 0x1100+ by
  `tools/gen_ea_modes.py`, with a SYNC before the displacement fetch and the
  release in r2.
- **Request release** (BIU, register strobe 11 code 6, loaded by the MODxx
  ending at 0x0780): the EU computes an EA faster than the 8088, so the BIU
  holds the EU's next bus request until the release cycle. It then starts it
  as if made at the start of that cycle.
  - Bases: last queue read, end of the last EU transfer, the opcode read.
  - An unused release is dropped at the next opcode read.
- The EU's SYNC got bit 14 = n cycles after the last queue read.
- **ALU writebacks** (0x090D/0x091C go through 0x1280/0x1288):
  - release the write 5 cycles after the operand read ended (MartyPC: EALOAD
    return delay, one ALU cycle, two for a memory destination);
  - arm the end with the new mode 0xB00n, "n cycles after the next transfer
    ends": the 8088 reads the next opcode in the write's T3, where the EU
    resumes, and MCL86 needs more than a cycle from there to its dispatch.
- Result (sampled 2000 per file): all of 00/01/08/09/10/11/18/19/20/21/28/
  29/30/31 exact, register and memory forms, byte and word; the read-only
  memory forms of 03/0B/39/84/8A exact.

## 2026-10-21 - Stack instructions, PUSHF, conditional jumps

g to h:
- **PUSH and POP** (registers, segment registers, flags) share one schedule
  each.
  - PUSH: write T1 at 9 and 13, end 15. The writes are released at cycle 5
    of the instruction; the end is "in the cycle the transfer ends". The arm
    replaces the routine's WAIT_CLOCKS call (0x1290), because the routine
    loads biu_dataout with the value afterwards.
  - POP: read T1 at 5 and 9, end 12. Released at cycle 2, end where the EU
    resumes (0x1298, instead of the POP procedure call).
- **PUSHF** pushed MCL86's internal flag bits. The 8088 reads bits 15-12
  and 1 as 1, bits 5 and 3 as 0 (0x12A0). All 10,000 PUSHF tests failed on
  state in the baseline; now all are exact.
- **Conditional jumps:**
  - Not taken: the end is armed 2 cycles after the displacement read (0x0340
    calls the fetch wrapper 0x1020).
  - Taken (0x12A8): SUSP 2 cycles after the displacement read; SUSP waits
    for a running code fetch's T4; the flush 4 cycles after the EU resumes.
    That is what makes full-queue and empty-queue tests differ by one cycle
    relative to the displacement read.
  - The end is "at the next byte in the queue" (0x12B0), armed after the
    flush, which clears any armed end.
- **BIU:** a flush keeps the last read byte on QS_BYTE (the suite records it
  with the E status).
- Losses in -g against -f: lucky traces of instructions that call CALC_EA
  directly (80.3/82.3, LEA, D0/D1 shifts, F6.3/F7.3 NEG). Their memory reads
  are timed now, the rest of them is not yet. States unchanged.

## 2026-10-21 - Near jumps and calls, returns

h to i:
- **Harness:** code fetches after the instruction's own (not prefetched)
  bytes return 0x90, whatever the address. The suite's generator does that
  ("All bytes fetched after the initial instruction bytes are set to
  0x90"), and a jump can land on the instruction's own bytes. The last Jcc
  and JMP failures were this.
- **BIU:** a SUSP that arrives in the T4 of a running code fetch is done at
  once (MartyPC's wait-until-T4 is already satisfied there).
- **JMP near** (0x12B8 from 0x03B7, a former NOP slot): SUSP 1 cycle after
  the displacement's high byte, flush 4 cycles after the EU resumes. JMP
  short already went through the Jcc taken path.
- **CALL near:** MCL86 pushed the return address first and then jumped; the
  8088 reads the displacement, suspends, flushes, and pushes 3 cycles later.
  Rewritten at 0x12C0.
- **RET** (0x12D8): pop released at cycle 2, SUSP where the EU resumes, flush
  1 cycle later, end at the first new byte.
- **RET imm16** (0x12F0): MCL86 popped before reading the immediate.
  Rewritten: immediate, pop released 3 cycles after it, SUSP, flush 2
  cycles later (MartyPC's farret).
- **RETF** (0x1308): IP pop released at cycle 4, SUSP, 3 cycles, CS pop,
  flush. **RETF imm16** (0x1320): immediate first, then the same, with SP
  adjusted after both pops.
- Sampled: E8, E9, EB, C2, C3, CA, CB and every Jcc exact on all cycles.

**Known risk: the EU lagging across instruction boundaries.**
- The BIU reads the next opcode at the scheduled cycle even when the EU
  still finishes the last instruction. If the next instruction's first timed
  event is soon (a ModR/M byte at cycle 1), an EU that dispatched late misses
  it.
- The suite cannot show this: every test starts from an idle CPU after the
  loader. The harness now installs the prefetched queue only once the EU
  waits in its main loop, as the generator's CPU is idle; before that, the
  loader's own JMP FAR tail made the EU late.
- Real programs need sequence tests: run longer code in the simulation and
  compare the bus trace with MartyPC's.

## 2026-10-21 - Far jump and call, loops

i to j:
- **One queue read per cycle:** the "subsequent byte/word" entries of the
  fetch procedures wait until the cycle after the last read (0x1338/0x133C).
  JMP FAR's second word needed it.
- **JMP FAR** (0x1340 from 0x03C7, a former NOP): SUSP 1 cycle after the last
  pointer byte, flush 2 cycles after resuming, end at the first new byte.
- **CALL FAR** (0x1350): MCL86 pushed first. The 8088 (MartyPC farcall)
  reads the pointer, suspends, pushes CS 3 cycles after resuming, flushes
  4 cycles after that, pushes IP 3 cycles after the flush.
- **Loops** (0x1370-0x13B2): the displacement is read in cycle 4 (after the
  CX update).
  - Not taken: the end 2 cycles after the read.
  - Taken JCXZ/LOOP: SUSP 1 cycle after the displacement.
  - Taken LOOPE/LOOPNE: SUSP 3 cycles after it, so one more prefetch
    starts.
  - Taken, all: the flush 4 cycles after resuming.
- **Harness:** the prefetched queue is installed only once the EU waits in
  its main loop. The retimed JMP FAR made the loader's last instruction end
  at the BIU's schedule while the EU was still finishing it, and the test's
  first ModR/M read then came a cycle late (see the EU-lag risk above).
- Sampled: E0-E3, 9A, EA exact on all cycles.

## 2026-10-21 - Single transfers and one-byte arithmetic

j to k:
- **ARMn wrappers** (0x13C8-0x13F6): set the request release (n cycles after
  the last queue read) and the end (where the transfer ends). The I/O
  routines call them from their WAIT_CLOCKS slot, before they read any port
  byte, because the release counts from whatever read comes last. JARMn
  (0x140A-0x1416) do ARMn and then the fetch-word call for MOV AL/AX
  <-> [addr].
  - Measured: A0/A1 1, A2/A3 2 (3 matches too), E4/E5 2, E6/E7 3, EC/ED 2,
    EE/EF 3, XLAT 5.
- **Absolute-end patches** (0x1420-0x1447) for one-byte instructions that
  ended through NOP's code with old counts:
  - LAHF 2, DAA/DAS 4;
  - CWD 5 (AX positive) / 6 (negative);
  - AAA/AAS 8 with adjust, 9 without. The adjust branch falls into the
    other's code and arms first; the BIU ignores the later load.
- Losses in j against i: lucky traces of group opcodes (C6, F6.0/F6.1, D0,
  1B/3B memory forms) whose immediate read moved with the one-read-per-cycle
  SYNC. Their timing is not done yet.

## 2026-10-21 - ALU groups, memory-form ends, MOV to memory

k to l:
- **BIU: scheduled read** (register strobe 11, code 7). The BIU reads the
  next queue byte (QS=S) n clocks after the last read, the transfer end or
  the opcode read; with bit 12 also the byte after it, one clock later.
  - For operand bytes the 8088 reads before MCL86 gets to them: the
    immediate of a register-form 80-83, one cycle after the ModR/M byte,
    behind about 40 microinstructions of CALC_EA, FETCH_EA and the fetch
    procedure.
  - The EU's later peek finds the byte read already.
- **EU: SYNC since the last transfer end** (bits 15:14 = 11, input
  EU_SINCE_DONE). For memory forms the EU is early instead; it must wait
  itself, or its own read beats the schedule and the scheduled read then
  takes the next byte too.
- **End "n after the next transfer end"** (0xB00n) now starts counting at
  the transfer's end; it counted down while waiting before.
- **Release add** (register strobe 11, code 14).
- **ALU groups 80/82, 81, 83** (0x14A0-0x14EF):
  - group CALC_EA wrappers schedule the immediate read for register
    operands;
  - the immediate wrapper SYNCs memory forms 2 cycles after the read ended;
  - CMP (reg field 7) with a memory operand ends 3 cycles after imm8, 2
    after imm16's high byte;
  - the register forms end 2 cycles after imm8, 4 after imm16.
  - Known limit: ADC/SBB/SUB with a memory operand write 1-2 cycles late.
    MCL86's microcode for them, behind the immediate path, is slower than
    the 8088.
- **ModR/M classes with memory ends** (0x1500-0x158C). Armed-entry variants
  arm "n after the next transfer end" for memory operands:
  - ALU into a register, CMP r/m,r, TEST: 3;
  - MOV r,r/m: 2;
  - MOV r/m,r: 0, at the write.
- **MOV r/m,r** (0x15A0/0x15B0): writes 4 cycles after the 8088 would have
  read (MartyPC 0x1e3/RTN and 0x000/0x001), as a release add. Known: with a
  segment prefix, [bx+di]/[bp+si] writes come 1 cycle early (4% of 88/89).
- Sampled exact on all cycles: every ALU r/m,reg and reg,r/m form,
  CMP/TEST, MOV r,r/m, all of ADD/OR/AND/XOR/CMP in 80-83.

## 2026-10-21 - MOV r/m,imm, TEST r/m,imm, NOT/NEG; a writeback fix

l to m:
- **BIU:** three taken bytes. MOV r/m16,imm16 deadlocked with two (the
  ModR/M byte held, the immediate's low byte taken, the scheduled high byte
  had no room). The scheduled-read pending flag goes to the EU as
  system_signals bit 14, so microcode can wait for the BIU's read instead of
  racing it.
- **MOV r/m,imm (C6/C7):**
  - register operand as group 80/81;
  - memory operand: the immediate 2 cycles after the 8088 would have read
    the operand (scheduled at the EA release in r2 + 2), the write 3 cycles
    after the immediate, the end at the write.
  - Known: C7 to memory writes late in ~40%.
- **TEST r/m,imm (F6.0/F6.1/F7.0):** the immediate 2 cycles after the
  ModR/M byte for a register, scheduled by a reg-field-aware armed entry,
  since the F6/F7 groups share CALC_EA with NOT/NEG/MUL/DIV. Memory as CMP.
  All exact.
- **ALU writeback fix:**
  - The patch armed "end at the next transfer" for register destinations
    too. Without an earlier armed end (NOT/NEG of a register) no transfer
    ever came, and the instruction waited on the parked counter for
    hundreds of cycles.
  - Now memory only (0x1670/0x1680).
- **NOT/NEG:**
  - end 2 after the ModR/M byte for a register;
  - memory write released 4 cycles after the read ended.
  - NEG r/m16 exact. Known: NOT to memory 1 cycle early in ~20%; NEG r/m8
    1 cycle late in ~75% (MCL86's byte SUB is slow).

Run m against l:
- Gains in C6/C7, F6/F7 and the shift files: the register-form writeback
  stall is gone.
- Losses in 83.2/83.5 (ADC/SUB r/m16,imm8 to memory, 5,973 -> 2,534 and
  4,371 -> 2,458). The writeback's new register test adds microinstructions
  to a path where MCL86 was already at the limit of the 8088's timing.
  These belong to the known limit (slow ADC/SBB/SUB microcode) and come back
  when that microcode is sped up.


## 2026-10-21 - INC/DEC r/m; request release timing; the system board

n to o:
- **BIU, request release:** a request held by a release (strobe 11 code 6)
  was released before the step's per-cycle phase work, so a pending fetch
  delay lost a cycle in the release step. Now the release comes after it,
  as for a request the EU makes directly. This was the "1 cycle early"
  class: NOT to memory (~20%), MOV [m],r with a segment prefix (88/89, 3%).
- **INC/DEC r/m (FE.0/FE.1, FF.0/FF.1):** same schedule as NOT: the register
  form ends 2 cycles after the ModR/M byte (wrappers 0x1700/0x1704, armed
  entry 0x1710), the memory form goes through the NOT/NEG writebacks.
- Run n (BIU pins READY/INTR/NMI/LOCK added, READY tied high in the suite):
  identical to m on every file.
- Run o: trace-exact 2,322,518 (77.2%), length 2,327,739; no file worse.
  FE.0/FE.1/FF.0/FF.1, F6.2/F7.2, 88/89 are 100%.

The system board (commit 5f224fb) and a Verilator model of the whole PC
(tb/sys) boot GLaBIOS 0.4.2 to its banner. tools/itrace_diff.py and
tools/ctrace_diff.py compare instruction and cycle traces with MartyPC
(branch martypc-ref): the first 16,460 instructions match register for
register; the first cycle difference is the end of an instruction whose
last bus cycle has a wait state (OUT A0h, clock 347).

## 2026-10-21 - IBM CGA card

`rtl/video/cga/` (branch `cga`): the IBM CGA on the card bus, with
MartyPC (MIT, commit 05c0d08) as the timing reference. Design and every
deviation: `doc/cga.md`.
- `cga_crtc.sv`: the Motorola MC6845, MartyPC's `Crtc6845::tick()` per
  character clock (last-line management, VTA, interlace, HSYNC width 0 = 16,
  fixed 16-line VSYNC, cursor blink modes, light pen).
- `cga_card.sv`: 16 KB VRAM (mirrored), 3D0-3DF, the mode deferral of
  text/graphics changes to HSYNC, the 80-column clock switching on lchar
  boundaries, all modes with MartyPC's drawing rules, blink, snow, an 8 KB
  character ROM port (IBM ROM layout, loaded by the glue), RGBI + syncs + a
  display window, raw composite signals.
- **Wait states:** MartyPC's `WAIT_TABLE` is one rule: the access ends at
  the instant the lchar phase becomes 14, at least 9 ticks after (end of
  T2 + 1). The card applies it from the board's MEMR/MEMW edges
  (`RD_LEAD` 6, `WR_LEAD` 3 for `xt_board.sv`).
- **Timing convention:** the card's dot update runs one clk before the
  board's edge of the same 14.318 MHz instant (`CE_DELAY` 6), which gives
  MartyPC's "catch up, then access" order for READY, read data and writes.

`tb/cga/`: Verilator TB with a model of `xt_board.sv`'s bus timing and a
C++ transliteration of MartyPC's CGA/6845 (`cga_model.h`) ticked next to
the card; every dot (colour, HSYNC, VSYNC) and every bus read is compared.

Results (`make -C tb/cga run`, 3 minutes):
- wait states at all 16 lchar phases, reads and writes: equal to MartyPC's
  table (256 accesses);
- BIOS modes 0-6: every dot of 2 frames equal, 912 dots x 262 lines;
- 3DA: 31,872 reads equal (also with VSYNC inside the display);
- random register writes (CRTC, mode, colour, light pen) and small 6845
  geometries: ~7.7 M dots and ~25,000 reads equal; cursor through VTA,
  snow, 34 frames of blink, thin font: equal.
- `tb/cga/mut.py`: 25 mutants, all killed. The first run found three
  test holes (blink compared only the last frames; no VSYNC inside the
  display; no repeated last line or cursor through VTA), closed.
- The `crtc` test found one real difference: MartyPC draws with the 6845's
  live RA, so an R8 write in mid-character changes the glyph row there; the
  card (and now the model) latches the row at the character clock, as the
  CGA's shift register does.

Out of context (Vivado 2022.2, xc7a200t-2, `tools/ooc/cga_ooc.tcl`): 480
LUTs, 415 FFs, 6 BRAM tiles, +2.15 ns at 100.2273 MHz.

System simulation with the real card instead of `cga_stub.sv` (`tb/sys`,
GLaBIOS 0.4.2 8X, 2 s): boots to the RAM test with the BIOS screen in VRAM,
so READY, the status polling and VRAM writes work with `xt_board.sv`
(no font loaded there: `pc_system` has no font port yet).

Open: composite decoding; a trace comparison with MartyPC itself running a
program (`tb/sys`); the font port in `pc_system`.


## 2026-10-21 - INT flags, AF in string ops (run p)

- **INT/INT3/INTO/exceptions** pushed FLAGS without bit 1 (and with MCL86's
  prefix state in 15-12): the INTERRUPT routine (0x04F6) now calls the PUSHF
  value procedure 0x12A0. CC/CD state 0 -> 100%, CE 49 -> 100%.
- **String ops** kept the segment override across their ES access in AF
  (STORE/RESTORE_SEG_PREFIX 0x0750/0x075A): now in flag bit 3 (scratch;
  PUSHF/LAHF mask it).
- Run p: state 2,907,858 -> 2,934,084; trace 2,322,516 (F6.7 IDIV r/m8 lost
  2 tests: its divide-error path is a few microinstructions longer; IDIV is
  not timed yet).

## 2026-10-21 - Floppy disk controller (branch `fdc`)

`rtl/fdc/`: the IBM PC/XT diskette adapter (`fdc_card`: DOR 3F2, MSR 3F4,
data 3F5, DRQ2/DACK2/TC, IRQ6, two drives) around a uPD765A core
(`upd765`) and a two-slot sector buffer with the sector port to the MEGA65
glue (`fdc_secbuf`). The disk surface is synthetic: a rotation of 6250 byte
times (200 ms), standard IBM MFM layout, sectors fetched from / committed to
the image through the sector port, the rotation held while the backend is
late. Design, protocol and timing sources: `doc/fdc.md`.

`tb/fdc` (`make run`): Verilator bench with BIOS-like bus cycles, an
8237-like DMA model and an image backend with random latency. All checks
pass (10.4 s simulated, about 5 minutes); five mutants (MT result table,
overrun detection, TC zero padding, the 77-step recalibrate limit, DOR bit 3
gating) are each caught.

Found while wiring: `xt_board.sv` drives `isa_tc` active low (the 8237's
EOP_n) and gives DMA memory-to-I/O cycles the card's own `isa_din` on
`isa_dout` instead of the memory data (doc/fdc.md section 6).

## 2026-10-21 - String instructions, ESC, MOV sreg (runs q, r)

- **String instructions** (tools/gen_strings.py, 0x1720-0x18D7): per op a
  START routine (release of the first transfer: non-REP 3 cycles after the
  opcode read, CMPS 4, SCAS 5; first REP iteration 10, CMPS 11, SCAS 12;
  later iterations n after the previous iteration's last transfer: STOS/MOVS
  5, LODS 7, CMPS 8, SCAS 9), MID (MOVS write 1 after the read, 2 with a
  segment prefix and no REP; CMPS second read 2 after the first), END (SYNC
  to n after the last transfer, then the end: non-REP 3 (CMPS/SCAS 4), CX
  exhausted 4/6, CMPS/SCAS Z condition 5). Iterations after the first carry
  flag bit 1 (cleared at 0x0004); the harness skips their re-dispatch.
  The MartyPC single-test tracer (tools/martypc/sst_trace.sh) showed the
  non-REP request comes 3 cycles after the opcode read, not 4: with an empty
  queue it aborts a prefetch whose address cycle has begun.
  All ten (A4-A7, AA-AF) are 100% trace-exact.
- **ESC (D8-DF)** through the MOV r16,r/m16 wrapper: 100%.
- **MOV r/m16,sreg (8C)** through the MOV r/m,r wrapper, write released 2
  after the 8088's read point (89 has 4): 71%. **MOV sreg,r/m16 (8E)**: the
  memory forms end one cycle late in ~75% (open).
- Run q: trace 2,338,519 (77.8%); run r: 2,419,649 (80.5%), length
  2,424,870, state 2,942,050 (97.8%). No file worse.

## 2026-10-21 - LEA, LES/LDS, XCHG, POP r/m, the FF group (run s)

All timed from the suite plus MartyPC's single-test traces
(tools/martypc/sst_trace.sh, which shows where the 8088's EU issues each bus
request, SUSP and FLUSH):
- **LEA**: end at the EA release r2 + 2 after the last queue read.
- **LES/LDS**: the second word released 4 after the first, end at its end.
- **XCHG r/m**: write released 6 after the read, end at the write.
- **POP r/m**: stack read released r2 + 3 (CALC_EA's release plus a release
  add), the write 3 after it, end at the write; no legacy wait.
- **JMP r/m**: SUSP (memory: 2 after the read), flush 1 after the SUSP
  completed (it completes at a running fetch's T4), end at the first new byte.
- **CALL r/m**: flush first (SYNC 3 after the ModR/M byte, memory 2 after the
  read; SUSP; 4 later the jump), then push the return address.
- **JMP FAR m**: SUSP 3 after the offset read, the segment read 1 after the
  SUSP completed, the jump right after it (inline; FETCH_EA's tail was a
  cycle too slow).
- **CALL FAR m**: the 8088's order: segment read 3 after the offset, SUSP 1
  after it, push CS 3 after the SUSP, flush 4 after that push, push IP.
- **PUSH r/m**: write released 4 after the ModR/M byte (register) or 5 after
  the read; PUSH SP through FF F4 pushes SP - 2 (state fix).
- Run s: trace 2,534,445 (84.3%), state 2,942,637. No file worse. 8D, C4,
  C5, 86, 87, 8F and FF.0-FF.7 are 100%.

## 2026-10-21 - Shifts and rotates (run t)

- **By 1 (D0/D1):** register end 1 after the ModR/M byte (wrappers 0x19E8
  byte, 0x1088 word), memory through the NOT/NEG writebacks (write released
  4 after the read, end at the write).
- **By CL (D2/D3):** the suite shows register end = ModR/M + 7 + 4*CL and
  memory write = read + 15 + 4*CL (CL is not masked on the 8088). 0x19F0 arms
  either at the start of every CL routine (A007 + 4*CL, or release
  2009 + 4*CL with the end at the write); the routines leave through the plain
  writebacks so the ALU writeback's release does not override it.
- Run t: trace 2,742,721 (91.2%), length 2,764,984. No file worse. All of
  D0-D3 except the undocumented SETMO/SETMOC (D0.6/D1.6/D2.6/D3.6) are 100%.

System: the 8237 got the hold acknowledge while the CPU was still inside a
bus cycle (the status pins go passive in T3), which broke GLaBIOS's PIC and
RAM tests; AEN and the 8237's HLDA now come only at the CPU's T4 or an idle
bus (b292ea6).

## 2026-10-21 - INT/IRET (run u)

- **Interrupts** in the 8088's order (0x1A00): vector IP read, CS read 1
  later, SUSP at its end, push FLAGS 2 after, push CS 5 after that, flush 4
  after the CS push, push IP 7 after it. First table read released by the
  caller: INT n 4 after the type byte, INT3 8 after the opcode, INTO 9; INTO
  not taken ends at cycle 4. **IRET** (0x1A50): pop IP 4 after the opcode,
  SUSP, pop CS 3 after, flush at its end, pop FLAGS 2 after, end 5 after.
  CC, CD, CE, CF 100%. Hardware interrupts, NMI, divide errors and the
  single-step trap use the same routine; their entry timing is not
  calibrated yet (system traces against MartyPC).
- Run u: trace 2,777,773 (92.4%). F6.7 (IDIV r/m8) lost 1 test through the
  divide-error path (IDIV is untimed).

## 2026-10-21 - Segment loads, MOV r/m,sreg, SALC (run v)

- After a segment register load MCL86 jumps to a main-loop entry that skips
  the interrupt polls (right: the 8088 inhibits interrupts for one
  instruction) but also the wait for the end counter, so the next opcode was
  read early. 0x1A90 waits for the end, then dispatches. 8E 25% -> 100%.
- MOV r/m16,sreg (8C): write released 3 after the 8088's read point: 100%.
- SALC (D6): CF set ends a cycle later (0x1A98). Prefixed SALC is still one
  cycle early.
- Run v: trace 2,790,714 (92.8%), length 2,813,289. No file worse.

## 2026-10-22 - First floppy boot (tb/sys)

- tb/sys with GLaBIOS 0.4.2, the real CGA, the 765 + 8237 path and the test
  image `hello360.img` (360 KB; its boot sector loads sector 2 by INT 13h and
  prints a line): cold boot, RAM test to 640 KB, equipment line (CGA, 8088,
  2 floppies), FDC reads C0 H0 S1 and S2 by DMA at 9.405 s simulated, screen
  "Booted from floppy A: (pc10-iii FDC+DMA)", then the image's halt loop at
  0000:7C1D. First end-to-end boot of the whole PC (CPU, board, DMA, FDC,
  CGA) in simulation.

## 2026-10-22 - Prefixed Jcc (run w)

- The 6x opcodes (8088 aliases of 70-7F) are the only Jcc tests with
  prefixes. A taken prefixed jump with a full queue suspended one cycle
  early: our EU reads the queue one clock before MartyPC's queue-read point
  (QS shows it a clock later, as on the 8088), so "SYNC 2 after the last
  queue read" is MartyPC's read + 1, and the SUSP fell in the T4 of a code
  fetch and cancelled the fetch the BIU had already committed for the next
  cycle. MartyPC: Jcc spends a cycle (0x0E9) before RELJMP, JMP short jumps
  straight in. Jcc taken now enters at 0x1AA0 with SYNC 4003; JMP short
  keeps 0x0344 and SYNC 4002. Without a prefix the earlier SUSP fell into a
  running fetch and waited for its T4, which hid the difference.
- tb/sst: `-l` lists every test (state/trace, queue length, cycle count,
  bytes); with `-d` the dump shows the BIU's address-cycle state and queue
  length, and `SST_UC=1` every microcode address the EU visits.
- Run w: trace 2,798,156 (93.05%), +7,442 (69, 6B-6F to 100%). No file
  worse.

## 2026-10-22 - SALC, SETMO, AAM/AAD state, NEG r/m8 (run x)

- **SALC** with CF clear also spends a cycle before its end (MartyPC 0x0A0,
  then RNI): the next opcode at cycle 3 (0x1AB0). D6 100%.
- **SETMO / SETMOC** (/6 of D0-D3, MCL86 ran SHR there): all ones, CF AF OF
  ZF cleared, SF PF set; SETMOC does nothing with CL = 0. Timing as SHR
  (0x1AC0-0x1ADF). All four files 100%.
- **AAM/AAD:** S, Z and P from AL (All_Flags_BYTE), not from AX. AAM with a
  zero immediate is a divide error: AX unchanged, flags of a zero result,
  INT 0 (0x1AE8). States 100%; their timing (the 8088's division loop) is
  still open.
- **NEG r/m8:** (x XOR FF) + 1 with one flag pass and CF/AF inverted
  (0x1AF0); MCL86's SUB_BYTE (two additions, flags twice) made the write a
  cycle late. F6.3 100%.
- Run x: state 2,978,782 (99.06%), trace 2,830,340 (94.13%), +32,184. No
  file worse.
- Left: MUL/DIV/AAM/AAD timing, ADC/SBB/SUB imm to memory, C6/C7 to memory.
  All three need EU or BIU changes (a cycle counter, a carry-in add, queue
  strobes for bytes the BIU has already read that complete in the same clk).

## 2026-10-22 - XTIDE hard disk card (branch `xtide`)

`rtl/hdc/`: an 8-bit XTIDE-compatible ISA card for the XTIDE Universal BIOS
(XUB): the option ROM socket C8000-CBFFF (the glue's ROM, read like the BIOS
ROM), two ATA drives (`ata_dev`: task file, IDENTIFY, READ/WRITE SECTORS and
MULTIPLE up to 8-sector blocks, SET MULTIPLE, VERIFY, INITIALIZE DEVICE
PARAMETERS, SET FEATURES 8-bit, CHS and LBA28, SRST, INTRQ) and an 8-slot
sector buffer behind the floppy's sector-port protocol with an LBA28 address
(`hdc_secbuf`: reads prefetched ahead of the host, writes committed behind it,
write-through). Design, timing model, the shell plan: `doc/hdc.md`.

- **Variant:** the XT-CF / Lo-tech register map (XUB device type 9, "PIO16
  with BIU offload"): `in ax,dx`/`stosw` and `lodsw`/`out dx,ax`, the fastest
  PIO on an 8088 both ways, with a plain 16-bit drive; the same decoder runs
  XUB's default type 7 (XT-CF 8-bit). XTIDE rev 1 and rev 2 maps as run-time
  variants 1/2 (for existing XUB images, the 4 KB tiny build, MartyPC's rev 2).
- **XUB:** GPL-2.0-or-later; r638 binaries and source from
  xtideuniversalbios.org in `~/pcxt-work/xtide/` (not in the repository).
  `tools/xubcfg.py` configures an image (device type, port, slave detection,
  padding, checksum) as XTIDECFG does.
- **tb/hdc:** 3184 checks over the three register maps (random backend
  latency), 20 of 20 mutants killed (`mut.py`).
- **tb/sys:** `-X xub -H img -V variant -W out`, RAM_KB (128 KB: GLaBIOS's
  memory test 0.25 s instead of 5 s), screen snapshots. A 20 MB test image
  (615/4/17, FAT16 partition, `tb/sys/hd/mkhdimg.py`) with an MBR that tests
  INT 13h AH=08h/02h/03h. Four 10 s runs (Fedora host, ~35 minutes each):
  XUB `ide_xt` type 9 without and with (empty) floppy drives, type 7 (8-bit),
  `ide_tiny` on rev 2: GLaBIOS finds the ROM, XUB identifies "PC10-III
  XTIDE disk image" as master, the slave "not found", boots C: (at 6.7 s;
  tiny 4.8 s), the MBR reads (sum F600 OK) and writes (read back OK); the
  images afterwards: exactly the four written sectors changed.
- **Measured** (XUB's loops on the cycle-exact CPU, per sector): Lo-tech read
  1.77 ms (33 clocks/word, 289 KB/s), write 1.81 ms; XT-CF 8-bit 2.44/2.48
  ms; rev 2 read 1.82 ms, write 3.59 ms.
- `pc_system`/contract: `hdc_enable`, `hdc_variant`, `hdc_rom_addr/rdata`,
  `hd_*`, `hd_sp_*`; the shell ties the card off (`hdc_enable = 0`) until
  the SD backend exists (doc/hdc.md section 8).

## 2026-10-22 - Refresh DMA against MartyPC; the BIU's blocking assignments

- **8253:** a control word set OUT from the OLD mode for one clk (KF8253: mode
  0 after reset, so OUT low), then from the new one: a false edge on OUT. The
  control word now sets OUT from the new mode at once. OUT before the first
  control word is undefined on the 8253 (`OUT_INIT`); counter 1 starts high,
  so the BIOS's mode-2 control word is no OUT1 edge and DRQ0 is not pending,
  masked, until the BIOS unmasks channel 0 (MartyPC's refresh has no such
  request). First difference to MartyPC: clock 208,499 -> 208,539.
- **Refresh phase:** MartyPC starts its refresh schedule when its device loop
  sees the PIT write, 7 CPU clocks after the 8253 reloads (its tick
  accumulator is unused). The hardware stays as it is; `DRQ0_SKEW` (tb/sys
  `make DRQ0_SKEW=7`, simulation only) delays DRQ0 to compare traces past it.
- **AEN** ends in the CPU clock where the 8237 drops HRQ (`hold_request_next`
  from the 8237): five clocks per transfer (S1 S2 S3 SW S4) as MartyPC's, one
  wait state less for the CPU cycle the refresh holds. With the skew: first
  difference 208,613 (the second refresh, during a code fetch: our HOLDA one
  clock early).
- tb/sys trace: the address column is the CPU's address latch (MartyPC's
  column; it used to be the board's bus address, the DMA address during a
  transfer); DMA markers R H F A K plus the 8237 state (`/0 /1 /2 /3 /W /4`).
- **Found:** biu88's clocked block assigns its state with blocking `=`, so in
  Verilator the EU and xt_board, clocked on the same edge, read the BIU's
  outputs AFTER the edge (seen: `hrq_ff1` loads the passive status of T3 in
  the edge that leaves T2). On the FPGA they read them before the edge. The
  simulated cycle timing (SST, tb/sys) can therefore differ from the
  bitstream's wherever a clocked reader samples BIU outputs on `cpu_step`.
  The second refresh's one-clock-early HOLDA is exactly that case. Handed to
  the cpu-timing work; board calibration waits for its answer.

## 2026-10-22 - IBM MDA and Hercules card (branch `mda`)

`rtl/video/mda/mda_card.sv`: the display part of the IBM Monochrome Display
and Printer Adapter and a Hercules Graphics Card mode, on the card bus.
Design, schematic reading and every difference: `doc/mda.md`.
- **Source:** IBM's MDA logic diagrams (Technical Reference 6361511, sheets
  1-10) for the timing, the CPU slot, the attributes and the ROM layout.
  MartyPC's MDA was read too: its wait states are the CGA's table indexed
  with the MDA clock (3-8 waits, mean 5.9), so it is not used for timing;
  its attribute table is used as a cross-check.
- **Dot clock:** 16.257 MHz (Hercules 16.000) from `clk` with a fractional
  accumulator (59609/367500), rising and falling edge enables; exact on
  average, each dot 6 or 7 clk.
- **Card logic from the schematic:** the 9-state character counter, CCLK
  (6845 steps when it rises), the two-character display pipeline (U31/U34
  -> U29/U30/U32), DISPEN/CURSOR delayed two characters and the syncs one
  (HSYNC stretched by one), U101's one-dot video register, the attribute
  decoder (no display, reverse, underline at row 12, blink, intensity,
  background intensity with blink off), the 9th dot for C0-DF, U28's
  cursor (16 frames) and character (32 frames) blink, the horizontal drive
  gate (U45), the status port (bit 0 delayed HSYNC, bit 3 the video dot).
- **CPU slot:** a VRAM or 6845 access is sampled at the 4Q edge and gets
  IOCHRDY at the next CCLK falling edge, 5.5-14.5 dots after the strobe.
  With `xt_board.sv`'s command edges and `biu88.v`'s READY sampling (as
  T3/Tw begin, since 8bf11db): VRAM reads 1-4 wait states (mean 2.4),
  6845 I/O 1-4 / 2-5 including the board's one. Without 3B8 bit 0 the dot
  clock is not selected and such an access never ends (as IBM warns).
- **Found: VRAM writes never wait on the current board.** MEMW starts at
  the falling edge in T2, the edge that already decides whether T3 is the
  last; no card can insert waits into a memory write. GLaBIOS's screen
  stayed blank (the MDA wrote only when the slot fell inside the 349 ns
  strobe). The card now writes at the strobe end if the slot has not come
  (like the CGA's fallback); the board's write timing is an open point for
  the board work (the CGA's write waits are affected the same way).
- **Character ROM:** MK36000 A11 = RA3, A12 = jumper: the MDA font is in
  the first 4 KB of the 5788005 image (rows 0-7 at char x 8 + row, rows
  8-15 at 0x800 + ...). The card shares the CGA's font load port.
- **Hercules:** 64 KB, 3BF (allow graphics, page 2), 3B8 bits 1/7,
  720x348 graphics with 16-dot characters, status bit 7; no B8000-BFFFF
  when a CGA is fitted.
- `pc_system`: `CGA_FIT` (1), `MDA_FIT` (0 none / 1 MDA / 2 Hercules), new
  outputs `mda_ce/video/intens/hsync/vsync/hblank/vblank`; the glue sets
  `dip_sw1` bits 5-4 = 11 for a monochrome primary display.

`tb/mda/` (Verilator, the board's bus timing, a C++ model of the schematic
reading `mda_model.h` stepped on the same clk; MartyPC's 6845 from
`tb/cga/cga_model.h`). `make -C tb/mda run`, about 3 minutes:
- IOCHRDY equal at every clk; 3,000 random accesses (wait distribution
  above); ~29,000 reads equal (bus, 3BA, 6845);
- mode 7, all characters and attributes: 2 frames dot-exact, 882 dots x 370
  lines (18.432 kHz, 49.82 Hz), text at dots 154-873 / lines 20-369;
- torture (3 x 4 frames of random 6845/3B8/VRAM writes), status, 104
  frames of blink (also with VSYNC in the display), horizontal drive gate,
  the HRES hang: all equal; Hercules text, 720x348 graphics on both pages,
  3BF gating, CGA coexistence, status bit 7: all equal;
- attribute decoder vs. MartyPC's `MDA_ATTR_TABLE`: 512 cases equal except
  the 128 with background intensity (blink off, bit 7), which MartyPC lacks;
- `mut.py`: 35 mutants, all killed. The first run found one hole (the
  blink counter's edge is invisible while VSYNC is in the blanking), closed.

`tb/sys` (`make MDA=1`, `sys_run -m -F font -o image`): GLaBIOS 0.4.2 8X
with the MDA fitted next to the CGA and the mono DIP setting: mode 7 at
518 ms, the banner on the MDA at 0.8 s simulated (text dump and PNG).
With the Hercules card (`make MDA=2`): banner and RAM count at 2.6 s (the
HGC detection message after the RAM test not reached in that run).

Open: the board's write timing (above); a Vivado out-of-context run; the
printer port; Hercules details without a schematic (doc/mda.md section 10).

## 2026-10-22 - Merged: board timing, XTIDE, CPU timing (race-free BIU), MDA; system trace to clock 1,041,809

- Merged `board-timing` (every non-CPU path passes in bt-j), `xtide`, `cpu-timing`
  (CPU out of context +0.407 ns; biu88 outputs are nonblocking copies, so the
  simulation does what the hardware does) and `mda`. `pc_clocks`' enables are
  registers now (byte-identical traces); `rtl/cpu/cpu8088.xdc` is in CORE-R6
  scoped to cpu8088; `mda_card.sv` is in the project.
- **SST run y** (race-free CPU + run x microcode): state 99.06%, trace 2,828,908
  (94.08%), -1,432 against the racy run x: 81.3 -1,183, CF -118, F6.0 -52,
  F6.1 -65, a few in F6.6/F7.4/F7.6/F7.7. This is the new baseline; the racy
  numbers were not what the bitstream does.
- **The race and the refresh:** with the race gone, the board's HOLDA flip-flop
  sees the status of the clock it samples; AEN follows HOLDA by one CPU clock
  (also in the CPU's T4 and T1, as MartyPC's S1 after HLDA), the T4/Ti gate,
  calibrated on the racy simulation, is gone. The DMA wait (READY) runs from
  the clock AEN rises (S1) to one clock after it falls.
- **RAM request per bus owner:** a CPU cycle that a transfer holds from its T1
  gets its MEMR right after the 8237's, so MEMR stays low across both; the
  board now starts RAM requests on the CPU's and the 8237's own strobes, and
  the refresh condition (DACK0, which outlasts AEN) gates only the 8237's.
  Before, such a CPU read returned the previous read's byte.
- **MartyPC trace diff** (`make DRQ0_SKEW=7`, 6M-clock reference): equal to
  clock 1,041,809 (was 208,499). There: XCHG [SI],DX ends with a full queue
  and MartyPC's preload byte; MartyPC takes the next opcode (INC AX) in the
  write's T3, ours in T4.
- Open (board): MEMW asserts at the falling CLK edge in T2, the same edge that
  samples IOCHRDY, so a card cannot add wait states to a write (the MDA's and
  CGA's write fallbacks work around it). MartyPC: AMWC from T2, CGA writes
  not ready from T2 on. To settle against MartyPC's CGA write cycles
  (first at reference clock 2,443,292).

## 2026-10-22 - Carry-in add, MUL/DIV/AAM/AAD as the 8088, EU lateness after a BIU opcode read; system trace to clock 2,439,285 (branch `cpu-y`)

- **tb/sys at 1,041,809** (the task from the merge): XCHG [SI],DX ends with a
  word write; its end (B000) has the BIU read INC AX's opcode in the write's
  T3, as MartyPC (its EU takes the preloaded byte there). Our EU still runs
  XCHG's last microinstructions and dispatches INC AX a clock later; INC/DEC
  r16 ended by the EU reaching the main loop (a legacy core-clock count, C002),
  so the opcode after INC AX was read a clock late. The 8088 rule is simply
  INC/DEC r16 = 2 cycles from the opcode read: absolute ends (E002). A
  detector for this class: a dev ROM whose main loop waits one more 8088
  clock before every dispatch (`SYNC 8001` at the queue test), i.e. every
  instruction starts with the BIU's own opcode read and a late EU; the SST
  files that get worse end through the EU's speed: 40-4F, 91-97 (XCHG AX,r:
  E003), 98 (CBW: E002), 9E (SAHF: E004) and MUL/DIV, all fixed.
- **Board (xt_board.sv):** the I/O wait state counts only after the DMA
  wait (AEN keeps the 8288's I/O command off; MartyPC's cycle.rs does not
  decrement I/O wait states while DMA wait states remain). An OUT whose T1
  met the refresh had one Tw too few (reference clock 1,042,013).
- **CLK phase sweep** (`sst_run -S 21`, `-P p`): the 100 MHz core clock gives
  20- or 21-clock 8088 periods (one 20 in ~21), and their position depends on
  the tests before, so an EU that reaches a SYNC or a strobe near a clock
  edge passes or fails by history. With -S each test runs at all 21
  positions. Found: CF (IRET) passed 240 of 300 at all phases (the CS pop
  waited `SYNC 8003`, 3 cycles from where the EU happened to be: now `C003`,
  3 after the IP pop ended); F6.0/F6.1 register TEST (the end armed after the
  immediate's fetch procedure, now as soon as the BIU's scheduled read has
  happened, 0x1B00). These were the race fix's CF/F6.0/F6.1 "regressions".
- **Carry-in add (eu.v):** bit 31 of an ADD word (unused) adds CF. ADC is one
  add, SUB = r0 + ~r1 + CF with CF set first, SBB the same with CF inverted
  first; one flag pass instead of two (MCL86 added twice and computed the
  flags twice). The 80-83 /2 /3 /5 memory forms wrote late because of the
  slow EU (81.3 was the race fix's -1,183): all twelve files 100%. OOC
  (`rooc.sh cpuy-a`): WNS +0.387 ns, WHS +0.105 ns (was +0.407).
- **MUL/IMUL/DIV/IDIV r/m8, r/m16, AAM, AAD** (`tools/gen_muldiv.py`,
  0x1B20-0x1EB1): the 8088's algorithms (CORX, CORD, the NEGATE and the
  signed pre/post steps, the REP prefix negation) step by step, so results,
  flags and the cycle count are the 8088's; the cycle counts per step from
  MartyPC's muldiv.rs (MIT). A Python model of those counts fits the suite
  exactly (register: end = opcode + 3 + cycles; memory: operand read end + 2
  + cycles; AAM/AAD: immediate + 1 + cycles); `gen_muldiv.py --test` runs the
  generated microcode in a small simulator against the model (results, ends,
  divide error releases). The end is armed from the count (A mode after the
  ModR/M byte; memory: SYNC 64 after the read, then F mode). Divide errors:
  the flags of the last flag-setting subtraction (minuend kept in the BIU's
  RM register), the first vector read released as the 8088's, and no IP-1
  (the register-operand marker in flag bit 14 made the INT routine push
  IP-1; MCL86's old DIV also went through 0x0F11, which restores AX/DX
  captured only after a prefix). D4, D5, F6.4-F7.7: 100% state and trace
  (were 0-25% trace, 23-97% state).
- **AAD:** MCL86's 0x02B7 ("jump over the first iteration") is a type 0 word
  with a non-zero immediate, i.e. since the SYNC "wait for cycle 0x2B9": AAD
  waited ~700 cycles (now a NOP; the system trace stopped there).
- **C7 to memory:** the immediate is taken from the queue view (the BIU read
  it already), without the fetch procedure's SYNCs, and the write released 2
  after the high byte (was 3: the write lost its slot to a code fetch); C7
  100%. C6 unchanged (the [bp+di]/[bx+si] forms write a cycle later than the
  release after the immediate gives; 307 tests).
- **Runs** (`~/pcxt-work/results/`): biu88-y1 (INC/DEC, IRET, TEST8, carry-in):
  trace 2,905,550 (96.63%), +76,642, no file worse. biu88-y4 (all, = y3):
  state 3,007,000 (100.00%), trace 3,006,693 (99.99%, +177,785 on run y), no
  file worse; only C6 (9693/10000) is left. Full runs now go to the Fedora host (16 jobs, ~10
  min).
- **tb/sys** (DRQ0_SKEW=7, 1.27 s): first difference 1,041,809 -> 1,042,013
  (INC/DEC) -> 2,439,097 (board I/O wait; AAD's SYNC there) -> 2,439,285.
  There: OR AL,DL then TEST AL,2: the BIU reads TEST's opcode at OR's end,
  our EU dispatches it ~2 cycles later and reads the immediate a cycle late.
- **EU lateness survey** (`sst_run -L`: core clocks from the start of the
  cycle in which the BIU read the next opcode to the EU's dispatch on it):
  the register forms of the ALU ops (00-3B), D0/D1, F6/F7 /2 /3, FE/FF /0 /1
  and others dispatch the next instruction 1-4 cycles after the BIU read it
  (up to 90 core clocks for D0.5/D0.7): MCL86 needs ~100-130 microinstructions
  for an instruction the 8088 does in 2-3 cycles. In the suite this is
  invisible (the window ends at that read); in a program the next
  instruction's first reads (ModR/M at cycle 1, an immediate at 2) come late.
  This is the next limit of the system trace.

## 2026-10-22 - Faster flags for OR/AND/XOR/TEST (run y5)

- The first step against the EU lateness above: the logical operations'
  flags (S, Z, P from the result; C, O, A cleared; the suite masks A) in
  10/11 microinstructions (LOGICB/LOGICW at 0x1F30) instead of
  CALCULATE_FLAGS (18/12) plus the clear. `sst_run -L -n 1000`, tests whose
  next dispatch comes more than 2 cycles after the BIU's read: 0A 119 -> 6,
  22 119 -> 65, 32 143 -> 82, 84 117 -> 0 (max lag 51 -> 43 core clocks).
- Run y5: identical to y4 (state 3,007,000, trace 3,006,693). tb/sys still
  differs first at 2,439,285: OR AL,DL (register form, ~110
  microinstructions from dispatch to the next dispatch, 5 cycles of EU time
  for a 3-cycle instruction) leaves the EU 2 cycles behind, and TEST AL,2
  reads its immediate a cycle late. Register-form ALU instructions need a
  shorter path (operand fetch/writeback through the register tables,
  CALC_EA's ModR/M decode for register operands, the main loop): open.
