#!/usr/bin/env python3
# mut_rtc.py - mutants of the real-time clock's write-back: CORE/vhdl/pc_rtc.vhd against
# tb_rtc.vhd (ghdl, with M2M's rtc_controller) and the firmware's PC_RTC_WB
# (CORE/m2m-rom/pc_rtc.asm) against run_rtcwb.sh (QNICE emulator). Every mutant must be
# killed. Run from anywhere. (The chip itself: tb/rtc/mut.py.)
import os, subprocess, sys, tempfile

H = os.path.dirname(os.path.abspath(__file__))
R = os.path.abspath(os.path.join(H, '..', '..'))
M = os.path.join(R, 'M2M', 'vhdl')
DUT = os.path.join(R, 'CORE', 'vhdl', 'pc_rtc.vhd')
DEPS = [os.path.join(M, 'cdc_stable.vhd'), os.path.join(M, 'i2c', 'rtc_master.vhd'),
        os.path.join(M, 'i2c', 'rtc_controller.vhd')]
TB = os.path.join(H, 'tb_rtc.vhd')

MUT = [
    ('no_again',      "            main_again <= '1';", "            main_again <= '0';"),
    ('live_time',     "         src_data_i     => main_req & main_time,", "         src_data_i     => main_req & time_i,"),
    ('ack_flip',      "            qnice_ack <= qnice_q(64);", "            qnice_ack <= not qnice_ack;"),
    ('no_ack',        "            qnice_ack <= qnice_q(64);", "            null;"),
    ('pending_inv',   "   qnice_pending <= qnice_q(64) xor qnice_ack;", "   qnice_pending <= qnice_q(64) xnor qnice_ack;"),
    ('byte_shift',    "            v_i := to_integer(unsigned(qnice_addr_i(3 downto 0))) - 1;",
                      "            v_i := to_integer(unsigned(qnice_addr_i(3 downto 0))) mod 8;"),
    ('req_no_wait',   "         if v_want = '1' and main_req = main_ack(0) then", "         if v_want = '1' then"),
    ('ack_any_bit',   " and qnice_data_i(0) = '1' then", " then"),
]

FW = os.path.join(R, 'CORE', 'm2m-rom', 'pc_rtc.asm')
FW_MUT = [
    ('fw_seven',      "                CMP     8, R4", "                CMP     7, R4"),
    ('fw_no_run',     "                MOVE    0x000C, @R3", "                MOVE    0x0004, @R3"),
    ('fw_no_ack',     "                MOVE    1, @R2\n", "                MOVE    0, @R2\n"),
    ('fw_ignore_pend',"                AND     1, R3\n                RBRA    _PCRTC_RET, Z",
                      "                AND     1, R3\n                NOP"),
    ('fw_no_restore', "_PCRTC_RET      MOVE    R6, @R0", "_PCRTC_RET      NOP"),
    ('fw_no_incrb',   "PC_RTC_WB       INCRB", "PC_RTC_WB       NOP"),
    ('fw_offset',     "                MOVE    PC_RTC_TIME, R5", "                MOVE    PC_RTC_ST, R5"),
]


def run_vhd(dut, work):
    os.makedirs(work, exist_ok=True)
    files = ' '.join('"%s"' % f for f in DEPS + [dut, TB])
    cmd = ('for f in {f}; do ghdl -a --std=08 -frelaxed "$f" || exit 1; done && '
           'ghdl -e --std=08 -frelaxed tb_rtc && ghdl -r --std=08 -frelaxed tb_rtc '
           '--ieee-asserts=disable --stop-time=1ms').format(f=files)
    p = subprocess.run(['bash', '-c', cmd], cwd=work, capture_output=True, text=True)
    return 'tb_rtc PASS' in p.stdout + p.stderr


def run_fw(path):
    p = subprocess.run([os.path.join(H, 'run_rtcwb.sh'), path], capture_output=True, text=True)
    return 'RTCWB TEST: PASS' in p.stdout


def main():
    ok_all = True
    with tempfile.TemporaryDirectory() as tmp:
        for title, src_path, muts, runner, ext in (('pc_rtc', DUT, MUT, None, '.vhd'),
                                                     ('firmware PC_RTC_WB', FW, FW_MUT, run_fw, '.asm')):
            src = open(src_path).read()
            def go(p, name):
                return run_vhd(p, os.path.join(tmp, name)) if runner is None else runner(p)
            if not go(src_path, 'orig_' + ext[1:]):
                print('%s: the original does not pass' % title); return 1
            k = 0
            for name, a, b in muts:
                if src.count(a) != 1:
                    print('%-15s pattern found %d times' % (name, src.count(a))); return 1
                p = os.path.join(tmp, name + ext)
                open(p, 'w').write(src.replace(a, b))
                survived = go(p, name)
                print('%-15s %s' % (name, 'SURVIVED' if survived else 'killed'))
                k += not survived
            print('%s mutants: %d of %d killed' % (title, k, len(muts)))
            ok_all &= k == len(muts)
    return 0 if ok_all else 1


sys.exit(main())
