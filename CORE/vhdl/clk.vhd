----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- Clock generator: the one clock of the PC (doc/architecture.md section 1)
--
--    main_clk  = 100 MHz * 55.125 / 5 / 11   = 100.2273 MHz (2205/22 MHz, exact)
--              = 7 x 14.31818 MHz (the PC's OSC)                           CLKOUT1
--    video_clk = 100 MHz * 55.125 / 5 / 38.5 = 28.63636 MHz = 2 x OSC      CLKOUT0
--              (the only fractional divider; M2M's video pipeline runs on it, see main.vhd)
--
-- VCO 1102.5 MHz (600..1440 MHz for -2), PFD 20 MHz. Everything PC-side runs on
-- main_clk with clock enables (ce_14m every 7, the 8088 clock every 21, PCLK every
-- 84 clocks), generated inside pc_system.
--
-- done by Johan Smolinski in 2026, based on the MiSTer2MEGA65 template (sy2002 and
-- MJoergen), licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

library xpm;
use xpm.vcomponents.all;

entity clk is
   port (
      sys_clk_i       : in  std_logic;   -- expects 100 MHz

      main_clk_o      : out std_logic;   -- 100.2273 MHz = 7 x 14.31818 MHz
      main_rst_o      : out std_logic;   -- main's reset, synchronized
      video_clk_o     : out std_logic;   -- 28.63636 MHz = 2 x 14.31818 MHz
      video_rst_o     : out std_logic    -- video reset, synchronized
   );
end entity clk;

architecture rtl of clk is

signal clkfb_mmcm         : std_logic;
signal clkfb              : std_logic;
signal main_clk_mmcm      : std_logic;
signal main_clk           : std_logic;
signal video_clk_mmcm     : std_logic;
signal video_clk          : std_logic;
signal main_locked        : std_logic;

begin

   i_clk_main : MMCME2_ADV
      generic map (
         BANDWIDTH            => "OPTIMIZED",
         CLKOUT4_CASCADE      => FALSE,
         COMPENSATION         => "ZHOLD",
         STARTUP_WAIT         => FALSE,
         CLKIN1_PERIOD        => 10.0,       -- INPUT @ 100 MHz
         REF_JITTER1          => 0.010,
         DIVCLK_DIVIDE        => 5,          -- PFD 20 MHz
         CLKFBOUT_MULT_F      => 55.125,     -- VCO 1102.5 MHz
         CLKFBOUT_PHASE       => 0.000,
         CLKFBOUT_USE_FINE_PS => FALSE,
         CLKOUT0_DIVIDE_F     => 38.500,     -- 28.63636 MHz (video)
         CLKOUT0_PHASE        => 0.000,
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_USE_FINE_PS  => FALSE,
         CLKOUT1_DIVIDE       => 11,         -- 100.2273 MHz (main)
         CLKOUT1_PHASE        => 0.000,
         CLKOUT1_DUTY_CYCLE   => 0.500,
         CLKOUT1_USE_FINE_PS  => FALSE
      )
      port map (
         CLKFBOUT            => clkfb_mmcm,
         CLKOUT0             => video_clk_mmcm,
         CLKOUT1             => main_clk_mmcm,
         CLKFBIN             => clkfb,
         CLKIN1              => sys_clk_i,
         CLKIN2              => '0',
         CLKINSEL            => '1',
         DADDR               => (others => '0'),
         DCLK                => '0',
         DEN                 => '0',
         DI                  => (others => '0'),
         DO                  => open,
         DRDY                => open,
         DWE                 => '0',
         PSCLK               => '0',
         PSEN                => '0',
         PSINCDEC            => '0',
         PSDONE              => open,
         LOCKED              => main_locked,
         CLKINSTOPPED        => open,
         CLKFBSTOPPED        => open,
         PWRDWN              => '0',
         RST                 => '0'
      ); -- i_clk_main

   clkfb_bufg : BUFG
      port map (
         I => clkfb_mmcm,
         O => clkfb
      );

   main_clk_bufg : BUFG
      port map (
         I => main_clk_mmcm,
         O => main_clk
      );

   main_clk_o <= main_clk;

   video_clk_bufg : BUFG
      port map (
         I => video_clk_mmcm,
         O => video_clk
      );

   video_clk_o <= video_clk;

   i_xpm_cdc_async_rst_video : xpm_cdc_async_rst
      generic map (
         RST_ACTIVE_HIGH => 1,
         DEST_SYNC_FF    => 6
      )
      port map (
         src_arst  => not main_locked,
         dest_clk  => video_clk,
         dest_arst => video_rst_o
      );

   i_xpm_cdc_async_rst_main : xpm_cdc_async_rst
      generic map (
         RST_ACTIVE_HIGH => 1,
         DEST_SYNC_FF    => 6
      )
      port map (
         src_arst  => not main_locked,
         dest_clk  => main_clk,
         dest_arst => main_rst_o
      );

end architecture rtl;
