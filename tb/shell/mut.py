#!/usr/bin/env python3
# mut.py - mutants of CORE/vhdl/pc_drvsnd.vhd against tb_drvsnd.vhd (ghdl), of
# CORE/vhdl/pc_chipset.vhd against tb_chipset.vhd, of CORE/vhdl/pc_fdd_sd.vhd (floppies, hard
# disk, the arbiter) against tb_fdd.vhd and of the firmware (CORE/m2m-rom/m2m-rom.asm): the
# settings file signature against run_cfgsig.sh, PREP_LOAD_IMAGE against run_prepload.sh (QNICE
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
    ('led_a_only',    "   led_o     <= drv_select_i(0) or drv_select_i(1) or hd_active_i;",
                      "   led_o     <= drv_select_i(0) or hd_active_i;"),
    ('led_no_hd',     "   led_o     <= drv_select_i(0) or drv_select_i(1) or hd_active_i;",
                      "   led_o     <= drv_select_i(0) or drv_select_i(1);"),
    ('led_green',     "   led_col_o <= x\"FFFF00\" when", "   led_col_o <= x\"00FF00\" when"),
    ('led_hd_yellow', "(drv_select_i(0) or drv_select_i(1)) = '1' else x\"FF0000\";",
                      "(drv_select_i(0) or drv_select_i(1)) = '1' else x\"FFFF00\";"),
    ('led_hd_wins',   "   led_col_o <= x\"FFFF00\" when (drv_select_i(0) or drv_select_i(1)) = '1' else",
                      "   led_col_o <= x\"FFFF00\" when (drv_select_i(0) or drv_select_i(1)) = '1' and hd_active_i = '0' else"),
    ('led_a_only_col',"   led_col_o <= x\"FFFF00\" when (drv_select_i(0) or drv_select_i(1)) = '1' else",
                      "   led_col_o <= x\"FFFF00\" when drv_select_i(0) = '1' else"),
    ('hd_sound',      "         v_mot := sound_i and (drv_motor_i(0) or drv_motor_i(1)) and not disk;",
                      "         v_mot := sound_i and (drv_motor_i(0) or drv_motor_i(1) or hd_active_i) and not disk;"),
]

CS = os.path.join(R, 'CORE', 'vhdl', 'pc_chipset.vhd')
CS_TB = os.path.join(H, 'tb_chipset.vhd')
CS_MUT = [
    ('cs_no_restart', "   rst_o     <= '1' when cnt /= 0 or (not xt_i) /= fe or mono_i /= mono else '0';",
                      "   rst_o     <= '0';"),
    ('cs_no_stretch', "            cnt  <= (others => '1');", "            cnt  <= (others => '0');"),
    ('cs_late',       "   rst_o     <= '1' when cnt /= 0 or (not xt_i) /= fe or mono_i /= mono else '0';",
                      "   rst_o     <= '1' when cnt /= 0 else '0';"),
    ('cs_late_mono',  "   rst_o     <= '1' when cnt /= 0 or (not xt_i) /= fe or mono_i /= mono else '0';",
                      "   rst_o     <= '1' when cnt /= 0 or (not xt_i) /= fe else '0';"),
    ('cs_sw_swapped', "                G_SW1_FE when fe = '1' else G_SW1_XT;",
                      "                G_SW1_XT when fe = '1' else G_SW1_FE;"),
    ('cs_sw_fixed',   "                G_SW1_FE when fe = '1' else G_SW1_XT;", "                G_SW1_FE;"),
    ('cs_default_xt', "   signal fe   : std_logic := '1';", "   signal fe   : std_logic := '0';"),
    ('cs_count_once', "         elsif cnt /= 0 then", "         elsif cnt = 1 then"),
    ('cs_mono_norst', "         if (not xt_i) /= fe or mono_i /= mono then", "         if (not xt_i) /= fe then"),
    ('cs_mono_dip',   "   cbm_dip_o <= mono & '1';", "   cbm_dip_o <= '0' & '1';"),
    ('cs_mono_set',   "   cbm_dip_o <= mono & '1';", "   cbm_dip_o <= mono & '0';"),
    ('cs_mono_live',  "   cbm_dip_o <= mono & '1';", "   cbm_dip_o <= mono_i & '1';"),
    ('cs_mono_sw_fe', "   dip_sw1_o <= (G_SW1_FE(7 downto 6) & \"11\" & G_SW1_FE(3 downto 0)) when fe = '1' and mono = '1' else",
                      "   dip_sw1_o <= (G_SW1_FE(7 downto 6) & \"01\" & G_SW1_FE(3 downto 0)) when fe = '1' and mono = '1' else"),
    ('cs_mono_sw_xt', "                (G_SW1_XT(7 downto 6) & \"11\" & G_SW1_XT(3 downto 0)) when mono = '1' else",
                      "                (G_SW1_XT(7 downto 6) & \"10\" & G_SW1_XT(3 downto 0)) when mono = '1' else"),
]


