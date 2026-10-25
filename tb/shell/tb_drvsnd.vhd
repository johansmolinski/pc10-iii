-- tb_drvsnd.vhd - pc_drvsnd.vhd (drive LED and drive sound) against a model of the MEGA65's
-- internal drive: a head (0..83, mechanical stops; it starts away from track 0), step pulses
-- taken on the falling edge while selected, TRK0 reported a few clocks late after a move,
-- the disk change latch (low after power-up and a removal, cleared by a step with a disk in),
-- outputs high while the drive is not selected. Small timing generics.
--
-- Checks: the LED; homing before the first step (and that PC steps wait for it); one step
-- per head movement, the 0..79 limits, TRK0 resync only after an outward step; a step
-- dropped while a pulse is made; no step before the settle time; no step when the motor
-- stopped meanwhile; pulse width, direction setup and hold; the disk guard (the first step
-- after an insertion finds the disk, then no motor and no steps, only probes; removal brings
-- the sound back; no false disk from a deselected drive); menu off (nothing, no probe, a
-- homing stops and resumes); a disk found while homing; homing without TRK0 (at most 85).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_drvsnd is
end entity tb_drvsnd;

architecture sim of tb_drvsnd is
   constant SETTLE    : natural := 7;
   constant TMR_BITS  : natural := 10;
   constant PRB_BITS  : natural := 4;
   constant DSETUP    : natural := 3;
   constant PULSE     : natural := 4;
   constant HOLD      : natural := 2;
   constant HRATE     : natural := 40;
   constant LAG       : natural := 30;       -- the model's TRK0 lag after a move

   signal clk, rst    : std_logic := '0';
   signal done        : boolean := false;
   signal sound       : std_logic := '1';
   signal motor, sel  : std_logic_vector(1 downto 0) := "00";
   signal step, st_in : std_logic := '0';
   signal led         : std_logic;
   signal led_col     : std_logic_vector(23 downto 0);
   signal f_motor, f_sel, f_dir, f_step : std_logic;
   signal f_trk0, f_chg : std_logic;
   signal cyl         : natural range 0 to 79;
   signal known, disk : std_logic;

   -- the drive model
   signal head        : integer := 30;
   signal head_set    : integer := -1;       -- the bench moves the head (a power-up position)
   signal rep_head    : integer := 30;       -- the position TRK0 reports
   signal since_move  : natural := 1000;
   signal disk_in     : std_logic := '0';
   signal latch       : std_logic := '0';    -- '1' = no change since the last step with a disk
   signal trk0_broken : boolean := false;
   signal p_in, p_out : natural := 0;        -- pulses taken
   signal bangs       : natural := 0;        -- outward pulses at track 0
   signal beyond      : natural := 0;        -- pulses that took the head past 79
   signal disk_moves  : natural := 0;        -- head moves with a disk in
   signal motclk, selclk, disk_motclk : natural := 0;
   signal viol        : natural := 0;        -- pulse width / direction setup / hold
   signal last_fall   : natural := 0;        -- clock of the last step pulse
   signal sel_fall    : natural := 0;        -- clock the select went low
   signal now         : natural := 0;
   signal home_gap    : natural := 100000;   -- shortest time between two homing pulses
