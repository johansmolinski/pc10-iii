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

## 2026-10-22 - Build pc10-real-e: the whole core meets 100.2273 MHz

- Full R6 build of main 7437964 (board timing, CPU timing, registered
  `pc_clocks` enables, `cpu8088.xdc` scoped to cpu8088), fedora
  `~/pcxt-builds/pc10-real-e` (kept for incremental builds, `REF=pc10-real-e`),
  reports in `~/pcxt-work/builds/pc10-real-e/`.
- Setup met everywhere: main_clk WNS +0.065 ns (the PC), hdmi +1.874, qnice
  +0.332, hr_clk +0.922. Utilization: 28,004 LUTs (20.9%), 20,443 FFs, 238.5
  BRAM tiles (65.3%). The microcode image was read by synthesis.
- Hold: one endpoint, -0.007 ns, the framework's HyperRAM input `hr_d_io[4]`
  -> IDDR (clock hr_rwds, 100% I/O-buffer delay), the path Megamiga knows
  (fastdisk-b missed it by 0.054 ns). It moves with placement (pc10-real-d
  +0.240, bt-j +0.021) and does not touch PC logic; the build script reports
  TIMING-FAILED because of it.
- The main checkout's `M2M/QNICE` submodule was not initialized (earlier builds
  came from worktrees): `git submodule update --init M2M/QNICE`.

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

## 2026-10-22 - READY sampled like the 8284 (branch `board-ready`); CGA writes wait

- **Board rule:** `xt_board.sv` sampled IOCHRDY at `cpu_fall`, the falling
  CLK edge 7 clk into a state, and biu88 (since 8bf11db) decides at the next
  step whether the T3/Tw it enters is the last: T3 was decided at the edge
  where MEMW/IOW start, so no card could stretch a write (the CGA and MDA
  wrote at the strobe end as a workaround). The 5160's 8284 takes RDY in two
  stages (rising edge, then falling edge) and the 8088 samples READY at the
  next rising edge, the one that ends T3/Tw: RDY at the rising edge that ends
  T2 decides T3. Now IOCHRDY is sampled on `rdy_ce`, a new `pc_clocks`
  register enable 2 clk before `cpu_step` (about the RDY setup time), into
  the register that drives READY_IN: stable over the clock before the step
  and the step's own (biu88 reads READY_IN on the step's clock; it has no
  `sn_*` copy of it). The DMA wait term changes only on steps, so it is the
  same as before (checked with a `$fatal` comparison against a `cpu_fall`
  copy); the I/O wait state is unchanged.
- **Commands:** MEMW/IOW at the falling edge in T2 are the 8288's advanced
  commands AMWC/AIOWC, which is what the 5160 uses (IBM wires AMWC/AIOWC to
  -MEMW/-IOW; KFPC-XT, built from the 5160 logic, the same; MartyPC asserts
  AMWC/AIOWC from T2, MWTC/IOWC from T3, and its raw trace shows `I:.A.` from
  T2). They stay; a card now sees MEMW 12 clk and MEMR 33 clk before the
  sample that decides T3. MEMR/IOR/INTA start one CPU clock before MartyPC's
  MRDC/IORC (in T1, not T2): kept and documented as an open point.
- **CGA:** IOCHRDY goes high 2 ticks before the CPU slot (lchar phase 12,
  `LEAD + 7` ticks after the strobe), the access (write, snow capture) stays
  at the slot (phase 14), inside the strobe. `RD_LEAD`/`WR_LEAD` unchanged.
  The write fallback (`acc_abort`) is gone; a `$fatal` guards against a
  strobe that ends before the slot, except when AEN cuts the CPU's command
  for a refresh while the CPU waits (HOLDA in T3/Tw): the card drops the
  access and restarts it when the strobe returns (found in the first system
  run: the assertion stopped GLaBIOS at its third CGA write).
- **MDA:** the card is unchanged except that its fallback (`wr_early`) is
  gone (same `$fatal` and AEN exception). With the new sample: VRAM reads 1-3
  wait states (mean 1.89), writes 2-4 (2.97), 6845 writes 2-4, 6845 reads
  after the 3B4 write 1-2; every write lands in the slot. GLaBIOS's banner on
  the MDA in `tb/sys` (`make MDA=1`, 1.0 s) without the fallback.
- **tb/cga:** the board model samples on `rdy_ce` and decides T3/Tw as biu88
  does. `waits` now also adds random gaps until every phase has 8 reads and
  8 writes (416 accesses): all equal; the old card on the new board: 370 of
  544 differ (one wait too many at 11 phases). Mutants 25 -> 27 (release
  phase and lead), all killed.
- **tb/mda:** board model as tb/cga's; `waits` expectations from the new
  sampling (above; the old ones encoded "writes never wait"); the model
  counts lost writes and every test requires none. Mutant "no write after an
  early strobe end" dropped: 34, all killed.
