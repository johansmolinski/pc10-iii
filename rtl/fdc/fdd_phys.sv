// fdd_phys.sv - a real 3.5" DD drive (the MEGA65's internal drive) behind the
// FDC card's sector port, as drive B: (doc/fdc.md section 10).
//
// The 765 model (upd765.sv) keeps its synthetic disk surface: rotation, ID
// fields, gaps, step timing and every status byte are the model's, exactly as
// for an image. What the drive adds is the data: each sector the model asks
// for is read from (or written to) the real disk, at sector level:
//   * the head follows the model: every step of drive B: in the model
//     (fdc_card's drv_step while B: is selected) is passed on to the drive at
//     once, so the real head moves when the PC seeks, at the PC's step rate
//     (at most one pulse per STEP_RATE). The real position is tracked in cur
//     (0..79), homed by stepping out to TRK0 when it is not known (power-up,
//     switching to the drive). A request whose cylinder differs from cur
//     moves the head there itself (a PC reset puts the model's heads to 0
//     without steps: the real head then follows to 0 as well);
//   * read: wait for the head to settle (SETTLE after the last step), select
//     the side, then decode the track (fdd_mfm_rd.sv) until the ID field with
//     the request's C, H, R and N = 2 passes with a good CRC; its data field
//     (DAM FB or F8 within DAM_WIN) is streamed to the card byte by byte as it
//     is decoded; a bad data CRC ends with sp_err (the 765 model reports a
//     data error, as a real 765 would; the BIOS and DOS retry);
//   * write: the same search; GAP2_T after the ID field (22 bytes of gap 2, as
//     the 765 does) WGATE opens and the data field is written (fdd_mfm_wr.sv):
//     12 x 00, 3 x A1*, FB, the card's 512 bytes, CRC, one 4E;
//   * format: the model commits each sector of a FORMAT TRACK with its fill
//     byte (sp_fmt = 1). The first such commit of a command writes the whole
//     track from index to index in the standard layout (the model's: GAP4a 80,
//     sync, IAM, GAP1 50, sectors 1..9 with C/H of the commit, N = 2, GAP3 80,
//     the fill byte); the others of the same track and command are taken
//     without touching the disk. (A real FORMAT TRACK also writes the IDs the
//     host gave; the model stores only the standard layout, and so does this.)
//   * not found: an ID field that never passes within three index pulses
//     ends with sp_err; when IDs of another cylinder passed instead, the head
//     is homed and moved once more first. No index for NOIDX_TO (no disk, a
//     dead motor) ends with sp_err too.
//   * the drive: motor on while the PC's motor bit of B: is set or a request
//     runs; a request waits until the motor has run SPINUP; selected while the motor runs, a head
//     movement runs or the head is not homed. present = an index pulse within
//     PRES_TO (the model's disk is in: it turns only then), wp = the WPT pin
//     (latched while selected).
//   * enable = 0 (B: is an image): the pins stay inactive, a request ends with
//     sp_err, the head position is forgotten.
//
// Clock: the PC's clk (28.63636 MHz); the constants are in microseconds and
// milliseconds of CLK_HZ.
//
// GPL-3.0-or-later, pc10-iii.

