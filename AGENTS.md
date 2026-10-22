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
4. **No Intel microcode in the repository or the bitstream.** Intel's
   8086/8088 microcode and the other tables read off its die (the ROM's
   address decoder, the translation ROM, the group decode ROM) are
   copyrighted (NEC v. Intel, 1989); do not copy them into this repository,
   not even as comments, and never into a RAM's initial contents. The CPU
   (z8086's EU, doc/z8086.md) loads them at start-up from the **microcode
   bundle** that the user builds with `tools/mkucode.py` from his own copy of
   Andrew Jenner's public archive (`8086_microcode_v2.zip`; the tool contains
   no table data): on the MEGA65 `/pc10/ucode.bin` on the SD card, next to the
   BIOS (`CORE/vhdl/pc_ucode.vhd`; the PC stays in reset without a valid
   one); in simulation `~/pcxt-work/ucode/8088.bin` (`$PC10_UCODE`, or
   `make Z86_UCODE=...`). The 8088 interrupt overlay for an 8086 bundle
   (`rtl/cpu/z8086/z86_overlay.svh`) holds only our own words, derived from
   behaviour (doc/z8086.md section 5). Timing facts from the test suite,
   MartyPC (MIT), XTCE (The Unlicense) or published analyses are fine.
5. **Test data stays outside the repo** (`~/pcxt-work/`): the suite has no
   licence file, and the converted form is several GB.
6. Hardware rules from Megamiga apply once there is a bitstream: board XDC,
   timing summaries after every build, build incrementally where possible.

## Layout

- `rtl/cpu/cpu8088.sv`: the 8088; `CPU = "z86"` (default) or `"mcl86"`.
- `rtl/cpu/z8086/` (doc/z8086.md): z8086's EU (`z86_eu.sv`, `alu.sv`), the
  Intel tables as RAMs (`z86_tables.sv`), the 8088 interrupt overlay
  (`z86_overlay.svh`), EU + adapter + biu88 (`cpu_z86.sv`).
- `tools/mkucode.py`: the microcode bundle (rule 4).
- `rtl/cpu/mcl86/`:
  - eu.v (microsequencer);
  - biu88.v (our cycle-stepped BIU) and biu_max.v (the original, for
    comparison);
  - eu4kx32.v (ROM model);
  - microcode.txt / .hex.
- `tb/sst/`: `sst2txt.py` (JSON -> line format), `sst_run.cpp` (Verilator
  harness), `tb_z86.v` / `tb_mcl86_biu88.v` / `tb_mcl86.v` (wrappers; debug
  outputs via hierarchical references). `make run` runs the z86 CPU,
  `make run CPU=mcl86` (BIU=biu88/max) the old one.
- `tb/sys/`: the system; `make` builds the z86 CPU, `make CPU=mcl86` the old
  one.
- `tools/mcasm.py`: microcode assembler; `tools/mcset.py`: change words in
  the listing in place.
- `rtl/video/cga/` (cga_card.sv, cga_crtc.sv) and `tb/cga/` (Verilator TB
  with a C++ MartyPC model, `make run`, mutants `mut.py`): `doc/cga.md`.

## Harness facts

- **Clocking:** CORE_CLK 100 MHz, CLK 4.7727 MHz from a phase accumulator,
  1/3 duty. MCL86's cycle counter and BIU state numbers are tuned for that
  ratio.
- **z86:** biu88 steps at `step`, the EU at `step` + 3 clk (its enable, one
  microinstruction per 8088 clock); the harness streams the microcode bundle
  through the load port once per process (`$PC10_UCODE`). The phase sweep
  (`-S`) changes nothing for it.
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

## CPU timing mechanisms (MCL86 + biu88)

MCL86's EU is a fast microsequencer (about 21 microinstructions per 8088
clock at 100 MHz); the 8088's timing is imposed on it from these pieces.

**SYNC microinstruction** (type 0, non-zero immediate). The sequencer and
the ROM output freeze until:

| Immediate | Waits until |
|---|---|
| `0x0nnn` | cycle n of the instruction (counted from the opcode read, `BIU_CYC`) |
| `0x4nnn` | n cycles after the last queue read |
| `0x8nnn` | n cycles from now |
| `0xCnnn` | n cycles after the last EU transfer ended |

**End counter** (BIU, strobe 10). A cycle-mode load marks the end of the
instruction: when it expires, the BIU reads the next opcode itself (QS=F),
even if the EU is still busy.

| Value | End |
|---|---|
| `0xE00n` | cycle n |
| `0xF00n` | n from now |
| `0xA00n` | n after the last queue read |
| `0xB00n` | n after the next transfer ends |

Rules:
- The first end armed in an instruction stands; later loads are ignored
  until the next opcode is read.
- A flush clears it, so arm the end after the jump request (0x12B0 does
  "end at the first new byte").
- Without bit 13 the value is the old core-clock count.

**Register strobe 11** codes, pc10-iii additions (MCL86 used 0-5):
- **6, request release:** the BIU holds the EU's next bus request until n
  cycles after the base (DATAOUT 14:13: 00 last queue read, 01 transfer
  end, 10 opcode read).
- **14:** adds to the pending release.
- **7, scheduled read:** the BIU reads the next queue byte (S) at a time from
  the same bases; bit 12 = two bytes.
- Unused releases and schedules are dropped at the next opcode read.

**Request codes** added: `0x1E` = SUSP. It is done at once if no code fetch
runs or the fetch is in its T4; otherwise at its T4.

**Queue reads:**
- The EU's first use of the queue top is the read (`EU_QREAD`); MCL86's
  pops are only bookkeeping.
- Fetch procedures:
  - 0x02A0 (byte after the opcode): SYNC 2;
  - 0x02E0 (word): SYNC 2, then the high byte 1 after the low;
  - 0x02A5/0x02E5 (subsequent): 1 after the last read;
  - ModR/M entries (0x1018, armed variants 0x1060, 0x14A0, 0x1500-0x1540):
    SYNC 1.

**Microcode conventions:**
- Patch area 0x1000-0x1FFF, each block commented "pc10-iii". The original
  routines jump or call there.
- Free words below 0x1000 (unused NOP slots) are reused where they exist.
- MCL86's call stack is 4 deep: count the nesting when wrapping procedures.
- eu.v compares the microcode addresses 0x0011 (initial AX/DX, OF
  override off), 0x09C9, 0x09CC, 0x0A03, 0x0A12, 0x0A46, 0x0A52, 0x0AAE,
  0x0ABA (the OF override at the ADD/ADC/SUB/SBB entries), 0x0E54, 0x0ED0,
  0x0E76, 0x0F02 (old IDIV) and 0x0F11 (restores AX/DX): never move code
  there. The F6/F7 MUL/DIV routines no longer pass 0x0F11 (AX/DX were
  captured only after a prefix).
- An ADD word (type 2) with bit 31 set adds CF as a carry-in (eu.v,
  2026-10-22): ADC, SUB, SBB in one pass.
- Every type 0 word with a non-zero immediate is a SYNC, also ones MCL86
  meant as something else (0x02B7 was one: AAD waited for cycle 0x2B9).
- r2 is free scratch around CALC_EA; wrappers pass end values in it.
- `tools/gen_muldiv.py` generates 0x1B20-0x1EB2 (MUL/IMUL/DIV/IDIV, AAM,
  AAD; `--test` runs the routines in a microcode simulator).

**Measuring:**
- `tools/sst_sched.py` (schedule per opcode) and `tools/sst_modes.py` (per
  addressing mode) give the target;
- `sst_run -S 21 -n N`: each test at the 21 positions of the 20-core-clock
  CLK periods (one in ~21): a test passes only if it passes at all of them.
  An EU that reaches a SYNC or a strobe near a clock edge passes or fails
  with the CLK phase (the plain run's phase depends on the tests before);
  `-P p` runs at one phase (0 <= p < 0.0477);
- scan the one or two free parameters with the dev build, then write the
  measured values into the listing with comments.

