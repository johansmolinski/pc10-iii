-- tb_fdd.vhd - pc_fdd_sd.vhd against a model of the SD host's engine port (sdhost.vhd's
-- protocol: READY/BUSY, START pulse, read bytes with RDWE/RDIDX/RDDATA, write bytes fetched by
-- WRIDX with the data one clock later, BLK and DONE in different clocks, DONE without BLK
-- when QNICE preempted the port) and a sector-port driver that follows doc/fdc.md section 5.
--
-- The image: 720 sectors (360K), clusters of 4 sectors, two extents (clusters 10..109 and
-- 300..379), cluster 0 at block 100. Checks: read data and block translation in both extents,
-- a write and its read-back, sp_wr_ready, a request beyond the file, a write to a write-
-- protected drive, a drive that is off, the preempt case, an engine error with retries and
-- the geometry outputs.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.sdhost_pkg.all;

entity tb_fdd is
end entity tb_fdd;

architecture sim of tb_fdd is
   signal qclk, mclk : std_logic := '0';
   signal done       : boolean := false;

   signal qaddr      : std_logic_vector(27 downto 0) := (others => '0');
   signal qdin       : std_logic_vector(15 downto 0) := (others => '0');
   signal qdout      : std_logic_vector(15 downto 0);
   signal qce, qwe   : std_logic := '0';
   signal qdrive     : std_logic := '0';
   signal qwp        : std_logic_vector(1 downto 0) := "00";

   signal c2q        : std_logic_vector(75 downto 0);
   signal q2c        : std_logic_vector(63 downto 0) := (others => '0');

   signal present, wp80, wpo : std_logic_vector(1 downto 0);
   signal tracks     : std_logic_vector(15 downto 0);
   signal heads      : std_logic_vector(3 downto 0);
   signal spt        : std_logic_vector(11 downto 0);

   signal sp_req, sp_write, sp_drive : std_logic := '0';
   signal sp_lba     : std_logic_vector(15 downto 0) := (others => '0');
   signal sp_rd_valid, sp_wr_ready, sp_done, sp_err : std_logic;
   signal sp_rd_data : std_logic_vector(7 downto 0);
   signal sp_wr_valid : std_logic := '0';
   signal sp_wr_data : std_logic_vector(7 downto 0) := (others => '0');
   signal busy       : std_logic;

   -- model controls
   signal preempt_total : natural := 0;    -- transfers so far that end without a block
   signal error_total   : natural := 0;    -- transfers so far that fail
   signal starts       : natural := 0;
   signal last_block   : natural := 0;

   function card_byte(blk : natural; i : natural) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned((blk * 7 + i * 3) mod 256, 8));
   end function;

   function lba2blk(l : natural) return natural is
      variable cl : natural := l / 4;
   begin
      if cl < 100 then
         return 100 + (10 + cl) * 4 + l mod 4;
      else
         return 100 + (300 + cl - 100) * 4 + l mod 4;
      end if;
   end function;
