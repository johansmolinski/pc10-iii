#!/usr/bin/env python3
"""make_release.py - package a release of the PC10-III core from a bitstream.

  make_release.py --bit FILE [--board R6] [--bit FILE --board R3 ...] --out DIR
                  [--jenner ZIP|DIR | --ucode FILE | --no-ucode]
                  [--version V] [--coretool PATH] [--no-blank-hd]
                  [--allow-dirty] [--force]

--bit and --board come in pairs, one per board (a single --bit without --board
is R6); every board's .cor and .bit go into the same package (since 0.1.1).

It checks the version (CORE_VERSION in CORE/vhdl/config.vhd: a plain release
number such as "0.1", equal to --version if given) and the bitstream (the
design of the board, the FPGA part), makes the .cor file with the MEGA65's
coretool (or bit2core), and writes

  DIR/PC10-III-<version>/                     the package, unpacked
  DIR/PC10-III-<version>-<boards>.zip         the same, zipped (boards joined
                                              by "-", e.g. R3-R6)

with these files and no others:

  PC10-III-<version>-<board>.cor   the core, for flashing a core slot (per board)
  PC10-III-<version>-<board>.bit   the bitstream, for JTAG (per board)
  pc10/ucode.bin                   the 8088 microcode bundle (AGENTS.md rule 4:
  pc10/UCODE-NOTICE.txt            Intel's property, a separate file, withdrawn
                                   if Intel asks), with its notice
  blank-hd20.img                   an empty 20 MB hard disk image for C:
  README.md, LICENSE               the core's README and licence (GPL-3.0)
  RELEASE-NOTES.md                 doc/release-<version>.md, if it exists
  tools/mkucode.py                 to build ucode.bin yourself
  tools/mkblankhd.py               to make more empty hard disks

The microcode bundle is built here from Andrew Jenner's archive
(8086_microcode_v2.zip, --jenner) with tools/mkucode.py, or taken ready-made
(--ucode); either way it must be the genuine 8088 bundle (its md5 below).
--no-ucode leaves it out (the package then needs the user's own).

Never in the package: a Commodore BIOS, character ROM or DOS disk. The core
creates its settings file (/pc10/pc10cfg) itself, so none is shipped.
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_VHD = os.path.join(REPO, "CORE", "vhdl", "config.vhd")
NOTICE = os.path.join(REPO, "tools", "release", "UCODE-NOTICE.txt")
MKUCODE = os.path.join(REPO, "tools", "mkucode.py")
MKBLANKHD = os.path.join(REPO, "tools", "mkblankhd.py")

NAME = "PC10-III"                       # file names and the name in the core menu
PART = "7a200tfbg484"                   # all MEGA65 boards from R3 on
UCODE_MD5 = "38d6a32ee095f280af7fc9c704e13d8c"   # mkucode.py --cpu 8088 of Jenner's v2
UCODE_SIZE = 6144
HD_SIZE = 615 * 4 * 17 * 512            # 21,411,840: the only size C: takes
CORETOOL_DEFAULT = os.path.expanduser("~/git/pub/mega65-tools/bin/coretool")


def die(msg):
    sys.exit("make_release: " + msg)


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def core_version():
    m = re.search(r'^\s*constant\s+CORE_VERSION\s*:\s*string\s*:=\s*"([^"]*)"\s*;',
                  open(CONFIG_VHD, encoding="latin1").read(), re.M)
    if not m:
        die("no CORE_VERSION constant in %s" % CONFIG_VHD)
    return m.group(1)


def git(*args):
    r = subprocess.run(["git", "-C", REPO] + list(args), capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def bit_header(path):
    """The fields a (design), b (part), c (date), d (time) of a Xilinx .bit file."""
    with open(path, "rb") as f:
        b = f.read(512)
    if len(b) < 13 or b[:2] != b"\x00\x09":
        die("%s: not a Xilinx bitstream" % path)
    i = 2 + 9
    i += 2                                  # 00 01
    fields = {}
    while i + 3 <= len(b):
        key = chr(b[i])
        if key == "e":
            break
        n = int.from_bytes(b[i + 1:i + 3], "big")
        fields[key] = b[i + 3:i + 3 + n].rstrip(b"\x00").decode("latin1")
        i += 3 + n
    for k in "abcd":
        if k not in fields:
            die("%s: bitstream header without field %s" % (path, k))
    return fields


def find_coretool(arg):
    if arg:
        if not os.access(arg, os.X_OK):
            die("--coretool %s is not executable" % arg)
        return ("bit2core" if os.path.basename(arg).startswith("bit2core") else "coretool"), arg
    for name in ("coretool", "bit2core"):
        p = shutil.which(name)
        if p:
            return name, p
    if os.access(CORETOOL_DEFAULT, os.X_OK):
        return "coretool", CORETOOL_DEFAULT
    die("neither coretool nor bit2core found (MEGA65 tools, https://github.com/MEGA65/mega65-tools): "
        "put one on the PATH or give --coretool")


def make_cor(tool, bit, board, version, out):
    kind, path = tool
    machine = "mega65" + board.lower()
    if kind == "coretool":
        cmd = [path, "--quiet", "--force", "--build", out, "--bit", bit, "--target", machine,
               "--bit-name", NAME, "--bit-version", version]
    else:
        cmd = [path, machine, bit, NAME, version, out]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.isfile(out):
        sys.stderr.write(r.stdout + r.stderr)
        die("%s failed" % kind)
    if kind == "coretool":
        r = subprocess.run([path, "--no-color", "--verify", out], capture_output=True, text=True)
        txt = r.stdout + r.stderr
        for want in (re.escape(machine), r"Name:\s+" + re.escape(NAME) + r"\s",
                     r"Version:\s+" + re.escape(version) + r"\s"):
            if not re.search(want, txt):
                sys.stderr.write(txt)
                die("%s: coretool --verify does not show %r" % (out, want))


def build_ucode(args, dst):
    if args.jenner:
        r = subprocess.run([sys.executable, "-I", MKUCODE, "--jenner", args.jenner,
                            "--cpu", "8088", "-o", dst], capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write(r.stdout + r.stderr)
            die("mkucode.py failed")
    else:
        shutil.copyfile(args.ucode, dst)
    r = subprocess.run([sys.executable, "-I", MKUCODE, "--check", dst], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        die("%s is not a valid microcode bundle" % dst)
    if os.path.getsize(dst) != UCODE_SIZE or md5(dst) != UCODE_MD5:
        die("%s: md5 %s, not the genuine 8088 bundle %s" % (dst, md5(dst), UCODE_MD5))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--bit", required=True, action="append",
                    help="the bitstream of a board's release build (once per board)")
    ap.add_argument("--out", required=True, help="output directory (the package and the zip go here)")
    ap.add_argument("--version", help="the release number; must equal CORE_VERSION in config.vhd")
    ap.add_argument("--board", action="append",
                    help="board revision of the --bit in the same position (default R6 for one --bit)")
    u = ap.add_mutually_exclusive_group(required=True)
    u.add_argument("--jenner", help="Jenner's 8086_microcode_v2.zip (or its unpacked directory)")
    u.add_argument("--ucode", help="a ready ucode.bin (checked against the genuine 8088 bundle)")
    u.add_argument("--no-ucode", action="store_true", help="no ucode.bin in the package")
    ap.add_argument("--coretool", help="coretool or bit2core (default: PATH, then %s)" % CORETOOL_DEFAULT)
    ap.add_argument("--no-blank-hd", action="store_true", help="no blank-hd20.img in the package")
    ap.add_argument("--allow-dirty", action="store_true",
                    help="package although the work tree has uncommitted changes (test runs)")
    ap.add_argument("--force", action="store_true", help="replace an existing package in --out")
    args = ap.parse_args()

    boards = [b.upper() for b in (args.board or ["R6"])]
    if len(boards) != len(args.bit):
        die("%d --bit but %d --board: give one --board per --bit" % (len(args.bit), len(boards)))
    for b in boards:
        if not re.fullmatch(r"R[3-6]", b):
            die("--board %s: one of R3..R6" % b)
    if len(set(boards)) != len(boards):
        die("a board twice: %s" % " ".join(boards))
    bits = sorted(zip(boards, args.bit))                # R3 before R6: the zip name, the listing

    # the version: config.vhd is the one source (welcome and help screens, core name)
    version = core_version()
    if not re.fullmatch(r"\d+\.\d+(\.\d+)?", version):
        die('CORE_VERSION "%s" in config.vhd is not a release number (e.g. "0.1")' % version)
    if args.version and args.version != version:
        die('--version %s, but config.vhd says CORE_VERSION "%s"' % (args.version, version))

    head = git("rev-parse", "--short", "HEAD") or "?"
    dirty = git("status", "--porcelain", "--untracked-files=no")
    if dirty and not args.allow_dirty:
        die("the work tree has uncommitted changes (--allow-dirty for a test):\n" + dirty)

    # the bitstreams
    hdrs = {}
    for board, bit in bits:
        if not os.path.isfile(bit):
            die("no bitstream %s" % bit)
        hdr = bit_header(bit)
        design, part = hdr["a"].split(";")[0], hdr["b"]
        if design != "mega65_" + board.lower():
            die("%s: design %s, not mega65_%s (--board?)" % (bit, design, board.lower()))
        if part != PART:
            die("%s: part %s, not %s" % (bit, part, PART))
        hdrs[board] = (design, hdr)

    tool = find_coretool(args.coretool)

    base = "%s-%s" % (NAME, version)
    final_pkg = os.path.join(os.path.abspath(args.out), base)
    final_zip = final_pkg + "-%s.zip" % "-".join(b for b, _ in bits)
    for p in (final_pkg, final_zip):
        if os.path.exists(p) and not args.force:
            die("%s exists (--force replaces it)" % p)
    # built under .part names, renamed when complete: a failed run leaves the old package
    pkg, zpath = final_pkg + ".part", final_zip + ".part"
    for p in (pkg, zpath):
        if os.path.exists(p):
            shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
    os.makedirs(os.path.join(pkg, "pc10"))
    os.makedirs(os.path.join(pkg, "tools"))

    expect = {"README.md", "LICENSE", "tools/mkucode.py", "tools/mkblankhd.py"}
    for board, bit in bits:
        core = "%s-%s" % (base, board)
        make_cor(tool, bit, board, version, os.path.join(pkg, core + ".cor"))
        shutil.copyfile(bit, os.path.join(pkg, core + ".bit"))
        expect |= {core + ".cor", core + ".bit"}
    if not args.no_ucode:
        build_ucode(args, os.path.join(pkg, "pc10", "ucode.bin"))
        shutil.copyfile(NOTICE, os.path.join(pkg, "pc10", "UCODE-NOTICE.txt"))
        expect |= {"pc10/ucode.bin", "pc10/UCODE-NOTICE.txt"}
    if not args.no_blank_hd:
        r = subprocess.run([sys.executable, "-I", MKBLANKHD, os.path.join(pkg, "blank-hd20.img")],
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write(r.stdout + r.stderr)
            die("mkblankhd.py failed")
        expect.add("blank-hd20.img")
    shutil.copyfile(os.path.join(REPO, "README.md"), os.path.join(pkg, "README.md"))
    shutil.copyfile(os.path.join(REPO, "LICENSE"), os.path.join(pkg, "LICENSE"))
    notes = os.path.join(REPO, "doc", "release-%s.md" % version)
    if os.path.isfile(notes):
        shutil.copyfile(notes, os.path.join(pkg, "RELEASE-NOTES.md"))
        expect.add("RELEASE-NOTES.md")
    shutil.copyfile(MKUCODE, os.path.join(pkg, "tools", "mkucode.py"))
    shutil.copyfile(MKBLANKHD, os.path.join(pkg, "tools", "mkblankhd.py"))

    # exactly the files above: nothing else can slip in (no ROM, no DOS)
    found = set()
    for d, _, files in os.walk(pkg):
        for f in files:
            found.add(os.path.relpath(os.path.join(d, f), pkg).replace(os.sep, "/"))
    if found != expect:
        die("package files differ from the list: extra %s, missing %s"
            % (sorted(found - expect), sorted(expect - found)))
    if "blank-hd20.img" in found:
        p = os.path.join(pkg, "blank-hd20.img")
        with open(p, "rb") as f:
            if os.path.getsize(p) != HD_SIZE or any(f.read()):
                die("blank-hd20.img is not %d zero bytes" % HD_SIZE)

    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        z.write(pkg, base)
        for rel in sorted(found):
            if "/" in rel:
                sub = base + "/" + rel.rsplit("/", 1)[0]
                if sub not in z.namelist() and sub + "/" not in z.namelist():
                    z.write(os.path.join(pkg, rel.rsplit("/", 1)[0]), sub)
            z.write(os.path.join(pkg, rel), base + "/" + rel)
    for p in (final_pkg, final_zip):
        if os.path.exists(p):
            shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
    os.rename(pkg, final_pkg)
    os.rename(zpath, final_zip)
    pkg, zpath = final_pkg, final_zip

    print("%s %s for %s: commit %s%s" % (NAME, version, " ".join(b for b, _ in bits), head,
                                         " (uncommitted changes)" if dirty else ""))
    for board, bit in bits:
        design, hdr = hdrs[board]
        print("  %s: bitstream %s (%s %s %s)" % (board, bit, design, hdr["c"], hdr["d"]))
    print("core file made with %s (%s)" % (tool[0], tool[1]))
    for rel in sorted(found):
        p = os.path.join(pkg, rel)
        print("  %-36s %10d  %s" % (rel, os.path.getsize(p), md5(p)))
    print("%s: %d bytes" % (zpath, os.path.getsize(zpath)))
    if args.no_ucode:
        print("note: no pc10/ucode.bin in the package (--no-ucode)")


if __name__ == "__main__":
    main()
