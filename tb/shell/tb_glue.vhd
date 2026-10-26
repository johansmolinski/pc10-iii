-- tb_glue.vhd - checks of the shell's VHDL glue (ghdl, see run.sh):
--   keyboard.vhd: make/break codes, the MEGA + digit Fn layer, the busy handshake
--   pc_bios.vhd:  the window reads the RAM 1:1 (the firmware right-aligns the image), 0xFF
--                 while the gate is closed
--   pc_ram.vhd:   2-clock read latency with ack, the size limit (0xFF above it)
--   pc_font.vhd:  the default font copied into the font port after the reset, a 2 KB font
--                 loaded by QNICE and copied to 0x1800 and 0x1000; a 16 KB Commodore ROM
--                 copied into both 16 KB halves, a 32 KB one 1:1 (font_cbm), the overflow bit
--   pc_ucode.vhd: a 6 KB bundle loaded by QNICE, read back, copied byte for byte into the
--                 CPU's load port on GO; valid only after the copy, cleared by forget
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_glue is
   generic (G_FONT_HEX : string := "../../CORE/font/cga_default.hex");
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

   -- font
   signal mrst      : std_logic := '1';
   signal fqaddr    : std_logic_vector(27 downto 0) := (others => '0');
   signal fqdin     : std_logic_vector(15 downto 0) := (others => '0');
   signal fqdout    : std_logic_vector(15 downto 0);
   signal fqce, fqwe : std_logic := '0';
   signal font_we   : std_logic;
   signal font_addr : std_logic_vector(14 downto 0);
   signal font_cbm  : std_logic;
   signal font_data : std_logic_vector(7 downto 0);
   type t_font is array (0 to 32767) of std_logic_vector(7 downto 0);
   signal font      : t_font := (others => x"EE");
   signal font_wr   : natural := 0;

   -- microcode bundle
   signal uqaddr    : std_logic_vector(27 downto 0) := (others => '0');
   signal uqdin     : std_logic_vector(15 downto 0) := (others => '0');
   signal uqdout    : std_logic_vector(15 downto 0);
   signal uqce, uqwe : std_logic := '0';
   signal uvalid    : std_logic;
   signal ucl_we    : std_logic;
   signal ucl_addr  : std_logic_vector(12 downto 0);
   signal ucl_data  : std_logic_vector(7 downto 0);
   signal ucl_n     : natural := 0;
   signal ucl_bad   : natural := 0;
   signal ucl_wr_valid : natural := 0;          -- writes while valid was high

   type t_codes is array (natural range <>) of std_logic_vector(7 downto 0);
   signal got       : t_codes(0 to 31);
   signal ngot      : natural := 0;