begin
   clk <= not clk after 5 ns when not done;

   dut : entity work.pc_drvsnd
      generic map (
         G_SETTLE => SETTLE, G_TMR_BITS => TMR_BITS, G_PRB_BITS => PRB_BITS,
         G_DIR_SETUP => DSETUP, G_PULSE => PULSE, G_HOLD => HOLD,
         G_HOME_RATE => HRATE, G_HOME_MAX => 85)
      port map (
         clk_i => clk, rst_i => rst, sound_i => sound,
         drv_motor_i => motor, drv_select_i => sel, drv_step_i => step, drv_step_in_i => st_in,
         led_o => led, led_col_o => led_col,
         f_motora_o => f_motor, f_selecta_o => f_sel, f_stepdir_o => f_dir, f_step_o => f_step,
         f_track0_i => f_trk0, f_diskchanged_i => f_chg,
         cyl_o => cyl, known_o => known, disk_o => disk);

   f_trk0 <= '0' when f_sel = '0' and rep_head = 0 and not trk0_broken else '1';
   f_chg  <= latch when f_sel = '0' else '1';

   model : process (clk)
      variable step_q, dir_q, sel_q : std_logic := '1';
      variable low, dir_age, rise_age : natural := 1000;
   begin
      if rising_edge(clk) then
         now <= now + 1;
         if f_motor = '0' then motclk <= motclk + 1; end if;
         if f_sel = '0' then selclk <= selclk + 1; end if;
         if f_motor = '0' and disk_in = '1' and latch = '1' then disk_motclk <= disk_motclk + 1; end if;
         if sel_q = '1' and f_sel = '0' then sel_fall <= now; end if;
         -- direction setup and hold, pulse width
         if f_dir /= dir_q then
            if step_q = '0' or rise_age < HOLD then viol <= viol + 1; end if;
            dir_age := 0;
         elsif dir_age < 1000 then
            dir_age := dir_age + 1;
         end if;
         if f_step = '0' then
            low := low + 1;
         elsif step_q = '0' then
            if low /= PULSE then viol <= viol + 1; end if;
            rise_age := 0;
         elsif rise_age < 1000 then
            rise_age := rise_age + 1;
         end if;
         if since_move < 1000 then since_move <= since_move + 1; end if;
         if since_move = LAG then rep_head <= head; end if;
         if step_q = '1' and f_step = '0' then
            low := 1;
            last_fall <= now;
            if known = '0' and now - last_fall < home_gap then home_gap <= now - last_fall; end if;
            if dir_age < DSETUP then viol <= viol + 1; end if;
            if f_sel = '0' then
               if f_dir = '1' then
                  p_out <= p_out + 1;
                  if head = 0 then bangs <= bangs + 1; else head <= head - 1; since_move <= 0; end if;
               else
                  p_in <= p_in + 1;
                  if head = 79 then beyond <= beyond + 1; end if;
                  if head < 83 then head <= head + 1; since_move <= 0; end if;
               end if;
               if disk_in = '1' then
                  if latch = '1' then disk_moves <= disk_moves + 1; end if;
                  latch <= '1';
               end if;
            end if;
         end if;
         if disk_in = '0' then latch <= '0'; end if;
         if head_set >= 0 then head <= head_set; rep_head <= head_set; since_move <= 1000; end if;
         step_q := f_step; dir_q := f_dir; sel_q := f_sel;
      end if;
   end process model;

   stim : process
      variable fails : natural := 0;
      variable n0, n1, t0 : natural;
      procedure clk_n(n : natural) is
      begin
         for i in 1 to n loop wait until rising_edge(clk); end loop;
      end procedure;
      procedure expect(what : string; got, want : integer) is
      begin
         if got /= want then
            report "FAIL " & what & ": " & integer'image(got) & " /= " & integer'image(want);
            fails := fails + 1;
         end if;
      end procedure;
      procedure expect_sl(what : string; got, want : std_logic) is
      begin
         if got /= want then
            report "FAIL " & what & ": " & std_logic'image(got);
            fails := fails + 1;
         end if;
      end procedure;
      -- one head movement of the selected drive, then gap clocks
      procedure pc_step(inward : std_logic; gap : natural) is
      begin
         st_in <= inward; step <= '1'; clk_n(1); step <= '0'; st_in <= '0'; clk_n(gap);
      end procedure;
      procedure pc_steps(inward : std_logic; n : natural) is
      begin
         for i in 1 to n loop pc_step(inward, 40); end loop;
      end procedure;
      procedure set_head(p : integer) is
      begin
         head_set <= p; clk_n(1); head_set <= -1; clk_n(1);
      end procedure;
      procedure reset_dut is
      begin
         rst <= '1'; clk_n(3); rst <= '0'; clk_n(3);
      end procedure;
      procedure wait_known(maxclk : natural) is
      begin
         for i in 1 to maxclk loop
            exit when known = '1';
            wait until rising_edge(clk);
         end loop;
      end procedure;
   begin
      reset_dut;

      -- a) the LED: drive A: or B: selected (DOR select + motor), yellow
      expect_sl("a LED off", led, '0');
      sel <= "01"; clk_n(1); expect_sl("a LED A:", led, '1');
      expect("a LED colour", to_integer(unsigned(led_col)), 16#FFFF00#);
      sel <= "10"; clk_n(1); expect_sl("a LED B:", led, '1');
      sel <= "00"; clk_n(1); expect_sl("a LED off again", led, '0');

      -- b) no motor: nothing, a step does not reach the drive
      pc_step('0', 40);
      expect("b no pulses", p_in + p_out, 0); expect_sl("b no select", f_sel, '1');
      expect_sl("b not homed", known, '0');

      -- c) A:'s motor: the drive runs and is homed from 30 (6 ms steps: HRATE here); a PC
      --    step during the homing is not passed on
      motor <= "01"; sel <= "01"; clk_n(3);
      expect_sl("c motor", f_motor, '0'); expect_sl("c select", f_sel, '0');
      clk_n(5 * HRATE); pc_step('0', 1);
      wait_known(60 * HRATE);
      expect_sl("c homed", known, '1'); expect("c head", head, 0); expect("c cyl", cyl, 0);
      expect("c homing pulses", p_out, 30); expect("c no inward pulses", p_in, 0);
      expect("c no bangs", bangs, 0);
      expect("c homing step rate", home_gap, HRATE);

      -- d) ten steps inward
      n0 := p_in; pc_steps('1', 10);
      expect("d pulses", p_in - n0, 10); expect("d head", head, 10); expect("d cyl", cyl, 10);
      -- e) at most cylinder 79
      n0 := p_in; pc_steps('1', 75);
      expect("e pulses", p_in - n0, 69); expect("e head", head, 79); expect("e cyl", cyl, 79);
      expect("e never past 79", beyond, 0);
      -- f) outward to 0, not below
      n0 := p_out; pc_steps('0', 84);
      expect("f pulses", p_out - n0, 79); expect("f head", head, 0); expect("f cyl", cyl, 0);
      expect("f no bangs", bangs, 0);
      --    an outward step to 0 and another before the drive reports track 0
      pc_step('1', 40); pc_step('0', 12); pc_step('0', 40);
      expect("f lag head", head, 0); expect("f lag cyl", cyl, 0); expect("f lag no bang", bangs, 0);

      -- g) TRK0 still reported just after an inward step from 0: an outward step right
      --    after it is passed on (the counter is not reset by the stale TRK0)
      pc_step('1', 12); pc_step('0', 40);
      expect("g head", head, 0); expect("g cyl", cyl, 0);
      pc_step('0', 40); expect("g no bang", bangs, 0);
      --    the counter is resynchronised by TRK0 after an outward step: a head that was moved
      --    (the bench) to 0 with the counter at 2
      pc_steps('1', 3); pc_steps('0', 1); set_head(0); clk_n(5);
      n0 := p_out; pc_step('0', 40);
      expect("g resync: no pulse at track 0", p_out - n0, 0); expect("g resync cyl", cyl, 0);
      pc_steps('1', 1); expect("g after resync head", head, 1); expect("g after resync cyl", cyl, 1);
      pc_steps('0', 1);

      -- h) a step while a pulse is being made is dropped
      n0 := p_in; pc_step('1', 2); pc_step('1', 40);
      expect("h one pulse", p_in - n0, 1); expect("h head", head, 1); expect("h cyl", cyl, 1);
      pc_steps('0', 1);

      -- i) a step right after the motor starts waits for the settle time
      motor <= "00"; sel <= "00"; clk_n(20);
      motor <= "01"; sel <= "01"; pc_step('1', 40);
      expect("i pulse", head, 1);
      if last_fall < sel_fall + SETTLE + DSETUP then
         report "FAIL i step " & integer'image(last_fall - sel_fall) & " clocks after the select";
         fails := fails + 1;
      end if;
      pc_steps('0', 1);
      -- j) the motor stops before the settle time: the step is not made
      motor <= "00"; sel <= "00"; clk_n(20);
      n0 := p_in;
      motor <= "01"; sel <= "01"; st_in <= '1'; step <= '1'; clk_n(1); step <= '0';
      motor <= "00"; sel <= "00"; clk_n(40);
      motor <= "01"; sel <= "01"; clk_n(40);
      expect("j no pulse", p_in - n0, 0); expect("j cyl", cyl, 0);

      -- B: works the same way (its motor, its steps)
      motor <= "10"; sel <= "10"; clk_n(3);
      expect_sl("B motor", f_motor, '0');
      pc_steps('1', 5); expect("B head", head, 5); expect("B cyl", cyl, 5);
      expect("pulse width / direction violations", viol, 0);

      -- k) a real disk is inserted: the first step finds it (the latch clears), then no
      --    motor and no steps; only probes
      disk_in <= '1'; clk_n(5);
      expect_sl("k no disk yet", disk, '0');
      n0 := p_in; pc_step('1', 40);
      expect("k the first step", p_in - n0, 1);
      expect_sl("k disk found", disk, '1'); expect_sl("k motor stops", f_motor, '1');
      n0 := p_in + p_out; pc_steps('1', 3);
      expect("k no steps with a disk", p_in + p_out - n0, 0);
      clk_n(3); n0 := motclk; n1 := selclk;
      clk_n(4 * 2**TMR_BITS);
      expect("k motor stays off", motclk - n0, 0);
      expect("k probe selects", selclk - n1, 4 * 2**PRB_BITS);
      expect("k no step with a detectable disk", disk_moves, 0);
      expect("k motor with the disk in (clocks)", disk_motclk, 4);
      -- l) the disk is taken out: the next probe brings the sound back
      disk_in <= '0'; clk_n(2**TMR_BITS + 4);
      expect_sl("l disk gone", disk, '0'); expect_sl("l motor again", f_motor, '0');
      n0 := p_out; pc_steps('0', 2); expect("l steps again", p_out - n0, 2);
      expect("l head = cyl", head, cyl);
      -- m) a deselected drive is never read: no false disk from the open line
      motor <= "00"; sel <= "00"; clk_n(3); expect_sl("m deselected", f_sel, '1');
      n1 := selclk; clk_n(3 * 2**TMR_BITS);
      expect_sl("m no false disk", disk, '0'); expect("m no probe without a disk", selclk - n1, 0);

      -- n) menu off: no select, no motor, no steps; with a disk no probe either
      sound <= '0'; motor <= "01"; sel <= "01"; clk_n(3);
      expect_sl("n motor", f_motor, '1'); expect_sl("n select", f_sel, '1');
      n0 := p_in + p_out; pc_steps('1', 3); expect("n no steps", p_in + p_out - n0, 0);
      expect_sl("n LED still", led, '1');
      sound <= '1'; clk_n(3); disk_in <= '1'; pc_step('0', 40);
      expect_sl("n disk found", disk, '1');
      sound <= '0'; clk_n(3); n1 := selclk; clk_n(3 * 2**TMR_BITS);
      expect("n no probe when off", selclk - n1, 0);
      sound <= '1'; disk_in <= '0'; clk_n(2**TMR_BITS + 4);
      expect_sl("n disk gone", disk, '0');
      --    the menu is switched off while a pulse is made: it ends, the head follows
      n0 := head; pc_step('1', 1); sound <= '0'; clk_n(40);
      expect("n pulse completes", head, n0 + 1); expect("n cyl", cyl, n0 + 1);
      sound <= '1'; clk_n(3);

      -- o) after a reset the head is unknown again; menu off stops a homing, on resumes it
      motor <= "00"; sel <= "00";
      reset_dut; set_head(20);
      sound <= '0'; motor <= "01"; sel <= "01"; clk_n(10 * HRATE);
      expect("o off: no homing", head, 20);
      sound <= '1'; clk_n(8 * HRATE + 20);
      sound <= '0'; clk_n(3); n0 := p_out; clk_n(5 * HRATE);
      expect("o homing stops", p_out - n0, 0);
      if head = 20 or head = 0 then
         report "FAIL o homing did not run part-way: " & integer'image(head);
         fails := fails + 1;
      end if;
      sound <= '1'; wait_known(40 * HRATE);
      expect_sl("o homed", known, '1'); expect("o head", head, 0); expect("o cyl", cyl, 0);

      -- p) a disk found while homing stops it
      motor <= "00"; sel <= "00";
      reset_dut; set_head(10); disk_in <= '1'; clk_n(3);
      n0 := p_out; motor <= "01"; sel <= "01"; clk_n(20 * HRATE);
      expect("p one homing step", p_out - n0, 1); expect_sl("p disk", disk, '1');
      expect_sl("p not homed", known, '0'); expect_sl("p motor off", f_motor, '1');
      disk_in <= '0'; clk_n(2**TMR_BITS + 4);
      wait_known(20 * HRATE);
      expect_sl("p homed after the removal", known, '1'); expect("p head", head, 0);

      -- q) no TRK0 at all: 85 homing steps, then track 0 is assumed
      motor <= "00"; sel <= "00";
      reset_dut; set_head(40); trk0_broken <= true; clk_n(3);
      n0 := p_out; n1 := bangs; motor <= "01"; sel <= "01";
      wait_known(100 * HRATE);
      expect_sl("q homed", known, '1'); expect("q pulses", p_out - n0, 85);
      expect("q head", head, 0); expect("q at the stop", bangs - n1, 45);
      trk0_broken <= false;
      expect("pulse width / direction violations (end)", viol, 0);

      if fails = 0 then
         report "DRIVE SOUND TB: PASS";
      else
         report "DRIVE SOUND TB: FAIL (" & integer'image(fails) & ")";
      end if;
      done <= true;
      wait;
   end process stim;
end architecture sim;