- **In-system oracle:** `sys_run -C [max]` checks every CPU memory cycle in
  B8000-BFFFF against MartyPC's count, `WAIT_TABLE[(dc + 1) & 15]` ticks
  rounded up to clocks with `dc` the card's phase at the end of T2; cycles
  stretched by a DMA wait are counted apart; exit code 3 on a mismatch.
  `tb/sys/cgawait_rom.py` makes a test ROM (no BIOS) with byte/word moves,
  REP MOVSB, LODSB/STOSB and pseudo-random delays, so reads and writes meet
  all 16 phases.

  | Build | GLaBIOS writes (1.0-1.27 s) | test ROM reads | test ROM writes |
  |---|---|---|---|
  | main 7437964 | 14,639 of 14,639 differ (0 Tw) | 2,026 of 2,026 differ | 2,025 of 2,025 differ (0 Tw) |
  | new board, old CGA | 9,580 of 13,175 differ | 1,446 of 1,989 | 1,523 of 1,989 |
  | this branch | 0 of 13,335 | 0 of 2,001 | 0 of 2,001 |

  GLaBIOS 0.4.2 reads no CGA memory in its first 4 s (fedora run: 13,371
  writes, all equal, 3,342 DMA-stretched); the reads were checked with the
  test ROM. The DMA-stretched cycles are not compared (MartyPC's refresh and
  the CGA's restart would need a model of their own).
- **Gates:** MartyPC trace (`DRQ0_SKEW=7`, 1.27 s): first difference at
  reference clock 1,041,809 before the merge of main 93831be (cpu-y), as on
  main 7437964, and at 2,439,285 after it, as on main 93831be; no `$fatal`.
  The `-C` oracle in the same runs: 13,335 / 13,313 CGA writes, all equal.
  tb/cga PASS, tb/mda PASS (MDA and Hercules), tb/fdc PASS (208 checks),
  tb/hdc PASS (3,184 checks). Merged with main: the I/O wait's DMA sample
  (`dma_rdy_sync`) is taken on `rdy_ce` too (the same value).
- **Floppy boot** (`sys_run -a hello360.img -s 10`, fedora): fails, and
  already on main. A run of each first-parent commit since the first floppy
  boot: 8c0461f to 22f9853 boot ("Booted from floppy A:"), 387e87e (refresh
  DMA against MartyPC), 14edb29 and b327eaf end with an empty screen, main
  7437964 with "POST Error 1000 FDC", main 93831be with "POST Error 0800
  FDD" (seek test), this branch before the merge the same, after it "FDD
  [ 0 ]" with POST still running at 10 s (its CGA writes now wait). Not
  caused by the READY rework; open (it starts with the refresh DMA work).

## 2026-10-22 - Floppy boot: a CPU command never continues a DMA strobe (branch `fdboot`)

- **Cause** (traces of 22f9853, 387e87e and main 531f5e2 with
  `sys_run -a hello360.img`, a new FDC event log `-f` and a clk-level dump
  of the board): since 387e87e AEN falls in the clk in which the 8237 ends
  its strobes (`aen_next = hold_ack && hold_request_next`, S4), where it
  used to fall one CPU clock later. A CPU command that the DMA held (the
  cycle met the refresh in T1) is released in that same clk, so the bus
  strobe of that kind stays low across both owners: the refresh (a read
  transfer: MEMR + IOW) ran straight into the CPU's MEMR or IOW. Cards that
  decode at the strobe's falling edge saw one DMA strobe.
  - The RAM had this first: the board's RAM request came at the strobe's
    falling edge, so a CPU read held by a refresh got the previous read's
    byte (7437964's finding). At 387e87e (128 KB and 640 KB runs) an early
    POST memory check (MEM_CHECK) fails and GLaBIOS halt-beeps from ~150 ms
    on: the empty screen of the bisect (14edb29, b327eaf the same there).
    7437964 fixed it for the RAM only (RAM requests per bus owner).
  - The FDC (`fdc_card`: "decode at the strobe's start, act at its end")
    drops the CPU's write. Main, step 10,711,241 (128 KB run): `OUT 3F2,08`
    (INT 13h reset, F000:ECB5) meets the refresh in T1, the refresh's IOW
    starts at step +4 with AEN high, AEN falls at +6 in the clk where the
    8237's IOW ends and the CPU's IOW begins; IOW stays low, the card's DOR
    cycle flag stays 0, no DOR write. The FDC log of 22f9853 shows `DOR 08`,
    `DOR 0C`, IRQ6; main shows only `DOR 0C`, the 765 is never reset, IRQ6
    (edge-triggered, high since the first reset at 521 ms) gives no new
    interrupt, FDC_WAIT_INT times out (POST Error 1000 FDC at 7437964; later
    timing moved the loss to the seek test's command bytes or let the
    reset's retry fail too: 0800 FDD, "FDD [ 0 ]"). Main's 640 KB run loses
    both resets (6,836 and 8,825 ms).
  - Neither the 8253 change nor the FDC's DMA: main never reached a DACK2
    cycle, and the fix leaves the 8253 as it is.
- **Fix** (`xt_board.sv`): the CPU's commands come back one clk after AEN
  falls (`cmd_en = !aen && !aen_d`; the next-strobe outputs for registered
  card decodes follow). The 8288 enables its commands well after AEN on the
  5160 (tAELCV); one clk is enough for the cards and leaves every CPU-clock
  edge (AEN, the DMA wait, READY, the trace) as it was. doc/architecture.md
  section 3 states the rule.
- **Regression check:** a `$fatal` in `xt_board` when a bus strobe changes
  owner while low. The old enable (`!aen` alone) with the check stops tb/sys
  before 50 ms (the first refresh that holds a CPU command), so every tb/sys
  run guards it, the 1.27 s trace gate included.
- **Gates** (fedora):
  - floppy boot, `sys_run -a hello360.img -s 10 -C 40`: FDC reset at
    6,836 ms (`DOR 08`, `DOR 0C`, IRQ6, sense interrupt), C0 H0 S1 and S2 by
    DMA at 9,405 ms, "Booted from floppy A: (pc10-iii FDC+DMA)" (22f9853:
    reset at 6,814 ms, sectors at 9,423 ms); the `-C` oracle there: 134 CGA
    reads and 14,135 writes, 0 differ (3,622 DMA-stretched);
  - MartyPC trace (`make DRQ0_SKEW=7`, `-s 1.27 -q -C 40 -t`,
    `tools/ctrace_diff.py` against the 6M-clock reference): first difference
    at reference clock 2,439,285, as on main; the `-C` oracle in that run
    13,313 CGA writes, 0 differ (3,348 DMA-stretched, not compared);
  - tb/fdc PASS (208 checks), tb/hdc PASS (3,184 checks), tb/cga PASS,
    tb/mda PASS (MDA and Hercules).
- Not built yet: `cmd_en` adds one register input in front of the four CPU
  strobes (the bitstream's timing to be checked with the next build).

## 2026-10-22 - Evaluation: z8086's EU (Intel's microcode) in front of biu88 (branch `z8086-eval`, not merged)

- **What:** nand2mario's z8086 (Apache 2.0, commit 596d9a6) runs the 8086's own
  microcode (Jenner's extraction) on a rebuilt micro-architecture. Its EU,
  cut loose from its bus and 6-byte queue (`rtl/cpu/z8086/z86_eu.sv`), runs
  one microinstruction per 8088 clock (a clock enable 3 clk after biu88's
  step) in front of biu88, unchanged, through an adapter that issues MCL86
  commands (`cpu_z86.sv`). `make CPU=z86` in tb/sst; the ROM image stays
  outside the repository (rule 4, `Z86_UCODE`). Full write-up:
  `doc/z8086-eval.md`.
- **Structural fixes** (none instruction-specific; the rules are Jenner's,
  from his microcode-level 8088 emulator XTCE): NX also in type 4 (STU 5 and
  WB,NX); W,RNI takes effect when the write is done; RNI/NX suppression for a
  memory destination from the microcode (a move to M in memory) instead of
  z8086's opcode table (CMP r/m wrote its operand back, POP r/m ended before
  its write); SUSP waits for a running fetch, CORR for the idle bus; the EU
  resumes a clock after biu88's done for writes and SUSP. ALU: DAA/DAS
  compare with 9Fh when AF is set; byte NEG of a memory operand took CF from
  16 bits.
- **Runs** (`~/pcxt-work/results/`): z86-a state 3,006,849 (99.99%), trace
  2,956,172 (98.31%); z86-b (ALU fixes) state 3,007,000 (100.00%), trace 2,956,172 (98.31%).
  Main (y5): 3,007,000 / 3,006,693. Of z86-b's trace failures, 50,521 go
  through the interrupt routine (INT 3, INT n, INTO taken, divide errors of
  DIV/IDIV/AAM), which is the 8086's in z8086 and differs in the 8088 (Jenner);
  the other 307 are C6, the same tests MCL86 fails (biu88). Everything else,
  MUL/DIV, REP strings, shifts by CL, far control transfers included, is
  exact on every cycle.
- **Size** (OOC, xc7a200t-2): z86_eu 1,541 LUTs, 534 FFs, 0.5 BRAM tile,
  ~97 MHz single-cycle; with biu88 4,324 LUTs, 2,333 FFs (main's MCL86 +
  biu88: 3,126 LUTs, 8 BRAM tiles).
- **Recommendation:** adopt Intel-microcode-at-one-per-clock as the faithful
  EU's base. Open: the 8088 ROM (interrupt routine), the rule 4 decision, a
  native EU/BIU interface for biu88 (then no 100 MHz), INTR/NMI/LOCK/HLT/WAIT,
  tb/sys.

## 2026-10-22 - z8086 is the 8088, Intel's microcode from the SD card (branch `z86`, phase A)

- **CPU:** `cpu8088` (`CPU = "z86"`, the default) is z8086's EU running Intel's
  8088 microcode, one microinstruction per 8088 clock, in front of biu88 (the
  evaluation's adapter, doc/z8086.md). MCL86 stays selectable (`CPU = "mcl86"`,
  `make CPU=mcl86` in tb/sys and tb/sst).
- **Rule 4:** the four Intel tables (microcode, its address decoder, the
  translation ROM, the group decode ROM) are RAMs (`z86_tables.sv`) without
  initial contents, filled from the microcode bundle; z8086's `group_decode`,
  `translate` and `uaddr_pack` logic is gone and upstream `z8086.sv` was
  removed. `tools/mkucode.py` builds the bundle (6144 bytes, magic
  `PC10UCOD`, checksum; format in the tool and doc/z8086.md) from the user's
  copy of Jenner's public `8086_microcode_v2.zip`, decoding the bit images
  as XTCE does; the tool has no table data. Checked: the 8086 images give
  z8086's `ucode.hex` word for word, the decoded decoder/translation/group
  tables equal z8086's functions entry for entry.
- **Finding: the archive has the 8088 ROM** (`l0.txt`..`r3.txt`,
  `translation_8088.txt`; XTCE loads them for the 8088), which the evaluation
  had missed. It differs from the 8086's in 11 words (interrupt routines) and
  in the INTR translation entry. The default bundle is the genuine 8088 one
  (flag bit 0: the overlay is off).
- **SD card:** `/pc10/ucode.bin`, a mandatory auto-load ROM next to the BIOS
  (`C_DEV_PC_UCODE` 0x0104, `pc_ucode.vhd`: 8 KB image, read back by the
  firmware's `UCODE_START` for its checks (size, magic, version, size field,
  checksum), then copied into the CPU through `pc_system`'s new `ucl_*` port;
  the PC stays in reset until then). Missing: the Shell's file-not-found
  screen; invalid: "/pc10/ucode.bin is not a valid 8088 microcode bundle
  (tools/mkucode.py)". Simulation: `~/pcxt-work/ucode/8088.bin`
  (`$PC10_UCODE`, `make Z86_UCODE=`), checked like the firmware
  (`tb/common/ucode_file.h`) and streamed through the same port. tb/shell
  checks `pc_ucode.vhd` (readback, the copy, the gate, forget). Firmware:
  31,991 of 32,768 words.
- **The 8088 interrupt overlay** (`z86_overlay.svh`, for an 8086 bundle): our
  own words for 9 rows plus the INTR translation entry, written from Jenner's
  description, MartyPC's sequences and the SST traces before looking at the
  8088 words (derivation in doc/z8086.md section 5). The INTA "word" is
  {2nd cycle, 1st cycle} with the genuine ROM (it takes the vector from the
  high byte); with the overlay biu88 delivers the vector in the low byte, as
  the 8086's own second INTA access does (`INTA_VEC_LO`).
- **Pins:** INTR, NMI and TEST sampled at the 8088 clock edge; NMI on a
  rising edge; INTR when IF is set and was set at the start of the
  instruction (one instruction after STI/POPF/IRET); single step on TF at the
  instruction's start; none after a prefix or a segment register load; the
  INT and TEST jump conditions (z8086 never took them: no interrupt in a REP
  string, WAIT); HLT waits for an interrupt (the halt bus cycle needs biu88's
  native interface: phase B); LOCK from the prefix to the start of the
  instruction after the locked one (z8086 took F0 for REP). An FC with an
  interrupt no longer waits for a queue byte.
- **EU fixes found on the way:** a REP prefix whose SC came in the clock of
  the previous instruction's RNI (NX overlap) was lost (z8086 cleared F1 at
  RNI; now at the SC after a non-prefix instruction, as XTCE): REPE SCASW ran
  as one SCASW in GLaBIOS's memory test. The SST suite never has that
  overlap.
- **Timing:** every EU register changes only at its clock enable (the bus
  tracking moved into `cpu_z86.sv`), so `cpu8088.xdc` gives EU -> EU paths 2
  clocks. Out of context (`rooc.sh z86b-a`, 100.2273 MHz, R6 part): WNS
  +0.492 ns, WHS +0.071 ns; 4,702 LUTs, 2,444 FFs, 1.5 BRAM tiles (the CPU
  with its tables; MCL86 + biu88 was 3,126 LUTs and 8 tiles).
- **Gates:**
  - SST, full suite (`z86d-88`, genuine 8088 bundle): state 3,007,000
    (100.00%), trace 3,006,693 (99.99%), only C6 (307, biu88's known case);
    no file worse than y5. With the 8086 bundle + overlay (`z86c-86`, before
    the F1 fix): the same numbers. Before the change the evaluation had
    2,956,172 (98.31%); CC, CD, CE, F6.6, F6.7, F7.6, F7.7, D4 now 100%.
  - Floppy boot (`sys_run -a hello360.img -s 10 -C 40`): FDC reset, C0 H0
    S1/S2 at 9,005 ms, "Booted from floppy A: (pc10-iii FDC+DMA)"; the CGA
    oracle 134 reads and 14,147 writes, 0 differ.
  - MartyPC trace (`DRQ0_SKEW=7`, 1.27 s): first difference at reference
    clock **2,227,925**: a LOOP that is not taken. MartyPC takes 6 clocks from
    the opcode to the next opcode, the 8088's microcode 5 (140 DEC, 141 to
    CX, 142 the displacement and the not-taken long jump, 143 RNI; Intel's
    table: 17 taken / 5 not taken); MartyPC's `mc_140` runs a cycle for 143
    and then its fetch cycle, which is 143 itself. The suite has no LOOP
    with CX = 1. With that cycle removed from MartyPC
    (`~/pcxt-work/scratch/z86b/marty_loopfix.py`, reference
    `GLABIOS_0.4.2_8X-6000000-loopfix`, identical to the original up to
    2,227,926), the first difference is at **2,439,294**, after MCL86's
    2,439,285: OR AL,DL and TEST AL,2 now come on time (the EU lateness is
    gone). There an IN 62h (the SW1 switches) reads 06 against MartyPC's 0E:
    tb/sys's default SW1 (0x6D, two drives) is not MartyPC's machine (no
    floppy drives). With MartyPC's switches (`-d EE`, IN 62h then reads 0E
    as MartyPC) the first difference is at 2,439,417: a read of 0:03FA
    returns FF against MartyPC's 00 (memory left by the BIOS's earlier
    tests, not the CPU's timing). The `-C` oracle in the 0x6D run: 13,305 CGA
    writes, 0 differ.
  - tb/cga PASS, tb/mda PASS, tb/fdc PASS (208 checks), tb/hdc PASS (3,184
    checks); tb/shell PASS.

## 2026-10-22 - biu88 with the real chip's EU/BIU interface (branch `z86`, phase B)

- **biu88** (`rtl/cpu/biu88.sv`, new): MartyPC's BIU model (the one the MCL86
  biu88 carried: T-states, address cycle, fetch policy, request phases, the
  abort, word transfers as byte cycles), stepped once per 8088 clock and
  changing state only at `step`. The EU's events of its last clock (queue
  read, request, FLUSH, SUSP, HALT; LOCK) are taken at the next step before
  the cycle, as MartyPC runs EU actions between cycles; the EU reads the
  queue head, its IP, the T-state, `done`/`done_imm` and the read data, all
  registers set at the step. The MCL86 command layer, end counters,
  releases, scheduled reads, taken bytes, the cycle counters and the
  per-core-clock fast part with its six candidate states are gone; the old
  BIU stays with MCL86 as `biu88_mcl` (`rtl/cpu/mcl86/biu88.v`) until MCL86
  is removed.
