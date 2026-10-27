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
3. **The CPU** is z8086's EU (`rtl/cpu/z8086/`, Apache 2.0: keep `LICENSE`
   and `NOTICE`, mark our changes "pc10-iii") with biu88 (ours). Its timing
   comes from Intel's microcode: fix the micro-architecture (the EU's loader,
   the bus interface), never add instruction-specific timing. The first CPU,
   MCL86, was removed on 2026-10-22; its story is in `doc/history.md`.
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
   **Releases** (the user's decision, 2026-10-25): the release package may
   ship the bundle as the separate file `pc10/ucode.bin` for the SD card,
   with a notice that it is Intel's property, not covered by the core's GPLv3,
   and withdrawn if Intel asks. It stays a separate file (never in the
   bitstream, never in this repository), so withdrawing it leaves the core
   untouched. The same pattern applies to Commodore's BIOS/character ROMs only
   if Commodore grants permission (asked 2026-10-25).
5. **Test data stays outside the repo** (`~/pcxt-work/`): the suite has no
   licence file, and the converted form is several GB.
6. Hardware rules from Megamiga apply once there is a bitstream: board XDC,
   timing summaries after every build, build incrementally where possible.

## Layout

- `rtl/cpu/cpu8088.sv`: the 8088 behind its max-mode pins.
- `rtl/cpu/z8086/` (doc/z8086.md): z8086's EU (`z86_eu.sv`, `alu.sv`), the
  Intel tables as RAMs (`z86_tables.sv`), the 8088 interrupt overlay
  (`z86_overlay.svh`), EU + tables + biu88 (`cpu_z86.sv`).
- `rtl/cpu/biu88.sv`: the cycle-stepped BIU (MartyPC's model), one step per
  8088 clock, the real chip's EU/BIU interface.
- `tools/mkucode.py`: the microcode bundle (rule 4).
- `tb/sst/`: `sst2txt.py` (JSON -> line format), `sst_run.cpp` (Verilator
  harness), `tb_z86.v` (wrapper; debug outputs via hierarchical references).
- `tb/sys/`: the system (`pc_system` + RAM/ROM models, a BIOS, the MartyPC
  trace comparison `tools/ctrace_diff.py`).
- `rtl/system/kf/`: kitune-san's 8237/8253/8255/8259 (changes marked
  `pc10-iii`); `tb/pit/`: the 8253's read/write byte sequence and latch
  (`make run`, mutants `mut.py`).
- `rtl/video/cga/` (cga_card.sv, cga_crtc.sv) and `tb/cga/` (Verilator TB
  with a C++ MartyPC model, `make run`, mutants `mut.py`): `doc/cga.md`.
- `rtl/video/pvc4/pvc4.sv`, `rtl/system/cbm_cfg230.sv` and `tb/pvc4/`: the
  PC10-III's onboard video (Paradise PVC4) and its 230h register:
  `doc/pvc4.md`. No Commodore ROM or character ROM content in the repository
  (the BIOS disassembly stays in `~/pcxt-work/pvc4/`).

## Harness facts

- **Clocking:** CORE_CLK 28.63636 MHz (the PC's clock, doc/clock-plan.md),
  CLK 4.7727 MHz = 6 core clocks per 8088 clock, high for 2 (1/3 duty).
  biu88 steps at `step`, the EU at `step` + 1 clk (its enable, `EU_DELAY`,
  one microinstruction per 8088 clock); each changes state only there. The harness streams the microcode bundle
  through the load port once per process (`$PC10_UCODE`).
- **Loader:** the CPU's registers come from a program served on the bus
  (POPF, MOV r16,imm, MOV sreg,AX, JMP FAR).
  - Prefetched tests (initial queue non-empty): a test-only port of biu88
    installs the queue when the loader's JMP FAR flushes it, and leaves the
    bus idle.
- **Trace window:** a test's trace runs from the cycle that reports the
  first-byte queue read (QS=F, reported one cycle after the read) to the
  cycle in which the next instruction's first byte is read.
- **Queue status:** from biu88's QS pins.
- **Sampling:** pins are sampled on the core clock before each CLK rising
  edge, because `biu88` changes them on the edge clock itself.
- **Debugging:** `sst_run -d` dumps every cycle, `+z86trace` (plusarg) one
  line per EU clock; tb/sys: `SYS_PLUSARGS="+ztrace_from=N +ztrace_to=M"`
  prints the EU per clock between trace steps N and M.
- **Flags:** the harness maps the EU's flags with `(flags & 0x0FD5) | 0xF002`
  (MCL86 kept prefix state in bits 15..12, 5, 3, 1; the EU's undefined bits
  are masked the same way).
