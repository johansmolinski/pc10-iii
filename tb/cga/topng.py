#!/usr/bin/env python3
"""Convert the testbench's PPM images to PNG (the window images doubled in
height, as a 15 kHz line looks on a 4:3 monitor)."""
import sys

from PIL import Image

for p in sys.argv[1:]:
    im = Image.open(p)
    if p.endswith('_window.ppm'):
        im = im.resize((im.width, im.height * 2), Image.NEAREST)
    im.save(p[:-4] + '.png')
