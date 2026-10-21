-- tb_glue.vhd - checks of the shell's VHDL glue (ghdl, see run.sh):
--   keyboard.vhd: make/break codes, the MEGA + digit Fn layer, the busy handshake
--   pc_bios.vhd:  the right-aligned image (8 KB file -> FE000-FFFFF, 0xFF below), the gate
--   pc_ram.vhd:   2-clock read latency with ack, the size limit (0xFF above it)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_glue is
end entity tb_glue;

architecture sim of tb_glue is
   signal clk       : std_logic := '0';
   signal qclk      : std_logic := '0';
   signal done      : boolean := false;

   -- keyboard
   signal key_num   : integer range 0 to 79 := 0;
   signal key_n     : std_logic := '1';
   signal pressed   : std_logic_vector(79 downto 0) := (others => '0');
   signal kcode     : std_logic_vector(7 downto 0);
   signal kvalid    : std_logic;
   signal kbusy     : std_logic := '0';

   -- bios
   signal qaddr     : std_logic_vector(27 downto 0) := (others => '0');
   signal qdin      : std_logic_vector(15 downto 0) := (others => '0');
   signal qdout     : std_logic_vector(15 downto 0);
   signal qce, qwe  : std_logic := '0';
   signal bvalid    : std_logic;
   signal raddr     : std_logic_vector(15 downto 0) := (others => '0');
   signal rdata     : std_logic_vector(7 downto 0);

   -- ram
   signal msize     : std_logic_vector(1 downto 0) := "00";
   signal maddr     : std_logic_vector(19 downto 0) := (others => '0');
   signal men, mwe  : std_logic := '0';
   signal mwd       : std_logic_vector(7 downto 0) := (others => '0');
   signal mrd       : std_logic_vector(7 downto 0);
   signal mack      : std_logic;

   type t_codes is array (natural range <>) of std_logic_vector(7 downto 0);
   signal got       : t_codes(0 to 31);
   signal ngot      : natural := 0;
