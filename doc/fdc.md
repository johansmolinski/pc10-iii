# PC10-III core - floppy disk controller

Status: 2026-10-21, branch `fdc`. RTL in `rtl/fdc/`, testbench in `tb/fdc/`.

The IBM PC/XT diskette adapter with a uPD765A-compatible controller. The
drives are disk images that the MEGA65 glue serves sector by sector. The same
765 core is meant to become the A2088's SMC 9268 later (section 8).

## 1. Files

| File | What |
|---|---|
| `rtl/fdc/fdc_card.sv` | the adapter on the card bus: I/O decode, DOR, DMA/TC handshake, the two drives' mechanics, the 1 us time base |
| `rtl/fdc/upd765.sv` | the 765: commands, MSR, status bytes, interrupts, seeks, and the synthetic disk surface (rotation, ID and data fields) |
| `rtl/fdc/fdc_secbuf.sv` | the sector buffer (2 x 512 bytes, one RAMB18) and the sector-port engine |
| `tb/fdc/fdc_run.cpp`, `tb/fdc/Makefile` | Verilator testbench: `make run` |

All on `clk` (28.63636 MHz) with enables; no other clock. About one RAMB18;
the rest is a few hundred flip-flops and the step/command logic.

## 2. The adapter (`fdc_card`)

I/O ports, decoded from SA9-SA0 with AEN = 0:

| Port | Dir | Register |
|---|---|---|
| 3F2 | W | DOR: bits 1-0 drive select, bit 2 = 0 holds the 765 in reset, bit 3 enables the DRQ2 and IRQ6 drivers, bits 7-4 motor enables A-D |
| 3F4 | R | 765 main status register |
| 3F5 | R/W | 765 data register |

Reads of other ports in 3F0-3F7 and of 3F2 leave the bus alone (the board
returns FF). The XT adapter has neither the DIR (3F7 read: disk change) nor
the CCR (3F7 write: data rate); both are AT adapter registers and come with
1.2M/1.44M support (section 7).

Wiring as on IBM's adapter:
- **Drive selection by the DOR alone.** A drive is selected when the DOR's
  select bits name it AND its motor bit is set. The 765's unit-select outputs
  are not connected: step pulses go to, and TRK0/WP/index come from, the
  DOR-selected drive, whatever unit the command names. With the motor bit off
  no drive is selected (no index pulses, no track 0).
- **READY tied high**: ST0 NR is never set, ST3 RDY always is. A drive
  without a medium gives no index pulses, so a read/write command waits
  forever, as on a real PC; the BIOS times out and resets the controller.
- **TS (two-sided)** tied high (ST3 bit 3 = 1), as MartyPC reports it.
- **TC** is the bus TC qualified by DACK2.
- **DOR bit 3** gates the DRQ2 and IRQ6 outputs only; the 765 keeps
  requesting (a masked DMA then ends in an overrun) and keeps its interrupt
  state (Sense Interrupt Status still works).
- A bus reset clears the DOR (765 held in reset, motors off) and the
  SPECIFY values; a DOR reset keeps the SPECIFY values (MartyPC).

Drive mechanics: each drive has a head position (0 after power-on) that
follows the step pulses; a 40-track drive stops at cylinder 41, an 80-track
drive at 83. `drv_80trk` sets the type per drive. The medium's geometry
(`img_tracks/heads/spt`) decides which positions carry sectors.

## 3. The 765 (`upd765`)

Commands: READ DATA (06), READ DELETED DATA (0C), WRITE DATA (05), WRITE
DELETED DATA (09), READ TRACK (02), READ ID (0A), FORMAT TRACK (0D), SEEK
(0F), RECALIBRATE (07), SENSE INTERRUPT STATUS (08), SENSE DRIVE STATUS (04),
SPECIFY (03). MT, MF and SK are honoured. Everything else, including the three
SCAN commands, is an invalid command (one result byte 0x80).

Behaviour:
- **Phases and MSR**: RQM, DIO, EXM (non-DMA execution), CB, and the four
  drive-busy bits (set from a SEEK/RECALIBRATE until its Sense Interrupt
  Status). RQM drops for `RQM_DELAY_US` (12 us) after each command and result
  byte.
- **Results**: ST0-ST3 per the data sheet. Read/write results give C, H, R, N
  of the sector after the last one transferred, using the data sheet's table
  (at EOT: C+1 R=1 without MT; with MT on head 0: H toggled, R=1; on head 1:
  C+1, H toggled, R=1). GLaBIOS's sector count relies on exactly this.
