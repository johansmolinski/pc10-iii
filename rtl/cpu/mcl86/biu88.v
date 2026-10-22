// biu88.v - cycle-stepped 8088 bus interface unit for the MCL86 EU.
//
// Replaces MCL86's biu_max.v, whose states were counted in 100 MHz core
// clocks. This BIU advances once per 8088 clock (input `step`, one core clock
// wide, at each rising edge of the 8088 CLK) and models the 8088 BIU as the
// MartyPC emulator does (cpu_808x/biu.rs, cycle.rs, queue.rs; MIT licence,
// Copyright 2022-2026 Daniel Balsom):
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
//   - word transfers as two byte transfers that no prefetch can split.
//
// The EU side keeps MCL86's interface (EU_BIU_COMMAND requests and strobes,
// BIU_DONE, the queue view PFQ_TOP_BYTE/PFQ_EMPTY/PFQ_ADDR_OUT, segment
// registers, cycle counter). MCL86's EU looks at the byte on top of the queue
// (PFQ_TOP_BYTE) and removes it later with a strobe, often well after it used
// it. The real chip removes a byte from the queue when it reads it, so here
// the EU's first use of the top byte (input eu_qread: 01 a jump through the
// opcode table, 11 any other use) is the read: the byte leaves the 4-byte
// queue and is "taken" (up to three bytes) for the EU's view until the strobe
// pops it. Queue status (QS1:QS0) is reported one cycle after the read, as on
// the real chip.
//
// The end of an instruction is timed here, not by the EU: when an absolute
// cycle-mode counter (below) runs out, the BIU reads the next opcode in that
// cycle (QS=F) even if the EU is still busy with the last steps of the
// instruction, which MCL86's microcode can take longer for than the 8088. The
// EU's dispatch on that byte then reads nothing new. BIU_CYC counts the 8088
// clocks since the last opcode read; the EU's SYNC microinstruction uses it.
//
// The MCL86 cycle counter (strobe 10) counts 100 MHz core clocks as before
// (legacy microcode) unless bit 13 of the loaded value is set. Then it counts
// 8088 clocks, and the value n (bits 11:0) is
//   bit 12 = 0, bit 14 = 1 (0xE00n): cycle n of the instruction, counted
//               from the cycle in which its opcode was read (absolute);
//   bit 12 = 1, bit 14 = 1 (0xF00n): n clocks from now;
//   bit 12 = 1, bit 14 = 0 (0xB00n): n clocks after the next EU bus transfer
//               ends (where the EU resumes; e.g. 0 = a write's T3);
//   bit 12 = 0, bit 14 = 0 (0xA00n): n clocks after the last queue read
//               (the 8088 reads the next opcode a fixed number of clocks
//               after an instruction's last operand byte).
// A cycle-mode load marks the END of the instruction (see below); mid-
// instruction timing uses the EU's SYNC microinstruction instead.
//
// Extra request codes (not in MCL86's BIU):
//   0x1E  SUSP   suspend prefetching; done when no code fetch is running
// Extra strobe (register strobe 11, code 6): request release. The next EU bus
// request is held until n 8088 clocks (n = DATAOUT bits 11:0) after
//   the last queue read          (bits 14:13 = 00),
//   the end of the last EU bus transfer, i.e. where the EU resumed
//                                (bit 13 = 1),
//   the opcode read              (bit 14 = 1),
// and then started as if the EU had made it at the start of that cycle. An
// unused release is dropped at the next opcode read.
// Register strobe 11, code 14: add DATAOUT bits 11:0 to a pending release
// (MOV [m],r writes 3 cycles after the 8088 would have read the operand).
// Register strobe 11, code 7: scheduled read. The BIU reads the next queue
// byte (QS=S) n clocks after the same bases (DATAOUT bits 14:13 = 00 last
// queue read, 01 transfer end, 10 opcode read), and with bit 12 set the byte
// after it one clock later, for instructions whose operand bytes the 8088
// reads before MCL86's microcode gets to them. The EU can
// compute an effective address faster than the 8088; CALC_EA sets the
// release to the cycle in which the 8088's EA microcode issues the operand
// read.
//
// Pins (pc10-iii, for the system board): READY is sampled as T3 and every Tw
// begin and says whether that state is the last one (low = a Tw follows;
// read data is taken in the last of them). The 8088 knows it there: a write
// ends its instruction in its last T3/Tw (MartyPC: wait states are counted
// at T2).
// INTR is sampled at every 8088 clock edge; an NMI rising edge is latched
// until the EU acknowledges it (BIU_NMI_DEBOUNCE, as MCL86's biu_max); LOCK
// is low from T2 of the first INTA cycle to T2 of the second, and while the
// EU's LOCK prefix is active.
// Not yet modelled: HOLD (the 5160 uses READY for DMA), HALT bus status
// details, the idle cycles between the two INTA cycles, interrupt latency
// against MartyPC.

