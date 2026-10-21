----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- BIOS ROM: 64 KB of block RAM (16 RAMB36) for the window F0000-FFFFF, filled by QNICE.
--
-- QNICE device C_DEV_PC_BIOS (globals.vhd), qnice_clk domain:
--   windows 0x0000..0x000F  the image, byte i of the file at window i/4096, offset i mod 4096
--                           (the Shell's ROM auto-loader writes the file from offset 0)
--   window  0x0100          control registers:
--     offset 0 (R)   size bits 15..0: one more than the highest image byte written
--     offset 1 (R)   size bit 16 (a 64 KB image has size 0x10000)
--     offset 2 (R/W) bit 0: BIOS valid - releases the PC from reset (the firmware sets it in
--                    PREP_START after checking the size)
--     offset 3 (R)   bit 0: a write went to a window outside 0..15 (the file is > 64 KB)
--     offset 4 (W)   any write: forget the image (size, overflow and valid back to 0)
--
-- PC side (main clock domain): rom_addr_i is the offset in F0000-FFFFF. An image of N bytes
-- is right-aligned, i.e. it ends at FFFFF like a real ROM in the top socket: rom_addr maps to
-- image byte rom_addr - (65536 - N) = (rom_addr + N) mod 65536, and below the image (the
-- carry of that sum is 0) the window reads 0xFF like an empty socket. 1 clock read latency.
-- The size crosses into the main clock domain through cdc_stable; it only changes while the
-- PC is held in reset (valid = 0).
--
-- done by Johan Smolinski in 2026 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pc_bios is
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
      main_valid_o    : out std_logic;
      rom_addr_i      : in  std_logic_vector(15 downto 0);
      rom_rdata_o     : out std_logic_vector(7 downto 0)
   );
end entity pc_bios;

architecture synthesis of pc_bios is

   constant C_WIN_CTRL    : std_logic_vector(15 downto 0) := x"0100";

   signal qnice_win       : std_logic_vector(15 downto 0);
   signal qnice_img       : std_logic;
   signal qnice_ctrl      : std_logic;
   signal qnice_ram_we    : std_logic;
   signal qnice_ram_addr  : std_logic_vector(15 downto 0);
   signal qnice_ram_q     : std_logic_vector(7 downto 0);

   signal qnice_size      : unsigned(16 downto 0) := (others => '0');
   signal qnice_valid     : std_logic := '0';
   signal qnice_ovfl      : std_logic := '0';

   signal main_ctl        : std_logic_vector(17 downto 0);
   signal main_size       : unsigned(16 downto 0);
   signal main_valid      : std_logic;

   signal main_sum        : unsigned(16 downto 0);
   signal main_ram_q      : std_logic_vector(7 downto 0);
   signal main_in_img     : std_logic := '0';

begin

   ---------------------------------------------------------------------------------------------
   -- QNICE side
   ---------------------------------------------------------------------------------------------

   qnice_win      <= qnice_addr_i(27 downto 12);
   qnice_img      <= '1' when qnice_win(15 downto 4) = x"000" else '0';
   qnice_ctrl     <= '1' when qnice_win = C_WIN_CTRL else '0';
   qnice_ram_addr <= qnice_win(3 downto 0) & qnice_addr_i(11 downto 0);
   qnice_ram_we   <= qnice_ce_i and qnice_we_i and qnice_img;

   -- QNICE writes on the falling edge (like the RAM's port A and every M2M device)
   p_regs : process (qnice_clk_i)
      variable v_end : unsigned(16 downto 0);
   begin
      if falling_edge(qnice_clk_i) then
         if qnice_ce_i = '1' and qnice_we_i = '1' then
            if qnice_img = '1' then
               v_end := resize(unsigned(qnice_ram_addr), 17) + 1;
               if v_end > qnice_size then
                  qnice_size <= v_end;
               end if;
            elsif qnice_ctrl = '1' then
               case qnice_addr_i(11 downto 0) is
                  when x"002" => qnice_valid <= qnice_data_i(0);
                  when x"004" =>
                     qnice_size  <= (others => '0');
                     qnice_valid <= '0';
                     qnice_ovfl  <= '0';
                  when others => null;
               end case;
            elsif qnice_win /= x"FFFF" then
               qnice_ovfl <= '1';
            end if;
         end if;
         if qnice_rst_i = '1' then
            qnice_size  <= (others => '0');
            qnice_valid <= '0';
            qnice_ovfl  <= '0';
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
            when x"000" => qnice_data_o <= std_logic_vector(qnice_size(15 downto 0));
            when x"001" => qnice_data_o <= x"000" & "000" & qnice_size(16);
            when x"002" => qnice_data_o <= x"000" & "000" & qnice_valid;
            when x"003" => qnice_data_o <= x"000" & "000" & qnice_ovfl;
            when others => qnice_data_o <= x"0000";
         end case;
      end if;
   end process p_read;

   ---------------------------------------------------------------------------------------------
   -- The 64 KB image: port A = QNICE (falling edge), port B = the PC (main clock)
   ---------------------------------------------------------------------------------------------

   main_sum <= resize(unsigned(rom_addr_i), 17) + main_size;

   i_rom : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH        => 16,
         DATA_WIDTH        => 8,
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
         address_b         => std_logic_vector(main_sum(15 downto 0)),
         data_b            => (others => '0'),
         wren_b            => '0',
         q_b               => main_ram_q
      ); -- i_rom

   p_main : process (main_clk_i)
   begin
      if rising_edge(main_clk_i) then
         main_in_img <= main_sum(16) and main_valid;
      end if;
   end process p_main;

   rom_rdata_o  <= main_ram_q when main_in_img = '1' else x"FF";

   ---------------------------------------------------------------------------------------------
   -- Clock domain crossing: size and valid are static while the PC runs
   ---------------------------------------------------------------------------------------------

   i_cdc : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 18,
         G_REGISTER_SRC => false
      )
      port map (
         src_clk_i                => qnice_clk_i,
         src_data_i(16 downto 0)  => std_logic_vector(qnice_size),
         src_data_i(17)           => qnice_valid,
         dst_clk_i                => main_clk_i,
         dst_data_o               => main_ctl
      ); -- i_cdc

   main_size    <= unsigned(main_ctl(16 downto 0));
   main_valid   <= main_ctl(17);
   main_valid_o <= main_valid;

end architecture synthesis;
