#!/usr/bin/env python3
"""Convert a MartyPC CPU trace into the pc10-iii normalized reference format.

    marty2norm.py [-o OUT] [--max N] TRACE          (CycleText trace)
    marty2norm.py --itrace [-o OUT] TRACE           (Instruction trace)

TRACE may be gzip-compressed (.gz). Output to stdout without -o.
Formats: doc/martypc-reference.md.

Cycle format, one line per 8088 clock:

    <clk> <T> <bus> <addr> <data> qs<n> [x] [nr] [dma=<st>] [@CCCC:IIII <disasm>]

  clk   0 = T1 of the first code fetch after reset (FFFF:0000 -> FFFF0)
  T     Ti T1 T2 T3 Tw T4
  bus   CODE MEMR MEMW IOR IOW INTA HALT, '-' in Ti (latched at T1, held to T4)
  addr  20-bit address latch (hex); only meaningful in T1..T4
  data  byte transferred by this bus cycle, on every T1..T4 line of it;
        '--' in Ti and for cycles without a data transfer (INTA, HALT)
  qs    8088 QS code as seen on the pins in this clock:
        0 idle, 1 first byte (F), 2 queue flush (E), 3 subsequent byte (S)
  x     this is the transfer clock (T3, or the last Tw)
  nr    READY low in this clock (wait states pending)
  dma   refresh DMA state when not idle: DREQ HRQ HLDA S1 S2 S3 S4 END
  @     on qs1 lines: CS:IP and disassembly of the instruction just started

Instruction format (--itrace), one line per instruction, registers BEFORE
the instruction (as tb/sys/sys_run.cpp -i writes them, minus the time):

    CCCC:IIII AX=.... BX=.... CX=.... DX=.... SP=.... BP=.... SI=.... DI=.... DS=.... ES=.... SS=.... F=.... ; <disasm>
"""
import argparse
import gzip
import re
import sys

# MartyPC CycleText (cpu_808x/logging.rs, cycle_state_string, short = false):
# 00000012:0005   [FFFF1] CS R0. M:R.. I:... |00 00| CODE T2 | CODE Tr CODE T2 | <-r 00 | None    | Normal     | F0 [        ] <-q EA | 1E8: ... | [FFFF:0000] jmpf F000h:E05Bh (5)
CYC = re.compile(
    r"^(\d+):(\d+) (A:| {2})\[([0-9A-F]{5})\] (..) ([R.])(\d+)([x.]) "
    r"M:([R.])([A.])([W.]) I:([R.])([A.])([W.]) \|([^|]*)\| (\w+) +(T\w) \|"
    r"[^|]*\| (<-r [0-9A-F]+|w-> [0-9A-F]+| {6}) \|[^|]*\|[^|]*\| ([ FSE])(\d+)([ *])\[")
INSTR = re.compile(r"\| \[([0-9A-F]{4}):([0-9A-F]{4})\] (.*?) \((\d+)\) *(?:;.*)?$")
QS = {" ": 0, "F": 1, "E": 2, "S": 3}
BUSNAME = {"CODE": "CODE", "MEMR": "MEMR", "MEMW": "MEMW", "IOR": "IOR",
           "IOW": "IOW", "INTA": "INTA", "HALT": "HALT", "PASV": "-"}


def opener(path):
    if path == "-":
        return sys.stdin
    if path.endswith(".gz"):
        return gzip.open(path, "rt", errors="replace")
    return open(path, errors="replace")


def convert_cycles(inp, out, max_clk):
    first = None          # MartyPC cycle number of clock 0
    pend = []             # lines of the bus cycle in progress: [fields..., extras]
    bus = "-"
    data = None
    n = 0

    def flush():
        nonlocal pend, data
        d = "--" if data is None else data
        for (clk, t, b, addr, qs, extra) in pend:
            dd = d if b != "-" else "--"
            out.write(f"{clk} {t} {b} {addr} {dd} qs{qs}{extra}\n")
        pend = []
        data = None

    for line in inp:
        m = CYC.match(line)
        if not m:
            continue
        (cnum, _icyc, ale, addr, _seg, rdy, _ws, xc, mr, amw, mw, ior, aiow, iow,
         dma, status, t, xfer, qop, _qlen, _pre) = m.groups()
        cnum = int(cnum)
        if first is None:
            # clock 0 = T1 of the first code fetch at FFFF0
            if not (t == "T1" and status == "CODE" and addr == "FFFF0"):
                continue
            first = cnum
            out.write(f"# martypc2norm: clock 0 = MartyPC cycle {first} (T1, CODE FFFF0)\n")
        clk = cnum - first
        if max_clk is not None and clk >= max_clk:
            break
        if t == "T1":
            flush()
            bus = BUSNAME.get(status, status)
        elif t == "Ti":
            if pend:
                flush()
            bus = "-"
        extra = ""
        if t in ("T3", "Tw") and xc == "x":
            extra += " x"
            if xfer.strip():
                data = xfer[4:]
        if rdy == ".":
            extra += " nr"
        dma = dma.strip()
        if dma and not re.match(r"^\d+ +\d+$", dma):
            extra += " dma=" + dma
        if qop == "F":
            mi = INSTR.search(line)
            if mi:
                extra += f" @{mi.group(1)}:{mi.group(2)} {mi.group(3).strip()}"
        b = bus if t != "Ti" else "-"
        pend.append((clk, t, b, addr, QS[qop], extra))
        if t == "Ti":
            flush()
        n += 1
    flush()
    return n


def convert_instr(inp, out, max_n):
    """MartyPC Instruction trace: 5 lines per instruction, registers AFTER it.
    Emit one line per instruction with the registers BEFORE it."""
    regs = dict(AX=0, BX=0, CX=0, DX=0, SP=0, BP=0, SI=0, DI=0, CS=0xFFFF, DS=0, ES=0, SS=0,
                IP=0, FLAGS=0xF002)
    head = None
    n = 0
    order = ["AX", "BX", "CX", "DX", "SP", "BP", "SI", "DI", "DS", "ES", "SS"]
    for line in inp:
        line = line.rstrip("\n")
        m = re.match(r"^([0-9a-f]{4}):([0-9a-f]{4}) (.*)$", line)
        if m:
            if head:
                out.write(head)
                n += 1
                if max_n is not None and n >= max_n:
                    return n
            r = " ".join(f"{k}={regs[k]:04X}" for k in order)
            head = f"{m.group(1).upper()}:{m.group(2).upper()} {r} F={regs['FLAGS']:04X} ; {m.group(3)}\n"
            continue
        for k, v in re.findall(r"(\w+): ([0-9a-f]{4})", line):
            regs[k] = int(v, 16)
    if head:
        out.write(head)
        n += 1
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace")
    ap.add_argument("-o", "--out")
    ap.add_argument("--itrace", action="store_true", help="input is an Instruction trace")
    ap.add_argument("--max", type=int, help="stop after N clocks (instructions with --itrace)")
    a = ap.parse_args()
    out = sys.stdout
    if a.out:
        out = gzip.open(a.out, "wt") if a.out.endswith(".gz") else open(a.out, "w")
    with opener(a.trace) as inp:
        if a.itrace:
            n = convert_instr(inp, out, a.max)
        else:
            n = convert_cycles(inp, out, a.max)
    if out is not sys.stdout:
        out.close()
    print(f"{n} lines", file=sys.stderr)


if __name__ == "__main__":
    main()
