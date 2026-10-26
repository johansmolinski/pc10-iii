----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- MEGA65 main file that contains the whole machine
--
-- * clk.vhd: the PC's one clock, 28.63636 MHz (main_clk, also the video clock)
-- * main.vhd: pc_system + keyboard + video/audio glue
-- * pc_ram.vhd: 640 KB system RAM in block RAM, no QNICE port (Megamiga hard rule 4)
-- * pc_bios.vhd: 64 KB BIOS ROM, QNICE device C_DEV_PC_BIOS, filled by the Shell's ROM
--   auto-loader from /pc10/bios.rom; the PC stays in reset until the firmware has checked
--   and released the image
-- * pc_font.vhd: the character ROM (free default font, or /pc10/char.rom), QNICE device
--   C_DEV_PC_FONT, copied into pc_system's font port
-- * pc_ucode.vhd: the 8088's microcode bundle (/pc10/ucode.bin, tools/mkucode.py), QNICE
--   device C_DEV_PC_UCODE, copied into the CPU's tables; the PC stays in reset until then
-- * pc_fdd_sd.vhd: floppy A: and B: and the hard disk C: from image files on the SD card (QNICE
--   devices C_DEV_PC_FDA/FDB/HDC, the SD host's engine port); JMP208 of the PC20-III's hard disk
--   (xta_enable) follows the image: no image = no drive, the PC10-III

-- * pc_chipset.vhd: the menu's chipset (FE2010A / 8255), its switches, the restart on a change
-- * pc_drvsnd.vhd: the drive LED (yellow while A: or B: is selected) and the drive sound (the
--   MEGA65's internal drive follows the motors and head steps of A: and B:)
-- * the OSM settings (config.vhd): floppy images and write protection, drive sound, chipset
--   (PC10-III's FE2010A or IBM XT's 8255, with its switches; a change restarts the PC),
--   memory size, display (colour or mono in three phosphors: the PVC4's CONFIG switch 2 with
--   switches 3/4; a change restarts the PC), character set (CONFIG switch 1), HDMI mode (60 Hz for colour, 50 Hz for mono),
--   analog 15 kHz / CSYNC, reset
--
-- The entity is the Megamiga fork's MEGA65_Core (M2M-UPSTREAM exceptions: floppy, SDRAM,
-- PMOD, Ethernet pins and the SD engine port are routed into the core); everything the PC
-- does not use is tied off here with the values of the original board tops.
--
-- done by Johan Smolinski in 2026, based on the MiSTer2MEGA65 template (sy2002 and
-- MJoergen, 2022) and Megamiga's mega65.vhd, licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.globals.all;
use work.types_pkg.all;
use work.video_modes_pkg.all;

entity MEGA65_Core is
generic (
   G_BOARD : string                                         -- Which platform are we running on.
);
port (
   --------------------------------------------------------------------------------------------------------
   -- QNICE Clock Domain
   --------------------------------------------------------------------------------------------------------

   -- Get QNICE clock from the framework: for the vdrives as well as for RAMs and ROMs
   qnice_clk_i             : in  std_logic;
   qnice_rst_i             : in  std_logic;

   -- Video and audio mode control
   qnice_dvi_o             : out std_logic;              -- 0=HDMI (with sound), 1=DVI (no sound)
   qnice_video_mode_o      : out video_mode_type;        -- Defined in video_modes_pkg.vhd
   qnice_osm_cfg_scaling_o : out std_logic_vector(8 downto 0);
   qnice_scandoubler_o     : out std_logic;              -- 0 = no scandoubler, 1 = scandoubler
   qnice_audio_mute_o      : out std_logic;
   qnice_audio_filter_o    : out std_logic;
   qnice_zoom_crop_o       : out std_logic;
   qnice_ascal_mode_o      : out std_logic_vector(1 downto 0);
   qnice_ascal_polyphase_o : out std_logic;
   qnice_ascal_triplebuf_o : out std_logic;
   qnice_retro15kHz_o      : out std_logic;              -- 0 = normal frequency, 1 = retro 15 kHz frequency
   qnice_csync_o           : out std_logic;              -- 0 = normal HS/VS, 1 = Composite Sync

   -- Flip joystick ports
   qnice_flip_joyports_o   : out std_logic;

   -- On-Screen-Menu selections
   qnice_osm_control_i     : in  std_logic_vector(255 downto 0);

   -- QNICE general purpose register
   qnice_gp_reg_i          : in  std_logic_vector(255 downto 0);

   -- Core-specific devices
   qnice_dev_id_i          : in  std_logic_vector(15 downto 0);
   qnice_dev_addr_i        : in  std_logic_vector(27 downto 0);
   qnice_dev_data_i        : in  std_logic_vector(15 downto 0);
   qnice_dev_data_o        : out std_logic_vector(15 downto 0);
   qnice_dev_ce_i          : in  std_logic;
   qnice_dev_we_i          : in  std_logic;
   qnice_dev_wait_o        : out std_logic;

   --------------------------------------------------------------------------------------------------------
   -- HyperRAM Clock Domain
   --------------------------------------------------------------------------------------------------------

   hr_clk_i                : in  std_logic;
   hr_rst_i                : in  std_logic;
   hr_core_write_o         : out std_logic;
   hr_core_read_o          : out std_logic;
   hr_core_address_o       : out std_logic_vector(31 downto 0);
   hr_core_writedata_o     : out std_logic_vector(15 downto 0);
   hr_core_byteenable_o    : out std_logic_vector( 1 downto 0);
   hr_core_burstcount_o    : out std_logic_vector( 7 downto 0);
   hr_core_readdata_i      : in  std_logic_vector(15 downto 0);
   hr_core_readdatavalid_i : in  std_logic;
   hr_core_waitrequest_i   : in  std_logic;
   hr_high_i               : in  std_logic;  -- Core is too fast
   hr_low_i                : in  std_logic;  -- Core is too slow

   --------------------------------------------------------------------------------------------------------
   -- Video Clock Domain
   --------------------------------------------------------------------------------------------------------

   video_clk_o             : out std_logic;
   video_rst_o             : out std_logic;
   video_ce_o              : out std_logic;
   video_ce_ovl_o          : out std_logic;
   video_red_o             : out std_logic_vector(7 downto 0);
   video_green_o           : out std_logic_vector(7 downto 0);
   video_blue_o            : out std_logic_vector(7 downto 0);
   video_vs_o              : out std_logic;
   video_hs_o              : out std_logic;
   video_hblank_o          : out std_logic;
   video_vblank_o          : out std_logic;
   video_fl_o              : out std_logic;  -- interlace field flag for ascal weave deinterlacing

   -- M2M-UPSTREAM rtg-framebuffer (Megamiga 2026-10-09): the RTG graphics card - ascal shows
   -- the framebuffer in HyperRAM instead of the Amiga picture while fb_ena_o = '1' (HDMI only:
   -- the analog output keeps the Amiga picture). Core clock domain, slowly changing.
   fb_ena_o                : out std_logic;
   fb_hsize_o              : out std_logic_vector(11 downto 0);
   fb_vsize_o              : out std_logic_vector(11 downto 0);
   fb_format_o             : out std_logic_vector( 5 downto 0);
   fb_base_o               : out std_logic_vector(31 downto 0);  -- HyperRAM byte address
   fb_stride_o             : out std_logic_vector(13 downto 0);
   fb_pal_clk_o            : out std_logic;
   fb_pal_a_o              : out std_logic_vector( 7 downto 0);
   fb_pal_dw_o             : out std_logic_vector(23 downto 0);
   fb_pal_wr_o             : out std_logic;
   fb_pal_dr_i             : in  std_logic_vector(23 downto 0) := (others => '0');

   --------------------------------------------------------------------------------------------------------
   -- Core Clock Domain
   --------------------------------------------------------------------------------------------------------

   clk_i                   : in  std_logic;              -- 100 MHz clock

   -- Share clock and reset with the framework
   main_clk_o              : out std_logic;              -- the PC's 28.63636 MHz clock
   main_rst_o              : out std_logic;              -- CORE's reset, synchronized

   -- M2M's reset manager provides 2 signals:
   --    m2m:   Reset the whole machine: Core and Framework
   --    core:  Only reset the core
   main_reset_m2m_i        : in  std_logic;
   main_reset_core_i       : in  std_logic;

   main_pause_core_i       : in  std_logic;

   -- On-Screen-Menu selections
   main_osm_control_i      : in  std_logic_vector(255 downto 0);

   -- QNICE general purpose register converted to main clock domain
   main_qnice_gp_reg_i     : in  std_logic_vector(255 downto 0);

   -- Audio output (Signed PCM)
   main_audio_left_o       : out signed(15 downto 0);
   main_audio_right_o      : out signed(15 downto 0);

   -- M2M Keyboard interface (incl. power led and drive led)
   main_kb_key_num_i       : in  integer range 0 to 79;  -- cycles through all MEGA65 keys
   main_kb_key_pressed_n_i : in  std_logic;              -- low active: debounced feedback: is kb_key_num_i pressed right now?
   main_kb_key_raw_n_i     : in  std_logic;              -- the same, also while the OSM is open (M2M osm-hotkey)
   main_power_led_o        : out std_logic;
   main_power_led_col_o    : out std_logic_vector(23 downto 0);
   main_drive_led_o        : out std_logic;
   main_drive_led_col_o    : out std_logic_vector(23 downto 0);

   -- OSM-open key selection (issue #8): the core decodes the "OSM: %s" radio and
   -- tells the framework's m2m_keyb which key(s) drive the menu-open bit
   -- (qnice_keys bit 7). Threaded core->framework->m2m_keyb, exactly like video_fl_o.
   osm_key_a_o             : out integer range 0 to 79;
   osm_key_b_o             : out integer range 0 to 79;
   osm_combo_o             : out std_logic;
   -- Megamiga (M2M-UPSTREAM osm-hotkey): '1' = the menu key must not open the menu now
   -- (CTRL+MEGA are held: CTRL+MEGA+HELP is the cartridge's freeze button)
   osm_block_o             : out std_logic;

   -- Joysticks and paddles input
   main_joy_1_up_n_i       : in  std_logic;
   main_joy_1_down_n_i     : in  std_logic;
   main_joy_1_left_n_i     : in  std_logic;
   main_joy_1_right_n_i    : in  std_logic;
   main_joy_1_fire_n_i     : in  std_logic;
   main_joy_1_up_n_o       : out std_logic;
   main_joy_1_down_n_o     : out std_logic;
   main_joy_1_left_n_o     : out std_logic;
   main_joy_1_right_n_o    : out std_logic;
   main_joy_1_fire_n_o     : out std_logic;
   main_joy_2_up_n_i       : in  std_logic;
   main_joy_2_down_n_i     : in  std_logic;
   main_joy_2_left_n_i     : in  std_logic;
   main_joy_2_right_n_i    : in  std_logic;
   main_joy_2_fire_n_i     : in  std_logic;
   main_joy_2_up_n_o       : out std_logic;
   main_joy_2_down_n_o     : out std_logic;
   main_joy_2_left_n_o     : out std_logic;
   main_joy_2_right_n_o    : out std_logic;
   main_joy_2_fire_n_o     : out std_logic;

   main_pot1_x_i           : in  std_logic_vector(7 downto 0);
   main_pot1_y_i           : in  std_logic_vector(7 downto 0);
   main_pot2_x_i           : in  std_logic_vector(7 downto 0);
   main_pot2_y_i           : in  std_logic_vector(7 downto 0);
   main_rtc_i              : in  std_logic_vector(64 downto 0);

   -- CBM-488/IEC serial port
   iec_reset_n_o           : out std_logic;
   iec_atn_n_o             : out std_logic;
   iec_clk_en_o            : out std_logic;
   iec_clk_n_i             : in  std_logic;
   iec_clk_n_o             : out std_logic;
   iec_data_en_o           : out std_logic;
   iec_data_n_i            : in  std_logic;
   iec_data_n_o            : out std_logic;
   iec_srq_en_o            : out std_logic;
   iec_srq_n_i             : in  std_logic;
   iec_srq_n_o             : out std_logic;

   -- MEGA65 internal floppy drive (Hardware Floppy feature): the 34-pin
   -- connector, threaded as plain wires from the board tops (M2M-UPSTREAM
   -- floppy-pins; the C64MEGA65 issue-#90 pattern). All active low. Drive B
   -- (f_motorb/f_selectb) stays tied '1' at the top level; the WRITE pins
   -- f_wdata/f_wgate are driven by physical_fdd_writer since WIP-V2-A9.
   f_wdata_o               : out std_logic;
   f_wgate_o               : out std_logic;
   f_motora_o              : out std_logic;
   f_selecta_o             : out std_logic;
   f_side1_o               : out std_logic;
   f_stepdir_o             : out std_logic;
   f_step_o                : out std_logic;
   f_density_o             : out std_logic;
   f_index_i               : in  std_logic;
   f_track0_i              : in  std_logic;
   f_writeprotect_i        : in  std_logic;
   f_rdata_i               : in  std_logic;
   f_diskchanged_i         : in  std_logic;

   -- SDRAM (R4/R5/R6 only: IS42S16320F, 32M x 16): the 8 MB Zorro II Fast RAM,
   -- threaded as plain wires from the board tops (M2M-UPSTREAM sdram-pins, the
   -- floppy-pins pattern). The R3 top has no SDRAM and leaves these unconnected;
   -- the R3 build then also ignores the Fast RAM menu bit (see C_HAS_SDRAM).
   sdram_clk_o             : out   std_logic;
   sdram_cke_o             : out   std_logic;
   sdram_ras_n_o           : out   std_logic;
   sdram_cas_n_o           : out   std_logic;
   sdram_we_n_o            : out   std_logic;
   sdram_cs_n_o            : out   std_logic;
   sdram_ba_o              : out   std_logic_vector(1 downto 0);
   sdram_a_o               : out   std_logic_vector(12 downto 0);
   sdram_dqml_o            : out   std_logic;
   sdram_dqmh_o            : out   std_logic;
   sdram_dq_io             : inout std_logic_vector(15 downto 0);

   -- PMOD headers (R4/R5/R6 only): the Amiga serial port on PMOD1, threaded as
   -- plain wires from the board tops (M2M-UPSTREAM pmod-pins, the floppy-pins
   -- pattern). All pins stay high-Z and both headers unpowered unless the
   -- "Serial port on PMOD" menu item is on. The R3 top leaves these unconnected.
   p1lo_io                 : inout std_logic_vector(3 downto 0);
   p1hi_io                 : inout std_logic_vector(3 downto 0);
   p2lo_io                 : inout std_logic_vector(3 downto 0);
   p2hi_io                 : inout std_logic_vector(3 downto 0);
   pmod1_en_o              : out   std_logic;
   pmod2_en_o              : out   std_logic;

   -- Ethernet PHY KSZ8081 (R4/R5/R6 only): the network card (eth_card.vhd), threaded as plain
   -- wires from the board tops (M2M-UPSTREAM eth-pins, the floppy-pins pattern). The R3 top
   -- leaves these unconnected.
   eth_clock_o             : out   std_logic;
   eth_led2_o              : out   std_logic;
   eth_mdc_o               : out   std_logic;
   eth_mdio_io             : inout std_logic;
   eth_reset_o             : out   std_logic;
   eth_rxd_i               : in    std_logic_vector(1 downto 0) := "00";
   eth_rxdv_i              : in    std_logic := '0';
   eth_rxer_i              : in    std_logic := '0';
   eth_txd_o               : out   std_logic_vector(1 downto 0);
   eth_txen_o              : out   std_logic;

   -- The engine port of the SD host controller (M2M-UPSTREAM sd-host, sdhost_pkg; QNICE
   -- clock domain): the IDE board's sector engine streams HDF sectors through it
   sd_eng_i                : in    std_logic_vector(63 downto 0) := (others => '0');
   sd_eng_o                : out   std_logic_vector(75 downto 0);

   -- C64 Expansion Port (aka Cartridge Port)
   cart_en_o               : out std_logic;  -- Enable port, active high
   cart_phi2_o             : out std_logic;
   cart_dotclock_o         : out std_logic;
   cart_dma_i              : in  std_logic;
   cart_reset_oe_o         : out std_logic;
   cart_reset_i            : in  std_logic;
   cart_reset_o            : out std_logic;
   cart_game_oe_o          : out std_logic;
   cart_game_i             : in  std_logic;
   cart_game_o             : out std_logic;
   cart_exrom_oe_o         : out std_logic;
   cart_exrom_i            : in  std_logic;
   cart_exrom_o            : out std_logic;
   cart_nmi_oe_o           : out std_logic;
   cart_nmi_i              : in  std_logic;
   cart_nmi_o              : out std_logic;
   cart_irq_oe_o           : out std_logic;
   cart_irq_i              : in  std_logic;
   cart_irq_o              : out std_logic;
   cart_roml_oe_o          : out std_logic;
   cart_roml_i             : in  std_logic;
   cart_roml_o             : out std_logic;
   cart_romh_oe_o          : out std_logic;
   cart_romh_i             : in  std_logic;
   cart_romh_o             : out std_logic;
   cart_ctrl_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_ba_i               : in  std_logic;
   cart_rw_i               : in  std_logic;
   cart_io1_i              : in  std_logic;
   cart_io2_i              : in  std_logic;
   cart_ba_o               : out std_logic;
   cart_rw_o               : out std_logic;
   cart_io1_o              : out std_logic;
   cart_io2_o              : out std_logic;
   cart_addr_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_a_i                : in  unsigned(15 downto 0);
   cart_a_o                : out unsigned(15 downto 0);
   cart_data_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_d_i                : in  unsigned( 7 downto 0);
   cart_d_o                : out unsigned( 7 downto 0)
);
end entity MEGA65_Core;

architecture synthesis of MEGA65_Core is

---------------------------------------------------------------------------------------------
-- OSM menu bits (= line numbers of OPTM_ITEMS in config.vhd; keep single-line, make_rom.sh
-- scrapes them into osm_const.asm as PC_OSM_*)
---------------------------------------------------------------------------------------------

constant C_MENU_FDA_LN        : natural := 2;   -- " A:%s" (the firmware's SPACE eject)
constant C_MENU_FDB_LN        : natural := 3;   -- " B:%s"
constant C_MENU_HDC_LN        : natural := 4;   -- " C:%s" (the hard disk image)
constant C_MENU_WP_A          : natural := 5;
constant C_MENU_WP_B          : natural := 6;
constant C_MENU_DRV_SOUND     : natural := 7;
constant C_MENU_CHIP_PC10     : natural := 12;
constant C_MENU_CHIP_XT       : natural := 13;
constant C_MENU_MEM_640       : natural := 19;
constant C_MENU_MEM_512       : natural := 20;
constant C_MENU_MEM_256       : natural := 21;
constant C_MENU_MEM_128       : natural := 22;
constant C_MENU_DISP_GREEN    : natural := 37;
constant C_MENU_DISP_AMBER    : natural := 38;
constant C_MENU_DISP_WHITE    : natural := 39;
constant C_MENU_CHARSET_SCAN  : natural := 42;
constant C_MENU_HDMI_720P     : natural := 28;
constant C_MENU_HDMI_480P     : natural := 29;
constant C_MENU_HDMI_720P50   : natural := 30;
constant C_MENU_ANALOG_15KHZ  : natural := 43;
constant C_MENU_ANALOG_CSYNC  : natural := 44;
constant C_MENU_RESET         : natural := 47;

-- The PC's switches in the 5160 layout (bit = 1: switch off), per chipset (the menu's
-- "Chipset", xt_board.sv's fe2010a). PC10-III, as the FE2010A gives them: bit 0 = 1 normal
-- POST, bit 1 = 0 no 8087, bits 3..2 = 11 memory, bits 7..6 = 01 two floppy drives (bits 0-3,
-- 6-7 are the reset value of the chip's switch register, which the BIOS rewrites); bits 5..4
-- are the VID0/VID1 pins, the PC10-III's CONFIG switches 3 and 4: 01 = switch 3 off, 4 on =
-- 80 x 25 colour (the Commodore BIOS swaps 01/10 into the IBM equipment bits; manual section
-- 2.2). IBM XT (5160 SW1 as the 8255 reads it): bits 5..4 = 10 CGA 80 x 25, the rest the
-- same. tb/sys 5160 runs use 0x6D, FE2010A runs (make FE=1) -d 5D.
constant C_DIP_SW1_FE         : std_logic_vector(7 downto 0) := x"5D";
constant C_DIP_SW1_XT         : std_logic_vector(7 downto 0) := x"6D";

---------------------------------------------------------------------------------------------
-- Clocks and resets
---------------------------------------------------------------------------------------------

signal main_clk               : std_logic;
signal main_rst               : std_logic;
signal video_clk              : std_logic;
signal video_rst              : std_logic;
signal main_pc_reset          : std_logic := '1';
attribute max_fanout : integer;
attribute max_fanout of main_pc_reset : signal is 32;    -- the PC's synchronous reset
signal main_bios_valid        : std_logic;
signal main_ucode_valid       : std_logic;
signal main_ucl_we            : std_logic;
signal main_ucl_addr          : std_logic_vector(12 downto 0);
signal main_ucl_data          : std_logic_vector(7 downto 0);
signal main_mem_size          : std_logic_vector(1 downto 0);
signal main_fe2010a           : std_logic;             -- the chipset: 1 = PC10-III (FE2010A)
signal main_chip_rst          : std_logic;
signal main_dip_sw1           : std_logic_vector(7 downto 0);
signal main_cbm_dip           : std_logic_vector(1 downto 0);   -- CONFIG switches 2 and 1
signal main_mono              : std_logic;             -- the menu's display: mono
signal main_mono_tint         : std_logic_vector(1 downto 0);
signal main_charset           : std_logic;             -- CONFIG switch 1: 1 = off = USA/Europe

---------------------------------------------------------------------------------------------
-- PC memory ports
---------------------------------------------------------------------------------------------

signal main_ram_addr          : std_logic_vector(19 downto 0);
signal main_ram_en            : std_logic;
signal main_ram_we            : std_logic;
signal main_ram_wdata         : std_logic_vector(7 downto 0);
signal main_ram_rdata         : std_logic_vector(7 downto 0);
signal main_ram_ack           : std_logic;
signal main_rom_addr          : std_logic_vector(15 downto 0);
signal main_rom_rdata         : std_logic_vector(7 downto 0);

---------------------------------------------------------------------------------------------
-- QNICE clock domain
---------------------------------------------------------------------------------------------

signal qnice_bios_data        : std_logic_vector(15 downto 0);
signal qnice_bios_ce          : std_logic;
signal qnice_bios_we          : std_logic;
signal qnice_font_data        : std_logic_vector(15 downto 0);
signal qnice_font_ce          : std_logic;
signal qnice_font_we          : std_logic;
signal qnice_ucode_data       : std_logic_vector(15 downto 0);
signal qnice_ucode_ce         : std_logic;
signal qnice_ucode_we         : std_logic;
signal qnice_fdd_data         : std_logic_vector(15 downto 0);
signal qnice_fdd_ce           : std_logic;
signal qnice_fdd_we           : std_logic;
signal qnice_fdd_drive        : std_logic_vector(1 downto 0);   -- 0 A:, 1 B:, 2 C:

---------------------------------------------------------------------------------------------
-- font port, floppy drives and the sector port (main clock)
---------------------------------------------------------------------------------------------

signal main_font_we           : std_logic;
signal main_font_addr         : std_logic_vector(14 downto 0);
signal main_font_cbm          : std_logic;             -- a Commodore character ROM (pc_font.vhd)
signal main_font_data         : std_logic_vector(7 downto 0);
signal main_drv_80trk         : std_logic_vector(1 downto 0);
signal main_img_present       : std_logic_vector(1 downto 0);
signal main_img_wp            : std_logic_vector(1 downto 0);
signal main_img_tracks        : std_logic_vector(15 downto 0);
signal main_img_heads         : std_logic_vector(3 downto 0);
signal main_img_spt           : std_logic_vector(11 downto 0);
signal main_drv_motor         : std_logic_vector(1 downto 0);
signal main_drv_select        : std_logic_vector(1 downto 0);
signal main_drv_step          : std_logic;
signal main_drv_step_in       : std_logic;
signal main_sp_req            : std_logic;
signal main_sp_write          : std_logic;
signal main_sp_drive          : std_logic;
signal main_sp_lba            : std_logic_vector(15 downto 0);
signal main_sp_rd_valid       : std_logic;
signal main_sp_rd_data        : std_logic_vector(7 downto 0);
signal main_sp_wr_valid       : std_logic;
signal main_sp_wr_data        : std_logic_vector(7 downto 0);
signal main_sp_wr_ready       : std_logic;
signal main_sp_done           : std_logic;
signal main_sp_err            : std_logic;
-- the PC20-III's hard disk (xta_card.sv) and its sector port
signal main_xta_present       : std_logic;
signal main_xta_active        : std_logic;
signal main_xta_sp_req        : std_logic;
signal main_xta_sp_write      : std_logic;
signal main_xta_sp_lba        : std_logic_vector(27 downto 0);
signal main_xta_sp_rd_valid   : std_logic;
signal main_xta_sp_rd_data    : std_logic_vector(7 downto 0);
signal main_xta_sp_wr_valid   : std_logic;
signal main_xta_sp_wr_data    : std_logic_vector(7 downto 0);
signal main_xta_sp_wr_ready   : std_logic;
signal main_xta_sp_done       : std_logic;
signal main_xta_sp_err        : std_logic;

begin

   ---------------------------------------------------------------------------------------------
   -- Tie-offs: everything the PC does not use (values of the original M2M board tops)
   ---------------------------------------------------------------------------------------------

   hr_core_write_o      <= '0';
   hr_core_read_o       <= '0';
   hr_core_address_o    <= (others => '0');
   hr_core_writedata_o  <= (others => '0');
   hr_core_byteenable_o <= (others => '0');
   hr_core_burstcount_o <= (others => '0');

   -- M2M-UPSTREAM rtg-framebuffer: off (ascal shows the core's picture)
   fb_ena_o             <= '0';
   fb_hsize_o           <= (others => '0');
   fb_vsize_o           <= (others => '0');
   fb_format_o          <= (others => '0');
   fb_base_o            <= (others => '0');
   fb_stride_o          <= (others => '0');
   fb_pal_clk_o         <= '0';
   fb_pal_a_o           <= (others => '0');
   fb_pal_dw_o          <= (others => '0');
   fb_pal_wr_o          <= '0';

   -- M2M-UPSTREAM interlace: progressive
   video_fl_o           <= '0';

   -- M2M-UPSTREAM osm-hotkey: the classic Help key opens the menu
   osm_key_a_o          <= 67;
   osm_key_b_o          <= 67;
   osm_combo_o          <= '0';
   osm_block_o          <= '0';

   -- IEC port: idle
   iec_reset_n_o        <= '1';
   iec_atn_n_o          <= '1';
   iec_clk_en_o         <= '0';
   iec_clk_n_o          <= '1';
   iec_data_en_o        <= '0';
   iec_data_n_o         <= '1';
   iec_srq_en_o         <= '0';
   iec_srq_n_o          <= '1';

   -- M2M-UPSTREAM floppy-pins: the internal drive plays the drive sound (pc_drvsnd.vhd: motor,
   -- select, direction, step); write gate, write data, side and density stay inactive (the
   -- DD-safe density level): nothing on a disk in it is touched
   f_wdata_o            <= '1';
   f_wgate_o            <= '1';
   f_side1_o            <= '1';
   f_density_o          <= '1';

   -- M2M-UPSTREAM sdram-pins: SDRAM idle (the PC keeps everything in block RAM; R3 has none)
   sdram_clk_o          <= '0';
   sdram_cke_o          <= '0';
   sdram_ras_n_o        <= '1';
   sdram_cas_n_o        <= '1';
   sdram_we_n_o         <= '1';
   sdram_cs_n_o         <= '1';
   sdram_ba_o           <= (others => '0');
   sdram_a_o            <= (others => '0');
   sdram_dqml_o         <= '0';
   sdram_dqmh_o         <= '0';
   sdram_dq_io          <= (others => 'Z');

   -- M2M-UPSTREAM pmod-pins: high-Z, headers unpowered
   p1lo_io              <= (others => 'Z');
   p1hi_io              <= (others => 'Z');
   p2lo_io              <= (others => 'Z');
   p2hi_io              <= (others => 'Z');
   pmod1_en_o           <= '0';
   pmod2_en_o           <= '0';

   -- M2M-UPSTREAM eth-pins: PHY held idle
   eth_clock_o          <= '0';
   eth_led2_o           <= '0';
   eth_mdc_o            <= '0';
   eth_mdio_io          <= 'Z';
   eth_reset_o          <= '1';
   eth_txd_o            <= (others => '0');
   eth_txen_o           <= '0';


   -- Expansion port: tristate everything; enabled because of the R5/R6 joystick port 2 bug
   cart_ctrl_oe_o       <= '0';
   cart_addr_oe_o       <= '0';
   cart_data_oe_o       <= '0';
   cart_en_o            <= '1';
   cart_reset_oe_o      <= '0';
   cart_game_oe_o       <= '0';
   cart_exrom_oe_o      <= '0';
   cart_nmi_oe_o        <= '0';
   cart_irq_oe_o        <= '0';
   cart_roml_oe_o       <= '0';
   cart_romh_oe_o       <= '0';
   cart_phi2_o          <= '0';
   cart_reset_o         <= '1';
   cart_dotclock_o      <= '0';
   cart_game_o          <= '1';
   cart_exrom_o         <= '1';
   cart_nmi_o           <= '1';
   cart_irq_o           <= '1';
   cart_roml_o          <= '0';
   cart_romh_o          <= '0';
   cart_ba_o            <= '0';
   cart_rw_o            <= '0';
   cart_io1_o           <= '0';
   cart_io2_o           <= '0';
   cart_a_o             <= (others => '0');
   cart_d_o             <= (others => '0');

   main_joy_1_up_n_o    <= '1';
   main_joy_1_down_n_o  <= '1';
   main_joy_1_left_n_o  <= '1';
   main_joy_1_right_n_o <= '1';
   main_joy_1_fire_n_o  <= '1';
   main_joy_2_up_n_o    <= '1';
   main_joy_2_down_n_o  <= '1';
   main_joy_2_left_n_o  <= '1';
   main_joy_2_right_n_o <= '1';
   main_joy_2_fire_n_o  <= '1';

   ---------------------------------------------------------------------------------------------
   -- Clock
   ---------------------------------------------------------------------------------------------

   clk_gen : entity work.clk
      port map (
         sys_clk_i         => clk_i,           -- expects 100 MHz
         main_clk_o        => main_clk,        -- 28.63636 MHz
         main_rst_o        => main_rst,
         video_clk_o       => video_clk,       -- the same clock
         video_rst_o       => video_rst
      ); -- clk_gen

   main_clk_o  <= main_clk;
   main_rst_o  <= main_rst;
   video_clk_o <= video_clk;
   video_rst_o <= video_rst;

   ---------------------------------------------------------------------------------------------
   -- main_clk
   ---------------------------------------------------------------------------------------------

   -- Power LED: green; blue while the reset button is held long. Drive LED (pc_drvsnd.vhd):
   -- yellow while drive A: or B: is selected (DOR select + its motor bit, the drive's own LED),
   -- else red while the hard disk is active.
   main_power_led_o     <= '1';
   main_power_led_col_o <= x"0000FF" when main_reset_m2m_i else x"00FF00";

   i_pc_drvsnd : entity work.pc_drvsnd
      port map (
         clk_i                => main_clk,
         rst_i                => main_rst,
         sound_i              => main_osm_control_i(C_MENU_DRV_SOUND),
         drv_motor_i          => main_drv_motor,
         drv_select_i         => main_drv_select,
         drv_step_i           => main_drv_step,
         drv_step_in_i        => main_drv_step_in,
         hd_active_i          => main_xta_active,
         led_o                => main_drive_led_o,
         led_col_o            => main_drive_led_col_o,
         f_motora_o           => f_motora_o,
         f_selecta_o          => f_selecta_o,
         f_stepdir_o          => f_stepdir_o,
         f_step_o             => f_step_o,
         f_track0_i           => f_track0_i,
         f_diskchanged_i      => f_diskchanged_i,
         cyl_o                => open,
         known_o              => open,
         disk_o               => open
      ); -- i_pc_drvsnd

   -- Every reset source, registered (pc_system wants a synchronous reset): the MMCM lock,
   -- the M2M resets (reset button short/long, the Shell's CSR reset, i.e. the OSM's "Reset
   -- the PC" and the loading of the BIOS), a BIOS that has not been released yet, and a
   -- change of the menu's chipset: it restarts the PC (pc_chipset.vhd: 2.3 ms of reset;
   -- xt_board takes the chipset while reset is high, the switches follow it).
   p_reset : process (main_clk)
   begin
      if rising_edge(main_clk) then
         main_pc_reset <= main_rst or main_reset_core_i or main_reset_m2m_i or not main_bios_valid or
                          not main_ucode_valid or main_chip_rst;
      end if;
   end process p_reset;

   i_pc_chipset : entity work.pc_chipset
      generic map (
         G_SW1_FE             => C_DIP_SW1_FE,
         G_SW1_XT             => C_DIP_SW1_XT
      )
      port map (
         clk_i                => main_clk,
         xt_i                 => main_osm_control_i(C_MENU_CHIP_XT),
         mono_i               => main_mono,
         fe2010a_o            => main_fe2010a,
         dip_sw1_o            => main_dip_sw1,
         cbm_dip_o            => main_cbm_dip,
         rst_o                => main_chip_rst
      ); -- i_pc_chipset

   -- the menu's display: colour, or mono in one of three phosphors (the PVC4's mono
   -- personality; main.vhd)
   main_mono      <= main_osm_control_i(C_MENU_DISP_GREEN) or main_osm_control_i(C_MENU_DISP_AMBER) or
                     main_osm_control_i(C_MENU_DISP_WHITE);
   -- CONFIG switch 1 (the character set) is the character ROM's A14, live as on the board
   main_charset   <= not main_osm_control_i(C_MENU_CHARSET_SCAN);

   main_mono_tint <= "01" when main_osm_control_i(C_MENU_DISP_AMBER) = '1' else
                     "10" when main_osm_control_i(C_MENU_DISP_WHITE) = '1' else
                     "00";

   main_mem_size <= "01" when main_osm_control_i(C_MENU_MEM_512) = '1' else
                    "10" when main_osm_control_i(C_MENU_MEM_256) = '1' else
                    "11" when main_osm_control_i(C_MENU_MEM_128) = '1' else
                    "00";

   i_main : entity work.main
      generic map (
         G_RAM_KB             => 640
      )
      port map (
         clk_main_i           => main_clk,
         reset_i              => main_pc_reset,
         fe2010a_i            => main_fe2010a,

         video_ce_o           => video_ce_o,
         video_ce_ovl_o       => video_ce_ovl_o,
         video_red_o          => video_red_o,
         video_green_o        => video_green_o,
         video_blue_o         => video_blue_o,
         video_vs_o           => video_vs_o,
         video_hs_o           => video_hs_o,
         video_hblank_o       => video_hblank_o,
         video_vblank_o       => video_vblank_o,

         audio_left_o         => main_audio_left_o,
         audio_right_o        => main_audio_right_o,

         kb_key_num_i         => main_kb_key_num_i,
         kb_key_pressed_n_i   => main_kb_key_pressed_n_i,

         ram_addr_o           => main_ram_addr,
         ram_en_o             => main_ram_en,
         ram_we_o             => main_ram_we,
         ram_wdata_o          => main_ram_wdata,
         ram_rdata_i          => main_ram_rdata,
         ram_ack_i            => main_ram_ack,

         rom_addr_o           => main_rom_addr,
         rom_rdata_i          => main_rom_rdata,

         font_we_i            => main_font_we,
         font_addr_i          => main_font_addr,
         font_data_i          => main_font_data,
         font_cbm_i           => main_font_cbm,
         font_thin_i          => '0',          -- the IBM CGA's jumper P3; the PVC4 has none
         cbm_dip_i            => main_cbm_dip(1) & main_charset,
         mono_tint_i          => main_mono_tint,
         ucl_we_i             => main_ucl_we,
         ucl_addr_i           => main_ucl_addr,
         ucl_data_i           => main_ucl_data,

         drv_80trk_i          => main_drv_80trk,
         img_present_i        => main_img_present,
         img_wp_i             => main_img_wp,
         img_tracks_i         => main_img_tracks,
         img_heads_i          => main_img_heads,
         img_spt_i            => main_img_spt,
         drv_motor_o          => main_drv_motor,
         fdc_active_o         => open,
         drv_select_o         => main_drv_select,
         drv_step_o           => main_drv_step,
         drv_step_in_o        => main_drv_step_in,
         sp_req_o             => main_sp_req,
         sp_write_o           => main_sp_write,
         sp_drive_o           => main_sp_drive,
         sp_lba_o             => main_sp_lba,
         sp_rd_valid_i        => main_sp_rd_valid,
         sp_rd_data_i         => main_sp_rd_data,
         sp_wr_valid_o        => main_sp_wr_valid,
         sp_wr_data_o         => main_sp_wr_data,
         sp_wr_ready_i        => main_sp_wr_ready,
         sp_done_i            => main_sp_done,
         sp_err_i             => main_sp_err,

         -- JMP208 follows the image (doc/xta.md section 11): without one the PC10-III, which
         -- has no drive ("Hard disk not found" at once)
         xta_enable_i         => main_xta_present,
         xta_present_i        => main_xta_present,
         xta_active_o         => main_xta_active,
         xta_sp_req_o         => main_xta_sp_req,
         xta_sp_write_o       => main_xta_sp_write,
         xta_sp_lba_o         => main_xta_sp_lba,
         xta_sp_rd_valid_i    => main_xta_sp_rd_valid,
         xta_sp_rd_data_i     => main_xta_sp_rd_data,
         xta_sp_wr_valid_o    => main_xta_sp_wr_valid,
         xta_sp_wr_data_o     => main_xta_sp_wr_data,
         xta_sp_wr_ready_i    => main_xta_sp_wr_ready,
         xta_sp_done_i        => main_xta_sp_done,
         xta_sp_err_i         => main_xta_sp_err,

         dip_sw1_i            => main_dip_sw1
      ); -- i_main

   i_pc_ram : entity work.pc_ram
      port map (
         clk_i                => main_clk,
         size_i               => main_mem_size,
         ram_addr_i           => main_ram_addr,
         ram_en_i             => main_ram_en,
         ram_we_i             => main_ram_we,
         ram_wdata_i          => main_ram_wdata,
         ram_rdata_o          => main_ram_rdata,
         ram_ack_o            => main_ram_ack
      ); -- i_pc_ram

   ---------------------------------------------------------------------------------------------
   -- Audio and video settings (QNICE clock domain)
   ---------------------------------------------------------------------------------------------

   -- The PVC4's colour personality is a 59.92 Hz source, its mono personality 49.8 Hz: 720p
   -- 60 Hz (default) or 480p 59.94 Hz for colour, 720p 50 Hz for mono (one source frame per
   -- output frame, nearly; at 60 Hz every fifth frame repeats).
   qnice_video_mode_o <= C_VIDEO_HDMI_720_5994 when qnice_osm_control_i(C_MENU_HDMI_480P) = '1' else
                         C_VIDEO_HDMI_16_9_50 when qnice_osm_control_i(C_MENU_HDMI_720P50) = '1' else
                         C_VIDEO_HDMI_16_9_60;

   qnice_dvi_o                <= '0';                                         -- HDMI with sound
   -- Analog: VGA at 31.4 kHz through the scandoubler (default), or the CGA's 15.7 kHz RGB
   -- (optionally with composite sync) for a CRT
   qnice_scandoubler_o        <= not qnice_osm_control_i(C_MENU_ANALOG_15KHZ);
   qnice_retro15kHz_o         <= qnice_osm_control_i(C_MENU_ANALOG_15KHZ);
   qnice_csync_o              <= qnice_osm_control_i(C_MENU_ANALOG_CSYNC);
   qnice_audio_mute_o         <= '0';
   qnice_audio_filter_o       <= '0';
   qnice_zoom_crop_o          <= '0';
   qnice_osm_cfg_scaling_o    <= (others => '1');
   qnice_ascal_mode_o         <= "00";
   qnice_ascal_polyphase_o    <= '0';
   qnice_ascal_triplebuf_o    <= '0';
   qnice_flip_joyports_o      <= '0';

   ---------------------------------------------------------------------------------------------
   -- Core specific device handling (QNICE clock domain)
   ---------------------------------------------------------------------------------------------

   core_specific_devices : process (all)
   begin
      qnice_dev_data_o <= x"EEEE";
      qnice_dev_wait_o <= '0';
      qnice_bios_ce    <= '0';
      qnice_bios_we    <= '0';
      qnice_font_ce    <= '0';
      qnice_font_we    <= '0';
      qnice_ucode_ce   <= '0';
      qnice_ucode_we   <= '0';
      qnice_fdd_ce     <= '0';
      qnice_fdd_we     <= '0';
      qnice_fdd_drive  <= "00";

      case qnice_dev_id_i is
         when C_DEV_PC_BIOS =>
            qnice_bios_ce    <= qnice_dev_ce_i;
            qnice_bios_we    <= qnice_dev_we_i;
            qnice_dev_data_o <= qnice_bios_data;

         when C_DEV_PC_FONT =>
            qnice_font_ce    <= qnice_dev_ce_i;
            qnice_font_we    <= qnice_dev_we_i;
            qnice_dev_data_o <= qnice_font_data;

         when C_DEV_PC_UCODE =>
            qnice_ucode_ce   <= qnice_dev_ce_i;
            qnice_ucode_we   <= qnice_dev_we_i;
            qnice_dev_data_o <= qnice_ucode_data;

         when C_DEV_PC_FDA | C_DEV_PC_FDB | C_DEV_PC_HDC =>
            qnice_fdd_ce     <= qnice_dev_ce_i;
            qnice_fdd_we     <= qnice_dev_we_i;
            if qnice_dev_id_i = C_DEV_PC_FDB then
               qnice_fdd_drive <= "01";
            elsif qnice_dev_id_i = C_DEV_PC_HDC then
               qnice_fdd_drive <= "10";
            end if;
            qnice_dev_data_o <= qnice_fdd_data;

         when others => null;
      end case;
   end process core_specific_devices;

   i_pc_bios : entity work.pc_bios
      port map (
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,
         qnice_addr_i         => qnice_dev_addr_i,
         qnice_data_i         => qnice_dev_data_i,
         qnice_data_o         => qnice_bios_data,
         qnice_ce_i           => qnice_bios_ce,
         qnice_we_i           => qnice_bios_we,

         main_clk_i           => main_clk,
         main_valid_o         => main_bios_valid,
         rom_addr_i           => main_rom_addr,
         rom_rdata_o          => main_rom_rdata
      ); -- i_pc_bios

   i_pc_font : entity work.pc_font
      port map (
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,
         qnice_addr_i         => qnice_dev_addr_i,
         qnice_data_i         => qnice_dev_data_i,
         qnice_data_o         => qnice_font_data,
         qnice_ce_i           => qnice_font_ce,
         qnice_we_i           => qnice_font_we,
         main_clk_i           => main_clk,
         main_rst_i           => main_rst,
         font_we_o            => main_font_we,
         font_addr_o          => main_font_addr,
         font_data_o          => main_font_data,
         font_cbm_o           => main_font_cbm
      ); -- i_pc_font

   i_pc_ucode : entity work.pc_ucode
      port map (
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,
         qnice_addr_i         => qnice_dev_addr_i,
         qnice_data_i         => qnice_dev_data_i,
         qnice_data_o         => qnice_ucode_data,
         qnice_ce_i           => qnice_ucode_ce,
         qnice_we_i           => qnice_ucode_we,
         main_clk_i           => main_clk,
         main_valid_o         => main_ucode_valid,
         ucl_we_o             => main_ucl_we,
         ucl_addr_o           => main_ucl_addr,
         ucl_data_o           => main_ucl_data
      ); -- i_pc_ucode

   i_pc_fdd_sd : entity work.pc_fdd_sd
      port map (
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,
         qnice_drive_i        => qnice_fdd_drive,
         qnice_addr_i         => qnice_dev_addr_i,
         qnice_data_i         => qnice_dev_data_i,
         qnice_data_o         => qnice_fdd_data,
         qnice_ce_i           => qnice_fdd_ce,
         qnice_we_i           => qnice_fdd_we,
         qnice_wp_i           => qnice_osm_control_i(C_MENU_WP_B) & qnice_osm_control_i(C_MENU_WP_A),
         sd_c2q_o             => sd_eng_o,
         sd_q2c_i             => sd_eng_i,
         main_clk_i           => main_clk,
         main_rst_i           => main_rst,
         drv_80trk_o          => main_drv_80trk,
         img_present_o        => main_img_present,
         img_wp_o             => open,
         img_tracks_o         => main_img_tracks,
         img_heads_o          => main_img_heads,
         img_spt_o            => main_img_spt,
         sp_req_i             => main_sp_req,
         sp_write_i           => main_sp_write,
         sp_drive_i           => main_sp_drive,
         sp_lba_i             => main_sp_lba,
         sp_rd_valid_o        => main_sp_rd_valid,
         sp_rd_data_o         => main_sp_rd_data,
         sp_wr_valid_i        => main_sp_wr_valid,
         sp_wr_data_i         => main_sp_wr_data,
         sp_wr_ready_o        => main_sp_wr_ready,
         sp_done_o            => main_sp_done,
         sp_err_o             => main_sp_err,
         hd_present_o         => main_xta_present,
         hd_sp_req_i          => main_xta_sp_req,
         hd_sp_write_i        => main_xta_sp_write,
         hd_sp_lba_i          => main_xta_sp_lba,
         hd_sp_rd_valid_o     => main_xta_sp_rd_valid,
         hd_sp_rd_data_o      => main_xta_sp_rd_data,
         hd_sp_wr_valid_i     => main_xta_sp_wr_valid,
         hd_sp_wr_data_i      => main_xta_sp_wr_data,
         hd_sp_wr_ready_o     => main_xta_sp_wr_ready,
         hd_sp_done_o         => main_xta_sp_done,
         hd_sp_err_o          => main_xta_sp_err,
         main_busy_o          => open
      ); -- i_pc_fdd_sd

   -- write protection: the menu (main clock domain; the FDC card reads WP for its status)
   main_img_wp <= main_osm_control_i(C_MENU_WP_B) & main_osm_control_i(C_MENU_WP_A);

end architecture synthesis;
