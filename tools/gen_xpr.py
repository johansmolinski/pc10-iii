#!/usr/bin/env python3
"""Generate CORE/CORE-R<n>.xpr from a Megamiga CORE-R<n>.xpr (the framework file list).

Keeps the project settings, the run strategies, the synth_pre.tcl hook, the constraint set and
every source under M2M/ (the vendored framework), drops Megamiga's own sources (CORE/vhdl,
Minimig) and adds the PC10-III sources below. Megamiga hard rule 2: SFType only VHDL2008,
SVerilog or none.

  tools/gen_xpr.py <Megamiga CORE-R6.xpr> CORE/CORE-R6.xpr
"""
import re, sys

CORE_FILES = [  # (path relative to CORE/, SFType)
    ("vhdl/globals.vhd",  "VHDL2008"),
    ("vhdl/config.vhd",   "VHDL2008"),
    ("vhdl/clk.vhd",      "VHDL2008"),
    ("vhdl/keyboard.vhd", "VHDL2008"),
    ("vhdl/pc_ram.vhd",   "VHDL2008"),
    ("vhdl/pc_bios.vhd",  "VHDL2008"),
    ("vhdl/main.vhd",     "VHDL2008"),
    ("vhdl/mega65.vhd",   "VHDL2008"),
    ("stub/pc_system.sv", "SVerilog"),
]

src, dst = sys.argv[1], sys.argv[2]
x = open(src).read()

m = re.search(r'(<FileSet Name="sources_1".*?<Filter Type="Srcs"/>\n)(.*?)(      <Config>.*?</FileSet>)', x, re.S)
head, body, tail = m.group(1), m.group(2), m.group(3)
entries = re.findall(r'      <File Path=".*?</File>\n', body, re.S)
keep = [e for e in entries if '$PPRDIR/../M2M/' in e]
for path, t in CORE_FILES:
    keep.append('      <File Path="$PPRDIR/%s">\n        <FileInfo SFType="%s">\n'
                '          <Attr Name="UsedIn" Val="synthesis"/>\n'
                '          <Attr Name="UsedIn" Val="simulation"/>\n'
                '        </FileInfo>\n      </File>\n' % (path, t))
# no Verilog include dir of Megamiga's AP68040
tail = re.sub(r'\s*<Option Name="VerilogDir"[^>]*/>', '', tail)
x = x[:m.start()] + head + "".join(keep) + tail + x[m.end():]

# the project's own path and id are rewritten by Vivado on open; give it a neutral path
x = re.sub(r'<Project Version="7" Minor="61" Path="[^"]*"',
           '<Project Version="7" Minor="61" Path="CORE-R6.xpr"', x)
for t in set(re.findall(r'SFType="([^"]*)"', x)):
    assert t in ("VHDL2008", "SVerilog"), t
open(dst, "w").write(x)
print("%s: %d framework files kept, %d core files" % (dst, len(keep) - len(CORE_FILES), len(CORE_FILES)))
