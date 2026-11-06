# Provenance of the vendored framework (M2M/)

`M2M/` is the MiSTer2MEGA65 framework as modified by the **Megamiga** project
(johansmolinski/Megamiga, local checkout `~/git/pub/AExp`), copied unchanged
from its `main` branch at commit **`4dac552`** (2026-10-21, "doc: PC XT core
and A2088 bridgeboard ideas"). The base is M2M V2.0.1 (sy2002 and MJoergen,
GPL-3.0) plus Megamiga's framework exceptions (interlace, core-io-hook,
screen-center, osm-hotkey, osm-scale, raw-joyports, floppy/SDRAM/PMOD/Ethernet
pins, osm-deps, live-text, nested-submenus, rtg-framebuffer, rom-32k,
code-banks, cfg-strings, sd-host with two slots, menu-rows, line-doubler,
rtg-native-modes, ...). Each change carries an `M2M-UPSTREAM <name>` tag in
the code; the list with the reasons is in Megamiga's `AGENTS.md`.

Taken over from Megamiga's `main` since (single files, the rest stays at `4dac552`):

- `M2M/vhdl/controllers/HDMI/video_out_clock.vhd` from `b2a2f06` (2026-11-03; taken over 2026-11-06):
  Megamiga's exception 22 `hdmi-clock-reset` (upstream AExp `b6f2d98`, AExp
  issue #39). A reset takes the video-mode-change route (the backup clock
  first, then the MMCM reset and reprogramming after the release;
  `mmcm_rst <= cfg_rst`). Before, the reset button stopped the HDMI pixel
  clock under the scaler's already released output stage: static vertical
  bars on HDMI until a power cycle, VGA fine (the user's R3A, pc10-r3-b).
  Bench `tb/voc/run_voc_reset.sh` (Megamiga's `CORE/sim/video`, with its red
  control: the template's behaviour must fail).

`M2M/QNICE` is a git submodule: johansmolinski/QNICE-FPGA, branch
`fat32-fastseek`, pinned to **`78aeaac`**, the commit Megamiga `main` pins
(fast FAT32 seek, extent maps, the FAT32 write layer).

Rules:

- Leave `M2M/` as it is. A framework change that cannot be avoided follows
  Megamiga's convention: an `M2M-UPSTREAM <name>` tag at every changed place
  and an entry in `doc/m2m-shell.md` (section "Framework exceptions").
  Our own so far: `menu-rows-inline` (2026-10-27, doc/m2m-shell.md section 8).
- To update: copy Megamiga's `M2M/` again (tracked files only), move the
  submodule to the commit Megamiga pins, update the two hashes above, and
  rebuild (`tools/gen_xpr.py` regenerates `CORE/CORE-R6.xpr` from Megamiga's
  project file if the framework's file list changed).