begin
   clk  <= not clk  after 5 ns  when not done;
   qclk <= not qclk after 10 ns when not done;

   -- the framework's scan: one key per 4 clocks
   p_scan : process (clk)
   begin
      if rising_edge(clk) then
         if key_num = 79 then key_num <= 0; else key_num <= key_num + 1; end if;
      end if;
   end process;
   key_n <= not pressed(key_num);

   i_kbd : entity work.keyboard
      port map (clk_main_i => clk, reset_i => '0', key_num_i => key_num, key_pressed_n_i => key_n,
                kbd_code_o => kcode, kbd_valid_o => kvalid, kbd_busy_i => kbusy);

   -- a board that is busy for 20 clocks after each code
   p_board : process (clk)
      variable busy_cnt : natural := 0;
   begin
      if rising_edge(clk) then
         if busy_cnt /= 0 then busy_cnt := busy_cnt - 1; end if;
         if kvalid = '1' then
            assert busy_cnt = 0 report "kbd_valid while busy" severity failure;
            got(ngot) <= kcode;
            ngot <= ngot + 1;
            busy_cnt := 20;
         end if;
         if busy_cnt /= 0 then kbusy <= '1'; else kbusy <= '0'; end if;
      end if;
   end process;

   i_bios : entity work.pc_bios
      port map (qnice_clk_i => qclk, qnice_rst_i => '0', qnice_addr_i => qaddr, qnice_data_i => qdin,
                qnice_data_o => qdout, qnice_ce_i => qce, qnice_we_i => qwe,
                main_clk_i => clk, main_valid_o => bvalid, rom_addr_i => raddr, rom_rdata_o => rdata);

   i_ram : entity work.pc_ram
      port map (clk_i => clk, size_i => msize, ram_addr_i => maddr, ram_en_i => men, ram_we_i => mwe,
                ram_wdata_i => mwd, ram_rdata_o => mrd, ram_ack_o => mack);

   p_test : process
      procedure qwrite(win : natural; ofs : natural; d : natural) is
      begin
         wait until rising_edge(qclk);
         qaddr <= std_logic_vector(to_unsigned(win, 16)) & std_logic_vector(to_unsigned(ofs, 12));
         qdin  <= std_logic_vector(to_unsigned(d, 16));
         qce <= '1'; qwe <= '1';
         wait until rising_edge(qclk);
         qce <= '0'; qwe <= '0';
      end procedure;
      procedure romchk(a : natural; d : std_logic_vector(7 downto 0)) is
      begin
         wait until rising_edge(clk);
         raddr <= std_logic_vector(to_unsigned(a, 16));
         wait until rising_edge(clk);
         wait until rising_edge(clk);
         assert rdata = d report "ROM " & to_hstring(to_unsigned(a, 16)) & ": " & to_hstring(rdata)
                                 & " expected " & to_hstring(d) severity failure;
      end procedure;
      procedure ramwr(a : natural; d : natural) is
      begin
         wait until rising_edge(clk);
         maddr <= std_logic_vector(to_unsigned(a, 20)); mwd <= std_logic_vector(to_unsigned(d, 8));
         men <= '1'; mwe <= '1';
         wait until rising_edge(clk);
         men <= '0';
         wait until rising_edge(clk) and mack = '1';
      end procedure;
      procedure ramrd(a : natural; d : std_logic_vector(7 downto 0)) is
         variable n : natural := 0;
      begin
         wait until rising_edge(clk);
         maddr <= std_logic_vector(to_unsigned(a, 20));
         men <= '1'; mwe <= '0';
         wait until rising_edge(clk);
         men <= '0';
         loop
            wait until rising_edge(clk);
            n := n + 1;
            exit when mack = '1';
         end loop;
         assert n = 2 report "RAM ack after " & integer'image(n) & " TB waits (expected 2: ack 2 clocks after ram_en)" severity failure;
         assert mrd = d report "RAM " & to_hstring(to_unsigned(a, 20)) & ": " & to_hstring(mrd)
                                & " expected " & to_hstring(d) severity failure;
      end procedure;
      procedure key(k : natural; p : std_logic) is
      begin
         pressed(k) <= p;
         wait for 2 us;
      end procedure;
      constant exp : t_codes(0 to 7) := (x"1E", x"9E", x"3B", x"BB", x"02", x"82", x"2A", x"AA");
   begin
      -- keyboard: A, MEGA+1 (F1; MEGA itself sends nothing), 1, left shift
      key(10, '1'); key(10, '0');
      key(61, '1'); key(56, '1'); key(61, '0'); key(56, '0');     -- break of F1 although MEGA is up
      key(56, '1'); key(56, '0');
      key(15, '1'); key(15, '0');
      wait for 2 us;
      assert ngot = 8 report "got " & integer'image(ngot) & " codes" severity failure;
      for i in exp'range loop
         assert got(i) = exp(i) report "code " & integer'image(i) & ": " & to_hstring(got(i)) severity failure;
      end loop;

      -- BIOS: an 8 KB image, byte i = i mod 251, then released
      for i in 0 to 8191 loop
         qwrite(i / 4096, i mod 4096, i mod 251);
      end loop;
      qwrite(16#0100#, 2, 1);
      wait for 1 us;
      assert bvalid = '1' report "BIOS not valid" severity failure;
      romchk(16#0000#, x"FF");
      romchk(16#DFFF#, x"FF");
      romchk(16#E000#, x"00");
      romchk(16#E001#, x"01");
      romchk(16#FFFF#, std_logic_vector(to_unsigned(8191 mod 251, 8)));
      romchk(16#FFF0#, std_logic_vector(to_unsigned(8176 mod 251, 8)));

      -- RAM: 640 KB, then 512 KB
      ramwr(16#00000#, 16#11#);
      ramwr(16#7FFFF#, 16#22#);
      ramwr(16#80000#, 16#33#);
      ramwr(16#9FFFF#, 16#44#);
      ramrd(16#00000#, x"11");
      ramrd(16#7FFFF#, x"22");
      ramrd(16#80000#, x"33");
      ramrd(16#9FFFF#, x"44");
      ramrd(16#A0000#, x"FF");
      msize <= "01";
      ramrd(16#80000#, x"FF");
      ramrd(16#7FFFF#, x"22");

      report "PASS: keyboard, BIOS alignment, RAM latency and size";
      done <= true;
      wait;
   end process;
end architecture sim;
