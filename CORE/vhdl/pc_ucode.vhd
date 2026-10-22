----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- The 8088's microcode bundle (tools/mkucode.py, doc/z8086.md): an 8 KB block RAM image that
-- the Shell's ROM auto-loader fills from /pc10/ucode.bin, copied into the CPU's tables
-- (pc_system's ucl_* port) when the firmware has checked it. Intel's tables are never part of
-- the bitstream (AGENTS.md rule 4): this RAM and the CPU's tables start empty, and the PC
-- stays in reset until a valid bundle has been copied.
--
-- QNICE device C_DEV_PC_UCODE (globals.vhd), qnice_clk domain:
--   windows 0x0000, 0x0001   the image, byte i of the file at window i/4096, offset i mod 4096
--                            (read back by the firmware for its checks)
--   window  0x0100           control registers:
--     offset 0 (R)   size: one more than the highest image byte written (0 = nothing loaded)
--     offset 1 (R)   bit 0: a write went outside the 8 KB (the file is too large)
--     offset 2 (W)   any write: copy the image into the CPU and release the PC (GO)
--              (R)   bit 0: GO was written
--     offset 4 (W)   any write: forget (size, overflow and GO back to 0; the PC is held)
--
-- Main clock side: on GO the image is copied into the CPU, one byte per clock (6144 clocks,
-- 61 us; the copy needs the PC in reset, which main_valid_o = '0' guarantees); then
-- main_valid_o goes high and stays high until a forget. The CPU's tables keep their contents
-- over PC resets.
--
-- done by Johan Smolinski in 2026 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pc_ucode is
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
      main_valid_o    : out std_logic;          -- the CPU's tables are loaded
      ucl_we_o        : out std_logic;
      ucl_addr_o      : out std_logic_vector(12 downto 0);
      ucl_data_o      : out std_logic_vector(7 downto 0)
   );
end entity pc_ucode;

architecture synthesis of pc_ucode is

   constant C_WIN_CTRL    : std_logic_vector(15 downto 0) := x"0100";
   constant C_SIZE        : natural := 6144;      -- the bundle (tools/mkucode.py, version 1)

   signal qnice_win       : std_logic_vector(15 downto 0);
   signal qnice_img       : std_logic;
   signal qnice_ctrl      : std_logic;
   signal qnice_ram_addr  : std_logic_vector(12 downto 0);
   signal qnice_ram_we    : std_logic;
   signal qnice_ram_q     : std_logic_vector(7 downto 0);
   signal qnice_size      : unsigned(13 downto 0) := (others => '0');
   signal qnice_ovfl      : std_logic := '0';
   signal qnice_go        : std_logic := '0';     -- GO written, not forgotten
   signal qnice_gen       : std_logic := '0';     -- toggles on every GO

   signal main_ctl        : std_logic_vector(1 downto 0);
   signal main_gen_d      : std_logic := '0';

   type t_cstate is (C_IDLE, C_COPY);
   signal cstate          : t_cstate := C_IDLE;
   signal cnt             : unsigned(12 downto 0) := (others => '0');
   signal rd_q            : std_logic_vector(7 downto 0);
   signal wr_valid        : std_logic := '0';
   signal wr_addr         : std_logic_vector(12 downto 0) := (others => '0');
   signal main_done       : std_logic := '0';

begin

   ---------------------------------------------------------------------------------------------
   -- QNICE side
   ---------------------------------------------------------------------------------------------

   qnice_win      <= qnice_addr_i(27 downto 12);
   qnice_img      <= '1' when qnice_win(15 downto 1) = "000000000000000" else '0';
   qnice_ctrl     <= '1' when qnice_win = C_WIN_CTRL else '0';
   qnice_ram_addr <= qnice_win(0) & qnice_addr_i(11 downto 0);
   qnice_ram_we   <= qnice_ce_i and qnice_we_i and qnice_img;

   -- QNICE writes on the falling edge (like the RAM's port A and every M2M device)
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
               case qnice_addr_i(11 downto 0) is
                  when x"002" =>
                     qnice_go  <= '1';
                     qnice_gen <= not qnice_gen;
                  when x"004" =>
                     qnice_size <= (others => '0');
                     qnice_ovfl <= '0';
                     qnice_go   <= '0';
                  when others => null;
               end case;
            elsif qnice_win /= x"FFFF" then
               qnice_ovfl <= '1';
            end if;
         end if;
         if qnice_rst_i = '1' then
            qnice_size <= (others => '0');
            qnice_ovfl <= '0';
            qnice_go   <= '0';
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
            when x"002" => qnice_data_o <= x"000" & "000" & qnice_go;
            when others => qnice_data_o <= x"0000";
         end case;
      end if;
   end process p_read;

   -- the image: empty at configuration (no Intel table in the bitstream)
   i_img : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH        => 13,
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
         address_b         => std_logic_vector(cnt),
         data_b            => (others => '0'),
         wren_b            => '0',
         q_b               => rd_q
      ); -- i_img

   -- GO and its generation are static while the copy runs (the firmware writes GO once)
   i_cdc : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 2,
         G_REGISTER_SRC => false
      )
      port map (
         src_clk_i      => qnice_clk_i,
         src_data_i(0)  => qnice_go,
         src_data_i(1)  => qnice_gen,
         dst_clk_i      => main_clk_i,
         dst_data_o     => main_ctl
      ); -- i_cdc

   ---------------------------------------------------------------------------------------------
   -- Copy engine (main clock): read the image at cnt, write the CPU's table one clock later
   ---------------------------------------------------------------------------------------------

   p_copy : process (main_clk_i)
   begin
      if rising_edge(main_clk_i) then
         wr_valid   <= '0';
         main_gen_d <= main_ctl(1);

         case cstate is
            when C_IDLE =>
               if main_ctl(1) /= main_gen_d and main_ctl(0) = '1' then
                  main_done <= '0';
                  cnt       <= (others => '0');
                  cstate    <= C_COPY;
               end if;

            when C_COPY =>
               wr_valid <= '1';
               wr_addr  <= std_logic_vector(cnt);
               cnt      <= cnt + 1;
               if cnt = C_SIZE - 1 then
                  cstate <= C_IDLE;
               end if;
         end case;

         -- the last byte goes out with wr_valid in the clock after C_COPY ends
         if cstate = C_IDLE and wr_valid = '1' then
            main_done <= '1';
         end if;
         if main_ctl(0) = '0' then
            main_done <= '0';
         end if;
      end if;
   end process p_copy;

   ucl_we_o     <= wr_valid;
   ucl_addr_o   <= wr_addr;
   ucl_data_o   <= rd_q;
   main_valid_o <= main_done and main_ctl(0);

end architecture synthesis;
