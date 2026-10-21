----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- CGA character ROM loader: an 8 KB image in block RAM, copied into pc_system's font port.
--
-- The image BRAM is preloaded with a free default font (CORE/font/cga_default.hex: the 8x8
-- glyphs of GLaBIOS, VileR's font, CC BY-SA 4.0 - see CORE/font/README.md), in the layout of
-- IBM's 5788005 ROM: the 8x8 font at 0x1800, a thin copy at 0x1000. The cga_card's own font
-- RAM has no initial contents, so:
--   * after the main reset (power-up, MMCM lock) the image is copied into the font port once;
--   * QNICE may overwrite the image (the Shell's optional auto-load of /pc10/cga.rom) and then
--     asks for another copy (control register GO).
--
-- QNICE device C_DEV_PC_FONT (globals.vhd), qnice_clk domain:
--   windows 0x0000, 0x0001   the image, byte i of the file at window i/4096, offset i mod 4096
--   window  0x0100           control registers:
--     offset 0 (R)   size: one more than the highest image byte written (0 = nothing loaded)
--     offset 1 (R)   bit 0: a write went outside the 8 KB (the file is too large)
--     offset 2 (W)   any write: copy the image into the font port now
-- A 2 KB file (an 8x8-only dump) is copied to 0x1800 and, as the thin font, to 0x1000; any
-- other size copies the whole 8 KB (bytes the file did not cover keep the default).
--
-- Copy: one byte per main clock (8192 clocks, 82 us); cga_card takes font_we at any time.
--
-- done by Johan Smolinski in 2026 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pc_font is
   generic (
      G_INIT_FILE     : string := "../../../CORE/font/cga_default.hex"
   );
   port (
      -- QNICE clock domain
      qnice_clk_i     : in  std_logic;
      qnice_rst_i     : in  std_logic;
      qnice_addr_i    : in  std_logic_vector(27 downto 0);
      qnice_data_i    : in  std_logic_vector(15 downto 0);
      qnice_data_o    : out std_logic_vector(15 downto 0);
      qnice_ce_i      : in  std_logic;
      qnice_we_i      : in  std_logic;

      -- main clock domain
      main_clk_i      : in  std_logic;
      main_rst_i      : in  std_logic;
      font_we_o       : out std_logic;
      font_addr_o     : out std_logic_vector(12 downto 0);
      font_data_o     : out std_logic_vector(7 downto 0)
   );
end entity pc_font;

architecture synthesis of pc_font is

   constant C_WIN_CTRL    : std_logic_vector(15 downto 0) := x"0100";

   signal qnice_win       : std_logic_vector(15 downto 0);
   signal qnice_img       : std_logic;
   signal qnice_ctrl      : std_logic;
   signal qnice_ram_addr  : std_logic_vector(12 downto 0);
   signal qnice_ram_we    : std_logic;
   signal qnice_ram_q     : std_logic_vector(7 downto 0);
   signal qnice_size      : unsigned(13 downto 0) := (others => '0');
   signal qnice_ovfl      : std_logic := '0';
   signal qnice_go        : std_logic := '0';            -- toggles on every GO

   signal main_ctl        : std_logic_vector(14 downto 0);
   signal main_go_d       : std_logic := '0';
   signal main_small      : std_logic;                    -- a 2 KB image

   type t_cstate is (C_IDLE, C_COPY);
   signal cstate          : t_cstate := C_IDLE;
   signal start_pending   : std_logic := '1';             -- copy once after the reset
   signal cnt             : unsigned(13 downto 0) := (others => '0');   -- 0..8191 (+ 2 KB pass)
   signal rd_addr         : std_logic_vector(12 downto 0);
   signal rd_q            : std_logic_vector(7 downto 0);
   signal wr_valid        : std_logic := '0';
   signal wr_addr         : std_logic_vector(12 downto 0) := (others => '0');

begin

   ---------------------------------------------------------------------------------------------
   -- QNICE side
   ---------------------------------------------------------------------------------------------

   qnice_win      <= qnice_addr_i(27 downto 12);
   qnice_img      <= '1' when qnice_win(15 downto 1) = "000000000000000" else '0';
   qnice_ctrl     <= '1' when qnice_win = C_WIN_CTRL else '0';
   qnice_ram_addr <= qnice_win(0) & qnice_addr_i(11 downto 0);
   qnice_ram_we   <= qnice_ce_i and qnice_we_i and qnice_img;

   p_regs : process (qnice_clk_i)
      variable v_end : unsigned(13 downto 0);
   begin
      if falling_edge(qnice_clk_i) then
         if qnice_ce_i = '1' and qnice_we_i = '1' then
            if qnice_img = '1' then
               v_end := resize(unsigned(qnice_ram_addr), 14) + 1;
               if v_end > qnice_size then
                  qnice_size <= v_end;
               end if;
            elsif qnice_ctrl = '1' then
               if qnice_addr_i(11 downto 0) = x"002" then
                  qnice_go <= not qnice_go;
               end if;
            elsif qnice_win /= x"FFFF" then
               qnice_ovfl <= '1';
            end if;
         end if;
         if qnice_rst_i = '1' then
            qnice_size <= (others => '0');
            qnice_ovfl <= '0';
         end if;
      end if;
   end process p_regs;

   p_read : process (all)
   begin
      qnice_data_o <= x"EEEE";
      if qnice_img = '1' then
         qnice_data_o <= x"00" & qnice_ram_q;
      elsif qnice_ctrl = '1' then
         case qnice_addr_i(11 downto 0) is
            when x"000" => qnice_data_o <= "00" & std_logic_vector(qnice_size);
            when x"001" => qnice_data_o <= x"000" & "000" & qnice_ovfl;
            when others => qnice_data_o <= x"0000";
         end case;
      end if;
   end process p_read;

   i_img : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH        => 13,
         DATA_WIDTH        => 8,
         ROM_PRELOAD       => true,
         ROM_FILE          => G_INIT_FILE,
         ROM_FILE_HEX      => true,
         RAM_STYLE_SELECT  => "block",
         FALLING_A         => true
      )
      port map (
         clock_a           => qnice_clk_i,
         address_a         => qnice_ram_addr,
         data_a            => qnice_data_i(7 downto 0),
         wren_a            => qnice_ram_we,
         q_a               => qnice_ram_q,

         clock_b           => main_clk_i,
         address_b         => rd_addr,
         data_b            => (others => '0'),
         wren_b            => '0',
         q_b               => rd_q
      ); -- i_img

   i_cdc : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 15,
         G_REGISTER_SRC => false
      )
      port map (
         src_clk_i                => qnice_clk_i,
         src_data_i(13 downto 0)  => std_logic_vector(qnice_size),
         src_data_i(14)           => qnice_go,
         dst_clk_i                => main_clk_i,
         dst_data_o               => main_ctl
      ); -- i_cdc

   main_small <= '1' when unsigned(main_ctl(13 downto 0)) = 2048 else '0';

   ---------------------------------------------------------------------------------------------
   -- Copy engine (main clock): read the image at cnt, write the font one clock later.
   -- Full copy: cnt = 0..8191 -> font address = cnt. 2 KB image: cnt = 0..4095 reads image
   -- byte cnt mod 2048 and writes 0x1800 + (cnt mod 2048) in the first pass, 0x1000 + ... in
   -- the second.
   ---------------------------------------------------------------------------------------------

   rd_addr <= "00" & std_logic_vector(cnt(10 downto 0)) when main_small = '1' else
              std_logic_vector(cnt(12 downto 0));

   p_copy : process (main_clk_i)
   begin
      if rising_edge(main_clk_i) then
         wr_valid <= '0';
         main_go_d <= main_ctl(14);
         if main_ctl(14) /= main_go_d then
            start_pending <= '1';
         end if;

         case cstate is
            when C_IDLE =>
               if start_pending = '1' then
                  start_pending <= '0';
                  cnt           <= (others => '0');
                  cstate        <= C_COPY;
               end if;

            when C_COPY =>
               wr_valid <= '1';
               if main_small = '1' then
                  wr_addr <= "11" & std_logic_vector(cnt(10 downto 0));
                  if cnt(11) = '1' then
                     wr_addr <= "10" & std_logic_vector(cnt(10 downto 0));
                  end if;
                  if cnt = 4095 then
                     cstate <= C_IDLE;
                  end if;
               else
                  wr_addr <= std_logic_vector(cnt(12 downto 0));
                  if cnt = 8191 then
                     cstate <= C_IDLE;
                  end if;
               end if;
               cnt <= cnt + 1;
         end case;

         if main_rst_i = '1' then
            cstate        <= C_IDLE;
            start_pending <= '1';
            wr_valid      <= '0';
         end if;
      end if;
   end process p_copy;

   -- the BRAM data of the address set in the previous clock arrives together with wr_addr
   font_we_o   <= wr_valid;
   font_addr_o <= wr_addr;
   font_data_o <= rd_q;

end architecture synthesis;
