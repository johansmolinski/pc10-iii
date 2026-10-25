----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- The menu's chipset (doc/m2m-shell.md section 8): the PC10-III's Faraday FE2010A or the IBM
-- XT's 8255 (xt_board.sv's fe2010a input) and the switches that go with it. A change restarts
-- the PC: rst_o is high for 2^G_RST_BITS clocks (2.3 ms) from the clock the menu bit changes,
-- and xt_board takes fe2010a while its reset is high. The switches change with fe2010a_o, so
-- the PC never runs with one chipset and the other's switches.
--
-- done by Johan Smolinski in 2026, licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pc_chipset is
generic (
   G_RST_BITS : natural := 16;
   -- the PC's switches in the 5160 layout (mega65.vhd)
   G_SW1_FE   : std_logic_vector(7 downto 0) := x"5D";
   G_SW1_XT   : std_logic_vector(7 downto 0) := x"6D"
);
port (
   clk_i      : in  std_logic;
   xt_i       : in  std_logic;                       -- the menu: IBM XT (8255)
   fe2010a_o  : out std_logic;                       -- to pc_system
   dip_sw1_o  : out std_logic_vector(7 downto 0);
   rst_o      : out std_logic                        -- restart the PC (OR into its reset)
);
end entity pc_chipset;

architecture synthesis of pc_chipset is
   signal fe   : std_logic := '1';                   -- the PC10-III (default)
   signal cnt  : unsigned(G_RST_BITS - 1 downto 0) := (others => '0');
begin
   p_chip : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if (not xt_i) /= fe then
            fe  <= not xt_i;
            cnt <= (others => '1');
         elsif cnt /= 0 then
            cnt <= cnt - 1;
         end if;
      end if;
   end process p_chip;

   fe2010a_o <= fe;
   dip_sw1_o <= G_SW1_FE when fe = '1' else G_SW1_XT;
   rst_o     <= '1' when cnt /= 0 or (not xt_i) /= fe else '0';
end architecture synthesis;
