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
