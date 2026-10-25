----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- The menu's chipset (doc/m2m-shell.md section 8): the PC10-III's Faraday FE2010A or the IBM
-- XT's 8255 (xt_board.sv's fe2010a input) and the switches that go with it; and the menu's
-- display (doc/pvc4.md section 8): colour or mono, the PC10-III's CONFIG switch 2 (the PVC4's
-- straps and 230h bit 7) together with switches 3 and 4 (DIP SW1 bits 5-4 = 11: both off =
-- mono, manual section 2.2). A change of either restarts the PC: rst_o is high for
-- 2^G_RST_BITS clocks (2.3 ms) from the clock a menu bit changes, and xt_board and the PVC4
-- take their straps while reset is high. The switches change with fe2010a_o and cbm_dip_o, so
-- the PC never runs with one setting and the other's switches.
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
   mono_i     : in  std_logic;                       -- the menu: onboard video mono
   fe2010a_o  : out std_logic;                       -- to pc_system
   dip_sw1_o  : out std_logic_vector(7 downto 0);
   cbm_dip_o  : out std_logic_vector(1 downto 0);    -- pc_system cbm_dip: switch 2 & switch 1
   rst_o      : out std_logic                        -- restart the PC (OR into its reset)
);
end entity pc_chipset;

architecture synthesis of pc_chipset is
   signal fe   : std_logic := '1';                   -- the PC10-III (default)
   signal mono : std_logic := '0';                   -- colour (default)
   signal cnt  : unsigned(G_RST_BITS - 1 downto 0) := (others => '0');
begin
   p_chip : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if (not xt_i) /= fe or mono_i /= mono then
            fe   <= not xt_i;
            mono <= mono_i;
            cnt  <= (others => '1');
         elsif cnt /= 0 then
            cnt <= cnt - 1;
         end if;
      end if;
   end process p_chip;

   fe2010a_o <= fe;
   -- switch 1 off: the USA/Europe character set (the PVC4's character ROM A14)
   dip_sw1_o <= (G_SW1_FE(7 downto 6) & "11" & G_SW1_FE(3 downto 0)) when fe = '1' and mono = '1' else
                (G_SW1_XT(7 downto 6) & "11" & G_SW1_XT(3 downto 0)) when mono = '1' else
                G_SW1_FE when fe = '1' else G_SW1_XT;
   cbm_dip_o <= mono & '1';
   rst_o     <= '1' when cnt /= 0 or (not xt_i) /= fe or mono_i /= mono else '0';
end architecture synthesis;