module biu88 (
    input               CORE_CLK_INT,
    input               RESET_INT,
    input               step,               // one core clock per 8088 clock

    // 8088 pins (maximum mode)
    input               READY_IN,
    input               NMI,
    input               INTR,
    output              LOCK_n,
    output              AD_OE,
    output     [19:0]   AD_OUT,
    input      [7:0]    AD_IN,
    output     [2:0]    S2_S0_OUT,
    output              S6_3_MUX,
    output     [1:0]    QS_OUT,
    output     [7:0]    QS_BYTE,            // debug: the byte QS_OUT reports
    output              ALE,

    // EU interface (MCL86)
    input      [15:0]   EU_BIU_COMMAND,
    input      [15:0]   EU_BIU_DATAOUT,
    input      [15:0]   EU_REGISTER_R3,
    input               EU_PREFIX_LOCK,
    input      [1:0]    eu_qread,           // EU uses the queue top: 01 opcode, 11 other

    output              BIU_DONE,
    output              BIU_CLK_COUNTER_ZERO,
    output     [1:0]    BIU_SEGMENT,
    output              BIU_NMI_CAUGHT,
    input               BIU_NMI_DEBOUNCE,
    output              BIU_INTR,

    output     [7:0]    PFQ_TOP_BYTE,
    output              PFQ_EMPTY,
    output     [15:0]   PFQ_ADDR_OUT,

    output     [15:0]   BIU_REGISTER_ES,
    output     [15:0]   BIU_REGISTER_SS,
    output     [15:0]   BIU_REGISTER_CS,
    output     [15:0]   BIU_REGISTER_DS,
    output     [15:0]   BIU_REGISTER_RM,
    output     [15:0]   BIU_REGISTER_REG,
    output     [15:0]   BIU_RETURN_DATA,
    output     [11:0]   BIU_CYC,            // 8088 clocks since the opcode read
    output     [11:0]   BIU_SINCE_READ,     // 8088 clocks since the last queue read
    output     [11:0]   BIU_SINCE_DONE,     // 8088 clocks since an EU transfer ended
    output              BIU_SR_PENDING,     // a scheduled read has not happened yet

    // test only (SingleStepTests): install a prefetched queue
    input               tb_preload,
    input      [31:0]   tb_queue,           // byte 0 in bits 7:0
    input      [2:0]    tb_queue_len,
    input      [15:0]   tb_ip,

    // debug
    output     [2:0]    dbg_t_state,
    output     [2:0]    dbg_ta_state,
    output     [2:0]    dbg_latch,          // status of the running bus cycle
    output     [2:0]    dbg_queue_len
);

// ------------------------------------------------------------------ encodings

// T-states
localparam [2:0] TI = 3'd0, T1 = 3'd1, T2 = 3'd2, T3 = 3'd3, TW = 3'd4, T4 = 3'd5;
// address cycle
localparam [2:0] TA_TD = 3'd0, TA_TR = 3'd1, TA_TS = 3'd2, TA_T0 = 3'd3, TA_TA = 3'd4;
// bus status = S2..S0
localparam [2:0] ST_INTA = 3'd0, ST_IOR = 3'd1, ST_IOW = 3'd2, ST_HALT = 3'd3,
                 ST_CODE = 3'd4, ST_MEMR = 3'd5, ST_MEMW = 3'd6, ST_PASV = 3'd7;
// fetch state
localparam [2:0] FS_NORMAL = 3'd0, FS_PAUSED = 3'd1, FS_DELAYED = 3'd2,
                 FS_SUSP = 3'd3, FS_HALTED = 3'd4;
// pending EU request
localparam [1:0] BP_NONE = 2'd0, BP_EARLY = 2'd1, BP_LATE = 2'd2;
// queue operation (QS1:QS0)
localparam [1:0] QO_IDLE = 2'd0, QO_FIRST = 2'd1, QO_FLUSH = 2'd2, QO_SUBS = 2'd3;
// EU request phases (MartyPC biu_bus_begin and the waits after it)
localparam [3:0] RP_IDLE   = 4'd0,  // no request
                 RP_FINISH = 4'd1,  // wait for the current bus cycle to reach T4
                 RP_DELAY  = 4'd2,  // a fetch delay is running
                 RP_ADDR   = 4'd3,  // wait for the address cycle to end
                 RP_ADDR2  = 4'd4,  // after an abort/delay: the new address cycle
                 RP_T4     = 4'd5,  // run out a T4 before the new T1
                 RP_WAIT   = 4'd6,  // bus cycle running; wait for the resume point
                 RP_SUSP   = 4'd7,  // SUSP: wait for a running code fetch
                 RP_HOLD   = 4'd8;  // request held until its release cycle

// ------------------------------------------------------------------ state

reg  [2:0]  t_cycle, ta_cycle, latch, status, pl_status, fetch_state;
reg  [1:0]  fetch_delay;
reg  [1:0]  bus_pending;
reg         final_transfer;
reg  [1:0]  transfer_n;
reg  [19:0] address_latch;
reg  [7:0]  data_bus;
reg         discard;              // a flush hit a running code fetch

