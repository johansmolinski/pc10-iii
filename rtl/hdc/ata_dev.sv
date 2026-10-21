// ata_dev.sv - an ATA hard disk pair (master + slave) whose media are disk
// images behind a sector port (doc/hdc.md).
//
// What the host sees is an ATA-2 style PIO device: the task file (command
// block registers 1-7, alternate status / device control), IDENTIFY DEVICE,
// READ/WRITE SECTORS, READ/WRITE MULTIPLE, SET MULTIPLE MODE, READ VERIFY,
// INITIALIZE DEVICE PARAMETERS, SET FEATURES (8-bit transfers for XT-CF),
// RECALIBRATE, SEEK, EXECUTE DEVICE DIAGNOSTIC and the power commands as
// no-ops. CHS (with the geometry from INITIALIZE DEVICE PARAMETERS) and
// LBA28 addressing. The data register is 16 bits wide, or 8 bits after SET
// FEATURES 01h; the card (xtide_card.sv) turns it into 8-bit ISA cycles.
//
// Both devices see every register write (one shared task file); a command
// runs on the device selected when it was written. One command at a time.
//
// Timing (doc/hdc.md section 4; deterministic for a given backend):
//   - BSY in the clk after the command write;
//   - non-data commands, IDENTIFY and the first DRQ of a write: CMD_US;
//   - between DRQ blocks: at least BLK_US, and until the next block of a
//     read is in the buffer (or a write has room for it);
//   - a write completes when the backend has stored every sector;
//   - power-up / RESET DRV / SRST: BSY for RESET_US after the reset ends.
// The time base is a 1 us enable from a phase accumulator (clk x 22/2205).
//
// The sector buffer has 8 slots of 512 bytes (hdc_secbuf.sv): reads are
// prefetched up to 8 sectors ahead of the host, writes are committed behind
// it, so READ/WRITE MULTIPLE accept blocks up to 8 sectors.
//
// GPL-3.0-or-later, pc10-iii.

module ata_dev #(
    parameter int SLOTS_LOG2 = 3,
    parameter int MULT_MAX   = 8,       // power of 2, <= 2**SLOTS_LOG2
    parameter int US_NUM     = 22,      // 1 us = clk * US_NUM / US_DEN
    parameter int US_DEN     = 2205,
    parameter int CMD_US     = 5,
    parameter int BLK_US     = 2,
    parameter int RESET_US   = 1000
) (
    input  logic        clk,
    input  logic        reset,          // hardware reset (RESET DRV)

    // task file (one-clk strobes from the card's decoder)
    input  logic        tf_rd,          // a register read begins (side effects)
    input  logic        tf_wr,          // a register write, data in tf_wdata
    input  logic        tf_cs1,         // 0 = command block, 1 = control block
    input  logic [2:0]  tf_reg,
    input  logic [7:0]  tf_wdata,
    output logic [7:0]  tf_rdata,       // the addressed register (combinational)
    output logic        tf_drive,       // the addressed register exists

    // data register
    input  logic        dat_rd,         // the host took dat_q (2 bytes or the low one)
    input  logic        dat_wr,         // the host writes dat_wdata
    input  logic        dat_word,       // 1 = 16-bit transfer, 0 = 8-bit
    input  logic [15:0] dat_wdata,
    output logic [15:0] dat_q,          // the next two bytes of the data phase
    output logic        mode8,          // the selected device is in 8-bit mode
    output logic        intrq,          // INTRQ (nIEN applied)

    // the media
    input  logic [1:0]       hd_present,
    input  logic [1:0][27:0] hd_sectors,    // LBA capacity
    input  logic [1:0][15:0] hd_cyls,       // default geometry (IDENTIFY words 1/3/6)
    input  logic [1:0][4:0]  hd_heads,      // 1-16
    input  logic [1:0][5:0]  hd_spt,        // 1-63
    output logic        active,             // a command runs or a sector moves

    // sector port (doc/hdc.md section 5)
    output logic        sp_req,
    output logic        sp_write,
    output logic        sp_drive,
    output logic [27:0] sp_lba,
    input  logic        sp_rd_valid,
    input  logic [7:0]  sp_rd_data,
    output logic        sp_wr_valid,
    output logic [7:0]  sp_wr_data,
    input  logic        sp_wr_ready,
    input  logic        sp_done,
    input  logic        sp_err
);

localparam int SLOTS = 2 ** SLOTS_LOG2;
localparam int AW    = SLOTS_LOG2 + 9;

// status bits
localparam logic [7:0] ST_BSY = 8'h80, ST_DRDY = 8'h40, ST_DF = 8'h20, ST_DSC = 8'h10,
                       ST_DRQ = 8'h08, ST_ERR = 8'h01;
