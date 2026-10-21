#!/usr/bin/env python3
"""Generate CORE/CORE-R<n>.xpr from a Megamiga CORE-R<n>.xpr (the framework file list).

Keeps the project settings, the run strategies, the synth_pre.tcl hook, the constraint set and
every source under M2M/ (the vendored framework), drops Megamiga's own sources (CORE/vhdl,
Minimig) and adds the PC10-III sources below. Megamiga hard rule 2: SFType only VHDL2008,
SVerilog or none.

  tools/gen_xpr.py [--stub] <Megamiga CORE-R6.xpr> CORE/CORE-R6.xpr
  (--stub: the shell-only stand-in CORE/stub/pc_system.sv instead of rtl/)
"""
import re, sys

import glob, os

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

def rtl(pattern):
    return sorted(os.path.relpath(f, os.path.join(ROOT, "CORE"))
                  for f in glob.glob(os.path.join(ROOT, pattern)))

VHDL = ["vhdl/globals.vhd", "vhdl/config.vhd", "vhdl/clk.vhd", "vhdl/keyboard.vhd",
        "vhdl/pc_ram.vhd", "vhdl/pc_bios.vhd", "vhdl/pc_font.vhd", "vhdl/pc_fdd_sd.vhd",
        "vhdl/main.vhd", "vhdl/mega65.vhd"]
KF_DIRS = ["KF8237", "KF8253", "KF8255", "KF8259"]
# the PC (rtl/, doc/architecture.md section 2); --stub: the shell-only stand-in instead
PC = (["../rtl/cpu/mcl86/eu.v", "../rtl/cpu/mcl86/biu88.v", "../rtl/cpu/mcl86/eu_rom.v",
       "../rtl/cpu/cpu8088.sv"]
      + [f for d in KF_DIRS for f in rtl("rtl/system/kf/%s/*.sv" % d)]
      + ["../rtl/system/pc_clocks.sv", "../rtl/system/xt_board.sv", "../rtl/system/pc_system.sv",
         "../rtl/video/cga/cga_crtc.sv", "../rtl/video/cga/cga_card.sv",
         "../rtl/fdc/upd765.sv", "../rtl/fdc/fdc_secbuf.sv", "../rtl/fdc/fdc_card.sv"])
STUB = ["stub/pc_system.sv"]
FLAT = ["sv/pc_system_flat.sv"]

def sftype(path):
    if path.endswith(".vhd"):
        return "VHDL2008"
    if path.endswith(".sv"):
        return "SVerilog"
    return None                          # .v: inferred from the extension

stub = "--stub" in sys.argv
args = [a for a in sys.argv[1:] if a != "--stub"]
CORE_FILES = [(f, sftype(f)) for f in VHDL + (STUB if stub else PC) + FLAT]

src, dst = args[0], args[1]
x = open(src).read()

m = re.search(r'(<FileSet Name="sources_1".*?<Filter Type="Srcs"/>\n)(.*?)(      <Config>.*?</FileSet>)', x, re.S)
head, body, tail = m.group(1), m.group(2), m.group(3)
entries = re.findall(r'      <File Path=".*?</File>\n', body, re.S)
keep = [e for e in entries if '$PPRDIR/../M2M/' in e]
for path, t in CORE_FILES:
    assert os.path.exists(os.path.join(ROOT, "CORE", path)), path
    keep.append('      <File Path="$PPRDIR/%s">\n        <FileInfo%s>\n'
                '          <Attr Name="UsedIn" Val="synthesis"/>\n'
                '          <Attr Name="UsedIn" Val="simulation"/>\n'
                '        </FileInfo>\n      </File>\n' % (path, ' SFType="%s"' % t if t else ""))
# no Verilog include dir of Megamiga's AP68040; ours: the KF chips' .svh files, and the
# microcode image of eu_rom.v, relative to the synthesis run directory (CORE/CORE-R6.runs/synth_1;
# build_bitstream.tcl checks that synthesis read it)
tail = re.sub(r'\s*<Option Name="VerilogDir"[^>]*/>', '', tail)
tail = re.sub(r'\s*<Define Name[^>]*/>', '', tail)
opts = "".join('\n        <Option Name="VerilogDir" Val="$PPRDIR/../rtl/system/kf/%s"/>' % d for d in KF_DIRS)
if not stub:
    opts += '\n        <Define Name="MCL86_ROM" Val="&quot;../../../rtl/cpu/mcl86/microcode.hex&quot;"/>'
tail = tail.replace("      <Config>", "      <Config>" + opts, 1)
x = x[:m.start()] + head + "".join(keep) + tail + x[m.end():]

# the project's own path and id are rewritten by Vivado on open; give it a neutral path
x = re.sub(r'<Project Version="7" Minor="61" Path="[^"]*"',
           '<Project Version="7" Minor="61" Path="CORE-R6.xpr"', x)
for t in set(re.findall(r'SFType="([^"]*)"', x)):
    assert t in ("VHDL2008", "SVerilog"), t
open(dst, "w").write(x)
print("%s: %d framework files kept, %d core files" % (dst, len(keep) - len(CORE_FILES), len(CORE_FILES)))
