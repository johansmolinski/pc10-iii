----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- The real-time clock's write-back (doc/rtc.md section 5): when the PC sets its clock (the
-- MSM6242B at 2C0h, rtl/system/msm6242.sv, pulses rtc_set), the time goes to the MEGA65's
-- battery RTC, so it survives a power-off. The core cannot reach the RTC itself: M2M's RTC is a
-- QNICE device (M2M/vhdl/i2c/rtc_controller.vhd, device 0x0006). The firmware's
-- HANDLE_CORE_IO (PC_RTC_WB, CORE/m2m-rom/pc_rtc.asm) polls this device and copies the time.
--
-- QNICE device C_DEV_PC_RTC (globals.vhd), window 0, qnice_clk domain:
--   offset 0 (R)  bit 0: a write-back is pending
--          (W)  bit 0 = 1: done (acknowledge)
--   offset 1..8 (R)  the time in the register order of M2M's RTC device 0x00..0x07:
--                    hundredths, seconds, minutes, hours, day, month, year since 2000 (BCD),
--                    weekday (0 = Monday); stable while the write-back is pending
--
-- Main clock domain: a request takes the clock (time_i, live) when it starts; a set while one
-- is pending starts another, with the then current time, after the acknowledge. The request
-- toggle with the time and the acknowledge toggle cross through cdc_stable (the time is held
-- while the toggle differs, so all 65 bits are stable together).
--
-- done by Johan Smolinski in 2026 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pc_rtc is
   port (
      -- QNICE clock domain
      qnice_clk_i     : in  std_logic;
      qnice_addr_i    : in  std_logic_vector(27 downto 0);
      qnice_data_i    : in  std_logic_vector(15 downto 0);
      qnice_data_o    : out std_logic_vector(15 downto 0);
      qnice_ce_i      : in  std_logic;
      qnice_we_i      : in  std_logic;

      -- main clock domain
      main_clk_i      : in  std_logic;
      set_i           : in  std_logic;                       -- one clock: the PC set the clock
      time_i          : in  std_logic_vector(63 downto 0)    -- the clock, live
   );
end entity pc_rtc;

architecture synthesis of pc_rtc is

   signal main_req      : std_logic := '0';                  -- toggles per request
   signal main_time     : std_logic_vector(63 downto 0) := (others => '0');
   signal main_again    : std_logic := '0';
   signal main_ack      : std_logic_vector(0 downto 0);

   signal qnice_q       : std_logic_vector(64 downto 0);     -- {request, time}
   signal qnice_ack     : std_logic := '0';
   signal qnice_pending : std_logic;

begin

   ---------------------------------------------------------------------------------------------
   -- Main clock domain
   ---------------------------------------------------------------------------------------------

   p_main : process (main_clk_i)
      variable v_want : std_logic;
   begin
      if rising_edge(main_clk_i) then
         v_want := set_i or main_again;
         if v_want = '1' and main_req = main_ack(0) then
            main_time  <= time_i;
            main_req   <= not main_req;
            main_again <= '0';
         elsif set_i = '1' then
            main_again <= '1';
         end if;
      end if;
   end process p_main;

   i_cdc_req : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 65,
         G_REGISTER_SRC => false
      )
      port map (
         src_clk_i      => main_clk_i,
         src_data_i     => main_req & main_time,
         dst_clk_i      => qnice_clk_i,
         dst_data_o     => qnice_q
      ); -- i_cdc_req

   i_cdc_ack : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 1,
         G_REGISTER_SRC => false
      )
      port map (
         src_clk_i      => qnice_clk_i,
         src_data_i     => (0 => qnice_ack),
         dst_clk_i      => main_clk_i,
         dst_data_o     => main_ack
      ); -- i_cdc_ack

   ---------------------------------------------------------------------------------------------
   -- QNICE side (writes on the falling edge, like every M2M device)
   ---------------------------------------------------------------------------------------------

   qnice_pending <= qnice_q(64) xor qnice_ack;

   p_qnice : process (qnice_clk_i)
   begin
      if falling_edge(qnice_clk_i) then
         if qnice_ce_i = '1' and qnice_we_i = '1' and qnice_addr_i(27 downto 12) = x"0000" and
            qnice_addr_i(11 downto 0) = x"000" and qnice_data_i(0) = '1' then
            qnice_ack <= qnice_q(64);
         end if;
      end if;
   end process p_qnice;

   p_read : process (all)
      variable v_i : natural range 0 to 7;
   begin
      qnice_data_o <= x"0000";
      if qnice_addr_i(27 downto 4) = x"000000" then
         if qnice_addr_i(3 downto 0) = x"0" then
            qnice_data_o <= x"000" & "000" & qnice_pending;
         elsif unsigned(qnice_addr_i(3 downto 0)) <= 8 then
            v_i := to_integer(unsigned(qnice_addr_i(3 downto 0))) - 1;
            qnice_data_o <= x"00" & qnice_q(8 * v_i + 7 downto 8 * v_i);
         end if;
      end if;
   end process p_read;

end architecture synthesis;
