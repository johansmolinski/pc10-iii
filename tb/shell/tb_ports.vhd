-- tb_ports.vhd - pc_ports.vhd: the PMOD headers off (both unpowered, every pin high-Z, the
-- 8250 sees an unplugged port: RXD mark, CTS/DSR/DCD/RI inactive; the printer reads ready) and
-- on (the pin directions: TXD, /RTS, /STROBE, /INIT, D0-D7 driven, CTS/RXD/BUSY/ACK inputs that
-- the bench drives through the 2-FF synchronizer, two clocks late; DSR and DCD follow DTR); an
-- external driver on every input pin while off and on (no contention: the bench resolves the
-- pins); the mouse lines for the Amiga and the Atari ST mapping; the POT buttons: a passive
-- mouse (line low from the start) never presses, an active one presses after it was seen
-- high, the watchdog disarms a line held low, the PC's reset disarms.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_ports is
end entity tb_ports;

architecture sim of tb_ports is
   constant TMO : natural := 50;
   signal clk  : std_logic := '0';
   signal done : boolean := false;
   signal rst, pmod_on, atari : std_logic := '0';
   signal txd, rts_n, dtr_n : std_logic := '1';
   signal rxd, cts_n, dsr_n, dcd_n, ri_n : std_logic;
   signal lpt_data : std_logic_vector(7 downto 0) := x"00";
   signal stb_n, init_n : std_logic := '1';
   signal busy, ack_n, pe, slct, err_n : std_logic;
   signal up_n, down_n, left_n, right_n, fire_n : std_logic := '1';
   signal pot_x, pot_y : std_logic_vector(7 downto 0) := x"00";
   signal xp, xq, yp, yq : std_logic;
   signal btn_n : std_logic_vector(2 downto 0);
   signal p1lo, p1hi, p2lo, p2hi : std_logic_vector(3 downto 0);
   -- the bench's drivers on the headers ('Z' = nothing connected)
   signal x1lo, x1hi, x2lo, x2hi : std_logic_vector(3 downto 0) := (others => 'Z');
   signal en1, en2 : std_logic;