reg  [7:0]  q0, q1, q2, q3;
reg  [2:0]  qlen;
reg  [15:0] pc;                   // offset of the next code fetch
reg  [7:0]  taken0, taken1, taken2; // bytes read from the queue, not yet
reg  [1:0]  ntaken;               // popped by the EU (taken0 = its view's top)
reg         preread;              // taken1/taken0 holds an opcode the BIU read
reg         end_armed;            // an end counter is running
reg         end_after_done;       // the end starts at the next transfer end
reg  [11:0] end_ad_n;             // ... and comes n clocks after it
reg  [15:0] eu_ip;                // offset of the EU's current byte
reg  [1:0]  queue_op;             // queue operation of the running cycle
reg  [7:0]  queue_byte;
reg  [15:0] op_ip;                // debug: offset and byte of the last opcode read
reg  [7:0]  op_byte;

reg  [15:0] reg_es, reg_ss, reg_cs, reg_ds, reg_rm, reg_reg;
reg  [12:0] counter;
reg         counter_cycles;
reg  [11:0] since_dispatch;       // 8088 clocks since the EU's last dispatch
reg  [11:0] since_read;           // 8088 clocks since the last queue read
reg         rel_armed;            // the next EU bus request waits for rel_n
reg  [11:0] rel_n;
reg         rel_abs;              // rel_n counts from the opcode read,
reg         rel_done;             // or from the last EU transfer's end, else
                                  // from the last queue read
reg  [11:0] since_done;           // 8088 clocks since an EU transfer ended
reg         sr_armed;             // a scheduled subsequent-byte read
reg  [11:0] sr_n;
reg  [1:0]  sr_base;              // 00 last queue read, 01 transfer end, 10 opcode
reg         sr_two;               // a second byte in the next cycle

// EU request being served
reg  [3:0]  rphase;
reg  [2:0]  r_type;               // bus status of the request
reg  [19:0] r_addr0, r_addr1;     // linear addresses of byte 0 and byte 1
reg  [15:0] r_data;
reg         r_word;
reg         r_second;             // working on byte 1 of a word
reg         r_was_delay, r_abort;
reg  [1:0]  r_delay_cnt;
reg  [15:0] return_data;
reg         done;

reg         eu_req_d1, strobe_d1;
reg         inta_lock;            // LOCK during the INTA pair
reg         t3_last;              // the running T3/Tw is the last one (READY)
reg         nmi_d1, nmi_d2, nmi_caught;

// MCL86 pipelines the queue view by one core clock; keep that latency
reg  [7:0]  pfq_top_d1;
reg         pfq_empty_d1;
reg  [15:0] pfq_addr_d1;

// ------------------------------------------------------------------ EU command fields

wire        eu_prefix_seg    = EU_BIU_COMMAND[14];
wire [1:0]  eu_strobe        = EU_BIU_COMMAND[13:12];
wire [1:0]  eu_segment       = EU_BIU_COMMAND[11:10];
wire        eu_req           = EU_BIU_COMMAND[9];
wire [4:0]  eu_req_code      = EU_BIU_COMMAND[8:4];
wire [1:0]  eu_qs            = EU_BIU_COMMAND[3:2];
wire [1:0]  eu_seg_override  = EU_BIU_COMMAND[1:0];

wire [1:0]  seg_sel = eu_prefix_seg ? eu_seg_override : eu_segment;
wire [15:0] seg_val = seg_sel == 2'b00 ? reg_es :
                      seg_sel == 2'b01 ? reg_ss :
                      seg_sel == 2'b10 ? reg_cs : reg_ds;

assign BIU_SEGMENT          = seg_sel;
assign BIU_REGISTER_ES      = o_reg_es;
assign BIU_REGISTER_SS      = o_reg_ss;
assign BIU_REGISTER_CS      = o_reg_cs;
assign BIU_REGISTER_DS      = o_reg_ds;
assign BIU_REGISTER_RM      = o_reg_rm;
assign BIU_REGISTER_REG     = o_reg_reg;
assign BIU_RETURN_DATA      = o_return_data;
assign BIU_CYC              = o_since_dispatch;
assign BIU_SINCE_READ       = o_since_read;
assign BIU_SINCE_DONE       = o_since_done;
assign BIU_SR_PENDING       = o_sr_armed;
assign BIU_DONE             = o_done;
assign BIU_CLK_COUNTER_ZERO = o_counter == 13'd0;
assign BIU_NMI_CAUGHT       = o_nmi_caught;
assign LOCK_n               = ~(o_inta_lock | EU_PREFIX_LOCK);

assign PFQ_TOP_BYTE = o_pfq_top_d1;
assign PFQ_EMPTY    = o_pfq_empty_d1;
assign PFQ_ADDR_OUT = o_pfq_addr_d1;

