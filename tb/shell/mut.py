#!/usr/bin/env python3
# mut.py - mutants of CORE/vhdl/pc_drvsnd.vhd against tb_drvsnd.vhd (ghdl), of
# CORE/vhdl/pc_chipset.vhd against tb_chipset.vhd and of the
# firmware's settings file signature (CORE/m2m-rom/m2m-rom.asm) against run_cfgsig.sh (QNICE
# emulator). Every mutant must be killed: the bench reports FAIL, or the simulation stops
# with an error (a counter leaving its range counts as killed). Run from anywhere.
import os, subprocess, sys, tempfile

H = os.path.dirname(os.path.abspath(__file__))
R = os.path.abspath(os.path.join(H, '..', '..'))
DUT = os.path.join(R, 'CORE', 'vhdl', 'pc_drvsnd.vhd')
TB = os.path.join(H, 'tb_drvsnd.vhd')

MUT = [
    ('no_homing',     "                  if known = '0' then", "                  if false then"),
    ('idle_any_step', "                  elsif drv_step_i = '1' then", "                  elsif true then"),
    ('home_no_trk0',  "                     if trk0_s = '0' or home_cnt = G_HOME_MAX then",
                      "                     if home_cnt = G_HOME_MAX then"),
    ('home_no_max',   "                     if trk0_s = '0' or home_cnt = G_HOME_MAX then",
                      "                     if trk0_s = '0' then"),
    ('home_gap',      "G_HOLD - 2 then", "G_HOLD - 12 then"),
    ('no_inner_stop', "                     if cyl /= 79 then", "                     if cyl /= 78 then"),
    ('no_outer_stop', "                  elsif cyl /= 0 then", "                  elsif true then"),
    ('no_resync',     "                     cyl <= 0;                          -- the drive is at track 0",
                      "                     null;"),
    ('no_last_out',   "                  elsif trk0_s = '0' and last_out = '1' then",
                      "                  elsif trk0_s = '0' then"),
    ('dir_inward',    "                        dir      <= '0';", "                        dir      <= '1';"),
    ('no_settle_wait',"               elsif v_ok then", "               elsif true then"),
    ('motor_stopped', " or (homing = '0' and v_mot = '0') then", " then"),
    ('pulse_short',   "               if cnt = G_PULSE - 1 then", "               if cnt = G_PULSE - 2 then"),
    ('setup_short',   "               if cnt = G_DIR_SETUP - 1 then", "               if cnt = G_DIR_SETUP - 2 then"),
    ('hold_short',    "               if cnt = G_HOLD - 1 then", "               if true then"),
    ('pulse_unsel',   "            v_sel := '1';                               -- a pulse that was counted ends",
                      "            null;"),
    ('dsk_noblock',   "(drv_motor_i(0) or drv_motor_i(1)) and not disk;", "(drv_motor_i(0) or drv_motor_i(1));"),
    ('dsk_noprobe',   "         if disk = '1' and tmr(G_TMR_BITS - 1 downto G_PRB_BITS) = 0 then",
                      "         if false then"),
    ('dsk_period',    "         if disk = '1' and tmr(G_TMR_BITS - 1 downto G_PRB_BITS) = 0 then",
                      "         if disk = '1' then"),
    ('dsk_inv',       "               v_disk := chg_s;", "               v_disk := not chg_s;"),
    ('dsk_nosettle',  "            if settle /= G_SETTLE then", "            if false then"),
    ('dsk_unselected',"         if v_sel = '1' and sel_n = '0' then", "         if true then"),
    ('dsk_noabort',   "               if sound_i = '0' or v_disk = '1' or", "               if sound_i = '0' or"),
    ('off_motor',     "         v_mot := sound_i and (", "         v_mot := ("),
    ('off_select',    "         v_sel := v_sel and sound_i;", "         null;"),
    ('led_a_only',    "   led_o     <= drv_select_i(0) or drv_select_i(1);", "   led_o     <= drv_select_i(0);"),
    ('led_green',     "   led_col_o <= x\"FFFF00\";", "   led_col_o <= x\"00FF00\";"),
]

CS = os.path.join(R, 'CORE', 'vhdl', 'pc_chipset.vhd')
CS_TB = os.path.join(H, 'tb_chipset.vhd')
CS_MUT = [
    ('cs_no_restart', "   rst_o     <= '1' when cnt /= 0 or (not xt_i) /= fe else '0';",
                      "   rst_o     <= '0';"),
    ('cs_no_stretch', "            cnt <= (others => '1');", "            cnt <= (others => '0');"),
    ('cs_late',       "   rst_o     <= '1' when cnt /= 0 or (not xt_i) /= fe else '0';",
                      "   rst_o     <= '1' when cnt /= 0 else '0';"),
    ('cs_sw_swapped', "   dip_sw1_o <= G_SW1_FE when fe = '1' else G_SW1_XT;",
                      "   dip_sw1_o <= G_SW1_XT when fe = '1' else G_SW1_FE;"),
    ('cs_sw_fixed',   "   dip_sw1_o <= G_SW1_FE when fe = '1' else G_SW1_XT;", "   dip_sw1_o <= G_SW1_FE;"),
    ('cs_default_xt', "   signal fe   : std_logic := '1';", "   signal fe   : std_logic := '0';"),
    ('cs_count_once', "         elsif cnt /= 0 then", "         elsif cnt = 1 then"),
]