- **Termination**: TC (normal end after the current sector), EOT without MT
  (IC=01, EN), ID not found within two index pulses (ND; WC when IDs with
  another cylinder passed; MA when no ID passed at all, e.g. an unformatted
  side, FM mode on an MFM disk, a cylinder beyond the medium), overrun (OR:
  a byte not taken before the next one), write protect (NW), backend errors
  (section 5).
- **TC inside a sector**: reads stop transferring and end after the sector;
  writes fill the rest of the sector with zeros (data sheet).
- **Seeks**: one step engine per unit (overlapped seeks), step period
  (16 - SRT) x 2 ms. RECALIBRATE steps out until TRK0 or 77 steps; after 77
  steps it ends with EC (ST0 0x70|unit), the famous "recalibrate twice" case
  of 80-track drives. Seeks end with an interrupt and ST0 = 0x20|HD|US.
- **Interrupts** (MartyPC's model of the PC behaviour): a "sense" latch set
  by the reset completion and by seek ends, cleared by a valid Sense Interrupt
  Status; a result-phase interrupt cleared by reading the first result byte;
  the per-byte service interrupt in non-DMA mode. After a reset all four units
  report a ready change (ST0 0xC0..0xC3), the first Sense Interrupt Status
  drops IRQ6 and the other three stay readable. SEEK/RECALIBRATE discard
  pending ready changes.
- **Non-DMA mode** (SPECIFY ND = 1): EXM set during execution, RQM + IRQ per
  byte, overrun as in DMA mode. TC never reaches the 765 there (no DACK), so a
  non-DMA read ends with EN at EOT.
- **Head load**: a data command waits HLT x 4 ms unless the head is still
  loaded on the same unit; it unloads HUT x 32 ms after a command.
- **Deleted data**: the images have no data-address marks, every sector reads
  as normal data. READ DELETED DATA therefore sets CM (and with SK skips every
  sector); WRITE DELETED DATA writes normal data.

## 4. Timing model

What software can observe, and where it comes from:

| Item | Model | Source |
|---|---|---|
| Byte rate | one byte per 32 us (250 kbit/s MFM) | IBM PC/XT DD: 300 RPM, 250 kbit/s |
| Rotation | 6250 byte times = 200 ms per revolution, an index pulse each | 300 RPM |
| Track layout | GAP4a 80, sync 12, IAM 4, GAP1 50; per sector: ID field 22 (sync, IDAM, CHRN, CRC), GAP2 22, sync 12, DAM 4, 512 data, CRC 2, GAP3 80 (0x54 for 15, 0x6C for 18 sectors). Sector k's ID field ends 146 + 654k + 22 bytes after the index; 1:1 interleave | IBM System 34 format; the GAP3 of DOS's FORMAT |
| Sector arrival | a READ/WRITE waits for its sector's ID to come under the head; READ ID returns the next ID to pass | rotation above |
| Index count | ND/MA after the second index pulse | data sheet |
| Step rate | (16 - SRT) x 2 ms, first step at once, interrupt one period after the last step | data sheet, doubled for the 250 kbit/s clock (82077 table); MartyPC uses (SRT+1) ms |
| Head load / unload | HLT x 4 ms (0 = 512 ms), HUT x 32 ms (0 = 512 ms) | same |
| RQM after a byte | low for 12 us | data sheet note (CAL) |
| Reset | interrupt and RQM 1 ms after the DOR releases reset | MartyPC |
| Overrun | a read byte not taken when the next is assembled (32 us), a write byte not delivered when it is due | data sheet |

The time base is a 1 us enable from a phase accumulator (clk x 11/315, exact
on average, +-1 clk jitter). The real adapter has its own 16 MHz crystal, so
the FDC is asynchronous to the CPU clock anyway.

Not modelled:
- motor spin-up (index pulses start as soon as the motor bit is set) and the
  head settle time (the 765 does not wait for it either; the BIOS does);
- the drives' rotational phases (one rotation for all drives);
- CRC errors, weak bits, copy protection, non-standard track layouts: a
  formatted track always reads back in the standard layout, whatever GAP3,
  interleave or IDs FORMAT TRACK wrote (only the sector data are stored);
- the precise DRQ timing of WRITE DATA's first byte (requested at the end of
  the ID field, 38 byte times before it is needed);
- data separator / PLL behaviour, FM recording (FM commands find no IDs);
- the SCAN commands.

**Backend stalls.** The disk surface stops turning while the card waits for
the sector port (section 5). With a backend that answers within the
rotational wait (a sector arrives at most every 21 ms; prefetch hides the
rest), the timing above is exact. A slower backend stretches the rotation
(the test bench runs 25-35 ms per sector: still correct data and results,
just slower).