// error register bits
localparam logic [7:0] ER_ABRT = 8'h04, ER_IDNF = 8'h10, ER_UNC = 8'h40;

// ------------------------------------------------------------ 1 us enable
logic [11:0] us_acc;
logic        us_tick;
always_ff @(posedge clk) begin
    if (reset) begin
        us_acc  <= 12'd0;
        us_tick <= 1'b0;
    end else if (us_acc + 12'(US_NUM) >= 12'(US_DEN)) begin
        us_acc  <= us_acc + 12'(US_NUM) - 12'(US_DEN);
        us_tick <= 1'b1;
    end else begin
        us_acc  <= us_acc + 12'(US_NUM);
        us_tick <= 1'b0;
    end
end

// ------------------------------------------------------------ registers
// task file (shared by both devices)
logic [7:0] r_feat, r_nsect, r_sect, r_lcyl, r_hcyl, r_sel;
logic       nien, srst;
wire        sel_dev = r_sel[4];
wire        sel_lba = r_sel[6];

// per device
logic [1:0][7:0]  r_err;                // error register
logic [1:0]       r_errbit, r_df;       // status ERR, DF after the last command
logic [1:0][15:0] g_cyls;               // current (logical) geometry
logic [1:0][4:0]  g_heads;
logic [1:0][7:0]  g_spt;
logic [1:0][7:0]  g_mult;               // READ/WRITE MULTIPLE block, 0 = off
logic [1:0]       g_mode8;              // SET FEATURES 01h
logic [1:0]       present_q;

// ------------------------------------------------------------ the command engine
typedef enum logic [4:0] {
    S_RESET, S_IDLE, S_WAIT,
    S_CHS1, S_CHS2, S_START,
    S_XFER, S_FIN0, S_FIN1, S_FIN2, S_FIN3, S_FIN4,
    S_ID1, S_ID2, S_IDGEN,
    S_IDP1, S_IDP2, S_IDP3
} state_t;
state_t st;

typedef enum logic [2:0] {
    C_NONE, C_READ, C_WRITE, C_VERIFY, C_IDENT, C_SETMULT, C_INITDP, C_FEAT
} cmd_t;
cmd_t       c_kind;
logic       c_dev;
logic [8:0] c_total;                    // sectors (1-256)
logic [8:0] c_mult;                     // DRQ block (1 or the multiple count)
logic [27:0] c_lba;                     // first sector
logic [7:0] c_res;                      // result of a non-data command (error register)
logic       c_diag;                     // EXECUTE DEVICE DIAGNOSTIC (code 01h is no error)

logic [15:0] tmr;                       // us
wire         tmr_zero = tmr == 16'd0;

// data phase
logic       x_bsy, x_drq;
logic [8:0] h_sec;                      // sectors the host has finished
logic [9:0] h_byte;                     // bytes of the current sector
logic [8:0] blk_end;                    // the current DRQ block ends before this sector
logic [8:0] e_next, e_done;             // engine: sectors issued / finished
logic [27:0] e_lba;                     // c_lba + e_next
logic [27:0] x_lba;                     // the sector of the transfer just issued
logic       e_err;
logic [8:0] e_errsec;
logic [7:0] e_errcode;
logic       e_errdf;

// end of a data command
logic [8:0] f_e;                        // sectors done before the end / the error
logic [27:0] f_lba;
logic [7:0] f_code;
logic       f_df;

// prefetch of the two bytes at the host pointer
logic [2:0] pf;                         // 0 = idle, 1-4 = reading
logic       pf_ok;                      // q_lo/q_hi hold the bytes at the pointer
logic [7:0] q_lo, q_hi;

// host write of the high byte one clk after the low one
logic       hw_pend;
logic [7:0] hw_hi;

// IDENTIFY
logic [9:0]  id_idx;
logic [27:0] id_cap;

// INTRQ
logic       ipend;

// iterative multiply-add (12 steps: acc += x * y) and divide (28 steps:
// x / y, quotient in x, remainder in rem)
logic        m_busy, m_div;
logic [27:0] m_x, m_acc;
logic [11:0] m_y;
logic [12:0] m_rem;
logic [4:0]  m_cnt;
wire  [12:0] m_r2 = {m_rem[11:0], m_x[27]};

// buffer port A and the transfer requests
logic [AW-1:0]          a_addr;
logic                   a_we;
logic [7:0]             a_wdata, a_rdata;
logic                   x_start, x_write, x_busy, x_done, x_err;
logic [SLOTS_LOG2-1:0]  x_slot;

