----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- Configuration data for the Shell: welcome and help screens, directories, the on-screen
-- menu (OSM). The address decoder at the end is the M2M template's, unchanged (the Megamiga
-- extensions SEL_OPTM_DEPS and SEL_OPTM_ROWS are not served: the classic menu).
--
-- Rules (Megamiga AGENTS.md, hard rules 7, 10, 11):
--   * OPTM_PAUSE stays false.
--   * The menu bit of a line is its line number: the C_MENU_* constants in mega65.vhd must
--     match OPTM_ITEMS below. make_rom.sh scrapes C_MENU_* and the core OPTM_G_* into
--     osm_const.asm (keep those constants single-line).
--   * Every menu growth: recheck MENU_HEAP_SIZE in m2m-rom.asm (the Shell goes fatal with
--     ERR_FATAL_HEAP1/2 at boot when it is too small).
--
-- done by Johan Smolinski in 2026, based on the MiSTer2MEGA65 template (sy2002 and
-- MJoergen, 2022), licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity config is
port (
   clk_i       : in std_logic;

   -- bits 27 .. 12:    select configuration data block; called "Selector" hereafter
   -- bits 11 downto 0: address the up to 4k the configuration data
   address_i   : in std_logic_vector(27 downto 0);

   -- config data
   data_o      : out std_logic_vector(15 downto 0)
);
end entity config;

architecture beh of config is

-- The version of the core: welcome/help screens and the core name derive from it
constant CORE_VERSION : string := "0.2 (WIP)";

----------------------------------------------------------------------------------------------------------
-- String and character constants (specific for the Anikki-16x16 font)
----------------------------------------------------------------------------------------------------------

constant CHR_LINE_1  : character := character'val(196);
constant CHR_LINE_5  : string := CHR_LINE_1 & CHR_LINE_1 & CHR_LINE_1 & CHR_LINE_1 & CHR_LINE_1;
constant CHR_LINE_10 : string := CHR_LINE_5 & CHR_LINE_5;

----------------------------------------------------------------------------------------------------------
-- Welcome and Help Screens
----------------------------------------------------------------------------------------------------------

constant WHS_RECORDS   : natural := 2;
constant WHS_MAX_PAGES : natural := 1;

constant SEL_WHS           : std_logic_vector(15 downto 0) := x"1000";

type WHS_INDEX_TYPE is array (0 to WHS_MAX_PAGES - 1) of natural;

type WHS_RECORD_TYPE is record
   page_count  : natural;
   page_start  : WHS_INDEX_TYPE;
   page_length : WHS_INDEX_TYPE;
end record;

type WHS_RECORD_ARRAY_TYPE is array (0 to WHS_RECORDS - 1) of WHS_RECORD_TYPE;

-- The OSM canvas is 40 x 25 characters (globals.vhd), the frame takes two of each.
constant SCR_WELCOME : string :=
   "PC10-III for MEGA65 " & CORE_VERSION & "\n\n" &
   "Commodore PC10-III / IBM PC XT\n\n" &
   "Powered by MiSTer2MEGA65\n\n" &
   "Press Space to continue.\n";

constant HELP_1 : string :=
   "\n PC10-III for MEGA65 " & CORE_VERSION & "\n\n" &
   " /pc10/bios.rom  BIOS, 8-64 KB\n" &
   " /pc10/char.rom  character ROM (optional)\n" &
   " A: B:  160K-720K  C: 20 MB (raw)\n\n" &
   " Keys (XT keyboard):\n" &
   " " & CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_10 & "\n" &
   " MEGA + 1..0     F1..F10\n" &
   " F1..F13 RUN/STOP F1..F7 F8\n" &
   " CLR/HOME        Home, MEGA: End\n" &
   " Cursor keys     keypad 8 2 4 6\n" &
   " MEGA + up/down  PgUp PgDn\n" &
   " MEGA + DEL/pound Del Ins\n" &
   " MEGA + -        keypad -\n" &
   " RESTORE         Num Lock\n" &
   " NO SCROLL       Scroll Lock\n" &
   " Arrow left/pound ` backslash\n" &
   " Help            this menu\n\n" &
   " Press Space to close the help screen.";

constant WHS_DATA : string := SCR_WELCOME & HELP_1;