module fdd_phys #(
    parameter int CLK_HZ     = 28_636_364,
    parameter int CELL_NUM   = 11,          // fdd_mfm_wr: cells per clk = 11/630 at 28.63636 MHz
    parameter int CELL_DEN   = 630,
    parameter int SPT        = 9,           // sectors per track written by FORMAT
    parameter int GAP3       = 80,          // GAP3 written by FORMAT (DOS: 0x50 for 720K)
    parameter int PRECOMP_CYL = 40,         // write precompensation from this cylinder on
    parameter int STEP_RATE_US = 3000,      // at most one step pulse per 3 ms
    parameter int HOME_RATE_US = 6000,      // homing: one step per 6 ms (the XT BIOS's rate)
    parameter int HOME_MAX   = 90,          // homing steps at most (no TRK0: take 0)
    parameter int SETTLE_US  = 18000,       // head settle after the last step
    parameter int SPINUP_US  = 500000,      // motor started by a request
    parameter int PRES_US    = 400000,      // present: an index pulse within this time
    parameter int NOIDX_US   = 1000000,     // a request without index pulses gives up
    parameter int DAM_US     = 2500,        // the data mark must follow the ID within this time
    parameter int GAP2_US    = 702          // write: from the ID's last CRC byte to WGATE
) (
    input  logic        clk,
    input  logic        reset,              // power-up: the head position is unknown
    input  logic        pc_reset,           // the PC's reset: the model's heads go to 0
    input  logic        enable,             // B: is the internal drive

    // the FDC card's drive B:
    input  logic        motor_b,            // DOR motor bit of B:
    input  logic        select_b,           // B: selected (DOR select + motor)
    input  logic        step,               // the selected drive's head moved (one clk)
    input  logic        step_in,
    input  logic        cmd_active,         // the 765 executes a command (fdc_active)

    // the sector port, requests for B: only (doc/fdc.md section 5)
    input  logic        sp_req,
    input  logic        sp_write,
    input  logic        sp_fmt,             // a FORMAT TRACK commit (sp_write = 1)
    input  logic [7:0]  sp_cyl,
    input  logic        sp_head,
    input  logic [7:0]  sp_sector,
    output logic        sp_rd_valid,
    output logic [7:0]  sp_rd_data,
    input  logic        sp_wr_valid,
    input  logic [7:0]  sp_wr_data,
    output logic        sp_wr_ready,
    output logic        sp_done,
    output logic        sp_err,

    // the medium, for the card's img_present/img_wp of B:
    output logic        present,
    output logic        wp,

    // the drive (34-pin interface, active low; f_stepdir_n = 1: outward)
    output logic        f_motor_n,
    output logic        f_select_n,
    output logic        f_stepdir_n,
    output logic        f_step_n,
    output logic        f_side1_n,
    output logic        f_wdata_n,
    output logic        f_wgate_n,
    input  logic        f_index_n,
    input  logic        f_track0_n,
    input  logic        f_wpt_n,
    input  logic        f_rdata_n,

    // state (testbench, diagnostics)
    output logic [6:0]  cyl_o,
    output logic        known_o,
    output logic        busy_o
);

function automatic int us2clk(input int us);
    return int'((longint'(CLK_HZ) * longint'(us)) / 64'd1_000_000);
endfunction
localparam int T_PULSE   = us2clk(8);
localparam int T_RATE    = us2clk(STEP_RATE_US);
localparam int T_HOME    = us2clk(HOME_RATE_US);
localparam int T_SETTLE  = us2clk(SETTLE_US);
localparam int T_SEL     = us2clk(50);
localparam int T_SIDE    = us2clk(100);
localparam int T_SPINUP  = us2clk(SPINUP_US);
localparam int T_PRES    = us2clk(PRES_US);
localparam int T_NOIDX   = us2clk(NOIDX_US);
localparam int T_DAM     = us2clk(DAM_US);
localparam int T_GAP2    = us2clk(GAP2_US);

function automatic logic [15:0] crc_byte(input logic [15:0] c, input logic [7:0] b);
    logic [15:0] x;
    x = c;
    for (int i = 7; i >= 0; i--)
        x = {x[14:0], 1'b0} ^ ((x[15] ^ b[i]) ? 16'h1021 : 16'h0000);
    return x;
endfunction
localparam logic [15:0] CRC_A1 = 16'hCDB4;   // after FFFF, A1, A1, A1

// ------------------------------------------------------------ read and write chains
logic       trk0, wpt, index_edge;
logic       rb_valid, rb_sync;
logic [7:0] rb_data;

fdd_mfm_rd #(
    .CELL_Q  ((CLK_HZ * 32 + 500_000) / 1_000_000),          // 2 us in 1/16 clks
    .GLITCH  (us2clk(1) * 32 / 100),                          // 320 ns
    .IDX_MIN (us2clk(200))
) u_rd (
    .clk        (clk),
    .reset      (reset),
    .f_index_n  (f_index_n),
    .f_track0_n (f_track0_n),
    .f_wpt_n    (f_wpt_n),
    .f_rdata_n  (f_rdata_n),
    .trk0       (trk0),
    .wpt        (wpt),
    .index_edge (index_edge),
    .byte_valid (rb_valid),
    .byte_sync  (rb_sync),
    .byte_data  (rb_data)
);