## 5. Sector port

The card asks the glue for whole 512-byte sectors. One transfer at a time:

| Signal | Dir (card) | Meaning |
|---|---|---|
| `sp_req` | out | a transfer is requested; held until `sp_done` (drops the clk after it) |
| `sp_write` | out | 0 = read the sector into the card, 1 = store the card's data |
| `sp_drive` | out | 0 = A:, 1 = B: |
| `sp_cyl`, `sp_head`, `sp_sector` | out | physical position (sector 1-based) |
| `sp_lba[15:0]` | out | `(cyl * heads + head) * spt + sector - 1`, from the drive's geometry inputs |
| `sp_rd_valid`, `sp_rd_data[7:0]` | in | read data, one byte per strobe, any spacing; the card never stalls them |
| `sp_wr_valid`, `sp_wr_data[7:0]` | out | write data offered by the card |
| `sp_wr_ready` | in | the glue takes the offered byte in this clk |
| `sp_done` | in | one clk: the transfer is over (read: with or after the 512th byte; write: data stored) |
| `sp_err` | in | with `sp_done`: the transfer failed |

All fields are stable while `sp_req` is high. A new request comes at the
earliest one clk after `sp_req` dropped. Write bytes come at most every
second clk. A read that ends with fewer than 512 bytes counts as failed.

Per drive inputs: `img_present`, `img_wp`, `img_tracks` (cylinders),
`img_heads` (1/2), `img_spt` (sectors per track), `drv_80trk` (the drive's
mechanics). Standard formats:

| Format | tracks | heads | spt | drive |
|---|---|---|---|---|
| 160K | 40 | 1 | 8 | 40-track |
| 180K | 40 | 1 | 9 | 40-track |
| 320K | 40 | 2 | 8 | 40-track |
| 360K | 40 | 2 | 9 | 40-track |
| 720K | 80 | 2 | 9 | 80-track |
| 1.2M / 1.44M | 80 | 2 | 15 / 18 | need 500 kbit/s (section 7) |

The glue can derive the geometry from the image size.

**Buffering.** The 765 never streams from the backend directly. Two slots:
- **Reads**: the sector is fetched into a slot when its ID matches (the
  rotation holds until the slot is full); while it is transferred, the next
  sector of a multi-sector read is prefetched into the other slot. Each
  sector reaches the DMA from the buffer at exactly the disk's byte rate.
- **Writes**: the host's bytes go into a slot at the byte rate; after the
  sector the slot is committed while the next sector fills the other slot.
  The result phase (and IRQ6) waits until every commit is acknowledged, so a
  completed WRITE DATA means the data are in the image.
- **FORMAT TRACK**: each sector's slot is filled with the fill byte and
  committed at the sector's LBA (by the R of its ID; IDs with N != 2 or R
  outside the geometry are not stored).

A failed read (`sp_err`) ends the command with IC=01, ST1 DE, ST2 DD (DOS:
"Data error"); a failed write with IC=01 and EC (DOS: "General failure").
The buffer is invalidated at the start of every command, so the glue may
change an image between commands.

## 6. What the integrator wires

In `pc_system` (card bus, `doc/architecture.md` section 3):

```systemverilog
fdc_card u_fdc (
    .clk, .reset,
    .isa_addr, .isa_dout, .isa_din(fdc_din), .isa_dsel(fdc_dsel),
    .isa_ior_n, .isa_iow_n, .isa_aen,
    .isa_ready(fdc_ready), .isa_irq(fdc_irq), .isa_drq(fdc_drq),
    .isa_dack_n, .isa_tc,           // TC active high!
    .drv_80trk, .img_present, .img_wp, .img_tracks, .img_heads, .img_spt,
    .drv_motor, .fdc_active,
    .sp_req, .sp_write, .sp_drive, .sp_cyl, .sp_head, .sp_sector, .sp_lba,
    .sp_rd_valid, .sp_rd_data, .sp_wr_valid, .sp_wr_data, .sp_wr_ready,
    .sp_done, .sp_err);
```

- `isa_din`/`isa_dsel` OR-ed with the other cards, `isa_ready` AND-ed (the
  card never waits), `isa_irq`/`isa_drq` OR-ed (the card drives IRQ6 and DRQ2
  only).
- **`isa_tc` must be active high** and valid while DACK2 and the strobe are
  low. `xt_board.sv` currently drives it with the 8237's `end_of_process_n_out`,
  which is active low: invert it there (`isa_tc = ~dma_eop`).
