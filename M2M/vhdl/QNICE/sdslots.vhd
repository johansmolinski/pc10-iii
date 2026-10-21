----------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework - Megamiga fork
--
-- sdslots: both SD card slots of the MEGA65 at the same time
-- (M2M-UPSTREAM sd-host, two slots; replaces the smart multiplexer sdmux.vhd)
--
-- One SD host controller (sdhost.vhd) per slot: slot 0 = the bottom tray, slot 1
-- = the back slot. sdmux connected one controller to one slot at a time and reset
-- it on every switch, so only one card was usable and a switch re-initialised the
-- card. Here both cards stay initialised (each in its own mode: native 4-bit or
-- SPI) and files on both can be open at once.
--
--   * QNICE registers 0..6 (0xFF20..0xFF26) go to the controller that register 7
--     (0xFF27, bit 0, read/write, 0 after a reset) selects. The firmware selects
--     the slot before every access (M2M/rom/sdcards.asm).
--   * The engine port (sdhost_pkg) goes to the controller that its slot bit
--     C2Q_SLOT names. A start pulse latches the slot until that controller's
--     done pulse (sdhost raises e_busy_o only some clocks after the start, once
--     it takes the request), so the outputs of the engine's controller stay
--     connected even if the bit changes.
--   * A controller is held in reset while its slot has no card (card-detect low
--     active, synchronised; it must report "no card" for G_ABSENT clocks, so a
--     contact glitch does not break a transfer) and while QNICE is reset. A
--     controller initialises a card on its own after the reset.
--   * cd_int_o / cd_ext_o: the synchronised card-detects (CSR bits 9/10), sel_o:
--     register 7 (CSR bit 8).
--
-- Done by the Megamiga fork in 2026 and licensed under GPL v3.
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sdhost_pkg.all;

entity sdslots is
   generic (
      G_ABSENT    : natural := 65535;    -- clocks without a card before the reset
      G_MS        : natural := 100_000   -- clk2x_i clocks per millisecond (sdhost.vhd)
   );
   port (
      clk_i       : in  std_logic;       -- QNICE clock (50 MHz)
      clk2x_i     : in  std_logic;       -- the controllers' clock (100 MHz, sdhost.vhd)
      reset_i     : in  std_logic;       -- QNICE reset

      -- QNICE registers 0xFF20..0xFF27 (writes on the falling edge, data_o
      -- combinational and 0 when not selected, as sdhost.vhd)
      en_i        : in  std_logic;
      we_i        : in  std_logic;
      reg_i       : in  std_logic_vector(2 downto 0);
      data_i      : in  std_logic_vector(15 downto 0);
      data_o      : out std_logic_vector(15 downto 0);

      sel_o       : out std_logic;       -- register 7
      cd_int_o    : out std_logic;       -- 1 = a card in the bottom tray
      cd_ext_o    : out std_logic;       -- 1 = a card in the back slot

      -- engine port of the core
      eng_i       : in  t_sd_c2q;
      eng_o       : out t_sd_q2c;

      -- slot 0: the bottom tray
      tray_cd_i   : in  std_logic;       -- low active
      tray_clk_o  : out std_logic;
      tray_cmd_o  : out std_logic;
      tray_cmd_oe : out std_logic;
      tray_cmd_i  : in  std_logic;
      tray_dat_o  : out std_logic_vector(3 downto 0);
      tray_dat_oe : out std_logic_vector(3 downto 0);
      tray_dat_i  : in  std_logic_vector(3 downto 0);

      -- slot 1: the back slot
      back_cd_i   : in  std_logic;       -- low active
      back_clk_o  : out std_logic;
      back_cmd_o  : out std_logic;
      back_cmd_oe : out std_logic;
      back_cmd_i  : in  std_logic;
      back_dat_o  : out std_logic_vector(3 downto 0);
      back_dat_oe : out std_logic_vector(3 downto 0);
      back_dat_i  : in  std_logic_vector(3 downto 0)
   );
end entity sdslots;

architecture synthesis of sdslots is

   type t_slv16 is array (0 to 1) of std_logic_vector(15 downto 0);
   type t_q2c   is array (0 to 1) of t_sd_q2c;
   type t_cnt   is array (0 to 1) of natural range 0 to G_ABSENT;

   signal cd_s1, cd_s2 : std_logic_vector(1 downto 0) := "00";   -- 1 = card
   signal cd_cnt       : t_cnt := (others => 0);
   signal rst          : std_logic_vector(1 downto 0) := "11";
   signal sel          : std_logic := '0';
   signal sel_data     : std_logic_vector(15 downto 0);
   signal en_c         : std_logic_vector(1 downto 0);
   signal data_c       : t_slv16;
   signal q2c          : t_q2c;
   signal start        : std_logic_vector(1 downto 0);
   signal eng_slot     : std_logic := '0';      -- the slot of the running transfer
   signal eng_act      : std_logic := '0';      -- a transfer runs (start .. done)
   signal eng_cur      : std_logic;

   signal clk_c, cmd_c, cmd_oe_c, cmd_in : std_logic_vector(1 downto 0);
   type t_slv4 is array (0 to 1) of std_logic_vector(3 downto 0);
   signal dat_c, dat_oe_c, dat_in : t_slv4;