logic       w_push, w_room, w_busy, w_reset;
logic [7:0] w_data;
logic [1:0] w_kind;
logic       w_precomp;

fdd_mfm_wr #(
    .CELL_NUM (CELL_NUM),
    .CELL_DEN (CELL_DEN),
    .LAUNCH   (us2clk(1)),
    .PULSE    (us2clk(1) / 2),
    .PRECOMP  ((us2clk(1) * 14 + 50) / 100)
) u_wr (
    .clk        (clk),
    .reset      (w_reset),
    .push       (w_push),
    .byte_data  (w_data),
    .byte_kind  (w_kind),
    .room       (w_room),
    .precomp_en (w_precomp),
    .busy       (w_busy),
    .f_wdata_n  (f_wdata_n),
    .f_wgate_n  (f_wgate_n)
);

// ------------------------------------------------------------ drive select, motor, medium
logic        req_busy;                  // a request is being served (from the request FSM)
logic        mv_need;                   // the head must move (from the mover)
logic        sel, mot;
logic [$clog2(us2clk(50) + 1) - 1:0] sel_cnt;
logic        sel_ok;                    // selected long enough: TRK0, WPT valid
logic [$clog2(us2clk(PRES_US) + 1) - 1:0] pres_cnt;
logic [$clog2(us2clk(SPINUP_US) + 1) - 1:0] mot_cnt;
logic        wp_q;

assign mot = enable && (motor_b || req_busy);
assign sel = enable && (motor_b || req_busy || mv_need);