// pins
assign ALE       = o_t_cycle == T1 && o_latch != ST_PASV && o_latch != ST_HALT;
assign S2_S0_OUT = (o_t_cycle == T1 || o_t_cycle == T2) ? o_status : ST_PASV;
assign AD_OE     = 1'b1;
assign AD_OUT    = o_t_cycle == T1 ? o_address_latch : {o_address_latch[19:8], o_data_bus};
assign S6_3_MUX  = o_t_cycle != T1;

assign dbg_t_state   = o_t_cycle;
assign dbg_ta_state  = ta_cycle;
assign dbg_latch     = o_latch;
assign dbg_queue_len = qlen;

// ------------------------------------------------------------------ helpers
// All of these work on the state registers with blocking assignments; they
// are only called from the one clocked block below, which is how the
// procedural MartyPC model maps onto a single synchronous update.

function rel_due;             // the held request may go
    input [11:0] n;
    rel_due = rel_abs ? since_dispatch >= n : rel_done ? since_done >= n : since_read >= n;
endfunction

function sr_due;              // the scheduled subsequent read may go
    input [11:0] n;
    sr_due = sr_base == 2'b10 ? since_dispatch >= n :
             sr_base == 2'b01 ? since_done >= n : since_read >= n;
endfunction

function has_room;            // room for a 1-byte fetch
    input [2:0] len;
    has_room = len <= 3'd3;
endfunction

