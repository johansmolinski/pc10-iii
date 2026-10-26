----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- The PC's floppy drives A: and B: on the MEGA65's drive LED and its internal 3.5" drive
-- (doc/m2m-shell.md section 4, "Drive LED" and "Drive sound"), and the hard disk C: on the LED.
--
-- Drive LED: yellow (as Megamiga's floppy LED) while drive A: or B: is selected, i.e. the
-- DOR selects it and its motor bit is set: the select line of a PC10-III drive, which
-- lights the drive's front-panel LED. Red while the PC20-III's hard disk is active
-- (xta_card.sv's LED: busy, or a write still going to the image) and no floppy drive is
-- selected: a floppy wins. The hard disk makes no drive sound.
--
-- Drive sound (Megamiga 0.7's "Virtual Drive Sound", ported; the menu's "Drive sound"): the
-- internal drive plays the sounds of the image drives. Its motor runs while the motor bit
-- of A: or B: is set, and it takes one step for every cylinder the selected drive's head
-- moves (fdc_card.sv's drv_step: one per 765 step pulse, as the real drive takes them; at
-- the 40-track drive's inner stop the 765's extra pulses move nothing, here as there).
-- Write gate, side and density stay inactive: nothing on a disk is ever touched.
--
--   * The real head is followed in cyl_o (0..79): an inward step at 79 is not passed on,
--     nor an outward one at 0 or while the drive reports track 0 (then cyl_o := 0). The
--     head position is not known at power-up: before the first step, while the PC's motor
--     runs, the drive is homed (outward steps every 6 ms until TRK0, at most 85), which
--     sounds like the POST's recalibrate on a real PC.
--   * A step pulse: direction set, 8 us, step low 8 us, high, direction held 8 us (the
--     765 makes pulses of a few us; drives need about 1 us). A step that comes while a
--     pulse is still being made (two drives' overlapped seeks) is dropped and not counted.
--   * Disk guard (Megamiga 90f1e9b): a real disk in the drive silences it. While the drive
--     is selected, /DSKCHG is valid after G_SETTLE clocks (36 us), and high means a disk is
--     in (the drive clears its change latch on a step with a disk inserted, so the first
--     step after an insertion finds it). Then no motor and no steps, only a probe: every
--     2^G_TMR_BITS clocks (0.586 s) the drive is selected for 2^G_PRB_BITS clocks (286 us),
--     and a low /DSKCHG (the disk was taken out) brings the sound back. A step only goes out
--     after the settle time, so the guard has looked first.
--   * TRK0 resynchronises cyl_o only when the last step was outward: a drive reports track 0
--     for a few ms after an inward step from it.
--   * sound_i = 0 (menu off): the drive is never selected, nothing moves; a homing in
--     progress stops (it starts again later).
--
-- Clock: main_clk, 28.63636 MHz (the constants in the generics' defaults).
--
-- done by Johan Smolinski in 2026 after Megamiga's hwf_pins_proc (Virtual Drive Sound),
-- licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pc_drvsnd is
generic (
   G_SETTLE     : natural := 1031;      -- 36.0 us selected before /DSKCHG and TRK0 count
   G_TMR_BITS   : natural := 24;        -- probe period 2^24 clocks = 0.586 s
   G_PRB_BITS   : natural := 13;        -- probe length 2^13 clocks = 286 us
   G_DIR_SETUP  : natural := 229;       -- 8.0 us direction before the step pulse
   G_PULSE      : natural := 229;       -- 8.0 us step pulse
   G_HOLD       : natural := 229;       -- 8.0 us direction held after it
   G_HOME_RATE  : natural := 171818;    -- 6.0 ms per homing step (the XT BIOS's step rate)
   G_HOME_MAX   : natural := 85         -- homing steps at most (no TRK0: assume track 0)
);
port (
   clk_i            : in  std_logic;    -- main_clk
   rst_i            : in  std_logic;    -- main_rst (power-up): the head position is unknown

   sound_i          : in  std_logic;    -- the menu's "Drive sound"
   drv_motor_i      : in  std_logic_vector(1 downto 0);    -- DOR motor bits of A: and B:
   drv_select_i     : in  std_logic_vector(1 downto 0);    -- A:/B: selected (fdc_card.sv)
   drv_step_i       : in  std_logic;    -- the selected drive's head moved (one clock)
   drv_step_in_i    : in  std_logic;    -- ... inward
   hd_active_i      : in  std_logic;    -- the hard disk's LED (xta_card.sv)

   -- the MEGA65's drive LED
   led_o            : out std_logic;
   led_col_o        : out std_logic_vector(23 downto 0);

   -- the internal drive (M2M-UPSTREAM floppy-pins; all active low; f_stepdir '1' = outward)
   f_motora_o       : out std_logic;
   f_selecta_o      : out std_logic;
   f_stepdir_o      : out std_logic;
   f_step_o         : out std_logic;
   f_track0_i       : in  std_logic;
   f_diskchanged_i  : in  std_logic;

   -- state, for the testbench
   cyl_o            : out natural range 0 to 79;
   known_o          : out std_logic;    -- homed: cyl_o is the real head position
   disk_o           : out std_logic     -- a real disk is in the drive
);
end entity pc_drvsnd;

architecture synthesis of pc_drvsnd is

   signal trk0_m, trk0_s  : std_logic := '1';           -- TRK0, synchronized (low = track 0)
   signal chg_m, chg_s    : std_logic := '1';           -- /DSKCHG, synchronized
   attribute async_reg    : string;
   attribute async_reg of trk0_m : signal is "true";
   attribute async_reg of trk0_s : signal is "true";
   attribute async_reg of chg_m  : signal is "true";
   attribute async_reg of chg_s  : signal is "true";

   type t_state is (S_IDLE, S_WAIT, S_SETUP, S_PULSE, S_HOLD, S_GAP);
   signal state      : t_state := S_IDLE;
   signal cnt        : natural range 0 to G_HOME_RATE := 0;
   signal cyl        : natural range 0 to 79 := 0;
   signal known      : std_logic := '0';
   signal homing     : std_logic := '0';
   signal home_cnt   : natural range 0 to G_HOME_MAX := 0;
   signal step_in    : std_logic := '0';               -- the PC step being made: inward
   signal last_out   : std_logic := '1';               -- the last step went outward
   signal disk       : std_logic := '0';
   signal settle     : natural range 0 to G_SETTLE := 0;
   signal tmr        : unsigned(G_TMR_BITS - 1 downto 0) := (others => '0');
   signal sel_n      : std_logic := '1';
   signal motor_n    : std_logic := '1';
   signal dir        : std_logic := '1';
   signal step_n     : std_logic := '1';

begin

   led_o     <= drv_select_i(0) or drv_select_i(1) or hd_active_i;
   -- yellow (Megamiga's floppy colour) for A:/B:, red for the hard disk
   led_col_o <= x"FFFF00" when (drv_select_i(0) or drv_select_i(1)) = '1' else x"FF0000";

   f_motora_o  <= motor_n;
   f_selecta_o <= sel_n;
   f_stepdir_o <= dir;
   f_step_o    <= step_n;
   cyl_o       <= cyl;
   known_o     <= known;
   disk_o      <= disk;

   p_drive : process (clk_i)
      variable v_mot  : std_logic;
      variable v_sel  : std_logic;
      variable v_disk : std_logic;
      variable v_ok   : boolean;                         -- selected long enough: inputs valid
   begin
      if rising_edge(clk_i) then
         trk0_m <= f_track0_i;       trk0_s <= trk0_m;
         chg_m  <= f_diskchanged_i;  chg_s  <= chg_m;
         tmr    <= tmr + 1;

         -- the drive's lines: motor while the PC runs one (no real disk), select for the
         -- motor, a homing, a step being made, or the probe of a real disk
         v_mot := sound_i and (drv_motor_i(0) or drv_motor_i(1)) and not disk;
         v_sel := v_mot or homing;
         if disk = '1' and tmr(G_TMR_BITS - 1 downto G_PRB_BITS) = 0 then
            v_sel := '1';
         end if;
         v_sel := v_sel and sound_i;
         if state = S_SETUP or state = S_PULSE or state = S_HOLD then
            v_sel := '1';                               -- a pulse that was counted ends
         end if;

         -- /DSKCHG and TRK0 are valid G_SETTLE clocks after the select
         v_disk := disk;
         v_ok   := false;
         if v_sel = '1' and sel_n = '0' then
            if settle /= G_SETTLE then
               settle <= settle + 1;
            else
               v_ok   := true;
               v_disk := chg_s;                         -- high = a disk is in
            end if;
         else
            settle <= 0;
         end if;
         disk <= v_disk;

         case state is
            when S_IDLE =>                              -- v_mot: menu on, no real disk
               if v_mot = '1' then
                  if known = '0' then                   -- home before the first step
                     homing   <= '1';
                     home_cnt <= 0;
                     state    <= S_WAIT;
                  elsif drv_step_i = '1' then
                     step_in <= drv_step_in_i;
                     state   <= S_WAIT;
                  end if;
               end if;

            when S_WAIT =>                              -- until the guard has looked
               if sound_i = '0' or v_disk = '1' or (homing = '0' and v_mot = '0') then
                  homing <= '0';                        -- off, a disk, or the PC's motor
                  state  <= S_IDLE;                     -- stopped: no step
               elsif v_ok then
                  state <= S_IDLE;
                  if homing = '1' then
                     if trk0_s = '0' or home_cnt = G_HOME_MAX then
                        homing   <= '0';
                        known    <= '1';
                        cyl      <= 0;
                        last_out <= '1';
                     else
                        home_cnt <= home_cnt + 1;
                        dir      <= '1';
                        cnt      <= 0;
                        state    <= S_SETUP;
                     end if;
                  elsif step_in = '1' then
                     if cyl /= 79 then
                        cyl      <= cyl + 1;
                        last_out <= '0';
                        dir      <= '0';
                        cnt      <= 0;
                        state    <= S_SETUP;
                     end if;
                  elsif trk0_s = '0' and last_out = '1' then
                     cyl <= 0;                          -- the drive is at track 0
                  elsif cyl /= 0 then
                     cyl      <= cyl - 1;
                     last_out <= '1';
                     dir      <= '1';
                     cnt      <= 0;
                     state    <= S_SETUP;
                  end if;
               end if;

            when S_SETUP =>
               if cnt = G_DIR_SETUP - 1 then
                  step_n <= '0';
                  cnt    <= 0;
                  state  <= S_PULSE;
               else
                  cnt <= cnt + 1;
               end if;

            when S_PULSE =>
               if cnt = G_PULSE - 1 then
                  step_n <= '1';
                  cnt    <= 0;
                  state  <= S_HOLD;
               else
                  cnt <= cnt + 1;
               end if;

            when S_HOLD =>
               if cnt = G_HOLD - 1 then
                  cnt <= 0;
                  if homing = '1' then
                     state <= S_GAP;
                  else
                     state <= S_IDLE;
                  end if;
               else
                  cnt <= cnt + 1;
               end if;

            when S_GAP =>                               -- homing: the rest of 6 ms (S_WAIT
               if cnt = G_HOME_RATE - G_DIR_SETUP - G_PULSE - G_HOLD - 2 then   -- takes 1)
                  cnt   <= 0;
                  state <= S_WAIT;
               else
                  cnt <= cnt + 1;
               end if;
         end case;

         sel_n   <= not v_sel;
         motor_n <= not v_mot;

         if rst_i = '1' then
            state    <= S_IDLE;
            known    <= '0';
            homing   <= '0';
            cyl      <= 0;
            last_out <= '1';
            disk     <= '0';
            settle   <= 0;
            sel_n    <= '1';
            motor_n  <= '1';
            dir      <= '1';
            step_n   <= '1';
         end if;
      end if;
   end process p_drive;

end architecture synthesis;
