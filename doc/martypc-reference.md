# MartyPC as a cycle reference

Status: 2026-10-21. MartyPC (Daniel Balsom, MIT licence) is a cycle-accurate
IBM PC/XT emulator whose 8088 model was validated against real chips. We run
its headless frontend on the build host and use its per-clock CPU trace as
the reference for the system simulation (`tb/sys`, `sys_run -t`).

- Source: `~/pcxt-work/ext/martypc-full`, commit `05c0d08`. Not vendored.
- Tools: `tools/martypc/`:
  - `setup_fedora.sh`: one-time build on the host;
  - `run_ref.sh`: run a BIOS and fetch the traces;
  - `remote_run.py`: run directory + config, runs on the host;
  - `marty2norm.py`: converter to the normalized format;
  - `headless-trace.patch`: our patch to MartyPC (below);
  - `sst_trace.sh`, `sst_extract.py`, `sst_annot.py`: single
    SingleStepTests through MartyPC's runner (section 7).
- Traces: `~/pcxt-work/martypc-traces/<name>/`, outside the repo.

## 1. Setup (once)

```
tools/martypc/setup_fedora.sh [~/pcxt-work/ext/martypc-full]
```

On `ssh fedora` (override with `MARTY_HOST`), it:

- installs Rust with rustup into `~/.rustup` and `~/.cargo` of the user
  (no system Rust). MartyPC's `rust-toolchain.toml` pins 1.92.0 plus the
  wasm32 target, which rustup fetches on the first build;
- installs `systemd-devel` with dnf (libudev for the `serialport` crate);
- copies the source to `/home/user/pcxt-work/ext/martypc-full` (tar over
  ssh, without `target/` and `.git/`), applies the patch;
- builds `cargo build --release -p martypc_headless` (about 30 s on 16 cores).

The result is `target/release/martypc_headless`. It takes no arguments we
need: it reads `./martypc.toml` from the current directory.

### Why the patch

At `05c0d08`, `martypc_headless` builds a machine and exits. The only mode
that runs it is **benchmark mode**: run N CPU cycles, print statistics.
Benchmark mode has two problems for us, which `headless-trace.patch`
(`run_benchmark.rs` only) fixes:

1. It never opened the trace file (`with_trace_log` was not called).
2. It skipped `Emulator::apply_config()`, so the CPU option
   `EnableWaitStates` stayed false (the default of the struct).
   - Then there are **no wait states and no DRAM refresh DMA** at all:
     `tick_dma()` is gated by `enable_wait_states`.
   - An unpatched benchmark run of GLaBIOS executes 72301 instructions in
     the first 2M clocks instead of 71180.

The patch sets these like the GUI does: power on, `pit_adjust(pit_phase)`,
`OffRailsDetection`, `EnableWaitStates(wait_states)`. It also flushes the
trace at the end and prints one `pc10-iii:` line with the effective options.

## 2. Running

```
tools/martypc/run_ref.sh -b ~/pcxt-work/bios/GLABIOS_0.4.2_8X.ROM -c 2000000
```

| Option | Effect |
|---|---|
| `-n NAME` | output directory name (default `<bios>-<clocks>`) |
| `--no-refresh` | `dram_refresh_simulation = false` |
| `--no-wait-states` | `wait_states = false` (this also stops refresh DMA) |
| `--cga-clock M` | CGA `clock_mode`: `Cycle` (default), `Dynamic`, `Character`, `Default` |
| `--no-itrace` | skip the second run that writes the instruction trace |
| `--no-raw` | do not fetch MartyPC's own cycle trace |
| `--keep` | leave the outputs in `/home/user/pcxt-work/martypc-run/NAME` on the host |

It runs MartyPC twice, once with `trace_mode = "CycleText"` and once with
`"Instruction"` (MartyPC has one trace mode per run). Both runs are
deterministic: the same options give byte-identical traces.

Output in `~/pcxt-work/martypc-traces/NAME/`:

| File | Content | Size per 1M clocks |
|---|---|---|
| `cycles.txt` | normalized cycle trace (section 4) | 29 MB |
| `instr.txt` | normalized instruction trace (section 5) | 4.2 MB (35.6k instructions) |
| `CycleText.log.gz` | MartyPC's cycle trace (section 3), gzip -1 | 13.7 MB (178 MB unpacked) |
| `martypc.toml` | the exact configuration used | |
| `pc10_ref.toml`, `romdef_pc10.toml` | the machine and ROM set definitions | |
| `run.log`, `itrace-run.log` | MartyPC's console output | |

