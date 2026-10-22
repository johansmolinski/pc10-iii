// biu88.sv - the 8088's bus interface unit, cycle-stepped, with the real
// chip's EU/BIU split (pc10-iii, 2026-10-22; doc/z8086.md section 6).
//
// The BIU advances once per 8088 clock (input `step`, one clk wide, at each
// rising edge of the 8088 CLK) and models the 8088 BIU as the MartyPC emulator
// does (cpu_808x/biu.rs, cycle.rs, queue.rs; MIT licence, Copyright 2022-2026
// Daniel Balsom), the model that the MCL86 version of biu88 (2026-10-21/22)
// carried:
//
//   - T-states Ti T1 T2 T3 Tw T4; status pins active in T1/T2, passive from
//     T3 (the transfer); a code fetch pushes its byte into the queue at T4;
//   - the address-cycle pipeline Tr -> Ts -> T0 -> Td (and Ta = aborted)
//     that every bus cycle goes through before its T1;
//   - fetch decisions at Ti, at the end of T2 and at T4 of the final transfer;
//     the 8088 queue policy (a fetch that would fill the queue to 4 while a
//     code fetch runs is delayed by 3 cycles), pause when full, suspend;
//   - EU requests that arrive early (Ti/T1/T2) or late (T3/T4 of a code fetch:
//     the fetch is aborted, costing the abort penalty);
//   - word transfers as two byte transfers that no prefetch can split; an
//     interrupt acknowledge "word" as the two INTA cycles, LOCK between them;
//   - the halt bus cycle (MartyPC's biu_halt).
//
// The EU side is the real chip's (z8086's EU, rtl/cpu/z8086/z86_eu.sv, one
// microinstruction per 8088 clock): per 8088 clock the EU reads the queue
// head (or not), and makes at most one of: a bus request (byte/word,
// read/write, memory/I/O/INTA, segment + offset), FLUSH (with the new IP),
// SUSP, HALT. Its outputs are registers it sets at its clock enable, after
// the step; this BIU takes them at the next step, before that clock's cycle
// (MartyPC: the EU acts between two cycles). What the EU sees (the queue
// head, its IP, the T-state, done and the read data) are registers set at the
// step. There is nothing per core clock any more: the whole state changes at
// `step` only (rtl/cpu/cpu8088.xdc: multicycle paths), except the test-only
// queue preload.
//
// Done (`done`, for the clock after the step): a read when its last byte's T4
// begins (the EU takes the data and runs in T4), a write when its last
// T3/Tw begins (READY high: the last one), SUSP when no code fetch runs (or
// the running one reaches T4). `done_imm`: done in the step that took the
// request (an immediate SUSP); the EU resumes a write or a SUSP that waited
// one clock after done (XTCE's resume rule, z86_eu.sv).
//
// GPL-3.0-or-later, pc10-iii.

module biu88 (
    input  logic        clk,
    input  logic        reset,
    input  logic        step,               // one clk per 8088 clock

    // 8088 pins (maximum mode)
    input  logic        READY_IN,           // sampled at the step that decides T3/Tw
    input  logic [7:0]  AD_IN,
    output logic [19:0] AD_OUT,
    output logic [2:0]  S2_S0_OUT,
    output logic        S6_3_MUX,
    output logic [1:0]  QS_OUT,
    output logic [7:0]  QS_BYTE,            // debug: the byte QS_OUT reports
    output logic        ALE,
    output logic        LOCK_n,

    // EU -> BIU: the EU's last clock (registers, taken at the next step)
    input  logic        eu_qrd,             // the EU read the queue head
    input  logic        eu_qrd_first,       // ... as an instruction's first byte
    input  logic        eu_req,             // a bus request
    input  logic        eu_wr, eu_io, eu_word, eu_inta, eu_seg0,
    input  logic [1:0]  eu_seg,             // 00 ES, 01 SS, 10 CS, 11 DS
    input  logic [15:0] eu_addr,            // offset (port for I/O)
    input  logic [15:0] eu_data,            // write data
    input  logic        eu_flush,           // jump: flush the queue, fetch from eu_flush_ip
    input  logic [15:0] eu_flush_ip,
    input  logic        eu_susp,            // suspend prefetching
    input  logic        eu_halt,            // HLT: the halt bus cycle
    input  logic        eu_lock,            // the LOCK prefix
    input  logic [15:0] reg_cs, reg_ds, reg_es, reg_ss,
    input  logic        inta_vec_lo,        // INTA word: the vector in the low byte (the
                                            // 8086-ROM overlay), else {2nd, 1st} as a word

    // BIU -> EU (registers, set at the step)
    output logic [7:0]  q_top,
    output logic        q_empty,
    output logic [15:0] q_ip,               // the EU's IP: the address of q_top
    output logic [2:0]  t_state,            // 0 Ti 1 T1 2 T2 3 T3 4 Tw 5 T4
    output logic [2:0]  bus_type,           // the running cycle's status (7 = none)
    output logic        done,
    output logic        done_imm,
    output logic [15:0] rdata,

    // test only (SingleStepTests): install a prefetched queue (taken at the
    // next step, after the EU's events: the loader's JMP FAR flush)
    input  logic        tb_preload,
    input  logic [31:0] tb_queue,           // byte 0 in bits 7:0
    input  logic [2:0]  tb_queue_len,
    input  logic [15:0] tb_ip,

    // debug
    output logic [2:0]  dbg_ta_state,
    output logic [2:0]  dbg_queue_len,
    output logic [15:0] dbg_pc
);

