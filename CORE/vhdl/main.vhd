----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- Wrapper for the PC: pc_system (rtl/system/pc_system.sv, through CORE/sv/pc_system_flat.sv;
-- the shell-only stand-in CORE/stub/pc_system.sv has the same ports) plus what it needs from
-- the MEGA65: keyboard, video into M2M, audio. RAM, BIOS ROM, CGA font loader and the floppy
-- backend are owned by mega65.vhd.
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

      -- CGA character ROM load port (pc_font.vhd)
      font_we_i               : in  std_logic;
      font_addr_i             : in  std_logic_vector(12 downto 0);
      font_data_i             : in  std_logic_vector(7 downto 0);
      font_thin_i             : in  std_logic;

      -- Floppy drives and the sector port (pc_fdd_sd.vhd)
      drv_80trk_i             : in  std_logic_vector(1 downto 0);
      img_present_i           : in  std_logic_vector(1 downto 0);
      img_wp_i                : in  std_logic_vector(1 downto 0);
      img_tracks_i            : in  std_logic_vector(15 downto 0);
      img_heads_i             : in  std_logic_vector(3 downto 0);
      img_spt_i               : in  std_logic_vector(11 downto 0);
      drv_motor_o             : out std_logic_vector(1 downto 0);
      fdc_active_o            : out std_logic;
      sp_req_o                : out std_logic;
      sp_write_o              : out std_logic;
      sp_drive_o              : out std_logic;
      sp_lba_o                : out std_logic_vector(15 downto 0);
      sp_rd_valid_i           : in  std_logic;
      sp_rd_data_i            : in  std_logic_vector(7 downto 0);
      sp_wr_valid_o           : out std_logic;
      sp_wr_data_o            : out std_logic_vector(7 downto 0);
      sp_wr_ready_i           : in  std_logic;
      sp_done_i               : in  std_logic;
      sp_err_i                : in  std_logic;

      -- Configuration
      dip_sw1_i               : in  std_logic_vector(7 downto 0)
   );
end entity main;

architecture synthesis of main is

   component pc_system_flat is
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
         font_we     : in  std_logic;
         font_addr   : in  std_logic_vector(12 downto 0);
         font_data   : in  std_logic_vector(7 downto 0);
         font_thin   : in  std_logic;
         drv_80trk   : in  std_logic_vector(1 downto 0);
         img_present : in  std_logic_vector(1 downto 0);
         img_wp      : in  std_logic_vector(1 downto 0);
         img_tracks  : in  std_logic_vector(15 downto 0);
         img_heads   : in  std_logic_vector(3 downto 0);
         img_spt     : in  std_logic_vector(11 downto 0);
         drv_motor   : out std_logic_vector(1 downto 0);
         fdc_active  : out std_logic;
         sp_req      : out std_logic;
         sp_write    : out std_logic;
         sp_drive    : out std_logic;
         sp_cyl      : out std_logic_vector(7 downto 0);
         sp_head     : out std_logic;
         sp_sector   : out std_logic_vector(7 downto 0);
         sp_lba      : out std_logic_vector(15 downto 0);
         sp_rd_valid : in  std_logic;
         sp_rd_data  : in  std_logic_vector(7 downto 0);
         sp_wr_valid : out std_logic;
         sp_wr_data  : out std_logic_vector(7 downto 0);
         sp_wr_ready : in  std_logic;
         sp_done     : in  std_logic;
         sp_err      : in  std_logic;
         kbd_code    : in  std_logic_vector(7 downto 0);
         kbd_valid   : in  std_logic;
         kbd_busy    : out std_logic;
         speaker     : out std_logic;
         dip_sw1     : in  std_logic_vector(7 downto 0)
      );
   end component pc_system_flat;

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

   i_pc_system : pc_system_flat
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
         font_we     => font_we_i,
         font_addr   => font_addr_i,
         font_data   => font_data_i,
         font_thin   => font_thin_i,
         drv_80trk   => drv_80trk_i,
         img_present => img_present_i,
         img_wp      => img_wp_i,
         img_tracks  => img_tracks_i,
         img_heads   => img_heads_i,
         img_spt     => img_spt_i,
         drv_motor   => drv_motor_o,
         fdc_active  => fdc_active_o,
         sp_req      => sp_req_o,
         sp_write    => sp_write_o,
         sp_drive    => sp_drive_o,
         sp_cyl      => open,
         sp_head     => open,
         sp_sector   => open,
         sp_lba      => sp_lba_o,
         sp_rd_valid => sp_rd_valid_i,
         sp_rd_data  => sp_rd_data_i,
         sp_wr_valid => sp_wr_valid_o,
         sp_wr_data  => sp_wr_data_o,
         sp_wr_ready => sp_wr_ready_i,
         sp_done     => sp_done_i,
         sp_err      => sp_err_i,
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
