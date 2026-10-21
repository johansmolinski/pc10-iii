#!/usr/bin/env python3
"""Convert the testbench's PPM images to PNG. The MDA's 720x350 is shown on
a 4:3 monitor, so the window images are doubled in height (a 1:1.3 pixel)."""
import sys

from PIL import Image

for p in sys.argv[1:]:
    im = Image.open(p)
    if p.endswith('_window.ppm'):
        im = im.resize((im.width, im.height * 2), Image.NEAREST)
    im.save(p[:-4] + '.png')