def run_cs(dut_path, work):
    os.makedirs(work, exist_ok=True)
    cmd = ('ghdl -a --std=08 "{d}" "{t}" && ghdl -e --std=08 tb_chipset && '
           'ghdl -r --std=08 tb_chipset').format(d=dut_path, t=CS_TB)
    p = subprocess.run(['bash', '-c', cmd], cwd=work, capture_output=True, text=True)
    return 'CHIPSET TB: PASS' in p.stdout + p.stderr and p.returncode == 0

FD = os.path.join(R, 'CORE', 'vhdl', 'pc_fdd_sd.vhd')
FD_TB = os.path.join(H, 'tb_fdd.vhd')
FD_DEPS = [os.path.join(R, 'M2M', 'QNICE', 'vhdl', 'tools.vhd')] + \
          [os.path.join(R, 'M2M', 'vhdl', f) for f in
           ('tdp_ram.vhd', '2port2clk_ram.vhd', 'cdc_stable.vhd', os.path.join('QNICE', 'sdhost.vhd'))]
FD_MUT = [
    # the arbiter
    ('fd_rr_fixed',    "               if sp_req_i = '1' and (hd_sp_req_i = '0' or m_last = '1') then",
                       "               if sp_req_i = '1' then"),
    ('fd_rr_hd_first', "               if sp_req_i = '1' and (hd_sp_req_i = '0' or m_last = '1') then",
                       "               if sp_req_i = '1' and hd_sp_req_i = '0' then"),
    ('fd_wrrdy_both',  "   hd_sp_wr_ready_o <= '1' when mstate = M_COLLECT and m_src = '1' else '0';",
                       "   hd_sp_wr_ready_o <= '1' when mstate = M_COLLECT else '0';"),
    ('fd_rv_both',     "   hd_sp_rd_valid_o <= m_rd_valid and m_src and not m_drop;",
                       "   hd_sp_rd_valid_o <= m_rd_valid and not m_drop;"),
    ('fd_done_both',   "   sp_done_o        <= m_done and not m_src and not m_drop;",
                       "   sp_done_o        <= m_done and not m_drop;"),
    ('fd_err_both',    "   hd_sp_err_o      <= m_err and m_src and not m_drop;",
                       "   hd_sp_err_o      <= m_err and not m_drop;"),
    ('fd_wdata_fdc',   "   m_wd_sel  <= hd_sp_wr_data_i  when m_src = '1' else sp_wr_data_i;",
                       "   m_wd_sel  <= sp_wr_data_i;"),
    ('fd_hd_write_fdc',"                     m_write <= hd_sp_write_i;", "                     m_write <= sp_write_i;"),
    # abandoned requests
    # (not a mutant: M_WAIT without its m_drop test streams to nobody, the outputs are gated)
    ('fd_drop_gate',   "   hd_sp_rd_valid_o <= m_rd_valid and m_src and not m_drop;",
                       "   hd_sp_rd_valid_o <= m_rd_valid and m_src;"),
    ('fd_no_drop',     "         if mstate /= M_IDLE and mstate /= M_LOW and m_req_sel = '0' then",
                       "         if false then"),
    ('fd_collect_hang',"               if m_req_sel = '0' then                      -- abandoned before the block",
                       "               if false then"),
    ('fd_low_hang',    "               if m_req_sel = '0' or m_drop = '1' then", "               if m_req_sel = '0' then"),
    # the hard disk C:
    ('fd_hd_nosize',   "   q_present(2) <= '1' when q_mode_on(2) = '1' and q_sects(2) = G_HD_SECTS else '0';",
                       "   q_present(2) <= '1' when q_mode_on(2) = '1' else '0';"),
    ('fd_hd_chk_size', "                  (q_drv = 2 and q_present(2) = '0') or (q_write = '1' and q_wp(q_drv) = '1') then",
                       "                  (q_write = '1' and q_wp(q_drv) = '1') then"),
    ('fd_hd_oor',      "                     m_oor   <= or hd_sp_lba_i(27 downto 16);", "                     m_oor   <= '0';"),
    ('fd_hd_drive_b',  "                     m_drive <= \"10\";", "                     m_drive <= \"01\";"),
    ('fd_hd_wp',       "   q_wp  <= '0' & qnice_wp_i;", "   q_wp  <= qnice_wp_i(1) & qnice_wp_i;"),
    ('fd_map_alias_a', "         address_a         => std_logic_vector(to_unsigned(q_d, 2)) & q_ofs(10 downto 0),",
                       "         address_a         => '0' & qnice_drive_i(0) & q_ofs(10 downto 0),"),
    ('fd_map_alias_b', "      q_map_raddr <= std_logic_vector(to_unsigned(q_drv, 2)) & std_logic_vector(v_w);",
                       "      q_map_raddr <= std_logic_vector(to_unsigned(q_drv mod 2, 2)) & std_logic_vector(v_w);"),
    ('fd_hd_regs_b',   "   q_d   <= 0 when qnice_drive_i = \"00\" else 1 when qnice_drive_i = \"01\" else 2;",
                       "   q_d   <= 0 when qnice_drive_i = \"00\" else 1;"),
    ('fd_hd_present_o',"   hd_present_o  <= m_geo(36);", "   hd_present_o  <= m_geo(0);"),
    # both drives (the 2026-10-21 set)
    ('fd_beyond',      " or resize(q_lba, 32) >= q_sects(q_drv) or", " or"),
    ('fd_no_offset',   "                             resize(q_offs, 32);", "                             to_unsigned(0, 32);"),
    ('fd_first_extent',"               elsif q_e + 1 = q_n then                     -- past the end of the map",
                       "               elsif true then"),
    ('fd_no_reissue',  "                     qstate <= Q_SD;                       -- preempted before the block",
                       "                     qstate <= Q_FINISH;"),
    ('fd_no_retry',    "                     if q_tries = G_RETRIES then", "                     if true then"),
    ('fd_no_wp',       " or (q_write = '1' and q_wp(q_drv) = '1') then", " then"),
]


