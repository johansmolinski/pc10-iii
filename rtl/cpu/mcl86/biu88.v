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

//
// Timing structure (pc10-iii, 2026-10-21: 100 MHz). The model above is
// procedural: at a step the T-state machine, the request phases and the EU's
// events of that clock ran in one chain, far too deep for one clock. The state
// is split, without changing what the model does on any clock the EU or an
// 8088 clock sample sees:
//
//   - the FAST part: everything the EU sees (the queue and the EU's view of
//     it, the counters, BIU_DONE, the return data, QS, the registers). It is
//     exact on every clock. At a step it needs only a few facts of the bus
//     state as it was before the step (a code fetch's push at T4, a transfer's
//     resume point, whether a code fetch is running: cb_pred), shallow
//     functions of the bus state.
//   - the BUS part: the T-states, the address cycle, the fetch policy and the
//     EU request phases (MartyPC's state). The EU's events change it on the
//     clock they happen, except around a step: the step's own work (do_cycle
//     and the request phases) is done two clocks later (win2) from a copy of
//     the bus state (bd*) and of the fast values it reads (sn_*) taken before
//     the step, followed by the EU events of the step's clock (p1_*) and of
//     the next (pw_*), in their order. The events of the clock of win2 are
//     applied one clock later (p2_*, pend), together with that clock's own
//     ones: the queue reads of two clocks in a row merge, and if the recorded
//     clock made a request (the next cannot make one: a request is an edge),
//     it is applied alone and that clock's events are recorded in turn. The
//     pins (driven by the bus state) show the step's result up to two clocks
//     later than before, which the 8088 clock samples (the next step, 20 or
//     21 clocks later) never see. rtl/cpu/cpu8088.xdc gives the paths from
//     bd*/sn_*/p1_* their clocks as multicycle paths.
//   - The decisions of a clock that depend on the EU's queue reads
//     (EU_QREAD comes late in the clock) are worked out as flat logic for
//     every value they depend on (f_chain); the bus part's result is worked
//     out for each combination of them (queue read none / without / with
//     CANCEL_DELAY, request not held / held) and kept as six candidate
//     registers (k*, l*), and the 3-bit choice among them (ksel) is the only
//     register the late decisions reach. The bus state is the chosen
//     candidate (an 8:1 mux of registers).
//   - The outputs are registers assigned with nonblocking assignments (o_*),
//     or the mux of the candidate registers (v_*), so that the EU and the
//     board, other processes on the same clock, read the values before the
//     clock edge in simulation too, as in hardware.