begin
   clk <= not clk after 5 ns when not done;

   p1lo <= x1lo;  p1hi <= x1hi;  p2lo <= x2lo;  p2hi <= x2hi;

   dut : entity work.pc_ports
      generic map (G_POT_TIMEOUT => TMO)
      port map (clk_i => clk, rst_i => rst, pmod_on_i => pmod_on, atari_i => atari,
                ser_txd_i => txd, ser_rts_n_i => rts_n, ser_dtr_n_i => dtr_n,
                ser_rxd_o => rxd, ser_cts_n_o => cts_n, ser_dsr_n_o => dsr_n, ser_dcd_n_o => dcd_n,
                ser_ri_n_o => ri_n, lpt_data_i => lpt_data, lpt_strobe_n_i => stb_n,
                lpt_init_n_i => init_n, lpt_busy_o => busy, lpt_ack_n_o => ack_n, lpt_pe_o => pe,
                lpt_slct_o => slct, lpt_err_n_o => err_n,
                joy_up_n_i => up_n, joy_down_n_i => down_n, joy_left_n_i => left_n,
                joy_right_n_i => right_n, joy_fire_n_i => fire_n, pot_x_i => pot_x, pot_y_i => pot_y,
                mouse_xp_o => xp, mouse_xq_o => xq, mouse_yp_o => yp, mouse_yq_o => yq,
                mouse_btn_n_o => btn_n,
                p1lo_io => p1lo, p1hi_io => p1hi, p2lo_io => p2lo, p2hi_io => p2hi,
                pmod1_en_o => en1, pmod2_en_o => en2);

   stim : process
      variable fails : natural := 0;
      procedure expect(what : string; ok : boolean) is
      begin
         if not ok then report "FAIL " & what; fails := fails + 1; end if;
      end procedure;
      procedure tick(n : natural := 1) is
      begin
         for i in 1 to n loop wait until rising_edge(clk); end loop;
         wait for 1 ns;
      end procedure;
      function allz(v : std_logic_vector) return boolean is
      begin
         for i in v'range loop if v(i) /= 'Z' then return false; end if; end loop;
         return true;
      end function;
   begin
      tick(3);
      -- ---- off: unpowered, high-Z, an unplugged port, a ready printer
      expect("off: headers unpowered", en1 = '0' and en2 = '0');
      txd <= '0'; rts_n <= '0'; stb_n <= '0'; init_n <= '0'; lpt_data <= x"A5"; dtr_n <= '0';
      tick(3);
      expect("off: PMOD1 lo high-Z", allz(p1lo));
      expect("off: PMOD1 hi high-Z", allz(p1hi));
      expect("off: PMOD2 high-Z", allz(p2lo) and allz(p2hi));
      expect("off: RXD mark, modem inputs inactive",
             rxd = '1' and cts_n = '1' and dsr_n = '1' and dcd_n = '1' and ri_n = '1');
      expect("off: printer ready", busy = '0' and ack_n = '1' and pe = '0' and slct = '1' and err_n = '1');
      -- something drives the inputs while off: the PC still sees an unplugged port
      x1lo <= "Z0Z0"; x1hi <= "Z01Z"; tick(4);
      expect("off: inputs ignored", rxd = '1' and cts_n = '1' and busy = '0' and ack_n = '1');
      expect("off: no contention", p1lo = "Z0Z0" and p1hi = "Z01Z");
      -- ---- on
      pmod_on <= '1';
      wait for 1 ns;
      expect("on: the enable is registered", en1 = '0');
      tick(1);
      expect("on: both headers powered", en1 = '1' and en2 = '1');
      x1lo <= (others => 'Z'); x1hi <= (others => 'Z');
      tick(1);
      expect("on: TXD, RTS driven", p1lo(1) = '0' and p1lo(3) = '0');
      expect("on: CTS, RXD inputs", p1lo(0) = 'Z' and p1lo(2) = 'Z');
      expect("on: STROBE, INIT driven", p1hi(0) = '0' and p1hi(3) = '0');
      expect("on: BUSY, ACK inputs", p1hi(1) = 'Z' and p1hi(2) = 'Z');
      expect("on: D0-D7", p2lo = "0101" and p2hi = "1010");
      stb_n <= '0'; init_n <= '1'; tick(1);
      expect("on: /STROBE alone", p1hi(0) = '0' and p1hi(3) = '1');
      stb_n <= '1'; init_n <= '0'; tick(1);
      expect("on: /INIT alone", p1hi(0) = '1' and p1hi(3) = '0');
      txd <= '1'; rts_n <= '1'; stb_n <= '1'; init_n <= '1'; lpt_data <= x"3C";
      tick(1);
      expect("on: outputs follow", p1lo(1) = '1' and p1lo(3) = '1' and p1hi(0) = '1' and p1hi(3) = '1' and
             p2lo = "1100" and p2hi = "0011");
      -- the inputs through the synchronizer: two clocks
      x1lo <= "Z0ZZ"; tick(1);                      -- RXD low
      expect("RXD: not yet", rxd /= '0');
      tick(1);
      expect("RXD: after two clocks", rxd = '0');
      x1lo <= "Z1ZZ"; tick(2);
      expect("RXD high", rxd = '1');
      x1lo <= "ZZZ0"; tick(2);
      expect("/CTS low = active", cts_n = '0');
      x1lo <= "ZZZ1"; tick(2);
      expect("/CTS high", cts_n = '1');
      x1hi <= "ZZ1Z"; tick(2);
      expect("BUSY", busy = '1');
      x1hi <= "Z0ZZ"; tick(2);
      expect("/ACK", ack_n = '0' and busy /= '1');
      x1hi <= (others => 'Z'); x1lo <= (others => 'Z');
      -- DSR, DCD follow DTR with the PMOD on; RI inactive
      dtr_n <= '0'; tick(1);
      expect("DSR, DCD = DTR (active)", dsr_n = '0' and dcd_n = '0' and ri_n = '1');
      dtr_n <= '1'; tick(1);
      expect("DSR, DCD = DTR (inactive)", dsr_n = '1' and dcd_n = '1');
      -- off again: everything back to high-Z
      pmod_on <= '0'; tick(3);
      expect("off again", en1 = '0' and en2 = '0' and allz(p1lo) and allz(p1hi) and allz(p2lo) and allz(p2hi));
      dtr_n <= '0'; tick(1);
      expect("off: DSR inactive whatever DTR", dsr_n = '1' and dcd_n = '1');

      -- ---- the mouse lines
      atari <= '0';
      up_n <= '0'; down_n <= '1'; left_n <= '1'; right_n <= '1'; wait for 1 ns;
      expect("Amiga: pin 1 = V", yp = '0' and xp = '1' and xq = '1' and yq = '1');
      up_n <= '1'; down_n <= '0'; wait for 1 ns;
      expect("Amiga: pin 2 = H", xp = '0' and yp = '1' and xq = '1' and yq = '1');
      down_n <= '1'; left_n <= '0'; wait for 1 ns;
      expect("Amiga: pin 3 = VQ", yq = '0' and xp = '1' and xq = '1' and yp = '1');
      left_n <= '1'; right_n <= '0'; wait for 1 ns;
      expect("Amiga: pin 4 = HQ", xq = '0' and xp = '1' and yp = '1' and yq = '1');
      atari <= '1'; wait for 1 ns;
      expect("Atari: pin 4 = V", yp = '0' and xq = '1' and xp = '1' and yq = '1');
      right_n <= '1'; up_n <= '0'; wait for 1 ns;
      expect("Atari: pin 1 = HQ", xq = '0' and yp = '1' and xp = '1' and yq = '1');
      up_n <= '1'; down_n <= '0'; wait for 1 ns;
      expect("Atari: pin 2 = H", xp = '0' and xq = '1');
      down_n <= '1'; left_n <= '0'; wait for 1 ns;
      expect("Atari: pin 3 = VQ", yq = '0' and yp = '1');
      left_n <= '1';
      fire_n <= '0'; wait for 1 ns;
      expect("left button = fire", btn_n(0) = '0');
      fire_n <= '1'; wait for 1 ns;
      expect("left button released", btn_n(0) = '1');

      -- ---- the POT buttons: a passive mouse (lines low from the start) never presses
      pot_x <= x"00"; pot_y <= x"00";
      rst <= '1'; tick(2); rst <= '0'; tick(2);
      expect("passive: right not pressed", btn_n(2) = '1');
      expect("passive: middle not pressed", btn_n(1) = '1');
      -- an active adapter drives the lines high: released; then low = pressed
      pot_x <= x"F0"; pot_y <= x"F0"; tick(2);
      expect("active: released", btn_n(2) = '1' and btn_n(1) = '1');
      pot_x <= x"10"; tick(2);
      expect("active: right pressed", btn_n(2) = '0' and btn_n(1) = '1');
      pot_y <= x"7F"; tick(2);
      expect("active: middle pressed", btn_n(1) = '0');
      pot_x <= x"80"; pot_y <= x"80"; tick(2);
      expect("active: both released", btn_n = "111");
      -- held low longer than the watchdog: disarmed (an unplugged adapter)
      pot_x <= x"00"; tick(5);
      expect("held: pressed", btn_n(2) = '0');
      tick(TMO + 2);
      expect("watchdog: disarmed", btn_n(2) = '1');
      -- the PC's reset disarms
      pot_y <= x"FF"; tick(2); pot_y <= x"00"; tick(2);
      expect("middle pressed before reset", btn_n(1) = '0');
      rst <= '1'; tick(1); rst <= '0'; tick(1);
      expect("reset disarms", btn_n(1) = '1');

      if fails = 0 then report "tb_ports PASS"; else report "tb_ports FAIL (" & integer'image(fails) & ")"; end if;
      done <= true;
      wait;
   end process stim;
end architecture sim;