always_ff @(posedge clk) begin
    if (reset || !sel) begin
        sel_cnt <= '0;
        sel_ok  <= 1'b0;
    end else if (sel_cnt == ($bits(sel_cnt))'(T_SEL))
        sel_ok <= 1'b1;
    else
        sel_cnt <= sel_cnt + 1'b1;

    if (reset || !mot)
        mot_cnt <= '0;
    else if (mot_cnt != ($bits(mot_cnt))'(T_SPINUP))
        mot_cnt <= mot_cnt + 1'b1;

    if (reset || !enable)
        pres_cnt <= '0;
    else if (sel && mot && index_edge)
        pres_cnt <= ($bits(pres_cnt))'(T_PRES);
    else if (pres_cnt != '0)
        pres_cnt <= pres_cnt - 1'b1;

    if (reset || !enable)
        wp_q <= 1'b0;
    else if (sel_ok)
        wp_q <= wpt;
end
assign present = pres_cnt != '0;
assign wp      = wp_q;

// ------------------------------------------------------------ the head
// target: drive B:'s head in the model (its steps while B: is selected; 0 at
// a PC reset, as the model's), at most 79
logic [6:0]  target;
logic        want_req;                  // the request FSM moves the head to req_cyl
logic [6:0]  req_cyl7;
wire  [6:0]  want = want_req ? req_cyl7 : target;
always_ff @(posedge clk) begin
    if (reset || pc_reset)
        target <= 7'd0;
    else if (step && select_b) begin
        if (step_in) begin
            if (target != 7'd79) target <= target + 7'd1;
        end else if (target != 7'd0)
            target <= target - 7'd1;
    end
end

typedef enum logic [2:0] {MV_IDLE, MV_SETUP, MV_PULSE, MV_HOLD, MV_GAP} mv_t;
logic        step_q = 1'b1, dir_q = 1'b1;  // the pins, inactive at power-up
assign f_step_n    = step_q;
assign f_stepdir_n = dir_q;
mv_t         mv;
logic [6:0]  cur;
logic        known;
logic        mv_out;                    // the step being made goes outward
logic        homing_step;
logic [6:0]  home_cnt;
logic [$clog2(us2clk(HOME_RATE_US) + 1) - 1:0] mv_cnt;
logic [$clog2(us2clk(SETTLE_US) + 1) - 1:0]    since;   // clks since the last step pulse
logic        rehome;                    // from the request FSM: forget the position

logic        settled;
assign mv_need = !known || cur != want || mv != MV_IDLE;
assign settled = mv == MV_IDLE && known && cur == want && since == ($bits(since))'(T_SETTLE);

always_ff @(posedge clk) begin
    if (mv == MV_PULSE)
        since <= '0;
    else if (since != ($bits(since))'(T_SETTLE))
        since <= since + 1'b1;

    if (reset || !enable) begin
        mv          <= MV_IDLE;
        known       <= 1'b0;
        cur         <= 7'd0;
        home_cnt    <= 7'd0;
        step_q      <= 1'b1;
        dir_q       <= 1'b1;
        mv_out      <= 1'b1;
    end else begin
        case (mv)
        MV_IDLE: begin
            mv_cnt <= '0;
            if (rehome) begin
                known    <= 1'b0;
                home_cnt <= 7'd0;
            end else if (!known) begin
                if (sel_ok) begin
                    if (trk0 || home_cnt == 7'(HOME_MAX)) begin
                        known <= 1'b1;
                        cur   <= 7'd0;
                    end else begin
                        mv_out      <= 1'b1;
                        homing_step <= 1'b1;
                        home_cnt    <= home_cnt + 7'd1;
                        dir_q       <= 1'b1;
                        mv          <= MV_SETUP;
                    end
                end
            end else if (mv_out && trk0 && cur != 7'd0 && sel_ok)
                cur <= 7'd0;            // resync at TRK0 (only after an outward step)
            else if (cur != want && sel_ok) begin
                mv_out      <= want < cur;
                homing_step <= 1'b0;
                dir_q       <= want < cur;
                mv          <= MV_SETUP;
            end
        end
        MV_SETUP: if (mv_cnt == ($bits(mv_cnt))'(T_PULSE)) begin
            mv_cnt   <= '0;
            step_q <= 1'b0;
            mv       <= MV_PULSE;
        end else
            mv_cnt <= mv_cnt + 1'b1;
        MV_PULSE: if (mv_cnt == ($bits(mv_cnt))'(T_PULSE)) begin
            mv_cnt   <= '0;
            step_q <= 1'b1;
            mv       <= MV_HOLD;
            if (known) begin
                if (mv_out) begin
                    if (cur != 7'd0) cur <= cur - 7'd1;
                end else if (cur != 7'd79)
                    cur <= cur + 7'd1;
            end
        end else
            mv_cnt <= mv_cnt + 1'b1;
        MV_HOLD: if (mv_cnt == ($bits(mv_cnt))'(T_PULSE)) begin
            mv_cnt <= ($bits(mv_cnt))'(3 * T_PULSE);
            mv     <= MV_GAP;
        end else
            mv_cnt <= mv_cnt + 1'b1;
        MV_GAP: if (mv_cnt >= ($bits(mv_cnt))'(homing_step ? T_HOME : T_RATE)) begin
            mv <= MV_IDLE;
        end else
            mv_cnt <= mv_cnt + 1'b1;
        default: mv <= MV_IDLE;
        endcase
    end
end

assign cyl_o   = cur;
assign known_o = known;
assign f_motor_n  = !mot;
assign f_select_n = !sel;

// ------------------------------------------------------------ requests
typedef enum logic [4:0] {
    R_IDLE, R_DRAIN, R_SPIN, R_SEEK, R_SIDE, R_SEARCH, R_ID, R_DAM, R_DATA,
    R_GAP2, R_WRITE, R_FIDX, R_FMT, R_WEND, R_FIN, R_LOW
} r_t;
r_t          rs;
logic        q_write, q_fmt, q_head, q_err;
logic [7:0]  q_cyl, q_sec;
logic [7:0]  fill;
logic [9:0]  taken;                     // card bytes taken
logic        cb_valid;                  // a card byte waits in cb
logic [7:0]  cb;
logic [1:0]  nsync;                     // consecutive A1 syncs (3 = a mark follows)
logic [2:0]  id_i;
logic [7:0]  id [4];
logic [15:0] crc;
logic [9:0]  dcnt;
logic [1:0]  idx_cnt;
logic        wrong_cyl, retried;
logic [$clog2(us2clk(NOIDX_US) + 1) - 1:0] tmr;
logic [$clog2(us2clk(NOIDX_US) + 1) - 1:0] noidx;
logic        fmt_valid;                 // a track formatted by this command
logic [7:0]  fmt_cyl;
logic        fmt_head;
logic        side;

// the write program: a byte counter through the fields
typedef enum logic [3:0] {
    F_GAP4A, F_SYNC0, F_IAM, F_FC, F_GAP1, F_SSYNC, F_IDAM, F_FE, F_ID, F_IDCRC,
    F_GAP2, F_DSYNC, F_DAM, F_FB, F_DATA, F_DCRC
} f_t;
logic        f_gap3, f_tail;            // GAP3 after a data field, GAP4b until index
f_t          fs;
logic [9:0]  fcnt;
logic [3:0]  fsec;
logic        stop_push;

assign req_busy = rs != R_IDLE && rs != R_LOW && rs != R_FIN;
assign req_cyl7 = q_cyl > 8'd79 ? 7'd79 : q_cyl[6:0];
assign busy_o   = req_busy;
assign f_side1_n = !side;
assign w_precomp = q_cyl >= 8'(PRECOMP_CYL);
assign w_reset   = reset || !enable;

// card write data: one byte ahead
assign sp_wr_ready = !cb_valid && taken != 10'd512 && q_write &&
                     (rs == R_DRAIN || rs == R_SPIN || rs == R_SEEK || rs == R_SIDE ||
                      rs == R_SEARCH || rs == R_ID || rs == R_GAP2 || rs == R_WRITE);

// the next byte of a write: data field (sector write) or the track (format)
logic [7:0] nb_data;
logic [1:0] nb_kind;
logic       nb_crc_rst, nb_crc_upd, nb_ok;
always_comb begin
    nb_data = 8'h4E;  nb_kind = 2'd0;  nb_crc_rst = 1'b0;  nb_crc_upd = 1'b0;
    nb_ok = 1'b1;
    if (f_gap3 || f_tail) nb_data = 8'h4E;
    else case (fs)
        F_GAP4A, F_GAP1, F_GAP2: nb_data = 8'h4E;
        F_SYNC0, F_SSYNC, F_DSYNC: nb_data = 8'h00;
        F_IAM:   begin nb_data = 8'hC2; nb_kind = 2'd2; end
        F_FC:    nb_data = 8'hFC;
        F_IDAM, F_DAM: begin
            nb_data = 8'hA1; nb_kind = 2'd1; nb_crc_upd = 1'b1;
            nb_crc_rst = fcnt == 10'd0;
        end
        F_FE:    begin nb_data = 8'hFE; nb_crc_upd = 1'b1; end
        F_FB:    begin nb_data = 8'hFB; nb_crc_upd = 1'b1; end
        F_ID: begin
            case (fcnt[1:0])
                2'd0: nb_data = q_cyl;
                2'd1: nb_data = {7'd0, q_head};
                2'd2: nb_data = 8'(fsec) + 8'd1;
                default: nb_data = 8'd2;
            endcase
            nb_crc_upd = 1'b1;
        end
        F_DATA: begin
            nb_data = q_fmt ? fill : cb;
            nb_ok   = q_fmt || cb_valid;
            nb_crc_upd = 1'b1;
        end
        F_IDCRC, F_DCRC: nb_data = fcnt[0] ? crc[7:0] : crc[15:8];
        default: ;
    endcase
end

always_ff @(posedge clk) begin
    sp_rd_valid <= 1'b0;
    sp_done     <= 1'b0;
    sp_err      <= 1'b0;
    w_push      <= 1'b0;
    rehome      <= 1'b0;

    if (!cmd_active) fmt_valid <= 1'b0;

    // card bytes
    if (sp_wr_valid && sp_wr_ready) begin
        cb       <= sp_wr_data;
        cb_valid <= 1'b1;
        taken    <= taken + 10'd1;
        if (taken == 10'd0) fill <= sp_wr_data;
    end

    // index pulses and the no-index timer while a request runs
    if (index_edge) noidx <= '0;
    else if (noidx != ($bits(noidx))'(T_NOIDX)) noidx <= noidx + 1'b1;

    if (reset) begin
        rs        <= R_IDLE;
        want_req  <= 1'b0;
        side      <= 1'b0;
        fmt_valid <= 1'b0;
        cb_valid  <= 1'b0;
    end else begin
        case (rs)
        R_IDLE: begin
            want_req  <= 1'b0;
            cb_valid  <= 1'b0;
            taken     <= 10'd0;
            q_err     <= 1'b0;
            wrong_cyl <= 1'b0;
            retried   <= 1'b0;
            if (sp_req) begin
                q_write <= sp_write;
                q_fmt   <= sp_write && sp_fmt;
                q_cyl   <= sp_cyl;
                q_head  <= sp_head;
                q_sec   <= sp_sector;
                if (!enable) begin
                    q_err <= 1'b1;
                    rs    <= R_FIN;
                end else if (sp_write && sp_fmt)
                    rs <= R_DRAIN;      // the fill byte first
                else
                    rs <= R_SPIN;
            end
        end

        R_DRAIN: begin                  // format: take the card's 512 bytes
            if (cb_valid) cb_valid <= 1'b0;
            if (taken == 10'd512 && !cb_valid) begin
                if (fmt_valid && fmt_cyl == q_cyl && fmt_head == q_head)
                    rs <= R_FIN;        // this track is formatted already
                else
                    rs <= R_SPIN;
            end
        end

        R_SPIN: begin                   // the motor (on with req_busy) up to speed
            want_req <= 1'b1;
            tmr      <= '0;
            if (mot_cnt == ($bits(mot_cnt))'(T_SPINUP))
                rs <= R_SEEK;
        end

        R_SEEK: begin                   // (a few clks first: a rehome takes effect)
            if (settled && tmr > ($bits(tmr))'(3)) begin
                tmr  <= '0;
                side <= q_head;
                rs   <= R_SIDE;
            end else if (tmr <= ($bits(tmr))'(3))
                tmr <= tmr + 1'b1;
        end

        R_SIDE: begin
            if (tmr == ($bits(tmr))'(T_SIDE)) begin
                tmr     <= '0;
                nsync   <= 2'd0;
                idx_cnt <= 2'd0;
                noidx   <= '0;
                if ((q_write && wp_q) || q_cyl > 8'd79) begin
                    q_err <= 1'b1;
                    rs    <= R_FIN;
                end else
                    rs <= q_fmt ? R_FIDX : R_SEARCH;
            end else
                tmr <= tmr + 1'b1;
        end

        R_SEARCH, R_ID: begin
            if (index_edge) begin
                idx_cnt <= idx_cnt + 2'd1;
                if (idx_cnt == 2'd2) begin
                    if (wrong_cyl && !retried) begin
                        retried <= 1'b1;
                        rehome  <= 1'b1;
                        tmr     <= '0;
                        rs      <= R_SEEK;
                    end else begin
                        q_err <= 1'b1;
                        rs    <= R_FIN;
                    end
                end
            end
            if (noidx == ($bits(noidx))'(T_NOIDX)) begin
                q_err <= 1'b1;
                rs    <= R_FIN;
            end
            if (rb_valid && !(index_edge && idx_cnt == 2'd2)) begin
                if (rb_sync) begin
                    if (nsync != 2'd3) nsync <= nsync + 2'd1;
                    if (rs == R_ID) rs <= R_SEARCH;           // a sync inside the ID field
                end else begin
                    nsync <= 2'd0;
                    if (rs == R_SEARCH) begin
                        if (nsync == 2'd3 && rb_data == 8'hFE) begin
                            crc  <= crc_byte(CRC_A1, 8'hFE);
                            id_i <= 3'd0;
                            rs   <= R_ID;
                        end
                    end else begin
                        crc <= crc_byte(crc, rb_data);
                        if (id_i < 3'd4) id[id_i[1:0]] <= rb_data;
                        id_i <= id_i + 3'd1;
                        if (id_i == 3'd5) begin
                            rs <= R_SEARCH;
                            if (crc_byte(crc, rb_data) == 16'h0000) begin
                                if (id[0] == q_cyl && id[1] == {7'd0, q_head} &&
                                    id[2] == q_sec && id[3] == 8'd2) begin
                                    tmr <= '0;
                                    rs  <= q_write ? R_GAP2 : R_DAM;
                                end else if (id[0] != q_cyl)
                                    wrong_cyl <= 1'b1;
                            end
                        end
                    end
                end
            end
        end

        R_DAM: begin
            tmr <= tmr + 1'b1;
            if (tmr == ($bits(tmr))'(T_DAM)) begin
                q_err <= 1'b1;
                rs    <= R_FIN;
            end else if (rb_valid) begin
                if (rb_sync) begin
                    if (nsync != 2'd3) nsync <= nsync + 2'd1;
                end else begin
                    nsync <= 2'd0;
                    if (nsync == 2'd3) begin
                        if (rb_data == 8'hFB || rb_data == 8'hF8) begin
                            crc  <= crc_byte(CRC_A1, rb_data);
                            dcnt <= 10'd0;
                            rs   <= R_DATA;
                        end else begin
                            q_err <= 1'b1;   // another ID field: no data mark
                            rs    <= R_FIN;
                        end
                    end
                end
            end
        end

        R_DATA: if (rb_valid) begin
            crc  <= crc_byte(crc, rb_data);
            dcnt <= dcnt + 10'd1;
            if (dcnt < 10'd512) begin
                sp_rd_valid <= 1'b1;
                sp_rd_data  <= rb_data;
            end
            if (dcnt == 10'd513) begin
                q_err <= crc_byte(crc, rb_data) != 16'h0000;
                rs    <= R_FIN;
            end
        end

        R_GAP2: begin                   // sector write: gap 2 passes under the head
            tmr <= tmr + 1'b1;
            if (tmr == ($bits(tmr))'(T_GAP2)) begin
                fs        <= F_DSYNC;
                fcnt      <= 10'd0;
                f_gap3    <= 1'b0;
                f_tail    <= 1'b0;
                stop_push <= 1'b0;
                rs        <= R_WRITE;
            end
        end

        R_FIDX: begin                   // format: from the index pulse
            if (noidx == ($bits(noidx))'(T_NOIDX)) begin
                q_err <= 1'b1;
                rs    <= R_FIN;
            end else if (index_edge) begin
                fs        <= F_GAP4A;
                fcnt      <= 10'd0;
                fsec      <= 4'd0;
                f_gap3    <= 1'b0;
                f_tail    <= 1'b0;
                stop_push <= 1'b0;
                rs        <= R_FMT;
            end
        end

        R_WRITE, R_FMT: begin
            if (rs == R_FMT && f_tail && index_edge)
                stop_push <= 1'b1;      // the track is round: stop at the index
            if (rs == R_FMT && noidx == ($bits(noidx))'(T_NOIDX)) begin
                stop_push <= 1'b1;
                q_err     <= 1'b1;
            end
            if (stop_push) begin
                if (!w_busy) rs <= R_WEND;
            end else if (w_room && !w_push && nb_ok) begin
                w_push <= 1'b1;
                w_data <= nb_data;
                w_kind <= nb_kind;
                if (nb_crc_upd)
                    crc <= crc_byte(nb_crc_rst ? 16'hFFFF : crc, nb_data);
                if (fs == F_DATA && !q_fmt) cb_valid <= 1'b0;
                // advance through the fields
                fcnt <= fcnt + 10'd1;
                if (f_tail) begin
                    if (rs == R_WRITE) stop_push <= 1'b1;   // one 4E after the data CRC
                end else if (f_gap3) begin
                    if (fcnt == 10'(GAP3 - 1)) begin
                        f_gap3 <= 1'b0;
                        fcnt   <= 10'd0;
                        fsec   <= fsec + 4'd1;
                        if (fsec == 4'(SPT - 1)) f_tail <= 1'b1;
                        else fs <= F_SSYNC;
                    end
                end else begin
                    case (fs)
                    F_GAP4A: if (fcnt == 10'd79) begin fs <= F_SYNC0; fcnt <= 10'd0; end
                    F_SYNC0: if (fcnt == 10'd11) begin fs <= F_IAM;   fcnt <= 10'd0; end
                    F_IAM:   if (fcnt == 10'd2)  begin fs <= F_FC;    fcnt <= 10'd0; end
                    F_FC:    begin fs <= F_GAP1; fcnt <= 10'd0; end
                    F_GAP1:  if (fcnt == 10'd49) begin fs <= F_SSYNC; fcnt <= 10'd0; end
                    F_SSYNC: if (fcnt == 10'd11) begin fs <= F_IDAM;  fcnt <= 10'd0; end
                    F_IDAM:  if (fcnt == 10'd2)  begin fs <= F_FE;    fcnt <= 10'd0; end
                    F_FE:    begin fs <= F_ID; fcnt <= 10'd0; end
                    F_ID:    if (fcnt == 10'd3)  begin fs <= F_IDCRC; fcnt <= 10'd0; end
                    F_IDCRC: if (fcnt == 10'd1)  begin fs <= F_GAP2;  fcnt <= 10'd0; end
                    F_GAP2:  if (fcnt == 10'd21) begin fs <= F_DSYNC; fcnt <= 10'd0; end
                    F_DSYNC: if (fcnt == 10'd11) begin fs <= F_DAM;   fcnt <= 10'd0; end
                    F_DAM:   if (fcnt == 10'd2)  begin fs <= F_FB;    fcnt <= 10'd0; end
                    F_FB:    begin fs <= F_DATA; fcnt <= 10'd0; end
                    F_DATA:  if (fcnt == 10'd511) begin fs <= F_DCRC; fcnt <= 10'd0; end
                    F_DCRC:  if (fcnt == 10'd1) begin
                                 fcnt <= 10'd0;
                                 if (rs == R_WRITE) f_tail <= 1'b1;
                                 else f_gap3 <= 1'b1;
                             end
                    default: ;
                    endcase
                end
            end
        end

        R_WEND: begin
            if (q_fmt && !q_err) begin
                fmt_valid <= 1'b1;
                fmt_cyl   <= q_cyl;
                fmt_head  <= q_head;
            end
            rs <= R_FIN;
        end

        R_FIN: begin
            want_req <= 1'b0;
            sp_done  <= 1'b1;
            sp_err   <= q_err;
            rs       <= R_LOW;
        end

        R_LOW: if (!sp_req) rs <= R_IDLE;

        default: rs <= R_IDLE;
        endcase

        // B: switched to an image in the middle of a request
        if (!enable && rs != R_IDLE && rs != R_FIN && rs != R_LOW) begin
            q_err <= 1'b1;
            rs    <= R_FIN;
        end
    end
end

endmodule
