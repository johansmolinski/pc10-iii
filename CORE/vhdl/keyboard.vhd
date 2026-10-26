----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- MEGA65 keyboard -> IBM PC/XT keyboard (scan code set 1, make and break codes)
--
-- The framework scans the 80 MEGA65 keys round-robin (key_num_i, 1000 full scans per
-- second, key_pressed_n_i debounced and low active). Every change of a key becomes its
-- make code (pressed) or break code (make code + 0x80, released) in a 16-entry FIFO, which
-- is handed to pc_system one code at a time: kbd_valid_o is a one-clock strobe, given only
-- while kbd_busy_i is low and at least C_HOLDOFF clocks after the previous strobe (so that
-- the board's busy flag has time to rise). A full FIFO leaves the key unchanged, so the
-- change is seen again on the next scan and nothing is lost.
--
-- XT keyboards have no E0-prefixed keys: the four cursor keys send the keypad codes
-- (8/2/4/6), like the cursor keys of a real 83-key keyboard with Num Lock off.
--
-- The mapping is positional where the MEGA65 has the key in the PC's place:
--
--   MEGA65            XT key (scan code)        MEGA65            XT key (scan code)
--   ESC               Esc (01)                  RETURN            Enter (1C)
--   1 .. 0            1 .. 0 (02-0B)            INST/DEL          Backspace (0E)
--   -                 - (0C)                    TAB               Tab (0F)
--   =                 = (0D)                    CTRL              Ctrl (1D)
--   + (right of 0)    keypad + (4E)             left SHIFT        left Shift (2A)
--   pound             \ (2B)                    right SHIFT       right Shift (36)
--   @                 [ (1A)                    ALT               Alt (38)
--   *                 ] (1B)                    SPACE             Space (39)
--   :                 ; (27)                    CAPS LOCK         Caps Lock (3A)
--   ;                 ' (28)                    NO SCROLL         Scroll Lock (46)
--   arrow left        ` (29)                    CLR/HOME          keypad 7 / Home (47)
--   arrow up          keypad * / PrtSc (37)     RESTORE           Num Lock (45)
--   , . /             , . / (33 34 35)          cursor up/down    keypad 8 / 2 (48 / 50)
--   letters           letters                   cursor left/right keypad 4 / 6 (4B / 4D)
--   F1 F3 F5 F7       F1 F2 F3 F4 (3B-3E)       F9 F11 F13        F5 F6 F7 (3F-41)
--   RUN/STOP          F8 (42)
--   MEGA + 1 .. 0     F1 .. F10 (3B-44)
--   MEGA + CLR/HOME   End (keypad 1, 4F)        MEGA + cursor up    PgUp (keypad 9, 49)
--   MEGA + INST/DEL   Del (keypad ., 53)        MEGA + cursor down  PgDn (keypad 3, 51)
--   MEGA + pound      Ins (keypad 0, 52)        MEGA + -            keypad - (4A)
--   (the MEGA layer: the code sent at the make is remembered for the break)
--
-- Not mapped: MEGA alone, HELP (opens the OSM by default), keypad 5 (the MEGA65 has no
-- keypad; see doc/m2m-shell.md). The cursor keys' C64 shift semantics (SHIFT + CRSR
-- right = left) are not used: the MEGA65 has separate up and left keys.
--
-- done by Johan Smolinski in 2026 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity keyboard is
   port (
      clk_main_i      : in  std_logic;
      reset_i         : in  std_logic;

      -- Interface to the MEGA65 keyboard
      key_num_i       : in  integer range 0 to 79;   -- cycles through all MEGA65 keys
      key_pressed_n_i : in  std_logic;               -- low active, debounced

      -- XT scan codes to pc_system
      kbd_code_o      : out std_logic_vector(7 downto 0);
      kbd_valid_o     : out std_logic;
      kbd_busy_i      : in  std_logic
   );
end entity keyboard;

architecture synthesis of keyboard is

   -- MEGA65 key numbers (M2M template keyboard.vhd)
   constant m65_mega      : integer := 61;

   type t_map is array (0 to 79) of std_logic_vector(7 downto 0);

   -- scan code per MEGA65 key; x"00" = not mapped
   constant C_MAP : t_map := (
       0 => x"0E",   -- INST/DEL     -> Backspace
       1 => x"1C",   -- RETURN       -> Enter
       2 => x"4D",   -- CRSR right   -> keypad 6 / Right
       3 => x"3E",   -- F7           -> F4
       4 => x"3B",   -- F1           -> F1
       5 => x"3C",   -- F3           -> F2
       6 => x"3D",   -- F5           -> F3
       7 => x"50",   -- CRSR down    -> keypad 2 / Down
       8 => x"04",   -- 3
       9 => x"11",   -- W
      10 => x"1E",   -- A
      11 => x"05",   -- 4
      12 => x"2C",   -- Z
      13 => x"1F",   -- S
      14 => x"12",   -- E
      15 => x"2A",   -- left SHIFT
      16 => x"06",   -- 5
      17 => x"13",   -- R
      18 => x"20",   -- D
      19 => x"07",   -- 6
      20 => x"2E",   -- C
      21 => x"21",   -- F
      22 => x"14",   -- T
      23 => x"2D",   -- X
      24 => x"08",   -- 7
      25 => x"15",   -- Y
      26 => x"22",   -- G
      27 => x"09",   -- 8
      28 => x"30",   -- B
      29 => x"23",   -- H
      30 => x"16",   -- U
      31 => x"2F",   -- V
      32 => x"0A",   -- 9
      33 => x"17",   -- I
      34 => x"24",   -- J
      35 => x"0B",   -- 0
      36 => x"32",   -- M
      37 => x"25",   -- K
      38 => x"18",   -- O
      39 => x"31",   -- N
      40 => x"4E",   -- +            -> keypad +
      41 => x"19",   -- P
      42 => x"26",   -- L
      43 => x"0C",   -- -
      44 => x"34",   -- .
      45 => x"27",   -- :            -> ;
      46 => x"1A",   -- @            -> [
      47 => x"33",   -- ,
      48 => x"2B",   -- pound        -> \
      49 => x"1B",   -- *            -> ]
      50 => x"28",   -- ;            -> '
      51 => x"47",   -- CLR/HOME     -> keypad 7 / Home
      52 => x"36",   -- right SHIFT
      53 => x"0D",   -- =
      54 => x"37",   -- arrow up     -> keypad * / PrtSc
      55 => x"35",   -- /
      56 => x"02",   -- 1
      57 => x"29",   -- arrow left   -> `
      58 => x"1D",   -- CTRL
      59 => x"03",   -- 2
      60 => x"39",   -- SPACE
      61 => x"00",   -- MEGA         (Fn layer, see below)
      62 => x"10",   -- Q
      63 => x"42",   -- RUN/STOP     -> F8
      64 => x"46",   -- NO SCROLL    -> Scroll Lock
      65 => x"0F",   -- TAB
      66 => x"38",   -- ALT
      67 => x"00",   -- HELP         (OSM key)
      68 => x"3F",   -- F9           -> F5
      69 => x"40",   -- F11          -> F6
      70 => x"41",   -- F13          -> F7
      71 => x"01",   -- ESC
      72 => x"3A",   -- CAPS LOCK
      73 => x"48",   -- CRSR up      -> keypad 8 / Up
      74 => x"4B",   -- CRSR left    -> keypad 4 / Left
      75 => x"45",   -- RESTORE      -> Num Lock
      others => x"00"
   );

   -- The MEGA layer, by the key's own scan code: MEGA + digit = F1..F10 (the digits are scan
   -- codes 02..0B, 1..0), and the keypad keys the MEGA65 lacks (2026-10-26: SETUP's End).
   function fn_code(make : std_logic_vector(7 downto 0)) return std_logic_vector is
   begin
      if unsigned(make) >= 16#02# and unsigned(make) <= 16#0B# then
         return std_logic_vector(unsigned(make) + 16#39#);     -- 02 -> 3B (F1) .. 0B -> 44 (F10)
      end if;
      case make is
         when x"47"  => return x"4F";                           -- CLR/HOME   -> End
         when x"48"  => return x"49";                           -- cursor up  -> PgUp
         when x"50"  => return x"51";                           -- cursor down -> PgDn
         when x"0E"  => return x"53";                           -- INST/DEL   -> Del
         when x"2B"  => return x"52";                           -- pound      -> Ins
         when x"0C"  => return x"4A";                           -- -          -> keypad -
         when others => return x"00";
      end case;
   end function fn_code;

   constant C_FIFO_LOG : natural := 4;
   constant C_HOLDOFF  : natural := 7;

   type t_fifo is array (0 to 2**C_FIFO_LOG - 1) of std_logic_vector(7 downto 0);

   signal key_state : std_logic_vector(79 downto 0) := (others => '0');   -- 1 = pressed
   signal key_fn    : std_logic_vector(79 downto 0) := (others => '0');   -- make was an Fn code
   signal fifo      : t_fifo;
   signal wr_ptr    : unsigned(C_FIFO_LOG - 1 downto 0) := (others => '0');
   signal rd_ptr    : unsigned(C_FIFO_LOG - 1 downto 0) := (others => '0');
   signal count     : unsigned(C_FIFO_LOG downto 0) := (others => '0');
   signal holdoff   : natural range 0 to C_HOLDOFF := 0;
   signal code_q    : std_logic_vector(7 downto 0) := (others => '0');
   signal valid_q   : std_logic := '0';

   -- pipeline (timing at 100 MHz): A registers the scan, B looks the key up, C decides. The
   -- framework shows each key for many clocks, so after a change C ignores the next two clocks
   -- (B may still hold the key's state from before the change).
   signal a_num     : integer range 0 to 79 := 0;
   signal a_pressed : std_logic := '0';
   signal b_num     : integer range 0 to 79 := 0;
   signal b_pressed : std_logic := '0';
   signal b_state   : std_logic := '0';
   signal b_fn      : std_logic := '0';
   signal b_mega    : std_logic := '0';
   signal b_map     : std_logic_vector(7 downto 0) := (others => '0');
   signal c_lock    : natural range 0 to 2 := 0;

begin

   p_scan : process (clk_main_i)
      variable v_make    : std_logic_vector(7 downto 0);
      variable v_fn      : std_logic;
      variable v_push    : boolean;
      variable v_pop     : boolean;
   begin
      if rising_edge(clk_main_i) then
         v_push    := false;
         v_pop     := false;
         valid_q   <= '0';

         -- A, B
         a_num     <= key_num_i;
         a_pressed <= not key_pressed_n_i;
         b_num     <= a_num;
         b_pressed <= a_pressed;
         b_state   <= key_state(a_num);
         b_fn      <= key_fn(a_num);
         b_mega    <= key_state(m65_mega);
         b_map     <= C_MAP(a_num);

         -- C: a key changed: queue its make or break code
         if c_lock /= 0 then
            c_lock <= c_lock - 1;
         elsif b_pressed /= b_state and count < 2**C_FIFO_LOG then
            c_lock <= 2;
            key_state(b_num) <= b_pressed;
            if b_pressed = '1' then
               v_fn := '0';
               if b_mega = '1' and fn_code(b_map) /= x"00" then
                  v_fn := '1';
               end if;
               key_fn(b_num) <= v_fn;
            else
               v_fn := b_fn;
            end if;
            if v_fn = '1' then
               v_make := fn_code(b_map);
            else
               v_make := b_map;
            end if;
            if v_make /= x"00" then
               fifo(to_integer(wr_ptr)) <= (not b_pressed) & v_make(6 downto 0);
               v_push := true;
            end if;
         end if;

         -- hand the oldest code to the board
         if holdoff /= 0 then
            holdoff <= holdoff - 1;
         elsif count /= 0 and kbd_busy_i = '0' then
            code_q  <= fifo(to_integer(rd_ptr));
            valid_q <= '1';
            holdoff <= C_HOLDOFF;
            v_pop   := true;
         end if;

         if v_push then
            wr_ptr <= wr_ptr + 1;
         end if;
         if v_pop then
            rd_ptr <= rd_ptr + 1;
         end if;
         if v_push and not v_pop then
            count <= count + 1;
         elsif v_pop and not v_push then
            count <= count - 1;
         end if;

         if reset_i = '1' then
            key_state <= (others => '0');
            key_fn    <= (others => '0');
            wr_ptr    <= (others => '0');
            rd_ptr    <= (others => '0');
            count     <= (others => '0');
            holdoff   <= 0;
            valid_q   <= '0';
            c_lock    <= 2;
         end if;
      end if;
   end process p_scan;

   kbd_code_o  <= code_q;
   kbd_valid_o <= valid_q;

end architecture synthesis;