Speed: 2M clocks take 1.4 s of emulation with the cycle trace on, about
10 s in total with conversion and transfer.

### Configuration

`remote_run.py` builds a run directory from `install/martypc.toml` with
these keys changed:

| Key | Value |
|---|---|
| `machine.config_name`, `emulator.benchmark.config_name` | `pc10_ref` |
| `machine.patch_roms` | `false` |
| `machine.turbo` | `false` |
| `machine.pit_phase` | `0` |
| `machine.cpu.dram_refresh_simulation` | `true` |
| `machine.cpu.wait_states` | `true` |
| `machine.cpu.off_rails_detection` | `false` |
| `machine.cpu.on_halt` | `"Continue"` |
| `machine.cpu.trace_on` | `true` |
| `machine.cpu.trace_mode` | `"CycleText"` / `"Instruction"` |
| `emulator.benchmark_mode` | `true` |
| `emulator.benchmark.end_condition` | `"Cycles"` |
| `emulator.benchmark.cycles` | N |

The machine `pc10_ref`:

- `Ibm5160` with 640 KB (`conventional.size = 0xA0000`, 0 memory wait
  states);
- one ISA CGA card (`clock_mode = "Cycle"`);
- Model F keyboard;
- no FDC, HDC, serial, mouse or game port.

The ROM set `pc10_bios` holds only the given image, identified by file
name, at `0x100000 - size` (F000:E000 for an 8 KB GLaBIOS).

MartyPC derives DIP switch block SW1 from this configuration: no floppy
drives, no 8087, all four RAM banks, CGA 80x25. Our `dip_sw1` must say the
same.

## 3. MartyPC's CycleText format

One line per CPU clock, written in `cycle_i()` after the clock's work and
before the T-state advances (`cpu_808x/logging.rs`, `cycle_state_string`).
Example (the QS=F clock of the first instruction):

```
00000012:0005   [FFFF1] CS R0. M:R.. I:... |00 00| CODE T2 | CODE Tr CODE T2 | <-r 00 | None    | Normal     | F0 [        ] <-q EA | <microcode>          |                  | [FFFF:0000] jmpf F000h:E05Bh (5)
```

