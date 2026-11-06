#!/usr/bin/env python3
"""Derive CORE/CORE-R3.xpr from CORE/CORE-R6.xpr (the one gen_xpr.py makes).

Megamiga hard rule 1 (keep the .xpr files in sync): the boards' projects differ only in the
board top, the board XDC and the audio driver: R3 drives the 3.5 mm jack through max10.vhdl
(it also delivers the reset) and pcm_to_pdm.vhdl instead of R4+'s audio.vhd. Megamiga's own
CORE-R3.xpr is out of date (its file list predates the framework this repository vendors), so
the R3 project is made from ours. Run it after every gen_xpr.py run.

  tools/xpr_board.py [CORE/CORE-R6.xpr] [CORE/CORE-R3.xpr]
"""
import os, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "CORE", "CORE-R6.xpr")
dst = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "CORE", "CORE-R3.xpr")

x = open(src).read()

def sub(old, new, count=1):
    global x
    n = x.count(old)
    if n != count:
        sys.exit("xpr_board.py: %r found %d times, expected %d" % (old, n, count))
    x = x.replace(old, new)

def entry(path):
    # Megamiga hard rule 2: SFType only VHDL2008, SVerilog or none (its R3 project lists both
    # .vhdl files as VHDL2008)
    return ('      <File Path="$PPRDIR/../M2M/vhdl/controllers/M65/%s">\n'
            '        <FileInfo SFType="VHDL2008">\n'
            '          <Attr Name="UsedIn" Val="synthesis"/>\n'
            '          <Attr Name="UsedIn" Val="simulation"/>\n'
            '        </FileInfo>\n'
            '      </File>\n' % path)

sub('Path="CORE-R6.xpr"', 'Path="CORE-R3.xpr"')
sub('$PPRDIR/../M2M/vhdl/top_mega65-r6.vhd', '$PPRDIR/../M2M/vhdl/top_mega65-r3.vhd')
sub('$PPRDIR/../M2M/MEGA65-R6.xdc', '$PPRDIR/../M2M/MEGA65-R3.xdc')
sub('<Option Name="TopModule" Val="mega65_r6"/>', '<Option Name="TopModule" Val="mega65_r3"/>', 2)
sub(entry("audio.vhd"), entry("max10.vhdl") + entry("pcm_to_pdm.vhdl"))

for left in ("r6", "R6", "audio.vhd"):
    if left in x:
        sys.exit("xpr_board.py: %r still in the R3 project" % left)
open(dst, "w").write(x)
print("wrote", dst)
