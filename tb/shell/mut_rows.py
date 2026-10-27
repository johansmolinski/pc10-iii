#!/usr/bin/env python3
# mut_rows.py - mutants of M2M/rom/menu_rows.asm (the row without a label: " B:%s" and
# " int. drive" on one line, hidden by OPTM_CORE_HIDE) against run_rows.sh (rows_test.asm on
# the QNICE emulator). Every mutant must be killed. Run from anywhere.
import os, subprocess, sys, tempfile

H = os.path.dirname(os.path.abspath(__file__))
R = os.path.abspath(os.path.join(H, '..', '..'))
DUT = os.path.join(R, 'M2M', 'rom', 'menu_rows.asm')

MUT = [
    ('right_edge',     "                SUB     3, R8                   ; length)",
                       "                SUB     2, R8                   ; length)"),
    ('no_hide',        "                RBRA    _OPTR_P_HID, C",
                       "                RBRA    _OPTR_P_HID, Z"),
    ('patch_width',    "                MOVE    @R7, @R8\n                SUB     1, @R8\n",
                       "                MOVE    @R7, @R8\n                SUB     2, @R8\n"),
    ('row_id_8bit',    "                AND     0x007F, R7              ; see _OPTM_ROWID in menu.asm)",
                       "                AND     0x00FF, R7              ; see _OPTM_ROWID in menu.asm)"),
    ('first_width',    "                XOR     R9, R9\n                RSUB    _OPTR_REC, 1\n                ADD     1, R6\n                RBRA    _OPTR_P_NEXT, 1\n\n_OPTR_P_LA",
                       "                MOVE    5, R9\n                RSUB    _OPTR_REC, 1\n                ADD     1, R6\n                RBRA    _OPTR_P_NEXT, 1\n\n_OPTR_P_LA"),
    ('labelless_col1', "                RBRA    _OPTR_P_FST, Z          ; line, see _OPTR_P_FST)",
                       "                RBRA    _OPTR_P_FST, 0          ; line, see _OPTR_P_FST)"),
    ('hidden_ordinal', "                RSUB    _OPTR_REC, 1\n                ADD     1, R6\n                RBRA    _OPTR_P_NEXT, 1\n\n_OPTR_P_NR",
                       "                RSUB    _OPTR_REC, 1\n                ADD     0, R6\n                RBRA    _OPTR_P_NEXT, 1\n\n_OPTR_P_NR"),
]

src = open(DUT).read()
alive = 0
with tempfile.TemporaryDirectory() as w:
    for name, a, b in MUT:
        if src.count(a) != 1:
            print('%-16s NOT FOUND' % name); alive += 1; continue
        m = os.path.join(w, 'menu_rows.asm')
        open(m, 'w').write(src.replace(a, b))
        out = subprocess.run([os.path.join(H, 'run_rows.sh'), m], capture_output=True, text=True).stdout
        killed = 'ROWS TEST: PASS' not in out
        alive += not killed
        print('%-16s %s' % (name, 'killed' if killed else 'SURVIVED'))
print('%d of %d killed' % (len(MUT) - alive, len(MUT)))
sys.exit(1 if alive else 0)