// ------------------------------------------------------------------ encodings

// T-states
localparam logic [2:0] TI = 3'd0, T1 = 3'd1, T2 = 3'd2, T3 = 3'd3, TW = 3'd4, T4 = 3'd5, TINIT = 3'd7;
// address cycle
localparam logic [2:0] TA_TD = 3'd0, TA_TR = 3'd1, TA_TS = 3'd2, TA_T0 = 3'd3, TA_TA = 3'd4;
// bus status = S2..S0
localparam logic [2:0] ST_INTA = 3'd0, ST_IOR = 3'd1, ST_IOW = 3'd2, ST_HALT = 3'd3,
                       ST_CODE = 3'd4, ST_MEMR = 3'd5, ST_MEMW = 3'd6, ST_PASV = 3'd7;
// fetch state
localparam logic [2:0] FS_NORMAL = 3'd0, FS_PAUSED = 3'd1, FS_DELAYED = 3'd2,
                       FS_SUSP = 3'd3, FS_HALTED = 3'd4;
// pending EU request
localparam logic [1:0] BP_NONE = 2'd0, BP_EARLY = 2'd1, BP_LATE = 2'd2;
// queue operation (QS1:QS0)
localparam logic [1:0] QO_IDLE = 2'd0, QO_FIRST = 2'd1, QO_FLUSH = 2'd2, QO_SUBS = 2'd3;
// EU request phases (MartyPC biu_bus_begin and the waits after it)
localparam logic [3:0] RP_IDLE   = 4'd0,  // no request
                       RP_FINISH = 4'd1,  // wait for the current bus cycle to reach T4
                       RP_DELAY  = 4'd2,  // a fetch delay is running
                       RP_ADDR   = 4'd3,  // wait for the address cycle to end
                       RP_ADDR2  = 4'd4,  // after an abort/delay: the new address cycle
                       RP_T4     = 4'd5,  // run out a T4 before the new T1
                       RP_WAIT   = 4'd6,  // bus cycle running; wait for the resume point
                       RP_SUSP   = 4'd7,  // SUSP: wait for a running code fetch
                       RP_HALTW  = 4'd8,  // HALT: wait for the bus cycle to finish
                       RP_HALTI  = 4'd9;  // HALT: one Ti, then the halt cycle

// ------------------------------------------------------------------ state (changes at step)

