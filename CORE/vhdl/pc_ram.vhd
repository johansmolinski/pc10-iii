----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- System RAM: 640 KB of byte-wide block RAM behind pc_system's abstract memory port
-- (doc/architecture.md section 4).
--
-- * 20 banks of 32 KB at 00000-9FFFF (8 RAMB36 each, 160 in all). NO QNICE port
--   (Megamiga hard rule 4: QNICE accesses on the falling
--   clock edge, a half-period path into 160 spread tiles does not close).
-- * Latency (timing at 100 MHz; the 160 tiles cover most of the die): the request is
--   registered as it comes (one copy, next to pc_system), then copied and decoded into one
--   register set per group of 5 banks, then into one per bank (so a register drives only
--   the 8 RAMB36 of its bank); the banks' outputs go through the block RAMs' output
--   registers and are multiplexed into a register. Read data and ram_ack_o are valid
--   6 clocks after ram_en_i (4 before doc/timing.md: the copy to all 20 banks and the
--   multiplexer each missed 100 MHz by a few hundred ps); pc_system waits for ram_ack_o
--   (architecture.md section 4 allows a later answer than the 1 clock of a bare BRAM, and
--   the board uses the data at the earliest 20 clocks after the request).
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
   constant C_GROUP  : natural := 5;                  -- banks per group
   constant C_GROUPS : natural := C_BANKS / C_GROUP;

   type t_bank   is array (0 to 2**15 - 1) of std_logic_vector(7 downto 0);
   type t_addr   is array (natural range <>) of std_logic_vector(14 downto 0);
   type t_data   is array (natural range <>) of std_logic_vector(7 downto 0);
   type t_gwe    is array (natural range <>) of std_logic_vector(C_GROUP - 1 downto 0);

   -- stage 0: the request as it comes
   signal r_addr   : std_logic_vector(19 downto 0) := (others => '0');
   signal r_wdata  : std_logic_vector(7 downto 0) := (others => '0');
   signal r_en     : std_logic := '0';
   signal r_we     : std_logic := '0';

   -- stage 1: the decoded request, one copy per group of banks
   signal g_addr   : t_addr(0 to C_GROUPS - 1) := (others => (others => '0'));
   signal g_wdata  : t_data(0 to C_GROUPS - 1) := (others => (others => '0'));
   signal g_we     : t_gwe(0 to C_GROUPS - 1) := (others => (others => '0'));
   attribute keep : string;
   attribute keep of g_addr  : signal is "true";
   attribute keep of g_wdata : signal is "true";
   signal bank_q   : natural range 0 to 31 := 0;
   signal en_q     : std_logic := '0';
   signal inr_q    : std_logic := '0';

   -- stage 2: one copy per bank
   signal b_addr   : t_addr(0 to C_BANKS - 1) := (others => (others => '0'));
   signal b_wdata  : t_data(0 to C_BANKS - 1) := (others => (others => '0'));
   signal b_we     : std_logic_vector(C_BANKS - 1 downto 0) := (others => '0');
   attribute keep of b_addr  : signal is "true";
   attribute keep of b_wdata : signal is "true";
   signal bank_q2  : natural range 0 to 31 := 0;
   signal en_q2    : std_logic := '0';
   signal inr_q2   : std_logic := '0';

   -- stage 3: the banks; stage 4: their output registers
   signal b_q      : t_data(0 to C_BANKS - 1);
   signal b_q2     : t_data(0 to C_BANKS - 1);
   signal bank_q3  : natural range 0 to 31 := 0;
   signal en_q3    : std_logic := '0';
   signal inr_q3   : std_logic := '0';
   signal bank_q4  : natural range 0 to 31 := 0;
   signal en_q4    : std_logic := '0';
   signal inr_q4   : std_logic := '0';

   -- stage 5: the output register
   signal rdata_q  : std_logic_vector(7 downto 0) := (others => '1');
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
      end if;
   end process p_in;

   p_group : process (clk_i)
      variable v_bank : natural range 0 to 31;
      variable v_inr  : std_logic;
   begin
      if rising_edge(clk_i) then
         v_bank := to_integer(unsigned(r_addr(19 downto 15)));
         if unsigned(r_addr) < limit then
            v_inr := '1';
         else
            v_inr := '0';
         end if;
         for g in 0 to C_GROUPS - 1 loop
            g_addr(g)  <= r_addr(14 downto 0);
            g_wdata(g) <= r_wdata;
            for j in 0 to C_GROUP - 1 loop
               if r_en = '1' and r_we = '1' and v_inr = '1' and v_bank = g * C_GROUP + j then
                  g_we(g)(j) <= '1';
               else
                  g_we(g)(j) <= '0';
               end if;
            end loop;
         end loop;
         bank_q <= v_bank;
         en_q   <= r_en;
         inr_q  <= v_inr;
      end if;
   end process p_group;

   p_req : process (clk_i)
   begin
      if rising_edge(clk_i) then
         for k in 0 to C_BANKS - 1 loop
            b_addr(k)  <= g_addr(k / C_GROUP);
            b_wdata(k) <= g_wdata(k / C_GROUP);
            b_we(k)    <= g_we(k / C_GROUP)(k mod C_GROUP);
         end loop;
         bank_q2 <= bank_q;
         en_q2   <= en_q;
         inr_q2  <= inr_q;
      end if;
   end process p_req;

   g_bank : for k in 0 to C_BANKS - 1 generate
      signal mem : t_bank;
      attribute ram_style : string;
      attribute ram_style of mem : signal is "block";
   begin
      p_bank : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if b_we(k) = '1' then
               mem(to_integer(unsigned(b_addr(k)))) <= b_wdata(k);
            end if;
            b_q(k)  <= mem(to_integer(unsigned(b_addr(k))));
            b_q2(k) <= b_q(k);                -- the block RAMs' output registers
         end if;
      end process p_bank;
   end generate g_bank;

   p_out : process (clk_i)
   begin
      if rising_edge(clk_i) then
         bank_q3 <= bank_q2;
         en_q3   <= en_q2;
         inr_q3  <= inr_q2;
         bank_q4 <= bank_q3;
         en_q4   <= en_q3;
         inr_q4  <= inr_q3;
         ack_q   <= en_q4;
         if inr_q4 = '0' or bank_q4 >= C_BANKS then
            rdata_q <= x"FF";
         else
            rdata_q <= b_q2(bank_q4);
         end if;
      end if;
   end process p_out;

   ram_rdata_o <= rdata_q;
   ram_ack_o   <= ack_q;

end architecture synthesis;