| Field | Meaning |
|---|---|
| `00000012:0005` | MartyPC cycle number : cycle within the instruction |
| `A:` | ALE (T1 only) |
| `[FFFF1]` | address latch (stays after the bus cycle) |
| `CS` | segment status S4/S3, shown from T2 on |
| `R0.` | `R` = READY (`.` = wait states pending), wait states left, `x` = the transfer clock (T3 or last Tw) |
| `M:RAW` | 8288 MRDC, AMWC, MWTC |
| `I:RAW` | 8288 IORC, AIOWC, IOWC |
| `\|00 00\|` | idle: PIT ch1 count and clocks to the next refresh; else the DMA state `DREQ`, `HRQ`, `HLDA`, `S1`..`S4`, `END` |
| `CODE T2` | S2-S0 status pins (they go `PASV` at T3, as on the chip) and the T-state |
| `CODE Tr CODE T2` | MartyPC's two-slot view of the address/bus pipeline |
| `<-r 00` / `w-> 00` | data bus while a read/write command is active |
| `None`, `Normal` | pending EU bus request, prefetch state |
| `F0 [..]` | queue op this clock (`F`, `S`, `E`, blank), queue length, `*` = preload byte; queue contents |
| `<-q EA` | the byte the queue op took |
| `<microcode>` | address and text of the microcode line (Intel's 8088 microcode as MartyPC lists it; the converter drops it, and it must not be copied into this repo: AGENTS.md rule 4) |
| `[CS:IP] disasm (len)` | on `F` clocks: the instruction that starts |

Two non-cycle lines appear at the start (`Resetting CPU!`, `Reset CPU! CS:
FFFF IP: 0000`). Cycles 1-6 are the reset sequence; cycle 7 is T1 of the
first fetch.

Points to watch:

- **Read data.** The `<-r` value in T2 is stale. The byte is read at the
  transfer clock (`x`: T3, or the last Tw). Writes show their data from T3
  (MWTC/IOWC).
- **QS timing.** The queue op is printed one clock after the EU took the
  byte. `cycle_i` copies `queue_op` to `last_queue_op` at the end of the
  clock, so the F appears in the next line. This is what the QS pins show,
  and the same convention as our SST harness and `sys_run -t`.
- **Prefixes.** Every prefix byte gets its own `F`. `rep stosw` shows two
  `F` clocks, both labelled with the full instruction. So the number of `F`
  clocks is instructions + prefixes: 71242 vs 71180 in the first 2M clocks.
- **DMA.** The refresh DMA does not show its own bus cycles (no refresh
  address, no MEMR). The CPU lines carry the DMA state, and the CPU sits in
  Ti or in Tw while DMA holds the bus.

## 4. Normalized cycle format (`cycles.txt`)

```
<clk> <T> <bus> <addr> <data> qs<n> [x] [nr] [dma=<st>] [@CCCC:IIII <disasm>]
```

| Field | Meaning |
|---|---|
| `clk` | 0 = T1 of the first code fetch after reset (CODE FFFF0). The header line `# martypc2norm: clock 0 = MartyPC cycle 7` gives the offset to the raw trace. |
| `T` | `Ti T1 T2 T3 Tw T4` |
| `bus` | `CODE MEMR MEMW IOR IOW INTA HALT`, latched at T1 and held to T4; `-` in Ti |
| `addr` | 20-bit address latch, hex. Only meaningful in T1..T4; in Ti it is the last cycle's address. |
| `data` | the byte this bus cycle transferred, on every T1..T4 line of it; `--` in Ti and for cycles without a transfer (INTA, HALT) |
| `qs<n>` | 8088 QS code on the pins this clock: 0 idle, 1 first byte (F), 2 flush (E), 3 subsequent (S) |
| `x` | the transfer clock (T3 or the last Tw) |
| `nr` | READY low this clock: wait states pending, or DMA wait |
| `dma=` | refresh DMA state when not idle |
| `@CS:IP disasm` | on qs1 clocks: the instruction that starts (its first byte, or a prefix) |

The first 30 lines of a GLaBIOS 0.4.2 (8X) boot:

```
# martypc2norm: clock 0 = MartyPC cycle 7 (T1, CODE FFFF0)
0 T1 CODE FFFF0 EA qs0
1 T2 CODE FFFF0 EA qs0
2 T3 CODE FFFF0 EA qs0 x
3 T4 CODE FFFF0 EA qs0
4 T1 CODE FFFF1 5B qs0
5 T2 CODE FFFF1 5B qs1 @FFFF:0000 jmpf F000h:E05Bh
6 T3 CODE FFFF1 5B qs0 x
7 T4 CODE FFFF1 5B qs0
8 T1 CODE FFFF2 E0 qs0
9 T2 CODE FFFF2 E0 qs3
...
24 Ti - FFFF5 -- qs0
25 Ti - FFFF5 -- qs0
26 Ti - FFFF5 -- qs2
27 Ti - FFFF5 -- qs0
28 T1 CODE FE05B FA qs0
```

An I/O cycle (1 wait state) and a refresh:

```
344 T1 IOW 000A0 00 qs0
345 T2 IOW 000A0 00 qs0 nr
346 T3 IOW 000A0 00 qs0 nr
347 Tw IOW 000A0 00 qs0 x
348 T4 IOW 000A0 00 qs1 @F000:E084 out 83h, al
...
208530 Ti - FE125 -- qs0 dma=DREQ
208531 Ti - FE125 -- qs0 dma=HRQ
208532 Ti - FE125 -- qs0 dma=HLDA
208533 Ti - FE125 -- qs0 dma=S1
208534 Ti - FE125 -- qs2 nr dma=S2
208535 Ti - FE125 -- qs0 nr dma=S3
208536 T1 CODE FE120 E6 qs0 nr dma=S4
208537 T2 CODE FE120 E6 qs0 nr
208538 T3 CODE FE120 E6 qs0 nr
208539 Tw CODE FE120 E6 qs0 nr
208540 Tw CODE FE120 E6 qs0 x
208541 T4 CODE FE120 E6 qs0
```

### Comparing with `sys_run -t`

`sys_run -t` writes `<step> <T> <bus> <addr> <data> qs<n> <CS>:<IP>`. The
first five columns and `qs<n>` use the same names. To compare:

- **Clock offset.** Ours counts from reset release. With the 2026-10-21
  build, our step `n + 5` is reference clock `n`: T1 CODE FFFF0 is step 5.
  Align on that line, not on a fixed number.
- **Data.** Ours prints the live bus every clock (FF in T4/Ti). Compare
  data only on the reference's `x` line, or on any T1..T4 line against the
  value of that bus cycle.
- **Address.** Compare only in T1..T4.
- **CS:IP.** Ours prints the IP register every clock. The reference has
  CS:IP only on qs1 lines.

A first comparison of 47.7k clocks (0.01 s of `sys_run`) matches exactly up
to clock 346. At clock 347, after the `out 0A0h, al` I/O write with one wait
state, ours reports QS=F of the next instruction (`out 83h, al`) in the Tw
clock; MartyPC reports it one clock later, in T4.

## 5. Normalized instruction format (`instr.txt`)

MartyPC's `Instruction` trace prints five lines per instruction with the
registers **after** it:

```
ffff:0000 jmpf F000h:E05Bh
AX: 0000 BX: 0000 CX: 0000 DX: 0000
SP: 0000 BP: 0000 SI: 0000 DI: 0000
CS: f000 DS: 0000 ES: 0000 SS: 0000
IP: e05b FLAGS: f002
```

`marty2norm.py --itrace` turns that into one line per instruction with the
registers **before** it, like `sys_run -i` without the time column:

```
F000:E05D AX=0000 BX=0000 CX=0000 DX=0000 SP=0000 BP=0000 SI=0000 DI=0000 DS=0000 ES=0000 SS=0000 F=F002 ; mov ax, 731Dh
```

The first line uses the reset state (CS=FFFF, others 0, F=F002). FLAGS is
MartyPC's value: bits 15-12 read as 1 and bit 1 is 1. A REP string
instruction is one line.

## 6. What MartyPC simulates around the CPU (timing)

The CPU is clocked at 14.31818 MHz / 3 = 4.77 MHz. The PIT runs at
14.31818 / 12, i.e. one PIT tick = 4 CPU clocks. Devices are advanced
between CPU instructions; a bus access passes the clocks elapsed in the
current instruction (`instr_elapsed`), so a device can catch up first.

**Bus cycle.** T1-T4 with the 8288 commands:

- MRDC/IORC from T2.
- AMWC/AIOWC from T2; MWTC/IOWC from T3.
- The wait states are fixed at T2. READY is sampled in T3/Tw; the transfer
  happens in T3 or in the last Tw.

**Wait states** (only with `wait_states = true`):

| Access | Wait states |
|---|---|
| Memory (RAM, ROM) | 0 (`DEFAULT_WAIT_STATES`; a machine's `conventional.wait_states` adds more) |
| CGA memory B8000-BFFFF | from `WAIT_TABLE[phase]` in system ticks; the phase is the CGA's 16-hclock character phase at T2. That is 3-8 CPU clocks (`devices/cga/mmio.rs`). It needs the CGA clocked per cycle, so we use `clock_mode = "Cycle"`. |
| I/O | 1, every port (`bus/io.rs`; only an SN76489 overrides it) |
| DMA wait | 6 clocks of READY low after a refresh DMA (see below) |

**DRAM refresh** (`dram_refresh_simulation = true`, needs wait states on)
is a scheduler in the CPU core, not an 8237 model (`cycle.rs`
`tick_dma()`):

- The period comes from PIT channel 1: the reload value times 4 CPU clocks
  (the BIOS programs 18, i.e. every 72 clocks). The phase comes from the
  counter at programming time (`DramRefreshUpdate`, `pit_phase`).
- At terminal count: DREQ, then HRQ the next clock.
- HLDA when S2-S0 are passive or the CPU is in T3/Tw/T4, and LOCK is not
  active.
- Then the DMA states S1..S4. After S1, READY goes low for 6 clocks
  (`dma_wait_states = 7`, decremented in the same clock). This stretches
  the CPU's next bus cycle; above it is the two Tw of the fetch at 208536.
- DACK0 after S2; the hold ends after S4.

**Interrupts.** The PIC drives INTR. The INTA cycles are traced as bus
type `INTA` without data.

**Options that change timing** (the settings for a real 5160 first):

| Option | 5160 | Effect |
|---|---|---|
| `machine.cpu.wait_states` | `true` | false = no wait states and no refresh |
| `machine.cpu.dram_refresh_simulation` | `true` | false = no refresh DMA |
| `machine.turbo` | `false` | true = CPU at 7.16 MHz (clock factor 2 instead of 3) |
| `machine.pit_phase` | `0` | 0-3: PIT phase against the CPU clock; moves the refresh and timer phases |
| CGA `clock_mode` | `Cycle` | `Character`/`Dynamic` clock the CGA in larger steps; this may change the CGA wait-state phase |
| `conventional.wait_states` | `0` | memory wait states |
| `machine.patch_roms` | `false` | ROM-set patches can change code (not used by our ROM set) |

MartyPC's `pit_phase` is the free parameter that our `pc_clocks.sv`
reset phase corresponds to (`architecture.md` section 1).

## 7. Single SingleStepTests through MartyPC (`sst_trace.sh`)

```
tools/martypc/sst_trace.sh AA 7 [more indices...]
```

This runs single tests of `~/pcxt-work/ext/sst8088/v2/XX.json.gz` through
MartyPC's own test runner (`cpu_test/run_tests.rs`). The index is the one in
`~/pcxt-work/sst-txt/XX.txt` (`T <idx>`), i.e. the position in the JSON
file. Each trace is written to `~/pcxt-work/martypc-traces/sst/XX-IDX.txt`
and printed. Each test takes a few seconds, most of it ssh and tar.

How it works:

- `sst_extract.py` writes a JSON file with only that test, under the
  suite's name (`AA.json.gz`, `F6.6.json.gz`): the runner takes the opcode
  and group extension from the file name. It also copies `metadata.json`
  and lists the test's `cycles` array as `expected.txt`.
- The runner selects tests only by opcode range and `test_run_limit`, so
  there is one run per test.
- The run uses a second binary, `target-sst/release/martypc_headless`,
  built with `--features cpu_tests,cpu_trace_comments`. `cpu_tests` is the
  runner itself (with cycle-state collection); `cpu_trace_comments` adds
  MartyPC's BIU/EU annotations to the CycleText lines.
  `setup_fedora.sh` builds it; `sst_trace.sh` builds it if it is missing.
- `remote_run.py --tests DIR --test-opcode XX` writes the config:
  `tests.test_mode = "Run"`, the opcode range, all `test_run_validate_*`
  true, and an absolute `trace_file`. MartyPC still loads a machine and its
  ROMs before it looks at the test mode, so the run directory has the usual
  `pc10_ref` machine and BIOS; they are not used.
- The runner uses a bare CPU without wait states (`EnableWaitStates(false)`)
  and limits CX of string instructions to 0..127, as in the suite.
- `sst_annot.py` runs on the host. It removes the microcode **text** before
  anything is copied back (AGENTS.md rule 4) and aligns the clocks.

Output:

```
# test AA 7: ss stosb
# bytes: 36 AA   prefetched: no   cycles: 15
# MartyPC: PASS
  c mN   <CycleText line without the cycle number> | uc NNN | [CS:IP] instr ; COMMENTS  || exp <test cycle>
```

- `c` is the index in the test's `cycles` list. 0 is the clock whose QS
  shows the first byte (the prefix, if any): MartyPC's runner trims its
  cycle states the same way (`clean_cycle_states`). Negative `c` are the
  reset sequence and the fetches before it.
- `mN` is MartyPC's cycle number.
- `uc NNN` is the microcode line number (`---` = none, `JMP`/`RET`/`COR` =
  MartyPC's markers for jumps, returns and the IP correction routine).
- `; ...` are MartyPC's trace comments. Line N carries what the EU emitted
  between clocks N-1 and N (the EU runs between `cycle()` calls) and what the
  BIU emitted while it processed clock N. They include:
  - `BUS_BEGIN`: the EU requests a bus cycle;
  - `TR`/`TS`/`T0`/`TA`/`TD` and `AS_TR`/`AS_TS`: Ta-pipeline
    transitions;
  - `WAIT_ADDRESS` / `WAIT_ADDRESS_DONE`, `WAIT_TX`/`TX`: the EU waits for
    the address cycle or the transfer;
  - `SUSP`, `FLUSH`, `ABORT` (prefetch aborted), `DECIDE`/`FETCH_*` (the
    prefetch decision), `EXECUTE`, `RNI`.
- The pipeline column (`CODE T4 CODE T0`) shows MartyPC's two bus slots.
  The address phase of the next cycle (Tr, Ts, T0, then Td or Ta) runs in
  the second slot while the current cycle finishes.
- `exp` gives the test's cycle: status pins, T-state, the 20-bit bus value
  (multiplexed: address only in T1), MRDC/AMWC/MWTC and IORC/AIOWC/IOWC,
  data and QS.
- A `!` before `||` marks a clock where MartyPC's status, T-state or QS
  differ from the test. The MartyPC column shows the address latch, not
  the bus; its read data is stale in T2.