logic [2:0]  t_cycle, ta_cycle, latch, status, pl_status, fetch_state;
logic [1:0]  fetch_delay, bus_pending, transfer_n;
logic        final_transfer, discard, inta_lock, t3_last;
logic [19:0] address_latch;
logic [7:0]  data_bus;
logic [15:0] pc;                        // offset of the next code fetch
logic [3:0]  rphase;
logic [2:0]  r_type;
logic [19:0] r_addr0, r_addr1;
logic [15:0] r_data;
logic        r_word, r_second, r_was_delay, r_abort;
logic [1:0]  r_delay_cnt;
logic [7:0]  q0, q1, q2, q3;
logic [2:0]  qlen;
logic [15:0] eu_ip;
logic [1:0]  qs_out;
logic [7:0]  qs_byte;
logic        cb;                        // a code fetch runs and is not in its T4
logic [15:0] return_data;
logic        o_done, o_done_imm;
logic        pre_pend;                  // test only: a preload is waiting for the step
logic [31:0] pre_queue;
logic [2:0]  pre_len;
logic [15:0] pre_ip;
logic [1:0]  rst_flush;                 // after reset: the jump to FFFF:0000

// ------------------------------------------------------------------ helpers

function automatic logic has_room(input logic [2:0] len);
    return len <= 3'd3;
endfunction

function automatic logic [15:0] seg_of(input logic [1:0] s);
    case (s)
        2'b00:   return reg_es;
        2'b01:   return reg_ss;
        2'b10:   return reg_cs;
        default: return reg_ds;
    endcase
endfunction

// ------------------------------------------------------------------ the step
// (MartyPC's procedures, on blocking working copies; the always block below
// loads them, runs the step and stores them back)

logic        v_db_cap, v_rdy_cap, v_wf_pend, v_done, v_done_imm, v_req_new;
logic [1:0]  v_queue_op;
logic [7:0]  v_queue_byte;

task automatic address_start(input logic [2:0] st);
    ta_cycle  = ta_cycle == TA_TA ? TA_TS : TA_TR;   // an abort's T0 was our Tr
    pl_status = st;
endtask

task automatic fetch_start;
    if (bus_pending != BP_EARLY && pl_status != ST_CODE && fetch_state != FS_DELAYED) begin
        fetch_state = FS_NORMAL;
        address_start(ST_CODE);
    end
endtask

