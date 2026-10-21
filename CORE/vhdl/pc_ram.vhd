----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- System RAM: 640 KB of byte-wide block RAM behind pc_system's abstract memory port
-- (doc/architecture.md section 4).
--
-- * 512 KB at 00000-7FFFF plus 128 KB at 80000-9FFFF: two inferred arrays, 160 RAMB36
--   tiles in all. NO QNICE port (Megamiga hard rule 4: QNICE accesses on the falling
--   clock edge, a half-period path into 160 spread tiles does not close).
-- * Latency: the request is registered first (address fan-out to 160 tiles from a
--   register), then the block RAM reads; read data and ram_ack_o are valid 2 clocks
--   after ram_en_i. pc_system waits for ram_ack_o (the contract allows a later answer
--   than the 1 clock of a bare BRAM).
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

   type t_ram_lo is array (0 to 2**19 - 1) of std_logic_vector(7 downto 0);
   type t_ram_hi is array (0 to 2**17 - 1) of std_logic_vector(7 downto 0);

   signal ram_lo : t_ram_lo;
   signal ram_hi : t_ram_hi;
   attribute ram_style : string;
   attribute ram_style of ram_lo : signal is "block";
   attribute ram_style of ram_hi : signal is "block";

   -- stage 1: the registered request
   signal a_q      : std_logic_vector(19 downto 0) := (others => '0');
   signal d_q      : std_logic_vector(7 downto 0)  := (others => '0');
   signal en_q     : std_logic := '0';
   signal we_q     : std_logic := '0';
   signal inr_q    : std_logic := '0';

   -- stage 2: the block RAM outputs
   signal q_lo     : std_logic_vector(7 downto 0);
   signal q_hi     : std_logic_vector(7 downto 0);
   signal sel_hi_q : std_logic := '0';
   signal inr_q2   : std_logic := '0';
   signal ack_q    : std_logic := '0';

   signal limit    : unsigned(19 downto 0);

begin

   with size_i select limit <=
      to_unsigned(16#A0000#, 20) when "00",
      to_unsigned(16#80000#, 20) when "01",
      to_unsigned(16#40000#, 20) when "10",
      to_unsigned(16#20000#, 20) when others;

   p_req : process (clk_i)
   begin
      if rising_edge(clk_i) then
         a_q   <= ram_addr_i;
         d_q   <= ram_wdata_i;
         en_q  <= ram_en_i;
         we_q  <= ram_en_i and ram_we_i;
         if unsigned(ram_addr_i) < limit then
            inr_q <= '1';
         else
            inr_q <= '0';
         end if;
      end if;
   end process p_req;

   p_lo : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if we_q = '1' and inr_q = '1' and a_q(19) = '0' then
            ram_lo(to_integer(unsigned(a_q(18 downto 0)))) <= d_q;
         end if;
         q_lo <= ram_lo(to_integer(unsigned(a_q(18 downto 0))));
      end if;
   end process p_lo;

   p_hi : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if we_q = '1' and inr_q = '1' and a_q(19 downto 17) = "100" then
            ram_hi(to_integer(unsigned(a_q(16 downto 0)))) <= d_q;
         end if;
         q_hi <= ram_hi(to_integer(unsigned(a_q(16 downto 0))));
      end if;
   end process p_hi;

   p_out : process (clk_i)
   begin
      if rising_edge(clk_i) then
         sel_hi_q <= a_q(19);
         inr_q2   <= inr_q;
         ack_q    <= en_q;
      end if;
   end process p_out;

   ram_rdata_o <= x"FF" when inr_q2 = '0' else
                  q_hi  when sel_hi_q = '1' else
                  q_lo;
   ram_ack_o   <= ack_q;

end architecture synthesis;
