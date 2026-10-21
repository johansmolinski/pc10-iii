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

- `rtl/cpu/mcl86/`: the 8088. It starts as MicroCore Labs' MCL86 (MIT
  licence), which is "cycle compatible, not cycle exact" by its own
  datasheet. It is corrected against the test suite step by step.
- `tb/sst/`: the SingleStepTests harness (Verilator + C++).
- `tools/`: `mcasm.py`, the MCL86 microcode assembler.

## Testing the CPU

Needs Verilator 5, Python 3 and the test suite:

```sh
git clone https://github.com/SingleStepTests/8088 ~/pcxt-work/ext/sst8088
cd tb/sst
make convert          # JSON -> harness format, ~3.7 GB in ~/pcxt-work/sst-txt
make run              # all opcode files, one job per CPU core
./obj_dir/sst_run -f ~/pcxt-work/sst-txt/90.txt   # first failure in detail
```

Each line of `make run` gives, per opcode file:
- `state`: tests with the right registers and memory;
- `plain`: tests that start with an empty queue;
- `length` and `trace`: of those, the ones with the right cycle count and
  the right trace on every cycle.

## Licence

GPL-3.0 (see `LICENSE`), like the MiSTer2MEGA65 framework. MCL86 is MIT
licensed; its notice is kept in its sources.