begin

   cd_int_o <= cd_s2(0);
   cd_ext_o <= cd_s2(1);
   sel_o    <= sel;

   detect : process(clk_i)
   begin
      if rising_edge(clk_i) then
         cd_s1 <= (not back_cd_i) & (not tray_cd_i);
         cd_s2 <= cd_s1;
         for i in 0 to 1 loop
            if cd_s2(i) = '1' then
               cd_cnt(i) <= 0;
            elsif cd_cnt(i) /= G_ABSENT then
               cd_cnt(i) <= cd_cnt(i) + 1;
            end if;
            if reset_i = '1' or cd_cnt(i) = G_ABSENT then
               rst(i) <= '1';
            else
               rst(i) <= '0';
            end if;
         end loop;
      end if;
   end process detect;

   -- register 7: the slot of registers 0..6
   en_c(0)  <= en_i when reg_i /= "111" and sel = '0' else '0';
   en_c(1)  <= en_i when reg_i /= "111" and sel = '1' else '0';
   sel_data <= x"000" & "000" & sel when en_i = '1' and we_i = '0' and reg_i = "111" else (others => '0');
   data_o   <= data_c(0) or data_c(1) or sel_data;

   sel_reg : process(clk_i)
   begin
      if falling_edge(clk_i) then
         if reset_i = '1' then
            sel <= '0';
         elsif en_i = '1' and we_i = '1' and reg_i = "111" then
            sel <= data_i(0);
         end if;
      end if;
   end process sel_reg;

   -- the engine port
   eng_cur  <= eng_slot when eng_act = '1' else eng_i(C2Q_SLOT);
   start(0) <= eng_i(C2Q_START) when eng_i(C2Q_SLOT) = '0' else '0';
   start(1) <= eng_i(C2Q_START) when eng_i(C2Q_SLOT) = '1' else '0';
   eng_o    <= q2c(1) when eng_cur = '1' else q2c(0);

   eng_latch : process(clk_i)
   begin
      if rising_edge(clk_i) then
         if eng_act = '0' then
            if eng_i(C2Q_START) = '1' then
               eng_act  <= '1';
               eng_slot <= eng_i(C2Q_SLOT);
            end if;
         elsif (eng_slot = '0' and q2c(0)(Q2C_DONE) = '1') or
               (eng_slot = '1' and q2c(1)(Q2C_DONE) = '1') then
            eng_act <= '0';
         end if;
         if reset_i = '1' then
            eng_act <= '0';
         end if;
      end if;
   end process eng_latch;

   -- the pins
   tray_clk_o  <= clk_c(0);
   tray_cmd_o  <= cmd_c(0);
   tray_cmd_oe <= cmd_oe_c(0);
   cmd_in(0)   <= tray_cmd_i;
   tray_dat_o  <= dat_c(0);
   tray_dat_oe <= dat_oe_c(0);
   dat_in(0)   <= tray_dat_i;
   back_clk_o  <= clk_c(1);
   back_cmd_o  <= cmd_c(1);
   back_cmd_oe <= cmd_oe_c(1);
   cmd_in(1)   <= back_cmd_i;
   back_dat_o  <= dat_c(1);
   back_dat_oe <= dat_oe_c(1);
   dat_in(1)   <= back_dat_i;

   g_ctrl : for i in 0 to 1 generate
      i_sdhost : entity work.sdhost
         generic map (G_MS => G_MS)
         port map (
            clk_i       => clk_i,
            clk2x_i     => clk2x_i,
            reset_i     => rst(i),
            en_i        => en_c(i),
            we_i        => we_i,
            reg_i       => reg_i,
            data_i      => data_i,
            data_o      => data_c(i),
            e_ready_o   => q2c(i)(Q2C_READY),
            e_start_i   => start(i),
            e_write_i   => eng_i(C2Q_WRITE),
            e_addr_i    => eng_i(C2Q_ADDR),
            e_count_i   => eng_i(C2Q_COUNT),
            e_limit_i   => eng_i(C2Q_LIMIT),
            e_abort_i   => eng_i(C2Q_ABORT),
            e_busy_o    => q2c(i)(Q2C_BUSY),
            e_done_o    => q2c(i)(Q2C_DONE),
            e_error_o   => q2c(i)(Q2C_ERROR),
            e_blk_o     => q2c(i)(Q2C_BLK),
            e_rd_we_o   => q2c(i)(Q2C_RDWE),
            e_rd_blk_o  => q2c(i)(Q2C_RDBLK),
            e_rd_idx_o  => q2c(i)(Q2C_RDIDX),
            e_rd_data_o => q2c(i)(Q2C_RDDATA),
            e_wr_blk_o  => q2c(i)(Q2C_WRBLK),
            e_wr_idx_o  => q2c(i)(Q2C_WRIDX),
            e_wr_data_i => eng_i(C2Q_WRDATA),
            sd_clk_o    => clk_c(i),
            cmd_o       => cmd_c(i),
            cmd_oe_o    => cmd_oe_c(i),
            cmd_i       => cmd_in(i),
            dat_o       => dat_c(i),
            dat_oe_o    => dat_oe_c(i),
            dat_i       => dat_in(i)
         );
   end generate g_ctrl;

end architecture synthesis;
