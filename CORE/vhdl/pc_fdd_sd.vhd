----------------------------------------------------------------------------------
-- PC10-III for MEGA65
--
-- pc_fdd_sd: the floppy images of drives A: and B: straight from the SD card.
--
-- The FDC card (rtl/fdc, doc/fdc.md section 5) asks for whole 512-byte sectors through the
-- sector port and buffers them itself, so this backend has no cache: every request becomes one
-- single-block transfer through the SD host controller's engine port (M2M-UPSTREAM sd-host,
-- the approach of Megamiga's adf_sd.vhd):
--
--   * the firmware hands over each image as Megamiga does: the extent map of the file
--     (FAT32$FILE_MAP format: word 0 = number of extents, then per extent first cluster lo/hi
--     and number of clusters lo/hi, up to 511 extents), the SD block of cluster 0
--     (DEV_CLUSTER - (2 << SHIFT)), log2(sectors per cluster), the number of 512-byte sectors
--     and the card slot. The geometry follows from the size (doc/fdc.md section 5):
--         320 sectors 160K 40/1/8, 360 180K 40/1/9, 640 320K 40/2/8, 720 360K 40/2/9,
--         1440 720K 80/2/9; anything else: no disk.
--     drv_80trk follows the image (an 80-track drive for a 720K image).
--   * a request crosses into the QNICE clock domain as a toggle with a payload that is stable
--     while it crosses (CORE.xdc bounds qnice <-> main), and the answer comes back the same way.
--   * read: the LBA becomes an SD block through the extent map; the block lands in a 512-byte
--     dual-port buffer; then the main side streams it to the card (one byte per clock) and
--     ends with sp_done.
--   * write: the main side first takes the card's 512 bytes into the buffer (sp_wr_ready = 1),
--     then asks for the block write; sp_done comes when the card has the block (write-through:
--     a completed WRITE DATA is on the SD card).
--   * a failed transfer is tried again G_RETRIES times, 1 ms apart; a controller that is not
--     ready (it re-initialises the card, or no card) is waited for up to G_READY_WAIT ms. A
--     transfer that ended without a block (QNICE preempted the engine port before the block)
--     is issued again. Errors, a drive that is off, an LBA outside the file and a write to a
--     write-protected image end with sp_err.
--
-- QNICE devices C_DEV_PC_FDA / C_DEV_PC_FDB (qnice_drive_i selects which one is addressed;
-- writes on the falling edge like every M2M device, reads combinational):
--   window 0x0000  registers of the drive:
--     0x00 MODE    bit 0 = on, bit 1 = the card is in slot 1
--     0x01/0x02    SECTS  number of 512-byte sectors of the file (lo, hi)
--     0x03/0x04    BASE   SD block of cluster 0 (lo, hi)
--     0x05 SHIFT   log2(sectors per cluster)
--     0x06 WP      (read) bit 0 = write protected (from the menu, qnice_wp_i)
--     0x08 STATUS  (read) bit 0 = a transfer is running (any drive), bit 1 = the drive has a disk
--     0x10..0x12   (read) blocks read, blocks written, failed requests (all drives, wrapping)
--   window 0x0001  the extent map of the drive (2048 words)
--   window 0xFFFF  the M2M CRT/ROM load CSR (STATUS, file size; PARSEST answers "ready" as soon
--                  as STATUS is "ok": the firmware has set the drive up in PREP_LOAD_IMAGE)
--
-- done by Johan Smolinski in 2026 (after Megamiga's adf_sd.vhd) and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.sdhost_pkg.all;

entity pc_fdd_sd is
   generic (
      G_RETRIES      : natural := 2;
      G_MS           : natural := 50_000;      -- QNICE clocks per millisecond
      G_READY_WAIT   : natural := 500          -- ms
   );
   port (
      -- QNICE clock domain
      qnice_clk_i     : in  std_logic;
      qnice_rst_i     : in  std_logic;
      qnice_drive_i   : in  std_logic;         -- 0 = A:, 1 = B:
      qnice_addr_i    : in  std_logic_vector(27 downto 0);
      qnice_data_i    : in  std_logic_vector(15 downto 0);
      qnice_data_o    : out std_logic_vector(15 downto 0);
      qnice_ce_i      : in  std_logic;
      qnice_we_i      : in  std_logic;
      qnice_wp_i      : in  std_logic_vector(1 downto 0);   -- write protection (the menu)

      -- SD host engine port (QNICE clock domain)
      sd_c2q_o        : out std_logic_vector(75 downto 0);
      sd_q2c_i        : in  std_logic_vector(63 downto 0);

      -- main clock domain: drive inputs and the sector port of pc_system
      main_clk_i      : in  std_logic;
      main_rst_i      : in  std_logic;
      drv_80trk_o     : out std_logic_vector(1 downto 0);
      img_present_o   : out std_logic_vector(1 downto 0);
      img_wp_o        : out std_logic_vector(1 downto 0);
      img_tracks_o    : out std_logic_vector(15 downto 0);   -- {B, A}
      img_heads_o     : out std_logic_vector(3 downto 0);
      img_spt_o       : out std_logic_vector(11 downto 0);
      sp_req_i        : in  std_logic;
      sp_write_i      : in  std_logic;
      sp_drive_i      : in  std_logic;
      sp_lba_i        : in  std_logic_vector(15 downto 0);
      sp_rd_valid_o   : out std_logic;
      sp_rd_data_o    : out std_logic_vector(7 downto 0);
      sp_wr_valid_i   : in  std_logic;
      sp_wr_data_i    : in  std_logic_vector(7 downto 0);
      sp_wr_ready_o   : out std_logic;
      sp_done_o       : out std_logic;
      sp_err_o        : out std_logic;
      main_busy_o     : out std_logic                       -- a transfer is running (LED)
   );
end entity pc_fdd_sd;

architecture synthesis of pc_fdd_sd is

   attribute async_reg : string;

   type t_u16x2 is array (0 to 1) of unsigned(15 downto 0);
   type t_u32x2 is array (0 to 1) of unsigned(31 downto 0);
   type t_u3x2  is array (0 to 1) of unsigned(2 downto 0);
   type t_csr   is array (0 to 1) of std_logic_vector(3 downto 0);

   ------------------------------------------------------------------------------------------
   -- QNICE side: registers
   ------------------------------------------------------------------------------------------
   signal q_mode_on   : std_logic_vector(1 downto 0) := "00";
   signal q_slot1     : std_logic_vector(1 downto 0) := "00";
   signal q_wp        : std_logic_vector(1 downto 0);
   signal q_sects     : t_u32x2 := (others => (others => '0'));
   signal q_base      : t_u32x2 := (others => (others => '0'));
   signal q_shift     : t_u3x2  := (others => (others => '0'));
   signal q_csr       : t_csr   := (others => (others => '0'));
   signal q_fs        : t_u32x2 := (others => (others => '0'));
   signal q_st_rd     : unsigned(15 downto 0) := (others => '0');
   signal q_st_wr     : unsigned(15 downto 0) := (others => '0');
   signal q_st_err    : unsigned(15 downto 0) := (others => '0');

   signal q_win       : std_logic_vector(15 downto 0);
   signal q_ofs       : std_logic_vector(11 downto 0);
   signal q_d         : natural range 0 to 1;
   signal q_map_we    : std_logic;
   signal q_map_q     : std_logic_vector(15 downto 0);

   -- geometry per drive (combinational from SECTS)
   signal q_present   : std_logic_vector(1 downto 0);
   signal q_tracks    : std_logic_vector(15 downto 0);
   signal q_heads     : std_logic_vector(3 downto 0);
   signal q_spt       : std_logic_vector(11 downto 0);

   ------------------------------------------------------------------------------------------
   -- QNICE side: the transfer engine
   ------------------------------------------------------------------------------------------
   type t_qstate is (Q_IDLE, Q_CHECK, Q_N0, Q_N1, Q_EA, Q_EB, Q_EC, Q_ED, Q_EE, Q_EF, Q_SD,
                     Q_RUN, Q_DELAY, Q_FINISH);
   signal qstate      : t_qstate := Q_IDLE;
   signal q_req_s     : std_logic_vector(2 downto 0) := "000";   -- sync of m_req_tgl, + last
   attribute async_reg of q_req_s : signal is "true";
   signal q_drv       : natural range 0 to 1 := 0;
   signal q_write     : std_logic := '0';
   signal q_lba       : unsigned(15 downto 0) := (others => '0');
   signal q_cluster   : unsigned(15 downto 0) := (others => '0');
   signal q_offs      : unsigned(15 downto 0) := (others => '0');
   signal q_next      : unsigned(31 downto 0) := (others => '0');  -- first file cluster after the extent
   signal q_n         : unsigned(9 downto 0) := (others => '0');   -- extents
   signal q_e         : unsigned(9 downto 0) := (others => '0');
   signal q_first     : unsigned(31 downto 0) := (others => '0');
   signal q_cnt       : unsigned(31 downto 0) := (others => '0');
   signal q_block     : unsigned(31 downto 0) := (others => '0');
   signal q_map_raddr : std_logic_vector(11 downto 0);
   signal q_map_rq    : std_logic_vector(15 downto 0);
   signal q_tries     : natural range 0 to G_RETRIES := 0;
   signal q_ms_cnt    : natural range 0 to G_MS - 1 := 0;
   signal q_ms        : natural range 0 to G_READY_WAIT := 0;
   signal q_blk_seen  : std_logic := '0';
   signal q_err       : std_logic := '0';
   signal q_done_tgl  : std_logic := '0';
   signal q_busy      : std_logic := '0';
   signal q_start     : std_logic := '0';

   -- buffer port A (engine)
   signal q_buf_addr  : std_logic_vector(8 downto 0);
   signal q_buf_we    : std_logic;
   signal q_buf_q     : std_logic_vector(7 downto 0);

   ------------------------------------------------------------------------------------------
   -- main side
   ------------------------------------------------------------------------------------------
   type t_mstate is (M_IDLE, M_COLLECT, M_WAIT, M_STREAM, M_FIN, M_LOW);
   signal mstate      : t_mstate := M_IDLE;
   signal m_req_tgl   : std_logic := '0';
   signal m_drive     : std_logic := '0';
   signal m_write     : std_logic := '0';
   signal m_lba       : std_logic_vector(15 downto 0) := (others => '0');
   signal m_done_s    : std_logic_vector(2 downto 0) := "000";
   attribute async_reg of m_done_s : signal is "true";
   signal m_idx       : unsigned(9 downto 0) := (others => '0');
   signal m_buf_addr  : std_logic_vector(8 downto 0);
   signal m_buf_we    : std_logic;
   signal m_buf_q     : std_logic_vector(7 downto 0);
   signal m_rd_valid  : std_logic := '0';
   signal m_done      : std_logic := '0';
   signal m_err       : std_logic := '0';
   signal m_geo       : std_logic_vector(35 downto 0);

   -- the q_err of the answer, read in the main domain when the done toggle has crossed
   signal q_err_out   : std_logic := '0';

begin

   ------------------------------------------------------------------------------------------
   -- Geometry from the size
   ------------------------------------------------------------------------------------------

   g_geo : for d in 0 to 1 generate
      p_geo : process (all)
         variable v_t : natural range 0 to 255;
         variable v_h : natural range 0 to 3;
         variable v_s : natural range 0 to 63;
      begin
         v_t := 0; v_h := 0; v_s := 0;
         case to_integer(q_sects(d)) is
            when  320 => v_t := 40; v_h := 1; v_s := 8;
            when  360 => v_t := 40; v_h := 1; v_s := 9;
            when  640 => v_t := 40; v_h := 2; v_s := 8;
            when  720 => v_t := 40; v_h := 2; v_s := 9;
            when 1440 => v_t := 80; v_h := 2; v_s := 9;
            when others => null;
         end case;
         if v_t /= 0 and q_mode_on(d) = '1' then
            q_present(d) <= '1';
         else
            q_present(d) <= '0';
         end if;
         q_tracks(d * 8 + 7 downto d * 8) <= std_logic_vector(to_unsigned(v_t, 8));
         q_heads(d * 2 + 1 downto d * 2)  <= std_logic_vector(to_unsigned(v_h, 2));
         q_spt(d * 6 + 5 downto d * 6)    <= std_logic_vector(to_unsigned(v_s, 6));
      end process p_geo;
   end generate g_geo;

   -- into the main domain (static while the drive is set up; the FDC card drops its buffer at
   -- every command)
   i_cdc_geo : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => 36,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i               => qnice_clk_i,
         src_data_i(1 downto 0)  => q_present,
         src_data_i(3 downto 2)  => q_wp,
         src_data_i(19 downto 4) => q_tracks,
         src_data_i(23 downto 20)=> q_heads,
         src_data_i(35 downto 24)=> q_spt,
         dst_clk_i               => main_clk_i,
         dst_data_o              => m_geo
      ); -- i_cdc_geo

   img_present_o <= m_geo(1 downto 0);
   img_wp_o      <= m_geo(3 downto 2);
   img_tracks_o  <= m_geo(19 downto 4);
   img_heads_o   <= m_geo(23 downto 20);
   img_spt_o     <= m_geo(35 downto 24);
   drv_80trk_o(0) <= '1' when m_geo(11 downto 4)  = x"50" else '0';
   drv_80trk_o(1) <= '1' when m_geo(19 downto 12) = x"50" else '0';

   ------------------------------------------------------------------------------------------
   -- QNICE registers
   ------------------------------------------------------------------------------------------

   q_wp  <= qnice_wp_i;
   q_win <= qnice_addr_i(27 downto 12);
   q_ofs <= qnice_addr_i(11 downto 0);
   q_d   <= 1 when qnice_drive_i = '1' else 0;

   p_qregs : process (qnice_clk_i)
   begin
      if falling_edge(qnice_clk_i) then
         if qnice_ce_i = '1' and qnice_we_i = '1' then
            if q_win = x"0000" then
               case q_ofs is
                  when x"000" => q_mode_on(q_d) <= qnice_data_i(0);
                                 q_slot1(q_d)   <= qnice_data_i(1);
                  when x"001" => q_sects(q_d)(15 downto 0)  <= unsigned(qnice_data_i);
                  when x"002" => q_sects(q_d)(31 downto 16) <= unsigned(qnice_data_i);
                  when x"003" => q_base(q_d)(15 downto 0)   <= unsigned(qnice_data_i);
                  when x"004" => q_base(q_d)(31 downto 16)  <= unsigned(qnice_data_i);
                  when x"005" => q_shift(q_d) <= unsigned(qnice_data_i(2 downto 0));
                  when others => null;
               end case;
            elsif q_win = x"FFFF" then
               case q_ofs is
                  when x"000" => q_csr(q_d) <= qnice_data_i(3 downto 0);
                  when x"001" => q_fs(q_d)(15 downto 0)  <= unsigned(qnice_data_i);
                  when x"002" => q_fs(q_d)(31 downto 16) <= unsigned(qnice_data_i);
                  when others => null;
               end case;
            end if;
         end if;
         if qnice_rst_i = '1' then
            q_mode_on <= "00";
            q_csr     <= (others => (others => '0'));
         end if;
      end if;
   end process p_qregs;

   p_qread : process (all)
   begin
      qnice_data_o <= x"EEEE";
      if q_win = x"0000" then
         case q_ofs is
            when x"000" => qnice_data_o <= x"000" & "00" & q_slot1(q_d) & q_mode_on(q_d);
            when x"001" => qnice_data_o <= std_logic_vector(q_sects(q_d)(15 downto 0));
            when x"002" => qnice_data_o <= std_logic_vector(q_sects(q_d)(31 downto 16));
            when x"003" => qnice_data_o <= std_logic_vector(q_base(q_d)(15 downto 0));
            when x"004" => qnice_data_o <= std_logic_vector(q_base(q_d)(31 downto 16));
            when x"005" => qnice_data_o <= x"000" & "0" & std_logic_vector(q_shift(q_d));
            when x"006" => qnice_data_o <= x"000" & "000" & q_wp(q_d);
            when x"008" => qnice_data_o <= x"000" & "00" & q_present(q_d) & q_busy;
            when x"010" => qnice_data_o <= std_logic_vector(q_st_rd);
            when x"011" => qnice_data_o <= std_logic_vector(q_st_wr);
            when x"012" => qnice_data_o <= std_logic_vector(q_st_err);
            when others => qnice_data_o <= x"0000";
         end case;
      elsif q_win = x"0001" then
         qnice_data_o <= q_map_q;
      elsif q_win = x"FFFF" then
         qnice_data_o <= x"0000";
         case q_ofs is
            when x"000" => qnice_data_o <= x"000" & q_csr(q_d);
            when x"001" => qnice_data_o <= std_logic_vector(q_fs(q_d)(15 downto 0));
            when x"002" => qnice_data_o <= std_logic_vector(q_fs(q_d)(31 downto 16));
            when x"010" => if q_csr(q_d) = "0011" then         -- STATUS ok -> PARSEST ready
                              qnice_data_o <= x"0002";
                           end if;
            when others => null;
         end case;
      end if;
   end process p_qread;

   ------------------------------------------------------------------------------------------
   -- Extent maps: port A = QNICE (falling edge), port B = the engine (rising edge)
   ------------------------------------------------------------------------------------------

   q_map_we <= qnice_ce_i and qnice_we_i when q_win = x"0001" else '0';

   i_map : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH        => 12,
         DATA_WIDTH        => 16,
         RAM_STYLE_SELECT  => "block",
         FALLING_A         => true
      )
      port map (
         clock_a           => qnice_clk_i,
         address_a         => qnice_drive_i & q_ofs(10 downto 0),
         data_a            => qnice_data_i,
         wren_a            => q_map_we,
         q_a               => q_map_q,
         clock_b           => qnice_clk_i,
         address_b         => q_map_raddr,
         q_b               => q_map_rq
      ); -- i_map

   ------------------------------------------------------------------------------------------
   -- The transfer engine (QNICE clock, rising edge)
   ------------------------------------------------------------------------------------------

   -- extent map word address, combinational from the state: the word addressed in one state
   -- is at q_map_rq in the next one (Q_N0: count; Q_N1/Q_EF: first lo; Q_EA: first hi;
   -- Q_EB: clusters lo; Q_EC: clusters hi)
   p_maddr : process (all)
      variable v_w : unsigned(10 downto 0);
      variable v_b : unsigned(10 downto 0);
   begin
      v_b := resize(q_e & "00", 11);
      case qstate is
         when Q_N1 | Q_EF => v_w := v_b + 1;
         when Q_EA        => v_w := v_b + 2;
         when Q_EB        => v_w := v_b + 3;
         when Q_EC        => v_w := v_b + 4;
         when others      => v_w := (others => '0');
      end case;
      if q_drv = 1 then
         q_map_raddr <= '1' & std_logic_vector(v_w);
      else
         q_map_raddr <= '0' & std_logic_vector(v_w);
      end if;
   end process p_maddr;

   p_engine : process (qnice_clk_i)
      variable v_shift : natural range 0 to 7;
      variable v_end   : unsigned(31 downto 0);
   begin
      if rising_edge(qnice_clk_i) then
         q_start <= '0';
         q_req_s <= q_req_s(1 downto 0) & m_req_tgl;
         v_shift := to_integer(q_shift(q_drv));

         case qstate is
            when Q_IDLE =>
               q_busy <= '0';
               if q_req_s(2) /= q_req_s(1) then
                  q_busy  <= '1';
                  if m_drive = '1' then q_drv <= 1; else q_drv <= 0; end if;
                  q_write <= m_write;
                  q_lba   <= unsigned(m_lba);
                  q_tries <= 0;
                  q_err   <= '0';
                  q_ms    <= 0;
                  qstate  <= Q_CHECK;
               end if;

            when Q_CHECK =>
               q_cluster <= shift_right(q_lba, v_shift);
               q_offs    <= q_lba and (shift_left(to_unsigned(1, 16), v_shift) - 1);
               q_e       <= (others => '0');
               q_next    <= (others => '0');
               if q_mode_on(q_drv) = '0' or resize(q_lba, 32) >= q_sects(q_drv) or
                  (q_write = '1' and q_wp(q_drv) = '1') then
                  q_err  <= '1';
                  qstate <= Q_FINISH;
               else
                  qstate <= Q_N0;
               end if;

            when Q_N0 =>                                    -- address word 0
               qstate <= Q_N1;

            when Q_N1 =>                                    -- the number of extents
               q_n <= unsigned(q_map_rq(9 downto 0));
               if unsigned(q_map_rq) = 0 or unsigned(q_map_rq) > 511 then
                  q_err  <= '1';
                  qstate <= Q_FINISH;
               else
                  qstate <= Q_EA;
               end if;

            when Q_EA =>
               q_first(15 downto 0)  <= unsigned(q_map_rq);
               qstate <= Q_EB;

            when Q_EB =>
               q_first(31 downto 16) <= unsigned(q_map_rq);
               qstate <= Q_EC;

            when Q_EC =>
               q_cnt(15 downto 0)    <= unsigned(q_map_rq);
               qstate <= Q_ED;

            when Q_ED =>
               q_cnt(31 downto 16)   <= unsigned(q_map_rq);
               qstate <= Q_EE;

            when Q_EE =>
               v_end := q_next + q_cnt;
               if resize(q_cluster, 32) < v_end then
                  q_block <= q_base(q_drv) +
                             shift_left(q_first + resize(q_cluster, 32) - q_next, v_shift) +
                             resize(q_offs, 32);
                  qstate  <= Q_SD;
               elsif q_e + 1 = q_n then                     -- past the end of the map
                  q_err  <= '1';
                  qstate <= Q_FINISH;
               else
                  q_next <= v_end;
                  q_e    <= q_e + 1;
                  qstate <= Q_EF;
               end if;

            when Q_EF =>                                    -- address the next extent
               qstate <= Q_EA;

            when Q_SD =>                                    -- wait for the controller
               q_blk_seen <= '0';
               if sd_q2c_i(Q2C_READY) = '1' and sd_q2c_i(Q2C_BUSY) = '0' then
                  q_start <= '1';
                  qstate  <= Q_RUN;
               elsif q_ms = G_READY_WAIT then
                  q_err  <= '1';
                  qstate <= Q_FINISH;
               elsif q_ms_cnt = G_MS - 1 then
                  q_ms_cnt <= 0;
                  q_ms     <= q_ms + 1;
               else
                  q_ms_cnt <= q_ms_cnt + 1;
               end if;

            when Q_RUN =>
               if sd_q2c_i(Q2C_BLK) = '1' then
                  q_blk_seen <= '1';
               end if;
               if q_start = '0' and sd_q2c_i(Q2C_DONE) = '1' then
                  if sd_q2c_i(Q2C_ERROR) = '1' then
                     if q_tries = G_RETRIES then
                        q_err  <= '1';
                        qstate <= Q_FINISH;
                     else
                        q_tries  <= q_tries + 1;
                        q_ms_cnt <= 0;
                        qstate   <= Q_DELAY;
                     end if;
                  elsif q_blk_seen = '0' and sd_q2c_i(Q2C_BLK) = '0' then
                     qstate <= Q_SD;                       -- preempted before the block
                  else
                     qstate <= Q_FINISH;
                  end if;
               end if;

            when Q_DELAY =>                                 -- 1 ms before a retry
               if q_ms_cnt = G_MS - 1 then
                  q_ms_cnt <= 0;
                  qstate   <= Q_SD;
               else
                  q_ms_cnt <= q_ms_cnt + 1;
               end if;

            when Q_FINISH =>
               if q_err = '1' then
                  q_st_err <= q_st_err + 1;
               elsif q_write = '1' then
                  q_st_wr <= q_st_wr + 1;
               else
                  q_st_rd <= q_st_rd + 1;
               end if;
               q_err_out  <= q_err;
               q_done_tgl <= not q_done_tgl;
               qstate     <= Q_IDLE;
         end case;

         if qnice_rst_i = '1' then
            qstate     <= Q_IDLE;
            q_busy     <= '0';
            q_start    <= '0';
         end if;
      end if;
   end process p_engine;

   -- the engine port: request fields held for the whole transfer, START a pulse
   p_c2q : process (all)
   begin
      sd_c2q_o              <= (others => '0');
      sd_c2q_o(C2Q_START)   <= q_start;
      sd_c2q_o(C2Q_WRITE)   <= q_write;
      sd_c2q_o(C2Q_ADDR)    <= std_logic_vector(q_block);
      sd_c2q_o(C2Q_COUNT)   <= x"0001";
      sd_c2q_o(C2Q_LIMIT)   <= x"0001";
      sd_c2q_o(C2Q_WRDATA)  <= q_buf_q;
      sd_c2q_o(C2Q_SLOT)    <= q_slot1(q_drv);
   end process p_c2q;

   -- buffer port A: the controller's read strobes write it, its write address reads it (the
   -- byte is there one clock after the address, as sdhost expects)
   q_buf_addr <= sd_q2c_i(Q2C_RDIDX) when q_write = '0' else sd_q2c_i(Q2C_WRIDX);
   q_buf_we   <= sd_q2c_i(Q2C_RDWE) when q_write = '0' and qstate = Q_RUN else '0';

   i_buf : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH        => 9,
         DATA_WIDTH        => 8,
         RAM_STYLE_SELECT  => "block"
      )
      port map (
         clock_a           => qnice_clk_i,
         address_a         => q_buf_addr,
         data_a            => sd_q2c_i(Q2C_RDDATA),
         wren_a            => q_buf_we,
         q_a               => q_buf_q,
         clock_b           => main_clk_i,
         address_b         => m_buf_addr,
         data_b            => sp_wr_data_i,
         wren_b            => m_buf_we,
         q_b               => m_buf_q
      ); -- i_buf

   ------------------------------------------------------------------------------------------
   -- Main side: the sector port
   ------------------------------------------------------------------------------------------

   m_buf_addr <= std_logic_vector(m_idx(8 downto 0));
   m_buf_we   <= sp_wr_valid_i when mstate = M_COLLECT else '0';
   sp_wr_ready_o <= '1' when mstate = M_COLLECT else '0';

   p_main : process (main_clk_i)
   begin
      if rising_edge(main_clk_i) then
         m_done_s   <= m_done_s(1 downto 0) & q_done_tgl;
         m_rd_valid <= '0';
         m_done     <= '0';
         m_err      <= '0';

         case mstate is
            when M_IDLE =>
               m_idx <= (others => '0');
               if sp_req_i = '1' then
                  m_drive <= sp_drive_i;
                  m_write <= sp_write_i;
                  m_lba   <= sp_lba_i;
                  if sp_write_i = '1' then
                     mstate <= M_COLLECT;
                  else
                     m_req_tgl <= not m_req_tgl;
                     mstate    <= M_WAIT;
                  end if;
               end if;

            when M_COLLECT =>
               if sp_wr_valid_i = '1' then
                  if m_idx = 511 then
                     m_req_tgl <= not m_req_tgl;
                     mstate    <= M_WAIT;
                  end if;
                  m_idx <= m_idx + 1;
               end if;

            when M_WAIT =>
               m_idx <= (others => '0');
               if m_done_s(2) /= m_done_s(1) then
                  if m_write = '0' and q_err_out = '0' then
                     mstate <= M_STREAM;
                  else
                     m_done <= '1';
                     m_err  <= q_err_out;
                     mstate <= M_LOW;
                  end if;
               end if;

            -- the byte at m_idx is in m_buf_q one clock later
            when M_STREAM =>
               m_rd_valid <= '1';
               if m_idx = 511 then
                  mstate <= M_FIN;
               end if;
               m_idx <= m_idx + 1;

            when M_FIN =>
               m_done <= '1';
               mstate <= M_LOW;

            when M_LOW =>
               if sp_req_i = '0' then
                  mstate <= M_IDLE;
               end if;
         end case;

         if main_rst_i = '1' then
            mstate     <= M_IDLE;
            m_rd_valid <= '0';
            m_done     <= '0';
         end if;
      end if;
   end process p_main;

   sp_rd_valid_o <= m_rd_valid;
   sp_rd_data_o  <= m_buf_q;
   sp_done_o     <= m_done;
   sp_err_o      <= m_err;
   main_busy_o   <= '0' when mstate = M_IDLE else '1';

end architecture synthesis;
