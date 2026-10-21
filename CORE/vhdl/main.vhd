----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- Wrapper for the PC: pc_system (rtl/system/pc_system.sv; until it exists the stand-in
-- CORE/stub/pc_system.sv) plus what it needs from the MEGA65: keyboard, video into M2M,
-- audio. The RAM and the BIOS ROM are owned by mega65.vhd.
--
-- Video: pc_system gives RGBI on the 14.31818 MHz enable; it becomes 8-bit RGB here with
-- the IBM 5153's brown (colour 6 = dark yellow with half green). The syncs are active high
-- and the blanks cover them already (contract, architecture.md section 4), as M2M wants
-- (Megamiga hard rule 6). video_ce_ovl_o, the enable of the scandoubled picture for the
-- analog OSM, is 2x vid_ce: the 7-clock pixel is split 3 + 4, like the scandoubler's own
-- doubled enable.
--
-- done by Johan Smolinski in 2026, based on the MiSTer2MEGA65 template (sy2002 and
-- MJoergen), licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity main is
   generic (
      G_RAM_KB                : natural := 640
   );
   port (
      clk_main_i              : in  std_logic;
      reset_i                 : in  std_logic;     -- synchronous, high active (all reset sources)

      -- Video output (on clk_main_i with video_ce_o)
      video_ce_o              : out std_logic;
      video_ce_ovl_o          : out std_logic;
      video_red_o             : out std_logic_vector(7 downto 0);
      video_green_o           : out std_logic_vector(7 downto 0);
      video_blue_o            : out std_logic_vector(7 downto 0);
      video_vs_o              : out std_logic;
      video_hs_o              : out std_logic;
      video_hblank_o          : out std_logic;
      video_vblank_o          : out std_logic;

      -- Audio output (signed PCM)
      audio_left_o            : out signed(15 downto 0);
      audio_right_o           : out signed(15 downto 0);

      -- M2M keyboard interface
      kb_key_num_i            : in  integer range 0 to 79;
      kb_key_pressed_n_i      : in  std_logic;

      -- System RAM (pc_ram.vhd in mega65.vhd)
      ram_addr_o              : out std_logic_vector(19 downto 0);
      ram_en_o                : out std_logic;
      ram_we_o                : out std_logic;
      ram_wdata_o             : out std_logic_vector(7 downto 0);
      ram_rdata_i             : in  std_logic_vector(7 downto 0);
      ram_ack_i               : in  std_logic;

      -- BIOS ROM (pc_bios.vhd in mega65.vhd)
      rom_addr_o              : out std_logic_vector(15 downto 0);
      rom_rdata_i             : in  std_logic_vector(7 downto 0);

      -- Configuration
      dip_sw1_i               : in  std_logic_vector(7 downto 0)
   );
end entity main;

architecture synthesis of main is

   component pc_system is
      generic (
         RAM_KB      : integer := 640
      );
      port (
         clk         : in  std_logic;
         reset       : in  std_logic;
         ram_addr    : out std_logic_vector(19 downto 0);
         ram_en      : out std_logic;
         ram_we      : out std_logic;
         ram_wdata   : out std_logic_vector(7 downto 0);
         ram_rdata   : in  std_logic_vector(7 downto 0);
         ram_ack     : in  std_logic;
         rom_addr    : out std_logic_vector(15 downto 0);
         rom_rdata   : in  std_logic_vector(7 downto 0);
         vid_ce      : out std_logic;
         vid_rgbi    : out std_logic_vector(3 downto 0);
         vid_hsync   : out std_logic;
         vid_vsync   : out std_logic;
         vid_hblank  : out std_logic;
         vid_vblank  : out std_logic;
         kbd_code    : in  std_logic_vector(7 downto 0);
         kbd_valid   : in  std_logic;
         kbd_busy    : out std_logic;
         speaker     : out std_logic;
         dip_sw1     : in  std_logic_vector(7 downto 0)
      );
   end component pc_system;

   signal kbd_code     : std_logic_vector(7 downto 0);
   signal kbd_valid    : std_logic;
   signal kbd_busy     : std_logic;

   signal vid_ce       : std_logic;
   signal vid_rgbi     : std_logic_vector(3 downto 0);
   signal vid_hsync    : std_logic;
   signal vid_vsync    : std_logic;
   signal vid_hblank   : std_logic;
   signal vid_vblank   : std_logic;
   signal speaker      : std_logic;

   signal ovl_cnt      : unsigned(2 downto 0) := (others => '0');

   -- RGBI {I, R, G, B} -> 8 bit per channel: 0xAA per colour bit, +0x55 for intensity;
   -- colour 6 (R G, no I) has green halved (0x55): the 5153's brown.
   function chan(c, i : std_logic) return std_logic_vector is
      variable v : unsigned(7 downto 0);
   begin
      v := (others => '0');
      if c = '1' then
         v := v + 16#AA#;
      end if;
      if i = '1' then
         v := v + 16#55#;
      end if;
      return std_logic_vector(v);
   end function chan;

