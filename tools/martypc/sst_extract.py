#!/usr/bin/env python3
"""Copy single tests of a SingleStepTests 8088 v2 file into a new file.

    sst_extract.py SUITE_DIR XX INDEX OUTDIR

Writes OUTDIR/XX.json.gz (the same name as in the suite, so MartyPC's runner
derives opcode and group extension from it) holding test INDEX only (the
index in the file, = "T <idx>" in ~/pcxt-work/sst-txt/XX.txt), and copies
metadata.json. Prints a short header: index, name, bytes, prefetched.
"""
import gzip
import json
import os
import shutil
import sys


def main():
    suite, xx, idx, outdir = sys.argv[1], sys.argv[2].upper(), int(sys.argv[3]), sys.argv[4]
    tests = json.load(gzip.open(os.path.join(suite, xx + ".json.gz"), "rt"))
    t = tests[idx]
    os.makedirs(outdir, exist_ok=True)
    with gzip.open(os.path.join(outdir, xx + ".json.gz"), "wt") as f:
        json.dump([t], f)
    shutil.copy(os.path.join(suite, "metadata.json"), outdir)
    with open(os.path.join(outdir, "expected.txt"), "w") as f:
        for n, c in enumerate(t["cycles"]):
            f.write("%d %s\n" % (n, " ".join(str(v) for v in c)))
    print("# test %s %d: %s" % (xx, idx, t["name"]))
    print("# bytes: %s   prefetched: %s   cycles: %d" % (
        " ".join("%02X" % b for b in t["bytes"]),
        "yes (queue %s)" % " ".join("%02X" % b for b in t["initial"]["queue"]) if t["initial"]["queue"] else "no",
        len(t["cycles"])))


if __name__ == "__main__":
    main()
