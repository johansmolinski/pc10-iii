# PC10-III for MEGA65

A cycle-exact Commodore PC10-III (IBM PC/XT compatible) core for the MEGA65,
built on the MiSTer2MEGA65 framework (the Megamiga fork of it), for all board
revisions from R3 on.

**Status: early work.** Nothing runs on a MEGA65 yet. The first step is the
CPU: a cycle-exact 8088, verified against the hardware-generated
[SingleStepTests 8088](https://github.com/SingleStepTests/8088) suite.

## Goals

- **Cycle exact or nothing.** Every bus cycle of the real machine, verified
  against hardware-generated traces, not just "runs most software".
- **The Commodore PC line**, above all the PC10-III: Faraday FE2010A
  chipset, 4.77 / 7.16 / 9.54 MHz, onboard video. An IBM 5160 + IBM CGA
  personality is the cycle-exact reference.
- **640 KB in block RAM**, so the core also runs on the R3.
- **Reusable as an island:** the same CPU, chipset and floppy controller
  are meant to become a Commodore A2088 bridgeboard inside
  [Megamiga](https://github.com/johansmolinski/Megamiga).

The full plan, with its research and open questions, is in
[doc/plan.md](doc/plan.md). The engineering log is in
[doc/history.md](doc/history.md).

## Repository

- `rtl/cpu/`: the 8088: nand2mario's z8086 execution unit (Apache 2.0) running
  Intel's own 8088 microcode, one microinstruction per 8088 clock, in front of
  `biu88`, our cycle-stepped bus interface unit ([doc/z8086.md](doc/z8086.md)).
  The microcode is not part of this repository or of the bitstream: you build
  it from your own copy of Andrew Jenner's public data (below). (The first
  CPU, MicroCore Labs' MCL86, is in the history: doc/history.md.)
- `tb/sst/`: the SingleStepTests harness (Verilator + C++).
- `rtl/video/cga/`: the IBM CGA card (MC6845, wait states, snow), timed
  after MartyPC; `tb/cga/`: its testbench (`make run`). See
  [doc/cga.md](doc/cga.md).
- `tools/`: `mkucode.py`, the microcode bundle; `ctrace_diff.py`, the cycle
  trace comparison with MartyPC.

## The 8088's microcode

The CPU needs Intel's 8088 microcode, which this project does not ship. Build
the bundle from Andrew Jenner's archive of the 8086/8088 microcode (extracted
from Ken Shirriff's die photos), once:

```sh
curl -O https://www.reenigne.org/misc/8086_microcode_v2.zip
unzip 8086_microcode_v2.zip
python3 tools/mkucode.py --jenner 8086_microcode_v2 -o ucode.bin
```

- **MEGA65:** copy `ucode.bin` to the SD card as `/pc10/ucode.bin`, next to
  `/pc10/bios.rom`. Without it (or with an invalid file) the core stops with a
  message at start-up, as without a BIOS.
- **Simulation:** the testbenches read `~/pcxt-work/ucode/8088.bin` (or
  `$PC10_UCODE`, or `make Z86_UCODE=...`).

`--cpu 8086` builds an 8086 bundle; the core then replaces the interrupt
microcode that differs on the 8088 with its own overlay (doc/z8086.md).

## Testing the CPU

Needs Verilator 5, Python 3, the microcode bundle (above) and the test suite:

```sh
git clone https://github.com/SingleStepTests/8088 ~/pcxt-work/ext/sst8088
cd tb/sst
make convert          # JSON -> harness format, ~3.7 GB in ~/pcxt-work/sst-txt
make run CPU=z86      # all opcode files, one job per CPU core
./obj_z86/sst_run -f ~/pcxt-work/sst-txt/90.txt   # first failure in detail
```

Each line of `make run` gives, per opcode file:
- `state`: tests with the right registers and memory;
- `plain`: tests that start with an empty queue;
- `length` and `trace`: of those, the ones with the right cycle count and
  the right trace on every cycle.

## Licence

GPL-3.0 (see `LICENSE`), like the MiSTer2MEGA65 framework. z8086 is Apache
2.0 (`rtl/cpu/z8086/LICENSE`, `NOTICE`); its notice is kept with its
sources.
