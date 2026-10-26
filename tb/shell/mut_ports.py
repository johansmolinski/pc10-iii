#!/usr/bin/env python3
# mut_ports.py - mutants of CORE/vhdl/pc_ports.vhd (the PMOD headers, the mouse lines, the POT
# buttons) against tb_ports.vhd (ghdl). Every mutant must be killed. Run from anywhere. (The
# 8250, the parallel port, the bus mouse and the mixer themselves: tb/ports/mut.py.)
import os, subprocess, sys, tempfile

H = os.path.dirname(os.path.abspath(__file__))
R = os.path.abspath(os.path.join(H, '..', '..'))
DUT = os.path.join(R, 'CORE', 'vhdl', 'pc_ports.vhd')
TB = os.path.join(H, 'tb_ports.vhd')

MUT = [
    ('pmod2_unpowered', "   pmod2_en_o <= on_q;", "   pmod2_en_o <= '0';"),
    ('pmod1_always_on', "   pmod1_en_o <= on_q;", "   pmod1_en_o <= '1';"),
    ('txd_always',      "   p1lo_io(1) <= ser_txd_i      when on_q = '1' else 'Z';", "   p1lo_io(1) <= ser_txd_i;"),
    ('cts_driven',      "   p1lo_io(0) <= 'Z';                                               -- /CTS in",
                        "   p1lo_io(0) <= ser_rts_n_i when on_q = '1' else 'Z';"),
    ('rts_not_driven',  "   p1lo_io(3) <= ser_rts_n_i    when on_q = '1' else 'Z';", "   p1lo_io(3) <= 'Z';"),
    ('strobe_init_swap',"   p1hi_io(0) <= lpt_strobe_n_i when on_q = '1' else 'Z';", "   p1hi_io(0) <= lpt_init_n_i when on_q = '1' else 'Z';"),
    ('busy_driven',     "   p1hi_io(1) <= 'Z';                                               -- BUSY in",
                        "   p1hi_io(1) <= '0' when on_q = '1' else 'Z';"),
    ('data_nibbles',    "   p2lo_io    <= lpt_data_i(3 downto 0) when", "   p2lo_io    <= lpt_data_i(7 downto 4) when"),
    ('data_always',     "   p2hi_io    <= lpt_data_i(7 downto 4) when on_q = '1' else (others => 'Z');",
                        "   p2hi_io    <= lpt_data_i(7 downto 4);"),
    ('rxd_unsync',      "   ser_rxd_o   <= in_sync(3)  when on_q = '1' else '1';", "   ser_rxd_o   <= p1lo_io(2)  when on_q = '1' else '1';"),
    ('rxd_off_space',   "   ser_rxd_o   <= in_sync(3)  when on_q = '1' else '1';", "   ser_rxd_o   <= in_sync(3);"),
    ('cts_off_active',  "   ser_cts_n_o <= in_sync(2)  when on_q = '1' else '1';", "   ser_cts_n_o <= in_sync(2)  when on_q = '1' else '0';"),
    ('dsr_fixed',       "   ser_dsr_n_o <= ser_dtr_n_i when on_q = '1' else '1';", "   ser_dsr_n_o <= '1';"),
    ('dcd_off_dtr',     "   ser_dcd_n_o <= ser_dtr_n_i when on_q = '1' else '1';", "   ser_dcd_n_o <= ser_dtr_n_i;"),
    ('busy_off_pin',    "   lpt_busy_o  <= in_sync(1)  when on_q = '1' else '0';", "   lpt_busy_o  <= in_sync(1);"),
    ('ack_inputs_swap', "   lpt_ack_n_o <= in_sync(0)  when on_q = '1' else '1';", "   lpt_ack_n_o <= in_sync(1)  when on_q = '1' else '1';"),
    ('slct_off',        "   lpt_slct_o  <= '1';", "   lpt_slct_o  <= '0';"),
    ('atari_ignored',   "   mouse_xq_o <= joy_up_n_i    when atari_i = '1' else joy_right_n_i;", "   mouse_xq_o <= joy_right_n_i;"),
    ('amiga_v_pin4',    "   mouse_yp_o <= joy_right_n_i when atari_i = '1' else joy_up_n_i;", "   mouse_yp_o <= joy_right_n_i;"),
    ('h_vq_swapped',    "   mouse_xp_o <= joy_down_n_i;", "   mouse_xp_o <= joy_left_n_i;"),
    ('pot_no_latch',    "   mouse_btn_n_o(2) <= not (rmb_capable and not pot_x_i(7));", "   mouse_btn_n_o(2) <= pot_x_i(7);"),
    ('pot_mid_from_x',  "   mouse_btn_n_o(1) <= not (mmb_capable and not pot_y_i(7));", "   mouse_btn_n_o(1) <= not (mmb_capable and not pot_x_i(7));"),
    ('no_watchdog',     "            if rmb_watchdog = G_POT_TIMEOUT then\n               rmb_capable <= '0';",
                        "            if false then\n               rmb_capable <= '0';"),
    ('no_reset_disarm', "            mmb_capable  <= '0';\n            mmb_watchdog <= 0;\n         end if;\n      end if;\n   end process p_pot;",
                        "            mmb_watchdog <= 0;\n         end if;\n      end if;\n   end process p_pot;"),
    ('left_from_pot',   "   mouse_btn_n_o(0) <= joy_fire_n_i;", "   mouse_btn_n_o(0) <= pot_x_i(7);"),
]


def run(dut, work):
    os.makedirs(work, exist_ok=True)
    cmd = ('ghdl -a --std=08 -frelaxed "{d}" && ghdl -a --std=08 -frelaxed "{t}" && '
           'ghdl -e --std=08 -frelaxed tb_ports && ghdl -r --std=08 -frelaxed tb_ports '
           '--ieee-asserts=disable --stop-time=1ms').format(d=dut, t=TB)
    p = subprocess.run(['bash', '-c', cmd], cwd=work, capture_output=True, text=True)
    return 'tb_ports PASS' in p.stdout + p.stderr


def main():
    src = open(DUT).read()
    with tempfile.TemporaryDirectory() as tmp:
        if not run(DUT, os.path.join(tmp, 'orig')):
            print('pc_ports: the original does not pass'); return 1
        k = 0
        for name, a, b in MUT:
            if src.count(a) != 1:
                print('%-17s pattern found %d times' % (name, src.count(a))); return 1
            p = os.path.join(tmp, name + '.vhd')
            open(p, 'w').write(src.replace(a, b))
            survived = run(p, os.path.join(tmp, name))
            print('%-17s %s' % (name, 'SURVIVED' if survived else 'killed'))
            k += not survived
        print('pc_ports mutants: %d of %d killed' % (k, len(MUT)))
    return 0 if k == len(MUT) else 1


sys.exit(main())
