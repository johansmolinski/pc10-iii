-- tb_rtc.vhd - pc_rtc.vhd with M2M's RTC device (rtc_controller.vhd and its rtc_master, the I2C
-- side answered by a stub) and the firmware's PC_RTC_WB (CORE/m2m-rom/pc_rtc.asm) as a
-- procedure that makes the same device accesses: a set from the PC raises "pending" with the
-- time, the write-back stops M2M's internal timer, writes its eight registers, copies them into
-- the RTC with auto-start (0x0C), acknowledges; M2M's rtc_o (the core's main_rtc_i) then shows
-- the PC's time and its toggle has not moved (the core does not reseed from its own write-back);
-- a write-back while the I2C bus is busy waits for a later call; a second set while one is
-- pending is delivered after the acknowledge with the time of that moment; no request without a
-- set; an acknowledge without a request, or a write of 0, changes nothing.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_rtc is
end entity tb_rtc;

architecture sim of tb_rtc is
   signal qclk, mclk : std_logic := '0';
   signal done       : boolean := false;
   signal qrst       : std_logic := '1';

   -- pc_rtc
   signal p_addr     : std_logic_vector(27 downto 0) := (others => '0');
   signal p_wdata    : std_logic_vector(15 downto 0) := (others => '0');
   signal p_rdata    : std_logic_vector(15 downto 0);
   signal p_ce, p_we : std_logic := '0';
   signal set        : std_logic := '0';
   signal tim        : std_logic_vector(63 downto 0) := (others => '0');

   -- M2M's RTC device
   signal r_ce, r_we : std_logic := '0';
   signal r_addr     : std_logic_vector(7 downto 0) := (others => '0');
   signal r_wdata    : std_logic_vector(15 downto 0) := (others => '0');
   signal r_rdata    : std_logic_vector(15 downto 0);
   signal rtc_o      : std_logic_vector(64 downto 0);
   signal m_wait     : std_logic := '0';
   signal m_ce, m_we : std_logic;
   signal m_addr     : std_logic_vector(7 downto 0);
   signal m_wdata    : std_logic_vector(15 downto 0);
   signal m_rdata    : std_logic_vector(15 downto 0) := x"0000";
   signal i2c_writes : natural := 0;
   signal i2c_hold   : boolean := false;     -- keep the I2C side busy