task q_push;
    input [7:0] b;
    begin
        case (qlen)
            3'd0: q0 = b;
            3'd1: q1 = b;
            3'd2: q2 = b;
            default: q3 = b;
        endcase
        if (qlen < 3'd4) qlen = qlen + 3'd1;
    end
endtask

task q_pop;                   // q0 leaves the queue
    begin
        q0 = q1; q1 = q2; q2 = q3;
        if (qlen != 3'd0) qlen = qlen - 3'd1;
    end
endtask

task address_start;
    input [2:0] st;
    begin
        ta_cycle  = ta_cycle == TA_TA ? TA_TS : TA_TR;   // an abort's T0 was our Tr
        pl_status = st;
    end
endtask

task fetch_start;
    begin
        if (bus_pending != BP_EARLY && pl_status != ST_CODE && fetch_state != FS_DELAYED) begin
            fetch_state = FS_NORMAL;
            address_start(ST_CODE);
        end
    end
endtask

task make_fetch_decision;
    begin
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
    end
endtask

task bus_begin_fetch;
    begin
        if (has_room(qlen)) begin
            fetch_state    = FS_NORMAL;
            pl_status      = ST_PASV;
            status         = ST_CODE;
            latch          = ST_CODE;
            t_cycle        = 3'd7;        // Tinit: becomes T1 for the next cycle
            address_latch  = {reg_cs, 4'h0} + {4'h0, pc};
            data_bus       = 8'h00;
            transfer_n     = 2'd1;
            final_transfer = 1'b1;
            discard        = 1'b0;
        end
    end
endtask

// a byte left the queue for the EU (MartyPC biu_queue_read side effects)
task queue_read_effects;
    begin
        if (fetch_state == FS_DELAYED && qlen == 3'd3)     // CANCEL_DELAY
            fetch_delay = 2'd0;
    end
endtask

task fetch_on_queue_read;                               // FOQR
    begin
        if (status == ST_PASV && has_room(qlen)) begin
            case (fetch_state)
                FS_SUSP: begin ta_cycle = TA_TD; fetch_start; end
                FS_PAUSED: if (t_cycle == TI) begin ta_cycle = TA_TD; fetch_start; end
                default: fetch_start;
            endcase
        end
    end
endtask

// --- EU bus request: the start of MartyPC's biu_bus_begin (at the boundary)
task request_begin;
    begin
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
    end
endtask

// the start of the bus cycle itself (end of biu_bus_begin)
task request_bus_start;
    begin
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
    end
endtask

// work through the request phases as far as the state allows (no cycle runs
// in here; every "wait" stops until the next step)
task request_advance;
    integer guard;
    begin
        for (guard = 0; guard < 6; guard = guard + 1) begin
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
    end
endtask

// the byte at the head of the queue is read: it leaves the 4-byte queue and
// goes behind the bytes the EU has not popped yet
task take_byte;
    input [1:0] op;
    begin
        queue_read_effects;
        if (ntaken == 2'd0) taken0 = q0;
        else if (ntaken == 2'd1) taken1 = q0;
        else taken2 = q0;
        ntaken     = ntaken + 2'd1;
        queue_byte = q0;
        q_pop;
        queue_op   = op;
        if (op == QO_FIRST) begin
            op_ip   = eu_ip + {14'd0, ntaken - 2'd1};
            op_byte = queue_byte;
            since_dispatch = 12'd0;
            rel_armed = 1'b0;           // an unused release ends with its instruction
            sr_armed  = 1'b0;
        end
        since_read = 12'd0;
        fetch_on_queue_read;
    end
endtask

// one 8088 clock: MartyPC cycle_i()
task do_cycle;
    begin
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
                            data_bus = AD_IN;
                        status = ST_PASV;
                    end
                    T4: begin
                        if (latch == ST_CODE) begin
                            if (!discard) begin
                                q_push(data_bus);
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
                        bus_begin_fetch;             // sets t_cycle = T1
                    end
                end else if (pl_status == ST_CODE && bus_pending == BP_LATE) begin
                    if (t_cycle == TI || t_cycle == T4)
                        ta_cycle = TA_TA;            // prefetch abort
                end else if (t_cycle == TI || t_cycle == T4) begin
                    ta_cycle = TA_TD;
                    t_cycle  = 3'd7;                 // Tinit: the EU starts T1
                end
            default: ;
        endcase

        // ---- next T-state
        case (t_cycle)
            3'd7: t_cycle = T1;                     // Tinit
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
                t3_last = READY_IN;
                if (latch == ST_INTA) inta_lock = transfer_n != 2'd2;
            end
            T3, TW: if (t3_last) t_cycle = T4;
                    else begin t_cycle = TW; t3_last = READY_IN; end
            T4: begin latch = ST_PASV; t_cycle = TI; end
            default: ;
        endcase
    end
endtask

// ------------------------------------------------------------------ main
// The outputs. The state is kept with blocking assignments (the model is
// procedural); these copies carry it to the outputs with nonblocking ones, so
// that the EU and the board (other processes on the same clock edge) read the
// values from before the edge in simulation too, as they do in hardware
// (pc10-iii, 2026-10-21: Verilator ran them after this block and gave them
// the new values).
reg  [15:0]  o_reg_es;
reg  [15:0]  o_reg_ss;
reg  [15:0]  o_reg_cs;
reg  [15:0]  o_reg_ds;
reg  [15:0]  o_reg_rm;
reg  [15:0]  o_reg_reg;
reg  [15:0]  o_return_data;
reg  [11:0]  o_since_dispatch;
reg  [11:0]  o_since_read;
reg  [11:0]  o_since_done;
reg         o_sr_armed;
reg         o_done;
reg         o_nmi_caught;
reg  [12:0]  o_counter;
reg         o_inta_lock;
reg  [7:0]  o_pfq_top_d1;
reg         o_pfq_empty_d1;
reg  [15:0]  o_pfq_addr_d1;
reg  [2:0]  o_t_cycle;
reg  [2:0]  o_latch;
reg  [2:0]  o_status;
reg  [19:0]  o_address_latch;
reg  [7:0]  o_data_bus;
reg  [1:0]  o_qs_out;
reg  [7:0]  o_qs_byte;
reg         o_biu_intr;
reg [1:0] qs_out; reg [7:0] qs_byte; reg biu_intr;
assign QS_OUT = o_qs_out; assign QS_BYTE = o_qs_byte; assign BIU_INTR = o_biu_intr;

always @(posedge CORE_CLK_INT) begin
    if (RESET_INT) begin
        t_cycle = TI;  ta_cycle = TA_TD;  latch = ST_PASV;  status = ST_PASV;
        pl_status = ST_PASV;  fetch_state = FS_NORMAL;  fetch_delay = 2'd0;
        bus_pending = BP_NONE;  final_transfer = 1'b1;  transfer_n = 2'd0;
        address_latch = 20'h0;  data_bus = 8'h0;  discard = 1'b0;
        q0 = 8'h0; q1 = 8'h0; q2 = 8'h0; q3 = 8'h0;  qlen = 3'd0;
        pc = 16'h0;  taken0 = 8'h0;  taken1 = 8'h0;  taken2 = 8'h0;  ntaken = 2'd0;
        preread = 1'b0;  end_armed = 1'b0;  end_after_done = 1'b0;  end_ad_n = 12'd0;
        eu_ip = 16'h0;  queue_op = QO_IDLE;  qs_out = QO_IDLE;
        queue_byte = 8'h0;  qs_byte = 8'h0;
        op_ip = 16'h0;  op_byte = 8'h0;
        reg_es = 16'h0; reg_ss = 16'h0; reg_cs = 16'hFFFF; reg_ds = 16'h0;
        reg_rm = 16'h0; reg_reg = 16'h0;
        counter = 13'd0;  counter_cycles = 1'b0;  since_dispatch = 12'd0;  since_read = 12'd0;
        rel_armed = 1'b0;  rel_n = 12'd0;  rel_abs = 1'b0;  rel_done = 1'b0;  since_done = 12'd0;
        sr_armed = 1'b0;  sr_n = 12'd0;  sr_base = 2'b00;  sr_two = 1'b0;
        rphase = RP_IDLE;  r_type = ST_PASV;  r_addr0 = 20'h0;  r_addr1 = 20'h0;
        r_data = 16'h0;  r_word = 1'b0;  r_second = 1'b0;
        r_was_delay = 1'b0;  r_abort = 1'b0;  r_delay_cnt = 2'd0;
        return_data = 16'h0;  done = 1'b0;
        eu_req_d1 = 1'b0;  strobe_d1 = 1'b0;
        pfq_top_d1 = 8'h0;  pfq_empty_d1 = 1'b1;  pfq_addr_d1 = 16'h0;
        biu_intr = 1'b0;
        inta_lock = 1'b0;  t3_last = 1'b1;  nmi_d1 = 1'b0;  nmi_d2 = 1'b0;  nmi_caught = 1'b0;
    end else begin
        done = 1'b0;

        // ================= the 8088 clock edge
        // NMI: a rising edge is caught until the EU takes it
        if (nmi_d1 && !nmi_d2) nmi_caught = 1'b1;
        else if (BIU_NMI_DEBOUNCE) nmi_caught = 1'b0;
        nmi_d2 = nmi_d1;
        nmi_d1 = NMI;

        if (step) begin
            biu_intr = INTR;                    // sampled at the CLK edge

            // MartyPC runs the request's wait loops cycle by cycle; the
            // conditions are checked at the boundary BEFORE each cycle, which
            // is here (state = the cycle about to run)
            do_cycle;

            // queue status: what the EU did in the cycle that just ended
            qs_out   = queue_op;
            qs_byte  = queue_byte;
            queue_op = QO_IDLE;

            if (counter_cycles && counter != 13'd0) counter = counter - 13'd1;
            if (since_dispatch != 12'hFFF) since_dispatch = since_dispatch + 12'd1;
            if (since_read != 12'hFFF) since_read = since_read + 12'd1;
            if (since_done != 12'hFFF) since_done = since_done + 12'd1;

            // request phases that need a whole cycle
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
                    // resume points: a read resumes when T4 is next (data
                    // taken at T3), a final write when T3 is next
                    if (t_cycle == T4 && (r_type != ST_MEMW && r_type != ST_IOW || r_word && !r_second)) begin
                        if (r_type == ST_MEMW || r_type == ST_IOW) ;
                        else if (r_second && r_type == ST_INTA)
                            return_data = {8'h00, data_bus};   // the vector: 2nd INTA
                        else if (r_second) return_data[15:8] = data_bus;
                        else return_data = {8'h00, data_bus};
                        if (r_word && !r_second) begin
                            r_second = 1'b1;
                            request_begin;            // second byte: same sequence
                        end else begin
                            rphase = RP_IDLE;
                            done = 1'b1;
                            since_done = 12'd0;
                            if (end_after_done) begin end_after_done = 1'b0; end_armed = 1'b1; counter = {1'b0, end_ad_n}; end
                        end
                    end else if ((t_cycle == T3 || t_cycle == TW) && t3_last &&
                                 (r_type == ST_MEMW || r_type == ST_IOW) &&
                                 (!r_word || r_second)) begin
                        rphase = RP_IDLE;
                        done = 1'b1;
                        since_done = 12'd0;
                        if (end_after_done) begin end_after_done = 1'b0; end_armed = 1'b1; counter = {1'b0, end_ad_n}; end
                    end
                end
                RP_SUSP:
                    if (latch != ST_CODE || t_cycle == T4) begin
                        ta_cycle  = TA_TD;
                        pl_status = ST_PASV;
                        rphase    = RP_IDLE;
                        done      = 1'b1;
                    end
                default: ;
            endcase
            if (rphase == RP_FINISH || rphase == RP_ADDR || rphase == RP_ADDR2)
                request_advance;

            // a held request is released at the start of its cycle; its
            // phases that need a whole cycle (a fetch delay) start counting
            // with the next step, as for a request the EU makes directly
            if (rphase == RP_HOLD && rel_due(rel_n)) begin
                rel_armed = 1'b0;
                request_begin;
                request_advance;
            end
        end else begin
            if (!counter_cycles && counter != 13'd0) counter = counter - 13'd1;
        end

        // ================= EU events (they belong to the running cycle)

        // segment and addressing registers, cycle counter
        if (eu_strobe == 2'b11) begin
            case (eu_req_code[3:0])
                4'h0: reg_es  = EU_BIU_DATAOUT;
                4'h1: reg_ss  = EU_BIU_DATAOUT;
                4'h2: reg_cs  = EU_BIU_DATAOUT;
                4'h3: reg_ds  = EU_BIU_DATAOUT;
                4'h4: reg_rm  = EU_BIU_DATAOUT;
                4'h5: reg_reg = EU_BIU_DATAOUT;
                4'hE: rel_n = rel_n + EU_BIU_DATAOUT[11:0];  // pc10-iii: release later
                4'h7: begin                         // pc10-iii: scheduled read
                    sr_armed = 1'b1;
                    sr_n     = EU_BIU_DATAOUT[11:0];
                    sr_base  = EU_BIU_DATAOUT[14:13];
                    sr_two   = EU_BIU_DATAOUT[12];
                end
                4'h6: begin                         // pc10-iii: request release
                    rel_armed = 1'b1;
                    rel_n     = EU_BIU_DATAOUT[11:0];
                    rel_abs   = EU_BIU_DATAOUT[14];
                    rel_done  = EU_BIU_DATAOUT[13];
                end
                default: ;
            endcase
        end
        // the first end armed in an instruction stands: later loads are
        // ignored until it has fired and the EU has dispatched the next opcode
        if (eu_strobe == 2'b10 && !end_armed && !preread && !end_after_done) begin
            counter        = EU_BIU_DATAOUT[12:0];
            counter_cycles = EU_BIU_DATAOUT[13];
            // cycle units: bit 12 = 0: zero at cycle n of the instruction
            // (0 = the cycle of its dispatch), wherever in the instruction the
            // load happens; bit 12 = 1: zero n cycles from now
            if (EU_BIU_DATAOUT[13]) begin
                if (EU_BIU_DATAOUT[12] && EU_BIU_DATAOUT[14]) begin
                    counter = {1'b0, EU_BIU_DATAOUT[11:0]};
                    end_armed = 1'b1;
                end else if (EU_BIU_DATAOUT[12]) begin
                    // n clocks after the next EU transfer ends (0xB00n); the
                    // count starts there
                    end_ad_n = EU_BIU_DATAOUT[11:0];
                    counter  = 13'h1FFF;
                    end_after_done = 1'b1;
                end else if (!EU_BIU_DATAOUT[14]) begin
                    counter = EU_BIU_DATAOUT[11:0] > since_read ?
                              {1'b0, EU_BIU_DATAOUT[11:0] - since_read} : 13'd0;
                    end_armed = 1'b1;
                end else begin
                    counter = EU_BIU_DATAOUT[11:0] > since_dispatch ?
                              {1'b0, EU_BIU_DATAOUT[11:0] - since_dispatch} : 13'd0;
                    end_armed = 1'b1;   // cycle-mode loads mark the end
                end
            end
        end

        // the EU's first use of the byte on top of its view is the read. An
        // opcode the BIU read already at the end of the last instruction
        // (preread) is not read again.
        if (eu_qread == 2'b01) begin
            if (preread)
                preread = 1'b0;
            else if (ntaken == 2'd0 && qlen != 3'd0) begin
                take_byte(QO_FIRST);
                end_armed = 1'b0;
            end
        end else if (eu_qread == 2'b11 && ntaken == 2'd0 && qlen != 3'd0)
            take_byte(QO_SUBS);

        // queue strobes: MCL86 pops the byte on top of its view, with a QS
        // code saying what it was (01 opcode, 11 subsequent byte). A byte the
        // EU never looked at is read here.
        if (eu_strobe == 2'b01 && !strobe_d1) begin
            if (ntaken == 2'd0 && qlen != 3'd0)
                take_byte(eu_qs == 2'b01 ? QO_FIRST : QO_SUBS);
            if (ntaken != 2'd0) begin
                taken0 = taken1;
                taken1 = taken2;
                ntaken = ntaken - 2'd1;
                eu_ip  = eu_ip + 16'd1;
            end
        end
        strobe_d1 = eu_strobe == 2'b01;

        // a scheduled subsequent-byte read: the BIU reads the next byte at
        // the cycle the 8088 reads it, even if the EU gets to it later (it
        // then finds the byte read already)
        if (sr_armed && sr_due(sr_n) && ntaken != 2'd3 && qlen != 3'd0) begin
            take_byte(QO_SUBS);
            if (sr_two) begin                   // the second byte, next cycle
                sr_two  = 1'b0;
                sr_n    = 12'd1;
                sr_base = 2'b00;
            end else
                sr_armed = 1'b0;
        end

        // the end of the instruction: when its absolute end counter runs out,
        // the next opcode is read in that cycle even if the EU is still busy
        // (MCL86's microcode can take longer than the 8088 for its last steps)
        if (end_armed && counter == 13'd0 && ntaken != 2'd3 && qlen != 3'd0 && !preread) begin
            take_byte(QO_FIRST);
            preread   = 1'b1;
            end_armed = 1'b0;
        end

        // bus requests
        if (eu_req && !eu_req_d1) begin
            case (eu_req_code)
                5'h19: begin                        // jump: flush the queue
                    qlen = 3'd0; ntaken = 2'd0; preread = 1'b0; end_armed = 1'b0;
                    rel_armed = 1'b0; end_after_done = 1'b0; sr_armed = 1'b0;
                    pc = EU_REGISTER_R3; eu_ip = EU_REGISTER_R3;
                    queue_op = QO_FLUSH;    // QS byte: the last byte read stays
                    if (latch == ST_CODE) discard = 1'b1;
                    fetch_state = FS_NORMAL;
                    fetch_start;
                    done = 1'b1;
                end
                5'h1E: begin                        // SUSP
                    fetch_state = FS_SUSP;
                    rphase = RP_SUSP;
                    // MartyPC biu_fetch_suspend: wait for a running code
                    // fetch to reach T4 (no wait when this cycle is its T4)
                    if (latch != ST_CODE || t_cycle == T4) begin
                        ta_cycle  = TA_TD;
                        pl_status = ST_PASV;
                        rphase    = RP_IDLE;
                        done      = 1'b1;
                    end
                end
                default: begin
                    r_second = 1'b0;
                    r_word   = 1'b0;
                    r_data   = EU_BIU_DATAOUT;
                    r_addr0  = {seg_val, 4'h0} + {4'h0, EU_REGISTER_R3};
                    r_addr1  = {seg_val, 4'h0} + {4'h0, EU_REGISTER_R3 + 16'd1};
                    case (eu_req_code)
                        5'h08: begin r_type = ST_IOR;  r_addr0 = {4'h0, EU_REGISTER_R3}; end
                        5'h1A: begin r_type = ST_IOR;  r_word = 1'b1; end
                        5'h0A: begin r_type = ST_IOW;  r_addr0 = {4'h0, EU_REGISTER_R3}; end
                        5'h1C: begin r_type = ST_IOW;  r_word = 1'b1; end
                        5'h0C: r_type = ST_MEMR;
                        5'h10: begin r_type = ST_MEMR; r_word = 1'b1; end
                        5'h11: begin r_type = ST_MEMR; r_word = 1'b1;
                                     r_addr0 = {reg_ss, 4'h0} + {4'h0, EU_REGISTER_R3};
                                     r_addr1 = {reg_ss, 4'h0} + {4'h0, EU_REGISTER_R3 + 16'd1}; end
                        5'h12: begin r_type = ST_MEMR; r_word = 1'b1;
                                     r_addr0 = {4'h0, EU_REGISTER_R3};
                                     r_addr1 = {4'h0, EU_REGISTER_R3 + 16'd1}; end
                        5'h0E: r_type = ST_MEMW;
                        5'h13: begin r_type = ST_MEMW; r_word = 1'b1; end
                        5'h14: begin r_type = ST_MEMW; r_word = 1'b1;
                                     r_addr0 = {reg_ss, 4'h0} + {4'h0, EU_REGISTER_R3};
                                     r_addr1 = {reg_ss, 4'h0} + {4'h0, EU_REGISTER_R3 + 16'd1}; end
                        5'h16: begin r_type = ST_INTA; r_word = 1'b1; end
                        default: r_type = ST_PASV;   // HALT (0x18) and unknown: ignored
                    endcase
                    if (eu_req_code == 5'h1A || eu_req_code == 5'h1C) begin
                        r_addr0 = {4'h0, EU_REGISTER_R3};
                        r_addr1 = {4'h0, EU_REGISTER_R3 + 16'd1};
                    end
                    if (r_type == ST_PASV)
                        done = 1'b1;
                    else if (rel_armed && !rel_due(rel_n))
                        rphase = RP_HOLD;           // the EU is early: hold it
                    else begin
                        rel_armed = 1'b0;
                        request_begin;
                        request_advance;
                    end
                end
            endcase
        end
        eu_req_d1 = eu_req;

        // test only: the queue as a prefetched test starts it (fetching is
        // paused when it is full; the bus is idle)
        if (tb_preload) begin
            q0 = tb_queue[7:0];   q1 = tb_queue[15:8];
            q2 = tb_queue[23:16]; q3 = tb_queue[31:24];
            qlen = tb_queue_len;
            ntaken = 2'd0; preread = 1'b0; end_armed = 1'b0;
            eu_ip = tb_ip;
            pc = tb_ip + {13'd0, tb_queue_len};
            ta_cycle = TA_TD;
            pl_status = ST_PASV;
            fetch_state = tb_queue_len == 3'd4 ? FS_PAUSED : FS_NORMAL;
            t_cycle = TI; latch = ST_PASV; status = ST_PASV;
            bus_pending = BP_NONE; discard = 1'b0;
        end

        // MCL86's one-clock queue view latency
        pfq_top_d1   = ntaken != 2'd0 ? taken0 : q0;
        pfq_empty_d1 = ntaken == 2'd0 && qlen == 3'd0;
        pfq_addr_d1  = eu_ip;
    end
    o_reg_es <= reg_es;
    o_reg_ss <= reg_ss;
    o_reg_cs <= reg_cs;
    o_reg_ds <= reg_ds;
    o_reg_rm <= reg_rm;
    o_reg_reg <= reg_reg;
    o_return_data <= return_data;
    o_since_dispatch <= since_dispatch;
    o_since_read <= since_read;
    o_since_done <= since_done;
    o_sr_armed <= sr_armed;
    o_done <= done;
    o_nmi_caught <= nmi_caught;
    o_counter <= counter;
    o_inta_lock <= inta_lock;
    o_pfq_top_d1 <= pfq_top_d1;
    o_pfq_empty_d1 <= pfq_empty_d1;
    o_pfq_addr_d1 <= pfq_addr_d1;
    o_t_cycle <= t_cycle;
    o_latch <= latch;
    o_status <= status;
    o_address_latch <= address_latch;
    o_data_bus <= data_bus;
    o_qs_out <= qs_out;
    o_qs_byte <= qs_byte;
    o_biu_intr <= biu_intr;
end

endmodule