begin

   i_pc_system : pc_system
      generic map (
         RAM_KB      => G_RAM_KB
      )
      port map (
         clk         => clk_main_i,
         reset       => reset_i,
         ram_addr    => ram_addr_o,
         ram_en      => ram_en_o,
         ram_we      => ram_we_o,
         ram_wdata   => ram_wdata_o,
         ram_rdata   => ram_rdata_i,
         ram_ack     => ram_ack_i,
         rom_addr    => rom_addr_o,
         rom_rdata   => rom_rdata_i,
         vid_ce      => vid_ce,
         vid_rgbi    => vid_rgbi,
         vid_hsync   => vid_hsync,
         vid_vsync   => vid_vsync,
         vid_hblank  => vid_hblank,
         vid_vblank  => vid_vblank,
         kbd_code    => kbd_code,
         kbd_valid   => kbd_valid,
         kbd_busy    => kbd_busy,
         speaker     => speaker,
         dip_sw1     => dip_sw1_i
      ); -- i_pc_system

   i_keyboard : entity work.keyboard
      port map (
         clk_main_i      => clk_main_i,
         reset_i         => reset_i,
         key_num_i       => kb_key_num_i,
         key_pressed_n_i => kb_key_pressed_n_i,
         kbd_code_o      => kbd_code,
         kbd_valid_o     => kbd_valid,
         kbd_busy_i      => kbd_busy
      ); -- i_keyboard

   ---------------------------------------------------------------------------------------------
   -- Video
   ---------------------------------------------------------------------------------------------

   p_video : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         -- 2x enable for the analog OSM: at vid_ce and 3 clocks later
         if vid_ce = '1' then
            ovl_cnt <= to_unsigned(1, 3);
         elsif ovl_cnt /= 0 then
            ovl_cnt <= ovl_cnt + 1;
         end if;
      end if;
   end process p_video;

   video_ce_o     <= vid_ce;
   video_ce_ovl_o <= '1' when vid_ce = '1' or ovl_cnt = 3 else '0';

   -- vid_rgbi and the syncs are registers of pc_system that change on vid_ce
   video_red_o    <= chan(vid_rgbi(2), vid_rgbi(3));
   video_green_o  <= x"55" when vid_rgbi = "0110" else chan(vid_rgbi(1), vid_rgbi(3));
   video_blue_o   <= chan(vid_rgbi(0), vid_rgbi(3));
   video_hs_o     <= vid_hsync;
   video_vs_o     <= vid_vsync;
   video_hblank_o <= vid_hblank;
   video_vblank_o <= vid_vblank;

   ---------------------------------------------------------------------------------------------
   -- Audio: the speaker line, 0 or +1/4 full scale, the same on both channels
   ---------------------------------------------------------------------------------------------

   audio_left_o   <= to_signed(16#2000#, 16) when speaker = '1' else (others => '0');
   audio_right_o  <= to_signed(16#2000#, 16) when speaker = '1' else (others => '0');

end architecture synthesis;