module biu88_mcl (
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
    input               INTA_VEC_LO,        // INTA word: the vector (2nd cycle) in the low byte
                                            // (MCL86; z86's 8088 overlay); else {2nd, 1st}

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

// ------------------------------------------------------------------ bus state

reg  [2:0]  t_cycle, ta_cycle, latch, status, pl_status, fetch_state;
reg  [1:0]  fetch_delay;
reg  [1:0]  bus_pending;
reg         final_transfer;
reg  [1:0]  transfer_n;
reg  [19:0] address_latch;
reg  [7:0]  data_bus;
reg         discard;              // a flush hit a running code fetch
reg  [15:0] pc;                   // offset of the next code fetch
// EU request being served
reg  [3:0]  rphase;
reg  [2:0]  r_type;               // bus status of the request
reg  [19:0] r_addr0, r_addr1;     // linear addresses of byte 0 and byte 1
reg  [15:0] r_data;
reg         r_word;
reg         r_second;             // working on byte 1 of a word
reg         r_was_delay, r_abort;
reg  [1:0]  r_delay_cnt;
reg         inta_lock;            // LOCK during the INTA pair
reg         t3_last;              // the running T3/Tw is the last one (READY)

// (The variables above are the working values of the bus state.) The bus state is kept as six candidates (k*/l*: the results for the six
// combinations of this clock's late decisions, see bus_select) and the choice
// among them (ksel = {queue read, CANCEL_DELAY, request held}). The working
// values above (t_cycle ...) are the chosen candidate, worked out at the start
// of each clock (bus_view). The late decisions so end in ksel and not in the
// whole bus state.
reg  [2:0] kn_t_cycle;
reg  [2:0] kn_ta_cycle;
reg  [2:0] kn_latch;
reg  [2:0] kn_status;
reg  [2:0] kn_pl_status;
reg  [2:0] kn_fetch_state;
reg  [1:0] kn_fetch_delay;
reg  [1:0] kn_bus_pending;
reg         kn_final_transfer;
reg  [1:0] kn_transfer_n;
reg  [19:0] kn_address_latch;
reg  [7:0] kn_data_bus;
reg         kn_discard;
reg  [15:0] kn_pc;
reg  [3:0] kn_rphase;
reg  [2:0] kn_r_type;
reg  [19:0] kn_r_addr0;
reg  [19:0] kn_r_addr1;
reg  [15:0] kn_r_data;
reg         kn_r_word;
reg         kn_r_second;
reg         kn_r_was_delay;
reg         kn_r_abort;
reg  [1:0] kn_r_delay_cnt;
reg         kn_t3_last;
reg         kn_inta_lock;
reg  [2:0] kt_t_cycle;
reg  [2:0] kt_ta_cycle;
reg  [2:0] kt_latch;
reg  [2:0] kt_status;
reg  [2:0] kt_pl_status;
reg  [2:0] kt_fetch_state;
reg  [1:0] kt_fetch_delay;
reg  [1:0] kt_bus_pending;
reg         kt_final_transfer;
reg  [1:0] kt_transfer_n;
reg  [19:0] kt_address_latch;
reg  [7:0] kt_data_bus;
reg         kt_discard;
reg  [15:0] kt_pc;
reg  [3:0] kt_rphase;
reg  [2:0] kt_r_type;
reg  [19:0] kt_r_addr0;
reg  [19:0] kt_r_addr1;
reg  [15:0] kt_r_data;
reg         kt_r_word;
reg         kt_r_second;
reg         kt_r_was_delay;
reg         kt_r_abort;
reg  [1:0] kt_r_delay_cnt;
reg         kt_t3_last;
reg         kt_inta_lock;
reg  [2:0] kc_t_cycle;
reg  [2:0] kc_ta_cycle;
reg  [2:0] kc_latch;
reg  [2:0] kc_status;
reg  [2:0] kc_pl_status;
reg  [2:0] kc_fetch_state;
reg  [1:0] kc_fetch_delay;
reg  [1:0] kc_bus_pending;
reg         kc_final_transfer;
reg  [1:0] kc_transfer_n;
reg  [19:0] kc_address_latch;
reg  [7:0] kc_data_bus;
reg         kc_discard;
reg  [15:0] kc_pc;
reg  [3:0] kc_rphase;
reg  [2:0] kc_r_type;
reg  [19:0] kc_r_addr0;
reg  [19:0] kc_r_addr1;
reg  [15:0] kc_r_data;
reg         kc_r_word;
reg         kc_r_second;
reg         kc_r_was_delay;
reg         kc_r_abort;
reg  [1:0] kc_r_delay_cnt;
reg         kc_t3_last;
reg         kc_inta_lock;
reg  [2:0] ln_t_cycle;
reg  [2:0] ln_ta_cycle;
reg  [2:0] ln_latch;
reg  [2:0] ln_status;
reg  [2:0] ln_pl_status;
reg  [2:0] ln_fetch_state;
reg  [1:0] ln_fetch_delay;
reg  [1:0] ln_bus_pending;
reg         ln_final_transfer;
reg  [1:0] ln_transfer_n;
reg  [19:0] ln_address_latch;
reg  [7:0] ln_data_bus;
reg         ln_discard;
reg  [15:0] ln_pc;
reg  [3:0] ln_rphase;
reg  [2:0] ln_r_type;
reg  [19:0] ln_r_addr0;
reg  [19:0] ln_r_addr1;
reg  [15:0] ln_r_data;
reg         ln_r_word;
reg         ln_r_second;
reg         ln_r_was_delay;
reg         ln_r_abort;
reg  [1:0] ln_r_delay_cnt;
reg         ln_t3_last;
reg         ln_inta_lock;
reg  [2:0] lt_t_cycle;
reg  [2:0] lt_ta_cycle;
reg  [2:0] lt_latch;
reg  [2:0] lt_status;
reg  [2:0] lt_pl_status;
reg  [2:0] lt_fetch_state;
reg  [1:0] lt_fetch_delay;
reg  [1:0] lt_bus_pending;
reg         lt_final_transfer;
reg  [1:0] lt_transfer_n;
reg  [19:0] lt_address_latch;
reg  [7:0] lt_data_bus;
reg         lt_discard;
reg  [15:0] lt_pc;
reg  [3:0] lt_rphase;
reg  [2:0] lt_r_type;
reg  [19:0] lt_r_addr0;
reg  [19:0] lt_r_addr1;
reg  [15:0] lt_r_data;
reg         lt_r_word;
reg         lt_r_second;
reg         lt_r_was_delay;
reg         lt_r_abort;
reg  [1:0] lt_r_delay_cnt;
reg         lt_t3_last;
reg         lt_inta_lock;
reg  [2:0] lc_t_cycle;
reg  [2:0] lc_ta_cycle;
reg  [2:0] lc_latch;
reg  [2:0] lc_status;
reg  [2:0] lc_pl_status;
reg  [2:0] lc_fetch_state;
reg  [1:0] lc_fetch_delay;
reg  [1:0] lc_bus_pending;
reg         lc_final_transfer;
reg  [1:0] lc_transfer_n;
reg  [19:0] lc_address_latch;
reg  [7:0] lc_data_bus;
reg         lc_discard;
reg  [15:0] lc_pc;
reg  [3:0] lc_rphase;
reg  [2:0] lc_r_type;
reg  [19:0] lc_r_addr0;
reg  [19:0] lc_r_addr1;
reg  [15:0] lc_r_data;
reg         lc_r_word;
reg         lc_r_second;
reg         lc_r_was_delay;
reg         lc_r_abort;
reg  [1:0] lc_r_delay_cnt;
reg         lc_t3_last;
reg         lc_inta_lock;
(* max_fanout = 24 *) reg  [2:0]  ksel;   // (replicated: it selects the whole state)
reg  [2:0]  ksel_n;
// the copy the step works from (see bd_*/sn_* in cpu8088.xdc)
(* dont_touch = "true" *) reg  [2:0] bdkn_t_cycle;
(* dont_touch = "true" *) reg  [2:0] bdkn_ta_cycle;
(* dont_touch = "true" *) reg  [2:0] bdkn_latch;
(* dont_touch = "true" *) reg  [2:0] bdkn_status;
(* dont_touch = "true" *) reg  [2:0] bdkn_pl_status;
(* dont_touch = "true" *) reg  [2:0] bdkn_fetch_state;
(* dont_touch = "true" *) reg  [1:0] bdkn_fetch_delay;
(* dont_touch = "true" *) reg  [1:0] bdkn_bus_pending;
(* dont_touch = "true" *) reg         bdkn_final_transfer;
(* dont_touch = "true" *) reg  [1:0] bdkn_transfer_n;
(* dont_touch = "true" *) reg  [19:0] bdkn_address_latch;
(* dont_touch = "true" *) reg  [7:0] bdkn_data_bus;
(* dont_touch = "true" *) reg         bdkn_discard;
(* dont_touch = "true" *) reg  [15:0] bdkn_pc;
(* dont_touch = "true" *) reg  [3:0] bdkn_rphase;
(* dont_touch = "true" *) reg  [2:0] bdkn_r_type;
(* dont_touch = "true" *) reg  [19:0] bdkn_r_addr0;
(* dont_touch = "true" *) reg  [19:0] bdkn_r_addr1;
(* dont_touch = "true" *) reg  [15:0] bdkn_r_data;
(* dont_touch = "true" *) reg         bdkn_r_word;
(* dont_touch = "true" *) reg         bdkn_r_second;
(* dont_touch = "true" *) reg         bdkn_r_was_delay;
(* dont_touch = "true" *) reg         bdkn_r_abort;
(* dont_touch = "true" *) reg  [1:0] bdkn_r_delay_cnt;
(* dont_touch = "true" *) reg         bdkn_t3_last;
(* dont_touch = "true" *) reg         bdkn_inta_lock;
(* dont_touch = "true" *) reg  [2:0] bdkt_t_cycle;
(* dont_touch = "true" *) reg  [2:0] bdkt_ta_cycle;
(* dont_touch = "true" *) reg  [2:0] bdkt_latch;
(* dont_touch = "true" *) reg  [2:0] bdkt_status;
(* dont_touch = "true" *) reg  [2:0] bdkt_pl_status;
(* dont_touch = "true" *) reg  [2:0] bdkt_fetch_state;
(* dont_touch = "true" *) reg  [1:0] bdkt_fetch_delay;
(* dont_touch = "true" *) reg  [1:0] bdkt_bus_pending;
(* dont_touch = "true" *) reg         bdkt_final_transfer;
(* dont_touch = "true" *) reg  [1:0] bdkt_transfer_n;
(* dont_touch = "true" *) reg  [19:0] bdkt_address_latch;
(* dont_touch = "true" *) reg  [7:0] bdkt_data_bus;
(* dont_touch = "true" *) reg         bdkt_discard;
(* dont_touch = "true" *) reg  [15:0] bdkt_pc;
(* dont_touch = "true" *) reg  [3:0] bdkt_rphase;
(* dont_touch = "true" *) reg  [2:0] bdkt_r_type;
(* dont_touch = "true" *) reg  [19:0] bdkt_r_addr0;
(* dont_touch = "true" *) reg  [19:0] bdkt_r_addr1;
(* dont_touch = "true" *) reg  [15:0] bdkt_r_data;
(* dont_touch = "true" *) reg         bdkt_r_word;
(* dont_touch = "true" *) reg         bdkt_r_second;
(* dont_touch = "true" *) reg         bdkt_r_was_delay;
(* dont_touch = "true" *) reg         bdkt_r_abort;
(* dont_touch = "true" *) reg  [1:0] bdkt_r_delay_cnt;
(* dont_touch = "true" *) reg         bdkt_t3_last;
(* dont_touch = "true" *) reg         bdkt_inta_lock;
(* dont_touch = "true" *) reg  [2:0] bdkc_t_cycle;
(* dont_touch = "true" *) reg  [2:0] bdkc_ta_cycle;
(* dont_touch = "true" *) reg  [2:0] bdkc_latch;
(* dont_touch = "true" *) reg  [2:0] bdkc_status;
(* dont_touch = "true" *) reg  [2:0] bdkc_pl_status;
(* dont_touch = "true" *) reg  [2:0] bdkc_fetch_state;
(* dont_touch = "true" *) reg  [1:0] bdkc_fetch_delay;
(* dont_touch = "true" *) reg  [1:0] bdkc_bus_pending;
(* dont_touch = "true" *) reg         bdkc_final_transfer;
(* dont_touch = "true" *) reg  [1:0] bdkc_transfer_n;
(* dont_touch = "true" *) reg  [19:0] bdkc_address_latch;
(* dont_touch = "true" *) reg  [7:0] bdkc_data_bus;
(* dont_touch = "true" *) reg         bdkc_discard;
(* dont_touch = "true" *) reg  [15:0] bdkc_pc;
(* dont_touch = "true" *) reg  [3:0] bdkc_rphase;
(* dont_touch = "true" *) reg  [2:0] bdkc_r_type;
(* dont_touch = "true" *) reg  [19:0] bdkc_r_addr0;
(* dont_touch = "true" *) reg  [19:0] bdkc_r_addr1;
(* dont_touch = "true" *) reg  [15:0] bdkc_r_data;
(* dont_touch = "true" *) reg         bdkc_r_word;
(* dont_touch = "true" *) reg         bdkc_r_second;
(* dont_touch = "true" *) reg         bdkc_r_was_delay;
(* dont_touch = "true" *) reg         bdkc_r_abort;
(* dont_touch = "true" *) reg  [1:0] bdkc_r_delay_cnt;
(* dont_touch = "true" *) reg         bdkc_t3_last;
(* dont_touch = "true" *) reg         bdkc_inta_lock;
(* dont_touch = "true" *) reg  [2:0] bdln_t_cycle;
(* dont_touch = "true" *) reg  [2:0] bdln_ta_cycle;
(* dont_touch = "true" *) reg  [2:0] bdln_latch;
(* dont_touch = "true" *) reg  [2:0] bdln_status;
(* dont_touch = "true" *) reg  [2:0] bdln_pl_status;
(* dont_touch = "true" *) reg  [2:0] bdln_fetch_state;
(* dont_touch = "true" *) reg  [1:0] bdln_fetch_delay;
(* dont_touch = "true" *) reg  [1:0] bdln_bus_pending;
(* dont_touch = "true" *) reg         bdln_final_transfer;
(* dont_touch = "true" *) reg  [1:0] bdln_transfer_n;
(* dont_touch = "true" *) reg  [19:0] bdln_address_latch;
(* dont_touch = "true" *) reg  [7:0] bdln_data_bus;
(* dont_touch = "true" *) reg         bdln_discard;
(* dont_touch = "true" *) reg  [15:0] bdln_pc;
(* dont_touch = "true" *) reg  [3:0] bdln_rphase;
(* dont_touch = "true" *) reg  [2:0] bdln_r_type;
(* dont_touch = "true" *) reg  [19:0] bdln_r_addr0;
(* dont_touch = "true" *) reg  [19:0] bdln_r_addr1;
(* dont_touch = "true" *) reg  [15:0] bdln_r_data;
(* dont_touch = "true" *) reg         bdln_r_word;
(* dont_touch = "true" *) reg         bdln_r_second;
(* dont_touch = "true" *) reg         bdln_r_was_delay;
(* dont_touch = "true" *) reg         bdln_r_abort;
(* dont_touch = "true" *) reg  [1:0] bdln_r_delay_cnt;
(* dont_touch = "true" *) reg         bdln_t3_last;
(* dont_touch = "true" *) reg         bdln_inta_lock;
(* dont_touch = "true" *) reg  [2:0] bdlt_t_cycle;
(* dont_touch = "true" *) reg  [2:0] bdlt_ta_cycle;
(* dont_touch = "true" *) reg  [2:0] bdlt_latch;
(* dont_touch = "true" *) reg  [2:0] bdlt_status;
(* dont_touch = "true" *) reg  [2:0] bdlt_pl_status;
(* dont_touch = "true" *) reg  [2:0] bdlt_fetch_state;
(* dont_touch = "true" *) reg  [1:0] bdlt_fetch_delay;
(* dont_touch = "true" *) reg  [1:0] bdlt_bus_pending;
(* dont_touch = "true" *) reg         bdlt_final_transfer;
(* dont_touch = "true" *) reg  [1:0] bdlt_transfer_n;
(* dont_touch = "true" *) reg  [19:0] bdlt_address_latch;
(* dont_touch = "true" *) reg  [7:0] bdlt_data_bus;
(* dont_touch = "true" *) reg         bdlt_discard;
(* dont_touch = "true" *) reg  [15:0] bdlt_pc;
(* dont_touch = "true" *) reg  [3:0] bdlt_rphase;
(* dont_touch = "true" *) reg  [2:0] bdlt_r_type;
(* dont_touch = "true" *) reg  [19:0] bdlt_r_addr0;
(* dont_touch = "true" *) reg  [19:0] bdlt_r_addr1;
(* dont_touch = "true" *) reg  [15:0] bdlt_r_data;
(* dont_touch = "true" *) reg         bdlt_r_word;
(* dont_touch = "true" *) reg         bdlt_r_second;
(* dont_touch = "true" *) reg         bdlt_r_was_delay;
(* dont_touch = "true" *) reg         bdlt_r_abort;
(* dont_touch = "true" *) reg  [1:0] bdlt_r_delay_cnt;
(* dont_touch = "true" *) reg         bdlt_t3_last;
(* dont_touch = "true" *) reg         bdlt_inta_lock;
(* dont_touch = "true" *) reg  [2:0] bdlc_t_cycle;
(* dont_touch = "true" *) reg  [2:0] bdlc_ta_cycle;
(* dont_touch = "true" *) reg  [2:0] bdlc_latch;
(* dont_touch = "true" *) reg  [2:0] bdlc_status;
(* dont_touch = "true" *) reg  [2:0] bdlc_pl_status;
(* dont_touch = "true" *) reg  [2:0] bdlc_fetch_state;
(* dont_touch = "true" *) reg  [1:0] bdlc_fetch_delay;
(* dont_touch = "true" *) reg  [1:0] bdlc_bus_pending;
(* dont_touch = "true" *) reg         bdlc_final_transfer;
(* dont_touch = "true" *) reg  [1:0] bdlc_transfer_n;
(* dont_touch = "true" *) reg  [19:0] bdlc_address_latch;
(* dont_touch = "true" *) reg  [7:0] bdlc_data_bus;
(* dont_touch = "true" *) reg         bdlc_discard;
(* dont_touch = "true" *) reg  [15:0] bdlc_pc;
(* dont_touch = "true" *) reg  [3:0] bdlc_rphase;
(* dont_touch = "true" *) reg  [2:0] bdlc_r_type;
(* dont_touch = "true" *) reg  [19:0] bdlc_r_addr0;
(* dont_touch = "true" *) reg  [19:0] bdlc_r_addr1;
(* dont_touch = "true" *) reg  [15:0] bdlc_r_data;
(* dont_touch = "true" *) reg         bdlc_r_word;
(* dont_touch = "true" *) reg         bdlc_r_second;
(* dont_touch = "true" *) reg         bdlc_r_was_delay;
(* dont_touch = "true" *) reg         bdlc_r_abort;
(* dont_touch = "true" *) reg  [1:0] bdlc_r_delay_cnt;
(* dont_touch = "true" *) reg         bdlc_t3_last;
(* dont_touch = "true" *) reg         bdlc_inta_lock;
(* dont_touch = "true" *) reg  [2:0]  bd_ksel;
// ... and the fast values its step reads
(* dont_touch = "true" *) reg [2:0]  sn_qlen;
(* dont_touch = "true" *) reg [15:0] sn_cs;
(* dont_touch = "true" *) reg [11:0] sn_since_dispatch, sn_since_read, sn_since_done, sn_rel_n;
(* dont_touch = "true" *) reg        sn_rel_abs, sn_rel_done;

// ------------------------------------------------------------------ fast state

reg  [7:0]  q0, q1, q2, q3;
reg  [2:0]  qlen;
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
reg  [11:0] sp_dispatch, sp_read, sp_done;  // each + 1 (saturating): their value
                                  // after the next step, kept ready
reg         cz;                   // counter == 0, kept with every counter change
reg         cz_gr, cz_gd, cz_sr, cz_sd;   // cz = cz_gr/cz_gd when cz_sr/cz_sd,
reg         cz_o;                         // else cz_o
reg         sdn_rst;              // since_done was reset in this clock (RP_WAIT)
reg  [11:0] sdn_pre;              // ... and its value before that
reg  [11:0] s0_d, s0_r, s0_n, p0_d, p0_r, p0_n;   // since_x / sp_x at the clock's start
reg         sr_armed;             // a scheduled subsequent-byte read
reg  [11:0] sr_n;
reg  [1:0]  sr_base;              // 00 last queue read, 01 transfer end, 10 opcode
reg         sr_two;               // a second byte in the next cycle
reg  [15:0] return_data;
reg         done;
reg         cb_s;
reg         cb;                   // a code fetch is running and not in its T4
                                  // (= latch == ST_CODE && t_cycle != T4 of
                                  // the model; only steps change it)

reg         eu_req_d1, strobe_d1;
reg         nmi_d1, nmi_d2, nmi_caught;

// MCL86 pipelines the queue view by one core clock; keep that latency
reg  [7:0]  pfq_top_d1;
reg         pfq_empty_d1;
reg  [15:0] pfq_addr_d1;

// win1, win2: the clocks after a step
reg         win1, win2;
wire        hold = step | win1;   // bd*/sn_* keep the state the step found

// ------------------------------------------------------------------ event records
// What the EU's events of one clock do to the bus state. ev_* is the record
// being applied, lv_* this clock's (from the fast part, with the f_*
// decisions), p1_*/pw_* those of the step's clock and the next, p2_* the
// pending one (pend).

reg         ev_take, ev_hit3;   // queue reads; the queue went from 3+ to 2-
reg         ev_flush; reg [15:0] ev_ip;
reg         ev_susp;
reg         ev_req, ev_hold, ev_rword; reg [2:0] ev_rtype; reg [15:0] ev_rdata;
reg  [19:0] ev_raddr0, ev_raddr1;
reg         ev_pre;  reg [2:0] ev_plen; reg [15:0] ev_pip;

reg         lv_flush; reg [15:0] lv_ip;
reg         lv_susp;
reg         lv_req, lv_rword; reg [2:0] lv_rtype; reg [15:0] lv_rdata;
reg  [19:0] lv_raddr0, lv_raddr1;
reg         lv_pre;  reg [2:0] lv_plen; reg [15:0] lv_pip;

reg         p1_take, p1_hit3;
reg         p1_flush; reg [15:0] p1_ip;
reg         p1_susp;
reg         p1_req, p1_hold, p1_rword; reg [2:0] p1_rtype; reg [15:0] p1_rdata;
reg  [19:0] p1_raddr0, p1_raddr1;
reg         p1_pre;  reg [2:0] p1_plen; reg [15:0] p1_pip;
reg  [7:0]  p1_adin; reg p1_ready;

reg         p2_take, p2_hit3;
reg         p2_flush; reg [15:0] p2_ip;
reg         p2_susp;
reg         p2_req, p2_hold, p2_rword; reg [2:0] p2_rtype; reg [15:0] p2_rdata;
reg  [19:0] p2_raddr0, p2_raddr1;
reg         p2_pre;  reg [2:0] p2_plen; reg [15:0] p2_pip;

reg         pw_take, pw_hit3;
reg         pw_flush; reg [15:0] pw_ip;
reg         pw_susp;
reg         pw_req, pw_hold, pw_rword; reg [2:0] pw_rtype; reg [15:0] pw_rdata;
reg  [19:0] pw_raddr0, pw_raddr1;
reg         pw_pre;  reg [2:0] pw_plen; reg [15:0] pw_pip;

// working values of the bus part for the fast state it reads
reg  [2:0]  bqlen;
// the step's pins enter at the end of its chain (their register,
// p1_adin/p1_ready, is written on the step's clock): T3/Tw took AD_IN into
// data_bus (db_cap, until something else writes data_bus), T2/Tw took READY
// into t3_last (rdy_cap), and a final write's resume point waits for READY
// (wf_pend: rphase becomes RP_IDLE then, unless an event of the chain set
// rphase: rph_w)
reg         db_cap, rdy_cap, wf_pend, rph_w;
reg         rq2;                  // a recorded clock without request merges
reg         p2_rq;                // the recorded clock made a request (or preload)
reg         pend;                 // p2 holds a clock not applied yet
// copies of the bus state (see the bus part of the main block)
reg  [2:0] sv_t_cycle;
reg  [2:0] sv_ta_cycle;
reg  [2:0] sv_latch;
reg  [2:0] sv_status;
reg  [2:0] sv_pl_status;
reg  [2:0] sv_fetch_state;
reg  [1:0] sv_fetch_delay;
reg  [1:0] sv_bus_pending;
reg         sv_final_transfer;
reg  [1:0] sv_transfer_n;
reg  [19:0] sv_address_latch;
reg  [7:0] sv_data_bus;
reg         sv_discard;
reg  [15:0] sv_pc;
reg  [3:0] sv_rphase;
reg  [2:0] sv_r_type;
reg  [19:0] sv_r_addr0;
reg  [19:0] sv_r_addr1;
reg  [15:0] sv_r_data;
reg         sv_r_word;
reg         sv_r_second;
reg         sv_r_was_delay;
reg         sv_r_abort;
reg  [1:0] sv_r_delay_cnt;
reg         sv_t3_last;
reg         sv_inta_lock;
reg  [2:0] t0_t_cycle;
reg  [2:0] t0_ta_cycle;
reg  [2:0] t0_latch;
reg  [2:0] t0_status;
reg  [2:0] t0_pl_status;
reg  [2:0] t0_fetch_state;
reg  [1:0] t0_fetch_delay;
reg  [1:0] t0_bus_pending;
reg         t0_final_transfer;
reg  [1:0] t0_transfer_n;
reg  [19:0] t0_address_latch;
reg  [7:0] t0_data_bus;
reg         t0_discard;
reg  [15:0] t0_pc;
reg  [3:0] t0_rphase;
reg  [2:0] t0_r_type;
reg  [19:0] t0_r_addr0;
reg  [19:0] t0_r_addr1;
reg  [15:0] t0_r_data;
reg         t0_r_word;
reg         t0_r_second;
reg         t0_r_was_delay;
reg         t0_r_abort;
reg  [1:0] t0_r_delay_cnt;
reg         t0_t3_last;
reg         t0_inta_lock;
reg  [2:0] t1_t_cycle;
reg  [2:0] t1_ta_cycle;
reg  [2:0] t1_latch;
reg  [2:0] t1_status;
reg  [2:0] t1_pl_status;
reg  [2:0] t1_fetch_state;
reg  [1:0] t1_fetch_delay;
reg  [1:0] t1_bus_pending;
reg         t1_final_transfer;
reg  [1:0] t1_transfer_n;
reg  [19:0] t1_address_latch;
reg  [7:0] t1_data_bus;
reg         t1_discard;
reg  [15:0] t1_pc;
reg  [3:0] t1_rphase;
reg  [2:0] t1_r_type;
reg  [19:0] t1_r_addr0;
reg  [19:0] t1_r_addr1;
reg  [15:0] t1_r_data;
reg         t1_r_word;
reg         t1_r_second;
reg         t1_r_was_delay;
reg         t1_r_abort;
reg  [1:0] t1_r_delay_cnt;
reg         t1_t3_last;
reg         t1_inta_lock;
reg  [2:0] wc_t_cycle;
reg  [2:0] wc_ta_cycle;
reg  [2:0] wc_latch;
reg  [2:0] wc_status;
reg  [2:0] wc_pl_status;
reg  [2:0] wc_fetch_state;
reg  [1:0] wc_fetch_delay;
reg  [1:0] wc_bus_pending;
reg         wc_final_transfer;
reg  [1:0] wc_transfer_n;
reg  [19:0] wc_address_latch;
reg  [7:0] wc_data_bus;
reg         wc_discard;
reg  [15:0] wc_pc;
reg  [3:0] wc_rphase;
reg  [2:0] wc_r_type;
reg  [19:0] wc_r_addr0;
reg  [19:0] wc_r_addr1;
reg  [15:0] wc_r_data;
reg         wc_r_word;
reg         wc_r_second;
reg         wc_r_was_delay;
reg         wc_r_abort;
reg  [1:0] wc_r_delay_cnt;
reg         wc_t3_last;
reg         wc_inta_lock;
reg  [2:0] ep_t_cycle;
reg  [2:0] ep_ta_cycle;
reg  [2:0] ep_latch;
reg  [2:0] ep_status;
reg  [2:0] ep_pl_status;
reg  [2:0] ep_fetch_state;
reg  [1:0] ep_fetch_delay;
reg  [1:0] ep_bus_pending;
reg         ep_final_transfer;
reg  [1:0] ep_transfer_n;
reg  [19:0] ep_address_latch;
reg  [7:0] ep_data_bus;
reg         ep_discard;
reg  [15:0] ep_pc;
reg  [3:0] ep_rphase;
reg  [2:0] ep_r_type;
reg  [19:0] ep_r_addr0;
reg  [19:0] ep_r_addr1;
reg  [15:0] ep_r_data;
reg         ep_r_word;
reg         ep_r_second;
reg         ep_r_was_delay;
reg         ep_r_abort;
reg  [1:0] ep_r_delay_cnt;
reg         ep_t3_last;
reg         ep_inta_lock;
reg  [2:0] vn_t_cycle;
reg  [2:0] vn_ta_cycle;
reg  [2:0] vn_latch;
reg  [2:0] vn_status;
reg  [2:0] vn_pl_status;
reg  [2:0] vn_fetch_state;
reg  [1:0] vn_fetch_delay;
reg  [1:0] vn_bus_pending;
reg         vn_final_transfer;
reg  [1:0] vn_transfer_n;
reg  [19:0] vn_address_latch;
reg  [7:0] vn_data_bus;
reg         vn_discard;
reg  [15:0] vn_pc;
reg  [3:0] vn_rphase;
reg  [2:0] vn_r_type;
reg  [19:0] vn_r_addr0;
reg  [19:0] vn_r_addr1;
reg  [15:0] vn_r_data;
reg         vn_r_word;
reg         vn_r_second;
reg         vn_r_was_delay;
reg         vn_r_abort;
reg  [1:0] vn_r_delay_cnt;
reg         vn_t3_last;
reg         vn_inta_lock;
reg  [2:0] vt_t_cycle;
reg  [2:0] vt_ta_cycle;
reg  [2:0] vt_latch;
reg  [2:0] vt_status;
reg  [2:0] vt_pl_status;
reg  [2:0] vt_fetch_state;
reg  [1:0] vt_fetch_delay;
reg  [1:0] vt_bus_pending;
reg         vt_final_transfer;
reg  [1:0] vt_transfer_n;
reg  [19:0] vt_address_latch;
reg  [7:0] vt_data_bus;
reg         vt_discard;
reg  [15:0] vt_pc;
reg  [3:0] vt_rphase;
reg  [2:0] vt_r_type;
reg  [19:0] vt_r_addr0;
reg  [19:0] vt_r_addr1;
reg  [15:0] vt_r_data;
reg         vt_r_word;
reg         vt_r_second;
reg         vt_r_was_delay;
reg         vt_r_abort;
reg  [1:0] vt_r_delay_cnt;
reg         vt_t3_last;
reg         vt_inta_lock;
reg  [2:0] vc_t_cycle;
reg  [2:0] vc_ta_cycle;
reg  [2:0] vc_latch;
reg  [2:0] vc_status;
reg  [2:0] vc_pl_status;
reg  [2:0] vc_fetch_state;
reg  [1:0] vc_fetch_delay;
reg  [1:0] vc_bus_pending;
reg         vc_final_transfer;
reg  [1:0] vc_transfer_n;
reg  [19:0] vc_address_latch;
reg  [7:0] vc_data_bus;
reg         vc_discard;
reg  [15:0] vc_pc;
reg  [3:0] vc_rphase;
reg  [2:0] vc_r_type;
reg  [19:0] vc_r_addr0;
reg  [19:0] vc_r_addr1;
reg  [15:0] vc_r_data;
reg         vc_r_word;
reg         vc_r_second;
reg         vc_r_was_delay;
reg         vc_r_abort;
reg  [1:0] vc_r_delay_cnt;
reg         vc_t3_last;
reg         vc_inta_lock;
reg  [2:0] hn_t_cycle;
reg  [2:0] hn_ta_cycle;
reg  [2:0] hn_latch;
reg  [2:0] hn_status;
reg  [2:0] hn_pl_status;
reg  [2:0] hn_fetch_state;
reg  [1:0] hn_fetch_delay;
reg  [1:0] hn_bus_pending;
reg         hn_final_transfer;
reg  [1:0] hn_transfer_n;
reg  [19:0] hn_address_latch;
reg  [7:0] hn_data_bus;
reg         hn_discard;
reg  [15:0] hn_pc;
reg  [3:0] hn_rphase;
reg  [2:0] hn_r_type;
reg  [19:0] hn_r_addr0;
reg  [19:0] hn_r_addr1;
reg  [15:0] hn_r_data;
reg         hn_r_word;
reg         hn_r_second;
reg         hn_r_was_delay;
reg         hn_r_abort;
reg  [1:0] hn_r_delay_cnt;
reg         hn_t3_last;
reg         hn_inta_lock;
reg  [2:0] ht_t_cycle;
reg  [2:0] ht_ta_cycle;
reg  [2:0] ht_latch;
reg  [2:0] ht_status;
reg  [2:0] ht_pl_status;
reg  [2:0] ht_fetch_state;
reg  [1:0] ht_fetch_delay;
reg  [1:0] ht_bus_pending;
reg         ht_final_transfer;
reg  [1:0] ht_transfer_n;
reg  [19:0] ht_address_latch;
reg  [7:0] ht_data_bus;
reg         ht_discard;
reg  [15:0] ht_pc;
reg  [3:0] ht_rphase;
reg  [2:0] ht_r_type;
reg  [19:0] ht_r_addr0;
reg  [19:0] ht_r_addr1;
reg  [15:0] ht_r_data;
reg         ht_r_word;
reg         ht_r_second;
reg         ht_r_was_delay;
reg         ht_r_abort;
reg  [1:0] ht_r_delay_cnt;
reg         ht_t3_last;
reg         ht_inta_lock;
reg  [2:0] hc_t_cycle;
reg  [2:0] hc_ta_cycle;
reg  [2:0] hc_latch;
reg  [2:0] hc_status;
reg  [2:0] hc_pl_status;
reg  [2:0] hc_fetch_state;
reg  [1:0] hc_fetch_delay;
reg  [1:0] hc_bus_pending;
reg         hc_final_transfer;
reg  [1:0] hc_transfer_n;
reg  [19:0] hc_address_latch;
reg  [7:0] hc_data_bus;
reg         hc_discard;
reg  [15:0] hc_pc;
reg  [3:0] hc_rphase;
reg  [2:0] hc_r_type;
reg  [19:0] hc_r_addr0;
reg  [19:0] hc_r_addr1;
reg  [15:0] hc_r_data;
reg         hc_r_word;
reg         hc_r_second;
reg         hc_r_was_delay;
reg         hc_r_abort;
reg  [1:0] hc_r_delay_cnt;
reg         hc_t3_last;
reg         hc_inta_lock;
(* keep = "true" *) reg  [2:0] fn_t_cycle;
(* keep = "true" *) reg  [2:0] fn_ta_cycle;
(* keep = "true" *) reg  [2:0] fn_latch;
(* keep = "true" *) reg  [2:0] fn_status;
(* keep = "true" *) reg  [2:0] fn_pl_status;
(* keep = "true" *) reg  [2:0] fn_fetch_state;
(* keep = "true" *) reg  [1:0] fn_fetch_delay;
(* keep = "true" *) reg  [1:0] fn_bus_pending;
(* keep = "true" *) reg         fn_final_transfer;
(* keep = "true" *) reg  [1:0] fn_transfer_n;
(* keep = "true" *) reg  [19:0] fn_address_latch;
(* keep = "true" *) reg  [7:0] fn_data_bus;
(* keep = "true" *) reg         fn_discard;
(* keep = "true" *) reg  [15:0] fn_pc;
(* keep = "true" *) reg  [3:0] fn_rphase;
(* keep = "true" *) reg  [2:0] fn_r_type;
(* keep = "true" *) reg  [19:0] fn_r_addr0;
(* keep = "true" *) reg  [19:0] fn_r_addr1;
(* keep = "true" *) reg  [15:0] fn_r_data;
(* keep = "true" *) reg         fn_r_word;
(* keep = "true" *) reg         fn_r_second;
(* keep = "true" *) reg         fn_r_was_delay;
(* keep = "true" *) reg         fn_r_abort;
(* keep = "true" *) reg  [1:0] fn_r_delay_cnt;
(* keep = "true" *) reg         fn_t3_last;
(* keep = "true" *) reg         fn_inta_lock;
(* keep = "true" *) reg  [2:0] ft_t_cycle;
(* keep = "true" *) reg  [2:0] ft_ta_cycle;
(* keep = "true" *) reg  [2:0] ft_latch;
(* keep = "true" *) reg  [2:0] ft_status;
(* keep = "true" *) reg  [2:0] ft_pl_status;
(* keep = "true" *) reg  [2:0] ft_fetch_state;
(* keep = "true" *) reg  [1:0] ft_fetch_delay;
(* keep = "true" *) reg  [1:0] ft_bus_pending;
(* keep = "true" *) reg         ft_final_transfer;
(* keep = "true" *) reg  [1:0] ft_transfer_n;
(* keep = "true" *) reg  [19:0] ft_address_latch;
(* keep = "true" *) reg  [7:0] ft_data_bus;
(* keep = "true" *) reg         ft_discard;
(* keep = "true" *) reg  [15:0] ft_pc;
(* keep = "true" *) reg  [3:0] ft_rphase;
(* keep = "true" *) reg  [2:0] ft_r_type;
(* keep = "true" *) reg  [19:0] ft_r_addr0;
(* keep = "true" *) reg  [19:0] ft_r_addr1;
(* keep = "true" *) reg  [15:0] ft_r_data;
(* keep = "true" *) reg         ft_r_word;
(* keep = "true" *) reg         ft_r_second;
(* keep = "true" *) reg         ft_r_was_delay;
(* keep = "true" *) reg         ft_r_abort;
(* keep = "true" *) reg  [1:0] ft_r_delay_cnt;
(* keep = "true" *) reg         ft_t3_last;
(* keep = "true" *) reg         ft_inta_lock;
(* keep = "true" *) reg  [2:0] fc_t_cycle;
(* keep = "true" *) reg  [2:0] fc_ta_cycle;
(* keep = "true" *) reg  [2:0] fc_latch;
(* keep = "true" *) reg  [2:0] fc_status;
(* keep = "true" *) reg  [2:0] fc_pl_status;
(* keep = "true" *) reg  [2:0] fc_fetch_state;
(* keep = "true" *) reg  [1:0] fc_fetch_delay;
(* keep = "true" *) reg  [1:0] fc_bus_pending;
(* keep = "true" *) reg         fc_final_transfer;
(* keep = "true" *) reg  [1:0] fc_transfer_n;
(* keep = "true" *) reg  [19:0] fc_address_latch;
(* keep = "true" *) reg  [7:0] fc_data_bus;
(* keep = "true" *) reg         fc_discard;
(* keep = "true" *) reg  [15:0] fc_pc;
(* keep = "true" *) reg  [3:0] fc_rphase;
(* keep = "true" *) reg  [2:0] fc_r_type;
(* keep = "true" *) reg  [19:0] fc_r_addr0;
(* keep = "true" *) reg  [19:0] fc_r_addr1;
(* keep = "true" *) reg  [15:0] fc_r_data;
(* keep = "true" *) reg         fc_r_word;
(* keep = "true" *) reg         fc_r_second;
(* keep = "true" *) reg         fc_r_was_delay;
(* keep = "true" *) reg         fc_r_abort;
(* keep = "true" *) reg  [1:0] fc_r_delay_cnt;
(* keep = "true" *) reg         fc_t3_last;
(* keep = "true" *) reg         fc_inta_lock;
(* keep = "true" *) reg  [2:0] gn_t_cycle;
(* keep = "true" *) reg  [2:0] gn_ta_cycle;
(* keep = "true" *) reg  [2:0] gn_latch;
(* keep = "true" *) reg  [2:0] gn_status;
(* keep = "true" *) reg  [2:0] gn_pl_status;
(* keep = "true" *) reg  [2:0] gn_fetch_state;
(* keep = "true" *) reg  [1:0] gn_fetch_delay;
(* keep = "true" *) reg  [1:0] gn_bus_pending;
(* keep = "true" *) reg         gn_final_transfer;
(* keep = "true" *) reg  [1:0] gn_transfer_n;
(* keep = "true" *) reg  [19:0] gn_address_latch;
(* keep = "true" *) reg  [7:0] gn_data_bus;
(* keep = "true" *) reg         gn_discard;
(* keep = "true" *) reg  [15:0] gn_pc;
(* keep = "true" *) reg  [3:0] gn_rphase;
(* keep = "true" *) reg  [2:0] gn_r_type;
(* keep = "true" *) reg  [19:0] gn_r_addr0;
(* keep = "true" *) reg  [19:0] gn_r_addr1;
(* keep = "true" *) reg  [15:0] gn_r_data;
(* keep = "true" *) reg         gn_r_word;
(* keep = "true" *) reg         gn_r_second;
(* keep = "true" *) reg         gn_r_was_delay;
(* keep = "true" *) reg         gn_r_abort;
(* keep = "true" *) reg  [1:0] gn_r_delay_cnt;
(* keep = "true" *) reg         gn_t3_last;
(* keep = "true" *) reg         gn_inta_lock;
(* keep = "true" *) reg  [2:0] gt_t_cycle;
(* keep = "true" *) reg  [2:0] gt_ta_cycle;
(* keep = "true" *) reg  [2:0] gt_latch;
(* keep = "true" *) reg  [2:0] gt_status;
(* keep = "true" *) reg  [2:0] gt_pl_status;
(* keep = "true" *) reg  [2:0] gt_fetch_state;
(* keep = "true" *) reg  [1:0] gt_fetch_delay;
(* keep = "true" *) reg  [1:0] gt_bus_pending;
(* keep = "true" *) reg         gt_final_transfer;
(* keep = "true" *) reg  [1:0] gt_transfer_n;
(* keep = "true" *) reg  [19:0] gt_address_latch;
(* keep = "true" *) reg  [7:0] gt_data_bus;
(* keep = "true" *) reg         gt_discard;
(* keep = "true" *) reg  [15:0] gt_pc;
(* keep = "true" *) reg  [3:0] gt_rphase;
(* keep = "true" *) reg  [2:0] gt_r_type;
(* keep = "true" *) reg  [19:0] gt_r_addr0;
(* keep = "true" *) reg  [19:0] gt_r_addr1;
(* keep = "true" *) reg  [15:0] gt_r_data;
(* keep = "true" *) reg         gt_r_word;
(* keep = "true" *) reg         gt_r_second;
(* keep = "true" *) reg         gt_r_was_delay;
(* keep = "true" *) reg         gt_r_abort;
(* keep = "true" *) reg  [1:0] gt_r_delay_cnt;
(* keep = "true" *) reg         gt_t3_last;
(* keep = "true" *) reg         gt_inta_lock;
(* keep = "true" *) reg  [2:0] gc_t_cycle;
(* keep = "true" *) reg  [2:0] gc_ta_cycle;
(* keep = "true" *) reg  [2:0] gc_latch;
(* keep = "true" *) reg  [2:0] gc_status;
(* keep = "true" *) reg  [2:0] gc_pl_status;
(* keep = "true" *) reg  [2:0] gc_fetch_state;
(* keep = "true" *) reg  [1:0] gc_fetch_delay;
(* keep = "true" *) reg  [1:0] gc_bus_pending;
(* keep = "true" *) reg         gc_final_transfer;
(* keep = "true" *) reg  [1:0] gc_transfer_n;
(* keep = "true" *) reg  [19:0] gc_address_latch;
(* keep = "true" *) reg  [7:0] gc_data_bus;
(* keep = "true" *) reg         gc_discard;
(* keep = "true" *) reg  [15:0] gc_pc;
(* keep = "true" *) reg  [3:0] gc_rphase;
(* keep = "true" *) reg  [2:0] gc_r_type;
(* keep = "true" *) reg  [19:0] gc_r_addr0;
(* keep = "true" *) reg  [19:0] gc_r_addr1;
(* keep = "true" *) reg  [15:0] gc_r_data;
(* keep = "true" *) reg         gc_r_word;
(* keep = "true" *) reg         gc_r_second;
(* keep = "true" *) reg         gc_r_was_delay;
(* keep = "true" *) reg         gc_r_abort;
(* keep = "true" *) reg  [1:0] gc_r_delay_cnt;
(* keep = "true" *) reg         gc_t3_last;
(* keep = "true" *) reg         gc_inta_lock;
reg  [11:0] b_since_dispatch, b_since_read, b_since_done;
// the same decisions as flat logic (f_*): the queue reads of a clock (qread,
// strobe, scheduled, end), whether any or a FIRST one happens, the CANCEL_DELAY
// condition and the request hold, from the values before the reads; the bus
// part uses these (EU_QREAD arrives late in the clock)
reg         f_tq01, f_tq11, f_tq, f_s, f_ts, f_fs, f_fb, f_tb, f_sra, f_srdue, f_tr, f_te;
reg         f_take, f_first, f_hit3, f_hold, f_reldue;
reg  [1:0]  fv_tq01, fv_tq11, fv_tq, fv_s, fv_ts, fv_fs, fv_fb, fv_tb, fv_tr, fv_te, fv_take, fv_first, fv_hit3, fv_hold;   // f_* per EU_QREAD value (bit = set)
reg  [1:0]  f_n2, f_n3;
reg  [7:0]  ft_te, ft_take, ft_first, ft_hit3, ft_hold;   // per {cz_gd, cz_gr, f_tr}
integer     j;
reg  [2:0]  f_q2, f_q3;
// their compares, in parallel for each value rel_n/sr_n can have after this
// clock's register strobe (the register, DATAOUT, the register + DATAOUT)
reg  [11:0] c_rn, c_rsum, c_srn, c_rneg;
reg         c_rovf;               // rel_n + DATAOUT >= 4096
reg         c_ge_d0, c_ge_d1, c_ge_d2, c_ge_n0, c_ge_n1, c_ge_n2, c_ge_r0, c_ge_r1, c_ge_r2;
reg         c_sge_d0, c_sge_d1, c_sge_n0, c_sge_n1, c_sge_r0, c_sge_r1;


// The outputs. The state above is kept with blocking assignments (the model is
// procedural); the copies below carry it to the outputs with nonblocking ones,
// so that the EU and the board (other processes on the same clock) read the
// value before the clock edge in simulation too, as they do in hardware.
reg  [15:0] o_reg_es;
reg  [15:0] o_reg_ss;
reg  [15:0] o_reg_cs;
reg  [15:0] o_reg_ds;
reg  [15:0] o_reg_rm;
reg  [15:0] o_reg_reg;
reg  [15:0] o_return_data;
reg  [11:0] o_since_dispatch;
reg  [11:0] o_since_read;
reg  [11:0] o_since_done;
reg         o_sr_armed;
reg         o_done;
reg         o_nmi_caught;
reg  [7:0] o_pfq_top_d1;
reg         o_pfq_empty_d1;
reg  [15:0] o_pfq_addr_d1;
reg  [2:0] o_qlen;
reg  [1:0] o_qs_out;
reg  [7:0] o_qs_byte;
reg         o_biu_intr;
reg         o_counter_zero;
reg  [1:0]  qs_out;
reg  [7:0]  qs_byte;
reg         biu_intr;
assign QS_OUT   = o_qs_out;
assign QS_BYTE  = o_qs_byte;
assign BIU_INTR = o_biu_intr;


// the bus state, as the candidate ksel = {queue read, CANCEL_DELAY, request
// held} chooses (an 8:1 mux of registers), and the step's copy of it
function [19:0] kmux;
    input [2:0]  k;
    input [19:0] kn, kt, kc, ln, lt, lc;
    case (k)
        3'b000, 3'b010: kmux = kn;
        3'b001, 3'b011: kmux = ln;
        3'b100:         kmux = kt;
        3'b101:         kmux = lt;
        3'b110:         kmux = kc;
        default:        kmux = lc;
    endcase
endfunction
wire [2:0] v_t_cycle;
wire [2:0] bv_t_cycle;
assign v_t_cycle  = kmux(ksel, kn_t_cycle, kt_t_cycle, kc_t_cycle, ln_t_cycle, lt_t_cycle, lc_t_cycle);
assign bv_t_cycle = kmux(bd_ksel, bdkn_t_cycle, bdkt_t_cycle, bdkc_t_cycle, bdln_t_cycle, bdlt_t_cycle, bdlc_t_cycle);
wire [2:0] v_ta_cycle;
wire [2:0] bv_ta_cycle;
assign v_ta_cycle  = kmux(ksel, kn_ta_cycle, kt_ta_cycle, kc_ta_cycle, ln_ta_cycle, lt_ta_cycle, lc_ta_cycle);
assign bv_ta_cycle = kmux(bd_ksel, bdkn_ta_cycle, bdkt_ta_cycle, bdkc_ta_cycle, bdln_ta_cycle, bdlt_ta_cycle, bdlc_ta_cycle);
wire [2:0] v_latch;
wire [2:0] bv_latch;
assign v_latch  = kmux(ksel, kn_latch, kt_latch, kc_latch, ln_latch, lt_latch, lc_latch);
assign bv_latch = kmux(bd_ksel, bdkn_latch, bdkt_latch, bdkc_latch, bdln_latch, bdlt_latch, bdlc_latch);
wire [2:0] v_status;
wire [2:0] bv_status;
assign v_status  = kmux(ksel, kn_status, kt_status, kc_status, ln_status, lt_status, lc_status);
assign bv_status = kmux(bd_ksel, bdkn_status, bdkt_status, bdkc_status, bdln_status, bdlt_status, bdlc_status);
wire [2:0] v_pl_status;
wire [2:0] bv_pl_status;
assign v_pl_status  = kmux(ksel, kn_pl_status, kt_pl_status, kc_pl_status, ln_pl_status, lt_pl_status, lc_pl_status);
assign bv_pl_status = kmux(bd_ksel, bdkn_pl_status, bdkt_pl_status, bdkc_pl_status, bdln_pl_status, bdlt_pl_status, bdlc_pl_status);
wire [2:0] v_fetch_state;
wire [2:0] bv_fetch_state;
assign v_fetch_state  = kmux(ksel, kn_fetch_state, kt_fetch_state, kc_fetch_state, ln_fetch_state, lt_fetch_state, lc_fetch_state);
assign bv_fetch_state = kmux(bd_ksel, bdkn_fetch_state, bdkt_fetch_state, bdkc_fetch_state, bdln_fetch_state, bdlt_fetch_state, bdlc_fetch_state);
wire [1:0] v_fetch_delay;
wire [1:0] bv_fetch_delay;
assign v_fetch_delay  = kmux(ksel, kn_fetch_delay, kt_fetch_delay, kc_fetch_delay, ln_fetch_delay, lt_fetch_delay, lc_fetch_delay);
assign bv_fetch_delay = kmux(bd_ksel, bdkn_fetch_delay, bdkt_fetch_delay, bdkc_fetch_delay, bdln_fetch_delay, bdlt_fetch_delay, bdlc_fetch_delay);
wire [1:0] v_bus_pending;
wire [1:0] bv_bus_pending;
assign v_bus_pending  = kmux(ksel, kn_bus_pending, kt_bus_pending, kc_bus_pending, ln_bus_pending, lt_bus_pending, lc_bus_pending);
assign bv_bus_pending = kmux(bd_ksel, bdkn_bus_pending, bdkt_bus_pending, bdkc_bus_pending, bdln_bus_pending, bdlt_bus_pending, bdlc_bus_pending);
wire        v_final_transfer;
wire        bv_final_transfer;
assign v_final_transfer  = kmux(ksel, kn_final_transfer, kt_final_transfer, kc_final_transfer, ln_final_transfer, lt_final_transfer, lc_final_transfer);
assign bv_final_transfer = kmux(bd_ksel, bdkn_final_transfer, bdkt_final_transfer, bdkc_final_transfer, bdln_final_transfer, bdlt_final_transfer, bdlc_final_transfer);
wire [1:0] v_transfer_n;
wire [1:0] bv_transfer_n;
assign v_transfer_n  = kmux(ksel, kn_transfer_n, kt_transfer_n, kc_transfer_n, ln_transfer_n, lt_transfer_n, lc_transfer_n);
assign bv_transfer_n = kmux(bd_ksel, bdkn_transfer_n, bdkt_transfer_n, bdkc_transfer_n, bdln_transfer_n, bdlt_transfer_n, bdlc_transfer_n);
wire [19:0] v_address_latch;
wire [19:0] bv_address_latch;
assign v_address_latch  = kmux(ksel, kn_address_latch, kt_address_latch, kc_address_latch, ln_address_latch, lt_address_latch, lc_address_latch);
assign bv_address_latch = kmux(bd_ksel, bdkn_address_latch, bdkt_address_latch, bdkc_address_latch, bdln_address_latch, bdlt_address_latch, bdlc_address_latch);
wire [7:0] v_data_bus;
wire [7:0] bv_data_bus;
assign v_data_bus  = kmux(ksel, kn_data_bus, kt_data_bus, kc_data_bus, ln_data_bus, lt_data_bus, lc_data_bus);
assign bv_data_bus = kmux(bd_ksel, bdkn_data_bus, bdkt_data_bus, bdkc_data_bus, bdln_data_bus, bdlt_data_bus, bdlc_data_bus);
wire        v_discard;
wire        bv_discard;
assign v_discard  = kmux(ksel, kn_discard, kt_discard, kc_discard, ln_discard, lt_discard, lc_discard);
assign bv_discard = kmux(bd_ksel, bdkn_discard, bdkt_discard, bdkc_discard, bdln_discard, bdlt_discard, bdlc_discard);
wire [15:0] v_pc;
wire [15:0] bv_pc;
assign v_pc  = kmux(ksel, kn_pc, kt_pc, kc_pc, ln_pc, lt_pc, lc_pc);
assign bv_pc = kmux(bd_ksel, bdkn_pc, bdkt_pc, bdkc_pc, bdln_pc, bdlt_pc, bdlc_pc);
wire [3:0] v_rphase;
wire [3:0] bv_rphase;
assign v_rphase  = kmux(ksel, kn_rphase, kt_rphase, kc_rphase, ln_rphase, lt_rphase, lc_rphase);
assign bv_rphase = kmux(bd_ksel, bdkn_rphase, bdkt_rphase, bdkc_rphase, bdln_rphase, bdlt_rphase, bdlc_rphase);
wire [2:0] v_r_type;
wire [2:0] bv_r_type;
assign v_r_type  = kmux(ksel, kn_r_type, kt_r_type, kc_r_type, ln_r_type, lt_r_type, lc_r_type);
assign bv_r_type = kmux(bd_ksel, bdkn_r_type, bdkt_r_type, bdkc_r_type, bdln_r_type, bdlt_r_type, bdlc_r_type);
wire [19:0] v_r_addr0;
wire [19:0] bv_r_addr0;
assign v_r_addr0  = kmux(ksel, kn_r_addr0, kt_r_addr0, kc_r_addr0, ln_r_addr0, lt_r_addr0, lc_r_addr0);
assign bv_r_addr0 = kmux(bd_ksel, bdkn_r_addr0, bdkt_r_addr0, bdkc_r_addr0, bdln_r_addr0, bdlt_r_addr0, bdlc_r_addr0);
wire [19:0] v_r_addr1;
wire [19:0] bv_r_addr1;
assign v_r_addr1  = kmux(ksel, kn_r_addr1, kt_r_addr1, kc_r_addr1, ln_r_addr1, lt_r_addr1, lc_r_addr1);
assign bv_r_addr1 = kmux(bd_ksel, bdkn_r_addr1, bdkt_r_addr1, bdkc_r_addr1, bdln_r_addr1, bdlt_r_addr1, bdlc_r_addr1);
wire [15:0] v_r_data;
wire [15:0] bv_r_data;
assign v_r_data  = kmux(ksel, kn_r_data, kt_r_data, kc_r_data, ln_r_data, lt_r_data, lc_r_data);
assign bv_r_data = kmux(bd_ksel, bdkn_r_data, bdkt_r_data, bdkc_r_data, bdln_r_data, bdlt_r_data, bdlc_r_data);
wire        v_r_word;
wire        bv_r_word;
assign v_r_word  = kmux(ksel, kn_r_word, kt_r_word, kc_r_word, ln_r_word, lt_r_word, lc_r_word);
assign bv_r_word = kmux(bd_ksel, bdkn_r_word, bdkt_r_word, bdkc_r_word, bdln_r_word, bdlt_r_word, bdlc_r_word);
wire        v_r_second;
wire        bv_r_second;
assign v_r_second  = kmux(ksel, kn_r_second, kt_r_second, kc_r_second, ln_r_second, lt_r_second, lc_r_second);
assign bv_r_second = kmux(bd_ksel, bdkn_r_second, bdkt_r_second, bdkc_r_second, bdln_r_second, bdlt_r_second, bdlc_r_second);
wire        v_r_was_delay;
wire        bv_r_was_delay;
assign v_r_was_delay  = kmux(ksel, kn_r_was_delay, kt_r_was_delay, kc_r_was_delay, ln_r_was_delay, lt_r_was_delay, lc_r_was_delay);
assign bv_r_was_delay = kmux(bd_ksel, bdkn_r_was_delay, bdkt_r_was_delay, bdkc_r_was_delay, bdln_r_was_delay, bdlt_r_was_delay, bdlc_r_was_delay);
wire        v_r_abort;
wire        bv_r_abort;
assign v_r_abort  = kmux(ksel, kn_r_abort, kt_r_abort, kc_r_abort, ln_r_abort, lt_r_abort, lc_r_abort);
assign bv_r_abort = kmux(bd_ksel, bdkn_r_abort, bdkt_r_abort, bdkc_r_abort, bdln_r_abort, bdlt_r_abort, bdlc_r_abort);
wire [1:0] v_r_delay_cnt;
wire [1:0] bv_r_delay_cnt;
assign v_r_delay_cnt  = kmux(ksel, kn_r_delay_cnt, kt_r_delay_cnt, kc_r_delay_cnt, ln_r_delay_cnt, lt_r_delay_cnt, lc_r_delay_cnt);
assign bv_r_delay_cnt = kmux(bd_ksel, bdkn_r_delay_cnt, bdkt_r_delay_cnt, bdkc_r_delay_cnt, bdln_r_delay_cnt, bdlt_r_delay_cnt, bdlc_r_delay_cnt);
wire        v_t3_last;
wire        bv_t3_last;
assign v_t3_last  = kmux(ksel, kn_t3_last, kt_t3_last, kc_t3_last, ln_t3_last, lt_t3_last, lc_t3_last);
assign bv_t3_last = kmux(bd_ksel, bdkn_t3_last, bdkt_t3_last, bdkc_t3_last, bdln_t3_last, bdlt_t3_last, bdlc_t3_last);
wire        v_inta_lock;
wire        bv_inta_lock;
assign v_inta_lock  = kmux(ksel, kn_inta_lock, kt_inta_lock, kc_inta_lock, ln_inta_lock, lt_inta_lock, lc_inta_lock);
assign bv_inta_lock = kmux(bd_ksel, bdkn_inta_lock, bdkt_inta_lock, bdkc_inta_lock, bdln_inta_lock, bdlt_inta_lock, bdlc_inta_lock);

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
assign BIU_CLK_COUNTER_ZERO = o_counter_zero;
assign BIU_NMI_CAUGHT       = o_nmi_caught;
assign LOCK_n               = ~(v_inta_lock | EU_PREFIX_LOCK);

assign PFQ_TOP_BYTE = o_pfq_top_d1;
assign PFQ_EMPTY    = o_pfq_empty_d1;
assign PFQ_ADDR_OUT = o_pfq_addr_d1;

// pins
assign ALE       = v_t_cycle == T1 && v_latch != ST_PASV && v_latch != ST_HALT;
assign S2_S0_OUT = (v_t_cycle == T1 || v_t_cycle == T2) ? v_status : ST_PASV;
assign AD_OE     = 1'b1;
assign AD_OUT    = v_t_cycle == T1 ? v_address_latch : {v_address_latch[19:8], v_data_bus};
assign S6_3_MUX  = v_t_cycle != T1;

assign dbg_t_state   = v_t_cycle;
assign dbg_ta_state  = v_ta_cycle;
assign dbg_latch     = v_latch;
assign dbg_queue_len = o_qlen;

// ------------------------------------------------------------------ the step, as the fast part sees it
// Facts about the bus state after a step's do_cycle, from the bus state
// before it (all registers here; the step does not change them in its own
// clock). The bus part computes the same in full.

// a code fetch pushes its byte at T4
wire        st_push   = v_latch == ST_CODE && v_t_cycle == T4 && !v_discard;
// the data bus after the step: a read takes AD_IN in T3/Tw
wire        st_rd     = v_latch == ST_CODE || v_latch == ST_MEMR || v_latch == ST_IOR || v_latch == ST_INTA;
wire [7:0]  st_db     = (v_t_cycle == T3 || v_t_cycle == TW) && st_rd ? AD_IN : v_data_bus;
// the next T-state is T4 (a read's resume point)
wire        st_t4     = (v_t_cycle == T3 || v_t_cycle == TW) && v_t3_last;
// the next T-state is T3/Tw, and the last one (READY): a write's resume point
wire        st_t3last = (v_t_cycle == T2 || (v_t_cycle == T3 || v_t_cycle == TW) && !v_t3_last) && READY_IN;
wire        r_write   = v_r_type == ST_MEMW || v_r_type == ST_IOW;
// a code fetch starts at the address cycle's T0 (do_cycle: bus_begin_fetch)
wire [2:0]  st_qlen   = st_push && qlen != 3'd4 ? qlen + 3'd1 : qlen;
wire        st_fetch  = (v_t_cycle == TI || v_t_cycle == T4) && v_ta_cycle == TA_T0 &&
                        v_pl_status == ST_CODE && v_bus_pending == BP_NONE &&
                        v_fetch_state != FS_SUSP && v_fetch_state != FS_HALTED && st_qlen <= 3'd3;
// a code fetch is running after the step, and not in its T4 (RP_T4 starts the
// EU's cycle in this step whatever the address cycle did)
wire        cb_pred   = v_rphase != RP_T4 &&
                        (v_latch == ST_CODE && (v_t_cycle == T1 || v_t_cycle == T2 ||
                                              (v_t_cycle == T3 || v_t_cycle == TW) && !v_t3_last) ||
                         st_fetch);

// ------------------------------------------------------------------ helpers

function ge_s;                // since_x >= n, since_x after this clock's step
    input [11:0] since0, sp0, n;  // (the register, the register + 1)
    ge_s = step ? sp0 >= n : since0 >= n;
endfunction

function ge_sum;              // since_x (after this clock's step) >= (a + b) mod 4096,
    input [11:0] since0, sp0, a, b; // without a + b in series: with L = (x - a) mod
    input        ovf;               // 4096, x >= a + b <=> x >= a && L >= b when a + b
    reg   [12:0] d0, d1;            // < 4096 (ovf = 0), and x >= a + b - 4096 <=>
    reg          g0, g1;            // x >= a || L >= b when ovf = 1
    begin
        d0 = {1'b0, since0} - {1'b0, a};        // d0[12]: since0 < a
        d1 = {1'b0, sp0} - {1'b0, a};
        g0 = ovf ? !d0[12] || d0[11:0] >= b : !d0[12] && d0[11:0] >= b;
        g1 = ovf ? !d1[12] || d1[11:0] >= b : !d1[12] && d1[11:0] >= b;
        ge_sum = step ? g1 : g0;
    end
endfunction

function has_room;            // room for a 1-byte fetch
    input [2:0] len;
    has_room = len <= 3'd3;
endfunction

function rel_due_f;           // a held request may go
    input [11:0] n, sd, sr, sdn;
    input        abs, dn;
    rel_due_f = abs ? sd >= n : dn ? sdn >= n : sr >= n;
endfunction

// ---- fast part

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

// the byte at the head of the queue is read: it leaves the 4-byte queue and
// goes behind the bytes the EU has not popped yet (the bus part's side of it,
// MartyPC biu_queue_read: CANCEL_DELAY and fetch-on-queue-read, is bus_takes)
task take_byte;
    input [1:0] op;
    begin
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
            since_dispatch = 12'd0;  sp_dispatch = 12'd1;
            rel_armed = 1'b0;           // an unused release ends with its instruction
            sr_armed  = 1'b0;
        end
        since_read = 12'd0;  sp_read = 12'd1;
    end
endtask

// the queue reads of this clock as flat logic, for EU_QREAD = qr (the f_*
// decisions; see the main block)
task f_chain;
    input [1:0] qr;
    begin
        f_tq01 = qr == 2'b01 && !preread && ntaken == 2'd0 && qlen != 3'd0;
        f_tq11 = qr == 2'b11 && ntaken == 2'd0 && qlen != 3'd0;
        f_tq   = f_tq01 | f_tq11;
        f_s    = eu_strobe == 2'b01 && !strobe_d1;
        f_ts   = f_s && !f_tq && ntaken == 2'd0 && qlen != 3'd0;
        f_fs   = f_ts && eu_qs == 2'b01;
        f_fb   = f_tq01 | f_fs;                 // a FIRST read before the scheduled one
        f_tb   = f_tq | f_ts;                   // a read before it
        f_n2   = ntaken + {1'b0, f_tb};
        if (f_s && f_n2 != 2'd0) f_n2 = f_n2 - 2'd1;
        f_q2   = qlen - {2'b0, f_tb};
        f_sra  = sr_armed && !f_fb;
        f_srdue = sr_base == 2'b10 ? (f_fb ? sr_n == 12'd0 : c_sge_d0) :
                  sr_base == 2'b01 ? c_sge_n0 :
                                     (f_tb ? sr_n == 12'd0 : c_sge_r0);
        f_tr   = f_sra && f_srdue && f_n2 != 2'd3 && f_q2 != 3'd0;
        // the rest for f_tr = 0 and 1 (n3/q3 = n2/q2 + / - f_tr); f_tr selects
        // (and for both values of the compares cz may come from in this
        // clock: cz_gr, cz_gd)
        for (j = 0; j < 8; j = j + 1) begin
            f_n3   = f_n2 + {1'b0, j[0]};
            f_q3   = f_q2 - {2'b0, j[0]};
            f_te   = end_armed && !f_tq01 && (cz_sr ? j[1] : cz_sd ? j[2] : cz_o) &&
                     f_n3 != 2'd3 && f_q3 != 3'd0 && !(preread && qr != 2'b01);
            f_take  = f_tb | j[0] | f_te;
            f_first = f_fb | f_te;
            f_hit3  = qlen == 3'd3 && f_take ||
                      qlen == 3'd4 && (f_tb & j[0] | f_tb & f_te | j[0] & f_te);
            f_reldue = rel_abs  ? (f_first ? rel_n == 12'd0 : c_ge_d0) :
                       rel_done ? c_ge_n0 :
                                  (f_take ? rel_n == 12'd0 : c_ge_r0);
            f_hold  = rel_armed && !f_first && !f_reldue;
            ft_te[j] = f_te;  ft_take[j] = f_take;  ft_first[j] = f_first;
            ft_hit3[j] = f_hit3;  ft_hold[j] = f_hold;
        end
        f_te    = ft_te[{cz_gd, cz_gr, f_tr}];
        f_take  = ft_take[{cz_gd, cz_gr, f_tr}];
        f_first = ft_first[{cz_gd, cz_gr, f_tr}];
        f_hit3  = ft_hit3[{cz_gd, cz_gr, f_tr}];
        f_hold  = ft_hold[{cz_gd, cz_gr, f_tr}];
    end
endtask

task fv_save;
    input integer k;
    begin
        fv_tq01[k] = f_tq01;
        fv_tq11[k] = f_tq11;
        fv_tq[k] = f_tq;
        fv_s[k] = f_s;
        fv_ts[k] = f_ts;
        fv_fs[k] = f_fs;
        fv_fb[k] = f_fb;
        fv_tb[k] = f_tb;
        fv_tr[k] = f_tr;
        fv_te[k] = f_te;
        fv_take[k] = f_take;
        fv_first[k] = f_first;
        fv_hit3[k] = f_hit3;
        fv_hold[k] = f_hold;
    end
endtask

task fv_load;
    input integer k;
    begin
        f_tq01 = fv_tq01[k];
        f_tq11 = fv_tq11[k];
        f_tq = fv_tq[k];
        f_s = fv_s[k];
        f_ts = fv_ts[k];
        f_fs = fv_fs[k];
        f_fb = fv_fb[k];
        f_tb = fv_tb[k];
        f_tr = fv_tr[k];
        f_te = fv_te[k];
        f_take = fv_take[k];
        f_first = fv_first[k];
        f_hit3 = fv_hit3[k];
        f_hold = fv_hold[k];
    end
endtask

// ---- bus part (on the bus registers; bqlen stands for the queue length)

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
        if (!has_room(bqlen))
            fetch_state = FS_PAUSED;
        else if (bus_pending != BP_EARLY && fetch_state != FS_SUSP && fetch_state != FS_HALTED) begin
            if (bqlen == 3'd3 && latch == ST_CODE) begin
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
        if (has_room(bqlen)) begin
            fetch_state    = FS_NORMAL;
            pl_status      = ST_PASV;
            status         = ST_CODE;
            latch          = ST_CODE;
            t_cycle        = 3'd7;        // Tinit: becomes T1 for the next cycle
            address_latch  = {sn_cs, 4'h0} + {4'h0, pc};
            data_bus       = 8'h00;
            db_cap         = 1'b0;
            transfer_n     = 2'd1;
            final_transfer = 1'b1;
            discard        = 1'b0;
        end
    end
endtask

task fetch_on_queue_read;                               // FOQR
    begin
        // (has_room: a byte has just left the queue)
        if (status == ST_PASV) begin
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
        db_cap        = 1'b0;
        rphase        = RP_WAIT;
    end
endtask

// work through the request phases as far as the state allows (no cycle runs
// in here; every "wait" stops until the next step). A pass moves at most one
// phase on (FINISH -> ADDR/DELAY -> ADDR2/T4 -> T4) and DELAY/T4 stay, so
// three passes reach the end.
task request_advance;
    integer guard;
    begin
        for (guard = 0; guard < 3; guard = guard + 1) begin
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

// request_begin followed by request_advance, written out: from RP_FINISH the
// passes reach RP_FINISH (the running cycle is not at its end),
// RP_DELAY, RP_ADDR (address cycle running), RP_ADDR2 (after a delay/abort
// the new address cycle starts: TR/TS, so it cannot end in the same call) or
// RP_T4, and a T4 of a non-code cycle runs out before the bus cycle starts.
task request_go;
    reg [2:0] ta1;
    reg       go;
    begin
        // The bus cycle starts at once (request_begin and request_advance
        // below reach RP_T4, and no T4 of a non-code cycle has to run out)
        // exactly when: the running cycle is past T2 (Ti/T1/T2 start a new
        // address cycle: TR/TS), it is at its end (FINISH: passive or T4), no
        // fetch delay runs (it would go through RP_DELAY or RP_ADDR2), the
        // address cycle has ended (ADDR: TD/TA) and no code fetch is aborted
        // (abort: pl_status == ST_CODE goes through RP_ADDR2). Worked out
        // directly; the other cases below never start it.
        go = t_cycle != TI && t_cycle != T1 && t_cycle != T2 &&
             (latch == ST_PASV || t_cycle == T4) && fetch_state != FS_DELAYED &&
             (ta_cycle == TA_TD || ta_cycle == TA_TA) && pl_status != ST_CODE &&
             !(t_cycle == T4 && latch != ST_CODE);
        if (go) begin
            r_was_delay = 1'b0;
            r_abort     = 1'b0;
            request_bus_start;
        end else begin
            // request_begin
            r_was_delay = 1'b0;
            r_abort     = 1'b0;
            ta1         = ta_cycle == TA_TA ? TA_TS : TA_TR;
            case (t_cycle)
                TI:     begin ta_cycle = ta1; pl_status = r_type; end
                T1, T2: begin ta_cycle = ta1; pl_status = r_type; bus_pending = BP_EARLY; end
                default:
                    if (pl_status == ST_CODE) begin
                        bus_pending = BP_LATE;
                        r_abort = 1'b1;
                    end else if (!final_transfer)
                        bus_pending = BP_EARLY;
            endcase
            rphase = RP_FINISH;
            // request_advance
            if (latch == ST_PASV || t_cycle == T4) begin
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
                if (rphase == RP_ADDR && (ta_cycle == TA_TD || ta_cycle == TA_TA)) begin
                    if (r_was_delay || r_abort) begin
                        address_start(r_type);
                        rphase = RP_ADDR2;
                    end else
                        rphase = RP_T4;
                end
            end
        end
    end
endtask

// one 8088 clock: MartyPC cycle_i() (bus part; the push is the fast part's)
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
                    if (has_room(bqlen)) make_fetch_decision;
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
                            db_cap = 1'b1;          // data_bus = AD_IN
                        status = ST_PASV;
                    end
                    T4: begin
                        if (latch == ST_CODE) begin
                            if (!discard) begin
                                if (bqlen < 3'd4) bqlen = bqlen + 3'd1;
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
                rdy_cap = 1'b1;                     // t3_last = READY_IN
                if (latch == ST_INTA) inta_lock = transfer_n != 2'd2;
            end
            T3, TW: if (t3_last) t_cycle = T4;
                    else begin t_cycle = TW; rdy_cap = 1'b1; end
            T4: begin latch = ST_PASV; t_cycle = TI; end
            default: ;
        endcase
    end
endtask

// a step on the bus state (bd_* loaded; the fast values from sn_*)
task bus_step;
    begin
        bqlen = sn_qlen;
        db_cap = 1'b0;  rdy_cap = 1'b0;  wf_pend = 1'b0;
        b_since_dispatch = sn_since_dispatch;
        b_since_read     = sn_since_read;
        b_since_done     = sn_since_done;

        // MartyPC runs the request's wait loops cycle by cycle; the
        // conditions are checked at the boundary BEFORE each cycle, which
        // is here (state = the cycle about to run)
        do_cycle;

        if (b_since_dispatch != 12'hFFF) b_since_dispatch = b_since_dispatch + 12'd1;
        if (b_since_read != 12'hFFF) b_since_read = b_since_read + 12'd1;
        if (b_since_done != 12'hFFF) b_since_done = b_since_done + 12'd1;

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
                    if (r_word && !r_second) begin
                        r_second = 1'b1;
                        request_begin;            // second byte: same sequence
                    end else begin
                        rphase = RP_IDLE;
                        b_since_done = 12'd0;
                    end
                end else if ((t_cycle == T3 || t_cycle == TW) &&
                             (r_type == ST_MEMW || r_type == ST_IOW) &&
                             (!r_word || r_second)) begin
                    // && t3_last: T3/Tw are next only after T2 or a Tw, which
                    // took READY into t3_last (rdy_cap); rphase = RP_IDLE then.
                    // (The b_since_done = 0 here only matters for a held
                    // request, and rphase is not RP_HOLD.)
                    wf_pend = 1'b1;
                end
            end
            RP_SUSP:
                if (latch != ST_CODE || t_cycle == T4) begin
                    ta_cycle  = TA_TD;
                    pl_status = ST_PASV;
                    rphase    = RP_IDLE;
                end
            default: ;
        endcase
        if (rphase == RP_FINISH || rphase == RP_ADDR || rphase == RP_ADDR2)
            request_advance;

        // a held request is released at the start of its cycle; its
        // phases that need a whole cycle (a fetch delay) start counting
        // with the next step, as for a request the EU makes directly
        if (rphase == RP_HOLD && rel_due_f(sn_rel_n, b_since_dispatch, b_since_read,
                                           b_since_done, sn_rel_abs, sn_rel_done)) begin
            request_go;
        end
    end
endtask

// the EU's events of one clock on the bus state (record ev_*)
task bus_events;
    begin
        // bytes left the queue (MartyPC biu_queue_read side effects, per
        // byte: CANCEL_DELAY when the queue held 3 bytes before it, then
        // fetch-on-queue-read). For one or more bytes in a clock that is one
        // CANCEL_DELAY if the queue went from 3 or more to 2 or fewer
        // (ev_hit3), and one FOQR: FOQR cannot change fetch_state while it is
        // FS_DELAYED (so the CANCEL_DELAYs do not depend on the FOQRs), and a
        // second FOQR finds what the first left (pl_status = ST_CODE after a
        // fetch_start, else the same state again) and changes nothing.
        if (ev_take) bus_takes;
        bus_rest;
    end
endtask

task bus_takes;
    begin
        if (fetch_state == FS_DELAYED) begin
            if (ev_hit3) fetch_delay = 2'd0;            // CANCEL_DELAY
        end else
            fetch_on_queue_read;
    end
endtask

// the rest of a clock's events, after its queue reads (flush, SUSP and the
// other requests are one request code: at most one of them)
task bus_rest;
    begin
        if (ev_flush) begin                     // jump: flush the queue
            pc = ev_ip;
            if (latch == ST_CODE) discard = 1'b1;
            fetch_state = FS_NORMAL;
            fetch_start;
        end else if (ev_susp) begin             // SUSP
            fetch_state = FS_SUSP;
            rphase = RP_SUSP;
            rph_w  = 1'b1;
            // MartyPC biu_fetch_suspend: wait for a running code
            // fetch to reach T4 (no wait when this cycle is its T4)
            if (latch != ST_CODE || t_cycle == T4) begin
                ta_cycle  = TA_TD;
                pl_status = ST_PASV;
                rphase    = RP_IDLE;
            end
        end else if (ev_req) begin              // a bus request
            r_second = 1'b0;
            r_word   = ev_rword;
            r_data   = ev_rdata;
            r_addr0  = ev_raddr0;
            r_addr1  = ev_raddr1;
            r_type   = ev_rtype;
            if (r_type != ST_PASV) begin
                rph_w = 1'b1;
                if (ev_hold)
                    rphase = RP_HOLD;           // the EU is early: hold it
                else begin
                    request_go;
                end
            end
        end
        // test only: the queue as a prefetched test starts it
        bus_pre;
    end
endtask

// the preload part of bus_rest (test only)
task bus_pre;
    begin
        if (ev_pre) begin
            pc = ev_pip + {13'd0, ev_plen};
            ta_cycle = TA_TD;
            pl_status = ST_PASV;
            fetch_state = ev_plen == 3'd4 ? FS_PAUSED : FS_NORMAL;
            t_cycle = TI; latch = ST_PASV; status = ST_PASV;
            bus_pending = BP_NONE; discard = 1'b0;
        end
    end
endtask

task bus_save_sv;
    begin
        sv_t_cycle = t_cycle;  sv_ta_cycle = ta_cycle;  sv_latch = latch;  sv_status = status;
        sv_pl_status = pl_status;  sv_fetch_state = fetch_state;  sv_fetch_delay = fetch_delay;
        sv_bus_pending = bus_pending;  sv_final_transfer = final_transfer;
        sv_transfer_n = transfer_n;  sv_address_latch = address_latch;  sv_data_bus = data_bus;
        sv_discard = discard;  sv_pc = pc;  sv_rphase = rphase;  sv_r_type = r_type;
        sv_r_addr0 = r_addr0;  sv_r_addr1 = r_addr1;  sv_r_data = r_data;  sv_r_word = r_word;
        sv_r_second = r_second;  sv_r_was_delay = r_was_delay;  sv_r_abort = r_abort;
        sv_r_delay_cnt = r_delay_cnt;  sv_t3_last = t3_last;  sv_inta_lock = inta_lock;
    end
endtask

task bus_load_sv;
    begin
        t_cycle = sv_t_cycle;  ta_cycle = sv_ta_cycle;  latch = sv_latch;  status = sv_status;
        pl_status = sv_pl_status;  fetch_state = sv_fetch_state;  fetch_delay = sv_fetch_delay;
        bus_pending = sv_bus_pending;  final_transfer = sv_final_transfer;
        transfer_n = sv_transfer_n;  address_latch = sv_address_latch;  data_bus = sv_data_bus;
        discard = sv_discard;  pc = sv_pc;  rphase = sv_rphase;  r_type = sv_r_type;
        r_addr0 = sv_r_addr0;  r_addr1 = sv_r_addr1;  r_data = sv_r_data;  r_word = sv_r_word;
        r_second = sv_r_second;  r_was_delay = sv_r_was_delay;  r_abort = sv_r_abort;
        r_delay_cnt = sv_r_delay_cnt;  t3_last = sv_t3_last;  inta_lock = sv_inta_lock;
    end
endtask

task bus_save_t0;
    begin
        t0_t_cycle = t_cycle;  t0_ta_cycle = ta_cycle;  t0_latch = latch;  t0_status = status;
        t0_pl_status = pl_status;  t0_fetch_state = fetch_state;  t0_fetch_delay = fetch_delay;
        t0_bus_pending = bus_pending;  t0_final_transfer = final_transfer;
        t0_transfer_n = transfer_n;  t0_address_latch = address_latch;  t0_data_bus = data_bus;
        t0_discard = discard;  t0_pc = pc;  t0_rphase = rphase;  t0_r_type = r_type;
        t0_r_addr0 = r_addr0;  t0_r_addr1 = r_addr1;  t0_r_data = r_data;  t0_r_word = r_word;
        t0_r_second = r_second;  t0_r_was_delay = r_was_delay;  t0_r_abort = r_abort;
        t0_r_delay_cnt = r_delay_cnt;  t0_t3_last = t3_last;  t0_inta_lock = inta_lock;
    end
endtask

task bus_load_t0;
    begin
        t_cycle = t0_t_cycle;  ta_cycle = t0_ta_cycle;  latch = t0_latch;  status = t0_status;
        pl_status = t0_pl_status;  fetch_state = t0_fetch_state;  fetch_delay = t0_fetch_delay;
        bus_pending = t0_bus_pending;  final_transfer = t0_final_transfer;
        transfer_n = t0_transfer_n;  address_latch = t0_address_latch;  data_bus = t0_data_bus;
        discard = t0_discard;  pc = t0_pc;  rphase = t0_rphase;  r_type = t0_r_type;
        r_addr0 = t0_r_addr0;  r_addr1 = t0_r_addr1;  r_data = t0_r_data;  r_word = t0_r_word;
        r_second = t0_r_second;  r_was_delay = t0_r_was_delay;  r_abort = t0_r_abort;
        r_delay_cnt = t0_r_delay_cnt;  t3_last = t0_t3_last;  inta_lock = t0_inta_lock;
    end
endtask

task bus_save_t1;
    begin
        t1_t_cycle = t_cycle;  t1_ta_cycle = ta_cycle;  t1_latch = latch;  t1_status = status;
        t1_pl_status = pl_status;  t1_fetch_state = fetch_state;  t1_fetch_delay = fetch_delay;
        t1_bus_pending = bus_pending;  t1_final_transfer = final_transfer;
        t1_transfer_n = transfer_n;  t1_address_latch = address_latch;  t1_data_bus = data_bus;
        t1_discard = discard;  t1_pc = pc;  t1_rphase = rphase;  t1_r_type = r_type;
        t1_r_addr0 = r_addr0;  t1_r_addr1 = r_addr1;  t1_r_data = r_data;  t1_r_word = r_word;
        t1_r_second = r_second;  t1_r_was_delay = r_was_delay;  t1_r_abort = r_abort;
        t1_r_delay_cnt = r_delay_cnt;  t1_t3_last = t3_last;  t1_inta_lock = inta_lock;
    end
endtask

task bus_load_t1;
    begin
        t_cycle = t1_t_cycle;  ta_cycle = t1_ta_cycle;  latch = t1_latch;  status = t1_status;
        pl_status = t1_pl_status;  fetch_state = t1_fetch_state;  fetch_delay = t1_fetch_delay;
        bus_pending = t1_bus_pending;  final_transfer = t1_final_transfer;
        transfer_n = t1_transfer_n;  address_latch = t1_address_latch;  data_bus = t1_data_bus;
        discard = t1_discard;  pc = t1_pc;  rphase = t1_rphase;  r_type = t1_r_type;
        r_addr0 = t1_r_addr0;  r_addr1 = t1_r_addr1;  r_data = t1_r_data;  r_word = t1_r_word;
        r_second = t1_r_second;  r_was_delay = t1_r_was_delay;  r_abort = t1_r_abort;
        r_delay_cnt = t1_r_delay_cnt;  t3_last = t1_t3_last;  inta_lock = t1_inta_lock;
    end
endtask

task bus_save_wc;
    begin
        wc_t_cycle = t_cycle;  wc_ta_cycle = ta_cycle;  wc_latch = latch;  wc_status = status;
        wc_pl_status = pl_status;  wc_fetch_state = fetch_state;  wc_fetch_delay = fetch_delay;
        wc_bus_pending = bus_pending;  wc_final_transfer = final_transfer;
        wc_transfer_n = transfer_n;  wc_address_latch = address_latch;  wc_data_bus = data_bus;
        wc_discard = discard;  wc_pc = pc;  wc_rphase = rphase;  wc_r_type = r_type;
        wc_r_addr0 = r_addr0;  wc_r_addr1 = r_addr1;  wc_r_data = r_data;  wc_r_word = r_word;
        wc_r_second = r_second;  wc_r_was_delay = r_was_delay;  wc_r_abort = r_abort;
        wc_r_delay_cnt = r_delay_cnt;  wc_t3_last = t3_last;  wc_inta_lock = inta_lock;
    end
endtask

task bus_save_ep;
    begin
        ep_t_cycle = t_cycle;  ep_ta_cycle = ta_cycle;  ep_latch = latch;  ep_status = status;
        ep_pl_status = pl_status;  ep_fetch_state = fetch_state;  ep_fetch_delay = fetch_delay;
        ep_bus_pending = bus_pending;  ep_final_transfer = final_transfer;
        ep_transfer_n = transfer_n;  ep_address_latch = address_latch;  ep_data_bus = data_bus;
        ep_discard = discard;  ep_pc = pc;  ep_rphase = rphase;  ep_r_type = r_type;
        ep_r_addr0 = r_addr0;  ep_r_addr1 = r_addr1;  ep_r_data = r_data;  ep_r_word = r_word;
        ep_r_second = r_second;  ep_r_was_delay = r_was_delay;  ep_r_abort = r_abort;
        ep_r_delay_cnt = r_delay_cnt;  ep_t3_last = t3_last;  ep_inta_lock = inta_lock;
    end
endtask

task bus_save_vn;
    begin
        vn_t_cycle = t_cycle;  vn_ta_cycle = ta_cycle;  vn_latch = latch;  vn_status = status;
        vn_pl_status = pl_status;  vn_fetch_state = fetch_state;  vn_fetch_delay = fetch_delay;
        vn_bus_pending = bus_pending;  vn_final_transfer = final_transfer;
        vn_transfer_n = transfer_n;  vn_address_latch = address_latch;  vn_data_bus = data_bus;
        vn_discard = discard;  vn_pc = pc;  vn_rphase = rphase;  vn_r_type = r_type;
        vn_r_addr0 = r_addr0;  vn_r_addr1 = r_addr1;  vn_r_data = r_data;  vn_r_word = r_word;
        vn_r_second = r_second;  vn_r_was_delay = r_was_delay;  vn_r_abort = r_abort;
        vn_r_delay_cnt = r_delay_cnt;  vn_t3_last = t3_last;  vn_inta_lock = inta_lock;
    end
endtask

task bus_save_vt;
    begin
        vt_t_cycle = t_cycle;  vt_ta_cycle = ta_cycle;  vt_latch = latch;  vt_status = status;
        vt_pl_status = pl_status;  vt_fetch_state = fetch_state;  vt_fetch_delay = fetch_delay;
        vt_bus_pending = bus_pending;  vt_final_transfer = final_transfer;
        vt_transfer_n = transfer_n;  vt_address_latch = address_latch;  vt_data_bus = data_bus;
        vt_discard = discard;  vt_pc = pc;  vt_rphase = rphase;  vt_r_type = r_type;
        vt_r_addr0 = r_addr0;  vt_r_addr1 = r_addr1;  vt_r_data = r_data;  vt_r_word = r_word;
        vt_r_second = r_second;  vt_r_was_delay = r_was_delay;  vt_r_abort = r_abort;
        vt_r_delay_cnt = r_delay_cnt;  vt_t3_last = t3_last;  vt_inta_lock = inta_lock;
    end
endtask

task bus_save_vc;
    begin
        vc_t_cycle = t_cycle;  vc_ta_cycle = ta_cycle;  vc_latch = latch;  vc_status = status;
        vc_pl_status = pl_status;  vc_fetch_state = fetch_state;  vc_fetch_delay = fetch_delay;
        vc_bus_pending = bus_pending;  vc_final_transfer = final_transfer;
        vc_transfer_n = transfer_n;  vc_address_latch = address_latch;  vc_data_bus = data_bus;
        vc_discard = discard;  vc_pc = pc;  vc_rphase = rphase;  vc_r_type = r_type;
        vc_r_addr0 = r_addr0;  vc_r_addr1 = r_addr1;  vc_r_data = r_data;  vc_r_word = r_word;
        vc_r_second = r_second;  vc_r_was_delay = r_was_delay;  vc_r_abort = r_abort;
        vc_r_delay_cnt = r_delay_cnt;  vc_t3_last = t3_last;  vc_inta_lock = inta_lock;
    end
endtask

task bus_save_hn;
    begin
        hn_t_cycle = t_cycle;  hn_ta_cycle = ta_cycle;  hn_latch = latch;  hn_status = status;
        hn_pl_status = pl_status;  hn_fetch_state = fetch_state;  hn_fetch_delay = fetch_delay;
        hn_bus_pending = bus_pending;  hn_final_transfer = final_transfer;
        hn_transfer_n = transfer_n;  hn_address_latch = address_latch;  hn_data_bus = data_bus;
        hn_discard = discard;  hn_pc = pc;  hn_rphase = rphase;  hn_r_type = r_type;
        hn_r_addr0 = r_addr0;  hn_r_addr1 = r_addr1;  hn_r_data = r_data;  hn_r_word = r_word;
        hn_r_second = r_second;  hn_r_was_delay = r_was_delay;  hn_r_abort = r_abort;
        hn_r_delay_cnt = r_delay_cnt;  hn_t3_last = t3_last;  hn_inta_lock = inta_lock;
    end
endtask

task bus_save_ht;
    begin
        ht_t_cycle = t_cycle;  ht_ta_cycle = ta_cycle;  ht_latch = latch;  ht_status = status;
        ht_pl_status = pl_status;  ht_fetch_state = fetch_state;  ht_fetch_delay = fetch_delay;
        ht_bus_pending = bus_pending;  ht_final_transfer = final_transfer;
        ht_transfer_n = transfer_n;  ht_address_latch = address_latch;  ht_data_bus = data_bus;
        ht_discard = discard;  ht_pc = pc;  ht_rphase = rphase;  ht_r_type = r_type;
        ht_r_addr0 = r_addr0;  ht_r_addr1 = r_addr1;  ht_r_data = r_data;  ht_r_word = r_word;
        ht_r_second = r_second;  ht_r_was_delay = r_was_delay;  ht_r_abort = r_abort;
        ht_r_delay_cnt = r_delay_cnt;  ht_t3_last = t3_last;  ht_inta_lock = inta_lock;
    end
endtask

task bus_save_hc;
    begin
        hc_t_cycle = t_cycle;  hc_ta_cycle = ta_cycle;  hc_latch = latch;  hc_status = status;
        hc_pl_status = pl_status;  hc_fetch_state = fetch_state;  hc_fetch_delay = fetch_delay;
        hc_bus_pending = bus_pending;  hc_final_transfer = final_transfer;
        hc_transfer_n = transfer_n;  hc_address_latch = address_latch;  hc_data_bus = data_bus;
        hc_discard = discard;  hc_pc = pc;  hc_rphase = rphase;  hc_r_type = r_type;
        hc_r_addr0 = r_addr0;  hc_r_addr1 = r_addr1;  hc_r_data = r_data;  hc_r_word = r_word;
        hc_r_second = r_second;  hc_r_was_delay = r_was_delay;  hc_r_abort = r_abort;
        hc_r_delay_cnt = r_delay_cnt;  hc_t3_last = t3_last;  hc_inta_lock = inta_lock;
    end
endtask

task bus_load_fn;
    begin
        t_cycle = fn_t_cycle;  ta_cycle = fn_ta_cycle;  latch = fn_latch;  status = fn_status;
        pl_status = fn_pl_status;  fetch_state = fn_fetch_state;  fetch_delay = fn_fetch_delay;
        bus_pending = fn_bus_pending;  final_transfer = fn_final_transfer;
        transfer_n = fn_transfer_n;  address_latch = fn_address_latch;  data_bus = fn_data_bus;
        discard = fn_discard;  pc = fn_pc;  rphase = fn_rphase;  r_type = fn_r_type;
        r_addr0 = fn_r_addr0;  r_addr1 = fn_r_addr1;  r_data = fn_r_data;  r_word = fn_r_word;
        r_second = fn_r_second;  r_was_delay = fn_r_was_delay;  r_abort = fn_r_abort;
        r_delay_cnt = fn_r_delay_cnt;  t3_last = fn_t3_last;  inta_lock = fn_inta_lock;
    end
endtask

task bus_load_ft;
    begin
        t_cycle = ft_t_cycle;  ta_cycle = ft_ta_cycle;  latch = ft_latch;  status = ft_status;
        pl_status = ft_pl_status;  fetch_state = ft_fetch_state;  fetch_delay = ft_fetch_delay;
        bus_pending = ft_bus_pending;  final_transfer = ft_final_transfer;
        transfer_n = ft_transfer_n;  address_latch = ft_address_latch;  data_bus = ft_data_bus;
        discard = ft_discard;  pc = ft_pc;  rphase = ft_rphase;  r_type = ft_r_type;
        r_addr0 = ft_r_addr0;  r_addr1 = ft_r_addr1;  r_data = ft_r_data;  r_word = ft_r_word;
        r_second = ft_r_second;  r_was_delay = ft_r_was_delay;  r_abort = ft_r_abort;
        r_delay_cnt = ft_r_delay_cnt;  t3_last = ft_t3_last;  inta_lock = ft_inta_lock;
    end
endtask

task bus_load_fc;
    begin
        t_cycle = fc_t_cycle;  ta_cycle = fc_ta_cycle;  latch = fc_latch;  status = fc_status;
        pl_status = fc_pl_status;  fetch_state = fc_fetch_state;  fetch_delay = fc_fetch_delay;
        bus_pending = fc_bus_pending;  final_transfer = fc_final_transfer;
        transfer_n = fc_transfer_n;  address_latch = fc_address_latch;  data_bus = fc_data_bus;
        discard = fc_discard;  pc = fc_pc;  rphase = fc_rphase;  r_type = fc_r_type;
        r_addr0 = fc_r_addr0;  r_addr1 = fc_r_addr1;  r_data = fc_r_data;  r_word = fc_r_word;
        r_second = fc_r_second;  r_was_delay = fc_r_was_delay;  r_abort = fc_r_abort;
        r_delay_cnt = fc_r_delay_cnt;  t3_last = fc_t3_last;  inta_lock = fc_inta_lock;
    end
endtask

task bus_load_gn;
    begin
        t_cycle = gn_t_cycle;  ta_cycle = gn_ta_cycle;  latch = gn_latch;  status = gn_status;
        pl_status = gn_pl_status;  fetch_state = gn_fetch_state;  fetch_delay = gn_fetch_delay;
        bus_pending = gn_bus_pending;  final_transfer = gn_final_transfer;
        transfer_n = gn_transfer_n;  address_latch = gn_address_latch;  data_bus = gn_data_bus;
        discard = gn_discard;  pc = gn_pc;  rphase = gn_rphase;  r_type = gn_r_type;
        r_addr0 = gn_r_addr0;  r_addr1 = gn_r_addr1;  r_data = gn_r_data;  r_word = gn_r_word;
        r_second = gn_r_second;  r_was_delay = gn_r_was_delay;  r_abort = gn_r_abort;
        r_delay_cnt = gn_r_delay_cnt;  t3_last = gn_t3_last;  inta_lock = gn_inta_lock;
    end
endtask

task bus_load_gt;
    begin
        t_cycle = gt_t_cycle;  ta_cycle = gt_ta_cycle;  latch = gt_latch;  status = gt_status;
        pl_status = gt_pl_status;  fetch_state = gt_fetch_state;  fetch_delay = gt_fetch_delay;
        bus_pending = gt_bus_pending;  final_transfer = gt_final_transfer;
        transfer_n = gt_transfer_n;  address_latch = gt_address_latch;  data_bus = gt_data_bus;
        discard = gt_discard;  pc = gt_pc;  rphase = gt_rphase;  r_type = gt_r_type;
        r_addr0 = gt_r_addr0;  r_addr1 = gt_r_addr1;  r_data = gt_r_data;  r_word = gt_r_word;
        r_second = gt_r_second;  r_was_delay = gt_r_was_delay;  r_abort = gt_r_abort;
        r_delay_cnt = gt_r_delay_cnt;  t3_last = gt_t3_last;  inta_lock = gt_inta_lock;
    end
endtask

task bus_load_gc;
    begin
        t_cycle = gc_t_cycle;  ta_cycle = gc_ta_cycle;  latch = gc_latch;  status = gc_status;
        pl_status = gc_pl_status;  fetch_state = gc_fetch_state;  fetch_delay = gc_fetch_delay;
        bus_pending = gc_bus_pending;  final_transfer = gc_final_transfer;
        transfer_n = gc_transfer_n;  address_latch = gc_address_latch;  data_bus = gc_data_bus;
        discard = gc_discard;  pc = gc_pc;  rphase = gc_rphase;  r_type = gc_r_type;
        r_addr0 = gc_r_addr0;  r_addr1 = gc_r_addr1;  r_data = gc_r_data;  r_word = gc_r_word;
        r_second = gc_r_second;  r_was_delay = gc_r_was_delay;  r_abort = gc_r_abort;
        r_delay_cnt = gc_r_delay_cnt;  t3_last = gc_t3_last;  inta_lock = gc_inta_lock;
    end
endtask

task bus_cp_fn_sv;
    begin
        fn_t_cycle = sv_t_cycle;  fn_ta_cycle = sv_ta_cycle;  fn_latch = sv_latch;
        fn_status = sv_status;  fn_pl_status = sv_pl_status;  fn_fetch_state = sv_fetch_state;
        fn_fetch_delay = sv_fetch_delay;  fn_bus_pending = sv_bus_pending;
        fn_final_transfer = sv_final_transfer;  fn_transfer_n = sv_transfer_n;
        fn_address_latch = sv_address_latch;  fn_data_bus = sv_data_bus;  fn_discard = sv_discard;
        fn_pc = sv_pc;  fn_rphase = sv_rphase;  fn_r_type = sv_r_type;  fn_r_addr0 = sv_r_addr0;
        fn_r_addr1 = sv_r_addr1;  fn_r_data = sv_r_data;  fn_r_word = sv_r_word;
        fn_r_second = sv_r_second;  fn_r_was_delay = sv_r_was_delay;  fn_r_abort = sv_r_abort;
        fn_r_delay_cnt = sv_r_delay_cnt;  fn_t3_last = sv_t3_last;  fn_inta_lock = sv_inta_lock;
    end
endtask

task bus_cp_fn_ep;
    begin
        fn_t_cycle = ep_t_cycle;  fn_ta_cycle = ep_ta_cycle;  fn_latch = ep_latch;
        fn_status = ep_status;  fn_pl_status = ep_pl_status;  fn_fetch_state = ep_fetch_state;
        fn_fetch_delay = ep_fetch_delay;  fn_bus_pending = ep_bus_pending;
        fn_final_transfer = ep_final_transfer;  fn_transfer_n = ep_transfer_n;
        fn_address_latch = ep_address_latch;  fn_data_bus = ep_data_bus;  fn_discard = ep_discard;
        fn_pc = ep_pc;  fn_rphase = ep_rphase;  fn_r_type = ep_r_type;  fn_r_addr0 = ep_r_addr0;
        fn_r_addr1 = ep_r_addr1;  fn_r_data = ep_r_data;  fn_r_word = ep_r_word;
        fn_r_second = ep_r_second;  fn_r_was_delay = ep_r_was_delay;  fn_r_abort = ep_r_abort;
        fn_r_delay_cnt = ep_r_delay_cnt;  fn_t3_last = ep_t3_last;  fn_inta_lock = ep_inta_lock;
    end
endtask

task bus_cp_ft_ep;
    begin
        ft_t_cycle = ep_t_cycle;  ft_ta_cycle = ep_ta_cycle;  ft_latch = ep_latch;
        ft_status = ep_status;  ft_pl_status = ep_pl_status;  ft_fetch_state = ep_fetch_state;
        ft_fetch_delay = ep_fetch_delay;  ft_bus_pending = ep_bus_pending;
        ft_final_transfer = ep_final_transfer;  ft_transfer_n = ep_transfer_n;
        ft_address_latch = ep_address_latch;  ft_data_bus = ep_data_bus;  ft_discard = ep_discard;
        ft_pc = ep_pc;  ft_rphase = ep_rphase;  ft_r_type = ep_r_type;  ft_r_addr0 = ep_r_addr0;
        ft_r_addr1 = ep_r_addr1;  ft_r_data = ep_r_data;  ft_r_word = ep_r_word;
        ft_r_second = ep_r_second;  ft_r_was_delay = ep_r_was_delay;  ft_r_abort = ep_r_abort;
        ft_r_delay_cnt = ep_r_delay_cnt;  ft_t3_last = ep_t3_last;  ft_inta_lock = ep_inta_lock;
    end
endtask

task bus_cp_fc_ep;
    begin
        fc_t_cycle = ep_t_cycle;  fc_ta_cycle = ep_ta_cycle;  fc_latch = ep_latch;
        fc_status = ep_status;  fc_pl_status = ep_pl_status;  fc_fetch_state = ep_fetch_state;
        fc_fetch_delay = ep_fetch_delay;  fc_bus_pending = ep_bus_pending;
        fc_final_transfer = ep_final_transfer;  fc_transfer_n = ep_transfer_n;
        fc_address_latch = ep_address_latch;  fc_data_bus = ep_data_bus;  fc_discard = ep_discard;
        fc_pc = ep_pc;  fc_rphase = ep_rphase;  fc_r_type = ep_r_type;  fc_r_addr0 = ep_r_addr0;
        fc_r_addr1 = ep_r_addr1;  fc_r_data = ep_r_data;  fc_r_word = ep_r_word;
        fc_r_second = ep_r_second;  fc_r_was_delay = ep_r_was_delay;  fc_r_abort = ep_r_abort;
        fc_r_delay_cnt = ep_r_delay_cnt;  fc_t3_last = ep_t3_last;  fc_inta_lock = ep_inta_lock;
    end
endtask

task bus_cp_gn_ep;
    begin
        gn_t_cycle = ep_t_cycle;  gn_ta_cycle = ep_ta_cycle;  gn_latch = ep_latch;
        gn_status = ep_status;  gn_pl_status = ep_pl_status;  gn_fetch_state = ep_fetch_state;
        gn_fetch_delay = ep_fetch_delay;  gn_bus_pending = ep_bus_pending;
        gn_final_transfer = ep_final_transfer;  gn_transfer_n = ep_transfer_n;
        gn_address_latch = ep_address_latch;  gn_data_bus = ep_data_bus;  gn_discard = ep_discard;
        gn_pc = ep_pc;  gn_rphase = ep_rphase;  gn_r_type = ep_r_type;  gn_r_addr0 = ep_r_addr0;
        gn_r_addr1 = ep_r_addr1;  gn_r_data = ep_r_data;  gn_r_word = ep_r_word;
        gn_r_second = ep_r_second;  gn_r_was_delay = ep_r_was_delay;  gn_r_abort = ep_r_abort;
        gn_r_delay_cnt = ep_r_delay_cnt;  gn_t3_last = ep_t3_last;  gn_inta_lock = ep_inta_lock;
    end
endtask

task bus_cp_gt_ep;
    begin
        gt_t_cycle = ep_t_cycle;  gt_ta_cycle = ep_ta_cycle;  gt_latch = ep_latch;
        gt_status = ep_status;  gt_pl_status = ep_pl_status;  gt_fetch_state = ep_fetch_state;
        gt_fetch_delay = ep_fetch_delay;  gt_bus_pending = ep_bus_pending;
        gt_final_transfer = ep_final_transfer;  gt_transfer_n = ep_transfer_n;
        gt_address_latch = ep_address_latch;  gt_data_bus = ep_data_bus;  gt_discard = ep_discard;
        gt_pc = ep_pc;  gt_rphase = ep_rphase;  gt_r_type = ep_r_type;  gt_r_addr0 = ep_r_addr0;
        gt_r_addr1 = ep_r_addr1;  gt_r_data = ep_r_data;  gt_r_word = ep_r_word;
        gt_r_second = ep_r_second;  gt_r_was_delay = ep_r_was_delay;  gt_r_abort = ep_r_abort;
        gt_r_delay_cnt = ep_r_delay_cnt;  gt_t3_last = ep_t3_last;  gt_inta_lock = ep_inta_lock;
    end
endtask

task bus_cp_gc_ep;
    begin
        gc_t_cycle = ep_t_cycle;  gc_ta_cycle = ep_ta_cycle;  gc_latch = ep_latch;
        gc_status = ep_status;  gc_pl_status = ep_pl_status;  gc_fetch_state = ep_fetch_state;
        gc_fetch_delay = ep_fetch_delay;  gc_bus_pending = ep_bus_pending;
        gc_final_transfer = ep_final_transfer;  gc_transfer_n = ep_transfer_n;
        gc_address_latch = ep_address_latch;  gc_data_bus = ep_data_bus;  gc_discard = ep_discard;
        gc_pc = ep_pc;  gc_rphase = ep_rphase;  gc_r_type = ep_r_type;  gc_r_addr0 = ep_r_addr0;
        gc_r_addr1 = ep_r_addr1;  gc_r_data = ep_r_data;  gc_r_word = ep_r_word;
        gc_r_second = ep_r_second;  gc_r_was_delay = ep_r_was_delay;  gc_r_abort = ep_r_abort;
        gc_r_delay_cnt = ep_r_delay_cnt;  gc_t3_last = ep_t3_last;  gc_inta_lock = ep_inta_lock;
    end
endtask

task bus_cp_ft_sv;
    begin
        ft_t_cycle = sv_t_cycle;  ft_ta_cycle = sv_ta_cycle;  ft_latch = sv_latch;
        ft_status = sv_status;  ft_pl_status = sv_pl_status;  ft_fetch_state = sv_fetch_state;
        ft_fetch_delay = sv_fetch_delay;  ft_bus_pending = sv_bus_pending;
        ft_final_transfer = sv_final_transfer;  ft_transfer_n = sv_transfer_n;
        ft_address_latch = sv_address_latch;  ft_data_bus = sv_data_bus;  ft_discard = sv_discard;
        ft_pc = sv_pc;  ft_rphase = sv_rphase;  ft_r_type = sv_r_type;  ft_r_addr0 = sv_r_addr0;
        ft_r_addr1 = sv_r_addr1;  ft_r_data = sv_r_data;  ft_r_word = sv_r_word;
        ft_r_second = sv_r_second;  ft_r_was_delay = sv_r_was_delay;  ft_r_abort = sv_r_abort;
        ft_r_delay_cnt = sv_r_delay_cnt;  ft_t3_last = sv_t3_last;  ft_inta_lock = sv_inta_lock;
    end
endtask

task bus_cp_fc_sv;
    begin
        fc_t_cycle = sv_t_cycle;  fc_ta_cycle = sv_ta_cycle;  fc_latch = sv_latch;
        fc_status = sv_status;  fc_pl_status = sv_pl_status;  fc_fetch_state = sv_fetch_state;
        fc_fetch_delay = sv_fetch_delay;  fc_bus_pending = sv_bus_pending;
        fc_final_transfer = sv_final_transfer;  fc_transfer_n = sv_transfer_n;
        fc_address_latch = sv_address_latch;  fc_data_bus = sv_data_bus;  fc_discard = sv_discard;
        fc_pc = sv_pc;  fc_rphase = sv_rphase;  fc_r_type = sv_r_type;  fc_r_addr0 = sv_r_addr0;
        fc_r_addr1 = sv_r_addr1;  fc_r_data = sv_r_data;  fc_r_word = sv_r_word;
        fc_r_second = sv_r_second;  fc_r_was_delay = sv_r_was_delay;  fc_r_abort = sv_r_abort;
        fc_r_delay_cnt = sv_r_delay_cnt;  fc_t3_last = sv_t3_last;  fc_inta_lock = sv_inta_lock;
    end
endtask

task bus_cp_gn_sv;
    begin
        gn_t_cycle = sv_t_cycle;  gn_ta_cycle = sv_ta_cycle;  gn_latch = sv_latch;
        gn_status = sv_status;  gn_pl_status = sv_pl_status;  gn_fetch_state = sv_fetch_state;
        gn_fetch_delay = sv_fetch_delay;  gn_bus_pending = sv_bus_pending;
        gn_final_transfer = sv_final_transfer;  gn_transfer_n = sv_transfer_n;
        gn_address_latch = sv_address_latch;  gn_data_bus = sv_data_bus;  gn_discard = sv_discard;
        gn_pc = sv_pc;  gn_rphase = sv_rphase;  gn_r_type = sv_r_type;  gn_r_addr0 = sv_r_addr0;
        gn_r_addr1 = sv_r_addr1;  gn_r_data = sv_r_data;  gn_r_word = sv_r_word;
        gn_r_second = sv_r_second;  gn_r_was_delay = sv_r_was_delay;  gn_r_abort = sv_r_abort;
        gn_r_delay_cnt = sv_r_delay_cnt;  gn_t3_last = sv_t3_last;  gn_inta_lock = sv_inta_lock;
    end
endtask

task bus_cp_gt_sv;
    begin
        gt_t_cycle = sv_t_cycle;  gt_ta_cycle = sv_ta_cycle;  gt_latch = sv_latch;
        gt_status = sv_status;  gt_pl_status = sv_pl_status;  gt_fetch_state = sv_fetch_state;
        gt_fetch_delay = sv_fetch_delay;  gt_bus_pending = sv_bus_pending;
        gt_final_transfer = sv_final_transfer;  gt_transfer_n = sv_transfer_n;
        gt_address_latch = sv_address_latch;  gt_data_bus = sv_data_bus;  gt_discard = sv_discard;
        gt_pc = sv_pc;  gt_rphase = sv_rphase;  gt_r_type = sv_r_type;  gt_r_addr0 = sv_r_addr0;
        gt_r_addr1 = sv_r_addr1;  gt_r_data = sv_r_data;  gt_r_word = sv_r_word;
        gt_r_second = sv_r_second;  gt_r_was_delay = sv_r_was_delay;  gt_r_abort = sv_r_abort;
        gt_r_delay_cnt = sv_r_delay_cnt;  gt_t3_last = sv_t3_last;  gt_inta_lock = sv_inta_lock;
    end
endtask

task bus_cp_gc_sv;
    begin
        gc_t_cycle = sv_t_cycle;  gc_ta_cycle = sv_ta_cycle;  gc_latch = sv_latch;
        gc_status = sv_status;  gc_pl_status = sv_pl_status;  gc_fetch_state = sv_fetch_state;
        gc_fetch_delay = sv_fetch_delay;  gc_bus_pending = sv_bus_pending;
        gc_final_transfer = sv_final_transfer;  gc_transfer_n = sv_transfer_n;
        gc_address_latch = sv_address_latch;  gc_data_bus = sv_data_bus;  gc_discard = sv_discard;
        gc_pc = sv_pc;  gc_rphase = sv_rphase;  gc_r_type = sv_r_type;  gc_r_addr0 = sv_r_addr0;
        gc_r_addr1 = sv_r_addr1;  gc_r_data = sv_r_data;  gc_r_word = sv_r_word;
        gc_r_second = sv_r_second;  gc_r_was_delay = sv_r_was_delay;  gc_r_abort = sv_r_abort;
        gc_r_delay_cnt = sv_r_delay_cnt;  gc_t3_last = sv_t3_last;  gc_inta_lock = sv_inta_lock;
    end
endtask

task bus_cp_fn_wc;
    begin
        fn_t_cycle = wc_t_cycle;  fn_ta_cycle = wc_ta_cycle;  fn_latch = wc_latch;
        fn_status = wc_status;  fn_pl_status = wc_pl_status;  fn_fetch_state = wc_fetch_state;
        fn_fetch_delay = wc_fetch_delay;  fn_bus_pending = wc_bus_pending;
        fn_final_transfer = wc_final_transfer;  fn_transfer_n = wc_transfer_n;
        fn_address_latch = wc_address_latch;  fn_data_bus = wc_data_bus;  fn_discard = wc_discard;
        fn_pc = wc_pc;  fn_rphase = wc_rphase;  fn_r_type = wc_r_type;  fn_r_addr0 = wc_r_addr0;
        fn_r_addr1 = wc_r_addr1;  fn_r_data = wc_r_data;  fn_r_word = wc_r_word;
        fn_r_second = wc_r_second;  fn_r_was_delay = wc_r_was_delay;  fn_r_abort = wc_r_abort;
        fn_r_delay_cnt = wc_r_delay_cnt;  fn_t3_last = wc_t3_last;  fn_inta_lock = wc_inta_lock;
    end
endtask

task bus_cp_ft_wc;
    begin
        ft_t_cycle = wc_t_cycle;  ft_ta_cycle = wc_ta_cycle;  ft_latch = wc_latch;
        ft_status = wc_status;  ft_pl_status = wc_pl_status;  ft_fetch_state = wc_fetch_state;
        ft_fetch_delay = wc_fetch_delay;  ft_bus_pending = wc_bus_pending;
        ft_final_transfer = wc_final_transfer;  ft_transfer_n = wc_transfer_n;
        ft_address_latch = wc_address_latch;  ft_data_bus = wc_data_bus;  ft_discard = wc_discard;
        ft_pc = wc_pc;  ft_rphase = wc_rphase;  ft_r_type = wc_r_type;  ft_r_addr0 = wc_r_addr0;
        ft_r_addr1 = wc_r_addr1;  ft_r_data = wc_r_data;  ft_r_word = wc_r_word;
        ft_r_second = wc_r_second;  ft_r_was_delay = wc_r_was_delay;  ft_r_abort = wc_r_abort;
        ft_r_delay_cnt = wc_r_delay_cnt;  ft_t3_last = wc_t3_last;  ft_inta_lock = wc_inta_lock;
    end
endtask

task bus_cp_fc_wc;
    begin
        fc_t_cycle = wc_t_cycle;  fc_ta_cycle = wc_ta_cycle;  fc_latch = wc_latch;
        fc_status = wc_status;  fc_pl_status = wc_pl_status;  fc_fetch_state = wc_fetch_state;
        fc_fetch_delay = wc_fetch_delay;  fc_bus_pending = wc_bus_pending;
        fc_final_transfer = wc_final_transfer;  fc_transfer_n = wc_transfer_n;
        fc_address_latch = wc_address_latch;  fc_data_bus = wc_data_bus;  fc_discard = wc_discard;
        fc_pc = wc_pc;  fc_rphase = wc_rphase;  fc_r_type = wc_r_type;  fc_r_addr0 = wc_r_addr0;
        fc_r_addr1 = wc_r_addr1;  fc_r_data = wc_r_data;  fc_r_word = wc_r_word;
        fc_r_second = wc_r_second;  fc_r_was_delay = wc_r_was_delay;  fc_r_abort = wc_r_abort;
        fc_r_delay_cnt = wc_r_delay_cnt;  fc_t3_last = wc_t3_last;  fc_inta_lock = wc_inta_lock;
    end
endtask

task bus_cp_gn_wc;
    begin
        gn_t_cycle = wc_t_cycle;  gn_ta_cycle = wc_ta_cycle;  gn_latch = wc_latch;
        gn_status = wc_status;  gn_pl_status = wc_pl_status;  gn_fetch_state = wc_fetch_state;
        gn_fetch_delay = wc_fetch_delay;  gn_bus_pending = wc_bus_pending;
        gn_final_transfer = wc_final_transfer;  gn_transfer_n = wc_transfer_n;
        gn_address_latch = wc_address_latch;  gn_data_bus = wc_data_bus;  gn_discard = wc_discard;
        gn_pc = wc_pc;  gn_rphase = wc_rphase;  gn_r_type = wc_r_type;  gn_r_addr0 = wc_r_addr0;
        gn_r_addr1 = wc_r_addr1;  gn_r_data = wc_r_data;  gn_r_word = wc_r_word;
        gn_r_second = wc_r_second;  gn_r_was_delay = wc_r_was_delay;  gn_r_abort = wc_r_abort;
        gn_r_delay_cnt = wc_r_delay_cnt;  gn_t3_last = wc_t3_last;  gn_inta_lock = wc_inta_lock;
    end
endtask

task bus_cp_gt_wc;
    begin
        gt_t_cycle = wc_t_cycle;  gt_ta_cycle = wc_ta_cycle;  gt_latch = wc_latch;
        gt_status = wc_status;  gt_pl_status = wc_pl_status;  gt_fetch_state = wc_fetch_state;
        gt_fetch_delay = wc_fetch_delay;  gt_bus_pending = wc_bus_pending;
        gt_final_transfer = wc_final_transfer;  gt_transfer_n = wc_transfer_n;
        gt_address_latch = wc_address_latch;  gt_data_bus = wc_data_bus;  gt_discard = wc_discard;
        gt_pc = wc_pc;  gt_rphase = wc_rphase;  gt_r_type = wc_r_type;  gt_r_addr0 = wc_r_addr0;
        gt_r_addr1 = wc_r_addr1;  gt_r_data = wc_r_data;  gt_r_word = wc_r_word;
        gt_r_second = wc_r_second;  gt_r_was_delay = wc_r_was_delay;  gt_r_abort = wc_r_abort;
        gt_r_delay_cnt = wc_r_delay_cnt;  gt_t3_last = wc_t3_last;  gt_inta_lock = wc_inta_lock;
    end
endtask

task bus_cp_gc_wc;
    begin
        gc_t_cycle = wc_t_cycle;  gc_ta_cycle = wc_ta_cycle;  gc_latch = wc_latch;
        gc_status = wc_status;  gc_pl_status = wc_pl_status;  gc_fetch_state = wc_fetch_state;
        gc_fetch_delay = wc_fetch_delay;  gc_bus_pending = wc_bus_pending;
        gc_final_transfer = wc_final_transfer;  gc_transfer_n = wc_transfer_n;
        gc_address_latch = wc_address_latch;  gc_data_bus = wc_data_bus;  gc_discard = wc_discard;
        gc_pc = wc_pc;  gc_rphase = wc_rphase;  gc_r_type = wc_r_type;  gc_r_addr0 = wc_r_addr0;
        gc_r_addr1 = wc_r_addr1;  gc_r_data = wc_r_data;  gc_r_word = wc_r_word;
        gc_r_second = wc_r_second;  gc_r_was_delay = wc_r_was_delay;  gc_r_abort = wc_r_abort;
        gc_r_delay_cnt = wc_r_delay_cnt;  gc_t3_last = wc_t3_last;  gc_inta_lock = wc_inta_lock;
    end
endtask

task bus_cp_fn_vn;
    begin
        fn_t_cycle = vn_t_cycle;  fn_ta_cycle = vn_ta_cycle;  fn_latch = vn_latch;
        fn_status = vn_status;  fn_pl_status = vn_pl_status;  fn_fetch_state = vn_fetch_state;
        fn_fetch_delay = vn_fetch_delay;  fn_bus_pending = vn_bus_pending;
        fn_final_transfer = vn_final_transfer;  fn_transfer_n = vn_transfer_n;
        fn_address_latch = vn_address_latch;  fn_data_bus = vn_data_bus;  fn_discard = vn_discard;
        fn_pc = vn_pc;  fn_rphase = vn_rphase;  fn_r_type = vn_r_type;  fn_r_addr0 = vn_r_addr0;
        fn_r_addr1 = vn_r_addr1;  fn_r_data = vn_r_data;  fn_r_word = vn_r_word;
        fn_r_second = vn_r_second;  fn_r_was_delay = vn_r_was_delay;  fn_r_abort = vn_r_abort;
        fn_r_delay_cnt = vn_r_delay_cnt;  fn_t3_last = vn_t3_last;  fn_inta_lock = vn_inta_lock;
    end
endtask

task bus_cp_ft_vt;
    begin
        ft_t_cycle = vt_t_cycle;  ft_ta_cycle = vt_ta_cycle;  ft_latch = vt_latch;
        ft_status = vt_status;  ft_pl_status = vt_pl_status;  ft_fetch_state = vt_fetch_state;
        ft_fetch_delay = vt_fetch_delay;  ft_bus_pending = vt_bus_pending;
        ft_final_transfer = vt_final_transfer;  ft_transfer_n = vt_transfer_n;
        ft_address_latch = vt_address_latch;  ft_data_bus = vt_data_bus;  ft_discard = vt_discard;
        ft_pc = vt_pc;  ft_rphase = vt_rphase;  ft_r_type = vt_r_type;  ft_r_addr0 = vt_r_addr0;
        ft_r_addr1 = vt_r_addr1;  ft_r_data = vt_r_data;  ft_r_word = vt_r_word;
        ft_r_second = vt_r_second;  ft_r_was_delay = vt_r_was_delay;  ft_r_abort = vt_r_abort;
        ft_r_delay_cnt = vt_r_delay_cnt;  ft_t3_last = vt_t3_last;  ft_inta_lock = vt_inta_lock;
    end
endtask

task bus_cp_fc_vc;
    begin
        fc_t_cycle = vc_t_cycle;  fc_ta_cycle = vc_ta_cycle;  fc_latch = vc_latch;
        fc_status = vc_status;  fc_pl_status = vc_pl_status;  fc_fetch_state = vc_fetch_state;
        fc_fetch_delay = vc_fetch_delay;  fc_bus_pending = vc_bus_pending;
        fc_final_transfer = vc_final_transfer;  fc_transfer_n = vc_transfer_n;
        fc_address_latch = vc_address_latch;  fc_data_bus = vc_data_bus;  fc_discard = vc_discard;
        fc_pc = vc_pc;  fc_rphase = vc_rphase;  fc_r_type = vc_r_type;  fc_r_addr0 = vc_r_addr0;
        fc_r_addr1 = vc_r_addr1;  fc_r_data = vc_r_data;  fc_r_word = vc_r_word;
        fc_r_second = vc_r_second;  fc_r_was_delay = vc_r_was_delay;  fc_r_abort = vc_r_abort;
        fc_r_delay_cnt = vc_r_delay_cnt;  fc_t3_last = vc_t3_last;  fc_inta_lock = vc_inta_lock;
    end
endtask

task bus_cp_gn_hn;
    begin
        gn_t_cycle = hn_t_cycle;  gn_ta_cycle = hn_ta_cycle;  gn_latch = hn_latch;
        gn_status = hn_status;  gn_pl_status = hn_pl_status;  gn_fetch_state = hn_fetch_state;
        gn_fetch_delay = hn_fetch_delay;  gn_bus_pending = hn_bus_pending;
        gn_final_transfer = hn_final_transfer;  gn_transfer_n = hn_transfer_n;
        gn_address_latch = hn_address_latch;  gn_data_bus = hn_data_bus;  gn_discard = hn_discard;
        gn_pc = hn_pc;  gn_rphase = hn_rphase;  gn_r_type = hn_r_type;  gn_r_addr0 = hn_r_addr0;
        gn_r_addr1 = hn_r_addr1;  gn_r_data = hn_r_data;  gn_r_word = hn_r_word;
        gn_r_second = hn_r_second;  gn_r_was_delay = hn_r_was_delay;  gn_r_abort = hn_r_abort;
        gn_r_delay_cnt = hn_r_delay_cnt;  gn_t3_last = hn_t3_last;  gn_inta_lock = hn_inta_lock;
    end
endtask

task bus_cp_gt_ht;
    begin
        gt_t_cycle = ht_t_cycle;  gt_ta_cycle = ht_ta_cycle;  gt_latch = ht_latch;
        gt_status = ht_status;  gt_pl_status = ht_pl_status;  gt_fetch_state = ht_fetch_state;
        gt_fetch_delay = ht_fetch_delay;  gt_bus_pending = ht_bus_pending;
        gt_final_transfer = ht_final_transfer;  gt_transfer_n = ht_transfer_n;
        gt_address_latch = ht_address_latch;  gt_data_bus = ht_data_bus;  gt_discard = ht_discard;
        gt_pc = ht_pc;  gt_rphase = ht_rphase;  gt_r_type = ht_r_type;  gt_r_addr0 = ht_r_addr0;
        gt_r_addr1 = ht_r_addr1;  gt_r_data = ht_r_data;  gt_r_word = ht_r_word;
        gt_r_second = ht_r_second;  gt_r_was_delay = ht_r_was_delay;  gt_r_abort = ht_r_abort;
        gt_r_delay_cnt = ht_r_delay_cnt;  gt_t3_last = ht_t3_last;  gt_inta_lock = ht_inta_lock;
    end
endtask

task bus_cp_gc_hc;
    begin
        gc_t_cycle = hc_t_cycle;  gc_ta_cycle = hc_ta_cycle;  gc_latch = hc_latch;
        gc_status = hc_status;  gc_pl_status = hc_pl_status;  gc_fetch_state = hc_fetch_state;
        gc_fetch_delay = hc_fetch_delay;  gc_bus_pending = hc_bus_pending;
        gc_final_transfer = hc_final_transfer;  gc_transfer_n = hc_transfer_n;
        gc_address_latch = hc_address_latch;  gc_data_bus = hc_data_bus;  gc_discard = hc_discard;
        gc_pc = hc_pc;  gc_rphase = hc_rphase;  gc_r_type = hc_r_type;  gc_r_addr0 = hc_r_addr0;
        gc_r_addr1 = hc_r_addr1;  gc_r_data = hc_r_data;  gc_r_word = hc_r_word;
        gc_r_second = hc_r_second;  gc_r_was_delay = hc_r_was_delay;  gc_r_abort = hc_r_abort;
        gc_r_delay_cnt = hc_r_delay_cnt;  gc_t3_last = hc_t3_last;  gc_inta_lock = hc_inta_lock;
    end
endtask

// the live events, from the state in the registers. Whether the EU reads
// the queue (and whether a request is held) is known late in the clock, so the
// results are worked out for each case (the sets below) and those late
// decisions select at the end (main block): queue reads none (n), without
// (t) or with (c) CANCEL_DELAY, request not held (v) or held (h)
task bus_live6;
    begin
        bus_save_t0;                            // the state before the events
        ev_hold = 1'b0;  bus_rest;  bus_save_vn;
        ev_hold = 1'b1;  bus_load_t0;  bus_rest;  bus_save_hn;
        bus_load_t0;
        if (fetch_state != FS_DELAYED) fetch_on_queue_read;
        bus_save_t1;
        ev_hold = 1'b0;  bus_rest;  bus_save_vt;
        ev_hold = 1'b1;  bus_load_t1;  bus_rest;  bus_save_ht;
        bus_load_t0;
        if (fetch_state == FS_DELAYED) fetch_delay = 2'd0;
        else fetch_on_queue_read;
        bus_save_t1;
        ev_hold = 1'b1;  bus_rest;  bus_save_hc;
        ev_hold = 1'b0;  bus_load_t1;  bus_rest;  bus_save_vc;
    end
endtask


// the bus state: the candidate ksel chooses
task bus_view;
    begin
        t_cycle = v_t_cycle;  ta_cycle = v_ta_cycle;  latch = v_latch;  status = v_status;
        pl_status = v_pl_status;  fetch_state = v_fetch_state;  fetch_delay = v_fetch_delay;
        bus_pending = v_bus_pending;  final_transfer = v_final_transfer;
        transfer_n = v_transfer_n;  address_latch = v_address_latch;  data_bus = v_data_bus;
        discard = v_discard;  pc = v_pc;  rphase = v_rphase;  r_type = v_r_type;
        r_addr0 = v_r_addr0;  r_addr1 = v_r_addr1;  r_data = v_r_data;  r_word = v_r_word;
        r_second = v_r_second;  r_was_delay = v_r_was_delay;  r_abort = v_r_abort;
        r_delay_cnt = v_r_delay_cnt;  t3_last = v_t3_last;
        inta_lock = v_inta_lock;
    end
endtask

// the same for the copy the step works from
task bus_bd_view;
    begin
        t_cycle = bv_t_cycle;  ta_cycle = bv_ta_cycle;  latch = bv_latch;  status = bv_status;
        pl_status = bv_pl_status;  fetch_state = bv_fetch_state;  fetch_delay = bv_fetch_delay;
        bus_pending = bv_bus_pending;  final_transfer = bv_final_transfer;
        transfer_n = bv_transfer_n;  address_latch = bv_address_latch;  data_bus = bv_data_bus;
        discard = bv_discard;  pc = bv_pc;  rphase = bv_rphase;  r_type = bv_r_type;
        r_addr0 = bv_r_addr0;  r_addr1 = bv_r_addr1;  r_data = bv_r_data;  r_word = bv_r_word;
        r_second = bv_r_second;  r_was_delay = bv_r_was_delay;  r_abort = bv_r_abort;
        r_delay_cnt = bv_r_delay_cnt;  
        t3_last = bv_t3_last;  inta_lock = bv_inta_lock;
    end
endtask

// the late selection among the six final candidates
task bus_select;
    input take, hit3, hold;
    begin
        if (!take) begin
            if (hold) bus_load_gn; else bus_load_fn;
        end else if (!hit3) begin
            if (hold) bus_load_gt; else bus_load_ft;
        end else begin
            if (hold) bus_load_gc; else bus_load_fc;
        end
    end
endtask

task ev_from_lv;
    begin
        ev_take = f_take; ev_hit3 = f_hit3; ev_flush = lv_flush; ev_ip = lv_ip; ev_susp = lv_susp;
        ev_req = lv_req; ev_hold = f_hold; ev_rword = lv_rword; ev_rtype = lv_rtype;
        ev_rdata = lv_rdata; ev_raddr0 = lv_raddr0; ev_raddr1 = lv_raddr1;
        ev_pre = lv_pre; ev_plen = lv_plen; ev_pip = lv_pip;
    end
endtask

task ev_from_p1;
    begin
        ev_take = p1_take; ev_hit3 = p1_hit3; ev_flush = p1_flush; ev_ip = p1_ip; ev_susp = p1_susp;
        ev_req = p1_req; ev_hold = p1_hold; ev_rword = p1_rword; ev_rtype = p1_rtype;
        ev_rdata = p1_rdata; ev_raddr0 = p1_raddr0; ev_raddr1 = p1_raddr1;
        ev_pre = p1_pre; ev_plen = p1_plen; ev_pip = p1_pip;
    end
endtask

task ev_from_pw;
    begin
        ev_take = pw_take; ev_hit3 = pw_hit3; ev_flush = pw_flush; ev_ip = pw_ip; ev_susp = pw_susp;
        ev_req = pw_req; ev_hold = pw_hold; ev_rword = pw_rword; ev_rtype = pw_rtype;
        ev_rdata = pw_rdata; ev_raddr0 = pw_raddr0; ev_raddr1 = pw_raddr1;
        ev_pre = pw_pre; ev_plen = pw_plen; ev_pip = pw_pip;
    end
endtask

task ev_from_p2;
    begin
        ev_take = p2_take; ev_hit3 = p2_hit3; ev_flush = p2_flush; ev_ip = p2_ip; ev_susp = p2_susp;
        ev_req = p2_req; ev_hold = p2_hold; ev_rword = p2_rword; ev_rtype = p2_rtype;
        ev_rdata = p2_rdata; ev_raddr0 = p2_raddr0; ev_raddr1 = p2_raddr1;
        ev_pre = p2_pre; ev_plen = p2_plen; ev_pip = p2_pip;
    end
endtask

// ------------------------------------------------------------------ main

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
        sp_dispatch = 12'd1;  sp_read = 12'd1;  sp_done = 12'd1;  cz = 1'b1;
        sr_armed = 1'b0;  sr_n = 12'd0;  sr_base = 2'b00;  sr_two = 1'b0;
        rphase = RP_IDLE;  r_type = ST_PASV;  r_addr0 = 20'h0;  r_addr1 = 20'h0;
        r_data = 16'h0;  r_word = 1'b0;  r_second = 1'b0;
        r_was_delay = 1'b0;  r_abort = 1'b0;  r_delay_cnt = 2'd0;
        return_data = 16'h0;  done = 1'b0;  cb = 1'b0;
        eu_req_d1 = 1'b0;  strobe_d1 = 1'b0;
        pfq_top_d1 = 8'h0;  pfq_empty_d1 = 1'b1;  pfq_addr_d1 = 16'h0;
        biu_intr = 1'b0;
        inta_lock = 1'b0;  t3_last = 1'b1;  nmi_d1 = 1'b0;  nmi_d2 = 1'b0;  nmi_caught = 1'b0;
        win1 = 1'b0;  win2 = 1'b0;  pend = 1'b0;
        db_cap = 1'b0;  rph_w = 1'b0;  rdy_cap = 1'b0;  wf_pend = 1'b0;
        // the bus state's candidates and the step's copy
        kn_t_cycle <= t_cycle;  kn_ta_cycle <= ta_cycle;  kn_latch <= latch;  kn_status <= status;
        kn_pl_status <= pl_status;  kn_fetch_state <= fetch_state;  kn_fetch_delay <= fetch_delay;
        kn_bus_pending <= bus_pending;  kn_final_transfer <= final_transfer;
        kn_transfer_n <= transfer_n;  kn_address_latch <= address_latch;  kn_data_bus <= data_bus;
        kn_discard <= discard;  kn_pc <= pc;  kn_rphase <= rphase;  kn_r_type <= r_type;
        kn_r_addr0 <= r_addr0;  kn_r_addr1 <= r_addr1;  kn_r_data <= r_data;  kn_r_word <= r_word;
        kn_r_second <= r_second;  kn_r_was_delay <= r_was_delay;  kn_r_abort <= r_abort;
        kn_r_delay_cnt <= r_delay_cnt;  
        kn_t3_last <= t3_last;  kn_inta_lock <= inta_lock;
        bdkn_t_cycle = t_cycle;  bdkn_ta_cycle = ta_cycle;  bdkn_latch = latch;
        bdkn_status = status;  bdkn_pl_status = pl_status;  bdkn_fetch_state = fetch_state;
        bdkn_fetch_delay = fetch_delay;  bdkn_bus_pending = bus_pending;
        bdkn_final_transfer = final_transfer;  bdkn_transfer_n = transfer_n;
        bdkn_address_latch = address_latch;  bdkn_data_bus = data_bus;  bdkn_discard = discard;
        bdkn_pc = pc;  bdkn_rphase = rphase;  bdkn_r_type = r_type;  bdkn_r_addr0 = r_addr0;
        bdkn_r_addr1 = r_addr1;  bdkn_r_data = r_data;  bdkn_r_word = r_word;
        bdkn_r_second = r_second;  bdkn_r_was_delay = r_was_delay;  bdkn_r_abort = r_abort;
        bdkn_r_delay_cnt = r_delay_cnt;  
        bdkn_t3_last = t3_last;  bdkn_inta_lock = inta_lock;
        kt_t_cycle <= t_cycle;  kt_ta_cycle <= ta_cycle;  kt_latch <= latch;  kt_status <= status;
        kt_pl_status <= pl_status;  kt_fetch_state <= fetch_state;  kt_fetch_delay <= fetch_delay;
        kt_bus_pending <= bus_pending;  kt_final_transfer <= final_transfer;
        kt_transfer_n <= transfer_n;  kt_address_latch <= address_latch;  kt_data_bus <= data_bus;
        kt_discard <= discard;  kt_pc <= pc;  kt_rphase <= rphase;  kt_r_type <= r_type;
        kt_r_addr0 <= r_addr0;  kt_r_addr1 <= r_addr1;  kt_r_data <= r_data;  kt_r_word <= r_word;
        kt_r_second <= r_second;  kt_r_was_delay <= r_was_delay;  kt_r_abort <= r_abort;
        kt_r_delay_cnt <= r_delay_cnt;  
        kt_t3_last <= t3_last;  kt_inta_lock <= inta_lock;
        bdkt_t_cycle = t_cycle;  bdkt_ta_cycle = ta_cycle;  bdkt_latch = latch;
        bdkt_status = status;  bdkt_pl_status = pl_status;  bdkt_fetch_state = fetch_state;
        bdkt_fetch_delay = fetch_delay;  bdkt_bus_pending = bus_pending;
        bdkt_final_transfer = final_transfer;  bdkt_transfer_n = transfer_n;
        bdkt_address_latch = address_latch;  bdkt_data_bus = data_bus;  bdkt_discard = discard;
        bdkt_pc = pc;  bdkt_rphase = rphase;  bdkt_r_type = r_type;  bdkt_r_addr0 = r_addr0;
        bdkt_r_addr1 = r_addr1;  bdkt_r_data = r_data;  bdkt_r_word = r_word;
        bdkt_r_second = r_second;  bdkt_r_was_delay = r_was_delay;  bdkt_r_abort = r_abort;
        bdkt_r_delay_cnt = r_delay_cnt;  
        bdkt_t3_last = t3_last;  bdkt_inta_lock = inta_lock;
        kc_t_cycle <= t_cycle;  kc_ta_cycle <= ta_cycle;  kc_latch <= latch;  kc_status <= status;
        kc_pl_status <= pl_status;  kc_fetch_state <= fetch_state;  kc_fetch_delay <= fetch_delay;
        kc_bus_pending <= bus_pending;  kc_final_transfer <= final_transfer;
        kc_transfer_n <= transfer_n;  kc_address_latch <= address_latch;  kc_data_bus <= data_bus;
        kc_discard <= discard;  kc_pc <= pc;  kc_rphase <= rphase;  kc_r_type <= r_type;
        kc_r_addr0 <= r_addr0;  kc_r_addr1 <= r_addr1;  kc_r_data <= r_data;  kc_r_word <= r_word;
        kc_r_second <= r_second;  kc_r_was_delay <= r_was_delay;  kc_r_abort <= r_abort;
        kc_r_delay_cnt <= r_delay_cnt;  
        kc_t3_last <= t3_last;  kc_inta_lock <= inta_lock;
        bdkc_t_cycle = t_cycle;  bdkc_ta_cycle = ta_cycle;  bdkc_latch = latch;
        bdkc_status = status;  bdkc_pl_status = pl_status;  bdkc_fetch_state = fetch_state;
        bdkc_fetch_delay = fetch_delay;  bdkc_bus_pending = bus_pending;
        bdkc_final_transfer = final_transfer;  bdkc_transfer_n = transfer_n;
        bdkc_address_latch = address_latch;  bdkc_data_bus = data_bus;  bdkc_discard = discard;
        bdkc_pc = pc;  bdkc_rphase = rphase;  bdkc_r_type = r_type;  bdkc_r_addr0 = r_addr0;
        bdkc_r_addr1 = r_addr1;  bdkc_r_data = r_data;  bdkc_r_word = r_word;
        bdkc_r_second = r_second;  bdkc_r_was_delay = r_was_delay;  bdkc_r_abort = r_abort;
        bdkc_r_delay_cnt = r_delay_cnt;  
        bdkc_t3_last = t3_last;  bdkc_inta_lock = inta_lock;
        ln_t_cycle <= t_cycle;  ln_ta_cycle <= ta_cycle;  ln_latch <= latch;  ln_status <= status;
        ln_pl_status <= pl_status;  ln_fetch_state <= fetch_state;  ln_fetch_delay <= fetch_delay;
        ln_bus_pending <= bus_pending;  ln_final_transfer <= final_transfer;
        ln_transfer_n <= transfer_n;  ln_address_latch <= address_latch;  ln_data_bus <= data_bus;
        ln_discard <= discard;  ln_pc <= pc;  ln_rphase <= rphase;  ln_r_type <= r_type;
        ln_r_addr0 <= r_addr0;  ln_r_addr1 <= r_addr1;  ln_r_data <= r_data;  ln_r_word <= r_word;
        ln_r_second <= r_second;  ln_r_was_delay <= r_was_delay;  ln_r_abort <= r_abort;
        ln_r_delay_cnt <= r_delay_cnt;  
        ln_t3_last <= t3_last;  ln_inta_lock <= inta_lock;
        bdln_t_cycle = t_cycle;  bdln_ta_cycle = ta_cycle;  bdln_latch = latch;
        bdln_status = status;  bdln_pl_status = pl_status;  bdln_fetch_state = fetch_state;
        bdln_fetch_delay = fetch_delay;  bdln_bus_pending = bus_pending;
        bdln_final_transfer = final_transfer;  bdln_transfer_n = transfer_n;
        bdln_address_latch = address_latch;  bdln_data_bus = data_bus;  bdln_discard = discard;
        bdln_pc = pc;  bdln_rphase = rphase;  bdln_r_type = r_type;  bdln_r_addr0 = r_addr0;
        bdln_r_addr1 = r_addr1;  bdln_r_data = r_data;  bdln_r_word = r_word;
        bdln_r_second = r_second;  bdln_r_was_delay = r_was_delay;  bdln_r_abort = r_abort;
        bdln_r_delay_cnt = r_delay_cnt;  
        bdln_t3_last = t3_last;  bdln_inta_lock = inta_lock;
        lt_t_cycle <= t_cycle;  lt_ta_cycle <= ta_cycle;  lt_latch <= latch;  lt_status <= status;
        lt_pl_status <= pl_status;  lt_fetch_state <= fetch_state;  lt_fetch_delay <= fetch_delay;
        lt_bus_pending <= bus_pending;  lt_final_transfer <= final_transfer;
        lt_transfer_n <= transfer_n;  lt_address_latch <= address_latch;  lt_data_bus <= data_bus;
        lt_discard <= discard;  lt_pc <= pc;  lt_rphase <= rphase;  lt_r_type <= r_type;
        lt_r_addr0 <= r_addr0;  lt_r_addr1 <= r_addr1;  lt_r_data <= r_data;  lt_r_word <= r_word;
        lt_r_second <= r_second;  lt_r_was_delay <= r_was_delay;  lt_r_abort <= r_abort;
        lt_r_delay_cnt <= r_delay_cnt;  
        lt_t3_last <= t3_last;  lt_inta_lock <= inta_lock;
        bdlt_t_cycle = t_cycle;  bdlt_ta_cycle = ta_cycle;  bdlt_latch = latch;
        bdlt_status = status;  bdlt_pl_status = pl_status;  bdlt_fetch_state = fetch_state;
        bdlt_fetch_delay = fetch_delay;  bdlt_bus_pending = bus_pending;
        bdlt_final_transfer = final_transfer;  bdlt_transfer_n = transfer_n;
        bdlt_address_latch = address_latch;  bdlt_data_bus = data_bus;  bdlt_discard = discard;
        bdlt_pc = pc;  bdlt_rphase = rphase;  bdlt_r_type = r_type;  bdlt_r_addr0 = r_addr0;
        bdlt_r_addr1 = r_addr1;  bdlt_r_data = r_data;  bdlt_r_word = r_word;
        bdlt_r_second = r_second;  bdlt_r_was_delay = r_was_delay;  bdlt_r_abort = r_abort;
        bdlt_r_delay_cnt = r_delay_cnt;  
        bdlt_t3_last = t3_last;  bdlt_inta_lock = inta_lock;
        lc_t_cycle <= t_cycle;  lc_ta_cycle <= ta_cycle;  lc_latch <= latch;  lc_status <= status;
        lc_pl_status <= pl_status;  lc_fetch_state <= fetch_state;  lc_fetch_delay <= fetch_delay;
        lc_bus_pending <= bus_pending;  lc_final_transfer <= final_transfer;
        lc_transfer_n <= transfer_n;  lc_address_latch <= address_latch;  lc_data_bus <= data_bus;
        lc_discard <= discard;  lc_pc <= pc;  lc_rphase <= rphase;  lc_r_type <= r_type;
        lc_r_addr0 <= r_addr0;  lc_r_addr1 <= r_addr1;  lc_r_data <= r_data;  lc_r_word <= r_word;
        lc_r_second <= r_second;  lc_r_was_delay <= r_was_delay;  lc_r_abort <= r_abort;
        lc_r_delay_cnt <= r_delay_cnt;  
        lc_t3_last <= t3_last;  lc_inta_lock <= inta_lock;
        bdlc_t_cycle = t_cycle;  bdlc_ta_cycle = ta_cycle;  bdlc_latch = latch;
        bdlc_status = status;  bdlc_pl_status = pl_status;  bdlc_fetch_state = fetch_state;
        bdlc_fetch_delay = fetch_delay;  bdlc_bus_pending = bus_pending;
        bdlc_final_transfer = final_transfer;  bdlc_transfer_n = transfer_n;
        bdlc_address_latch = address_latch;  bdlc_data_bus = data_bus;  bdlc_discard = discard;
        bdlc_pc = pc;  bdlc_rphase = rphase;  bdlc_r_type = r_type;  bdlc_r_addr0 = r_addr0;
        bdlc_r_addr1 = r_addr1;  bdlc_r_data = r_data;  bdlc_r_word = r_word;
        bdlc_r_second = r_second;  bdlc_r_was_delay = r_was_delay;  bdlc_r_abort = r_abort;
        bdlc_r_delay_cnt = r_delay_cnt;  
        bdlc_t3_last = t3_last;  bdlc_inta_lock = inta_lock;
        ksel <= 3'd0;  bd_ksel = 3'd0;
        p1_take = 1'b0; p1_flush = 1'b0; p1_susp = 1'b0; p1_req = 1'b0; p1_pre = 1'b0;
        p2_take = 1'b0; p2_flush = 1'b0; p2_susp = 1'b0; p2_req = 1'b0; p2_pre = 1'b0;
    end else begin
        bus_view;                               // the bus state
        done = 1'b0;
        sdn_rst = 1'b0;
        sdn_pre = since_done;
        s0_d = since_dispatch;  s0_r = since_read;  s0_n = since_done;
        p0_d = sp_dispatch;     p0_r = sp_read;     p0_n = sp_done;
        lv_flush = 1'b0;  lv_ip = EU_REGISTER_R3;  lv_susp = 1'b0;
        lv_req = 1'b0;  lv_rword = 1'b0;  lv_rtype = ST_PASV;  lv_rdata = EU_BIU_DATAOUT;
        lv_raddr0 = 20'h0;  lv_raddr1 = 20'h0;
        lv_pre = 1'b0;  lv_plen = tb_queue_len;  lv_pip = tb_ip;

        // ================= the 8088 clock edge
        // NMI: a rising edge is caught until the EU takes it
        if (nmi_d1 && !nmi_d2) nmi_caught = 1'b1;
        else if (BIU_NMI_DEBOUNCE) nmi_caught = 1'b0;
        nmi_d2 = nmi_d1;
        nmi_d1 = NMI;

        if (step) begin
            biu_intr = INTR;                    // sampled at the CLK edge
            cb_s     = cb_pred;                 // (before the push changes qlen)

            // do_cycle, fast side: a code fetch's T4 pushes its byte
            if (st_push) q_push(data_bus);

            // queue status: what the EU did in the cycle that just ended
            qs_out   = queue_op;
            qs_byte  = queue_byte;
            queue_op = QO_IDLE;

            cz = counter == 13'd0 || counter_cycles && counter == 13'd1;
            if (counter_cycles && counter != 13'd0) counter = counter - 13'd1;
            // (since_x != 0xFFF ? since_x + 1 : 0xFFF), kept ready in sp_x
            since_dispatch = sp_dispatch;
            since_read     = sp_read;
            since_done     = sp_done;
            sdn_pre        = sp_done;
            if (sp_dispatch != 12'hFFF) sp_dispatch = sp_dispatch + 12'd1;
            if (sp_read != 12'hFFF) sp_read = sp_read + 12'd1;
            if (sp_done != 12'hFFF) sp_done = sp_done + 12'd1;

            // request phases, fast side
            case (rphase)
                RP_WAIT:
                    if (st_t4 && (!r_write || r_word && !r_second)) begin
                        if (r_write) ;
                        else if (r_second && r_type == ST_INTA && INTA_VEC_LO)
                            return_data = {8'h00, st_db};   // the vector: 2nd INTA
                        else if (r_second) return_data[15:8] = st_db;
                        else return_data = {8'h00, st_db};
                        if (!(r_word && !r_second)) begin
                            done = 1'b1;
                            since_done = 12'd0;  sp_done = 12'd1;  sdn_rst = 1'b1;
                            if (end_after_done) begin end_after_done = 1'b0; end_armed = 1'b1; counter = {1'b0, end_ad_n}; cz = end_ad_n == 12'd0; end
                        end
                    end else if (st_t3last && r_write && (!r_word || r_second)) begin
                        done = 1'b1;
                        since_done = 12'd0;  sp_done = 12'd1;  sdn_rst = 1'b1;
                        if (end_after_done) begin end_after_done = 1'b0; end_armed = 1'b1; counter = {1'b0, end_ad_n}; cz = end_ad_n == 12'd0; end
                    end
                RP_SUSP:
                    if (!cb_s) done = 1'b1;
                default: ;
            endcase

            // a held request is released at the start of its cycle
            // (rel_due_f(rel_n, since_dispatch, since_read, since_done, ...)
            // with since_x = sp_x of the clock's start, since_done 0 when
            // RP_WAIT ended a transfer above)
            if (rphase == RP_HOLD && (rel_abs  ? p0_d >= rel_n :
                                      rel_done ? (sdn_rst ? rel_n == 12'd0 : p0_n >= rel_n) :
                                                 p0_r >= rel_n))
                rel_armed = 1'b0;

            cb = cb_s;
        end else begin
            cz = counter == 13'd0 || !counter_cycles && counter == 13'd1;
            if (!counter_cycles && counter != 13'd0) counter = counter - 13'd1;
        end

        // ================= EU events (they belong to the running cycle)

        // (the values of rel_n/sr_n before the register strobe, for the
        // flat compares below)
        c_rn  = rel_n;
        c_srn = sr_n;
        {c_rovf, c_rsum} = {1'b0, rel_n} + {1'b0, EU_BIU_DATAOUT[11:0]};
        c_rneg = 12'd0 - rel_n;

        // the compares of a cycle-mode end counter load (cz below)
        cz_gr = ge_s(s0_r, p0_r, EU_BIU_DATAOUT[11:0]);
        cz_gd = ge_s(s0_d, p0_d, EU_BIU_DATAOUT[11:0]);
        cz_sr = 1'b0;
        cz_sd = 1'b0;
        cz_o  = cz;

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
            cz = EU_BIU_DATAOUT[13] ?
                     (EU_BIU_DATAOUT[12] && EU_BIU_DATAOUT[14] ? EU_BIU_DATAOUT[11:0] == 12'd0 :
                      EU_BIU_DATAOUT[12]                      ? 1'b0 :
                      !EU_BIU_DATAOUT[14]                     ? cz_gr :
                                                                cz_gd) :
                     EU_BIU_DATAOUT[12:0] == 13'd0;
            // (for f_chain: cz is cz_gr or cz_gd here, else as worked out)
            cz_sr = EU_BIU_DATAOUT[13] && !EU_BIU_DATAOUT[12] && !EU_BIU_DATAOUT[14];
            cz_sd = EU_BIU_DATAOUT[13] && !EU_BIU_DATAOUT[12] &&  EU_BIU_DATAOUT[14];
            cz_o  = EU_BIU_DATAOUT[13] ? EU_BIU_DATAOUT[12] && EU_BIU_DATAOUT[14] && EU_BIU_DATAOUT[11:0] == 12'd0 :
                                         EU_BIU_DATAOUT[12:0] == 13'd0;
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

        // ---- the queue reads below, as flat logic (f_*, for the bus part and
        // the decisions below). EU_QREAD comes late in the clock, so they
        // are worked out for each of its values and it selects.
        // since_x >= sr_n / rel_n, for the register's value (0) and DATAOUT
        // (1) and, for rel_n, their sum (2)
        // (the value after a step's increment is sp_x: both compares, step
        // selects; since_done is 0 when RP_WAIT ended a transfer here)
        c_sge_d0 = ge_s(s0_d, p0_d, c_srn);  c_sge_d1 = ge_s(s0_d, p0_d, EU_BIU_DATAOUT[11:0]);
        c_sge_n0 = sdn_rst ? c_srn == 12'd0 : ge_s(s0_n, p0_n, c_srn);
        c_sge_n1 = sdn_rst ? EU_BIU_DATAOUT[11:0] == 12'd0 : ge_s(s0_n, p0_n, EU_BIU_DATAOUT[11:0]);
        c_sge_r0 = ge_s(s0_r, p0_r, c_srn);  c_sge_r1 = ge_s(s0_r, p0_r, EU_BIU_DATAOUT[11:0]);
        c_ge_d0 = ge_s(s0_d, p0_d, c_rn);  c_ge_d1 = ge_s(s0_d, p0_d, EU_BIU_DATAOUT[11:0]);
        c_ge_d2 = ge_sum(s0_d, p0_d, c_rn, EU_BIU_DATAOUT[11:0], c_rovf);
        c_ge_n0 = sdn_rst ? c_rn == 12'd0 : ge_s(s0_n, p0_n, c_rn);
        c_ge_n1 = sdn_rst ? EU_BIU_DATAOUT[11:0] == 12'd0 : ge_s(s0_n, p0_n, EU_BIU_DATAOUT[11:0]);
        c_ge_n2 = sdn_rst ? EU_BIU_DATAOUT[11:0] == c_rneg :       // (rel_n + D) mod 4096 == 0
                            ge_sum(s0_n, p0_n, c_rn, EU_BIU_DATAOUT[11:0], c_rovf);
        c_ge_r0 = ge_s(s0_r, p0_r, c_rn);  c_ge_r1 = ge_s(s0_r, p0_r, EU_BIU_DATAOUT[11:0]);
        c_ge_r2 = ge_sum(s0_r, p0_r, c_rn, EU_BIU_DATAOUT[11:0], c_rovf);
        if (eu_strobe == 2'b11 && eu_req_code[3:0] == 4'h7) begin   // sr_n = DATAOUT
            c_sge_d0 = c_sge_d1;  c_sge_n0 = c_sge_n1;  c_sge_r0 = c_sge_r1;
        end
        if (eu_strobe == 2'b11 && eu_req_code[3:0] == 4'h6) begin   // rel_n = DATAOUT
            c_ge_d0 = c_ge_d1;  c_ge_n0 = c_ge_n1;  c_ge_r0 = c_ge_r1;
        end
        if (eu_strobe == 2'b11 && eu_req_code[3:0] == 4'hE) begin   // rel_n += DATAOUT
            c_ge_d0 = c_ge_d2;  c_ge_n0 = c_ge_n2;  c_ge_r0 = c_ge_r2;
        end
        f_chain(2'b00);  fv_save(0);
        f_chain(2'b01);  fv_save(1);
        f_chain(2'b11);
        if (eu_qread == 2'b01) fv_load(1);
        else if (eu_qread != 2'b11) fv_load(0);

        // the EU's first use of the byte on top of its view is the read. An
        // opcode the BIU read already at the end of the last instruction
        // (preread) is not read again. (The read conditions are the f_*
        // decisions above, the same conditions as flat logic.)
        if (eu_qread == 2'b01) begin
            if (preread)
                preread = 1'b0;
            else if (f_tq01) begin              // ntaken == 0 && qlen != 0
                take_byte(QO_FIRST);
                end_armed = 1'b0;
            end
        end else if (f_tq11)                    // eu_qread == 11 && ntaken == 0 && qlen != 0
            take_byte(QO_SUBS);

        // queue strobes: MCL86 pops the byte on top of its view, with a QS
        // code saying what it was (01 opcode, 11 subsequent byte). A byte the
        // EU never looked at is read here.
        if (f_s) begin                          // eu_strobe == 01 && !strobe_d1
            if (f_ts)                           // ntaken == 0 && qlen != 0
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
        if (f_tr) begin                         // sr_armed && sr_due(sr_n) && ntaken != 3 && qlen != 0
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
        if (f_te) begin                         // end_armed && counter == 0 && ntaken != 3 && qlen != 0 && !preread
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
                    eu_ip = EU_REGISTER_R3;
                    queue_op = QO_FLUSH;    // QS byte: the last byte read stays
                    done = 1'b1;
                    lv_flush = 1'b1;
                end
                5'h1E: begin                        // SUSP
                    lv_susp = 1'b1;
                    // done at once unless a code fetch runs and is not in T4
                    if (!cb) done = 1'b1;
                end
                default: begin
                    lv_req    = 1'b1;
                    lv_raddr0 = {seg_val, 4'h0} + {4'h0, EU_REGISTER_R3};
                    lv_raddr1 = {seg_val, 4'h0} + {4'h0, EU_REGISTER_R3 + 16'd1};
                    case (eu_req_code)
                        5'h08: begin lv_rtype = ST_IOR;  lv_raddr0 = {4'h0, EU_REGISTER_R3}; end
                        5'h1A: begin lv_rtype = ST_IOR;  lv_rword = 1'b1; end
                        5'h0A: begin lv_rtype = ST_IOW;  lv_raddr0 = {4'h0, EU_REGISTER_R3}; end
                        5'h1C: begin lv_rtype = ST_IOW;  lv_rword = 1'b1; end
                        5'h0C: lv_rtype = ST_MEMR;
                        5'h10: begin lv_rtype = ST_MEMR; lv_rword = 1'b1; end
                        5'h11: begin lv_rtype = ST_MEMR; lv_rword = 1'b1;
                                     lv_raddr0 = {reg_ss, 4'h0} + {4'h0, EU_REGISTER_R3};
                                     lv_raddr1 = {reg_ss, 4'h0} + {4'h0, EU_REGISTER_R3 + 16'd1}; end
                        5'h12: begin lv_rtype = ST_MEMR; lv_rword = 1'b1;
                                     lv_raddr0 = {4'h0, EU_REGISTER_R3};
                                     lv_raddr1 = {4'h0, EU_REGISTER_R3 + 16'd1}; end
                        5'h0E: lv_rtype = ST_MEMW;
                        5'h13: begin lv_rtype = ST_MEMW; lv_rword = 1'b1; end
                        5'h14: begin lv_rtype = ST_MEMW; lv_rword = 1'b1;
                                     lv_raddr0 = {reg_ss, 4'h0} + {4'h0, EU_REGISTER_R3};
                                     lv_raddr1 = {reg_ss, 4'h0} + {4'h0, EU_REGISTER_R3 + 16'd1}; end
                        5'h16: begin lv_rtype = ST_INTA; lv_rword = 1'b1; end
                        default: lv_rtype = ST_PASV;   // HALT (0x18) and unknown: ignored
                    endcase
                    if (eu_req_code == 5'h1A || eu_req_code == 5'h1C) begin
                        lv_raddr0 = {4'h0, EU_REGISTER_R3};
                        lv_raddr1 = {4'h0, EU_REGISTER_R3 + 16'd1};
                    end
                    if (lv_rtype == ST_PASV)
                        done = 1'b1;
                    else if (f_hold)            // rel_armed && !rel_due(rel_n):
                        ;                           // the EU is early: held
                    else
                        rel_armed = 1'b0;
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
            cb = 1'b0;
            lv_pre = 1'b1;
        end

        // MCL86's one-clock queue view latency
        pfq_top_d1   = ntaken != 2'd0 ? taken0 : q0;
        pfq_empty_d1 = ntaken == 2'd0 && qlen == 3'd0;
        pfq_addr_d1  = eu_ip;

        // ================= the bus part
        // (all cases are worked out, the early conditions pick the six
        // candidates, the late decisions select one of them last)
        bus_save_sv;                            // the registers
        // two clocks after a step: the step (from the copy, three clocks) and
        // the events of the step's clock (p1) and of the clock after it (pw)
        bus_bd_view;
        ev_from_p1;
        bus_step;
        rph_w = 1'b0;
        bus_events;
        ev_from_pw;
        bus_events;
        if (db_cap) data_bus = p1_adin;         // the step's pins
        if (rdy_cap) t3_last = p1_ready;
        if (wf_pend && p1_ready && !rph_w) rphase = RP_IDLE;
        bus_save_wc;
        // a recorded clock (p2, pend) that made a request (or a preload,
        // test only): it alone; this clock's events are recorded in turn
        // (they make no request: a request is an edge of EU_BIU_COMMAND bit 9)
        bus_load_sv;
        ev_from_p2;
        bus_events;
        bus_save_ep;
        // any other clock: this clock's events (after a recorded clock that
        // made no request, its queue reads merge with this clock's: no event
        // comes between them, see bus_takes)
        bus_load_sv;
        ev_from_lv;
        bus_live6;
        // the candidates
        p2_rq = p2_flush || p2_susp || p2_req || p2_pre;
        if (step || win1) begin                 // the step's clock and the next: no change
            bus_cp_fn_sv;  bus_cp_ft_sv;  bus_cp_fc_sv;  bus_cp_gn_sv;  bus_cp_gt_sv;  bus_cp_gc_sv;
        end else if (win2) begin
            bus_cp_fn_wc;  bus_cp_ft_wc;  bus_cp_fc_wc;  bus_cp_gn_wc;  bus_cp_gt_wc;  bus_cp_gc_wc;
        end else if (pend && p2_rq) begin
            bus_cp_fn_ep;  bus_cp_ft_ep;  bus_cp_fc_ep;  bus_cp_gn_ep;  bus_cp_gt_ep;  bus_cp_gc_ep;
        end else begin
            bus_cp_fn_vn;  bus_cp_ft_vt;  bus_cp_fc_vc;  bus_cp_gn_hn;  bus_cp_gt_ht;  bus_cp_gc_hc;
        end
        rq2 = pend && !p2_rq;                   // p2's queue reads merge
        ksel_n = {f_take | rq2 & p2_take, f_hit3 | rq2 & p2_hit3, f_hold};
        bus_select(ksel_n[2], ksel_n[1], ksel_n[0]);

        // the events of the step's clock (p1), of the clock after it and of a
        // clock after a recorded request (p2) are applied later (recorded
        // after their use above)
        if (step) begin
            p1_take = f_take; p1_hit3 = f_hit3; p1_flush = lv_flush; p1_ip = lv_ip; p1_susp = lv_susp;
            p1_req = lv_req; p1_hold = f_hold; p1_rword = lv_rword; p1_rtype = lv_rtype;
            p1_rdata = lv_rdata; p1_raddr0 = lv_raddr0; p1_raddr1 = lv_raddr1;
            p1_pre = lv_pre; p1_plen = lv_plen; p1_pip = lv_pip;
            p1_adin = AD_IN; p1_ready = READY_IN;
        end
        if (win1) begin
            pw_take = f_take; pw_hit3 = f_hit3; pw_flush = lv_flush; pw_ip = lv_ip; pw_susp = lv_susp;
            pw_req = lv_req; pw_hold = f_hold; pw_rword = lv_rword; pw_rtype = lv_rtype;
            pw_rdata = lv_rdata; pw_raddr0 = lv_raddr0; pw_raddr1 = lv_raddr1;
            pw_pre = lv_pre; pw_plen = lv_plen; pw_pip = lv_pip;
        end
        pend = win2 || pend && p2_rq;
        if (pend) begin
            p2_take = f_take; p2_hit3 = f_hit3; p2_flush = lv_flush; p2_ip = lv_ip; p2_susp = lv_susp;
            p2_req = lv_req; p2_hold = f_hold; p2_rword = lv_rword; p2_rtype = lv_rtype;
            p2_rdata = lv_rdata; p2_raddr0 = lv_raddr0; p2_raddr1 = lv_raddr1;
            p2_pre = lv_pre; p2_plen = lv_plen; p2_pip = lv_pip;
        end

        // the copy for the next step
        if (!hold) begin
            bdkn_t_cycle = fn_t_cycle;  bdkn_ta_cycle = fn_ta_cycle;  bdkn_latch = fn_latch;
            bdkn_status = fn_status;  bdkn_pl_status = fn_pl_status;
            bdkn_fetch_state = fn_fetch_state;  bdkn_fetch_delay = fn_fetch_delay;
            bdkn_bus_pending = fn_bus_pending;  bdkn_final_transfer = fn_final_transfer;
            bdkn_transfer_n = fn_transfer_n;  bdkn_address_latch = fn_address_latch;
            bdkn_data_bus = fn_data_bus;  bdkn_discard = fn_discard;  bdkn_pc = fn_pc;
            bdkn_rphase = fn_rphase;  bdkn_r_type = fn_r_type;  bdkn_r_addr0 = fn_r_addr0;
            bdkn_r_addr1 = fn_r_addr1;  bdkn_r_data = fn_r_data;  bdkn_r_word = fn_r_word;
            bdkn_r_second = fn_r_second;  bdkn_r_was_delay = fn_r_was_delay;
            bdkn_r_abort = fn_r_abort;  bdkn_r_delay_cnt = fn_r_delay_cnt;
            bdkn_t3_last = fn_t3_last;
            bdkn_inta_lock = fn_inta_lock;
            bdkt_t_cycle = ft_t_cycle;  bdkt_ta_cycle = ft_ta_cycle;  bdkt_latch = ft_latch;
            bdkt_status = ft_status;  bdkt_pl_status = ft_pl_status;
            bdkt_fetch_state = ft_fetch_state;  bdkt_fetch_delay = ft_fetch_delay;
            bdkt_bus_pending = ft_bus_pending;  bdkt_final_transfer = ft_final_transfer;
            bdkt_transfer_n = ft_transfer_n;  bdkt_address_latch = ft_address_latch;
            bdkt_data_bus = ft_data_bus;  bdkt_discard = ft_discard;  bdkt_pc = ft_pc;
            bdkt_rphase = ft_rphase;  bdkt_r_type = ft_r_type;  bdkt_r_addr0 = ft_r_addr0;
            bdkt_r_addr1 = ft_r_addr1;  bdkt_r_data = ft_r_data;  bdkt_r_word = ft_r_word;
            bdkt_r_second = ft_r_second;  bdkt_r_was_delay = ft_r_was_delay;
            bdkt_r_abort = ft_r_abort;  bdkt_r_delay_cnt = ft_r_delay_cnt;
            bdkt_t3_last = ft_t3_last;
            bdkt_inta_lock = ft_inta_lock;
            bdkc_t_cycle = fc_t_cycle;  bdkc_ta_cycle = fc_ta_cycle;  bdkc_latch = fc_latch;
            bdkc_status = fc_status;  bdkc_pl_status = fc_pl_status;
            bdkc_fetch_state = fc_fetch_state;  bdkc_fetch_delay = fc_fetch_delay;
            bdkc_bus_pending = fc_bus_pending;  bdkc_final_transfer = fc_final_transfer;
            bdkc_transfer_n = fc_transfer_n;  bdkc_address_latch = fc_address_latch;
            bdkc_data_bus = fc_data_bus;  bdkc_discard = fc_discard;  bdkc_pc = fc_pc;
            bdkc_rphase = fc_rphase;  bdkc_r_type = fc_r_type;  bdkc_r_addr0 = fc_r_addr0;
            bdkc_r_addr1 = fc_r_addr1;  bdkc_r_data = fc_r_data;  bdkc_r_word = fc_r_word;
            bdkc_r_second = fc_r_second;  bdkc_r_was_delay = fc_r_was_delay;
            bdkc_r_abort = fc_r_abort;  bdkc_r_delay_cnt = fc_r_delay_cnt;
            bdkc_t3_last = fc_t3_last;
            bdkc_inta_lock = fc_inta_lock;
            bdln_t_cycle = gn_t_cycle;  bdln_ta_cycle = gn_ta_cycle;  bdln_latch = gn_latch;
            bdln_status = gn_status;  bdln_pl_status = gn_pl_status;
            bdln_fetch_state = gn_fetch_state;  bdln_fetch_delay = gn_fetch_delay;
            bdln_bus_pending = gn_bus_pending;  bdln_final_transfer = gn_final_transfer;
            bdln_transfer_n = gn_transfer_n;  bdln_address_latch = gn_address_latch;
            bdln_data_bus = gn_data_bus;  bdln_discard = gn_discard;  bdln_pc = gn_pc;
            bdln_rphase = gn_rphase;  bdln_r_type = gn_r_type;  bdln_r_addr0 = gn_r_addr0;
            bdln_r_addr1 = gn_r_addr1;  bdln_r_data = gn_r_data;  bdln_r_word = gn_r_word;
            bdln_r_second = gn_r_second;  bdln_r_was_delay = gn_r_was_delay;
            bdln_r_abort = gn_r_abort;  bdln_r_delay_cnt = gn_r_delay_cnt;
            bdln_t3_last = gn_t3_last;
            bdln_inta_lock = gn_inta_lock;
            bdlt_t_cycle = gt_t_cycle;  bdlt_ta_cycle = gt_ta_cycle;  bdlt_latch = gt_latch;
            bdlt_status = gt_status;  bdlt_pl_status = gt_pl_status;
            bdlt_fetch_state = gt_fetch_state;  bdlt_fetch_delay = gt_fetch_delay;
            bdlt_bus_pending = gt_bus_pending;  bdlt_final_transfer = gt_final_transfer;
            bdlt_transfer_n = gt_transfer_n;  bdlt_address_latch = gt_address_latch;
            bdlt_data_bus = gt_data_bus;  bdlt_discard = gt_discard;  bdlt_pc = gt_pc;
            bdlt_rphase = gt_rphase;  bdlt_r_type = gt_r_type;  bdlt_r_addr0 = gt_r_addr0;
            bdlt_r_addr1 = gt_r_addr1;  bdlt_r_data = gt_r_data;  bdlt_r_word = gt_r_word;
            bdlt_r_second = gt_r_second;  bdlt_r_was_delay = gt_r_was_delay;
            bdlt_r_abort = gt_r_abort;  bdlt_r_delay_cnt = gt_r_delay_cnt;
            bdlt_t3_last = gt_t3_last;
            bdlt_inta_lock = gt_inta_lock;
            bdlc_t_cycle = gc_t_cycle;  bdlc_ta_cycle = gc_ta_cycle;  bdlc_latch = gc_latch;
            bdlc_status = gc_status;  bdlc_pl_status = gc_pl_status;
            bdlc_fetch_state = gc_fetch_state;  bdlc_fetch_delay = gc_fetch_delay;
            bdlc_bus_pending = gc_bus_pending;  bdlc_final_transfer = gc_final_transfer;
            bdlc_transfer_n = gc_transfer_n;  bdlc_address_latch = gc_address_latch;
            bdlc_data_bus = gc_data_bus;  bdlc_discard = gc_discard;  bdlc_pc = gc_pc;
            bdlc_rphase = gc_rphase;  bdlc_r_type = gc_r_type;  bdlc_r_addr0 = gc_r_addr0;
            bdlc_r_addr1 = gc_r_addr1;  bdlc_r_data = gc_r_data;  bdlc_r_word = gc_r_word;
            bdlc_r_second = gc_r_second;  bdlc_r_was_delay = gc_r_was_delay;
            bdlc_r_abort = gc_r_abort;  bdlc_r_delay_cnt = gc_r_delay_cnt;
            bdlc_t3_last = gc_t3_last;
            bdlc_inta_lock = gc_inta_lock;
            bd_ksel = ksel_n;
            sn_qlen = qlen;  sn_cs = reg_cs;
            sn_since_dispatch = since_dispatch;  sn_since_read = since_read;
            sn_since_done = since_done;  sn_rel_n = rel_n;
            sn_rel_abs = rel_abs;  sn_rel_done = rel_done;
        end
        win2 = win1;
        win1 = step;
        // the candidates and the choice
        kn_t_cycle <= fn_t_cycle;  kn_ta_cycle <= fn_ta_cycle;  kn_latch <= fn_latch;
        kn_status <= fn_status;  kn_pl_status <= fn_pl_status;  kn_fetch_state <= fn_fetch_state;
        kn_fetch_delay <= fn_fetch_delay;  kn_bus_pending <= fn_bus_pending;
        kn_final_transfer <= fn_final_transfer;  kn_transfer_n <= fn_transfer_n;
        kn_address_latch <= fn_address_latch;  kn_data_bus <= fn_data_bus;
        kn_discard <= fn_discard;  kn_pc <= fn_pc;  kn_rphase <= fn_rphase;
        kn_r_type <= fn_r_type;  kn_r_addr0 <= fn_r_addr0;  kn_r_addr1 <= fn_r_addr1;
        kn_r_data <= fn_r_data;  kn_r_word <= fn_r_word;  kn_r_second <= fn_r_second;
        kn_r_was_delay <= fn_r_was_delay;  kn_r_abort <= fn_r_abort;
        kn_r_delay_cnt <= fn_r_delay_cnt;  
        kn_t3_last <= fn_t3_last;  kn_inta_lock <= fn_inta_lock;
        kt_t_cycle <= ft_t_cycle;  kt_ta_cycle <= ft_ta_cycle;  kt_latch <= ft_latch;
        kt_status <= ft_status;  kt_pl_status <= ft_pl_status;  kt_fetch_state <= ft_fetch_state;
        kt_fetch_delay <= ft_fetch_delay;  kt_bus_pending <= ft_bus_pending;
        kt_final_transfer <= ft_final_transfer;  kt_transfer_n <= ft_transfer_n;
        kt_address_latch <= ft_address_latch;  kt_data_bus <= ft_data_bus;
        kt_discard <= ft_discard;  kt_pc <= ft_pc;  kt_rphase <= ft_rphase;
        kt_r_type <= ft_r_type;  kt_r_addr0 <= ft_r_addr0;  kt_r_addr1 <= ft_r_addr1;
        kt_r_data <= ft_r_data;  kt_r_word <= ft_r_word;  kt_r_second <= ft_r_second;
        kt_r_was_delay <= ft_r_was_delay;  kt_r_abort <= ft_r_abort;
        kt_r_delay_cnt <= ft_r_delay_cnt;  
        kt_t3_last <= ft_t3_last;  kt_inta_lock <= ft_inta_lock;
        kc_t_cycle <= fc_t_cycle;  kc_ta_cycle <= fc_ta_cycle;  kc_latch <= fc_latch;
        kc_status <= fc_status;  kc_pl_status <= fc_pl_status;  kc_fetch_state <= fc_fetch_state;
        kc_fetch_delay <= fc_fetch_delay;  kc_bus_pending <= fc_bus_pending;
        kc_final_transfer <= fc_final_transfer;  kc_transfer_n <= fc_transfer_n;
        kc_address_latch <= fc_address_latch;  kc_data_bus <= fc_data_bus;
        kc_discard <= fc_discard;  kc_pc <= fc_pc;  kc_rphase <= fc_rphase;
        kc_r_type <= fc_r_type;  kc_r_addr0 <= fc_r_addr0;  kc_r_addr1 <= fc_r_addr1;
        kc_r_data <= fc_r_data;  kc_r_word <= fc_r_word;  kc_r_second <= fc_r_second;
        kc_r_was_delay <= fc_r_was_delay;  kc_r_abort <= fc_r_abort;
        kc_r_delay_cnt <= fc_r_delay_cnt;  
        kc_t3_last <= fc_t3_last;  kc_inta_lock <= fc_inta_lock;
        ln_t_cycle <= gn_t_cycle;  ln_ta_cycle <= gn_ta_cycle;  ln_latch <= gn_latch;
        ln_status <= gn_status;  ln_pl_status <= gn_pl_status;  ln_fetch_state <= gn_fetch_state;
        ln_fetch_delay <= gn_fetch_delay;  ln_bus_pending <= gn_bus_pending;
        ln_final_transfer <= gn_final_transfer;  ln_transfer_n <= gn_transfer_n;
        ln_address_latch <= gn_address_latch;  ln_data_bus <= gn_data_bus;
        ln_discard <= gn_discard;  ln_pc <= gn_pc;  ln_rphase <= gn_rphase;
        ln_r_type <= gn_r_type;  ln_r_addr0 <= gn_r_addr0;  ln_r_addr1 <= gn_r_addr1;
        ln_r_data <= gn_r_data;  ln_r_word <= gn_r_word;  ln_r_second <= gn_r_second;
        ln_r_was_delay <= gn_r_was_delay;  ln_r_abort <= gn_r_abort;
        ln_r_delay_cnt <= gn_r_delay_cnt;  
        ln_t3_last <= gn_t3_last;  ln_inta_lock <= gn_inta_lock;
        lt_t_cycle <= gt_t_cycle;  lt_ta_cycle <= gt_ta_cycle;  lt_latch <= gt_latch;
        lt_status <= gt_status;  lt_pl_status <= gt_pl_status;  lt_fetch_state <= gt_fetch_state;
        lt_fetch_delay <= gt_fetch_delay;  lt_bus_pending <= gt_bus_pending;
        lt_final_transfer <= gt_final_transfer;  lt_transfer_n <= gt_transfer_n;
        lt_address_latch <= gt_address_latch;  lt_data_bus <= gt_data_bus;
        lt_discard <= gt_discard;  lt_pc <= gt_pc;  lt_rphase <= gt_rphase;
        lt_r_type <= gt_r_type;  lt_r_addr0 <= gt_r_addr0;  lt_r_addr1 <= gt_r_addr1;
        lt_r_data <= gt_r_data;  lt_r_word <= gt_r_word;  lt_r_second <= gt_r_second;
        lt_r_was_delay <= gt_r_was_delay;  lt_r_abort <= gt_r_abort;
        lt_r_delay_cnt <= gt_r_delay_cnt;  
        lt_t3_last <= gt_t3_last;  lt_inta_lock <= gt_inta_lock;
        lc_t_cycle <= gc_t_cycle;  lc_ta_cycle <= gc_ta_cycle;  lc_latch <= gc_latch;
        lc_status <= gc_status;  lc_pl_status <= gc_pl_status;  lc_fetch_state <= gc_fetch_state;
        lc_fetch_delay <= gc_fetch_delay;  lc_bus_pending <= gc_bus_pending;
        lc_final_transfer <= gc_final_transfer;  lc_transfer_n <= gc_transfer_n;
        lc_address_latch <= gc_address_latch;  lc_data_bus <= gc_data_bus;
        lc_discard <= gc_discard;  lc_pc <= gc_pc;  lc_rphase <= gc_rphase;
        lc_r_type <= gc_r_type;  lc_r_addr0 <= gc_r_addr0;  lc_r_addr1 <= gc_r_addr1;
        lc_r_data <= gc_r_data;  lc_r_word <= gc_r_word;  lc_r_second <= gc_r_second;
        lc_r_was_delay <= gc_r_was_delay;  lc_r_abort <= gc_r_abort;
        lc_r_delay_cnt <= gc_r_delay_cnt;  
        lc_t3_last <= gc_t3_last;  lc_inta_lock <= gc_inta_lock;
        ksel <= ksel_n;
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
    o_pfq_top_d1 <= pfq_top_d1;
    o_pfq_empty_d1 <= pfq_empty_d1;
    o_pfq_addr_d1 <= pfq_addr_d1;
    o_qlen <= qlen;
    o_qs_out <= qs_out;
    o_qs_byte <= qs_byte;
    o_biu_intr <= biu_intr;
    o_counter_zero <= cz;
end

endmodule