constant SCR_WELCOME_START : natural := 0;
constant HELP_1_START      : natural := SCR_WELCOME'length;

constant WHS : WHS_RECORD_ARRAY_TYPE := (
   (page_count    => 1,
    page_start    => (0 => SCR_WELCOME_START),
    page_length   => (0 => SCR_WELCOME'length)),

   (page_count    => 1,
    page_start    => (0 => HELP_1_START),
    page_length   => (0 => HELP_1'length))
);

----------------------------------------------------------------------------------------------------------
-- Set start folder for file browser and specify config file for menu persistence
----------------------------------------------------------------------------------------------------------

constant SEL_DIR_START     : std_logic_vector(15 downto 0) := x"0100";
constant SEL_CFG_FILE      : std_logic_vector(15 downto 0) := x"0101";

constant DIR_START         : string := "/pc10";
constant CFG_FILE          : string := "/pc10/pc10cfg";

----------------------------------------------------------------------------------------------------------
-- General configuration settings: Reset, Pause, OSD behavior, Ascal, etc. (Selector 0x0110)
----------------------------------------------------------------------------------------------------------

constant SEL_GENERAL       : std_logic_vector(15 downto 0) := x"0110";  -- !!! DO NOT TOUCH !!!

constant RESET_COUNTER     : natural := 100;
constant OPTM_PAUSE        : boolean := false;     -- hard rule 7
constant WELCOME_ACTIVE    : boolean := false;
constant WELCOME_AT_RESET  : boolean := false;
constant KEYBOARD_AT_RESET : boolean := false;
constant JOY_1_AT_RESET    : boolean := true;    -- the bus mouse in joystick port 1 (pc_ports.vhd)
constant JOY_2_AT_RESET    : boolean := false;
constant KEYBOARD_AT_OSD   : boolean := false;
constant JOY_1_AT_OSD      : boolean := false;
constant JOY_2_AT_OSD      : boolean := false;
constant ASCAL_USAGE       : natural := 2;   -- 2 = AUSE_DIRECT: ascal mode from ASCAL_MODE below
constant ASCAL_MODE        : natural := 0;   -- nearest neighbour
constant SAVE_SETTINGS     : boolean := true;
constant VD_ANTI_THRASHING_DELAY : natural := 2000;
constant VD_ITERATION_SIZE       : natural := 100;

----------------------------------------------------------------------------------------------------------
-- Name of the core
----------------------------------------------------------------------------------------------------------

constant SEL_CORENAME      : std_logic_vector(15 downto 0) := x"0200";
constant CORENAME          : string := "PC10-III " & CORE_VERSION;

----------------------------------------------------------------------------------------------------------
-- On-Screen-Menu (OSM)
----------------------------------------------------------------------------------------------------------

constant SEL_OPTM_ITEMS       : std_logic_vector(15 downto 0) := x"0300";
constant SEL_OPTM_GROUPS      : std_logic_vector(15 downto 0) := x"0301";
constant SEL_OPTM_STDSEL      : std_logic_vector(15 downto 0) := x"0302";
constant SEL_OPTM_LINES       : std_logic_vector(15 downto 0) := x"0303";
constant SEL_OPTM_START       : std_logic_vector(15 downto 0) := x"0304";
constant SEL_OPTM_ICOUNT      : std_logic_vector(15 downto 0) := x"0305";
constant SEL_OPTM_MOUNT_DRV   : std_logic_vector(15 downto 0) := x"0306";
constant SEL_OPTM_SINGLESEL   : std_logic_vector(15 downto 0) := x"0307";
constant SEL_OPTM_MOUNT_STR   : std_logic_vector(15 downto 0) := x"0308";
constant SEL_OPTM_DIMENSIONS  : std_logic_vector(15 downto 0) := x"0309";
constant SEL_OPTM_SAVING_STR  : std_logic_vector(15 downto 0) := x"030A";
constant SEL_OPTM_HELP        : std_logic_vector(15 downto 0) := x"0310";
constant SEL_OPTM_CRTROM      : std_logic_vector(15 downto 0) := x"0311";
constant SEL_OPTM_CRTROM_STR  : std_logic_vector(15 downto 0) := x"0312";

constant OPTM_G_TEXT       : integer := 16#00000#;         -- text that cannot be selected
constant OPTM_G_CLOSE      : integer := 16#000FF#;         -- menu items that closes menu
constant OPTM_G_STDSEL     : integer := 16#00100#;         -- item within a group that is selected by default
constant OPTM_G_LINE       : integer := 16#00200#;         -- draw a line at this position
constant OPTM_G_START      : integer := 16#00400#;         -- selector / cursor position after startup (only use once!)
constant OPTM_G_HEADLINE   : integer := 16#01000#;         -- like OPTM_G_TEXT but will be shown in a brigher color
constant OPTM_G_SINGLESEL  : integer := 16#08000#;         -- single select item
constant OPTM_G_MOUNT_DRV  : integer := 16#08800#;         -- line item means: mount drive
constant OPTM_G_HELP       : integer := 16#0A000#;         -- line item means: help screen; first occurance = WHS(1)
constant OPTM_G_SUBMENU    : integer := 16#0C000#;         -- starts/ends a section that is treated as submenu
constant OPTM_G_LOAD_ROM   : integer := 16#18000#;         -- line item means: load ROM

constant OPTM_GTC          : natural := 17;                -- Amount of significant bits in OPTM_G_* constants

constant OPTM_S_MOUNT      : string := "<Mount Drive>";
constant OPTM_S_CRTROM     : string := "<No Disk>";
constant OPTM_S_SAVING     : string := "<Saving>";

-- Size of menu and menu items. The line numbers are the bits of qnice_osm_control_i
-- (mega65.vhd C_MENU_*):
--     0  PC10-III                headline
--     1  ----
--     2  A:%s                    floppy image of A: (manual ROM load 0, pc_fdd_sd.vhd)
--     3  B:%s                    floppy image of B: (manual ROM load 1)
--     4  C:%s                    hard disk image of C: (manual ROM load 2, pc_fdd_sd.vhd;
--                                JMP208 follows it: no image = no drive)
--     5  A: write protected      C_MENU_WP_A
--     6  B: write protected      C_MENU_WP_B
--     7  Drive sound (int. drive) C_MENU_DRV_SOUND (default on; pc_drvsnd.vhd)
--     8  ----
--     9  Chipset: %s             submenu (a change restarts the PC, mega65.vhd)
--    10    Chipset               headline
--    11    ----
--    12    PC10-III (FE2010A)    C_MENU_CHIP_PC10 (default; switches 5D)
--    13    IBM XT (8255)         C_MENU_CHIP_XT (switches 6D)
--    14    ----
--    15    Back to main menu
--    16  Memory: %s              submenu
--    17    Memory size           headline
--    18    ----
--    19    640 KB                C_MENU_MEM_640 (default)
--    20    512 KB                C_MENU_MEM_512
--    21    256 KB                C_MENU_MEM_256
--    22    128 KB                C_MENU_MEM_128
--    23    ----
--    24    Back to main menu
--    25  HDMI: %s                submenu
--    26    HDMI mode             headline
--    27    ----
--    28    720p 60 Hz 16:9       C_MENU_HDMI_720P (default)
--    29    480p 59.94 Hz 4:3     C_MENU_HDMI_480P
--    30    720p 50 Hz 16:9       C_MENU_HDMI_720P50 (the PVC4's mono personality is 49.8 Hz)
--    31    ----
--    32    Back to main menu
--    33  Display: %s             submenu: the PVC4's CONFIG switch 2 + switches 3/4 (a change
--                                between colour and mono restarts the PC, pc_chipset.vhd)
--    34    Display               headline
--    35    ----
--    36    Colour                (default; 80 x 25 colour)
--    37    Monochrome, green     C_MENU_DISP_GREEN (mono; the phosphor only in main.vhd)
--    38    Monochrome, amber     C_MENU_DISP_AMBER
--    39    Monochrome, white     C_MENU_DISP_WHITE
--    40    ----
--    41    Back to main menu
--    42  Scandinavian charset    C_MENU_CHARSET_SCAN (CONFIG switch 1 on: the Commodore character
--                                ROM's A14 = 0, live as on the board; default off = USA/Europe)
--    43  Analog: 15 kHz RGB      C_MENU_ANALOG_15KHZ (default off: 31 kHz VGA, scandoubler)
--    44  Analog: CSYNC           C_MENU_ANALOG_CSYNC
--    45  ----
--    46  Help
--    47  Reset the PC            C_MENU_RESET (momentary: the firmware resets and clears it)
--    48  ----
--    49  Close Menu
--
-- The settings file keeps one byte per line, so the layout is part of its format: the
-- firmware's CFG_SIGCHECK accepts only a file whose text carries this menu's signature
-- (m2m-rom.asm, CFG_SIG_VAL; change it with every layout change), any other file is reset to
-- the defaults.
constant OPTM_SIZE         : natural := 50;
constant OPTM_DX           : natural := 28;
constant OPTM_DY           : natural := 21;   -- the visible main menu (lines 0-9, 16, 25, 33, 42-49)

constant OPTM_ITEMS        : string :=
   " PC10-III\n"              &
   "\n"                       &
   " A:%s\n"                  &
   " B:%s\n"                  &
   " C:%s\n"                  &
   " A: write protected\n"    &
   " B: write protected\n"    &
   " Drive sound (int. drive)\n" &
   "\n"                       &
   " Chipset: %s\n"           &
   " Chipset\n"               &
   "\n"                       &
   " PC10-III (FE2010A)\n"    &
   " IBM XT (8255)\n"         &
   "\n"                       &
   " Back to main menu\n"     &
   " Memory: %s\n"            &
   " Memory size\n"           &
   "\n"                       &
   " 640 KB\n"                &
   " 512 KB\n"                &
   " 256 KB\n"                &
   " 128 KB\n"                &
   "\n"                       &
   " Back to main menu\n"     &
   " HDMI: %s\n"              &
   " HDMI mode\n"             &
   "\n"                       &
   " 720p 60 Hz 16:9\n"       &
   " 480p 59.94 Hz 4:3\n"     &
   " 720p 50 Hz 16:9\n"       &
   "\n"                       &
   " Back to main menu\n"     &
   " Display: %s\n"           &
   " Display\n"               &
   "\n"                       &
   " Colour\n"                &
   " Monochrome, green\n"     &
   " Monochrome, amber\n"     &
   " Monochrome, white\n"     &
   "\n"                       &
   " Back to main menu\n"     &
   " Scandinavian charset\n"  &
   " Analog: 15 kHz RGB\n"    &
   " Analog: CSYNC\n"         &
   "\n"                       &
   " Help\n"                  &
   " Reset the PC\n"          &
   "\n"                       &
   " Close Menu\n";

-- Menu groups (single-line: make_rom.sh scrapes them into osm_const.asm as PC_OPTM_G_*)
constant OPTM_G_FDA        : integer := 1;
constant OPTM_G_FDB        : integer := 2;
constant OPTM_G_WPA        : integer := 3;
constant OPTM_G_WPB        : integer := 4;
constant OPTM_G_MEM        : integer := 5;
constant OPTM_G_HDMI       : integer := 6;
constant OPTM_G_DISP       : integer := 7;
constant OPTM_G_15KHZ      : integer := 8;
constant OPTM_G_CSYNC      : integer := 9;
constant OPTM_G_RESET      : integer := 10;
constant OPTM_G_DRVSND     : integer := 11;
constant OPTM_G_CHIP       : integer := 12;
constant OPTM_G_CHARSET    : integer := 13;
constant OPTM_G_HDC        : integer := 14;

type OPTM_GTYPE is array (0 to OPTM_SIZE - 1) of integer range 0 to 2**OPTM_GTC- 1;

constant OPTM_GROUPS       : OPTM_GTYPE := ( OPTM_G_TEXT + OPTM_G_HEADLINE,            --  0 PC10-III
                                             OPTM_G_LINE,                              --  1
                                             OPTM_G_FDA + OPTM_G_LOAD_ROM + OPTM_G_START, --  2 A:%s
                                             OPTM_G_FDB + OPTM_G_LOAD_ROM,             --  3 B:%s
                                             OPTM_G_HDC + OPTM_G_LOAD_ROM,             --  4 C:%s
                                             OPTM_G_WPA + OPTM_G_SINGLESEL,            --  5 A: write protected
                                             OPTM_G_WPB + OPTM_G_SINGLESEL,            --  6 B: write protected
                                             OPTM_G_DRVSND + OPTM_G_SINGLESEL + OPTM_G_STDSEL, --  7 Drive sound
                                             OPTM_G_LINE,                              --  8
                                             OPTM_G_SUBMENU,                           --  9 Chipset: %s
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 10 Chipset
                                             OPTM_G_LINE,                              -- 11
                                             OPTM_G_CHIP + OPTM_G_STDSEL,              -- 12 PC10-III (FE2010A)
                                             OPTM_G_CHIP,                              -- 13 IBM XT (8255)
                                             OPTM_G_LINE,                              -- 14
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 15 Back
                                             OPTM_G_SUBMENU,                           -- 16 Memory: %s
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 17 Memory size
                                             OPTM_G_LINE,                              -- 18
                                             OPTM_G_MEM + OPTM_G_STDSEL,               -- 19 640 KB
                                             OPTM_G_MEM,                               -- 20 512 KB
                                             OPTM_G_MEM,                               -- 21 256 KB
                                             OPTM_G_MEM,                               -- 22 128 KB
                                             OPTM_G_LINE,                              -- 23
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 24 Back
                                             OPTM_G_SUBMENU,                           -- 25 HDMI: %s
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 26 HDMI mode
                                             OPTM_G_LINE,                              -- 27
                                             OPTM_G_HDMI + OPTM_G_STDSEL,              -- 28 720p 60 Hz
                                             OPTM_G_HDMI,                              -- 29 480p 59.94 Hz
                                             OPTM_G_HDMI,                              -- 30 720p 50 Hz
                                             OPTM_G_LINE,                              -- 31
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 32 Back
                                             OPTM_G_SUBMENU,                           -- 33 Display: %s
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 34 Display
                                             OPTM_G_LINE,                              -- 35
                                             OPTM_G_DISP + OPTM_G_STDSEL,              -- 36 Colour
                                             OPTM_G_DISP,                              -- 37 Monochrome, green
                                             OPTM_G_DISP,                              -- 38 Monochrome, amber
                                             OPTM_G_DISP,                              -- 39 Monochrome, white
                                             OPTM_G_LINE,                              -- 40
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 41 Back
                                             OPTM_G_CHARSET + OPTM_G_SINGLESEL,        -- 42 Scandinavian charset
                                             OPTM_G_15KHZ + OPTM_G_SINGLESEL,          -- 43 Analog: 15 kHz
                                             OPTM_G_CSYNC + OPTM_G_SINGLESEL,          -- 44 Analog: CSYNC
                                             OPTM_G_LINE,                              -- 45
                                             OPTM_G_HELP,                              -- 46 Help
                                             OPTM_G_RESET + OPTM_G_SINGLESEL,          -- 47 Reset the PC
                                             OPTM_G_LINE,                              -- 48
                                             OPTM_G_CLOSE                              -- 49 Close Menu
                                           );

begin

addr_decode : process(clk_i)
   -- return ASCII value of given string at the position defined by index (zero-based)
   pure function str2data(str : string; index : integer) return std_logic_vector is
   variable strpos : integer;
   begin
      strpos := index + 1;
      if strpos <= str'length then
         return std_logic_vector(to_unsigned(character'pos(str(strpos)), 16));
      else
         return X"0000"; -- zero terminated strings
      end if;
   end function str2data;

   -- return the dimensions of the Options menu
   pure function getDXDY(dx, dy, index: natural) return std_logic_vector is
   begin
      case index is
         when 0 => return std_logic_vector(to_unsigned(dx + 2, 16));
         when 1 => return std_logic_vector(to_unsigned(dy + 2, 16));
         when others => return X"0000";
      end case;
   end function getDXDY;

   -- convert bool to std_logic_vector
   pure function bool2slv(b: boolean) return std_logic_vector is
   begin
      if b then
         return x"0001";
      else
         return x"0000";
      end if;
   end function bool2slv;

   -- return the General Configuration settings
   function getGenConf(index: natural) return std_logic_vector is
   begin
      case index is
         when 1      => return std_logic_vector(to_unsigned(RESET_COUNTER, 16));
         when 2      => return bool2slv(OPTM_PAUSE);
         when 3      => return bool2slv(WELCOME_ACTIVE);
         when 4      => return bool2slv(WELCOME_AT_RESET);
         when 5      => return bool2slv(KEYBOARD_AT_RESET);
         when 6      => return bool2slv(JOY_1_AT_RESET);
         when 7      => return bool2slv(JOY_2_AT_RESET);
         when 8      => return bool2slv(KEYBOARD_AT_OSD);
         when 9      => return bool2slv(JOY_1_AT_OSD);
         when 10     => return bool2slv(JOY_2_AT_OSD);
         when 11     => return std_logic_vector(to_unsigned(ASCAL_USAGE, 16));
         when 12     => return std_logic_vector(to_unsigned(ASCAL_MODE, 16));
         when 13     => return std_logic_vector(to_unsigned(VD_ANTI_THRASHING_DELAY, 16));
         when 14     => return std_logic_vector(to_unsigned(VD_ITERATION_SIZE, 16));
         when 15     => return bool2slv(SAVE_SETTINGS);
         when others => return x"0000";
      end case;
   end function getGenConf;

   variable index           : integer;
   variable whs_page_index  : integer;
   variable whs_array_index : integer;

begin

   if falling_edge(clk_i) then

      index := to_integer(unsigned(address_i(11 downto 0)));
      whs_page_index  := to_integer(unsigned(address_i(19 downto 12)));
      whs_array_index := to_integer(unsigned(address_i(23 downto 20)));

      data_o <= x"EEEE";

      -----------------------------------------------------------------------------------
      -- Welcome & Help System: upper 4 bits of address equal SEL_WHS' upper 4 bits
      -----------------------------------------------------------------------------------

      if address_i(27 downto 24) = SEL_WHS(15 downto 12) then

         if  whs_array_index < WHS_RECORDS then
            if index = 4095 then
               data_o <= std_logic_vector(to_unsigned(WHS(whs_array_index).page_count, 16));
            else
               if index < WHS(whs_array_index).page_length(whs_page_index) then
                  data_o <= str2data(WHS_DATA, WHS(whs_array_index).page_start(whs_page_index) + index);
               else
                  data_o <= (others => '0'); -- zero-terminated strings
               end if;
            end if;
         end if;

      -----------------------------------------------------------------------------------
      -- All other selectors, which are 16-bit values
      -----------------------------------------------------------------------------------

      else

         case address_i(27 downto 12) is
            when SEL_GENERAL           => data_o <= getGenConf(index);
            when SEL_DIR_START         => data_o <= str2data(DIR_START, index);
            when SEL_CFG_FILE          => data_o <= str2data(CFG_FILE, index);
            when SEL_CORENAME          => data_o <= str2data(CORENAME, index);
            when SEL_OPTM_ITEMS        => data_o <= str2data(OPTM_ITEMS, index);
            when SEL_OPTM_MOUNT_STR    => data_o <= str2data(OPTM_S_MOUNT, index);
            when SEL_OPTM_CRTROM_STR   => data_o <= str2data(OPTM_S_CRTROM, index);
            when SEL_OPTM_SAVING_STR   => data_o <= str2data(OPTM_S_SAVING, index);
            when SEL_OPTM_GROUPS       => data_o <= std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(15)) &
                                                    std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(14)) & "0" &
                                                    std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(12)) & "0000" &
                                                    std_logic_vector(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(7 downto 0));
            when SEL_OPTM_STDSEL       => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(8));
            when SEL_OPTM_LINES        => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(9));
            when SEL_OPTM_START        => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(10));
            when SEL_OPTM_MOUNT_DRV    => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(11));
            when SEL_OPTM_HELP         => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(13));
            when SEL_OPTM_SINGLESEL    => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(15));
            when SEL_OPTM_CRTROM       => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(16));
            when SEL_OPTM_ICOUNT       => data_o <= x"00" & std_logic_vector(to_unsigned(OPTM_SIZE, 8));
            when SEL_OPTM_DIMENSIONS   => data_o <= getDXDY(OPTM_DX, OPTM_DY, index);

            when others                => null;
         end case;
      end if;
   end if;
end process;

end architecture beh;