task automatic make_fetch_decision;
    if (!has_room(qlen))
        fetch_state = FS_PAUSED;
    else if (bus_pending != BP_EARLY && fetch_state != FS_SUSP && fetch_state != FS_HALTED) begin
        if (qlen == 3'd3 && latch == ST_CODE) begin
            // queue policy: delay the fetch that would fill the queue
            if (ta_cycle == TA_TD) begin
                if (fetch_state != FS_DELAYED || fetch_delay == 2'd0) begin
                    fetch_state = FS_DELAYED;
                    fetch_delay = 2'd3;
                end
            end
        end else if (ta_cycle == TA_TD)
            fetch_start;
    end
endtask

task automatic bus_begin_fetch;
    if (has_room(qlen)) begin
        fetch_state    = FS_NORMAL;
        pl_status      = ST_PASV;
        status         = ST_CODE;
        latch          = ST_CODE;
        t_cycle        = TINIT;         // becomes T1 for the next cycle
        address_latch  = {reg_cs, 4'h0} + {4'h0, pc};
        data_bus       = 8'h00;
        transfer_n     = 2'd1;
        final_transfer = 1'b1;
        discard        = 1'b0;
    end
endtask

task automatic fetch_on_queue_read;                     // FOQR
    // (has_room: a byte has just left the queue)
    if (status == ST_PASV) begin
        case (fetch_state)
            FS_SUSP: begin ta_cycle = TA_TD; fetch_start; end
            FS_PAUSED: if (t_cycle == TI) begin ta_cycle = TA_TD; fetch_start; end
            default: fetch_start;
        endcase
    end
endtask

// --- EU bus request: the start of MartyPC's biu_bus_begin (at the boundary)
task automatic request_begin;
    r_was_delay = 1'b0;
    r_abort     = 1'b0;
    case (t_cycle)
        TI: address_start(r_type);
        T1, T2: begin
            bus_pending = BP_EARLY;
            address_start(r_type);
        end
        default: begin
            if (pl_status == ST_CODE) begin
                bus_pending = BP_LATE;
                r_abort = 1'b1;
            end else if (!final_transfer)
                bus_pending = BP_EARLY;
        end
    endcase
    rphase = RP_FINISH;
endtask

// the start of the bus cycle itself (end of biu_bus_begin)
task automatic request_bus_start;
    if (!r_second) begin
        transfer_n     = 2'd1;
        final_transfer = !r_word;
    end else begin
        transfer_n     = 2'd2;
        final_transfer = 1'b1;
    end
    bus_pending   = BP_NONE;
    pl_status     = ST_PASV;
    status        = r_type;
    latch         = r_type;
    t_cycle       = T1;
    address_latch = r_second ? r_addr1 : r_addr0;
    data_bus      = r_second ? r_data[15:8] : r_data[7:0];
    rphase        = RP_WAIT;
endtask

// work through the request phases as far as the state allows (no cycle runs
// in here; every "wait" stops until the next step). A pass moves at most one
// phase on (FINISH -> ADDR/DELAY -> ADDR2/T4 -> T4) and DELAY/T4 stay, so
// three passes reach the end.
task automatic request_advance;
    for (int guard = 0; guard < 3; guard++) begin
        case (rphase)
            RP_FINISH:
                if (latch == ST_PASV || t_cycle == T4) begin
                    // biu_bus_wait_delay
                    if (fetch_state == FS_DELAYED) begin
                        r_was_delay = 1'b1;
                        if (fetch_delay == 2'd0) begin
                            ta_cycle = TA_TD;
                            rphase = RP_ADDR;
                        end else begin
                            r_delay_cnt = fetch_delay;
                            rphase = RP_DELAY;
                        end
                    end else
                        rphase = RP_ADDR;
                end
            RP_ADDR:
                if (ta_cycle == TA_TD || ta_cycle == TA_TA) begin
                    if (r_was_delay || r_abort) begin
                        address_start(r_type);
                        rphase = RP_ADDR2;
                    end else
                        rphase = RP_T4;
                end
            RP_ADDR2:
                if (ta_cycle == TA_TD || ta_cycle == TA_TA)
                    rphase = RP_T4;
            default: ;
        endcase
    end
    // RP_T4: a T4 of a non-code cycle must run out first
    if (rphase == RP_T4 && !(t_cycle == T4 && latch != ST_CODE))
        request_bus_start;
endtask

// the halt bus cycle (MartyPC biu_halt): status HALT in a T1, then passive
task automatic halt_bus_start;
    pl_status      = ST_PASV;
    status         = ST_HALT;
    latch          = ST_HALT;
    t_cycle        = T1;
    address_latch  = {reg_cs, 4'h0} + {4'h0, pc};
    data_bus       = 8'h00;
    transfer_n     = 2'd1;
    final_transfer = 1'b1;
    rphase         = RP_IDLE;
endtask

// one 8088 clock: MartyPC cycle_i()
task automatic do_cycle;
    // ---- operate the current T-state
    case (latch)
        ST_PASV: begin
            transfer_n = 2'd0;
            if (fetch_state == FS_DELAYED && fetch_delay == 2'd0) begin
                fetch_state = FS_NORMAL;
                make_fetch_decision;
            end else if (fetch_state == FS_PAUSED) begin
                if (has_room(qlen)) make_fetch_decision;
            end
        end
        ST_HALT: ;
        default:
            case (t_cycle)
                TI: make_fetch_decision;
                T2: if (final_transfer) make_fetch_decision;
                T3, TW: begin
                    // the transfer (no wait states yet)
                    if (latch == ST_CODE || latch == ST_MEMR || latch == ST_IOR || latch == ST_INTA)
                        v_db_cap = 1'b1;    // data_bus = AD_IN
                    status = ST_PASV;
                end
                T4: begin
                    if (latch == ST_CODE) begin
                        if (!discard) begin
                            // the fetched byte enters the queue
                            case (qlen)
                                3'd0: q0 = data_bus;
                                3'd1: q1 = data_bus;
                                3'd2: q2 = data_bus;
                                default: q3 = data_bus;
                            endcase
                            if (qlen < 3'd4) qlen = qlen + 3'd1;
                            pc = pc + 16'd1;
                        end
                        discard = 1'b0;
                    end
                    if (final_transfer) make_fetch_decision;
                end
                default: ;
            endcase
    endcase

    // ---- fetch delay counter
    if (fetch_state == FS_DELAYED && t_cycle != TW && fetch_delay != 2'd0)
        fetch_delay = fetch_delay - 2'd1;

    // ---- address cycle
    case (ta_cycle)
        TA_TR: ta_cycle = TA_TS;
        TA_TS: ta_cycle = TA_T0;
        TA_T0:
            if (pl_status == ST_CODE && bus_pending == BP_NONE) begin
                if ((t_cycle == TI || t_cycle == T4) &&
                    fetch_state != FS_SUSP && fetch_state != FS_HALTED) begin
                    ta_cycle = TA_TD;
                    bus_begin_fetch;             // sets t_cycle = Tinit
                end
            end else if (pl_status == ST_CODE && bus_pending == BP_LATE) begin
                if (t_cycle == TI || t_cycle == T4)
                    ta_cycle = TA_TA;            // prefetch abort
            end else if (t_cycle == TI || t_cycle == T4) begin
                ta_cycle = TA_TD;
                t_cycle  = TINIT;                // Tinit: the EU starts T1
            end
        default: ;
    endcase

    // ---- next T-state
    case (t_cycle)
        TINIT: t_cycle = T1;
        TI: if (latch == ST_PASV) t_cycle = TI;
            else if (latch == ST_HALT) begin
                status = ST_PASV; latch = ST_PASV; t_cycle = TI;
            end else t_cycle = T1;
        T1: if (latch == ST_PASV) t_cycle = T1;
            else if (latch == ST_HALT) begin
                status = ST_PASV; latch = ST_PASV; t_cycle = TI;
            end else t_cycle = T2;
        T2: begin
            t_cycle = T3;
            v_rdy_cap = 1'b1;                   // t3_last = READY_IN
            if (latch == ST_INTA) inta_lock = transfer_n != 2'd2;
        end
        T3, TW: if (t3_last) t_cycle = T4;
                else begin t_cycle = TW; v_rdy_cap = 1'b1; end
        T4: begin latch = ST_PASV; t_cycle = TI; end
        default: ;
    endcase
endtask

// the step's cycle and the request phases that need a whole cycle
task automatic bus_step;
    v_db_cap = 1'b0;  v_rdy_cap = 1'b0;  v_wf_pend = 1'b0;

    do_cycle;
    if (v_db_cap) data_bus = AD_IN;
    if (v_rdy_cap) t3_last = READY_IN;

    case (rphase)
        RP_DELAY: begin
            r_delay_cnt = r_delay_cnt - 2'd1;
            if (r_delay_cnt == 2'd0) begin
                ta_cycle = TA_TA;
                rphase   = RP_ADDR;
            end
        end
        RP_T4: request_bus_start;           // the T4 has run out
        RP_WAIT: begin
            // resume points: a read resumes when T4 is next (data taken at
            // T3/Tw), a final write when its last T3/Tw is next
            if (t_cycle == T4 && (r_type != ST_MEMW && r_type != ST_IOW || r_word && !r_second)) begin
                if (r_type != ST_MEMW && r_type != ST_IOW) begin
                    if (r_second && r_type == ST_INTA && inta_vec_lo)
                        return_data = {8'h00, data_bus};    // the vector: 2nd INTA
                    else if (r_second) return_data[15:8] = data_bus;
                    else return_data = {8'h00, data_bus};
                end
                if (r_word && !r_second) begin
                    r_second = 1'b1;
                    request_begin;            // second byte: same sequence
                end else begin
                    rphase = RP_IDLE;
                    v_done = 1'b1;
                end
            end else if ((t_cycle == T3 || t_cycle == TW) && t3_last &&
                         (r_type == ST_MEMW || r_type == ST_IOW) && (!r_word || r_second)) begin
                rphase = RP_IDLE;
                v_done = 1'b1;
            end
        end
        RP_SUSP:
            if (latch != ST_CODE || t_cycle == T4) begin
                ta_cycle  = TA_TD;
                pl_status = ST_PASV;
                rphase    = RP_IDLE;
                v_done    = 1'b1;
            end
        RP_HALTW:
            if (latch == ST_PASV || t_cycle == T4 || t_cycle == TI)
                rphase = RP_HALTI;
        RP_HALTI:
            if (t_cycle == TI)
                halt_bus_start;
        default: ;
    endcase
    if (rphase == RP_FINISH || rphase == RP_ADDR || rphase == RP_ADDR2)
        request_advance;
endtask

// the EU's events of its last clock, before the step's cycle: the queue read
// (MartyPC biu_queue_read: CANCEL_DELAY when the queue held 3 bytes, else
// fetch-on-queue-read), then FLUSH, SUSP, HALT or a request
task automatic eu_events;
    logic [19:0] base;
    if (eu_qrd && qlen != 3'd0) begin
        v_queue_byte = q0;
        v_queue_op   = eu_qrd_first ? QO_FIRST : QO_SUBS;
        if (fetch_state == FS_DELAYED) begin
            if (qlen == 3'd3) fetch_delay = 2'd0;           // CANCEL_DELAY
        end
        q0 = q1; q1 = q2; q2 = q3;
        qlen = qlen - 3'd1;
        eu_ip = eu_ip + 16'd1;
        if (fetch_state != FS_DELAYED)
            fetch_on_queue_read;
    end
    if (eu_flush) begin                         // jump: flush the queue
        qlen = 3'd0;
        v_queue_op = QO_FLUSH;
        eu_ip = eu_flush_ip;
        pc = eu_flush_ip;
        if (latch == ST_CODE) discard = 1'b1;
        fetch_state = FS_NORMAL;
        fetch_start;
    end
    if (eu_susp) begin                          // SUSP
        fetch_state = FS_SUSP;
        rphase = RP_SUSP;
        // MartyPC biu_fetch_suspend: wait for a running code fetch to reach
        // T4 (no wait when this cycle is its T4): done at once
        if (!cb) begin
            ta_cycle  = TA_TD;
            pl_status = ST_PASV;
            rphase    = RP_IDLE;
            v_done = 1'b1;
            v_done_imm = 1'b1;
        end
    end else if (eu_halt) begin                 // HLT
        fetch_state = FS_HALTED;
        rphase = RP_HALTW;
    end else if (eu_req) begin                  // a bus request
        base = eu_io ? 20'h0 : eu_seg0 ? 20'h0 : {seg_of(eu_seg), 4'h0};
        r_second = 1'b0;
        r_word   = eu_word | eu_inta;
        r_data   = eu_data;
        r_addr0  = base + {4'h0, eu_addr};
        r_addr1  = base + {4'h0, eu_addr + 16'd1};
        r_type   = eu_inta ? ST_INTA : eu_io ? (eu_wr ? ST_IOW : ST_IOR) : (eu_wr ? ST_MEMW : ST_MEMR);
        v_req_new = 1'b1;
        request_go;
    end
endtask

// request_begin followed by request_advance (the request phases as far as
// the state allows, at the boundary before the cycle)
task automatic request_go;
    request_begin;
    request_advance;
endtask

// ------------------------------------------------------------------ registers
// The state above is worked on with blocking assignments in this one block,
// at the step; everything another module reads comes from the nonblocking
// output registers below (so that, in simulation too, the EU and the board
// read the values before the clock edge, as in hardware).

logic [2:0]  o_t_cycle, o_latch, o_status, o_ta_cycle;
logic [19:0] o_address_latch;
logic [7:0]  o_data_bus, o_q0, o_qs_byte;
logic [1:0]  o_qs;
logic        o_qempty, o_inta_lock;
logic [15:0] o_ip, o_rdata, o_pc;
logic [2:0]  o_qlen;

always @(posedge clk) begin
    if (reset) begin
        t_cycle = TI;  ta_cycle = TA_TD;  latch = ST_PASV;  status = ST_PASV;
        pl_status = ST_PASV;  fetch_state = FS_NORMAL;  fetch_delay = 2'd0;
        bus_pending = BP_NONE;  final_transfer = 1'b1;  transfer_n = 2'd0;
        address_latch = 20'h0;  data_bus = 8'h0;  discard = 1'b0;  pc = 16'h0;
        rphase = RP_IDLE;  r_type = ST_PASV;  r_addr0 = 20'h0;  r_addr1 = 20'h0;
        r_data = 16'h0;  r_word = 1'b0;  r_second = 1'b0;  r_was_delay = 1'b0;
        r_abort = 1'b0;  r_delay_cnt = 2'd0;  inta_lock = 1'b0;  t3_last = 1'b1;
        q0 = 8'h0; q1 = 8'h0; q2 = 8'h0; q3 = 8'h0;  qlen = 3'd0;  eu_ip = 16'h0;
        qs_out = QO_IDLE;  qs_byte = 8'h0;  cb = 1'b0;  return_data = 16'h0;
        pre_pend = 1'b0;  rst_flush = 2'd2;
        o_done <= 1'b0;  o_done_imm <= 1'b0;
    end else begin
        if (step) begin
            v_done = 1'b0;  v_done_imm = 1'b0;  v_req_new = 1'b0;
            v_queue_op = QO_IDLE;  v_queue_byte = qs_byte;

            // the EU's last clock
            eu_events;

            // after reset the 8088 starts at FFFF:0000: a flush to IP 0 in
            // the EU's first clock (taken at the second step)
            if (rst_flush == 2'd1) begin
                qlen = 3'd0;
                v_queue_op = QO_FLUSH;
                eu_ip = 16'h0;
                pc = 16'h0;
                if (latch == ST_CODE) discard = 1'b1;
                fetch_state = FS_NORMAL;
                fetch_start;
            end
            if (rst_flush != 2'd0) rst_flush = rst_flush - 2'd1;

            // test only: the queue as a prefetched test starts it (fetching
            // is paused when it is full; the bus is idle)
            if (pre_pend) begin
                pre_pend = 1'b0;
                q0 = pre_queue[7:0];   q1 = pre_queue[15:8];
                q2 = pre_queue[23:16]; q3 = pre_queue[31:24];
                qlen = pre_len;
                eu_ip = pre_ip;
                pc = pre_ip + {13'd0, pre_len};
                ta_cycle = TA_TD;  pl_status = ST_PASV;
                fetch_state = pre_len == 3'd4 ? FS_PAUSED : FS_NORMAL;
                t_cycle = TI;  latch = ST_PASV;  status = ST_PASV;
                bus_pending = BP_NONE;  discard = 1'b0;
            end

            // this clock's cycle
            bus_step;

            // a code fetch runs after the step and is not in its T4 (a SUSP
            // of the EU in this clock waits for it)
            cb = latch == ST_CODE && (t_cycle == T1 || t_cycle == T2 || t_cycle == T3 || t_cycle == TW);

            // queue status: what the EU did in its last clock
            qs_out  = v_queue_op;
            qs_byte = v_queue_byte;

            o_done     <= v_done;
            o_done_imm <= v_done_imm;
        end
        if (tb_preload) begin
            pre_pend  = 1'b1;
            pre_queue = tb_queue;  pre_len = tb_queue_len;  pre_ip = tb_ip;
        end
    end
    o_t_cycle       <= t_cycle;
    o_ta_cycle      <= ta_cycle;
    o_latch         <= latch;
    o_status        <= status;
    o_address_latch <= address_latch;
    o_data_bus      <= data_bus;
    o_inta_lock     <= inta_lock;
    o_q0            <= q0;
    o_qempty        <= qlen == 3'd0;
    o_qlen          <= qlen;
    o_ip            <= eu_ip;
    o_pc            <= pc;
    o_qs            <= qs_out;
    o_qs_byte       <= qs_byte;
    o_rdata         <= return_data;
end

// ------------------------------------------------------------------ outputs

assign q_top     = o_q0;
assign q_empty   = o_qempty;
assign q_ip      = o_ip;
assign t_state   = o_t_cycle;
assign bus_type  = o_latch;
assign done      = o_done;
assign done_imm  = o_done_imm;
assign rdata     = o_rdata;

// pins (the halt cycle has ALE, as MartyPC's 8288)
assign ALE       = o_t_cycle == T1 && o_latch != ST_PASV;
assign S2_S0_OUT = (o_t_cycle == T1 || o_t_cycle == T2) ? o_status : ST_PASV;
assign AD_OUT    = o_t_cycle == T1 ? o_address_latch : {o_address_latch[19:8], o_data_bus};
assign S6_3_MUX  = o_t_cycle != T1;
assign QS_OUT    = o_qs;
assign QS_BYTE   = o_qs_byte;
assign LOCK_n    = ~(o_inta_lock | eu_lock);

assign dbg_ta_state  = o_ta_cycle;
assign dbg_queue_len = o_qlen;
assign dbg_pc        = o_pc;

endmodule
