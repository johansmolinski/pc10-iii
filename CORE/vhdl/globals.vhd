----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- Global constants
--
-- Based on the MiSTer2MEGA65 template (sy2002 and MJoergen, 2022) in the Megamiga fork;
-- licensed under GPL v3
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.qnice_tools.all;
use work.video_modes_pkg.all;

package globals is

----------------------------------------------------------------------------------------------------------
-- QNICE Firmware
----------------------------------------------------------------------------------------------------------

constant QNICE_FIRMWARE_MONITOR   : string  := "../../../M2M/QNICE/monitor/monitor.rom";    -- debug/development
constant QNICE_FIRMWARE_M2M       : string  := "../../../CORE/m2m-rom/m2m-rom.rom";         -- release

-- Select firmware here
constant QNICE_FIRMWARE           : string  := QNICE_FIRMWARE_M2M;

-- Megamiga fork (M2M-UPSTREAM code-banks): the code bank ROM behind the window 0x9000-0x9FFF.
-- "" = no code banks: the PC10-III firmware fits into the 32K-word ROM.
constant QNICE_CODE_BANKS         : string  := "";

----------------------------------------------------------------------------------------------------------
-- Clock Speed(s)
----------------------------------------------------------------------------------------------------------

-- The PC's one clock: 100 MHz * 55.125 / 5 / 11 = 2205/22 MHz = 100.227272.. MHz = 7 x 14.31818 MHz
-- (doc/architecture.md section 1, CORE/vhdl/clk.vhd)
constant CORE_CLK_SPEED       : natural := 100_227_273;

-- System clock speed (crystal that is driving the FPGA) and QNICE clock speed
-- !!! Do not touch !!!
constant BOARD_CLK_SPEED      : natural := 100_000_000;
constant QNICE_CLK_SPEED      : natural := 50_000_000;   -- a change here has dependencies in qnice_globals.vhd

----------------------------------------------------------------------------------------------------------
-- Video Mode
----------------------------------------------------------------------------------------------------------

-- The On-Screen-Menu canvas: CHARS_DX x CHARS_DY = 640/16 x 400/16 = 40 x 25 characters. 640 x 400
-- is the CGA picture after the scandoubler (640 x 200 at 15.7 kHz, every line doubled), so the OSM
-- fits the analog output. On HDMI the overlay is right-shifted by H_PIXELS - VGA_DX (>= 0 for every
-- mode we offer: 1280 - 640 for 720p, 720 - 640 for 480p).
constant VGA_DX               : natural := 640;
constant VGA_DY               : natural := 400;

-- The scandoubler runs on video_clk_o = main_clk (100.2 MHz) with a 14.318 MHz pixel enable (7x);
-- the plain line doubler (M2M-UPSTREAM line-doubler) needs only 2x, Hq2x would need 4x.
constant VGA_LINEDOUBLER      : boolean := true;

--    FONT_*  size of one OSM character (the 8x8 strike, rendered as 16x16 cells)
constant FONT_FILE            : string  := "../font/Anikki-8x8-m2m.rom";
constant FONT_DX              : natural := 16;
constant FONT_DY              : natural := 16;

-- Constants for the OSM screen memory
constant CHARS_DX             : natural := VGA_DX / FONT_DX;
constant CHARS_DY             : natural := VGA_DY / FONT_DY;
constant CHAR_MEM_SIZE        : natural := CHARS_DX * CHARS_DY;
constant VRAM_ADDR_WIDTH      : natural := f_log2(CHAR_MEM_SIZE);

----------------------------------------------------------------------------------------------------------
-- HyperRAM memory map (in units of 4kW)
----------------------------------------------------------------------------------------------------------

constant C_HMAP_M2M           : std_logic_vector(15 downto 0) := x"0000";     -- Reserved for the M2M framework

----------------------------------------------------------------------------------------------------------
-- QNICE devices of the core (ids >= 0x0100)
----------------------------------------------------------------------------------------------------------

-- The BIOS ROM (pc_bios.vhd): windows 0..15 = the 64 KB image, loaded from offset 0 (the device
-- right-aligns it to FFFFF itself); window 0x0100 = its control registers (see pc_bios.vhd).
constant C_DEV_PC_BIOS        : std_logic_vector(15 downto 0) := x"0100";
-- The floppy images of A: and B: (pc_fdd_sd.vhd): window 0 registers, window 1 the extent map,
-- window 0xFFFF the CRT/ROM load CSR. Manual "ROM" loads in the menu (nothing is streamed).
constant C_DEV_PC_FDA         : std_logic_vector(15 downto 0) := x"0101";
constant C_DEV_PC_FDB         : std_logic_vector(15 downto 0) := x"0102";
-- The CGA character ROM (pc_font.vhd): windows 0..1 the 8 KB image, window 0x0100 control.
constant C_DEV_PC_FONT        : std_logic_vector(15 downto 0) := x"0103";

