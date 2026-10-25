# The default CGA font

`cga_default.hex` is the character ROM image the core uses until the user
loads a character ROM (`/pc10/char.rom`: an IBM one, 8 KB 5788005 layout or a
2 KB 8x8 dump, or the PC10-III's own Commodore 318086-xx, 16 or 32 KB).
`CORE/vhdl/pc_font.vhd` preloads its image RAM with it and copies it into the
video at power-up.

- Glyphs 00-7F: the 8x8 graphics character set of **GLaBIOS**
  (https://github.com/640-KB/GLaBIOS, commit `68c65a5`, GPL-3.0). The font
  bitmaps are by **VileR** (https://int10h.org/oldschool-pc-fonts/), licensed
  **CC BY-SA 4.0** (https://int10h.org/oldschool-pc-fonts/readme/#legal_stuff).
  This image is an adaptation of them and is under the same licence.
- 80-FF: empty (GLaBIOS has no upper half).
- 0x1000-0x17FF: the "thin" font, derived from the same glyphs (each row with
  its right edges removed); 0x0000-0x0FFF: the MDA font, the same glyphs
  stretched from 8 to 14 rows (used by the PVC4's mono personality,
  doc/pvc4.md; since 2026-10-25, zero before).

Regenerate: `tools/mkcgafont.py <GLaBIOS>/src/GLABIOS.ASM CORE/font/cga_default.hex`.
