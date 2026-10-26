#!/usr/bin/env python3
# mut_hdc.py - mutants of the hard disk C: across power-off: CORE/m2m-rom/pc_hdc.asm (HDC_SAVE,
# HDC_RESTORE, HDC_PEND_APPLY) and its hooks in CORE/m2m-rom/m2m-rom.asm (PREP_LOAD_IMAGE,
# the SPACE eject and the pending name in HANDLE_CORE_IO) against run_hdc.sh (QNICE emulator,
# SD card image). Every mutant must be killed. Run from anywhere.
import os, subprocess, sys, tempfile

H = os.path.dirname(os.path.abspath(__file__))
R = os.path.abspath(os.path.join(H, '..', '..'))
FW = os.path.join(R, 'CORE', 'm2m-rom', 'm2m-rom.asm')
HDC = os.path.join(R, 'CORE', 'm2m-rom', 'pc_hdc.asm')

# (name, file, pattern, replacement)
MUT = [
    # PREP_LOAD_IMAGE: C: remembered or forgotten
    ('pl_no_save',    FW,  "                RSUB    HDC_SAVE, 1\n                MOVE    PC_OPTM_G_HDC, R10",
                           "                NOP\n                MOVE    PC_OPTM_G_HDC, R10"),
    ('pl_any_drive',  FW,  "                RBRA    _PCPL_RET, !Z           ; path (R8 = 0: mounted), or",
                           "                NOP"),
    ('pl_r10_lost',   FW,  "                RSUB    HDC_SAVE, 1\n                MOVE    PC_OPTM_G_HDC, R10",
                           "                RSUB    HDC_SAVE, 1\n                NOP"),
    ('pl_ok_lost',    FW,  "                XOR     R9, R9                  ; 2 = FAT32 error",
                           "                NOP"),
    # HDC_SAVE: the path
    ('sv_restoring',  HDC, "                CMP     0, @R3                  ; stays\n                RBRA    _HSV_RET, !Z",
                           "                CMP     0, @R3                  ; stays\n                NOP"),
    ('sv_empty_walk', HDC, "                RBRA    _HSV_SET, !Z            ; (C: is empty)", "                NOP"),
    ('sv_cluster_lo', HDC, "                ADD     FAT32$DE_CLUS_LO, R8\n                CMP     @R8++, R4\n",
                           "                ADD     FAT32$DE_CLUS_LO, R8\n                ADD     1, R8\n"),
    ('sv_no_parent',  HDC, "                RBRA    _HSV_DIR, Z\n                RBRA    _HSV_END, 1",
                           "                RBRA    _HSV_DONE, Z\n                RBRA    _HSV_END, 1"),
    ('sv_no_root',    HDC, "                RBRA    _HSV_DONE, Z", "                RBRA    _HSV_UP, 1"),
    ('sv_root_hi',    HDC, "                SUB     3, R8                   ; done", "                SUB     2, R8"),
    ('sv_room',       HDC, "                ADD     5, R9                   ; must not exceed the room",
                           "                ADD     4, R9"),
    ('sv_room_check', HDC, "                RBRA    _HSV_END, N             ; (R9 > R10)", "                NOP"),
    ('sv_no_slash',   HDC, "                MOVE    0x002F, @--R7", "                MOVE    0x005C, @--R7"),
    ('sv_slot',       HDC, "                ADD     0x0030, R8\n", "                ADD     0x0031, R8\n"),
    ('sv_ad_lost',    HDC, "_HSV_END        MOVE    R1, @R0++               ; the current directory back",
                           "_HSV_END        ADD     1, R0"),
    ('sv_buffer',     HDC, "                CMP     HDC_FDH, @R8\n                RBRA    _HSV_SET, !Z\n                MOVE    0, @R8",
                           "                CMP     HDC_FDH, @R8\n                RBRA    _HSV_SET, !Z\n                NOP"),
    ('sv_never_path', HDC, "                MOVE    R9, R3                  ; R3: ..or the path", "                NOP"),
    # HDC_RESTORE
    ('rs_pend_0',     HDC, "                MOVE    HDC_PEND, R3            ; R3: HDC_PEND, 1: it mounts\n                MOVE    1, @R3",
                           "                MOVE    HDC_PEND, R3            ; R3: HDC_PEND, 1: it mounts\n                MOVE    0, @R3"),
    ('rs_no_s',       HDC, "                CMP     0x0053, @R0++\n                RBRA    _HRS_ERR, !Z",
                           "                CMP     0x0053, @R0++\n                NOP"),
    ('rs_no_d',       HDC, "                CMP     0x0044, @R0++\n                RBRA    _HRS_ERR, !Z",
                           "                CMP     0x0044, @R0++\n                NOP"),
    ('rs_slot_range', HDC, "                RBRA    _HRS_ERR, N             ; (R8 > 1, also below \"0\")",
                           "                NOP"),
    ('rs_no_colon',   HDC, "                CMP     0x003A, @R0++\n                RBRA    _HRS_ERR, !Z",
                           "                CMP     0x003A, @R0++\n                NOP"),
    ('rs_no_card',    HDC, "                RSUB    SDC$MOUNT, 1            ; R8: the card's device handle\n                CMP     0, R9\n                RBRA    _HRS_ERR, !Z",
                           "                RSUB    SDC$MOUNT, 1            ; R8: the card's device handle\n                CMP     0, R9\n                NOP"),
    ('rs_open_err',   HDC, "                CMP     0, R10\n                RBRA    _HRS_ERR, !Z", "                NOP\n                NOP"),
    ('rs_pl_err',     HDC, "                MOVE    R9, R2\n                CMP     0, R8\n                RBRA    _HRS_ERR, !Z",
                           "                MOVE    R9, R2\n                CMP     0, R8\n                NOP"),
    ('rs_no_status',  HDC, "                RSUB    CRTROM_CSR_W, 1         ; (HDC_PEND)", "                NOP"),
    ('rs_reason',     HDC, "                MOVE    R2, R8\n                RSUB    SCR$PRINTSTR, 1",
                           "                MOVE    HDC_S_NF, R8\n                RSUB    SCR$PRINTSTR, 1"),
    ('rs_keep_key',   HDC, "                MOVE    1, R8                   ; no key\n                RSUB    HDC_SAVE, 1",
                           "                MOVE    1, R8                   ; no key\n                NOP"),
    ('rs_pend_left',  HDC, "_HRS_NO         MOVE    0, @R3", "_HRS_NO         NOP"),
    ('rs_handle',     HDC, "                MOVE    HANDLE_RM_FILE3, R9     ; the Shell's handle of C:",
                           "                MOVE    HDC_FDH, R9"),
    # HDC_PEND_APPLY
    ('pa_no_heap',    HDC, "                RBRA    _HPA_RET, Z             ; no menu yet", "                NOP"),
    ('pa_again',      HDC, "                MOVE    0, @R0\n                MOVE    VDRIVES_NUM, R8",
                           "                NOP\n                MOVE    VDRIVES_NUM, R8"),
    ('pa_slot',       HDC, "                ADD     2, R8\n", "                ADD     1, R8\n"),
    ('pa_no_vdrives', HDC, "                MOVE    @R8, R8                 ; submenus + 2) x OPTM_DX",
                           "                XOR     R8, R8"),
    ('pa_last_slash', HDC, "                RBRA    _HPA_S, 1", "                RBRA    _HPA_SL, 1"),
    ('pa_long',       HDC, "                SUB     1, R9                   ; R9: at most OPTM_DX - 1", "                NOP"),
    ('pa_flag',       HDC, "                MOVE    0, @--R2                ; \"%s is replaced\" := 0",
                           "                SUB     1, R2"),
    # HANDLE_CORE_IO
    ('io_no_forget',  FW,  "                RSUB    HDC_SAVE, 1             ; (R8: the device, not 0)", "                NOP"),
    ('io_any_drive',  FW,  "                CMP     2, R2                   ; C: the settings forget it",
                           "                CMP     0, R2"),
    ('io_no_apply',   FW,  "                RSUB    HDC_PEND_APPLY, 1       ; C:'s name after HDC_RESTORE", "                NOP"),
]


def run(fw, hdc):
    p = subprocess.run([os.path.join(H, 'run_hdc.sh'), fw, hdc], capture_output=True, text=True)
    return 'HDC TEST: PASS' in p.stdout


def main():
    src = {FW: open(FW).read(), HDC: open(HDC).read()}
    if not run(FW, HDC):
        print('the original does not pass'); return 1
    killed = 0
    with tempfile.TemporaryDirectory() as tmp:
        for name, f, a, b in MUT:
            n = src[f].count(a)
            if n != 1:
                print('%-15s pattern found %d times' % (name, n)); return 1
            p = os.path.join(tmp, name + '.asm')
            open(p, 'w').write(src[f].replace(a, b))
            ok = run(p if f == FW else FW, p if f == HDC else HDC)
            print('%-15s %s' % (name, 'SURVIVED' if ok else 'killed'))
            killed += not ok
    print('pc_hdc mutants: %d of %d killed' % (killed, len(MUT)))
    return 0 if killed == len(MUT) else 1


sys.exit(main())