- **EU:** the done tracking that the adapter did per core clock is the
  EU's own (`bus_busy`, the XTCE resume rule from `done`/`done_imm`); the
  segment registers are read by biu88 instead of mirrored; `cpu_z86.sv` is
  tables + EU + biu88, no adapter.
- **New in biu88:** the halt bus cycle (MartyPC's `biu_halt`: fetching stops,
  the running cycle finishes, one Ti, then status 011 in a T1 with ALE, then
  passive); the INTA "word" as {2nd, 1st} for the genuine 8088 microcode (the
  overlay gets the vector in the low byte); the reset jump to FFFF:0000 as a
  flush in the EU's first clock, as the adapter did. Not compared with a
  trace: HLT (not in the suite, GLaBIOS does not halt in the traced time).
- **Timing:** `cpu8088.xdc`: every EU or biu88 register to every EU or biu88
  register is a 3-clock path (biu88 -> EU is EU_DELAY = 3 clk, the others at
  least 18). Out of context (`rooc.sh z86b-b`, 100.2273 MHz): WNS +2.800 ns
  (was +0.492), WHS +0.112 ns; the CPU is 2,749 LUTs (biu88 483, EU 1,479,
  tables 766 of which 576 LUTRAM), 793 FFs, 1.5 BRAM tiles (phase A: 4,702
  LUTs, 2,444 FFs; biu88_mcl alone was 2,820 LUTs). The longest paths in
  clocks: EU -> EU 18.1 ns, EU -> biu88 18.1 ns, biu88 -> biu88 17.7 ns,
  biu88 -> EU 11.1 ns, i.e. single-cycle at 28.636 MHz (34.9 ns).
