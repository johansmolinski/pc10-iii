-- tb_fdd.vhd - pc_fdd_sd.vhd against a model of the SD host's engine port (sdhost.vhd's
-- protocol: READY/BUSY, START pulse, read bytes with RDWE/RDIDX/RDDATA, write bytes fetched by
-- WRIDX with the data one clock later, BLK and DONE in different clocks, DONE without BLK
-- when QNICE preempted the port) and two sector-port drivers: the FDC's (doc/fdc.md section 5)
-- and the hard disk card's (xta_card.sv, the hd_sp_* protocol of doc/hdc.md section 5).
--
-- A: 720 sectors (360K), clusters of 4 sectors, two extents (clusters 10..109 and 300..379),
-- cluster 0 at block 100. C: 41,820 sectors (the PC20-III's drive), clusters of 64 sectors,
-- three extents (clusters 1000..1199, 5000..5299, 9000..9153: the last cluster is only partly
-- the file's), cluster 0 at block 200000. Checks: read data and block translation in every
-- extent of both drives, writes and their read-back, sp_wr_ready, requests beyond the file
-- (C: also an LBA above 65535), a write to a write-protected drive, drives that are off, C:
-- with a wrong size (no disk, every request fails), the preempt case, an engine error with
-- retries, the geometry outputs; both ports at once (reads, writes, back-to-back requests
-- served in turn), answers only to the port that asked, and requests abandoned by their port
-- (dropped before sp_done, as a card reset does) in the wait, in the write collection and
-- in the read stream.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.sdhost_pkg.all;

entity tb_fdd is
end entity tb_fdd;

architecture sim of tb_fdd is
   constant HD_BASE  : natural := 200000;

   signal qclk, mclk : std_logic := '0';
   signal done       : boolean := false;

   signal qaddr      : std_logic_vector(27 downto 0) := (others => '0');
   signal qdin       : std_logic_vector(15 downto 0) := (others => '0');
   signal qdout      : std_logic_vector(15 downto 0);
   signal qce, qwe   : std_logic := '0';
   signal qdrive     : std_logic_vector(1 downto 0) := "00";
   signal qwp        : std_logic_vector(1 downto 0) := "00";

   signal c2q        : std_logic_vector(75 downto 0);
   signal q2c        : std_logic_vector(63 downto 0) := (others => '0');

   signal present, wp80, wpo : std_logic_vector(1 downto 0);
   signal hd_present : std_logic;
   signal tracks     : std_logic_vector(15 downto 0);
   signal heads      : std_logic_vector(3 downto 0);
   signal spt        : std_logic_vector(11 downto 0);

   -- the FDC's port
   signal sp_req, sp_write, sp_drive : std_logic := '0';
   signal sp_lba     : std_logic_vector(15 downto 0) := (others => '0');
   signal sp_rd_valid, sp_wr_ready, sp_done, sp_err : std_logic;
   signal sp_rd_data : std_logic_vector(7 downto 0);
   signal sp_wr_valid : std_logic := '0';
   signal sp_wr_data : std_logic_vector(7 downto 0) := (others => '0');
   -- the hard disk's port
   signal hd_req, hd_write : std_logic := '0';
   signal hd_lba     : std_logic_vector(27 downto 0) := (others => '0');
   signal hd_rd_valid, hd_wr_ready, hd_done, hd_err : std_logic;
   signal hd_rd_data : std_logic_vector(7 downto 0);
   signal hd_wr_valid : std_logic := '0';
   signal hd_wr_data : std_logic_vector(7 downto 0) := (others => '0');
   signal busy       : std_logic;

   -- model controls
   signal preempt_total : natural := 0;    -- transfers so far that end without a block
   signal error_total   : natural := 0;    -- transfers so far that fail
   signal starts       : natural := 0;
   signal last_block   : natural := 0;
   -- the order of the transfers (F = a floppy block, H = a hard disk block) while log_on
   signal log_on       : boolean := false;
   signal log_str      : string(1 to 16) := (others => '.');
   signal log_n        : natural := 0;
   -- the hard disk's process
   signal hd_go        : natural := 0;     -- the test step the hard disk process runs
   signal hd_ack       : natural := 0;     -- the last step it finished
   signal go_both      : std_logic := '0';

   function card_byte(blk : natural; i : natural) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned((blk * 7 + i * 3 + blk / 256) mod 256, 8));
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

   function hd2blk(l : natural) return natural is
      variable cl : natural := l / 64;
   begin
      if cl < 200 then
         return HD_BASE + (1000 + cl) * 64 + l mod 64;
      elsif cl < 500 then
         return HD_BASE + (5000 + cl - 200) * 64 + l mod 64;
      else
         return HD_BASE + (9000 + cl - 500) * 64 + l mod 64;
      end if;
   end function;

   -- one sector request on a port (the caller is just past a rising edge of mclk unless
   -- sync); reads compare with the card content of block blk (xor xorv), writes send it
   -- (xor xorv). The request drops in the clock after sp_done; the procedure returns one
   -- clock later, so a following call re-requests after exactly one clock low.
   procedure sreq(signal clk : in std_logic;
                  signal req, wr : out std_logic; signal lba_o : out std_logic_vector;
                  signal wv : out std_logic; signal wd : out std_logic_vector(7 downto 0);
                  signal rv, rdy, dn, er : in std_logic; signal rd : in std_logic_vector(7 downto 0);
                  lba, blk : natural; write : std_logic; xorv : natural; expect_err : std_logic;
                  tag : string; sync : boolean := true) is
      variable n : natural := 0;
   begin
      if sync then
         wait until rising_edge(clk);
      end if;
      req <= '1'; wr <= write;
      lba_o <= std_logic_vector(to_unsigned(lba, lba_o'length));
      if write = '1' then
         for i in 0 to 511 loop
            wv <= '1';
            wd <= card_byte(blk, i) xor std_logic_vector(to_unsigned(xorv, 8));
            loop
               wait until rising_edge(clk);
               exit when rdy = '1';
               if dn = '1' then                           -- refused before the data
                  exit;
               end if;
            end loop;
            wv <= '0';
            exit when dn = '1';
            wait until rising_edge(clk);                    -- at most every second clock
         end loop;
      end if;
      if dn /= '1' then
         loop
            wait until rising_edge(clk);
            if rv = '1' then
               assert rd = (card_byte(blk, n) xor std_logic_vector(to_unsigned(xorv, 8)))
                  report tag & " LBA " & integer'image(lba) & " byte " & integer'image(n) & ": " &
                         to_hstring(rd) severity failure;
               n := n + 1;
            end if;
            exit when dn = '1';
         end loop;
      end if;
      assert er = expect_err report tag & " LBA " & integer'image(lba) & ": sp_err = " &
                                     std_logic'image(er) severity failure;
      if write = '0' and expect_err = '0' then
         assert n = 512 report tag & " LBA " & integer'image(lba) & ": " & integer'image(n) &
                               " bytes" severity failure;
      end if;
      req <= '0';
      wait until rising_edge(clk);
   end procedure;
begin
   qclk <= not qclk after 10 ns when not done;
   mclk <= not mclk after 17.46 ns when not done;   -- 28.63636 MHz

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
         sp_done_o => sp_done, sp_err_o => sp_err,
         hd_present_o => hd_present,
         hd_sp_req_i => hd_req, hd_sp_write_i => hd_write, hd_sp_lba_i => hd_lba,
         hd_sp_rd_valid_o => hd_rd_valid, hd_sp_rd_data_o => hd_rd_data,
         hd_sp_wr_valid_i => hd_wr_valid, hd_sp_wr_data_i => hd_wr_data,
         hd_sp_wr_ready_o => hd_wr_ready, hd_sp_done_o => hd_done, hd_sp_err_o => hd_err,
         main_busy_o => busy);

   -- answers only while the port asks, and only to it
   -- (a request that drops, abandoned, may see one more clock of what was under way)
   p_mon : process (mclk)
      variable sp_req_d, hd_req_d : std_logic := '0';
   begin
      if rising_edge(mclk) then
         assert not ((sp_rd_valid = '1' or sp_done = '1') and sp_req = '0' and sp_req_d = '0')
            report "FDC port: an answer without a request" severity failure;
         assert not ((hd_rd_valid = '1' or hd_done = '1') and hd_req = '0' and hd_req_d = '0')
            report "hard disk port: an answer without a request" severity failure;
         sp_req_d := sp_req;
         hd_req_d := hd_req;
         assert not (sp_err = '1' and sp_done = '0') report "FDC port: sp_err without sp_done"
            severity failure;
         assert not (hd_err = '1' and hd_done = '0') report "hard disk port: sp_err without sp_done"
            severity failure;
         assert not (sp_wr_ready = '1' and hd_wr_ready = '1')
            report "both ports ready for write data" severity failure;
      end if;
   end process p_mon;

   -- the engine port model (QNICE clock, rising edge); the card: card_byte() for every block
   -- not written yet, the written blocks in a small store
   p_model : process
      constant NSTORE : natural := 32;
      type t_blk   is array (0 to 511) of std_logic_vector(7 downto 0);
      type t_store is array (0 to NSTORE - 1) of t_blk;
      type t_nums  is array (0 to NSTORE - 1) of integer;
      variable store : t_store;
      variable nums  : t_nums := (others => -1);
      variable slot  : integer;
      variable blk   : natural;
      variable wr    : std_logic;
      variable p_cnt : natural := 0;
      variable e_cnt : natural := 0;
      impure function find(b : integer) return integer is
      begin
         for k in 0 to NSTORE - 1 loop
            if nums(k) = b then return k; end if;
         end loop;
         return -1;
      end function;
   begin
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
            if log_on and log_n < 16 then
               if blk >= HD_BASE then
                  log_str(log_n + 1) <= 'H';
               else
                  log_str(log_n + 1) <= 'F';
               end if;
               log_n <= log_n + 1;
            end if;
            wr  := c2q(C2Q_WRITE);
            slot := find(blk);
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
                  if slot >= 0 then
                     q2c(Q2C_RDDATA) <= store(slot)(i);
                  else
                     q2c(Q2C_RDDATA) <= card_byte(blk, i);
                  end if;
                  wait until rising_edge(qclk);
                  q2c(Q2C_RDWE) <= '0';
                  wait until rising_edge(qclk);
               end loop;
               q2c(Q2C_BLK) <= '1';
               wait until rising_edge(qclk);
               q2c(Q2C_BLK) <= '0';
            else
               if slot < 0 then
                  slot := find(-1);
                  assert slot >= 0 report "model: store full" severity failure;
                  nums(slot) := blk;
               end if;
               for i in 0 to 511 loop
                  q2c(Q2C_WRIDX) <= std_logic_vector(to_unsigned(i, 9));
                  wait until rising_edge(qclk);
                  wait until rising_edge(qclk);                 -- the byte one clock later
                  store(slot)(i) := c2q(C2Q_WRDATA);
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

   -- the hard disk card's process: runs test step hd_go, then hd_ack <= hd_go
   p_hd : process
      procedure hreq(lba, blk : natural; write : std_logic; xorv : natural; expect_err : std_logic;
                     sync : boolean := true) is
      begin
         sreq(mclk, hd_req, hd_write, hd_lba, hd_wr_valid, hd_wr_data,
              hd_rd_valid, hd_wr_ready, hd_done, hd_err, hd_rd_data,
              lba, blk, write, xorv, expect_err, "C:", sync);
      end procedure;
      variable st : natural;
   begin
      wait until hd_go /= hd_ack;
      st := hd_go;
      case st is
         when 1 =>                                   -- reads: every extent, the edges
            hreq(0, hd2blk(0), '0', 0, '0');
            assert last_block = HD_BASE + 1000 * 64 report "block of C: LBA 0: " &
               integer'image(last_block) severity failure;
            hreq(12799, hd2blk(12799), '0', 0, '0');  -- last of the first extent
            hreq(12800, hd2blk(12800), '0', 0, '0');  -- second extent
            assert last_block = HD_BASE + 5000 * 64 report "block of C: LBA 12800: " &
               integer'image(last_block) severity failure;
            hreq(31999, hd2blk(31999), '0', 0, '0');
            hreq(32000, hd2blk(32000), '0', 0, '0');  -- third extent
            assert last_block = HD_BASE + 9000 * 64 report "block of C: LBA 32000" severity failure;
            hreq(41819, hd2blk(41819), '0', 0, '0');  -- the last sector
            assert last_block = HD_BASE + 9153 * 64 + 27 report "block of C: LBA 41819" severity failure;
            hreq(20005, hd2blk(20005), '0', 0, '0');  -- inside a cluster
            assert last_block = HD_BASE + (5000 + 312 - 200) * 64 + 37 report "block of C: LBA 20005"
               severity failure;
         when 2 =>                                   -- beyond the file, above 65535
            hreq(41820, hd2blk(41820), '0', 0, '1');
            hreq(65536 + 5, 0, '0', 0, '1');
            hreq(16#FFFFFFF#, 0, '0', 0, '1');
         when 3 =>                                   -- write, read back (the floppy's WP is on)
            hreq(13000, hd2blk(13000), '1', 16#3C#, '0');
            hreq(13000, hd2blk(13000), '0', 16#3C#, '0');
            hreq(13001, hd2blk(13001), '0', 0, '0');  -- the neighbour unchanged
         when 4 | 9 | 10 =>                          -- an error expected (off, no disk)
            hreq(7, hd2blk(7), '0', 0, '1');
            hreq(8, hd2blk(8), '1', 0, '1');
         when 5 =>                                   -- both ports at once: reads
            wait until go_both = '1';
            for k in 0 to 3 loop
               hreq(100 + k, hd2blk(100 + k), '0', 0, '0', false);
            end loop;
         when 6 =>                                   -- both ports at once: writes, read back
            wait until go_both = '1';
            hreq(40000, hd2blk(40000), '1', 16#77#, '0', false);
            hreq(40001, hd2blk(40001), '1', 16#78#, '0', false);
            hreq(40000, hd2blk(40000), '0', 16#77#, '0', false);
            hreq(40001, hd2blk(40001), '0', 16#78#, '0', false);
         when 7 =>                                   -- abandoned in the wait, then a new one
            wait until rising_edge(mclk);
            hd_req <= '1'; hd_write <= '0';
            hd_lba <= std_logic_vector(to_unsigned(300, 28));
            for k in 1 to 300 loop wait until rising_edge(mclk); end loop;   -- in the transfer
            assert busy = '1' report "abandon: the backend is not busy" severity failure;
            hd_req <= '0';                                -- the card is reset
            for k in 1 to 30 loop wait until rising_edge(mclk); end loop;
            hreq(301, hd2blk(301), '0', 0, '0');          -- asked while the old one runs
         when 8 =>                                   -- abandoned while the data are collected
            wait until rising_edge(mclk);
            hd_req <= '1'; hd_write <= '1';
            hd_lba <= std_logic_vector(to_unsigned(302, 28));
            for i in 0 to 99 loop
               hd_wr_valid <= '1'; hd_wr_data <= x"EE";
               loop
                  wait until rising_edge(mclk);
                  exit when hd_wr_ready = '1';
               end loop;
               hd_wr_valid <= '0';
               wait until rising_edge(mclk);
            end loop;
            hd_req <= '0';
            wait until rising_edge(mclk);
            wait until rising_edge(mclk);
            hreq(302, hd2blk(302), '0', 0, '0');          -- unchanged
         when 11 =>                                  -- abandoned while the data are streamed
            wait until rising_edge(mclk);
            hd_req <= '1'; hd_write <= '0';
            hd_lba <= std_logic_vector(to_unsigned(303, 28));
            loop
               wait until rising_edge(mclk);
               exit when hd_rd_valid = '1';
            end loop;
            for k in 1 to 100 loop wait until rising_edge(mclk); end loop;
            hd_req <= '0';
            wait until rising_edge(mclk);
            wait until rising_edge(mclk);
            hreq(304, hd2blk(304), '0', 0, '0', false);   -- asked again at once
         when others => null;
      end case;
      hd_ack <= st;
   end process p_hd;

   p_test : process
      procedure qw(drv, win, ofs, d : natural) is
      begin
         wait until rising_edge(qclk);
         qdrive <= std_logic_vector(to_unsigned(drv, 2));
         qaddr <= std_logic_vector(to_unsigned(win, 16)) & std_logic_vector(to_unsigned(ofs, 12));
         qdin  <= std_logic_vector(to_unsigned(d, 16));
         qce <= '1'; qwe <= '1';
         wait until rising_edge(qclk);
         qce <= '0'; qwe <= '0';
      end procedure;

      procedure qr(drv, win, ofs : natural; variable d : out natural) is
      begin
         wait until rising_edge(qclk);
         qdrive <= std_logic_vector(to_unsigned(drv, 2));
         qaddr <= std_logic_vector(to_unsigned(win, 16)) & std_logic_vector(to_unsigned(ofs, 12));
         qce <= '1';
         wait until falling_edge(qclk);
         d := to_integer(unsigned(qdout));
         wait until rising_edge(qclk);
         qce <= '0';
      end procedure;

      procedure req(drv : std_logic; lba : natural; write : std_logic; xorv : natural;
                    expect_err : std_logic; sync : boolean := true) is
      begin
         sp_drive <= drv;
         sreq(mclk, sp_req, sp_write, sp_lba, sp_wr_valid, sp_wr_data,
              sp_rd_valid, sp_wr_ready, sp_done, sp_err, sp_rd_data,
              lba, lba2blk(lba), write, xorv, expect_err, "A:", sync);
      end procedure;

      procedure hd(st : natural) is                   -- run a step of the hard disk process
      begin
         hd_go <= st;
         wait until hd_ack = st;
      end procedure;

      procedure hd_setup(sects : natural) is
      begin
         qw(2, 0, 1, sects mod 65536); qw(2, 0, 2, sects / 65536);
      end procedure;

      variable d : natural;
   begin
      -- drive A: the extent map (window 1), then the registers, mode last
      qw(0, 1, 0, 2);
      qw(0, 1, 1, 10);  qw(0, 1, 2, 0); qw(0, 1, 3, 100); qw(0, 1, 4, 0);
      qw(0, 1, 5, 300); qw(0, 1, 6, 0); qw(0, 1, 7, 80);  qw(0, 1, 8, 0);
      qw(0, 0, 1, 720); qw(0, 0, 2, 0);
      qw(0, 0, 3, 100); qw(0, 0, 4, 0);
      qw(0, 0, 5, 2);
      qw(0, 0, 0, 1);
      -- C: three extents of 64-sector clusters, 41,820 sectors (its own map and registers)
      qw(2, 1, 0, 3);
      qw(2, 1, 1, 1000); qw(2, 1, 2, 0); qw(2, 1, 3, 200); qw(2, 1, 4, 0);
      qw(2, 1, 5, 5000); qw(2, 1, 6, 0); qw(2, 1, 7, 300); qw(2, 1, 8, 0);
      qw(2, 1, 9, 9000); qw(2, 1, 10, 0); qw(2, 1, 11, 154); qw(2, 1, 12, 0);
      assert hd_present = '0' report "C: present before it is set up" severity failure;
      hd_setup(41820);
      qw(2, 0, 3, HD_BASE mod 65536); qw(2, 0, 4, HD_BASE / 65536);
      qw(2, 0, 5, 6);
      qw(2, 0, 0, 1);
      wait for 4 us;
      assert present = "01" and tracks(7 downto 0) = x"28" and heads(1 downto 0) = "10" and
             spt(5 downto 0) = "001001" and wp80 = "00"
         report "geometry of a 360K image" severity failure;
      assert hd_present = '1' report "C: not present" severity failure;
      qr(2, 0, 8, d);
      assert d mod 4 = 2 report "C: STATUS " & integer'image(d) severity failure;
      qr(1, 0, 8, d);
      assert d mod 4 = 0 report "B: STATUS " & integer'image(d) severity failure;
      qr(2, 0, 1, d);
      assert d = 41820 mod 65536 report "C: SECTS readback" severity failure;
      qr(0, 0, 1, d);
      assert d = 720 report "A: SECTS readback" severity failure;

      req('0', 0, '0', 0, '0');                -- first extent
      assert last_block = 140 report "block of LBA 0: " & integer'image(last_block) severity failure;
      req('0', 399, '0', 0, '0');              -- last sector of the first extent
      req('0', 400, '0', 0, '0');              -- second extent
      assert last_block = 1300 report "block of LBA 400: " & integer'image(last_block) severity failure;
      req('0', 719, '0', 0, '0');
      req('0', 720, '0', 0, '1');              -- beyond the file
      req('1', 0, '0', 0, '1');                -- B: is off

      hd(1);                                   -- C: reads
      hd(2);                                   -- C: beyond the file

      req('0', 5, '1', 16#A5#, '0');           -- write, then read it back
      req('0', 5, '0', 16#A5#, '0');
      qwp <= "11";
      wait for 700 ns;
      req('0', 6, '1', 16#5A#, '1');           -- write protected
      hd(3);                                   -- C: is not
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

      -- both ports at once, back to back (each re-asks one clock after its sp_done): they take
      -- turns
      hd_go <= 5;
      wait until rising_edge(mclk);
      log_on <= true;
      go_both <= '1';
      for k in 0 to 3 loop
         req('0', 20 + k, '0', 0, '0', false);
      end loop;
      if hd_ack /= 5 then
         wait until hd_ack = 5;
      end if;
      log_on <= false;
      go_both <= '0';
      wait for 1 ns;
      assert log_n = 8 and (log_str(1 to 8) = "FHFHFHFH" or log_str(1 to 8) = "HFHFHFHF")
         report "both ports: order " & log_str(1 to 8) severity failure;
      -- both ports write at once, then read back
      hd_go <= 6;
      wait until rising_edge(mclk);
      go_both <= '1';
      req('0', 30, '1', 16#11#, '0', false);
      req('0', 31, '1', 16#12#, '0', false);
      req('0', 30, '0', 16#11#, '0', false);
      req('0', 31, '0', 16#12#, '0', false);
      if hd_ack /= 6 then
         wait until hd_ack = 6;
      end if;
      go_both <= '0';
      req('0', 32, '0', 0, '0');                -- the neighbour unchanged

      -- abandoned requests of the hard disk port; the FDC's next request is served
      d := starts;
      hd(7);
      hd(8);
      hd(11);
      req('0', 33, '0', 0, '0');
      assert starts = d + 6 report "abandoned: " & integer'image(starts - d) & " transfers"
         severity failure;

      -- C: with a wrong size: no disk; off: no disk
      hd_setup(41819);
      wait for 4 us;
      assert hd_present = '0' report "C: of 41,819 sectors is a disk" severity failure;
      hd(4);
      hd_setup(41821);
      wait for 4 us;
      assert hd_present = '0' report "C: of 41,821 sectors is a disk" severity failure;
      hd(9);
      hd_setup(41820);
      qw(2, 0, 0, 0);
      wait for 4 us;
      assert hd_present = '0' report "C: off is a disk" severity failure;
      hd(10);
      req('0', 34, '0', 0, '0');                -- A: still there

      qw(0, 0, 1, 1440);                       -- 720K: an 80-track drive
      wait for 4 us;
      assert tracks(7 downto 0) = x"50" and wp80 = "01" report "geometry of a 720K image" severity failure;
      qw(0, 0, 1, 1000);                       -- no known format: no disk
      wait for 4 us;
      assert present = "00" report "odd size must mean no disk" severity failure;

      report "PASS: pc_fdd_sd (" & integer'image(starts) & " engine transfers)";
      done <= true;
      wait;
   end process p_test;
end architecture sim;
