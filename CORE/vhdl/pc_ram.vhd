----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- System RAM: 640 KB of byte-wide block RAM behind pc_system's abstract memory port
-- (doc/architecture.md section 4).
--
-- * 20 banks of 32 KB at 00000-9FFFF (8 RAMB36 each, 160 in all). NO QNICE port
--   (Megamiga hard rule 4: QNICE accesses on the falling
--   clock edge, a half-period path into 160 spread tiles does not close).
-- * Latency 2: the request is registered as it comes (next to pc_system), the banks read
--   it into the block RAMs' registers, and a multiplexer picks the bank: read data and
--   ram_ack_o are valid 2 clocks after ram_en_i. At 28.63636 MHz (doc/clock-plan.md) a
--   clock is 34.9 ns; the 6-clock pipeline that spread the request over the 160 tiles at
--   100 MHz (doc/timing.md) is not needed. pc_system waits for ram_ack_o (architecture.md
--   section 4); the board takes the data well before the CPU samples it at the end of T3.
-- * size_i limits the RAM seen by the PC at run time (OSM "Memory"): 00 = 640 KB,
--   01 = 512 KB, 10 = 256 KB, 11 = 128 KB. Above the limit reads return 0xFF (open
--   bus) and writes are dropped; both are acknowledged.
--
-- done by Johan Smolinski in 2026 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pc_ram is
   port (
      clk_i       : in  std_logic;
      size_i      : in  std_logic_vector(1 downto 0);
      ram_addr_i  : in  std_logic_vector(19 downto 0);
      ram_en_i    : in  std_logic;
      ram_we_i    : in  std_logic;
      ram_wdata_i : in  std_logic_vector(7 downto 0);
      ram_rdata_o : out std_logic_vector(7 downto 0);
      ram_ack_o   : out std_logic
   );
end entity pc_ram;

architecture synthesis of pc_ram is

   constant C_BANKS  : natural := 20;                 -- 20 x 32 KB = 640 KB

   type t_bank   is array (0 to 2**15 - 1) of std_logic_vector(7 downto 0);
   type t_data   is array (natural range <>) of std_logic_vector(7 downto 0);

   -- stage 0: the request as it comes
   signal r_addr   : std_logic_vector(19 downto 0) := (others => '0');
   signal r_wdata  : std_logic_vector(7 downto 0) := (others => '0');
   signal r_en     : std_logic := '0';
   signal r_we     : std_logic := '0';
   signal r_inr    : std_logic := '0';

   -- stage 1: the banks' registers
   signal b_q      : t_data(0 to C_BANKS - 1);
   signal bank_q   : natural range 0 to 31 := 0;
   signal inr_q    : std_logic := '0';
   signal ack_q    : std_logic := '0';

   signal limit    : unsigned(19 downto 0);

begin

   with size_i select limit <=
      to_unsigned(16#A0000#, 20) when "00",
      to_unsigned(16#80000#, 20) when "01",
      to_unsigned(16#40000#, 20) when "10",
      to_unsigned(16#20000#, 20) when others;

   p_in : process (clk_i)
   begin
      if rising_edge(clk_i) then
         r_addr  <= ram_addr_i;
         r_wdata <= ram_wdata_i;
         r_en    <= ram_en_i;
         r_we    <= ram_we_i;
         if unsigned(ram_addr_i) < limit then
            r_inr <= '1';
         else
            r_inr <= '0';
         end if;
      end if;
   end process p_in;

   g_bank : for k in 0 to C_BANKS - 1 generate
      signal mem : t_bank;
      attribute ram_style : string;
      attribute ram_style of mem : signal is "block";
   begin
      p_bank : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if r_en = '1' and r_we = '1' and r_inr = '1' and to_integer(unsigned(r_addr(19 downto 15))) = k then
               mem(to_integer(unsigned(r_addr(14 downto 0)))) <= r_wdata;
            end if;
            b_q(k) <= mem(to_integer(unsigned(r_addr(14 downto 0))));
         end if;
      end process p_bank;
   end generate g_bank;

   p_out : process (clk_i)
   begin
      if rising_edge(clk_i) then
         bank_q <= to_integer(unsigned(r_addr(19 downto 15)));
         inr_q  <= r_inr;
         ack_q  <= r_en;
      end if;
   end process p_out;

   ram_rdata_o <= x"FF" when inr_q = '0' or bank_q >= C_BANKS else b_q(bank_q);
   ram_ack_o   <= ack_q;

end architecture synthesis;
