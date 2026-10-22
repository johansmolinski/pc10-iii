# z8086 as the 8088's execution unit - evaluation

Branch `z8086-eval` (worktree `~/git/my/pc10-iii-z86`), 2026-10-22. An
evaluation, not for merging. Question: can nand2mario's z8086, which runs
Intel's own 8086 microcode, be the base of a faithful 8088 EU for the
PC10-III, one microinstruction per CPU clock, on the board's master clock with
clock enables (like fx68k for the 68000), in front of our biu88?

Short answer: yes. Once its EU runs in front of biu88 at one microinstruction
per 8088 clock and six structural points are corrected (sections 2 and 5),
it passes 100.00% of the SingleStepTests on state and 98.31% on the full
per-cycle trace, without a single instruction-specific timing rule. 99.4% of
what is left goes through the interrupt microcode, which is the 8086's in
z8086 and differs in the 8088 (section 5); the rest is one case biu88 also
fails with MCL86.

## 1. z8086

- Source: https://github.com/nand2mario/z8086, commit
  `596d9a6616b90c31f35b0d0947d4c1b11aa7a674` (2025-12-21), cloned to
  `~/git/my/z8086`. Write-up: https://nand2mario.github.io/posts/2025/z8086/.
- Licence: Apache 2.0, stated in the README ("I have chosen to release it
  under the permissive Apache 2.0 license"). The repository has no LICENSE
  file; `rtl/cpu/z8086/LICENSE` is the Apache 2.0 text, `NOTICE` names the
  source and commit.
- Size: `z8086.sv` 1343 lines, `alu.sv` 514 lines; about 1800 LUTs on Artix-7
  by its README (with its own bus and 6-byte queue).
- **Microcode** (`src/z8086/ucode.hex`, 512 x 21 bits): Intel's 8086
  microcode as Andrew Jenner extracted it from Ken Shirriff's die photo
  (https://www.reenigne.org/blog/8086-microcode-disassembled/). It is the
  **8086** ROM: it has two INTA microinstructions (0x19A, 0x19C), where the
  8088's does one INTA access and lets the BIU split it (Jenner).
- **Decode ROMs**, rebuilt as logic in `z8086.sv`: the group decode ROM
  (`group_decode`, from Shirriff's transcription,
  https://static.righto.com/8086/groupRom.html), the translation ROM
  (`translate`, microcode entry points for the EA modes and the long
  jumps/calls; upstream `doc/translation_8086.txt`) and the microcode address
  compression (`uaddr_pack`, the 13-bit {AR,CR} to the 512 ROM rows).
- **Repository rule 4** (no Intel microcode): `ucode.hex` is NOT imported. The
  build reads it from the local z8086 checkout (`tb/sst`: `Z86_UCODE`,
  default `~/git/my/z8086/src/z8086/ucode.hex`; the OOC script takes the
  path as an argument). `z8086.sv` (imported, as the base of `z86_eu.sv`)
  still contains the translation ROM's entry addresses and the address
  compression table as logic: reconstructions of Intel ROM contents, not
  microcode words. Whether rule 4 covers them is the owner's call; this
  branch is not merged.

## 2. Answers about z8086's EU

**One microinstruction per clock?** Yes. The ROM word for the next address
is read every clock that is not stalled (`uc <= ucode_rom[uaddr]`) and executed
the next (`ROME`), as Shirriff describes the real pipeline (address register,
then the ROM output a clock later: "One micro-instruction is executed per
clock cycle", righto.com 2023/01, the microcode pipeline). A taken jump, a
long jump/call (through the translation ROM), RTN, the entry of an EA routine
and the group 3/4/5 re-entry clear ROME for one clock: the wasted clock of
the real chip ("the next micro-instruction is on the way, so it is blocked by
the ROM Enable (ROME) signal going low"). An untaken jump costs nothing. In
z8086 the clock is its system clock (50 MHz in its SoC) with a simple
rd/wr/ready bus; here it is the 8088 clock (a clock enable).

**Internal timing**, item by item:

| Point | z8086 | Real chip (Shirriff, Jenner, XTCE) | Here |
|---|---|---|---|
| Loader FC/SC | the patent's 4-state loader; FC reads the opcode, SC the ModR/M byte (2BR) or runs a 1BL instruction; first microinstruction the clock after SC | the same: "three full clock cycles from the arrival of an instruction until the first micro-instruction completes" | kept |
| RNI | ends the instruction; FC in the same clock | the same | kept |
| NXT (NX) | only type 1 (ALU) bit 0 | also type 4: STU = 5 (NX) and STU = 1 (WB,NX). In the ROM every STU = 5 word is followed by an RNI word | **added** (every instruction ending "NX; RNI" was a clock slow) |
| type 6 + RNI ("W,RNI") | next instruction's FC in the clock of the request | RNI when the transfer completes (XTCE `busAccessDone`); the opcode is read in the write's last T3 | **fixed** |
| RNI/NX for a memory destination | an opcode table (`writes_memory`) plus "WB nulls the next RNI if M is memory" | XTCE: a move to M while M is memory skips every later plain RNI (the instruction ends with W,RNI); a type 1 NX is dropped while M is memory unless the microinstruction's own ALU field is CMP; WB,NX counts unless M is memory and the op is not CMP; CMP never writes M | **replaced** by the XTCE rule. z8086's table wrote CMP r/m's operand back (an extra write cycle), let POP r/m end before its write, and dropped CMP's NX |
| EU waits on the bus | stalls from the type 6 microinstruction until `ready` (right in principle: "the microcode engine is blocked until the memory request completes", Shirriff) but its bus has no T-states | XTCE: a request starts after 1-2 address clocks (Ts/T0), byte transfers back to back for a word on the 8088, the last completes in T3 (READY), the next microinstruction runs in T4 | biu88 times the bus; the EU resumes where XTCE does (section 3) |
| Queue reads | `Q` source stalls on an empty queue; ModR/M popped at SC; opcode at FC | the same; the queue is the BIU's, a fetched byte usable the clock after its T4 | biu88's queue (4 bytes), z8086's 6-byte queue removed |
| SUSP | sets a flag, no wait | waits until a running fetch reaches T4 (XTCE `stateSuspending`) | **added** (biu88's SUSP request; the EU resumes the clock after) |
| CORR | `IP <= IP - q_len` in the same clock | waits until no transfer runs (bus passive, not T4), at least two clocks (Shirriff: the BIU runs two "fake" states; XTCE `stateWaitingForQueueIdle`) | **added** (the EU waits for Ti/T3); IP itself is biu88's EU IP, so nothing is subtracted |
| FLUSH | resets its queue in the clock | the same (XTCE: prefetch restarts the next clock) | biu88's flush request (MCL86 code 0x19) |
| Jumps and calls | 1-clock bubble on taken short/long jumps, long calls, RTN | the same | kept |
| ALU and flags | combinational ALU; the op is set by type 1 (ALUOPC register), Σ used by the next microinstruction; flags written with the F bit | the same (Shirriff's ADD example) | kept; DAA/DAS threshold fixed (below) |
| M/N | group decode at FC/SC, M/N from opcode or ModR/M, crossover for the d bit, byte/word from bit 0 | the same (Shirriff, register codes) | kept |
| Interrupts | INTR/NMI latched at instruction ends, microcode at 1r0000000.00ab; the 8086 ROM (two INTA microinstructions) | the 8088's ROM differs in the interrupt routine (one INTA access, the BIU splits it; INTR entry 0x19E, not 0x19D; "the other changes seem to be fallout", Jenner) | not changed; INTR/NMI not wired in this prototype |
| Not modelled | LOCK, WAIT/TEST, HLT bus cycle (HLT just stops the sequencer), coprocessor, single-step trap timing | | |

**Deviations from the real chip** found by the suite (all corrected here
except the interrupt routine):
1. type 4 NX missing;
2. W,RNI started the next instruction at the request;
3. the memory-destination RNI/NX table (CMP r/m, POP r/m);
4. no SUSP wait, no CORR wait;
5. DAA/DAS: with AF set the 8086/8088 compares the old AL with 9Fh, not 99h
   (z8086 used 99h: 1 test in 50 of DAA/DAS failed on state);
6. the 8086 interrupt microcode (section 5).

**8088 against 8086** (Jenner, Shirriff, XTCE):
- Microcode: only the interrupt handling differs. The 8086 does two word INTA
  accesses, the 8088 one, split by the BIU; the INTR translation entry is
  0x19E on the 8088 (0x19D on the 8086); the rest is "fallout". Shirriff
  photographed the 8088 ROM ("very similar but not identical"); no published
  word-by-word diff and no public 8088 ROM dump was found. XTCE (Jenner's
  microcode-level 8088 emulator) loads the 8088 ROM from bit images that are
  not in his public repository.
- Queue: 4 bytes (2-bit pointers), filled a byte at a time; the 8088 fetch
  policy (a fetch that would fill the queue is delayed; Jenner measured the
  3-byte delay on a real 8088); biu88 has it.
- 8-bit BIU: word transfers are two byte cycles; the microcode only sees the
  word flag.
- What the EU depends on: only the interrupt routine (and through it the INTA
  count). Queue size, fetch policy, CORR's constant and the byte split are the
  BIU's.

## 3. The prototype

Files (`rtl/cpu/z8086/`):
- `z8086.sv`, `alu.sv`: upstream (alu.sv with the DAA/DAS fix).
- `z86_eu.sv`: z8086's EU without its bus and queue; changes marked
  "pc10-iii".
- `cpu_z86.sv`: `z86_eu` + an adapter + `biu88` (unchanged).
- `tb/sst/tb_z86.v` + `make CPU=z86` (`Z86_UCODE` = the ROM image).
- `tools/ooc/z86_ooc.tcl`, `z86_ooc_top.v`: out-of-context synthesis.

The split is the real chip's:
- the EU keeps the microcode sequencer, loader, group decode, M/N, the ALU,
  the lower register file and IND/OPR/the segment registers (the microcode
  moves to and from them directly);
- the BIU (biu88) owns the bus T-states, the address cycle, the queue, the
  fetch policy, the EU's IP and the fetch address.

**Clocking.** Everything on the core clock. biu88 steps once per 8088 clock
(`step`, as on main). The EU's clock enable `ce` is `step` delayed by 3
clocks, so the EU sees the BIU state after the step: a byte pushed at T4, a
transfer's done pulse. One microinstruction per `ce`. The EU itself does not
need 100 MHz: everything it does happens once per 8088 clock. Only biu88 (as
built for MCL86) works per core clock.

**EU to BIU, per 8088 clock** (the adapter turns the EU's pulses of that
clock into biu88's MCL86 commands on the following core clocks, all inside the
same 8088 clock, which biu88 attributes to that clock):

| clk after the EU's | command | from the EU |
|---|---|---|
| +2 | register strobe 11, codes 0-3 | segment register written (biu88 forms CS:IP and the transfer address from its copy) |
| +3 | queue strobe 01, QS code 01/11 | queue read at FC (first byte) or of a Q source / ModR/M (subsequent): read and pop in one, QS from biu88 one clock later |
| +4 | request (bit 9 edge) | type 6: 0x0C/0x10 read byte/word, 0x0E/0x13 write, 0x12 word read at segment 0, 0x08/0x1A IN, 0x0A/0x1C OUT, 0x16 INTA; FLUSH: 0x19 with the new IP; SUSP: 0x1E |

- The EU's IP for microcode reads of PC is biu88's EU IP (`PFQ_ADDR_OUT`),
  the address of the next byte the EU reads: already what CORR would compute.
- PC writes are kept and handed over with FLUSH.
- Write data is OPR after the request microinstruction's own move.
- None of biu88's MCL86 timing aids is used: no end counter, no request
  release, no scheduled read, no "taken" bytes. The EU's own microcode
  sequence times every queue read, request and instruction end.

**Where the EU resumes after a transfer** (XTCE's rule, onto biu88's done
pulse):
- read: biu88 reports done at the step into T4; the next microinstruction runs
  in T4;
- write: done at the step into the last T3; a W,RNI reads the next opcode in
  that T3, otherwise the next microinstruction runs a clock later (T4);
- SUSP: done at once if no fetch runs (next microinstruction the next clock),
  otherwise at T4, and the EU runs a clock later.

**Harness mapping** (`tb_z86.v`):
- `dbg_eu_cmd` is the command to biu88, so the loader's JMP FAR is the flush
  request as before;
- `dbg_rom_addr` reads 0x0006 while the loader waits for an opcode, where
  the harness installs a prefetched queue;
- `dbg_dispatch` is one EU clock after FC (with NX the last microinstruction
  runs after FC) and after an outstanding transfer;
- `dbg_flags` has bit 1 cleared (MCL86's REP marker);
- `dbg_ip` is the EU IP at FC.

The `-S` phase sweep changes nothing: the EU acts at a fixed offset from
`step`.

## 4. SingleStepTests

Full suite, `make run CPU=z86` on fedora (16 jobs), compared with run y5
(MCL86 + biu88, main), `~/pcxt-work/results/`:

| run | CPU | state | trace | files below 100% (trace) |
|---|---|---|---|---|
| biu88-y5 (main) | MCL86 EU (100 MHz microsequencer, hand-timed microcode) + biu88 | 3,007,000 (100.00%) | 3,006,693 (99.99%) | 1 (C6) |
| z86-a (2391ed9) | z8086 EU + biu88 | 3,006,849 (99.99%) | 2,956,172 (98.31%) | 9 |
| z86-b (28c4332) | + DAA/DAS, NEG r/m8 flags | 3,007,000 (100.00%) | 2,956,172 (98.31%) | 9 |

(3,007,000 tests in 323 files; every test is graded on cycles, the
prefetched ones with biu88's queue preload. Length: z86-a 2,968,709.)

Before the structural fixes (a 50-test sample of every file, 16,150 tests):
the EU as imported, behind biu88, passed 16,022 on state; after NX, W,RNI,
SUSP/CORR waits and the RNI/NX rule: 16,149 state, 15,894 trace (98.4%).
The MCL86 path took runs a-y (two days of per-instruction SYNCs, end
counters and releases) to reach its 99.99%; z86 gets 98.3% from Intel's
microcode with no instruction-specific timing at all.

Every test that z86-b fails on its trace, by file (z86-a: the same, plus
the 151 state failures of 27, 2F and F6.3 fixed in b):

| file | instruction | trace failures | cause |
|---|---|---|---|
| CC | INT 3 | 10,000 | interrupt microcode (8086 ROM) |
| CD | INT n | 10,000 | interrupt microcode |
| CE | INTO | 5,051 (all taken) | interrupt microcode |
| F6.6 / F6.7 | DIV / IDIV r/m8 | 5,199 / 7,540 (all divide errors) | interrupt microcode (INT 0) |
| F7.6 / F7.7 | DIV / IDIV r/m16 | 5,095 / 7,589 (all divide errors) | interrupt microcode (INT 0) |
| D4 | AAM | 47 (AAM 0: divide error) | interrupt microcode (INT 0) |
| C6 | MOV r/m8,imm8 | 307 | BIU (the same 307 tests fail with MCL86, run y5) |

50,521 of the 50,828 failures (99.4%) go through the interrupt routine; the
rest is the one case biu88 already fails with MCL86. Results, flags and
memory are right in all of them (state 100% in b).

## 5. What is left, by category

**Structural (EU/BIU interface, queue, loader) - fixed in the prototype:**
1. Type 4 NX (STU = 5) and WB,NX (STU = 1) were not next-to-last: +1 clock on
   every instruction ending "NX; RNI" (XCHG AX,r, NOP, prefixed forms...).
2. W,RNI started the next instruction in the clock of the write request; the
   real chip reads the next opcode in the write's last T3 (PUSH, CALL, MOV
   [m],r, all read-modify-write forms).
3. The memory-destination RNI/NX rule: z8086's opcode table; replaced by
   XTCE's rule from the microcode itself (CMP r/m did a write cycle of its
   own; POP r/m ended before its write; CMP's NX).
4. SUSP did not wait for a running fetch; CORR did not wait for the bus
   (JMP/CALL/RET/Jcc/LOOP flush timing: 3 clocks early before the fix).
5. Where the EU resumes after a write or a SUSP that waited (a clock after
   biu88's done; reads resume at biu88's done).

With these, every instruction class that does not take an interrupt matches
the real 8088 on every cycle (except C6 below), including MUL/DIV (CORX/CORD
loops), string instructions with REP, shifts by CL, BCD adjusts, far
jumps/calls/returns, segment loads and prefixes. No test needed a per-opcode
timing rule.

**Missing feature: the 8088's interrupt microcode** (50,521 failures). z8086
runs the **8086** ROM. Its interrupt routine suspends prefetching before the
vector reads, where the real 8088 keeps fetching between them (SST CD test 0:
a code fetch between the two vector words; the 8086 routine's first vector
read comes 3 clocks late). Jenner: the 8088's routine differs ("one INTA
access, split by the BIU", entry 0x19E; "the other changes seem to be
fallout"). An experiment entering at 0x19E in the 8086 ROM (skipping its
SUSP) does not match either (first read 2 clocks late, INT 3 state wrong):
the 8088's words are needed, not a different entry. No public dump of the
8088 ROM was found; Shirriff photographed it, and Jenner's XTCE reads it from
bit images that are not in his public repository. With the 8088 ROM this
category should go the way of the rest, since the INT tests' bus cycles are
otherwise ordinary reads and writes.

**BIU: C6 MOV r/m8,imm8** (307): the write starts a clock early for some
[bp+di]/[bx+si] forms. The same 307 tests fail with MCL86 (run y5), so it is
in biu88's request timing, not in either EU. XTCE delays an I/O request by an
extra clock when a prefetch could start (`stateIODelay2`); worth comparing
with biu88's address-cycle rules.

**Not exercised by the suite / not done in the prototype:** INTR/NMI (biu88's
BIU_INTR and the INTA request are there; the 8086 ROM would make two INTA
requests, i.e. four INTA cycles on the 8088 bus), LOCK, HLT's bus status, WAIT
and TEST, the trap flag's timing, the 8086's "interrupt after MOV SS / POP
SS / prefix" rule (z8086 has a version of it), the system board (tb/sys).

## 6. Size and speed (Vivado 2022.2, xc7a200t-2, out of context, placed and routed)

| design | LUTs | FFs | BRAM tiles | clock | WNS |
|---|---|---|---|---|---|
| z86_eu alone, ce = 1 (every clock a microinstruction) | 1,541 | 534 | 0.5 (the 512 x 21 ROM) | 10.0 ns | -0.319 ns: **~97 MHz** single-cycle |
| cpu_z86 = z86_eu + adapter + biu88, cpu8088.xdc's multicycle paths | 4,324 (EU 1,501, biu88 2,820) | 2,333 | 0.5 | 9.977 ns (100.2273 MHz) | -0.406 ns (an EU-internal path: ALU -> IND, 23 levels) |
| main's cpu8088 = MCL86 EU + biu88 (`~/pcxt-work/ooc/cpuy-a`) | 3,126 (EU 761, biu88 2,408) | 2,228 | 8 (8K x 32 microcode) | 9.977 ns | +0.387 ns |

- The EU's paths are one-clock paths only because the OOC run gives it a clock
  enable every clock. Behind biu88 its registers change once per 8088 clock,
  so at 100 MHz they are 20-21-clock multicycle paths (one constraint), and
  on a 28.636 MHz master clock (enable every 6 / 4 / 3 clocks for 4.77 /
  7.16 / 9.54 MHz) the EU closes with ~3x margin as a plain single-cycle
  design.
- biu88 is the part that needs 100 MHz: it was built to serve MCL86's
  100 MHz EU on any core clock (fast part, candidate registers, the
  `bd*/sn_*/p1_*` window). With an EU that acts once per 8088 clock, most of
  that machinery has nothing left to do.

## 7. Recommendation

**Adopt the z8086 approach - Intel's microcode at one microinstruction per
CPU clock - as the base of the faithful EU.** Measured here:
- the timing is the microcode's own: after six structural corrections (none
  instruction-specific) every non-interrupt instruction class matches the
  8088 on every cycle; MCL86 needed two days of per-instruction tuning for
  the same and still runs the next instruction 1-4 clocks late in real code
  (the tb/sys stop at clock 2,439,285, history 2026-10-22), which this EU
  cannot do by construction: the loader reads the next opcode exactly when
  the microcode says;
- it needs no 100 MHz: one microinstruction per 8088 clock, ~97 MHz
  single-cycle Fmax alone, 4.77/7.16/9.54 MHz (and the turbo modes) are just
  enable rates of a 28.636 MHz clock;
- it is small: 1.5 k LUTs and half a BRAM tile against MCL86's 8 BRAM tiles.

Work that remains:
1. **The 8088 microcode ROM** (interrupt routine). Needed for INT/INTO/divide
   errors (50,521 SST failures) and for INTR (INTA count). Sources: Shirriff's
   8088 ROM photo (transcription), or Jenner's 8088 bit images (XTCE's
   `l0..r3.txt` + `translation_8088.txt`; not public). Then the 8088's
   translation entries (INTR at 0x19E).
2. **Rule 4 decision.** The core cannot work without Intel's microcode (and
   uses reconstructions of the group/translation ROMs). Either the ROM image
   stays outside the repository and is loaded at run time (QNICE from the SD
   card, like the BIOS) or rule 4 changes. fx68k ships the 68000's microcode
   the same way z8086 does.
3. **A native EU/BIU interface in biu88.** Drop the MCL86 layer (strobes,
   taken bytes, end counters, releases, scheduled reads) and the per-core-clock
   fast part; drive biu88 from the EU's clock enable with queue read, request
   (segment/offset/word/write), done/T-state and the XTCE resume rule. That
   removes the 100 MHz requirement for the whole CPU. MartyPC's BIU model
   (what biu88 follows) and XTCE's (what the EU's resume rule follows) should
   be cross-checked there (the C6 case).
4. **The EU itself:** wire INTR/NMI/INTA, LOCK, HLT bus status, WAIT/TEST,
   the trap flag; review z8086's remaining simplifications (`writes_memory` is
   no longer used for RNI/NX but still computed; POPF's high nibble; the
   interrupt delay rule); a microcode-level comparison against XTCE
   (`xtce_microcode.h`, The Unlicense) cycle by cycle, which is the reference
   for every point in section 2.
5. **System test:** tb/sys against the MartyPC trace, where MCL86 stops.

Not adopting it would mean continuing MCL86's hand timing per instruction
and keeping a 100 MHz EU, neither of which the real machine has.