begin
   qclk <= not qclk after 10 ns when not done;     -- 50 MHz
   mclk <= not mclk after 17.46 ns when not done;  -- 28.64 MHz

   dut : entity work.pc_rtc
      port map (qnice_clk_i => qclk, qnice_addr_i => p_addr, qnice_data_i => p_wdata,
                qnice_data_o => p_rdata, qnice_ce_i => p_ce, qnice_we_i => p_we,
                main_clk_i => mclk, set_i => set, time_i => tim);

   m2m : entity work.rtc_controller
      generic map (G_CLK_SPEED_HZ => 50_000_000, G_BOARD => "MEGA65_R6")
      port map (clk_i => qclk, rst_i => qrst, rtc_o => rtc_o,
                cpu_s_wait_o => open, cpu_s_ce_i => r_ce, cpu_s_we_i => r_we, cpu_s_addr_i => r_addr,
                cpu_s_wr_data_i => r_wdata, cpu_s_rd_data_o => r_rdata,
                cpu_m_wait_i => m_wait, cpu_m_ce_o => m_ce, cpu_m_we_o => m_we, cpu_m_addr_o => m_addr,
                cpu_m_wr_data_o => m_wdata, cpu_m_rd_data_i => m_rdata);

   -- the I2C controller: the status register 0xF1 answers 1 (idle) and 0 (accepted) in turn,
   -- the buffer 0x0101 (a valid day and month)
   i2c : process (qclk)
      variable alt : std_logic := '0';
   begin
      if rising_edge(qclk) then
         m_rdata <= x"0101";
         if m_ce = '1' and m_we = '0' and m_addr = x"F1" then
            alt := not alt;
            if i2c_hold then
               m_rdata <= x"0002";
            else
               m_rdata <= x"000" & "000" & alt;
            end if;
         end if;
         if m_ce = '1' and m_we = '1' then
            i2c_writes <= i2c_writes + 1;
         end if;
      end if;
   end process i2c;

   stim : process
      variable fails : natural := 0;
      variable v     : std_logic_vector(15 downto 0);
      variable tog   : std_logic;
      variable ok    : boolean;
      constant T1    : std_logic_vector(63 downto 0) := x"0084031411234756";   -- Sun 14.03.84 11:23:47.56
      constant T2    : std_logic_vector(63 downto 0) := x"0300010100000123";
      constant T3    : std_logic_vector(63 downto 0) := x"0499123123595900";
      procedure expect(what : string; c : boolean) is
      begin
         if not c then report "FAIL " & what; fails := fails + 1; end if;
      end procedure;
      -- QNICE accesses (one qnice clock, written on the falling edge)
      procedure p_rd(a : natural; d : out std_logic_vector(15 downto 0)) is
      begin
         p_addr <= std_logic_vector(to_unsigned(a, 28));
         p_ce <= '1'; p_we <= '0';
         wait until rising_edge(qclk);
         d := p_rdata;
         p_ce <= '0';
      end procedure;
      procedure p_wr(a : natural; d : std_logic_vector(15 downto 0)) is
      begin
         p_addr <= std_logic_vector(to_unsigned(a, 28));
         p_wdata <= d;
         p_ce <= '1'; p_we <= '1';
         wait until falling_edge(qclk);
         wait until rising_edge(qclk);
         p_ce <= '0'; p_we <= '0';
      end procedure;
      procedure r_rd(a : natural; d : out std_logic_vector(15 downto 0)) is
      begin
         r_addr <= std_logic_vector(to_unsigned(a, 8));
         r_ce <= '1'; r_we <= '0';
         wait for 1 ns;
         d := r_rdata;
         wait until rising_edge(qclk);
         r_ce <= '0';
      end procedure;
      procedure r_wr(a : natural; d : std_logic_vector(15 downto 0)) is
      begin
         r_addr <= std_logic_vector(to_unsigned(a, 8));
         r_wdata <= d;
         r_ce <= '1'; r_we <= '1';
         wait until rising_edge(qclk);
         r_ce <= '0'; r_we <= '0';
      end procedure;
      -- PC_RTC_WB: returns did = true when it wrote the time back
      procedure wb(did : out boolean) is
         variable s, b : std_logic_vector(15 downto 0);
      begin
         did := false;
         p_rd(0, s);
         if s(0) = '0' then return; end if;
         r_wr(8, x"0000");
         r_rd(8, s);
         if s /= x"0000" then return; end if;
         for i in 0 to 7 loop
            p_rd(1 + i, b);
            r_wr(i, b);
         end loop;
         r_wr(8, x"000C");
         p_wr(0, x"0001");
         did := true;
      end procedure;
      procedure pc_set(t : std_logic_vector(63 downto 0)) is
      begin
         wait until rising_edge(mclk);
         tim <= t; set <= '1';
         wait until rising_edge(mclk);
         set <= '0';
      end procedure;
      procedure idle_q(n : natural) is
      begin
         for i in 1 to n loop wait until rising_edge(qclk); end loop;
      end procedure;
   begin
      idle_q(4);
      qrst <= '0';
      -- the power-up read of the RTC (the toggle flips once)
      for i in 1 to 2000 loop
         r_rd(8, v);
         exit when v(0) = '0';
      end loop;
      idle_q(10);
      expect("power-up read done", v(0) = '0' and rtc_o(64) = '1');
      tog := rtc_o(64);

      -- nothing pending without a set
      p_rd(0, v);
      expect("no request at start", v(0) = '0');
      wb(ok);
      expect("no write-back without a set", not ok);

      -- one set: pending with the time
      pc_set(T1);
      tim <= T2;                                -- the clock runs on: the request keeps T1
      idle_q(10);
      p_rd(0, v);
      expect("pending after a set", v(0) = '1');
      for i in 0 to 7 loop
         p_rd(1 + i, v);
         expect("time byte " & integer'image(i), v(7 downto 0) = T1(8 * i + 7 downto 8 * i));
      end loop;
      -- the I2C side busy: the write-back waits
      i2c_hold <= true;
      r_wr(8, x"0000");                         -- stop, then copy RTC -> internal: busy
      r_wr(8, x"0002");
      idle_q(4);
      wb(ok);
      expect("waits while the I2C bus is busy", not ok);
      p_rd(0, v);
      expect("still pending", v(0) = '1');
      p_wr(0, x"0000");                         -- bit 0 clear: no acknowledge
      idle_q(10);
      p_rd(0, v);
      expect("a write of 0 does not acknowledge", v(0) = '1');
      i2c_hold <= false;
      for i in 1 to 2000 loop
         r_rd(8, v);
         exit when v(0) = '0';
      end loop;
      idle_q(4);
      tog := rtc_o(64);                         -- (that read flipped it)
      wb(ok);
      expect("written back", ok);
      for i in 1 to 2000 loop
         r_rd(8, v);
         exit when v(3 downto 0) = "1000";      -- running again, I2C idle
      end loop;
      expect("M2M timer running again", v(3 downto 0) = "1000");
      idle_q(10);
      expect("rtc_o: the PC's time", rtc_o(55 downto 8) = T1(63 downto 16));
      expect("rtc_o: no new toggle", rtc_o(64) = tog);
      expect("the write reached the I2C side", i2c_writes > 0);
      idle_q(20);
      p_rd(0, v);
      expect("acknowledged", v(0) = '0');
      wb(ok);
      expect("no second write-back", not ok);
      p_wr(0, x"0001");                         -- a second acknowledge changes nothing
      idle_q(20);
      p_rd(0, v);
      expect("a second acknowledge: nothing pending", v(0) = '0');

      -- two sets close together: the second after the acknowledge, with the time then
      pc_set(T2);
      tim <= T2;
      idle_q(5);
      pc_set(T3);
      tim <= T3;
      idle_q(10);
      for i in 0 to 7 loop
         p_rd(1 + i, v);
         expect("first request T2", v(7 downto 0) = T2(8 * i + 7 downto 8 * i));
      end loop;
      wb(ok);
      expect("first write-back", ok);
      for i in 1 to 2000 loop
         r_rd(8, v);
         exit when v(2 downto 0) = "000";
      end loop;
      idle_q(20);
      p_rd(0, v);
      expect("the second request pending", v(0) = '1');
      for i in 0 to 7 loop
         p_rd(1 + i, v);
         expect("second request T3", v(7 downto 0) = T3(8 * i + 7 downto 8 * i));
      end loop;
      wb(ok);
      expect("second write-back", ok);
      for i in 1 to 2000 loop
         r_rd(8, v);
         exit when v(3 downto 0) = "1000";
      end loop;
      idle_q(20);
      expect("rtc_o: T3", rtc_o(55 downto 8) = T3(63 downto 16));
      p_rd(0, v);
      expect("nothing left", v(0) = '0');

      if fails = 0 then report "tb_rtc PASS"; else report "tb_rtc FAIL: " & integer'image(fails); end if;
      done <= true;
      wait;
   end process stim;
end architecture sim;
