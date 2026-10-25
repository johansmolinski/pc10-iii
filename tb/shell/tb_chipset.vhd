-- tb_chipset.vhd - pc_chipset.vhd: the default (PC10-III, switches 5D, no restart), a change
-- to the IBM XT (the chipset and the switches change in the same clock, the PC is held in reset
-- from that clock for 2^G_RST_BITS clocks), no restart while nothing changes, and back.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_chipset is
end entity tb_chipset;

architecture sim of tb_chipset is
   constant BITS : natural := 4;
   signal clk  : std_logic := '0';
   signal done : boolean := false;
   signal xt   : std_logic := '0';
   signal fe, rst : std_logic;
   signal sw   : std_logic_vector(7 downto 0);
begin
   clk <= not clk after 5 ns when not done;

   dut : entity work.pc_chipset
      generic map (G_RST_BITS => BITS)
      port map (clk_i => clk, xt_i => xt, fe2010a_o => fe, dip_sw1_o => sw, rst_o => rst);

   stim : process
      variable fails : natural := 0;
      variable n : natural;
      procedure expect(what : string; ok : boolean) is
      begin
         if not ok then report "FAIL " & what; fails := fails + 1; end if;
      end procedure;
      -- the clocks rst stays high from now on (rst sampled before each edge)
      procedure count_rst is
      begin
         n := 0;
         for i in 1 to 100 loop
            wait for 1 ns;
            exit when rst = '0';
            n := n + 1;
            wait until rising_edge(clk);
         end loop;
      end procedure;
   begin
      wait until rising_edge(clk);
      wait for 1 ns;
      expect("default PC10-III", fe = '1'); expect("default switches 5D", sw = x"5D");
      expect("no restart at the start", rst = '0');
      for i in 1 to 20 loop wait until rising_edge(clk); end loop;
      wait for 1 ns;
      expect("still no restart", rst = '0');
      -- to the IBM XT
      xt <= '1'; wait for 1 ns;
      expect("restart in the clock of the change", rst = '1');
      wait until rising_edge(clk); wait for 1 ns;
      expect("IBM XT", fe = '0'); expect("switches 6D", sw = x"6D");
      count_rst;
      expect("restart length " & integer'image(n + 1), n + 1 = 2**BITS);
      for i in 1 to 20 loop wait until rising_edge(clk); end loop;
      wait for 1 ns;
      expect("XT: no restart while it stays", rst = '0' and fe = '0');
      -- back to the PC10-III
      xt <= '0'; wait for 1 ns;
      expect("restart again", rst = '1');
      wait until rising_edge(clk); wait for 1 ns;
      expect("PC10-III again", fe = '1' and sw = x"5D");
      count_rst;
      expect("restart length again " & integer'image(n + 1), n + 1 = 2**BITS);
      if fails = 0 then
         report "CHIPSET TB: PASS";
      else
         report "CHIPSET TB: FAIL (" & integer'image(fails) & ")";
      end if;
      done <= true;
      wait;
   end process stim;
end architecture sim;