begin
   clk  <= not clk  after 17.46 ns when not done;    -- 28.63636 MHz
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

   i_font : entity work.pc_font
      generic map (G_INIT_FILE => G_FONT_HEX)
      port map (qnice_clk_i => qclk, qnice_rst_i => '0', qnice_addr_i => fqaddr, qnice_data_i => fqdin,
                qnice_data_o => fqdout, qnice_ce_i => fqce, qnice_we_i => fqwe,
                main_clk_i => clk, main_rst_i => mrst,
                font_we_o => font_we, font_addr_o => font_addr, font_data_o => font_data,
                font_cbm_o => font_cbm);

   i_ucode : entity work.pc_ucode
      port map (qnice_clk_i => qclk, qnice_rst_i => '0', qnice_addr_i => uqaddr, qnice_data_i => uqdin,
                qnice_data_o => uqdout, qnice_ce_i => uqce, qnice_we_i => uqwe,
                main_clk_i => clk, main_valid_o => uvalid,
                ucl_we_o => ucl_we, ucl_addr_o => ucl_addr, ucl_data_o => ucl_data);

   -- the CPU's load port: byte n at address n, in order
   p_ucl : process (clk)
   begin
      if rising_edge(clk) then
         if ucl_we = '1' then
            if unsigned(ucl_addr) /= ucl_n mod 8192 or
               ucl_data /= std_logic_vector(to_unsigned((ucl_n mod 6144) * 7 mod 256, 8)) then
               ucl_bad <= ucl_bad + 1;
            end if;
            if uvalid = '1' then ucl_wr_valid <= ucl_wr_valid + 1; end if;
            ucl_n <= ucl_n + 1;
         end if;
      end if;
   end process;

   -- the CGA card's font RAM
   p_font : process (clk)
   begin
      if rising_edge(clk) then
         if font_we = '1' then
            font(to_integer(unsigned(font_addr))) <= font_data;
            font_wr <= font_wr + 1;
         end if;
      end if;
   end process;

   p_test : process
      -- a Commodore test image: byte i
      impure function cimg(i : natural) return std_logic_vector is
      begin
         return std_logic_vector(to_unsigned((i * 13 + i / 4096 + 5) mod 256, 8));
      end function;
      -- write image bytes lo..hi through the font device's windows
      procedure fload(lo, hi : natural) is
      begin
         for i in lo to hi loop
            wait until rising_edge(qclk);
            fqaddr <= std_logic_vector(to_unsigned(i / 4096, 16)) & std_logic_vector(to_unsigned(i mod 4096, 12));
            fqdin  <= x"00" & cimg(i);
            fqce <= '1'; fqwe <= '1';
            wait until rising_edge(qclk);
            fqce <= '0'; fqwe <= '0';
         end loop;
      end procedure;
      procedure fgo is
      begin
         wait until rising_edge(qclk);
         fqaddr <= x"0100" & x"002"; fqce <= '1'; fqwe <= '1';
         wait until rising_edge(qclk);
         fqce <= '0'; fqwe <= '0';
      end procedure;
      procedure freg(ofs : natural; v : std_logic_vector(15 downto 0); what : string) is
      begin
         wait until rising_edge(qclk);
         fqaddr <= x"0100" & std_logic_vector(to_unsigned(ofs, 12)); fqce <= '1';
         wait until rising_edge(qclk);
         assert fqdout = v report what & " " & to_hstring(fqdout) severity failure;
         fqce <= '0';
      end procedure;
      variable n0 : natural;
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
         wait for 7 us;
      end procedure;
      constant exp : t_codes(0 to 19) := (x"1E", x"9E", x"3B", x"BB", x"02", x"82", x"2A", x"AA",
                                          x"4F", x"CF", x"49", x"C9", x"51", x"D1", x"53", x"D3",
                                          x"52", x"D2", x"4A", x"CA");
   begin
      -- keyboard: A, MEGA+1 (F1; MEGA itself sends nothing), 1, left shift
      key(10, '1'); key(10, '0');
      key(61, '1'); key(56, '1'); key(61, '0'); key(56, '0');     -- break of F1 although MEGA is up
      key(56, '1'); key(56, '0');
      key(15, '1'); key(15, '0');
      -- the MEGA layer's keypad keys: CLR/HOME End, up PgUp, down PgDn, INST/DEL Del, pound Ins,
      -- - keypad - (the last one's break after MEGA is up)
      key(61, '1');
      key(51, '1'); key(51, '0'); key(73, '1'); key(73, '0'); key(7, '1'); key(7, '0');
      key(0, '1'); key(0, '0'); key(48, '1'); key(48, '0');
      key(43, '1'); key(61, '0'); key(43, '0');
      wait for 7 us;
      assert ngot = 20 report "got " & integer'image(ngot) & " codes" severity failure;
      for i in exp'range loop
         assert got(i) = exp(i) report "code " & integer'image(i) & ": " & to_hstring(got(i)) severity failure;
      end loop;

      -- BIOS: an 8 KB image where the firmware puts it (E000-FFFF; byte i = i mod 251) and
      -- 0xFF below (two samples), first with the gate closed, then released
      for i in 0 to 8191 loop
         qwrite(16#E000# / 4096 + i / 4096, i mod 4096, i mod 251);
      end loop;
      qwrite(0, 0, 16#FF#);
      qwrite(13, 4095, 16#FF#);
      romchk(16#E000#, x"FF");                -- gate closed
      qwrite(16#0100#, 2, 1);
      wait for 4 us;
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

      -- font: the default after the reset ('A' row 1 = 0x78, thin = 0x78 and not 0x3C = 0x40)
      mrst <= '0';
      wait for 400 us;
      assert font_wr = 8192 report "default font: " & integer'image(font_wr) & " writes" severity failure;
      assert font(16#1800# + 16#41# * 8 + 1) = x"78" and font(16#1000# + 16#41# * 8 + 1) = x"40" and
             font(16#1800# + 16#C1# * 8 + 1) = x"00" and font(0) = x"00"
         report "default font content" severity failure;
      assert font_cbm = '0' report "default font: font_cbm" severity failure;
      -- a 2 KB font from QNICE, then GO
      for i in 0 to 2047 loop
         wait until rising_edge(qclk);
         fqaddr <= x"0000" & std_logic_vector(to_unsigned(i, 12));
         fqdin  <= x"00" & (std_logic_vector(to_unsigned(i mod 256, 8)) xor x"3C");
         fqce <= '1'; fqwe <= '1';
         wait until rising_edge(qclk);
         fqce <= '0'; fqwe <= '0';
      end loop;
      wait until rising_edge(qclk);
      fqaddr <= x"0100" & x"000"; fqce <= '1';
      wait until rising_edge(qclk);
      assert fqdout = x"0800" report "font size " & to_hstring(fqdout) severity failure;
      fqaddr <= x"0100" & x"002"; fqwe <= '1';
      wait until rising_edge(qclk);
      fqce <= '0'; fqwe <= '0';
      wait for 400 us;
      assert font_wr = 8192 + 4096 report "2 KB font: " & integer'image(font_wr - 8192) & " writes" severity failure;
      for i in 0 to 2047 loop
         assert font(16#1800# + i) = (std_logic_vector(to_unsigned(i mod 256, 8)) xor x"3C") and
                font(16#1000# + i) = (std_logic_vector(to_unsigned(i mod 256, 8)) xor x"3C")
            report "2 KB font byte " & integer'image(i) severity failure;
      end loop;
      assert font_cbm = '0' report "2 KB font: font_cbm" severity failure;

      -- a 16 KB Commodore ROM (one national set): both halves, font_cbm
      fload(0, 16383);
      freg(0, x"4000", "16 KB size");
      n0 := font_wr;
      fgo;
      wait for 1500 us;
      assert font_wr - n0 = 32768 report "16 KB ROM: " & integer'image(font_wr - n0) & " writes" severity failure;
      assert font_cbm = '1' report "16 KB ROM: font_cbm" severity failure;
      for i in 0 to 32767 loop
         assert font(i) = cimg(i mod 16384) report "16 KB ROM byte " & integer'image(i) severity failure;
      end loop;
      -- grown to 32 KB: 1:1
      fload(16384, 32767);
      freg(0, x"8000", "32 KB size");
      freg(1, x"0000", "32 KB overflow");
      n0 := font_wr;
      fgo;
      wait for 1500 us;
      assert font_wr - n0 = 32768 report "32 KB ROM: " & integer'image(font_wr - n0) & " writes" severity failure;
      assert font_cbm = '1' report "32 KB ROM: font_cbm" severity failure;
      for i in 0 to 32767 loop
         assert font(i) = cimg(i) report "32 KB ROM byte " & integer'image(i) severity failure;
      end loop;
      -- one byte beyond: the overflow bit
      wait until rising_edge(qclk);
      fqaddr <= x"0008" & x"000"; fqdin <= x"0055"; fqce <= '1'; fqwe <= '1';
      wait until rising_edge(qclk);
      fqce <= '0'; fqwe <= '0';
      freg(1, x"0001", "overflow after 32 KB");
      freg(0, x"8000", "size after the overflow");

      -- microcode bundle: 6144 bytes (byte i = i * 7 mod 256), read back, GO
      for i in 0 to 6143 loop
         wait until rising_edge(qclk);
         uqaddr <= std_logic_vector(to_unsigned(i / 4096, 16)) & std_logic_vector(to_unsigned(i mod 4096, 12));
         uqdin  <= x"00" & std_logic_vector(to_unsigned(i * 7 mod 256, 8));
         uqce <= '1'; uqwe <= '1';
         wait until rising_edge(qclk);
         uqce <= '0'; uqwe <= '0';
      end loop;
      wait until rising_edge(qclk);
      uqaddr <= x"0001" & x"7FF"; uqce <= '1';
      wait until rising_edge(qclk);
      assert uqdout = x"00" & std_logic_vector(to_unsigned(6143 * 7 mod 256, 8)) report "bundle readback" severity failure;
      uqaddr <= x"0100" & x"000";
      wait until rising_edge(qclk);
      assert uqdout = x"1800" report "bundle size " & to_hstring(uqdout) severity failure;
      uqce <= '0';
      wait for 7 us;
      assert uvalid = '0' and ucl_n = 0 report "bundle valid or copied before GO" severity failure;
      wait until rising_edge(qclk);
      uqaddr <= x"0100" & x"002"; uqce <= '1'; uqwe <= '1';
      wait until rising_edge(qclk);
      uqce <= '0'; uqwe <= '0';
      wait for 400 us;
      assert ucl_n = 6144 and ucl_bad = 0 and ucl_wr_valid = 0
         report "bundle copy: " & integer'image(ucl_n) & " writes, " & integer'image(ucl_bad) & " wrong, " &
                integer'image(ucl_wr_valid) & " while valid" severity failure;
      assert uvalid = '1' report "bundle not valid after the copy" severity failure;
      wait until rising_edge(qclk);
      uqaddr <= x"0100" & x"004"; uqce <= '1'; uqwe <= '1';
      wait until rising_edge(qclk);
      uqce <= '0'; uqwe <= '0';
      wait for 7 us;
      assert uvalid = '0' report "bundle still valid after forget" severity failure;

      report "PASS: keyboard, BIOS alignment, RAM latency and size, character ROM (IBM 2 KB, Commodore 16 and 32 KB), microcode bundle";
      done <= true;
      wait;
   end process;
end architecture sim;