- **DMA memory-to-I/O cycles** (WRITE DATA, FORMAT TRACK): the card takes the
  byte from `isa_dout` during IOW. `xt_board.sv` drives
  `isa_dout = bus_wdata = dma_owns ? isa_din : cpu_dout`, so in a DMA read
  transfer the card sees its own `isa_din` instead of the memory data. In DMA
  cycles with MEMR, `isa_dout` must carry the RAM/ROM read data.
- The 5160 needs SW1 bits 1 (IPL drives present) and 7-8 (number of drives).
- Ports for `pc_system`: the drive inputs, `drv_motor`/`fdc_active` (LEDs) and
  the sector port, unchanged, so the MEGA65 glue can serve them from HyperRAM
  or the SD card (ADF-style buffering is not needed: the card buffers).

## 7. Later: AT controller, 1.2M / 1.44M

- DIR (3F7 read, bit 7 = disk change, latched at eject, cleared by a step)
  and CCR (3F7 write, data rate 500/300/250 kbit/s);
- the data rate as a run-time input: `BYTE_US` 16 (500k), 26.67 (300k, needs
  a fractional byte clock) and `TRACK_BYTES` 12500 (1.44M at 300 RPM) or
  10416 (1.2M at 360 RPM) instead of parameters; the step/head timings change
  with the rate too (the 765's clock follows the data rate on the AT);
- `img_spt` up to 18 is already handled by the layout (GAP3 0x54/0x6C).

## 8. Missing for the A2088's SMC 9268

The 9268 is a 765-compatible controller with an on-chip data separator and
write precompensation; the A2088 decodes it at the same ports. For the
bridgeboard:
- the 9268's own register map and any additions to the 765 command set must
  be checked against its data sheet (not available yet) - the core assumes
  plain 765A behaviour;
- drive B: on the A2088 is the Amiga's external drive (J4, 23-pin, through
  the Amiga's connector): its mechanics (80 tracks, 3.5") and possibly no
  READY/TS ties like IBM's; drive A: on J3;
- in Megamiga, the sector port is served by the Amiga side's SD/HyperRAM
  glue (the same protocol);
- the A2088T path through Janus (the Amiga reading PC disks via Paula) is
  separate work (doc/plan.md section 7);
- a real-flux path (Hardware Floppy + IBM MFM decoder) would replace the
  synthetic surface: the 765 would then need a byte/mark stream interface
  instead of the internal rotation model.

## 9. Verification

`tb/fdc`: `make run` builds the card with Verilator and runs `fdc_run`, which
drives the card bus like the BIOS (I/O cycles with the 5160's timing, an
8237-like single-transfer DMA model on channel 2 with DACK/TC) and serves the
sector port from in-memory images with random latency and byte spacing.
Large test data stay outside the repository: the final images go to
`~/pcxt-work/fdc/`.

Covered (each with result bytes and data compared against the image model):
reset + four Sense Interrupt Status; MSR in reset/idle/command/seek and the
RQM delay; invalid and SCAN commands; RECALIBRATE at track 0; SEEK with the
step timing (10 steps = 80.0 ms); SENSE DRIVE STATUS (T0, WP, cylinder);
READ DATA over a whole track with the byte period (32.0 us) and sector pitch
(654 bytes) measured on DRQ2; multi-track across heads; EN, ND, ND+WC, MA (FM
command); READ ID and the rotation period (the same sector read twice:
200.0 ms apart); WRITE DATA and read-back, TC inside a sector (zero padding),
write protect; FORMAT TRACK (fill byte, neighbours untouched); READ TRACK;
overrun with an unarmed DMA; DOR bit 3 gating; non-DMA read with per-byte
IRQ6 and EXM; drive B 80-track: seek 79, read, RECALIBRATE EC after 77
steps (616 ms) and the second RECALIBRATE; a 25-35 ms backend (reads and
writes); backend errors (DE+DD, EC); a single-sided medium (MA on side 1);
no medium (the command hangs, a DOR reset recovers); random seek/read/write
traffic.

A run simulates 10.4 s of PC time in about five minutes (`-s seed` varies
the backend latencies and the random traffic). Mutants that the bench
catches: the MT result table, the per-byte overrun check (the OR must come
one byte time after the first DRQ), the TC zero padding, the 77-step
recalibrate limit, the DOR bit 3 IRQ gate.

Not yet verified: Vivado synthesis (Verilator lint only), and the card inside `pc_system` with the real KF8237 and a
BIOS (GLaBIOS / IBM XT BIOS booting DOS from an image) - that needs the two
`xt_board.sv` fixes of section 6.
