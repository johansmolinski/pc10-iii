#!/usr/bin/env python3
"""Show the real 8088's schedule for an opcode file of the test suite.

  sst_sched.py XX.txt [-n N] [--all]

Works on the harness format (tb/sst/sst2txt.py). For each test it takes the
cycle in which the opcode was read as 0 (QS=F is reported one cycle later) and
lists, relative to it:
  Fn / Sn   the queue reads (cycle of the read, not of the report),
  Rn / Wn   bus cycles the EU asked for (T1 of a memory/IO read or write),
  En        the queue flush,
  end n     the read of the next instruction's first byte.
Tests with prefixes are skipped unless --all; by default only tests that
start with a full queue are used, so queue refills don't blur the pattern.
Prints the most common schedules with their counts.
"""
import collections
import sys

PREFIX = {0x26, 0x2E, 0x36, 0x3E, 0xF0, 0xF2, 0xF3}


def tests(path):
    t = None
    for line in open(path):
        tag, _, rest = line.rstrip('\n').partition(' ')
        if tag == 'T':
            t = {'name': rest.split(' ', 2)[2].strip(), 'cycles': []}
        elif tag == 'B':
            v = list(map(int, rest.split()))
            t['bytes'] = v[1:]
        elif tag == 'Q':
            t['queue'] = list(map(int, rest.split()))[1:]
        elif tag == 'c':
            f = rest.split()
            t['cycles'].append({'ale': int(f[0]) & 1, 'bus': f[7], 't': f[8],
                                'q': f[9], 'qb': int(f[10])})
        elif tag == 'E':
            yield t


def schedule(t):
    cyc = t['cycles']
    npre = 0
    for b in t['bytes']:
        if b in PREFIX:
            npre += 1
        else:
            break
    # the opcode's F is the (npre+1)-th F; reads happen one cycle earlier
    fs = [i for i, c in enumerate(cyc) if c['q'] == 'F']
    if len(fs) <= npre:
        return None
    base = fs[npre] - 1
    ev = []
    for i, c in enumerate(cyc):
        if i <= fs[npre]:
            continue
        if c['q'] in 'FSE' and c['q'] != '-':
            ev.append(f"{c['q']}{i - 1 - base}")
        if c['ale'] and c['bus'] != 'CODE':
            ev.append(f"{'W' if c['bus'] in ('MEMW', 'IOW') else 'R'}{i - base}")
    ev.append(f'end {len(cyc) - 1 - base}')
    return ' '.join(ev)


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    path = args[0]
    n = 12
    use_all = '--all' in args
    if '-n' in args:
        n = int(args[args.index('-n') + 1])
    cnt = collections.Counter()
    names = {}
    for t in tests(path):
        if not use_all:
            if not t['queue'] or t['bytes'][0] in PREFIX:
                continue
        s = schedule(t)
        if s is None:
            continue
        cnt[s] += 1
        names.setdefault(s, t['name'])
    total = sum(cnt.values())
    for s, c in cnt.most_common(n):
        print(f'{c:6d} {100.0 * c / total:5.1f}%  {s:50s}  e.g. {names[s]}')
    print(f'{total} tests, {len(cnt)} schedules')


if __name__ == '__main__':
    main()
