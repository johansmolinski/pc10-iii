----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- pc_ports.vhd: the PC10-III's serial and parallel ports on the MEGA65's PMOD headers and
-- its bus mouse port on joystick port 1 (doc/ports.md section 6).
--
-- PMOD (M2M-UPSTREAM pmod-pins, Megamiga's exception 13: the board tops route the headers
-- into MEGA65_Core). One menu item ("PMOD: serial + printer", pmod_on_i) powers both headers
-- and drives the outputs; off, every pin is high-Z and both headers are unpowered, as in
-- Megamiga. All signals are 3.3 V TTL at the chip's polarity:
--   PMOD1 lo  [0] /CTS in   [1] TXD out    [2] RXD in    [3] /RTS out   (Megamiga's layout)
--   PMOD1 hi  [0] /STROBE out  [1] BUSY in  [2] /ACK in  [3] /INIT out
--   PMOD2 lo  D0-D3 out         PMOD2 hi  D4-D7 out
-- The inputs are synchronized (2 FF); CORE.xdc pulls RXD and /ACK up (idle) and /CTS and
-- BUSY down (an unconnected pin reads "clear to send" and "printer not busy").
-- The 8250's other modem inputs are not on the header: with the PMOD on, DSR and DCD follow
-- the PC's own DTR (the DTR-DSR-DCD loop of a null-modem cable, so the BIOS's INT 14h and
-- terminal programs see a partner), RI is inactive. With the PMOD off the port reads as one
-- with nothing plugged in: RXD idle (mark), CTS, DSR, DCD and RI inactive. The printer's
-- status lines that are not on the header (PE, SLCT, /ERROR) read "printer ready"; with the
-- PMOD off BUSY and /ACK too (the port still exists, the BIOS still finds it).
--
-- Mouse: an Amiga (1352-style, the PC10-III's own) or Atari ST quadrature mouse in joystick
-- port 1, through M2M's debouncer, which is a plain 2-FF synchronizer here (M2M-UPSTREAM
-- raw-joyports, Megamiga's exception 6: a 1 ms filter swallows the quadrature pulses).
-- M2M's names are the joystick's: up = DB9 pin 1, down = 2, left = 3, right = 4, fire = 6.
--   Amiga: H = pin 2, HQ = pin 4, V = pin 1, VQ = pin 3 (the 5720's J8 has the same lines)
--   Atari ST (atari_i): pins 1 and 4 swapped, the known adapter wiring [A]
-- Buttons: left = fire (pin 6). Right (pin 9) and middle (pin 5) are POT lines that the
-- MEGA65 can only sense: a passive mouse's switches to GND are invisible on every board
-- revision, so they work only with an active adapter that drives the lines (Megamiga's
-- presence latch: a line counts as a button only after it was seen driven high, and a
-- line that stays "pressed" for 30 s disarms it again, an unplugged adapter).
--
-- done by Johan Smolinski in 2026, the PMOD wiring and the POT buttons after Megamiga's
-- mega65.vhd and main.vhd, licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pc_ports is
   generic (
      G_POT_TIMEOUT        : natural := 30 * 28_636_364      -- 30 s of a held POT button
   );
   port (
      clk_i                : in    std_logic;
      rst_i                : in    std_logic;                 -- the PC's reset (the POT latches)
      pmod_on_i            : in    std_logic;                 -- the menu: PMOD headers on
      atari_i              : in    std_logic;                 -- the menu: an Atari ST mouse

      -- the 8250's pins (pc_system)
      ser_txd_i            : in    std_logic;
      ser_rts_n_i          : in    std_logic;
      ser_dtr_n_i          : in    std_logic;
      ser_rxd_o            : out   std_logic;
      ser_cts_n_o          : out   std_logic;
      ser_dsr_n_o          : out   std_logic;
      ser_dcd_n_o          : out   std_logic;
      ser_ri_n_o           : out   std_logic;
      -- the parallel port's pins (pc_system)
      lpt_data_i           : in    std_logic_vector(7 downto 0);
      lpt_strobe_n_i       : in    std_logic;
      lpt_init_n_i         : in    std_logic;
      lpt_busy_o           : out   std_logic;
      lpt_ack_n_o          : out   std_logic;
      lpt_pe_o             : out   std_logic;
      lpt_slct_o           : out   std_logic;
      lpt_err_n_o          : out   std_logic;

      -- joystick port 1 (M2M, synchronized) and its POT lines (255 - the sampler's count)
      joy_up_n_i           : in    std_logic;
      joy_down_n_i         : in    std_logic;
      joy_left_n_i         : in    std_logic;
      joy_right_n_i        : in    std_logic;
      joy_fire_n_i         : in    std_logic;
      pot_x_i              : in    std_logic_vector(7 downto 0);   -- DB9 pin 9
      pot_y_i              : in    std_logic_vector(7 downto 0);   -- DB9 pin 5
      -- the bus mouse's lines (pc_system)
      mouse_xp_o           : out   std_logic;                 -- H
      mouse_xq_o           : out   std_logic;                 -- HQ
      mouse_yp_o           : out   std_logic;                 -- V
      mouse_yq_o           : out   std_logic;                 -- VQ
      mouse_btn_n_o        : out   std_logic_vector(2 downto 0);   -- {right, middle, left}

      -- the PMOD headers
      p1lo_io              : inout std_logic_vector(3 downto 0);
      p1hi_io              : inout std_logic_vector(3 downto 0);
      p2lo_io              : inout std_logic_vector(3 downto 0);
      p2hi_io              : inout std_logic_vector(3 downto 0);
      pmod1_en_o           : out   std_logic;
      pmod2_en_o           : out   std_logic
   );
end entity pc_ports;

architecture synthesis of pc_ports is

   signal on_q             : std_logic := '0';
   -- RXD, /CTS, BUSY, /ACK
   signal in_meta          : std_logic_vector(3 downto 0) := "1101";
   signal in_sync          : std_logic_vector(3 downto 0) := "1101";
   attribute ASYNC_REG     : string;
   attribute ASYNC_REG of in_meta : signal is "TRUE";
   attribute ASYNC_REG of in_sync : signal is "TRUE";

   signal rmb_capable      : std_logic := '0';
   signal mmb_capable      : std_logic := '0';
   signal rmb_watchdog     : natural range 0 to G_POT_TIMEOUT := 0;
   signal mmb_watchdog     : natural range 0 to G_POT_TIMEOUT := 0;

begin

   p_sync : process (clk_i)
   begin
      if rising_edge(clk_i) then
         on_q    <= pmod_on_i;
         in_meta <= p1lo_io(2) & p1lo_io(0) & p1hi_io(1) & p1hi_io(2);
         in_sync <= in_meta;
      end if;
   end process p_sync;

   ---------------------------------------------------------------------------------------------
   -- PMOD pins
   ---------------------------------------------------------------------------------------------

   pmod1_en_o <= on_q;
   pmod2_en_o <= on_q;

   p1lo_io(0) <= 'Z';                                               -- /CTS in
   p1lo_io(1) <= ser_txd_i      when on_q = '1' else 'Z';           -- TXD
   p1lo_io(2) <= 'Z';                                               -- RXD in
   p1lo_io(3) <= ser_rts_n_i    when on_q = '1' else 'Z';           -- /RTS
   p1hi_io(0) <= lpt_strobe_n_i when on_q = '1' else 'Z';           -- /STROBE
   p1hi_io(1) <= 'Z';                                               -- BUSY in
   p1hi_io(2) <= 'Z';                                               -- /ACK in
   p1hi_io(3) <= lpt_init_n_i   when on_q = '1' else 'Z';           -- /INIT
   p2lo_io    <= lpt_data_i(3 downto 0) when on_q = '1' else (others => 'Z');
   p2hi_io    <= lpt_data_i(7 downto 4) when on_q = '1' else (others => 'Z');

   ser_rxd_o   <= in_sync(3)  when on_q = '1' else '1';
   ser_cts_n_o <= in_sync(2)  when on_q = '1' else '1';
   ser_dsr_n_o <= ser_dtr_n_i when on_q = '1' else '1';
   ser_dcd_n_o <= ser_dtr_n_i when on_q = '1' else '1';
   ser_ri_n_o  <= '1';
   lpt_busy_o  <= in_sync(1)  when on_q = '1' else '0';
   lpt_ack_n_o <= in_sync(0)  when on_q = '1' else '1';
   lpt_pe_o    <= '0';
   lpt_slct_o  <= '1';
   lpt_err_n_o <= '1';

   ---------------------------------------------------------------------------------------------
   -- The mouse
   ---------------------------------------------------------------------------------------------

   mouse_xp_o <= joy_down_n_i;                                      -- pin 2
   mouse_xq_o <= joy_up_n_i    when atari_i = '1' else joy_right_n_i;   -- pin 1 / pin 4
   mouse_yp_o <= joy_right_n_i when atari_i = '1' else joy_up_n_i;      -- pin 4 / pin 1
   mouse_yq_o <= joy_left_n_i;                                      -- pin 3

   -- the POT buttons' presence latches (Megamiga's main.vhd)
   p_pot : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if pot_x_i(7) = '1' then
            rmb_capable  <= '1';
            rmb_watchdog <= 0;
         elsif rmb_capable = '1' then
            if rmb_watchdog = G_POT_TIMEOUT then
               rmb_capable <= '0';
            else
               rmb_watchdog <= rmb_watchdog + 1;
            end if;
         end if;

         if pot_y_i(7) = '1' then
            mmb_capable  <= '1';
            mmb_watchdog <= 0;
         elsif mmb_capable = '1' then
            if mmb_watchdog = G_POT_TIMEOUT then
               mmb_capable <= '0';
            else
               mmb_watchdog <= mmb_watchdog + 1;
            end if;
         end if;

         if rst_i = '1' then
            rmb_capable  <= '0';
            rmb_watchdog <= 0;
            mmb_capable  <= '0';
            mmb_watchdog <= 0;
         end if;
      end if;
   end process p_pot;

   mouse_btn_n_o(0) <= joy_fire_n_i;
   mouse_btn_n_o(1) <= not (mmb_capable and not pot_y_i(7));
   mouse_btn_n_o(2) <= not (rmb_capable and not pot_x_i(7));

end architecture synthesis;