def run_cs(dut_path, work):
    os.makedirs(work, exist_ok=True)
    cmd = ('ghdl -a --std=08 "{d}" "{t}" && ghdl -e --std=08 tb_chipset && '
           'ghdl -r --std=08 tb_chipset').format(d=dut_path, t=CS_TB)
    p = subprocess.run(['bash', '-c', cmd], cwd=work, capture_output=True, text=True)
    return 'CHIPSET TB: PASS' in p.stdout + p.stderr and p.returncode == 0

FW = os.path.join(R, 'CORE', 'm2m-rom', 'm2m-rom.asm')
FW_MUT = [
    ('sig_always',    "                RBRA    _CFGSC_OK, Z", "                RBRA    _CFGSC_OK, 1"),
    ('sig_inverted',  "                RBRA    _CFGSC_OK, Z", "                RBRA    _CFGSC_OK, !Z"),
    ('sig_no_set',    "                RSUB    CFGS_SET, 1", "                NOP"),
    ('sig_short_buf', "                MOVE    4, R10\n                RSUB    CFGS_GET, 1",
                      "                MOVE    2, R10\n                RSUB    CFGS_GET, 1"),
    ('sig_no_leave',  "_CFGSC_OK       SYSCALL(leave, 1)", "_CFGSC_OK       NOP"),
]


def run_fw(path):
    p = subprocess.run([os.path.join(H, 'run_cfgsig.sh'), path], capture_output=True, text=True)
    return 'CFGSIG TEST: PASS' in p.stdout


def run(dut_path, work):
    os.makedirs(work, exist_ok=True)
    cmd = ('ghdl -a --std=08 "{d}" "{t}" && ghdl -e --std=08 tb_drvsnd && '
           'ghdl -r --std=08 tb_drvsnd --ieee-asserts=disable --stop-time=50ms').format(d=dut_path, t=TB)
    p = subprocess.run(['bash', '-c', cmd], cwd=work, capture_output=True, text=True)
    out = p.stdout + p.stderr
    return 'DRIVE SOUND TB: PASS' in out and p.returncode == 0


def main():
    src = open(DUT).read()
    with tempfile.TemporaryDirectory() as tmp:
        if not run(DUT, os.path.join(tmp, 'orig')):
            print('the original does not pass'); return 1
        killed = 0
        for name, a, b in MUT:
            n = src.count(a)
            if n != 1:
                print('%-15s pattern found %d times' % (name, n)); return 1
            p = os.path.join(tmp, name + '.vhd')
            open(p, 'w').write(src.replace(a, b))
            ok = run(p, os.path.join(tmp, name))
            print('%-15s %s' % (name, 'SURVIVED' if ok else 'killed'))
            killed += not ok
        print('pc_drvsnd mutants: %d of %d killed' % (killed, len(MUT)))
        csrc = open(CS).read()
        if not run_cs(CS, os.path.join(tmp, 'cs_orig')):
            print('the chipset bench does not pass'); return 1
        ck = 0
        for name, a, b in CS_MUT:
            if csrc.count(a) != 1:
                print('%-15s pattern found %d times' % (name, csrc.count(a))); return 1
            p = os.path.join(tmp, name + '.vhd')
            open(p, 'w').write(csrc.replace(a, b))
            ok = run_cs(p, os.path.join(tmp, name))
            print('%-15s %s' % (name, 'SURVIVED' if ok else 'killed'))
            ck += not ok
        print('pc_chipset mutants: %d of %d killed' % (ck, len(CS_MUT)))
        fsrc = open(FW).read()
        if not run_fw(FW):
            print('the firmware test does not pass'); return 1
        fk = 0
        for name, a, b in FW_MUT:
            if fsrc.count(a) != 1:
                print('%-15s pattern found %d times' % (name, fsrc.count(a))); return 1
            p = os.path.join(tmp, name + '.asm')
            open(p, 'w').write(fsrc.replace(a, b))
            ok = run_fw(p)
            print('%-15s %s' % (name, 'SURVIVED' if ok else 'killed'))
            fk += not ok
        print('firmware signature mutants: %d of %d killed' % (fk, len(FW_MUT)))
        return 0 if killed == len(MUT) and ck == len(CS_MUT) and fk == len(FW_MUT) else 1


sys.exit(main())
