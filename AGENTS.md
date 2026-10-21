# PC10-III for MEGA65 - agent notes

A cycle-exact Commodore PC10-III / IBM PC XT core for the MEGA65 on the
Megamiga fork of MiSTer2MEGA65. The plan and all research: `doc/plan.md`.
The dated engineering log: `doc/history.md` (one entry per increment: what,
why, test numbers).

## Rules

1. **Cycle exact is the bar.** A change to the CPU is good only when it does
   not lower any count of the SingleStepTests harness (`tb/sst`, `make run`).
   Record the before/after totals in `doc/history.md`.
2. **Never push** to GitHub without the user's go-ahead. Commit as
   `Johan Smolinski <johan.smolinski@gmail.com>`, no Co-Authored-By trailers.
3. **MCL86 sources** (`rtl/cpu/mcl86/`) are ours to change ("start with this
   CPU anyway and we'll correct it as we go", the user, 2026-10-21). Keep the
   MIT notice. The microcode is edited in `microcode.txt` and assembled by
   `tools/mcasm.py`; `microcode.hex` is generated, but tracked so that
   synthesis needs no Python. The unmodified upstream ROM is the Xilinx
   `MCL86_Microcode_Xilinx_Version_4.coe` (`mcasm.py --check` reproduces it
   from the original listing).
4. **No Intel microcode.** Intel's 8086 microcode is copyrighted (NEC v.
   Intel, 1989); do not copy it into this repository, not even as comments.
   Timing facts from the test suite, MartyPC (MIT) or published analyses
   are fine.
5. **Test data stays outside the repo** (`~/pcxt-work/`): the suite has no
   licence file, and the converted form is several GB.
6. Hardware rules from Megamiga apply once there is a bitstream: board XDC,
   timing summaries after every build, build incrementally where possible.

## Layout

- `rtl/cpu/mcl86/`:
  - eu.v (microsequencer);
  - biu88.v (our cycle-stepped BIU) and biu_max.v (the original, for
    comparison);
  - eu4kx32.v (ROM model);
  - microcode.txt / .hex.
- `tb/sst/`: `sst2txt.py` (JSON -> line format), `sst_run.cpp` (Verilator
  harness), `tb_mcl86.v` (wrapper; debug outputs via hierarchical
  references).
- `tools/mcasm.py`: microcode assembler; `tools/mcset.py`: change words in
  the listing in place.

## Harness facts

- **Clocking:** CORE_CLK 100 MHz, CLK 4.7727 MHz from a phase accumulator,
  1/3 duty. MCL86's cycle counter and BIU state numbers are tuned for that
  ratio.
- **Loader:** the CPU's registers come from a program served on the bus
  (POPF, MOV r16,imm, MOV sreg,AX, JMP FAR).
  - Prefetched tests (initial queue non-empty): with `biu88`, a test-only
    port installs the queue when the loader's JMP FAR flushes it, and leaves
    the bus idle. With `BIU=max` they get the state verdict only.
- **Trace window:** a test's trace runs from the cycle that reports the
  first-byte queue read (QS=F, reported one cycle after the read) to the
  cycle in which the next instruction's first byte is read.
- **Queue status:**
  - `biu88` has QS pins; the harness samples them.
  - `BIU=max` has none: the harness takes the opcode dispatch as F, and
    strobes with QS code 11 as S.
- **Sampling:** pins are sampled on the core clock before each CLK rising
  edge, because `biu88` changes them on the edge clock itself.
- **Dev loop for microcode:**
  - copy `microcode.txt`, change words with `tools/mcset.py`, assemble with
    `tools/mcasm.py`;
  - build once with
    `make OBJ=obj_dev ROMHEX=<abs path>/dev.hex obj_dev/sst_run` (the path is
    compiled in, so `rm -rf obj_dev` when it changes);
  - run single files, e.g. `./obj_dev/sst_run -f <file>`;
  - `-d` dumps every cycle with the EU events, numbered by cycle.

  A full `make run` reads the committed `microcode.hex` at each process
  start, so don't regenerate it while a full run is going.
- **Cycle counter modes** (biu88): bit 13 of the loaded value = 8088 clocks;
  bit 12 = 0 is absolute (cycle n of the instruction, 0 = the dispatch
  cycle), bit 12 = 1 is relative (n cycles from now). Without bit 13 the
  value is in 100 MHz core clocks (legacy).
- **Flags:** MCL86 keeps prefix state in flag bits 15..12, 5, 3 and 1. The
  harness maps them: `(flags & 0x0FD5) | 0xF002`.