def run_fd(dut_path, work):
    os.makedirs(work, exist_ok=True)
    cmd = ' && '.join(['ghdl -a --std=08 -frelaxed "%s"' % f for f in FD_DEPS + [dut_path, FD_TB]] +
                      ['ghdl -e --std=08 -frelaxed tb_fdd',
                       'ghdl -r --std=08 -frelaxed tb_fdd --ieee-asserts=disable --stop-time=20ms'])
    p = subprocess.run(['bash', '-c', cmd], cwd=work, capture_output=True, text=True)
    return 'PASS: pc_fdd_sd' in p.stdout + p.stderr and p.returncode == 0

FW = os.path.join(R, 'CORE', 'm2m-rom', 'm2m-rom.asm')
FW_MUT = [
    ('sig_always',    "                RBRA    _CFGSC_OK, Z", "                RBRA    _CFGSC_OK, 1"),
    ('sig_inverted',  "                RBRA    _CFGSC_OK, Z", "                RBRA    _CFGSC_OK, !Z"),
    ('sig_no_set',    "                RSUB    CFGS_SET, 1", "                NOP"),
    ('sig_short_buf', "                MOVE    4, R10\n                RSUB    CFGS_GET, 1",
                      "                MOVE    2, R10\n                RSUB    CFGS_GET, 1"),
    ('sig_no_leave',  "_CFGSC_OK       SYSCALL(leave, 1)", "_CFGSC_OK       NOP"),
]