begin
   qclk <= not qclk after 10 ns when not done;
   mclk <= not mclk after 5 ns when not done;

   dut : entity work.pc_fdd_sd
      generic map (G_MS => 50, G_READY_WAIT => 20)
      port map (
         qnice_clk_i => qclk, qnice_rst_i => '0', qnice_drive_i => qdrive,
         qnice_addr_i => qaddr, qnice_data_i => qdin, qnice_data_o => qdout,
         qnice_ce_i => qce, qnice_we_i => qwe, qnice_wp_i => qwp,
         sd_c2q_o => c2q, sd_q2c_i => q2c,
         main_clk_i => mclk, main_rst_i => '0',
         drv_80trk_o => wp80, img_present_o => present, img_wp_o => wpo,
         img_tracks_o => tracks, img_heads_o => heads, img_spt_o => spt,
         sp_req_i => sp_req, sp_write_i => sp_write, sp_drive_i => sp_drive, sp_lba_i => sp_lba,
         sp_rd_valid_o => sp_rd_valid, sp_rd_data_o => sp_rd_data,
         sp_wr_valid_i => sp_wr_valid, sp_wr_data_i => sp_wr_data, sp_wr_ready_o => sp_wr_ready,
         sp_done_o => sp_done, sp_err_o => sp_err, main_busy_o => busy);

   -- the engine port model (QNICE clock, rising edge)
   p_model : process
      type t_card is array (0 to 2047 * 512 + 511) of std_logic_vector(7 downto 0);
      variable card  : t_card;
      variable blk   : natural;
      variable wr    : std_logic;
      variable p_cnt : natural := 0;
      variable e_cnt : natural := 0;
   begin
      for b in 0 to 2047 loop
         for i in 0 to 511 loop
            card(b * 512 + i) := card_byte(b, i);
         end loop;
      end loop;
      q2c(Q2C_READY) <= '1';
      loop
         wait until rising_edge(qclk);
         q2c(Q2C_DONE) <= '0'; q2c(Q2C_BLK) <= '0'; q2c(Q2C_RDWE) <= '0'; q2c(Q2C_ERROR) <= '0';
         if c2q(C2Q_START) = '1' then
            assert q2c(Q2C_BUSY) = '0' report "START while busy" severity failure;
            assert c2q(C2Q_COUNT) = x"0001" report "count /= 1" severity failure;
            starts <= starts + 1;
            blk := to_integer(unsigned(c2q(C2Q_ADDR)));
            last_block <= blk;
            wr  := c2q(C2Q_WRITE);
            q2c(Q2C_BUSY) <= '1';
            for k in 1 to 5 loop wait until rising_edge(qclk); end loop;
            if p_cnt < preempt_total then
               p_cnt := p_cnt + 1;
            elsif e_cnt < error_total then
               e_cnt := e_cnt + 1;
               q2c(Q2C_ERROR) <= '1';
            elsif wr = '0' then
               for i in 0 to 511 loop
                  q2c(Q2C_RDWE) <= '1';
                  q2c(Q2C_RDIDX) <= std_logic_vector(to_unsigned(i, 9));
                  q2c(Q2C_RDDATA) <= card(blk * 512 + i);
                  wait until rising_edge(qclk);
                  q2c(Q2C_RDWE) <= '0';
                  wait until rising_edge(qclk);
               end loop;
               q2c(Q2C_BLK) <= '1';
               wait until rising_edge(qclk);
               q2c(Q2C_BLK) <= '0';
            else
               for i in 0 to 511 loop
                  q2c(Q2C_WRIDX) <= std_logic_vector(to_unsigned(i, 9));
                  wait until rising_edge(qclk);
                  wait until rising_edge(qclk);                 -- the byte one clock later
                  card(blk * 512 + i) := c2q(C2Q_WRDATA);
               end loop;
               q2c(Q2C_BLK) <= '1';
               wait until rising_edge(qclk);
               q2c(Q2C_BLK) <= '0';
            end if;
            q2c(Q2C_DONE) <= '1';
            q2c(Q2C_BUSY) <= '0';
         end if;
      end loop;
   end process p_model;

   p_test : process
      procedure qw(drv : std_logic; win, ofs, d : natural) is
      begin
         wait until rising_edge(qclk);
         qdrive <= drv;
         qaddr <= std_logic_vector(to_unsigned(win, 16)) & std_logic_vector(to_unsigned(ofs, 12));
         qdin  <= std_logic_vector(to_unsigned(d, 16));
         qce <= '1'; qwe <= '1';
         wait until rising_edge(qclk);
         qce <= '0'; qwe <= '0';
      end procedure;

      -- one sector request; reads compare with the card content of block lba2blk(lba) (+ xor)
      procedure req(drv : std_logic; lba : natural; write : std_logic; xorv : natural;
                    expect_err : std_logic) is
         variable n : natural := 0;
         variable b : natural := lba2blk(lba);
      begin
         wait until rising_edge(mclk);
         sp_req <= '1'; sp_write <= write; sp_drive <= drv;
         sp_lba <= std_logic_vector(to_unsigned(lba, 16));
         if write = '1' then
            for i in 0 to 511 loop
               sp_wr_valid <= '1';
               sp_wr_data  <= card_byte(b, i) xor std_logic_vector(to_unsigned(xorv, 8));
               loop
                  wait until rising_edge(mclk);
                  exit when sp_wr_ready = '1';
               end loop;
               sp_wr_valid <= '0';
               wait until rising_edge(mclk);                   -- at most every second clock
            end loop;
         end if;
         loop
            wait until rising_edge(mclk);
            if sp_rd_valid = '1' then
               assert sp_rd_data = (card_byte(b, n) xor std_logic_vector(to_unsigned(xorv, 8)))
                  report "LBA " & integer'image(lba) & " byte " & integer'image(n) & ": " &
                         to_hstring(sp_rd_data) severity failure;
               n := n + 1;
            end if;
            exit when sp_done = '1';
         end loop;
         assert sp_err = expect_err report "LBA " & integer'image(lba) & ": sp_err = " &
                                           std_logic'image(sp_err) severity failure;
         if write = '0' and expect_err = '0' then
            assert n = 512 report "LBA " & integer'image(lba) & ": " & integer'image(n) & " bytes"
               severity failure;
         end if;
         sp_req <= '0';
         wait until rising_edge(mclk);
      end procedure;
   begin
      -- drive A: the extent map (window 1), then the registers, mode last
      qw('0', 1, 0, 2);
      qw('0', 1, 1, 10);  qw('0', 1, 2, 0); qw('0', 1, 3, 100); qw('0', 1, 4, 0);
      qw('0', 1, 5, 300); qw('0', 1, 6, 0); qw('0', 1, 7, 80);  qw('0', 1, 8, 0);
      qw('0', 0, 1, 720); qw('0', 0, 2, 0);
      qw('0', 0, 3, 100); qw('0', 0, 4, 0);
      qw('0', 0, 5, 2);
      qw('0', 0, 0, 1);
      wait for 1 us;
      assert present = "01" and tracks(7 downto 0) = x"28" and heads(1 downto 0) = "10" and
             spt(5 downto 0) = "001001" and wp80 = "00"
         report "geometry of a 360K image" severity failure;

      req('0', 0, '0', 0, '0');                -- first extent
      assert last_block = 140 report "block of LBA 0: " & integer'image(last_block) severity failure;
      req('0', 399, '0', 0, '0');              -- last sector of the first extent
      req('0', 400, '0', 0, '0');              -- second extent
      assert last_block = 1300 report "block of LBA 400: " & integer'image(last_block) severity failure;
      req('0', 719, '0', 0, '0');
      req('0', 720, '0', 0, '1');              -- beyond the file
      req('1', 0, '0', 0, '1');                -- B: is off

      req('0', 5, '1', 16#A5#, '0');           -- write, then read it back
      req('0', 5, '0', 16#A5#, '0');
      qwp <= "01";
      wait for 200 ns;
      req('0', 6, '1', 16#5A#, '1');           -- write protected
      qwp <= "00";

      preempt_total <= 2;                       -- QNICE took the port twice
      wait until rising_edge(qclk);
      req('0', 7, '0', 0, '0');
      error_total <= 2;                         -- two errors, then it works (G_RETRIES = 2)
      wait until rising_edge(qclk);
      req('0', 8, '0', 0, '0');
      error_total <= 5;                         -- three: the request fails
      wait until rising_edge(qclk);
      req('0', 9, '0', 0, '1');

      qw('0', 0, 1, 1440);                     -- 720K: an 80-track drive
      wait for 1 us;
      assert tracks(7 downto 0) = x"50" and wp80 = "01" report "geometry of a 720K image" severity failure;
      qw('0', 0, 1, 1000);                     -- no known format: no disk
      wait for 1 us;
      assert present = "00" report "odd size must mean no disk" severity failure;

      report "PASS: pc_fdd_sd (" & integer'image(starts) & " engine transfers)";
      done <= true;
      wait;
   end process p_test;
end architecture sim;
