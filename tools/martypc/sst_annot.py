#!/usr/bin/env python3
"""Align a MartyPC CycleText trace of one SingleStepTests test with the test.

    sst_annot.py TRACE EXPECTED [RUN_LOG TEST_RUN_LOG]

TRACE: MartyPC CycleText log of a run with exactly one test.
EXPECTED: expected.txt from sst_extract.py (the test's "cycles" array).
Writes to stdout one line per MartyPC clock:

    <c> <MartyPC CycleText line, cycle number removed, microcode text removed> || <expected cycle>

c = index in the test's cycle list (0 = the clock whose QS shows the first
byte, which is where the suite's list starts; negative = reset and fetches
before it). The microcode TEXT (Intel's) is removed; only the line number
stays, as "uc NNN" (AGENTS.md rule 4). "!" before the expected cycle marks a
clock where status pins, T-state or queue op differ from the test.
"""
import re
import sys

LINE = re.compile(r"^(\d+):(\d+) (.*)$")
UC = re.compile(r"\| ([0-9A-F]{3}|JMP|RET|COR| {3}): .{34} \|")
FIELDS = re.compile(r"\|[^|]*\| (\w+) +(T\w) \|.*?\| ([ FSE])\d+[ *]\[")


def main():
    trace, expected = sys.argv[1], sys.argv[2]
    exp = []
    for l in open(expected):
        p = l.split()
        # n ale addr seg mem io bhe data status T qop qbyte
        exp.append(p)
    lines = []
    for l in open(trace, errors="replace"):
        m = LINE.match(l.rstrip("\n"))
        if not m:
            continue
        rest = m.group(3)
        u = UC.search(rest)
        if not u:
            raise SystemExit("no microcode field in: " + rest[:120])
        rest = rest[:u.start()] + "| uc %s |" % u.group(1).replace("   ", "---") + rest[u.end():]
        lines.append((int(m.group(1)), rest))
    first = None
    for i, (_, rest) in enumerate(lines):
        f = FIELDS.search(rest)
        if f and f.group(3) == "F":
            first = i
            break
    if first is None:
        raise SystemExit("no QS=F clock in the trace")
    for i, (cyc, rest) in enumerate(lines):
        c = i - first
        tail = ""
        if 0 <= c < len(exp):
            e = exp[c]
            status, t, qop = e[8], e[9], e[10]
            f = FIELDS.search(rest)
            mq = f.group(3).strip() or "-"
            mark = "  " if f and (f.group(1), f.group(2), mq) == (status, t, qop) else " !"
            tail = "%s|| exp %s %s %05X M:%s I:%s d=%02X q=%s" % (mark, status, t, int(e[2]), e[4], e[5], int(e[7]), qop)
        elif c >= len(exp):
            tail = "   || (after the test's last cycle)"
        print("%3d m%-3d %s%s" % (c, cyc, rest.rstrip(), tail))
    if len(lines) - first != len(exp):
        print("# MartyPC clocks from the first F: %d, test cycles: %d" % (len(lines) - first, len(exp)))


if __name__ == "__main__":
    main()
