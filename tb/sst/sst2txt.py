#!/usr/bin/env python3
"""Convert SingleStepTests 8088 v2 JSON files into the line format sst_run reads.

  sst2txt.py <metadata.json> <out_dir> <XX.json.gz | XX.R.json.gz>...

One output file per input (XX.txt / XX.R.txt). Per test:

  T idx flagmask name...            flagmask: flags the CPU defines (metadata)
  B n b0 b1 ...                     instruction bytes
  I ax bx cx dx cs ss ds es sp bp si di ip flags
  M n addr val ...                  initial RAM, in access order
  Q n q0 q1 ...                     initial queue (empty = not prefetched)
  F mask v ...                      final registers present (bit i = I order)
  W n addr val ...                  final RAM (changed bytes)
  C n                               then n cycle lines:
  c pins addr seg mem io data bus t qop qbyte
  E

seg/mem/io/bus/t/qop stay the strings of the JSON ("--", "R--", "CODE", "T1",
"F", ...).
"""
import gzip
import json
import os
import sys

REGS = ['ax', 'bx', 'cx', 'dx', 'cs', 'ss', 'ds', 'es',
        'sp', 'bp', 'si', 'di', 'ip', 'flags']


def flag_mask(meta, base):
    parts = base.split('.')
    ent = meta['opcodes'].get(parts[0].upper(), {})
    if len(parts) > 1 and 'reg' in ent:
        ent = ent['reg'].get(parts[1], {})
    return ent.get('flags-mask', 0xFFFF)


def convert(meta, src, out_dir):
    base = os.path.basename(src).split('.json')[0]
    tests = json.loads(gzip.open(src).read())
    mask = flag_mask(meta, base)
    lines = []
    for t in tests:
        ini, fin = t['initial'], t['final']
        lines.append(f"T {t['idx']} {mask} {t['name']}")
        lines.append('B %d %s' % (len(t['bytes']), ' '.join(map(str, t['bytes']))))
        lines.append('I ' + ' '.join(str(ini['regs'][r]) for r in REGS))
        ram = ini['ram']
        lines.append('M %d %s' % (len(ram), ' '.join(f'{a} {v}' for a, v in ram)))
        q = ini.get('queue', [])
        lines.append('Q %d %s' % (len(q), ' '.join(map(str, q))))
        fmask, fv = 0, []
        for i, r in enumerate(REGS):
            if r in fin['regs']:
                fmask |= 1 << i
                fv.append(str(fin['regs'][r]))
        lines.append(f'F {fmask} ' + ' '.join(fv))
        fram = fin['ram']
        lines.append('W %d %s' % (len(fram), ' '.join(f'{a} {v}' for a, v in fram)))
        cyc = t['cycles']
        lines.append(f'C {len(cyc)}')
        for c in cyc:
            lines.append('c ' + ' '.join(str(x) for x in c))
        lines.append('E')
    with open(os.path.join(out_dir, base + '.txt'), 'w') as f:
        f.write('\n'.join(lines) + '\n')
    return base, len(tests)


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    meta = json.load(open(sys.argv[1]))
    os.makedirs(sys.argv[2], exist_ok=True)
    for src in sys.argv[3:]:
        base, n = convert(meta, src, sys.argv[2])
        print(f'{base}: {n} tests')


if __name__ == '__main__':
    main()