- **Gates** (the same as phase A, unchanged numbers):
  - SST full (`z86e-88`): state 3,007,000 (100.00%), trace 3,006,693
    (99.99%), C6 only (307); no file worse than phase A (`z86d-88`) or y5.
    8086 bundle + overlay (`z86e-86`): the same.
  - Floppy boot: C0 H0 S1/S2 at 9,005 ms, "Booted from floppy A:", the CGA
    oracle 134 reads and 14,147 writes, 0 differ.
  - MartyPC trace: first difference 2,227,925 (MartyPC's LOOP); with the
    LOOP-fixed reference 2,439,294 (SW1 0x6D) and 2,439,417 with MartyPC's
    switches (`-d EE`), as phase A; the `-C` oracle 13,305 writes, 0 differ.
  - tb/cga, tb/mda, tb/fdc (208 checks), tb/hdc (3,184 checks) PASS.

## 2026-10-22 - MCL86 removed (branch `z86`)

- `rtl/cpu/mcl86/` (MCL86's EU, its microcode listing and image, biu88_mcl,
  biu_max), `tb/sst/tb_mcl86*.v`, the microcode tools (`mcasm.py`,
  `mcset.py`, `gen_ea_modes.py`, `gen_strings.py`, `gen_muldiv.py`) and the
  `CPU` parameter of `cpu8088`/`pc_system` are gone; the project, the OOC
  script and the build gate (the MCL86 microcode image) with them. MCL86
  reached 99.99% of the suite's traces after two days of per-instruction
  timing (the entries above); the z86 CPU reaches the same with Intel's
  microcode and no instruction-specific timing. doc/cpu-timing.md is kept as
  history.
- Gates after the removal (`z86f-88`, gates `f`): SST state 3,007,000
  (100.00%), trace 3,006,693 (99.99%, C6 only), no file worse than y5;
  floppy boot ("Booted from floppy A:", sectors at 9,005 ms, the CGA oracle
  134 reads / 14,147 writes, 0 differ); MartyPC trace 2,227,925 (2,439,294
  against the LOOP-fixed reference, 2,439,417 with `-d EE`); tb/cga, tb/mda,
  tb/fdc, tb/hdc, tb/shell PASS. The floppy boot with the 8086 bundle and the
  overlay (hardware IRQs through rows 0x19A-0x19D) boots the same way, with
  the same oracle numbers.

## 2026-10-22 - Clock plan: the PC on 28.63636 MHz (phase C, assessment only)

- doc/clock-plan.md: what it takes to run the whole PC on the PC10-III's
  master clock instead of 100.2273 MHz. The FE2010A (no datasheet found;
  Sergey Kiselev's reverse-engineered notes for the Micro 8088) makes 4.77,
  7.15 and 9.54 MHz from a 28.63636 MHz crystal (XSEL), 9.54 MHz with a 50%
  duty cycle; the PC10-III's 9.54 MHz needs that crystal, so its master clock
  is 28.63636 MHz = 2 x OSC (not verified on a PC10-III board). The MMCM
  already makes it (M2M's video clock, VCO 1102.5 / 38.5; 100 x 31.5 / 5 / 22
  is equivalent).
- Every constant in clk units is listed with its value at 28.6 MHz:
  `pc_clocks` (84/21/7 -> 24/6,4,3/2), `xt_board` (`cmd_en`, DRQ0_SKEW, the
  RAM answer, the keyboard delays in CPU clocks), the CPU (`EU_DELAY` 1, the
  multicycle constraints go: the longest EU/biu88 paths are 18 ns), CGA
  (`CE_DELAY`), MDA (`DOT_INC/DOT_MOD`), FDC/XTIDE (`US_NUM/US_DEN` 11/315),
  `pc_ram` (6-clk latency must shrink for 9.54 MHz), the video crossing in
  `main.vhd` (gone), the duty cycles (1/3 at /6; /4 undocumented; /3 at 50%
  is off the clock grid) and the turbo switch. Not implemented.

## 2026-10-23 - The PC on the PC10-III's 28.63636 MHz master clock (branch `clk28`)

- **What:** the whole PC side runs on one 28.63636 MHz clock (2 x OSC, the
  FE2010A's crystal; MMCM VCO 1102.5 MHz / 38.5 as before), also M2M's video
  clock; no 100 MHz clock any more. Plan and what was done beyond it:
  doc/clock-plan.md (section 6, marked done); doc/architecture.md section 1,
  doc/timing.md section 5.
- **Enables** (`pc_clocks.sv`): a modulo-24 counter and the CPU clock's own
  modulo-6 counter: `ce_14m` /2, `cpu_step` /6 (CLK high 2, low 4: the 8284's
  1/3), `cpu_fall` step + 2, `rdy_ce` step - 1, new `cpu_prestep` (the clk
  before the step), PCLK /24. The FE2010A's /4 and /3 only need another
  period of the CPU counter (not done).
- **CPU:** `EU_DELAY` 1; `rtl/cpu/cpu8088.xdc` deleted (and from the R6
  project, `tools/gen_xpr.py`). No other change in `rtl/cpu` (comments).
- **The order within an OSC tick.** At 100 MHz a tick had 7 clk and some
  registered follow-ups of a CPU edge happened 1-2 clk later, still before
  the next tick; at 2 clk per tick they would come a tick (or, DRQ0, a CPU
  clock) late. Moved to the edge itself:
  - the 8288 commands end at the edge where T4 begins (`cyc_end`, from a
    mirror of biu88's "this T3/Tw is the last" flag; `$fatal` check);
  - the 8237 ends its strobes one clk before the edge that ends S4
    (`cpu_prestep` into KF8237) and the CPU's commands return with AEN
    (`aen_d` gone); the memory keeps driving a DMA read's data in that clk
    (`dma_mem_src`: without it the trace's data column in 5,456 DMA-held
    write cycles showed 00 instead of the RAM byte);
  - the 8237's DREQ register takes DRQ0's D input;
  - CGA: `CE_DELAY` 1; I/O acts in the strobe's last clk (three new
    next-clk inputs; `$fatal` check against the old end); an access counts the
    tick it starts in; the 80-column clock switch takes a pending text/graphics
    mode in the post clk (tb/cga torture found it: the CRTC timeline drifted,
    3DA and light pen reads differed); the composite VSYNC shift one clk
    earlier; the dots are computed 3 ticks late from a delay line of the dot
    logic's inputs and a copy of the fetched character (the fetch takes 5 clk).
- **Real time:** FDC and XTIDE 1 us = 11/315 clk; the XTIDE's IDENTIFY keeps
  CMD_US from the command (it was reloaded after the 512-clk sector write:
  23 us at 28.6 MHz). MDA 59609/105000 (16.257 MHz), Hercules 352/630: a dot
  is 1.76 clk, and a falling dot edge after the rising one in the same clk
  was lost (tb/mda: 741 of 742 lines short, waits wrong); now taken in the
  next clk (`fall_pend`, card and model).
- **CORE:** `clk.vhd` one output (`main_clk` = `video_clk`); `main.vhd`
  registers RGBI, syncs, blanks and `vid_ce` together (no crossing);
  `pc_ram.vhd` latency 2 (request register, the banks, a multiplexer);
  CORE.xdc: one clock, QNICE <-> main 20 ns as before, no geometry
  multicycle, no `FORCE_MAX_FANOUT`; the stand-in pc_system's constants.
- **Testbenches:** tb/sys `CLK_HZ`; tb/sst 6 clk per CPU clock (integer, `-P`
  in clk); tb/cga and tb/mda board models at 2/6 clk with the T4 end (tb/cga
  also the next-clk values, `LAT` 6); tb/fdc and tb/hdc bus cycles in units of
  `C` = 6; tb/shell clock period, RAM latency 2, copy waits. Mutant lists
  updated (CGA: `CE_DELAY` 2, I/O end late, access tick lost, display delay 2).
- **Gates** (fedora, gates `c4`; main = c49a1fc exported, gates `base0`):
  - MartyPC trace (`DRQ0_SKEW=7`, `-s 1.27 -C 40`): **byte-identical to
    main's** (SHA-256 a72753ca...; both `-t` traces compared whole, not just
    their first difference); against MartyPC therefore the same first
    differences, 2,227,925 (`cycles.txt`) and 2,439,294 (`-loopfix`). The
    `-d EE` trace is byte-identical too (bd612823..., 2,227,925 / 2,439,417),
    and so is the trace with the shell's RAM latency (`-L 2`). The `-C` oracle
    13,305 writes, 0 differ.
  - Floppy boot (`-a hello360.img -s 10 -C 40`): C0 H0 S1/S2 at 9,005.376 ms,
    "Booted from floppy A: (pc10-iii FDC+DMA)"; the oracle 134 reads, 14,147
    writes, 0 differ. The whole log equals main's but for one line: the
    second sector request at 9,005.394 ms instead of 9,005.381 (tb/sys's
    image backend sends a byte per clk, so 512 bytes take 18 us instead of
    5 us; the CS:IP samples every 50 ms, the boot and the oracle are the
    same).
  - SST full (`clk28-a`): state 3,007,000, trace 3,006,693, every file's line
    identical to `z86f-88` (main).
  - tb/cga PASS; tb/mda PASS (MDA and Hercules; the 6845 read right after a
    3B4 write now 1-3 wait states, 3 in 1%: the dot edges are on a 35 ns
    grid and RDY is sampled 35 ns before the edge; doc/mda.md 4.2); tb/fdc
    PASS (208 checks); tb/hdc PASS (3,182 checks: the random traffic draws
    per clk, so its count moves); tb/shell PASS. Mutants: tb/cga 29 of 29
    killed, tb/mda 34 of 34, tb/hdc 20 of 20.
- **Simulation speed** (the 1.27 s trace run alone on fedora): 322.0 s before,
  95.3-97.9 s after (3.3x); the full SST run took about 3 minutes; the floppy
  boot run (10 s, in parallel with the other gates) 2,494 s before, 741 s
  after.
- **Out of context** (`tools/ooc/rooc.sh --pc clk28-pc`, `pc_ooc.tcl`:
  pc_system with CGA, Hercules, FDC and XTIDE, pc_ram, the ROMs as block RAM;
  R6 part, 34.921 ns, no exceptions): **WNS +15.498 ns**, WHS +0.070 ns, 0
  failing endpoints; 8,690 LUTs, 4,284 FFs, 206 BRAM tiles. Worst path:
  biu88 `qlen` -> `address_latch` CE, 19 levels, 19.0 ns.

## 2026-10-25 - Drive LED and drive sound (branch `drvsnd`)

- **Drive LED** (`CORE/vhdl/pc_drvsnd.vhd`): yellow (`FFFF00`, Megamiga's
  floppy colour) while drive A: or B: is selected = the DOR selects it and its
  motor bit is set, the select line that lights a PC10-III drive's LED (so it
  stays on during the BIOS's motor run-on and is off while only the other
  drive's motor runs). Before: green while a motor ran or the FDC executed,
  yellow while a block moved to/from the SD card. Power LED unchanged.
- **Drive sound**, Megamiga 0.7's "Virtual Drive Sound" with its disk guard
  (90f1e9b) ported: the MEGA65's internal drive runs its motor while A:'s or
  B:'s motor bit is set and takes one step per cylinder the selected drive's
  head moves (one per 765 step pulse; the 765's pulses past the 40-track
  drive's stop, e.g. the BIOS's seek to 50, move nothing there and give no
  step here, so the real head stays with the emulated one). The real head is
  followed in 0..79 (no step past 79, none out at 0 or at TRK0, resync to 0 at
  TRK0 only after an outward step); new against Megamiga: the head is homed
  (6 ms steps to TRK0, at most 85) before the first step, because its
  position after power-up is unknown, and a step leaves only after the 36 us
  settle time, so the guard has read /DSKCHG first. Guard: /DSKCHG high while
  selected = a real disk: no motor, no steps, a 286 us probe every 0.586 s.
  Pulses 8 us direction setup, 8 us low, 8 us hold. Constants recomputed for
  28.63636 MHz (doc/m2m-shell.md section 4). Write gate/data, side, density
  inactive.
- **FDC exports** (`fdc_card.sv`, through `pc_system`, `pc_system_flat`,
  `main.vhd`, the stub, tb/sys, the OOC top): `drv_select[1:0]`, `drv_step`,
  `drv_step_in` (registered, nothing else in the card changed).
- **Menu:** `Drive sound (int. drive)` at line 6 (default on; Megamiga's
  "Noclick" does not apply to a PC: no select without the motor); the menu is
  32 lines, every C_MENU_* from 6 on moved by one, OPTM_DY 18, menu heap
  demand 663 of 1024. **Settings file:** the Shell would load a 31-byte
  `/pc10/pc10cfg` as a file from a menu that grew at its end, shifting every
  option from line 6; `CFG_SIGCHECK` now requires the text line `menu=2`
  (`CFG_SIG_VAL`, the layout version), otherwise the defaults are used and
  `CFG_SIGSET` adds the signature at the next save. Firmware ROM 32037 of
  32768 words (31991 before), RAM layout unchanged.
- **Tests:** `tb/shell/tb_drvsnd.vhd` (ghdl, a drive model with stops, a late
  TRK0 and the change latch) PASS; `tb/shell/run_cfgsig.sh` (the two firmware
  callbacks with M2M's cfgstr.asm on the QNICE emulator's batch mode) PASS;
  `tb/shell/mut.py`: pc_drvsnd 27 of 27 mutants killed, firmware 5 of 5;
  `tb/shell/run.sh` PASS. tb/fdc follows the heads from the exports: 232
  checks (208 before), PASS, including DOR -> `drv_select` for 9 values, the
  seek to 50 on the 40-track A: (41 steps, the recalibrate 41 back) and no
  steps with the motor off.
- **Floppy boot gate** (fedora, `sys_run -b GLABIOS_0.4.2_8X.ROM -a
  hello360.img -s 10 -C 40`, `~/pcxt-work/drvsnd/`): this branch and main
  (b94261c) give the same log line for line but the wall time: C0 H0 S1/S2 at
  9,005.376/9,005.394 ms, "Booted from floppy A:", the CGA oracle 134 reads
  and 14,147 writes, 0 differ.
- Not verified: the hardware (the MEGA65 drive's step rate limit, TRK0 delay
  and /DSKCHG behaviour), the firmware's settings-file path beyond the two
  callbacks (the Shell's load/save around them), Vivado (synthesis, timing).

## 2026-10-25 - The chipset as a menu choice: PC10-III (FE2010A) or IBM XT (8255) (branch `chipset`)

- **Why:** the Commodore BIOS 4.41 needs the FE2010A's port logic (b00d54a),
  GLaBIOS (the free default BIOS) selects the switch nibble with PB3 like a
  5160 and stops with "POST Error 0800 FDD" on it. The user chose a menu item.
- **xt_board.sv:** the `FE2010A` parameter is now the input `fe2010a`, taken
  into `fe_mode` while reset is high. Both port logics are always there: the
  KF8255 as before (its chip select gated with !fe_mode, its port C from the
  5160 switch nibble), the FE2010A registers (port B, 62h switch register, 63h
  configuration, written only in FE mode); port B, its drive flag and the read
  data are multiplexed by `fe_mode`, and the 63h RAM size limits `ram_top` only
  in FE mode. pc_system has the input instead of the parameter; tb/sys keeps
  its `FE2010A` parameter (`make FE=1`) and drives the input with it;
  pc_system_flat, main.vhd, the stub and the OOC top pass it through.
- **Shell:** `pc_chipset.vhd`: the menu bit, the switches (5D FE2010A, 6D
  8255) and a restart on a change (the PC held in reset for 2^16 clocks =
  2.3 ms from the clock the menu bit changes, OR-ed into `main_pc_reset`). The
  memory size, by contrast, acts at once (`pc_ram.vhd`), so there was no
  restart path to reuse.
- **Menu:** submenu `Chipset: %s` at line 8 (headline, `PC10-III (FE2010A)`
  default at 11, `IBM XT (8255)` at 12, back at 14), behind the drive sound;
  39 lines, every C_MENU_* from Memory on moved by 7, OPTM_DY 19, menu heap
  demand 806 of 1024. Settings signature `menu=3` (old files get the
  defaults once). Firmware ROM 32037 words (unchanged), RAM unchanged.
- **Tests:** `tb/shell/tb_chipset.vhd` PASS; `tb/shell/mut.py`: pc_chipset 7
  of 7, pc_drvsnd 27 of 27, firmware 5 of 5 killed; `tb/shell/run.sh` PASS.
- **Gates** (fedora, `gates.sh chipset` and `chipset-base` = main 00a51da
  exported, `~/pcxt-work/clk/chipset*`): 8255 mode (tb/sys default):
  - MartyPC trace (`DRQ0_SKEW=7`, `-s 1.27 -q -C 40 -t`): SHA-256 a72753ca...
    on both (unchanged since clk28), first difference 2,227,925 (MartyPC's
    LOOP); `-d EE` bd612823... and `-L 2` a72753ca... on both;
  - floppy boot (GLaBIOS, `-a hello360.img -s 10 -C 40`): the log identical to
    main's but the wall time (C0 H0 S1/S2 at 9,005.376/9,005.394 ms, "Booted
    from floppy A:", the CGA oracle 134 reads / 14,147 writes, 0 differ);
  - tb/fdc 232 checks, tb/hdc 3,182 checks, tb/cga, tb/mda, tb/shell PASS.
- **FE2010A mode** (`make FE=1`, the Commodore BIOS 4.41,
  `-s 24 -a hello360.img -d 5D`, `~/pcxt-work/chipset/cbm-fe`): the banner,
  "Hard disk not found", no timer or keyboard error, "System RAM 256 KBytes
  OK" at 24 s (the RAM test still running); the log (CS:IP every 50 ms over
  24 s, POST codes, the screen) is identical to the run of main's code in
  `~/pcxt-work/scratch/cbm/fe2_cbm.log` but for that run's extra screenshot
  at 18 s.
- The same at 50 s (`~/pcxt-work/chipset/cbm-fe45`, 3,489 s wall): "System
  RAM 640 KBytes OK", the boot sector read (C0 H0 S1/S2) at 38,205.376 ms
  and "Booted from floppy A: (pc10-iii FDC+DMA)"; the PC sits in the boot
  sector's loop (0000:7C1D) from 39.9 s on. Not verified: the menu, the
  restart and the settings file in the real shell (no Vivado, no hardware);
  GLaBIOS with 6D on the 8255 is covered by tb/sys only.

## 2026-10-25 - The PC10-III's onboard video: Paradise PVC4 (branch `pvc4`)

- **What:** the PC10-III has no IBM CGA or MDA; its video is the Paradise
  PVC4 on the main board ("video card on a chip": CGA, MDA, Hercules,
  Plantronics ColorPlus, AT&T 6300; "flicker-free operation in all video
  modes"). doc/pvc4.md is the chip as a specification (data sheet, the
  PC10-III manual's chapters 2.2, 5, 6 and the video schematic sheet 9-6,
  the Commodore BIOS 4.41 read for its use of the chip), with the
  assumptions marked.
- **Facts found:** the PC10-III straps the PVC4 (sheet 9-6) to Paradise
  register E0h (DIP switch 2 off: mono mapping, 9-dot characters) or 40h
  (switch 2 on: colour), both with the "flicker override" (video enable
  forced on), and Configuration register F7h (one 64K x 8 bank, IBM 200
  lines, border on, printer decode off); CLOCK1 and CLOCK2 are the same
  16.257 MHz oscillator (no 24 MHz: the manual's ALPHA132 at 24 MHz cannot
  run on this sheet); the character ROM is a 27256 with A14 = DIP switch 1
  (national set), A11 = NOT switch 2 (mono/colour), A13 = the PVC4's CA13,
  A12 = character bit 7; the BIOS never writes 3XA/3XB, so the straps decide
  everything; 230h (in the 5720 gate array) reads switch 2 in bit 7, its
  write bit 7 (venb') enables the PVC4's data buffer and READY, bits 6-0 read
  back (the BIOS's handshake). The snow the user saw is the IBM CGA model's:
  the PVC4's DRAM sequence gives the CPU its own memory cycle.
- **Model** (`rtl/video/pvc4/pvc4.sv`): one 6845 (`cga_crtc.sv`; R8 gone,
  R10 on/off only, the lock with R11 as underline row) for a colour
  personality (`cga_card.sv`'s display on ce_14m, without snow) and a mono
  one (`mda_card.sv`'s on a 16.257 MHz accumulator that never stops, /2 in
  40 columns, 8/9-dot characters, Hercules with the PC10-III's own CRTC
  table: 880 x 368); 64 KB in two A14 banks; Plantronics 320x200x16 and
  640x200x4 with the plane swap; 3X8 readable, the unlock, 3DE (CA13), 3BF,
  the PVC4 status bits, border control; a 32 KB character ROM RAM in the
  Commodore layout or an IBM 5788005 image. CPU access: READY low with the
  strobe, high after the CPU part (5 clocks) of the next memory sequence (16
  colour clocks, two mono characters) that saw the synchronised request;
  the sequencer runs on the undivided clock (a first version divided it in
  40 columns and held READY up to 2.2 us, beyond the data sheet's 2000 ns:
  the Commodore BIOS's video RAM probe showed it).
- **230h** (`rtl/system/cbm_cfg230.sv`): the register (reset 00h assumed),
  not the RTC, mouse, COM and LPT it enables.
- **Integration:** `pc_system` `PVC4_FIT` (default 0: unchanged), new ports
  `font_addr_hi`, `font_cbm`, `cbm_dip`, `vid_mono`, `vid_monomode`; an
  unfitted CGA sees no strobes (its write check fired on the PVC4's shorter
  cycles); the IBM cards' fonts take only `font_addr_hi` = 0. Shell:
  `pc_system_flat` = FE2010A + PVC4, no CGA; `main.vhd` generics
  `G_CBM_DIP` ("01": USA set, colour, matching DIP SW1 5Dh) and
  `G_MONO_TINT` (green/amber/white for the mono personality's four levels);
  the stand-in, the OOC top (now with the PVC4), gen_xpr.py and CORE-R6.xpr
  carry the two new files; the default font gained an MDA part (the GLaBIOS
  glyphs stretched to 14 rows; the CGA part byte-identical).
- **tb/pvc4** (`make run`, ~1 min): the board's bus model and a reference
  model built from tb/cga's MartyPC CGA and tb/mda's MDA models plus the
  PVC4's differences; READY at every clk, every VRAM write instant, every
  read and every dot compared. 22 tests PASS (registers and the unlock, wait
  states in four clock modes, BIOS modes 0-6, flicker override, Plantronics,
  no snow, status, torture 4+3 runs, MDA text 9/8-dot, mono /2, Hercules
  pages, the Commodore ROM layout, blink). Wait states: colour reads 1-6
  (mean 3.97), writes 2-7 (5.20); mono reads 1-6 (3.61), writes 2-7 (4.96);
  READY low at most 1502 ns. `mut.py`: 37 of 37 mutants killed (the first
  run left three; the harness then got the write-instant check, the `cbm`
  test the switch-against-mapping cases).
- **System** (`tb/sys`, fedora, `~/pcxt-work/pvc4/`): the Commodore BIOS 4.41
  on the PC10-III build (`make FE=1 PVC4=1`, `sys_run -d 5D [-m] -a
  hello360.img -s 28`): 230h = 00h (onboard video on) and the CRTC tables at
  0.05-0.66 ms, 230h = 81h, the B0/B8:007B probe at 283 ms finds no expansion
  card and writes 230h = 01h (on); colour: the banner ("Commodore PC BIOS
  Rev. 4.41", "Hard disk not found") at 1.5 s, "System RAM ... KBytes OK"
  counting; mono (DIP switch 2 off: Paradise E0h, 16.257 MHz, 9-dot): the
  same on the mono personality (POST 00 at 2.78 s instead of 1.54 s); at
  8.09 s the BIOS writes 230h 00/01/09/19/59 (onboard COM, mouse, RTC
  enables). Frames: `cbm_col.ppm` (768 x 245, RGBI), `cbm_mono.ppm` (738 x
  354, green). The CPU's cycles to the PVC4's memory over the 28 s: colour
  28,093 reads 2-6 Tw (mean 4.33), 68,197 writes 2-7 (5.58); mono 11,609
  writes 2-7 (6.08). No snow (there is none to show: the CPU never takes the
  display's cycle). GLaBIOS 0.4.2 on the IBM board with the PVC4 (`make
  PVC4=1`, 6 s; the FE2010A's switch select is PB2, GLaBIOS's PB3, so
  GLaBIOS reads the wrong switch nibble on `FE=1`): colour and mono banners
  at 1 s, "RAM [ 544 KB OK ]" / "[ 560 KB OK ]" at 6 s; 13,366 / 3,559
  writes, 2-7 Tw (CGA in the same boot: 3-8). `sys_run` gained `-P`
  (CONFIG switches 1-2), 32 KB Commodore fonts with `-F`, `-o` for the PVC4
  frame, the text dump from the PVC4's RAM and the wait histogram.
- **Gates** (fedora `gates.sh pvc4-a`, the default build): the MartyPC trace
  (`DRQ0_SKEW=7`, `-s 1.27 -q -C 40 -t`) SHA-256 a72753ca..., the `-d EE`
  trace bd612823..., the `-L 2` trace a72753ca...: byte-identical; floppy
  boot log line for line equal to `chipset-base`'s (C0 H0 S1 at 9,005.376
  ms, "Booted from floppy A:", oracle 134 reads + 14,147 writes, 0 differ);
  tb/cga, tb/mda, tb/fdc (232 checks), tb/hdc (3,182) PASS; tb/shell PASS
  (locally: the fedora copy has no M2M/QNICE).
- Not verified: hardware, Vivado (synthesis, timing; the PVC4 adds about 24
  RAMB36: 64 KB video RAM, 32 KB character ROM), the CPU access timing of a
  real PVC4 (doc/pvc4.md section 4), ALPHA132, the mono personality on the
  analog output (doc/pvc4.md 8.1), the user's Commodore character ROMs.

## 2026-10-25 - The menu's Display (colour / mono, the phosphor) and 720p 50 Hz

- **What:** the PVC4 merge (2896c09) left DIP switch 2 and the mono tint as
  generics. The menu's "Display: %s" submenu (lines 32-40): Colour (default),
  Monochrome green / amber / white. `pc_chipset.vhd` now also takes the
  display: mono sets CONFIG switch 2 off (`cbm_dip` 11: the PVC4's straps,
  230h bit 7) and switches 3/4 off (DIP SW1 bits 5-4 = 11, 7Dh on both
  chipsets); a change between colour and mono restarts the PC like a chipset
  change (the straps are taken in reset). The phosphor is `main.vhd`'s
  `mono_tint_i` (constant tables per tint, no multiplier) and changes live.
  The HDMI submenu gained 720p 50 Hz (`C_VIDEO_HDMI_16_9_50`) for the mono
  personality's 49.8 Hz. "CGA: thin font" is gone (the PVC4 has no jumper
  P3; `font_thin` tied 0). Menu 48 lines, `MENU_HEAP_SIZE` demand 990 of
  1024, settings signature `menu=4`.
- **Tests:** tb/shell PASS (tb_chipset: mono on both chipsets, the switches
  change with the register, one restart per change); mut.py: pc_chipset 14 of
  14 (5 new mono mutants), pc_drvsnd 27 of 27, signature 5 of 5 killed. ghdl
  analysis of config/main/mega65.vhd clean.
- Not verified: Vivado, hardware.
- **Hardware** (build pc10-real-p = 193e09b, WNS +0.320, WHS +0.036, BRAM 252
  of 365 tiles, was 234): the Commodore BIOS 4.41 in colour without snow, and
  in mono (Display: Monochrome, green) over HDMI, confirmed by the user
  2026-10-25.

## 2026-10-25 - The Commodore character ROM and the character set (CONFIG switch 1)

- **What:** the user pointed to zimmers.net's PC10 firmware; the character
  ROMs 318086-01 (16 KB), -02, -03 (32 KB), an unnumbered 32 KB one and the
  PC10-SD's (kept in `~/pcxt-work/roms/zimmers/pc10/`, never in the repo)
  confirm doc/pvc4.md section 5's wiring: A12 = character bit 7, A10-A4 =
  bits 6-0, A3-A0 = row; the 9x14 mono font where A13 = A11, the 8x8 colour
  font where they differ (CA13 swaps them); A14 = 1 the USA/Europe set
  (slashed zero, cent, yen, Pts), A14 = 0 the Scandinavian set (manual 2-3:
  switch 1 on; ae, AE, o-slash, O-slash and four more glyphs differ).
- `pc_font.vhd`: a 32 KB image (8 RAMB36, was 2): 2 KB and 8 KB files are
  IBM images as before, 16 KB and 32 KB ones Commodore ROMs (`font_cbm_o`,
  32 KB copied 1:1, 16 KB into both halves); the copy's mode is taken when
  it starts. The auto-load file is now `/pc10/char.rom` (was `cga.rom`: the
  machine has no CGA); `FONT_START` accepts 2/8/16/32 KB. `main.vhd` passes
  the 15-bit font address and `font_cbm` to `pc_system`.
- Menu line 41 "Scandinavian charset" (CONFIG switch 1 on): `cbm_dip[0]`,
  live (on the board A14 is wired to the switch). 49 lines, menu heap demand
  1017 of 1024, settings signature `menu=5`.
- **Tests:** tb/shell PASS; tb_glue loads a 16 KB image (32768 font writes,
  each byte = image byte mod 16384, `font_cbm` = 1), grows it to 32 KB (1:1)
  and checks the overflow bit; it caught the copy's GO bit left at the old
  CDC index (main_ctl(14) after the word grew to 17 bits).
- **Hardware** (build pc10-real-q, WNS +0.263, BRAM 258): with
  `/pc10/char.rom` = 318086-03 every glyph was mirrored left-right (user's
  photo). The Commodore ROM holds the leftmost dot in D0, IBM's in D7 (read
  MSB-first, '[' is ']'; the first check of the ROMs used symmetric glyphs
  and missed it): the board wires the ROM's data lines to the PVC4 in reverse
  order. `pvc4.sv` now stores a Commodore image bit-reversed (`font_wd`), the
  reference model reverses its glyph fetch for `cbm`, and the test ROM
  (`make_cbm`) holds the real bit order. tb/pvc4 PASS; mutants "CBM data not
  reversed" (cbm: 39,394 dots differ) and "IBM data reversed too" (cmode3:
  78,796) killed.


## 2026-10-25 - The PC20-III's hard disk: the specification (branch `xta`, step 1)

- **What:** doc/xta.md, the plan's guesses replaced by facts: the
  disassembly of the disk BIOS in Commodore BIOS 4.41 (WD "IDE SuperBIOS
  Rev. 1.0", F8000-F9FFF; listings in `~/pcxt-work/xta/`, not in the
  repository), the PC10-III schematic of CN202 (sheet "FDD_HDD_BIOS"), WD's
  WD93024/34/44-X technical reference (via the PC-DISK database), kobolt's
  PC 20-III emulator (MIT), 86Box `hdc_xta.c`, MartyPC `xebec.rs`.
- **Findings:**
  - the drive is a WD93024-X (Commodore 312711-01): 782/2/27 physical (RLL),
    **615/4/17 in translate mode**, **3329 rpm**, seek 5/39/63 ms, one-sector
    buffer (WD: 3:1 interleave with single-transfer DMA, 2:1 in demand mode);
  - CN202 is only buffered I/O channel lines (SA0-1, IOR, IOW, DACK3,
    -HDCS, RESET, D0-7, IRQ via JMP206, DRQ via JMP207); **JMP208 gates the
    data buffer** (position A: the ports read FFh, the BIOS's "Hard disk not
    found" of today);
  - port 322h is the drive's configuration register: **FFh** for the
    PC20-III (translate, type 3 = 615/4, IRQ5, XT); bits 5-4 pick one of two
    4-entry drive tables, bit 7 = 0 would make the BIOS program the AT's
    second 8237 (the D4h/D6h accesses);
  - the BIOS's handshake, CCB (0-based sectors), all opcodes it uses, the
    sense-code mapping, DMA channel 3 (47h/4Bh, no TC to the drive), the
    status-bit-5 polling, and the detection sequence: reset, recalibrate,
    E4, test ready with a spin-up wait to tick 446, reset (initialize must
    succeed for drive 1 too), recalibrate;
  - the formatter is **`G=F800:5`** in 4.41 (the manual's FA00:5 and "WX2
    1.08" are an older ROM's), default interleave 4.
- **Open:** whether drive 1's test ready fails (4.9 s cold / ~14 s warm
  boot wait) or succeeds (kobolt); the real drive's command overhead,
  spin-up and reset times; the translation and interleave on 27-sector
  tracks (doc/xta.md section 11).
- Steps 2-4 (RTL, unit bench, tb/sys) not started (priority moved to the
  Paradise PVC4).

## 2026-10-25 - The PC20-III's hard disk: the card and its tests (branch `xta`, steps 2-4)

- **What:** `rtl/hdc/xta_card.sv`, the PC10-III main board's CN202 host side
  and the Western Digital WD93024-X with its embedded controller as one card
  (doc/xta.md section 9): 320h-323h behind JMP208 (`enable`; off = the ports
  float, no IRQ, no DRQ), the XT bus phases, the CCB, every command the
  Commodore BIOS 4.41 and its WD formatter use (00, 01, 03, 04, 05, 06, 07,
  08, 0A, 0B, 0C, 0D, 0E, 0F, E0, E3, E4, E5, E6), completion and sense
  bytes, DRQ3/DACK3 (no TC) and IRQ5 with the mask, a medium input
  (`present`), the LED (`active`), the sector port of the XTIDE card on a
  4-slot `hdc_secbuf` (read ahead, write behind, write-through at the end
  of each command).
- **Timing** (the drive's, not the backend's): 3329 rpm as 27 slots of
  exactly 516,124 clk per revolution, logical sector L = physical sector L
  (linear translation), the format's interleave as the usual slot layout,
  seeks 2760 + 140 x isqrt(256 d) us (5.0 / 38.9 / 65.3 ms), a one-sector
  buffer (the next read waits for the host, the next write's data come at
  the end of the previous slot), command overheads (300 us), 1.08 us per
  host byte, 5 s spin-up. All assumptions are [A] in doc/xta.md 9.2-9.4,
  the parameters configurable.
- **pc_system:** `XTA_FIT` (default 0: not built), ports `xta_enable`,
  `xta_present`, `xta_active`, `xta_sp_*`; the stand-in, `pc_system_flat`
  and the OOC top tie them off. tb/sys: `make XTA=1`, `sys_run -A image
  -jmp208 A|B -WA out -xl` (command log), `-k ms:keys` (typed scan codes),
  `-w` (warm-boot flag; the Commodore BIOS still tests its memory).
  `tb/sys/hd/fmtboot.S` + `mkfmtboot.py`: a boot floppy that starts the WD
  formatter at F800:0005 with a 5-function INT 21h instead of DOS/DEBUG.
- **Two bus faults, found in tb/sys** (doc/xta.md 9.7, 10.2): (1) the
  board's DACK3 outlasts AEN into the CPU's next I/O cycle, and the card
  took the BIOS's status poll for a DMA read (the boot sector read hung): a
  DMA cycle is now DACK3 with AEN. (2) The board fixes a cycle's wait states
  one state ahead and its DMA wait reaches READY with AEN, so the 8237 can
  take the bus in the last Tw of a CPU read; AEN cut the IOR and the CPU
  took the open bus (FFh = "interrupt"), and the resumed strobe moved a
  second data byte. `xt_board.sv` now gives the CPU the data its command had
  when AEN cut it (timing unchanged; on the 5160 the CPU would wait), and
  the card moves one data byte per CPU bus cycle (ALE). The drive's byte
  time now counts from a strobe's start (it overlapped nothing before: 2.8
  instead of ~2.2 us per byte).
- **tb/xta:** 2,742,243 checks, 0 failed (7.5 s of PC time; the full
  format with `-f`: 56.40 s, as the timing model says); `mut.py` 45 of 45
  killed.
- **tb/sys, Commodore BIOS 4.41, cold boot** (`make FE=1 PVC4=1 XTA=1`,
  `sys_run -d 5D -A hdtest.img -xl -s 60`, fedora, 5,535 s wall): the disk
  BIOS finds the drive (test ready loop until the 5 s spin-up, reset,
  initialize, recalibrate; drive 1 fails recalibrate), no "Hard disk not
  found"; at 45.6 s it boots the MBR test from C:, which prints `AH=08 CX DX
  6591 0301` (613 / 17 / 4 / 1 drive), reads 1 and 20 sectors (sum F600
  OK), writes and reads back 3 (OK), writes 1; `mkhdimg.py check` OK. With
  `-jmp208 A`: "Hard disk not found", no drive command. A test ROM
  (`tb/sys/hd/xtadma.S`) runs 32 DMA commands with refresh and a PIO read
  in 0.08 s of PC time.
- **Gates** (`gates.sh xta-f` vs merge-a): g_tr/g_tre/g_trL2 identical,
  g_fd identical but for the wall time, tb/fdc, tb/hdc, tb/cga, tb/mda
  PASS with identical logs; tb/shell and tb/pvc4 PASS locally.
- **Open** ([Q] in doc/xta.md 13): drive 1's test ready, the translation and
  interleave on the 27-sector tracks, the overheads and spin-up, the
  board's DMA/READY timing (the 5160 would add wait states).
- **The WD formatter** (`fmtboot.img` in A:, a blank image, `-k` answers
  Enter, Enter, N, y, N): "IDE Superbios Rev. 1.0", write sector buffer,
  format drive at interleave 4 in 56.36 s of PC time (the model: 56.4 s),
  "Format Successful"; all 41,820 sectors written with the buffer (11,377 s
  wall for 125 s). Not exercised: DOS on the drive (no DOS here), the
  dynamic/virtual configurations, bad-track formats through the BIOS, an
  INT 13h error path on the real BIOS.

## 2026-10-26 - Hardware: the Commodore character ROM (build pc10-real-r)

- Build `pc10-real-r` (5dfd2d9, WNS +0.263, WHS +0.036) with 318086-03 as
  `/pc10/char.rom`: the user confirmed the Commodore banner the right way round
  (the bit-reversed data lines) and the live "Scandinavian charset" switch.
  Found on the way: SPACE on a mounted floppy line opened the browser (no
  eject); fixed in 362e019 (build `pc10-real-s`). DOS 3.21's `setclock -r`
  printed "RTC timeout": no clock chip at 2C0h yet (branch `rtc`).
- Build `pc10-real-s` (362e019, incremental from pc10-real-r): WNS +0.263 but
  **WHS -0.068** (a same-clock hold path in `u_fdc/u_buf` across a clock region
  boundary, cells "Moved" by the incremental placement; the only change was the
  firmware's BRAM contents). Not used. Instead Megamiga's
  `patch_firmware.sh`/`.tcl`/`.py` came over (`CORE/`, QNICE ROM only: no
  rodata, no banks): `save` kept pc10-real-r's routed checkpoint
  (fedora `~/pcxt-fw/pc10-real-r`), `patch` put the 362e019 firmware in
  (16 block RAMs verified against the reference): `pc10-real-t` = pc10-real-r's
  HDL and timing (WNS +0.263, WHS +0.036) with the SPACE eject; kit
  `~/pcxt-work/kits/pc10-real-t` (+ Commodore MS-DOS 3.21 disks 1/2 for the SD
  card, never in the repo). Loaded on the MEGA65.

## 2026-10-26 - The PC20-III's hard disk in the shell (branch `xta-shell`, step 5)

- **What:** the MEGA65 build fits the hard disk (`pc_system_flat` `XTA_FIT`
  = 1; doc/xta.md section 11, doc/m2m-shell.md section 4). The image is a raw
  file of exactly 21,411,840 bytes (41,820 sectors) on the SD card, mounted on
  the new menu line ` C:%s` (line 4; every `C_MENU_*` from 4 on moved by one,
  `C_MENU_HDC_LN` for the eject); **JMP208 follows the image** (`xta_enable` =
  `xta_present` = mounted: without one the PC10-III, "Hard disk not found" at
  once). The BIOS looks at its start: mount, then reset the PC. SPACE on the
  mounted line ejects it (main's floppy eject, merged).
- **Backend:** `pc_fdd_sd.vhd` got a third drive (C:, QNICE device
  `C_DEV_PC_HDC` 0x0105 with the floppies' registers, its own extent map of at
  most 511 extents, present only at 41,820 sectors, LBA 28 bits: above 65535
  or beyond the file = `sp_err`, never write-protected) and a second
  main-side sector port with an arbiter (one request at a time, round robin
  when both ask, answers only to the port served; a request dropped before
  `sp_done`, i.e. a card reset, is abandoned). Still the only user of the SD
  host's engine port; write-through. Firmware: `PREP_LOAD_IMAGE` takes C:
  only at 0x0146B800 bytes ("Not a PC20-III hard disk image: C: needs exactly
  21,411,840 bytes"), `FD_DEV_TAB` has the third device. Settings signature
  `menu=6`; menu heap demand 1058, `MENU_HEAP_SIZE` 1088, `HEAP_SIZE` 19904
  (`HEAP` 0xA52E, 418 words below the stack); ROM 32296 of 32768 words.
- **LED:** red while `xta_active` (busy or a write still going to the image),
  yellow for a selected floppy drive (it wins); no drive sound for C:.
- **Tests (tb/shell, local):** `tb_fdd` C: in three extents of 64-sector
  clusters, both ports at once (reads served F H F H, writes), a monitor (no
  answer to a port that does not ask, no `err` without `done`, never both
  `wr_ready`), abandoned requests in the wait, the write collection and the
  read stream, wrong sizes / off = no disk: PASS, 49 engine transfers;
  `run_prepload.sh` (new: `PREP_LOAD_IMAGE` on the QNICE emulator, 11 cases)
  PASS; `tb_drvsnd` the LED colours PASS. `mut.py`: `pc_fdd_sd` 27 of 27 (new;
  one candidate dropped as equivalent), `pc_drvsnd` 32 of 32, `pc_chipset` 14
  of 14, signature 5 of 5, `PREP_LOAD_IMAGE` 9 of 9 killed.
- **Gates** (fedora `gates.sh xsh-a` = 9824c95's tree vs `merge-b`): g_tr
  a72753ca..., g_tre bd612823..., g_trL2 a72753ca... identical; g_fd identical
  but the wall time; tb/fdc (232 checks), tb/hdc (3,182), tb/cga, tb/mda logs
  identical but paths and wall times (tb/shell: local only, as before).
  tb/xta `make run`: 2,742,243 checks, 0 failed (unchanged RTL).
- **Builds** (R6, incremental from `pc10-real-r`): `pc10-xta-a` (9824c95):
  RESULT OK, **WNS +0.052, WHS +0.036**, 0 routing errors; the worst path is
  QNICE's address bus into the BIOS ROM block RAM (half period, qnice_clk;
  main_clk +13.2). `pc10-xta-b` (0e28ba4, main's eject merged, from
  pc10-xta-a): the same timing, **BRAM 260.5 of 365** (258 before: the
  card's sector buffer and the 8K-word extent map), 29,816 LUTs; `xta_card`
  1,268 LUTs, 1 RAMB36, 2 DSPs; `pc_fdd_sd` 757 LUTs. Kit
  `~/pcxt-work/kits/pc10-xta-a/` (bitstream of pc10-xta-b; `sd/pc10/`: the
  Commodore BIOS 4.41 as `bios.rom`, GLaBIOS as `bios-glabios.rom`, a blank
  `hd20.img`, `hd20-wdfmt.img` = the WD formatter's result from tb/sys,
  `fmtboot.img`, Commodore MS-DOS 3.21 `dos321-1.img`/`dos321-2.img`; none of
  it in the repo). Not on hardware yet.
- **tb/sys** (fedora, `make FE=1 PVC4=1 XTA=1`): the MBR test boot from C:
  (`-A hdtest.img -s 60`) as before: `AH=08 CX DX 6591 0301`, `read 20, sum
  F600 OK`, `write 3, read back OK`, `mkhdimg.py check` OK (LBA 49-51, 59).
  New `sys_run -e 'text|keys'` (keys when the cursor's line shows text, in
  order) and `-E text` (stop): Commodore MS-DOS 3.21 from A: with a blank C:
  (`RAM_KB=256` for a shorter memory test): `fdisk` (Enter, Enter = the whole
  disk, active; "System will now restart" at 53.4 s), the reboot, `format c:
  /s` at 86.5 s, "Proceed with Format (Y/N)?y" at 100.1 s; FORMAT verifies
  about 0.38 s per cylinder (cylinder 52 at 120 s), so the whole 615 take
  about 235 s of PC time (8-9 h wall on the loaded host). Still running at
  this entry: fedora `~/pcxt-work/dos/run1.log` (image `dos1.img`), then
  `run2.sh` copies DOS disk 1's files onto C: (mtools) and cold-boots from C:
  (`run2.log`, `dos2.img`).

## 2026-10-26 - The PC10-III's real-time clock: an MSM6242B at 2C0h, seeded from and written back to the MEGA65's RTC (branch `rtc`)

- **Why:** on hardware MS-DOS 3.21's AUTOEXEC (`setclock -r`) printed `RTC
  timeout`: nothing answered at 2C0h (FFh reads have BUSY set).
- **Facts** (doc/rtc.md): the board's U401 is an OKI MSM6242B (SM sheet 9-4:
  D3-D0, A3-A0, RD'/WR' = NIOR'/NIOW', CS0' from the 5720, CS1/ALE on the
  battery node, STD.P only on a pull-up: no interrupt), enabled by 230h bit 6,
  which the BIOS 4.41 sets in every POST. The POST reads 2C0h twice 2.33 s
  apart; ticking: `Onboard RTC at 02C0h`, the tick count from INT 1Ah AH=02;
  not ticking: CD = 04h, CF = 07h/04h, once more. INT 1Ah AH=02-05 use HOLD
  (07h) with BUSY polling, the year registers count from 1980. SETUP keeps its
  configuration in the hard disk's MBR (signature `PC10` at 1B0h, the word at
  1B4h), not in the RTC (the chip has no RAM: the old note was wrong).
  SETCLOCK V3.0 (Colt disk): `-r` reads 13 registers in 24 h mode, `-w` uses
  STOP/REST and writes W from DOS, and stores DOS's hundredths as the seconds
  (a bug of V3.0). MS-DOS 3.21's IO.SYS reads the RTC (AH=02, AH=04) at boot
  and never writes it: DOS's TIME/DATE do not persist, `setclock -w` does.
- **Model** (`rtl/system/msm6242.sv`, in pc_system with the PVC4/230h board
  logic): an exact 32.768 kHz accumulator on clk, the BCD calendar with leap
  years, 12/24 h, HOLD with one held carry, BUSY (183 us window, cleared by a
  16 kHz sample with HOLD = 0, kept while HOLD stays set), 30 s adjust,
  STOP/REST/TEST, the STD.P/IRQ flag; no reset (battery). Seed: M2M's
  `main_rtc_i` on its toggle (stable data, valid BCD, not during HOLD, not
  after the PC set the clock; years + 20, weekday Monday = 0 -> W 1).
  Write-back: `rtc_set` when the PC has set the clock and HOLD/STOP/ADJ are
  clear, `rtc_time` in M2M's register order (years - 20 mod 100, so 1980-1999
  are 2080-2099 on the MEGA65 and back). LUTs 374, FFs 184, 1 DSP.
- **Shell:** `CORE/vhdl/pc_rtc.vhd` (QNICE device 0x0106, request/acknowledge
  through `cdc_stable`), firmware `PC_RTC_WB` (`CORE/m2m-rom/pc_rtc.asm`, first
  in `HANDLE_CORE_IO`): stop M2M's internal timer, its registers 0x00-0x07,
  0x0C (copy to the RTC, then run), acknowledge; 61 words, ROM 32227 of 32768,
  no variables (HEAP 0xA51C unchanged).
- **tb/rtc** (`make run`, fedora; reference model + independent checks:
  gmtime calendar, the BIOS's INT 1Ah and SETCLOCK V3.0 sequences with their
  cycle gaps): 12 runs PASS, 2,836,999,846 clk compared with the model, 6.2 M
  CPU reads, 492 explicit checks (322 calendar cases in 24 h and 12 h mode,
  1980-2079); the phase sweep around the carry shows the BIOS's INT 1Ah
  failing in 5 of 11 phases inside BUSY's ~250 us window (its 50 retries keep
  HOLD set; DS's own note) and SETCLOCK in 3. `mut.py`: 54 of 54 killed (the
  first run left two: no calendar year with odd tens and a leap year, and an
  equivalent strobe mutant; the calendar gained 1990/1992/2010/2012).
- **tb/shell** (local): `tb_rtc.vhd` (pc_rtc.vhd with M2M's rtc_controller,
  the firmware's sequence, busy I2C, two requests, stray acknowledges),
  `run_rtcwb.sh` (`PC_RTC_WB` on the QNICE emulator), `run.sh` PASS;
  `mut_rtc.py` 8 of 8 + 7 of 7 killed. tb/pvc4 `make run` PASS.
- **Gates** (fedora `gates.sh rtc-a`, vs merge-b): g_tr a72753ca..., g_tre
  bd612823..., g_trL2 a72753ca...: identical; g_fd identical but for the wall
  time; tb/fdc, tb/hdc, tb/cga, tb/mda logs identical but for paths.
- **tb/sys** (fedora, Commodore BIOS 4.41 + Colt MS-DOS 3.21, `-R
  "2026-10-26 12:34:56"`): 640 KB: `Onboard RTC at 02C0h`, IO.SYS reads the
  date, `setclock -r` without `RTC timeout`, DATE `Mon 10-26-2026` and TIME
  `12:36:09.17` at 70/73 s; 256 KB: `time 23:59:50`, `date 12-31-99`,
  `setclock -w`: one write-back `2099-12-31 23:59:29.00` weekday 4 (the 29 s
  are DOS's hundredths, SETCLOCK V3.0's bug), `setclock -r`, DATE `Fri
  12-31-1999`, TIME `23:59:44.61`; without a seed: `1-01-1980 0:01:00`.
- **Build** pc10-rtc-a (REF=pc10-real-r, commit 1aeb061): WNS +0.067, WHS
  +0.036, BRAM 258 of 365 (unchanged); the worst path is QNICE's own (device
  register to its address bus, +0.067; pc10-real-r +0.263), the new device in
  the QNICE read mux. Kit `~/pcxt-work/kits/pc10-rtc-a/` (pc10-real-r's SD
  files, `dos321-1.img`, `bios-cbm441.rom` to copy over `bios.rom`).
- Not verified: hardware; M2M's RTC write on the real I2C chip.

## 2026-10-26 - Main with the hard disk and the RTC (build pc10-real-u)

- Merged `xta-shell` (6584887; build pc10-xta-b loaded on the MEGA65 first)
  and `rtc` (e80fb99; conflicts only where both added ports/lines: the drive
  fitted plus the RTC ports in pc_system_flat/OOC/main/mega65, both doc
  sections). Firmware 32357/32768 words, `HEAP` 0xA52E (418 words below the
  stack). tb/shell run.sh: all PASS (tb_glue, tb_fdd 49 transfers, drvsnd,
  chipset, tb_rtc, CFGSIG, PREPLOAD, RTCWB, stub).
- Build `pc10-real-u` (REF=pc10-xta-b): WNS +0.021, WHS +0.036, BRAM
  260.5/365; checkpoint saved for `patch_firmware.sh` (fedora
  `~/pcxt-fw/pc10-real-u`). Kit `~/pcxt-work/kits/pc10-real-u` (Commodore BIOS
  4.41, char ROM, DOS 3.21, hd20.img, hd20-wdfmt.img, fmtboot.img). Loaded on
  the MEGA65. Gates of the merged tree: fedora `clk/merge-c`.
- Hardware (pc10-real-u): the user confirmed the RTC (date and time correct
  from the MEGA65's battery clock); the hard disk was formatting at the time,
  "all seems good so far".
- Hardware (pc10-real-u): the user formatted `hd20.img` (FDISK, FORMAT C: /S)
  and **DOS 3.21 boots from C:**; its date/time prompt is prefilled from the RTC.
  The time was one hour ahead (the MEGA65's battery clock still on summer time,
  which ended 2026-10-25 [A]); DOS TIME does not reach the RTC (IO.SYS never
  writes it, as on the real machine), and FORMAT /S copied no SETCLOCK.EXE.
- Hardware (pc10-real-u): `setclock -w` (copied from the Colt DOS disk to C:)
  writes the RTC and the MEGA65's battery clock; the time persists across a
  power cycle. RTC write-back confirmed.

## 2026-10-26 - Turbo: the FE2010A's 7.16 and 9.54 MHz (branch `turbo`)

- **What:** in the PC10-III chipset mode, port 63h bits 7-6 run the 8088 at
  7.16 MHz (master clock / 4) or 9.54 MHz (/ 3), and the FE2010A's turbo
  wait states apply. The Commodore BIOS's Ctrl-Alt-S/T/D, SETUP's default
  speed and SPEED.EXE work as on the real machine. The IBM XT (8255) choice
  stays at 4.77 MHz. There is no menu change: the real machine has no other
  speed control. Facts, sources, assumptions and open questions:
  doc/turbo.md. doc/clock-plan.md step 5 is done (section 7 there).
- **Research** (doc/turbo.md sections 1-5):
  - Kiselev's FE2010A notes (the 2023 wait-state table: I/O 1/4/6, 4 at
    9.54 MHz with bit 6; memory bus 0/2/4, 0 with bit 5; on-board RAM 0) and
    their git history (bit 7 overrides bit 6; 50% duty except at 4.77 MHz).
  - The FE2010 data sheet, GLaBIOS, Kiselev's 8088_bios, 86Box and MAME (no
    turbo), the PC10-III manual (Ctrl-Alt-S/T/D, "pre set to the standard 4.77
    MHz"), and TopBench on a real PC10-III (opcodes x 1.51 / x 2.01).
  - The Commodore BIOS 4.41 (our disassembly): hot keys in INT 9 (EAB9 ->
    D40F: 00h/40h/80h to 63h, a beep, 0040:0012 bits 7-6). Every BIOS service
    exit (C6B5) writes (0040:0012 & C0h) | 01h to 63h. CA55 sets 0012 from
    SETUP's word 40:A1h bits 1-0. The POST writes 45h/51h/41h (bit 6) during
    the RAM sizing and locks with `| 48h`. SETUP is Ctrl-Alt-Esc (EACB ->
    D762; doc/rtc.md section 5).
  - SPEED.EXE V1.2 (PC1020-3.ZIP: `-s/-t/-d` = 01h/41h/81h) and V1.2c (Colt
    disk: `-s/-t`) only write 0040:0012. The next BIOS service exit switches.
- **pc_clocks.sv:** the CPU counter's period 6/4/3. `cpu_fall` is step + 2
  (4.77: 1/3 duty; 7.16: 50%) or step + 1 (9.54: 50%, the 1.5 clk edge rounded
  down). `rdy_ce`/`cpu_prestep` are the clk before the step. A new speed takes
  effect where the modulo-24 counter is 0 or 12: no shortened clock, and the
  phase to OSC/PCLK is kept. `ce_477` is a fixed 4.77 MHz enable for the
  keyboard's delays, which were in CPU clocks.
- **xt_wait.sv** (new): the board's wait states as a count (the table above),
  with the DMA rule of 2026-10-22. For one wait state it is identical to the old
  `io_wait`/`dma_ok` (checked in tb/wait).
- **xt_board.sv:** the speed from 63h (FE mode only), `ce_477`, `xt_wait`.
  - **FE mode: the DMA takes the bus only between CPU bus cycles.** The
    FE2010 uses RQ/GT, which the 8088 grants in T4/Ti, so the hold flip-flop
    takes a T3/Tw only when it is the last. The first build's tb/sys runs
    (old rule) showed why it matters. A refresh in an I/O cycle's turbo wait
    states split the CPU's IOW/IOR into two strobes: a doubled FDC command
    byte or result read gave "Drive A: Bad" at 9.54 MHz, INT 13h status 20h
    and wrong data at 7.16/9.54 MHz, and a DOS program loaded as garbage at
    7.16 MHz. tb/sys `+cutlog` counted the split strobes of the floppy test
    (fdtest, 256 KB): at the turbo speeds 3,002 MEMW, 2,492 MEMR, 25 IOW and 1
    IOR, plus 3,276 PVC4 MEMW at 4.77 MHz. INT 13h returned status 20h for
    cylinder 0 at 7.16 MHz and 3 at 9.54 MHz, and a wrong sum with status 00h
    for cylinder 0 at 9.54 MHz. After the fix there are no split strobes at
    any speed, and every read has status 00h with the same sums at 7.16, 9.54
    and 4.77 MHz (6178h B6C7h 0B15h D589h).
  - The 5160 mode is unchanged.
- **Testbenches:**
  - tb/clk (new): `ref` (speed 0 = the /6 counter in every clk), `fixed`,
    `switch` (2M clk of random requests), PHASE 0 and 5: PASS. `mut.py` 16 of 16
    killed (one equivalent mutant found and its redundant RTL term removed).
  - tb/wait (new): 3 x 400,000 random bus cycles: PASS. `mut.py` 20 of 20
    killed.
  - tb/sst `-T 4`/`-T 3`.
  - tb/sys: `-cr` (CPU clocks per 50 ms and a wait-state histogram per speed
    and class), the log line `CPU clock x MHz` at every change, `\#hh` raw scan
    codes and `\.` pauses in `-k`, `+cutlog`. The boot floppies
    `tb/sys/turbo/speedtest.S` and `fdtest.S` (`mkspeedtest.py`).
- **SST** (fedora, full suite): state 3,007,000, trace 3,006,693 at 4.77 MHz
  (6 clk), 7.16 MHz (4) and 9.54 MHz (3). Every file's line is the same at the
  three dividers and the same as clk28-a's (before: 3,007,000 / 3,006,693).
- **Gates** (fedora `gates.sh turbo-a` and `turbo-b` vs `merge-c`): g_tr
  a72753ca..., g_tre bd612823..., g_trL2 a72753ca...: identical. g_fd is
  identical but for the wall time. tb/fdc 232, tb/hdc 3,182 checks, tb/cga,
  tb/mda PASS. tb/pvc4 PASS (13,626 operations), tb/xta 2,742,243 checks,
  tb/rtc PASS. tb/shell (local) PASS.
- **tb/sys** (fedora, the Commodore BIOS 4.41, FE2010A + PVC4; doc/turbo.md
  section 6):
  - The POST runs at 7.16 MHz from 0.23 to 0.61 s and from 7.91 to 10.21 s
    (the BIOS's own 45h/51h/41h). The boot sector is read at 34.005 s with
    640 KB (38.205 before).
  - The hot keys switch 1.2 ms after the letter: 7,158,861 / 9,545,152 /
    4,773,054 CPU clocks in the following second.
  - The speed test (loops between two timer ticks): register loop 1.501 /
    2.002; 4 x IN 1.390 (7.16) / 1.761 (9.54) / 1.878 (9.54 with bit 6); 4 x ROM
    1.440 / 1.820, 2.076 with bit 5. The wait-state histogram: I/O 1/4/6,
    on-board RAM 0, ROM 0/2/4.
  - The floppy test: the same data at all speeds.
  - MS-DOS 3.21 booted at 9.54 MHz (640 KB): AUTOEXEC's `setclock -r` and
    `speed -t` (7.16 MHz at 47.13 s), then `speed2 -d` (9.54, 50.69 s), `ver`,
    `speed2 -s` (4.77, 55.07 s), `speed -t` (7.16, 59.04 s), all at `A>`
    (5,980 s wall).
  - SETUP with Ctrl-Alt-Esc (640 KB; with 256 KB SETUP crashes, its stack is
    at 5000h).
  - Logs: fedora `~/pcxt-work/turbo/sys/` (s1c, s2c, s3c, s5c, f1, f2).
- **Build** pc10-turbo-a (RTL 23bcd36, REF=pc10-real-u): WNS +0.021, WHS
  +0.036. It is superseded by **pc10-turbo-b** (8d35d5b, the DMA rule,
  REF=pc10-turbo-a): WNS +0.021, WHS +0.036 (QNICE's paths, as pc10-real-u);
  main_clk WNS +13.214, WHS +0.043; BRAM 260.5/365 and LUTs 30,292 unchanged.
  Kit `~/pcxt-work/kits/pc10-turbo-b/` (pc10-real-u's SD files plus
  `speedtest.img`, `fdtest.img` and `dos321-speed.img` = Colt disk 1 with the
  PC10-III's SPEED.EXE V1.2 as SPEED2.EXE).
- Not verified: hardware (speeds, wait states, the hot keys' beep pitch);
  the PC20-III hard disk at the turbo speeds; SETUP's default speed through
  the MBR.

