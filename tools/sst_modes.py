#!/usr/bin/env python3
"""Real schedules per addressing mode (memory operands) of an opcode file.

  sst_modes.py XX.txt

Groups the prefetched, unprefixed tests by the addressing mode in their name
([bx+si+d8] etc.) and prints each mode's most common schedule (see
sst_sched.py for the notation).
"""
import collections
import re
import sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from sst_sched import tests, schedule, PREFIX


def mode(name):
    m = re.search(r'\[(?:[a-z]s:)?([^\]]*)\]', name)
    if not m:
        return None
    s = m.group(1)
    s = re.sub(r'[+-][0-9A-F]+h', '+d', s)
    s = re.sub(r'^[0-9A-F]+h$', 'd16', s)
    return s


def main():
    by = collections.defaultdict(collections.Counter)
    disp = collections.defaultdict(set)
    for t in tests(sys.argv[1]):
        if not t['queue'] or t['bytes'][0] in PREFIX:
            continue
        md = mode(t['name'])
        if md is None:
            continue
        modrm = t['bytes'][1]
        dsz = {0: 0, 1: 1, 2: 2}[modrm >> 6] if (modrm >> 6) != 3 else 0
        if (modrm >> 6) == 0 and (modrm & 7) == 6:
            dsz = 2
        key = f'{md} d{dsz}' if dsz else md
        by[key][schedule(t)] += 1
    for k in sorted(by):
        s, c = by[k].most_common(1)[0]
        print(f'{k:12s} {c:5d}/{sum(by[k].values()):5d}  {s}')


if __name__ == '__main__':
    main()