# PREP_LOAD_IMAGE (the image checks) against run_prepload.sh
PL_MUT = [
    ('pl_hd_size_lo',  "                CMP     0xB800, R2", "                CMP     0xB600, R2"),
    ('pl_hd_size_hi',  "                CMP     0x0146, R3", "                CMP     0x0147, R3"),
    ('pl_hd_hi_skip',  "                CMP     0x0146, R3\n                RBRA    _PCPL_HBAD, !Z",
                       "                CMP     0x0146, R3\n                NOP"),
    ('pl_hd_as_fd',    "                RBRA    _PCPL_FD, !Z", "                RBRA    _PCPL_FD, 1"),
    ('pl_hd_drive',    "                MOVE    2, R1\n                CMP     PC_OPTM_G_HDC, R10",
                       "                MOVE    1, R1\n                CMP     PC_OPTM_G_HDC, R10"),
    ('pl_hd_ignored',  "                CMP     PC_OPTM_G_HDC, R10\n                RBRA    _PCPL_OK, !Z",
                       "                CMP     PC_OPTM_G_HDC, R10\n                RBRA    _PCPL_OK, 1"),
    ('pl_hd_device',   "FD_DEV_TAB      .DW     PC_DEV_FDA, PC_DEV_FDB, PC_DEV_HDC",
                       "FD_DEV_TAB      .DW     PC_DEV_FDA, PC_DEV_FDB, PC_DEV_FDB"),
    ('pl_hd_message',  "                MOVE    ERR_HD_SIZE, R9", "                MOVE    ERR_FD_SIZE, R9"),
    ('pl_fdb_as_hd',   "                CMP     PC_OPTM_G_FDB, R10\n                RBRA    _PCPL_D, Z",
                       "                CMP     PC_OPTM_G_FDB, R10\n                NOP"),
]


def run_pl(path):
    p = subprocess.run([os.path.join(H, 'run_prepload.sh'), path], capture_output=True, text=True)
    return 'PREPLOAD TEST: PASS' in p.stdout


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
        dsrc = open(FD).read()
        if not run_fd(FD, os.path.join(tmp, 'fd_orig')):
            print('the floppy/hard disk backend bench does not pass'); return 1
        dk = 0
        for name, a, b in FD_MUT:
            if dsrc.count(a) != 1:
                print('%-15s pattern found %d times' % (name, dsrc.count(a))); return 1
            p = os.path.join(tmp, name + '.vhd')
            open(p, 'w').write(dsrc.replace(a, b))
            ok = run_fd(p, os.path.join(tmp, name))
            print('%-15s %s' % (name, 'SURVIVED' if ok else 'killed'))
            dk += not ok
        print('pc_fdd_sd mutants: %d of %d killed' % (dk, len(FD_MUT)))
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
        if not run_pl(FW):
            print('the PREP_LOAD_IMAGE test does not pass'); return 1
        pk = 0
        for name, a, b in PL_MUT:
            if fsrc.count(a) != 1:
                print('%-15s pattern found %d times' % (name, fsrc.count(a))); return 1
            p = os.path.join(tmp, name + '.asm')
            open(p, 'w').write(fsrc.replace(a, b))
            ok = run_pl(p)
            print('%-15s %s' % (name, 'SURVIVED' if ok else 'killed'))
            pk += not ok
        print('firmware PREP_LOAD_IMAGE mutants: %d of %d killed' % (pk, len(PL_MUT)))
        return 0 if (killed == len(MUT) and ck == len(CS_MUT) and dk == len(FD_MUT) and
                     fk == len(FW_MUT) and pk == len(PL_MUT)) else 1


sys.exit(main())
