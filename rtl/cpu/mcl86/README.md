# MCL86 (MicroCore Labs), as imported

- Source: https://github.com/MicroCoreLabs/Projects, folder `MCL86/Core`,
  commit 78f3fb0eb230e014f4a53397d8577c3570681b9d (2026-08-28).
- Files: `eu.v` (rev. 3.0, 2025-09-29), `biu_max.v`, `Microcode_MCL86.txt`
  (rev. 4.0, here `microcode.txt`). `eu4kx32.v` is ours (the ROM model).
- Licence: MIT, Copyright (c) 2020 Ted Fried; the notice stays in each file.
- `microcode.hex` = `tools/mcasm.py microcode.txt`; identical to the shipped
  `MCL86_Microcode_Xilinx_Version_4.coe` at import.

From the MCL86 datasheet: the core is "cycle compatible, not cycle exact ...
within a clock or two"; MUL/DIV take a fixed mid-range time; the queue status
lines are not supported. Instruction timing comes from a cycle counter
(BIU_CLK_COUNTER_ZERO) that the microcode loads with a per-instruction count
in 100 MHz core clocks. This repository corrects it against SingleStepTests.