----------------------------------------------------------------------------------------------------------
-- Virtual Drive Management System: not used (yet)
----------------------------------------------------------------------------------------------------------

type vd_buf_array is array(natural range <>) of std_logic_vector;
constant C_VDNUM              : natural := 0;
constant C_VD_DEVICE          : std_logic_vector(15 downto 0) := x"EEEE";
constant C_VD_BUFFER          : vd_buf_array := (x"EEEE", x"EEEE");

----------------------------------------------------------------------------------------------------------
-- System for handling simulated cartridges and ROM loaders
----------------------------------------------------------------------------------------------------------

type crtrom_buf_array is array(natural range<>) of std_logic_vector;
constant ENDSTR : character := character'val(0);

-- Cartridges and ROMs can be stored into QNICE devices, HyperRAM and SDRAM
constant C_CRTROMTYPE_DEVICE     : std_logic_vector(15 downto 0) := x"0000";
constant C_CRTROMTYPE_HYPERRAM   : std_logic_vector(15 downto 0) := x"0001";
constant C_CRTROMTYPE_SDRAM      : std_logic_vector(15 downto 0) := x"0002";

-- Types of automatically loaded ROMs:
-- If a mandatory file is missing, then the core outputs the missing file and goes fatal
constant C_CRTROMTYPE_MANDATORY  : std_logic_vector(15 downto 0) := x"0003";
constant C_CRTROMTYPE_OPTIONAL   : std_logic_vector(15 downto 0) := x"0004";

-- Manually loadable ROMs: the floppy images of A: and B: (menu lines " A:%s", " B:%s"). The
-- firmware's PREP_LOAD_IMAGE hands the file to pc_fdd_sd.vhd (extent map) and leaves the file
-- pointer at the end, so the Shell streams nothing and only does the CSR handshake.
constant C_CRTROMS_MAN_NUM       : natural := 2;
constant C_CRTROMS_MAN           : crtrom_buf_array := ( C_CRTROMTYPE_DEVICE, C_DEV_PC_FDA,
                                                         C_CRTROMTYPE_DEVICE, C_DEV_PC_FDB,
                                                         x"EEEE");

-- Automatically loaded ROMs: the BIOS, mandatory. The Shell loads it into C_DEV_PC_BIOS before the
-- PC leaves reset and goes fatal if the file is missing; PREP_START (m2m-rom.asm) then checks the
-- size (8..64 KB) and releases the BIOS gate of pc_bios.vhd.
-- The CGA character ROM is optional: without /pc10/cga.rom the free default font of
-- pc_font.vhd stays (PREP_START copies a loaded one into the CGA card).
constant BIOS_ROM_NAME           : string := "/pc10/bios.rom" & ENDSTR;
constant BIOS_ROM_NAME_START     : std_logic_vector(15 downto 0) := x"0000";
constant FONT_ROM_NAME           : string := "/pc10/cga.rom" & ENDSTR;
constant FONT_ROM_NAME_START     : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(BIOS_ROM_NAME'length, 16));

constant C_CRTROMS_AUTO_NUM      : natural := 2;
constant C_CRTROMS_AUTO_NAMES    : string  := BIOS_ROM_NAME & FONT_ROM_NAME;
constant C_CRTROMS_AUTO          : crtrom_buf_array := ( C_CRTROMTYPE_DEVICE, C_DEV_PC_BIOS,
                                                         C_CRTROMTYPE_MANDATORY, BIOS_ROM_NAME_START,
                                                         C_CRTROMTYPE_DEVICE, C_DEV_PC_FONT,
                                                         C_CRTROMTYPE_OPTIONAL, FONT_ROM_NAME_START,
                                                         x"EEEE");

----------------------------------------------------------------------------------------------------------
-- Audio filters (the framework's optional low-pass; values of the C64 template, unused while
-- qnice_audio_filter_o = '0')
----------------------------------------------------------------------------------------------------------

constant audio_flt_rate : std_logic_vector(31 downto 0) := std_logic_vector(to_signed(7056000, 32));
constant audio_cx       : std_logic_vector(39 downto 0) := std_logic_vector(to_signed(4258969, 40));
constant audio_cx0      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(3, 8));
constant audio_cx1      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(2, 8));
constant audio_cx2      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(1, 8));
constant audio_cy0      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed(-6216759, 24));
constant audio_cy1      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed( 6143386, 24));
constant audio_cy2      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed(-2023767, 24));
constant audio_att      : std_logic_vector( 4 downto 0) := "00000";
constant audio_mix      : std_logic_vector( 1 downto 0) := "00"; -- 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

end package globals;