// ------------------------------------------------------------ helpers
function automatic logic [8:0] min9(input logic [8:0] a, input logic [8:0] b);
    return a < b ? a : b;
endfunction

wire [8:0]  nsect_total = r_nsect == 8'd0 ? 9'd256 : {1'b0, r_nsect};
wire [27:0] cap_c       = hd_sectors[c_dev];
wire        rst_busy    = st == S_RESET;
wire        drq_phase   = st == S_XFER && x_drq;
wire        bsy_any     = rst_busy || (st != S_IDLE && !drq_phase);
wire        any_present = |hd_present;
wire        is_write    = c_kind == C_WRITE;
wire [9:0]  h_nb        = h_byte + (dat_word ? 10'd2 : 10'd1);
wire        h_step      = drq_phase && (is_write ? dat_wr : dat_rd);
wire [27:0] start_lba   = sel_lba ? c_lba : m_acc;
wire        verify_bad  = start_lba >= cap_c || cap_c - start_lba < 28'(c_total);

// results of SET MULTIPLE MODE / SET FEATURES
logic [7:0] wait_res;
always_comb begin
    wait_res = c_res;
    if (c_kind == C_SETMULT &&
        !(r_nsect == 8'd0 || (r_nsect <= 8'(MULT_MAX) && (r_nsect & (r_nsect - 8'd1)) == 8'd0)))
        wait_res = ER_ABRT;
    if (c_kind == C_FEAT)
        case (r_feat)
            8'h01, 8'h81,                   // 8-bit transfers on / off
            8'h02, 8'h82,                   // write cache (the backend writes through)
            8'h03,                          // transfer mode
            8'h55, 8'hAA,                   // read look-ahead
            8'h66, 8'hCC: ;                 // power-on defaults after reset
            default: wait_res = ER_ABRT;
        endcase
end

// ------------------------------------------------------------ IDENTIFY data
// ATA strings: the first character of a pair in the word's high byte
/* verilator lint_off ASCRANGE */
localparam logic [0:39][7:0] ID_MODEL  = "PC10-III XTIDE disk image               ";
localparam logic [0:19][7:0] ID_SERIAL = "PC10III-DISK-0000000";
localparam logic [0:7][7:0]  ID_FW     = "0.1     ";
/* verilator lint_on ASCRANGE */

wire  [7:0]  id_w  = id_idx[8:1];
wire  [7:0]  id_ws = id_w - 8'd10;          // serial number, words 10-19
wire  [7:0]  id_wf = id_w - 8'd23;          // firmware revision, words 23-26
wire  [7:0]  id_wm = id_w - 8'd27;          // model, words 27-46
logic [15:0] id_word;
always_comb begin
    id_word = 16'h0000;
    case (id_w)
        8'd0:  id_word = 16'h0040;                          // fixed disk
        8'd1:  id_word = hd_cyls[c_dev];
        8'd3:  id_word = 16'(hd_heads[c_dev]);
        8'd4:  id_word = 16'(hd_spt[c_dev]) << 9;           // bytes per track (obsolete)
        8'd5:  id_word = 16'd512;
        8'd6:  id_word = 16'(hd_spt[c_dev]);
        8'd20: id_word = 16'd3;                             // buffer type
        8'd21: id_word = 16'(SLOTS);                        // buffer size (sectors)
        8'd22: id_word = 16'd4;                             // ECC bytes
        8'd47: id_word = 16'h8000 | 16'(MULT_MAX);
        8'd49: id_word = 16'h0200;                          // LBA
        8'd50: id_word = 16'h4000;
        8'd51: id_word = 16'h0200;                          // PIO mode 2 timing
        8'd53: id_word = 16'h0001;                          // words 54-58 valid
        8'd54: id_word = g_cyls[c_dev];
        8'd55: id_word = 16'(g_heads[c_dev]);
        8'd56: id_word = 16'(g_spt[c_dev]);
        8'd57: id_word = id_cap[15:0];
        8'd58: id_word = {4'd0, id_cap[27:16]};
        8'd59: id_word = g_mult[c_dev] != 8'd0 ? {8'h01, g_mult[c_dev]} : 16'h0000;
        8'd60: id_word = hd_sectors[c_dev][15:0];
        8'd61: id_word = {4'd0, hd_sectors[c_dev][27:16]};
        default:
            if (id_w >= 8'd10 && id_w <= 8'd19) begin
                id_word = {ID_SERIAL[{id_ws[3:0], 1'b0}], ID_SERIAL[{id_ws[3:0], 1'b1}]};
                if (id_w == 8'd19) id_word[7:0] = c_dev ? "1" : "0";
            end else if (id_w >= 8'd23 && id_w <= 8'd26)
                id_word = {ID_FW[{id_wf[1:0], 1'b0}], ID_FW[{id_wf[1:0], 1'b1}]};
            else if (id_w >= 8'd27 && id_w <= 8'd46)
                id_word = {ID_MODEL[{id_wm[4:0], 1'b0}], ID_MODEL[{id_wm[4:0], 1'b1}]};
    endcase
end

// ------------------------------------------------------------ the state machine
always_ff @(posedge clk) begin
    x_start <= 1'b0;
    a_we    <= 1'b0;

    // per-device defaults while no medium is present: a new medium starts
    // with its default geometry, multiple mode off and 16-bit transfers
    present_q <= hd_present;
    for (int d = 0; d < 2; d++)
        if (!present_q[d]) begin
            g_cyls[d]  <= hd_cyls[d];
            g_heads[d] <= hd_heads[d];
            g_spt[d]   <= 8'(hd_spt[d]);
            g_mult[d]  <= 8'd0;
            g_mode8[d] <= 1'b0;
        end

    if (us_tick && !tmr_zero) tmr <= tmr - 16'd1;

    // the math unit
    if (m_busy) begin
        if (!m_div) begin
            if (m_y[0]) m_acc <= m_acc + m_x;
            m_x <= m_x << 1;
            m_y <= m_y >> 1;
        end else if (m_r2 >= {1'b0, m_y}) begin
            m_rem <= m_r2 - {1'b0, m_y};
            m_x   <= {m_x[26:0], 1'b1};
        end else begin
            m_rem <= m_r2;
            m_x   <= {m_x[26:0], 1'b0};
        end
        if (m_cnt == 5'd0) m_busy <= 1'b0;
        else m_cnt <= m_cnt - 5'd1;
    end

    // prefetch of the bytes at the host pointer (BRAM: data 1 clk after the address)
    case (pf)
        3'd1: begin a_addr <= {h_sec[SLOTS_LOG2-1:0], h_byte[8:0]};        pf <= 3'd2; end
        3'd2: begin a_addr <= {h_sec[SLOTS_LOG2-1:0], h_byte[8:0] + 9'd1}; pf <= 3'd3; end
        3'd3: begin q_lo <= a_rdata;                                        pf <= 3'd4; end
        3'd4: begin q_hi <= a_rdata;  pf_ok <= 1'b1;                        pf <= 3'd0; end
        default: ;
    endcase

    // high byte of a 16-bit host write
    if (hw_pend) begin
        hw_pend <= 1'b0;
        a_addr  <= a_addr + AW'(1);
        a_wdata <= hw_hi;
        a_we    <= 1'b1;
    end

    // ---------------------------------------------------- engine (data commands)
    // reads run up to SLOTS sectors ahead of the host, writes commit the
    // sectors the host has finished; in order, one transfer at a time
    if (st == S_XFER && !e_err && !x_busy) begin
        if ((c_kind == C_READ && e_next < c_total && 9'(e_next - h_sec) < 9'(SLOTS)) ||
            (is_write && e_next < h_sec)) begin
            if (e_lba >= cap_c) begin
                e_err <= 1'b1;  e_errsec <= e_next;  e_errcode <= ER_IDNF;  e_errdf <= 1'b0;
            end else begin
                x_start <= 1'b1;
                x_write <= is_write;
                x_slot  <= e_next[SLOTS_LOG2-1:0];
                x_lba   <= e_lba;
                e_next  <= e_next + 9'd1;
                e_lba   <= e_lba + 28'd1;
            end
        end
    end
    if (x_done) begin
        e_done <= e_done + 9'd1;
        if (x_err && (!e_err || e_done < e_errsec)) begin
            e_err     <= 1'b1;
            e_errsec  <= e_done;
            e_errcode <= is_write ? ER_ABRT : ER_UNC;
            e_errdf   <= is_write;
        end
    end

    // ---------------------------------------------------- register writes
    if (tf_wr && tf_cs1 && tf_reg == 3'd6) begin
        nien <= tf_wdata[1];
        srst <= tf_wdata[2];
    end
    if (tf_wr && !tf_cs1 && !bsy_any) begin
        case (tf_reg)
            3'd1: r_feat  <= tf_wdata;
            3'd2: r_nsect <= tf_wdata;
            3'd3: r_sect  <= tf_wdata;
            3'd4: r_lcyl  <= tf_wdata;
            3'd5: r_hcyl  <= tf_wdata;
            3'd6: r_sel   <= tf_wdata;
            default: ;
        endcase
    end
    if (tf_rd && !tf_cs1 && tf_reg == 3'd7 && sel_dev == c_dev)
        ipend <= 1'b0;                  // reading Status clears INTRQ

    // ---------------------------------------------------- host data
    if (h_step) begin
        if (is_write) begin
            a_addr  <= {h_sec[SLOTS_LOG2-1:0], h_byte[8:0]};
            a_wdata <= dat_wdata[7:0];
            a_we    <= 1'b1;
            hw_pend <= dat_word;
            hw_hi   <= dat_wdata[15:8];
        end
        pf_ok <= 1'b0;
        if (h_nb >= 10'd512) begin
            h_byte <= 10'd0;
            h_sec  <= h_sec + 9'd1;
            if (h_sec + 9'd1 == blk_end) begin
                // end of a DRQ block
                x_drq <= 1'b0;
                x_bsy <= 1'b1;
                tmr   <= 16'(BLK_US);
                blk_end <= min9(c_total, blk_end + c_mult);
            end else if (!is_write)
                pf <= 3'd1;
        end else begin
            h_byte <= h_nb;
            if (!is_write) pf <= 3'd1;
        end
    end

    // ---------------------------------------------------- the commands
    case (st)
    S_RESET: begin
        if (srst) tmr <= 16'(RESET_US);
        else if (tmr_zero && !x_busy && !m_busy) begin
            // ATA signature, diagnostic code 01h (device 0 passed, device 1
            // passed or absent)
            r_nsect <= 8'd1;  r_sect <= 8'd1;  r_lcyl <= 8'd0;  r_hcyl <= 8'd0;  r_sel <= 8'd0;
            r_err   <= {8'h01, 8'h01};
            r_errbit <= 2'b00;
            r_df    <= 2'b00;
            g_mode8 <= 2'b00;           // a reset restores 16-bit transfers
            st <= S_IDLE;
        end
    end

    S_IDLE: begin
        if (tf_wr && !tf_cs1 && tf_reg == 3'd7 && hd_present[sel_dev]) begin
            c_dev    <= sel_dev;
            c_res    <= 8'h00;
            c_diag   <= 1'b0;
            c_kind   <= C_NONE;
            c_total  <= nsect_total;
            c_mult   <= 9'd1;
            ipend    <= 1'b0;
            r_errbit[sel_dev] <= 1'b0;
            r_df[sel_dev]     <= 1'b0;
            tmr <= 16'(CMD_US);
            st  <= S_WAIT;
            casez (tf_wdata)
                8'h20, 8'h21: begin c_kind <= C_READ;   st <= S_CHS1; end
                8'h30, 8'h31: begin c_kind <= C_WRITE;  st <= S_CHS1; end
                8'h40, 8'h41: begin c_kind <= C_VERIFY; st <= S_CHS1; end
                8'hC4, 8'hC5:
                    if (g_mult[sel_dev] == 8'd0) c_res <= ER_ABRT;
                    else begin
                        c_kind <= tf_wdata[0] ? C_WRITE : C_READ;
                        c_mult <= {1'b0, g_mult[sel_dev]};
                        st <= S_CHS1;
                    end
                8'hC6: c_kind <= C_SETMULT;
                8'h91: begin c_kind <= C_INITDP; st <= S_IDP1; end
                8'hEC: begin c_kind <= C_IDENT; st <= S_ID1; end
                8'hEF: c_kind <= C_FEAT;
                8'h1?, 8'h7?: ;                         // RECALIBRATE, SEEK
                8'h90: begin                            // EXECUTE DEVICE DIAGNOSTIC
                    r_err <= {8'h01, 8'h01};
                    r_nsect <= 8'd1;  r_sect <= 8'd1;  r_lcyl <= 8'd0;  r_hcyl <= 8'd0;  r_sel <= 8'd0;
                    c_res  <= 8'h01;
                    c_diag <= 1'b1;
                end
                8'hE0, 8'hE1, 8'hE2, 8'hE3, 8'hE6,     // standby, idle, sleep: no-ops
                8'h94, 8'h95, 8'h96, 8'h97, 8'h99: ;
                8'hE5, 8'h98: r_nsect <= 8'hFF;         // CHECK POWER MODE: active
                default: c_res <= ER_ABRT;
            endcase
        end
    end

    // non-data commands: BSY for CMD_US, then the result
    S_WAIT: begin
        if (tmr_zero) begin
            if (wait_res == 8'h00)
                case (c_kind)
                    C_SETMULT: g_mult[c_dev] <= r_nsect;
                    C_FEAT:
                        if (r_feat == 8'h01) g_mode8[c_dev] <= 1'b1;
                        else if (r_feat == 8'h81) g_mode8[c_dev] <= 1'b0;
                    default: ;
                endcase
            r_err[c_dev]    <= wait_res;
            r_errbit[c_dev] <= wait_res != 8'h00 && !c_diag;
            ipend <= 1'b1;
            st <= S_IDLE;
        end
    end

    // ------------------------------------------------ read / write / verify
    // CHS -> LBA: (C * heads + H) * spt + S - 1 with the current geometry
    S_CHS1: begin
        if (sel_lba) begin
            c_lba <= {r_sel[3:0], r_hcyl, r_lcyl, r_sect};
            st <= S_START;
        end else if (r_sect == 8'd0 || r_sect > g_spt[c_dev] || 5'(r_sel[3:0]) >= g_heads[c_dev] ||
                     {r_hcyl, r_lcyl} >= g_cyls[c_dev]) begin
            // no such sector: the task file keeps the address
            f_e <= 9'd0;  f_code <= ER_IDNF;  f_df <= 1'b0;
            st <= S_FIN4;
        end else begin
            m_busy <= 1'b1;  m_div <= 1'b0;  m_cnt <= 5'd11;
            m_x <= 28'({r_hcyl, r_lcyl});  m_y <= 12'(g_heads[c_dev]);  m_acc <= 28'(r_sel[3:0]);
            st <= S_CHS2;
        end
    end
    S_CHS2: if (!m_busy) begin
        m_busy <= 1'b1;  m_div <= 1'b0;  m_cnt <= 5'd11;
        m_x <= m_acc;  m_y <= 12'(g_spt[c_dev]);  m_acc <= 28'(r_sect - 8'd1);
        st <= S_START;
    end
    S_START: if (!m_busy) begin
        c_lba <= start_lba;
        h_sec <= 9'd0;  h_byte <= 10'd0;
        e_next <= 9'd0;  e_done <= 9'd0;  e_lba <= start_lba;  e_err <= 1'b0;
        blk_end <= min9(c_total, c_mult);
        x_bsy <= 1'b1;  x_drq <= 1'b0;  pf_ok <= 1'b0;
        tmr <= 16'(CMD_US);
        if (c_kind == C_VERIFY) begin
            // no data: the whole range must exist
            f_e <= start_lba >= cap_c ? 9'd0 : verify_bad ? 9'(cap_c - start_lba) : c_total;
            f_code <= verify_bad ? ER_IDNF : 8'h00;
            f_df <= 1'b0;
            st <= S_FIN0;
        end else
            st <= S_XFER;
    end

    S_XFER: begin
        if (x_bsy && tmr_zero) begin
            if (is_write) begin
                if (e_err) begin
                    f_e <= e_errsec;  f_code <= e_errcode;  f_df <= e_errdf;
                    st <= S_FIN0;
                end else if (h_sec == c_total) begin
                    if (e_done == c_total) begin
                        f_e <= c_total;  f_code <= 8'h00;  f_df <= 1'b0;
                        st <= S_FIN0;
                    end
                end else if (9'(blk_end - e_done) <= 9'(SLOTS)) begin
                    x_bsy <= 1'b0;
                    x_drq <= 1'b1;
                    if (h_sec != 9'd0) ipend <= 1'b1;   // not before the first block
                end
            end else begin
                // read (and IDENTIFY, whose sector is already in slot 0)
                if (h_sec == c_total) begin
                    f_e <= c_total;  f_code <= 8'h00;  f_df <= 1'b0;
                    st <= S_FIN0;
                end else if (e_err && e_errsec < blk_end) begin
                    f_e <= e_errsec;  f_code <= e_errcode;  f_df <= 1'b0;
                    st <= S_FIN0;
                end else if (e_done >= blk_end) begin
                    if (pf_ok) begin
                        x_bsy <= 1'b0;
                        x_drq <= 1'b1;
                        ipend <= 1'b1;
                    end else if (pf == 3'd0)
                        pf <= 3'd1;
                end
            end
        end
        // a failed write ends the data phase at once
        if (is_write && e_err && x_drq) begin
            x_drq <= 1'b0;
            x_bsy <= 1'b1;
        end
    end

    // end of a data command: wait for the engine; the task file then holds
    // the last sector transferred (or the failing one) and the sectors left
    S_FIN0: if (!x_busy) begin
        x_bsy <= 1'b1;  x_drq <= 1'b0;
        f_lba <= c_lba + 28'(f_e) - (f_code == 8'h00 ? 28'd1 : 28'd0);
        st <= S_FIN1;
    end
    S_FIN1: begin
        if (c_kind == C_IDENT) st <= S_FIN4;
        else if (sel_lba) begin
            r_sect <= f_lba[7:0];  r_lcyl <= f_lba[15:8];  r_hcyl <= f_lba[23:16];
            r_sel[3:0] <= f_lba[27:24];
            st <= S_FIN4;
        end else begin
            // LBA -> CHS: sector = lba % spt + 1, then lba / spt -> cylinder, head
            m_busy <= 1'b1;  m_div <= 1'b1;  m_cnt <= 5'd27;
            m_x <= f_lba;  m_y <= 12'(g_spt[c_dev]);  m_rem <= 13'd0;
            st <= S_FIN2;
        end
    end
    S_FIN2: if (!m_busy) begin
        r_sect <= m_rem[7:0] + 8'd1;
        m_busy <= 1'b1;  m_div <= 1'b1;  m_cnt <= 5'd27;
        m_y <= 12'(g_heads[c_dev]);  m_rem <= 13'd0;       // m_x: the quotient
        st <= S_FIN3;
    end
    S_FIN3: if (!m_busy) begin
        r_sel[3:0] <= m_rem[3:0];
        r_lcyl <= m_x[7:0];
        r_hcyl <= m_x[15:8];
        st <= S_FIN4;
    end
    S_FIN4: begin
        if (c_kind != C_IDENT) r_nsect <= 8'(c_total - f_e);
        r_err[c_dev]    <= f_code;
        r_errbit[c_dev] <= f_code != 8'h00;
        r_df[c_dev]     <= f_df;
        // reads interrupt per DRQ block only; writes and the rest at the end
        if (f_code != 8'h00 || (c_kind != C_READ && c_kind != C_IDENT)) ipend <= 1'b1;
        x_bsy <= 1'b0;
        st <= S_IDLE;
    end

    // ------------------------------------------------ IDENTIFY DEVICE
    // current capacity = cylinders * (heads * spt), then 256 words into slot 0
    S_ID1: begin
        m_busy <= 1'b1;  m_div <= 1'b0;  m_cnt <= 5'd11;
        m_x <= 28'(g_spt[c_dev]);  m_y <= 12'(g_heads[c_dev]);  m_acc <= 28'd0;
        st <= S_ID2;
    end
    S_ID2: if (!m_busy) begin
        m_busy <= 1'b1;  m_div <= 1'b0;  m_cnt <= 5'd11;
        m_x <= 28'(g_cyls[c_dev]);  m_y <= m_acc[11:0];  m_acc <= 28'd0;
        id_idx <= 10'd0;
        st <= S_IDGEN;
    end
    S_IDGEN: if (!m_busy) begin
        if (id_idx == 10'd0) id_cap <= m_acc;
        if (id_idx == 10'd512) begin
            c_total <= 9'd1;  c_mult <= 9'd1;  c_lba <= 28'd0;
            h_sec <= 9'd0;  h_byte <= 10'd0;  blk_end <= 9'd1;
            e_next <= 9'd1;  e_done <= 9'd1;  e_err <= 1'b0;
            x_bsy <= 1'b1;  x_drq <= 1'b0;  pf_ok <= 1'b0;
            tmr <= 16'(CMD_US);
            st <= S_XFER;
        end else begin
            a_addr  <= {SLOTS_LOG2'(0), id_idx[8:0]};
            a_wdata <= id_idx[0] ? id_word[15:8] : id_word[7:0];
            a_we    <= 1'b1;
            id_idx  <= id_idx + 10'd1;
        end
    end

    // ------------------------------------------------ INITIALIZE DEVICE PARAMETERS
    // heads = DH[3:0] + 1, spt = sector count, cylinders = capacity / (heads * spt)
    S_IDP1: begin
        if (r_nsect == 8'd0) begin
            c_res <= ER_ABRT;
            st <= S_WAIT;
        end else begin
            m_busy <= 1'b1;  m_div <= 1'b0;  m_cnt <= 5'd11;
            m_x <= 28'(r_nsect);  m_y <= 12'(r_sel[3:0]) + 12'd1;  m_acc <= 28'd0;
            st <= S_IDP2;
        end
    end
    S_IDP2: if (!m_busy) begin
        m_busy <= 1'b1;  m_div <= 1'b1;  m_cnt <= 5'd27;
        m_x <= cap_c;  m_y <= m_acc[11:0];  m_rem <= 13'd0;
        st <= S_IDP3;
    end
    S_IDP3: if (!m_busy) begin
        g_heads[c_dev] <= 5'(r_sel[3:0]) + 5'd1;
        g_spt[c_dev]   <= r_nsect;
        g_cyls[c_dev]  <= m_x[27:16] != 12'd0 ? 16'hFFFF : m_x[15:0];
        st <= S_WAIT;                   // tmr has run out: the result at once
    end

    default: st <= S_RESET;
    endcase

    // ---------------------------------------------------- resets
    if (tf_wr && tf_cs1 && tf_reg == 3'd6 && tf_wdata[2]) begin
        // SRST: both devices; a sector transfer in flight finishes first
        st <= S_RESET;
        tmr <= 16'(RESET_US);
        ipend <= 1'b0;
        x_bsy <= 1'b0;  x_drq <= 1'b0;
        pf <= 3'd0;
    end
    if (reset) begin
        st <= S_RESET;
        tmr <= 16'(RESET_US);
        r_feat <= 8'd0;  r_nsect <= 8'd1;  r_sect <= 8'd1;  r_lcyl <= 8'd0;  r_hcyl <= 8'd0;  r_sel <= 8'd0;
        nien <= 1'b0;  srst <= 1'b0;
        r_err <= {8'h01, 8'h01};
        r_errbit <= 2'b00;  r_df <= 2'b00;
        present_q <= 2'b00;
        c_dev <= 1'b0;  c_kind <= C_NONE;
        ipend <= 1'b0;
        x_bsy <= 1'b0;  x_drq <= 1'b0;
        e_err <= 1'b0;
        pf <= 3'd0;  pf_ok <= 1'b0;
        hw_pend <= 1'b0;
        m_busy <= 1'b0;
    end
end

// ------------------------------------------------------------ register reads
logic [7:0] status;
always_comb begin
    if (rst_busy)                                   status = ST_BSY;
    else if (!hd_present[sel_dev])                  status = 8'h00;   // device 0 answers for a missing device 1
    else if (st != S_IDLE && sel_dev == c_dev)      status = drq_phase ? (ST_DRDY | ST_DSC | ST_DRQ) : ST_BSY;
    else status = ST_DRDY | ST_DSC | (r_df[sel_dev] ? ST_DF : 8'h00) | (r_errbit[sel_dev] ? ST_ERR : 8'h00);
end

always_comb begin
    tf_rdata = 8'hFF;
    tf_drive = 1'b0;
    if (!any_present) begin
        // no drive on the cable: only the pull-down on DD7 (BSY reads 0)
        tf_drive = !tf_cs1 || tf_reg == 3'd6;
        tf_rdata = 8'h7F;
    end else if (!tf_cs1) begin
        tf_drive = 1'b1;
        case (tf_reg)
            3'd1: tf_rdata = r_err[sel_dev];
            3'd2: tf_rdata = r_nsect;
            3'd3: tf_rdata = r_sect;
            3'd4: tf_rdata = r_lcyl;
            3'd5: tf_rdata = r_hcyl;
            3'd6: tf_rdata = {1'b1, r_sel[6], 1'b1, r_sel[4:0]};
            3'd7: tf_rdata = status;
            default: tf_drive = 1'b0;           // the data register is the card's
        endcase
    end else if (tf_reg == 3'd6) begin
        tf_drive = 1'b1;
        tf_rdata = status;                      // alternate status
    end
end

assign dat_q  = any_present ? {q_hi, q_lo} : 16'h7F7F;
assign mode8  = g_mode8[sel_dev];
assign intrq  = ipend && !nien && sel_dev == c_dev && hd_present[c_dev];
assign active = (st != S_IDLE && st != S_RESET) || x_busy;

// ------------------------------------------------------------ the buffer
hdc_secbuf #(.SLOTS_LOG2(SLOTS_LOG2)) u_buf (
    .clk         (clk),
    .reset       (reset),
    .a_addr      (a_addr),
    .a_we        (a_we),
    .a_wdata     (a_wdata),
    .a_rdata     (a_rdata),
    .x_start     (x_start),
    .x_write     (x_write),
    .x_slot      (x_slot),
    .x_lba       (x_lba),
    .x_drive     (c_dev),
    .x_busy      (x_busy),
    .x_done      (x_done),
    .x_err       (x_err),
    .sp_req      (sp_req),
    .sp_write    (sp_write),
    .sp_drive    (sp_drive),
    .sp_lba      (sp_lba),
    .sp_rd_valid (sp_rd_valid),
    .sp_rd_data  (sp_rd_data),
    .sp_wr_valid (sp_wr_valid),
    .sp_wr_data  (sp_wr_data),
    .sp_wr_ready (sp_wr_ready),
    .sp_done     (sp_done),
    .sp_err      (sp_err)
);

endmodule
