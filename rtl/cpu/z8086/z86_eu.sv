//
// z86_eu.sv - the execution unit of nand2mario's z8086 (Intel's 8086/8088
// microcode on a rebuilt micro-architecture), cut loose from its bus and
// prefetch queue so that it runs behind biu88, the cycle-stepped 8088 BIU of
// pc10-iii, as the 8088 of the PC10-III.
//
// Derived from z8086.sv (z8086, nand2mario, December 2025, Apache 2.0; see
// NOTICE). pc10-iii changes (z8086-eval and z86, 2026-10-22), marked
// "pc10-iii":
//   - clock enable `ce`: one microinstruction per 8088 clock. Every register
//     of this module changes only at ce;
//   - the Intel tables are not logic here: the microcode, its address decoder,
//     the translation ROM and the group decode ROM are RAMs in z86_tables.sv,
//     loaded from the microcode bundle (AGENTS.md rule 4);
//   - the bus state machine and the 6-byte queue are gone: the real chip's
//     EU/BIU split with biu88 (rtl/cpu/biu88.sv). The queue is biu88's
//     (q_top/q_none in, q_rd out), the EU's IP is biu88's (PC reads return
//     it, so CORR has nothing left to correct), PC writes are handed to biu88
//     with FLUSH; SUSP and HALT are biu88 requests; biu88 reads the segment
//     registers;
//   - a type 6 microinstruction becomes one biu88 request (byte or word; the
//     8088 BIU splits a word into two byte cycles); the EU stalls until biu88
//     reports it done (bus_busy, below);
//   - interrupts as the 8088 takes them at an instruction boundary (NMI,
//     INTR, single step), the INT and TEST jump conditions, HLT, LOCK.
`timescale 1ns/1ns

module z86_eu #(
    parameter bit POPF_HI_IS_F = 1'b1
) (
    input             clk,
    input             ce,        // pc10-iii: one clock per 8088 clock
    input      [2:0]  biu_t,     // pc10-iii: biu88's T-state (0 Ti, 1 T1, 2 T2, 3 T3, 4 Tw, 5 T4)
    input             reset_n,
    input             intr,      // pc10-iii: pins sampled at the 8088 clock edge (adapter)
    input             nmi,
    input             test_n,

    // pc10-iii: the tables (z86_tables.sv)
    output     [12:0] ua,        // {AR, CR}: the microcode address
    input      [20:0] uc_word,   // the word at ua (two clk later)
    output     [7:0]  tr_idx,    // translation ROM
    input      [12:0] tr_out,
    output     [8:0]  grp_idx,   // group decode ROM (0x100: interrupt)
    input      [14:0] grp_out,

    // pc10-iii: biu88 side
    input      [7:0]  q_top,     // byte at the head of the queue
    input             q_none,    // queue empty
    input      [15:0] biu_ip,    // the EU's IP: address of q_top
    // outputs: set at ce, valid until the next ce (biu88 takes them at the
    // next step)
    output reg        q_rd,      // the EU reads q_top
    output reg        q_rd_first,//      ... as the first byte of an instruction
    output reg        req,       // bus request
    output reg        req_wr, req_io, req_word, req_inta, req_seg0,
    output reg [1:0]  req_seg,   // biu88 code: 00 ES, 01 SS, 10 CS, 11 DS
    output reg [15:0] req_addr,
    output     [15:0] req_data,  // OPR
    output reg        flush,     // jump: flush the queue, fetch from flush_ip
    output reg [15:0] flush_ip,
    output reg        susp,      // suspend prefetching
    output     [15:0] seg_cs, seg_ds, seg_es, seg_ss,
    output reg        halt_req,  // HLT: the halt bus cycle
    output reg        halted,    // HLT executed, no interrupt yet
    output reg        lock,      // LOCK prefix: the pin
    output reg        rni_pend,  // a W,RNI/R,RNI waits for its transfer
    // biu88: the transfer of the outstanding request (or SUSP) is done in
    // this clock; done_imm: in the step that took it; the read data
    input             bus_done,
    input             bus_done_imm,
    input      [15:0] bus_rdata,
    output            dbg_fc     // first clock of a new instruction (with ce)
);

//----------------------------------------------------------------- Global registers and signals

// CAPITALIZED variables like ROME are original ones from Intel documentation
// Lowercase variables are specific to this implementation

// Simulation config: control POPF high nibble behavior via plusargs
// Default is 1 (8088-style: F on high nibble). 80186 tests set this to 0.
reg popf_hi_is_f = POPF_HI_IS_F;

// Upper (BIU) register file
reg [15:0] CS = 16'hFFF0;    // segment registers
reg [15:0] DS, ES, SS;       
reg [15:0] IND, OPR;         // indirect and operand regs for memory access
reg [15:0] IND_pre_update;   // IND after "move" and before "action"
reg [15:0] IND_next;

// Lower (EU) register file
reg [15:0] AX, CX, DX, BX, SP, BP, SI, DI;  // general purpose regs
reg [15:0] F = 2'b10;        // flags: 15 14 13 12 11 10 9  8  7  6  5  4  3  2  1  0
                             //                    OF DF IF TF SF ZF    AF    PF    CF
reg [15:0] F2;               // new flags from ALU
wire       OF = F[11];
wire       DF = F[10];
wire       SF = F[7];
wire       ZF = F[6];
wire       AF = F[4];
wire       PF = F[2];
wire       CF = F[0];

// ALU signals
reg [15:0] TMPA, TMPB, TMPC; // ALU temp regs
reg  [4:0] ALUOPC;           // operation 110
reg [16:0] SIGMA;            // ALU result
reg [15:0] s_bus;            // source bus
reg        s_bus_rdy;

// Microcode sequencer internal regs and signals
reg [7:0]  IR;               // IR 102: instruction opcode
reg [8:0]  AR;               // AR 112: microcode address prefix
reg [3:0]  CR;               // CR 124: microcode sequence counter
reg [12:0] SR;               // SR 126: microcode saved return address
reg [4:0]  M, M_next;        // M 104: source bus code (r/m or IR[2:0])
reg [4:0]  N, N_next;        // N 106: destination bus code (reg or IR[5:3])
reg [3:0]  X;                // X 108: ALU operation (IR[6:3])
wire       X0 = X[0];     
reg        BPE;              // base prefix enable
reg        BPL;              // base prefix low
reg        BPH;              // base prefix high
reg  [3:0] CNT;              // loop counter for MAXC,NCZ
reg        Z16;              // internal zero flag - NZ tests this for loops
reg        XC;               // extended condition code
     
// Microcode signals     
reg [20:0] uc;               // current 21-bit microcode
reg        ROME;             // ROM-enable: `uc` is valid this cycle
wire       stall;            // memory access stalls microcode execution
assign ua = {AR, CR};        // pc10-iii: the tables decode and read it (z86_tables.sv)

wire [2:0] uc_typ;           // microcode type (LMN)
wire [4:0] uc_s;             // move source location (FGIJH)
wire [4:0] uc_d;             // move destination location (EDCBA)
assign uc_typ = uc[9:7];
assign uc_s = {uc[15:14],uc[12:11],uc[13]};
assign uc_d = {uc[16],uc[17],uc[18],uc[19],uc[20]};
reg [4:0] uc_s_l;

wire       T0 = uc_typ[2:1] == 2'd0;  // short jump
wire       T1 = uc_typ[2:1] == 2'd1;  // ALU operations
wire       T4 = uc_typ == 3'd4;       // bookkeeping
wire       T5 = uc_typ == 3'd5;       // long jump
wire       T6 = uc_typ == 3'd6;       // bus/memory operations
wire       T7 = uc_typ == 3'd7;       // long call
// Short jump
wire       NCZ   = T0 && uc[7:4] == 4'd4;
// ALU operations
wire       LRCY  = T1 && uc[7:3] == 5'b01010;
// Type 4 OPQR
wire       MAXC  = T4 && uc[6:3] == 4'd0;
wire       FLUSH = T4 && uc[6:3] == 4'd1;
wire       CF1   = T4 && uc[6:3] == 4'd2;
wire       CITF  = T4 && uc[6:3] == 4'd3;
wire       RCY   = T4 && uc[6:3] == 4'd4;
wire       CCOF  = T4 && uc[6:3] == 4'd6;
wire       SCOF  = T4 && uc[6:3] == 4'd7;
wire       WAIT  = T4 && uc[6:3] == 4'd8;
// Type 4 STU
// RNI is defined below
wire       WB    = T4 && uc[2:0] == 3'd1;
wire       CORR  = T4 && uc[2:0] == 3'd2;
wire       SUSP  = T4 && uc[2:0] == 3'd3;
wire       RTN   = T4 && uc[2:0] == 3'd4;

// Loader timing signals
wire       FC;               // loader first clock: opcode ready
wire       SC;               // loader second clock: group decode ready
wire       RNI;              // run next instruction
wire       NXT;              // next-to-last micro-instruction

// Instruction decode
// g_* values from: https://static.righto.com/8086/groupRom.html
reg        g_inout;          // in/out instructions
reg        g_modrm_not;      // ModR/M byte exists and performs read/modify/write on its argument.
reg        g_grp345;         // group 3/4/5 opcode
reg        g_prefix;         // instruction prefix
reg        g_2br_not;        // two-byte ROM instruction (similar to out1)
reg        g_alu_top;        // top bit for ALU
reg        g_cond;           // instruction that sets/clears condition code directly
reg        g_axal;           // instruction using AL/AX
reg        g_seg_reg_bits;   // MOV instruction using a segment register
reg        g_d;              // instruction with a `d` bit
reg        g_1bl;            // One-byte logic (1BL) instruction: prefixes, HLT, condition-code instructions.
reg        g_w;              // instruction where bit 0 is byte/word indicator.
reg        g_forcebyte;      // byte operation
reg        g_len1;           // byte operation when bit 1 is set
reg        g_carry, g_carry2;// allows a carry update. 
wire       modrm_present = ~g_2br_not;
reg        g_alu_in_opcode;  // Column 12: an instruction with bits 5-3 specifying the ALU instruction.
reg        ea_uses_bp;       // rm that includes BP uses SS by default; [disp16] (mod==00 && rm==110) uses DS
reg        MOD1;             // jump if 1 byte offset in effective address
reg        L8;               // byte instruction
reg        L8_aux;           // aux L8 for ALU and memory operations
wire       L8_next;  
wire       L8_aux_next;  
reg        F1;               // REP prefix active, and sign in multiplication
reg        F1Z;              // REPZ vs REPNZ (IR[0])

// These are in original 8086 but not currently used in this implementation
// reg        g_imm_move;      // Column 10: immediate move instructions, bit 3 select byte vs word
// reg        g_cmc;           // Column 13: CMC instruction
// reg        g_hlt;           // Column 14: HLT instruction
// reg        g_rep_prefix;    // Column 31: REP prefix
// reg        g_seg_prefix;    // Column 32: segment prefix
// reg        g_lock_prefix;   // Column 33: LOCK prefix
// reg        g_cli;           // Column 34: CLI instruction

// Interrupt (pc10-iii): taken at an instruction boundary (the loader's FC)
reg        nmi_pending;      // an NMI rising edge, not yet taken
reg        nmi_prev;
reg        if_start;         // IF at the start of the instruction: STI/POPF/IRET that
                             // set IF let one more instruction run first
reg        trap_arm;         // TF at the start of the instruction: single step after it
reg        seg_inhibit;      // after a prefix or a segment register load
                             // (MOV sr / POP sr): no interrupt at the next boundary
wire       intr_ok    = intr & F[9] & if_start;
wire       irq_take   = ~seg_inhibit & (nmi_pending | intr_ok | trap_arm);
wire [1:0] irq_ab     = nmi_pending ? 2'b01 : intr_ok ? 2'b10 : 2'b00;  // NMI, INTR, single step
wire       int_cond   = nmi_pending | (intr & F[9]);   // the microcode's INT condition (XTCE)
reg        prev_np;          // the previous instruction was not a prefix

// Prefetch queue view (pc10-iii: biu88's)
wire [7:0] q_bus;            // prefetch queue bus
wire       q_empty;

// Loader
reg [1:0] loader_state = 2'd0;      // patent figure 3 state machine

// Locations
localparam [4:0] LOC_ES  = 5'b00000;    // ES / RA
localparam [4:0] LOC_CS  = 5'b00001;    // CS / RC
localparam [4:0] LOC_SS  = 5'b00010;    // SS / RS
localparam [4:0] LOC_DS  = 5'b00011;    // DS / RD
localparam [4:0] LOC_PC  = 5'b00100;    // PC (IP)
localparam [4:0] LOC_IND = 5'b00101;    // IND (offset)
localparam [4:0] LOC_OPR = 5'b00110;    // OPR (last bus word)

localparam [4:0] LOC_Q = 5'b00111;      // 7
localparam [4:0] LOC_AL = 5'b01000;     // 8
localparam [4:0] LOC_CL = 5'b01001;     // 9
localparam [4:0] LOC_DL = 5'b01010;     // A
localparam [4:0] LOC_BL = 5'b01011;     // B
localparam [4:0] LOC_TMPA = 5'b01100;   // C
localparam [4:0] LOC_TMPB = 5'b01101;   // D
localparam [4:0] LOC_TMPC = 5'b01110;   // E
localparam [4:0] LOC_F = 5'b01111;      // F
localparam [4:0] LOC_AH = 5'b10000;     // 10
localparam [4:0] LOC_CH = 5'b10001;     // 11
localparam [4:0] LOC_DH = 5'b10010;     // 12
localparam [4:0] LOC_BH = 5'b10011;     // 13
localparam [4:0] LOC_M = 5'b10010;      // 12, only in microcode
localparam [4:0] LOC_N = 5'b10011;      // 13, only in microcode
localparam [4:0] LOC_SIGMA = 5'b10100;  // 14
localparam [4:0] LOC_TMPAL = 5'b10100;  // 14, destination
localparam [4:0] LOC_TMPBL = 5'b10101;  // 15, destination
localparam [4:0] LOC_CR    = 5'b10110;  // 16, source
localparam [4:0] LOC_TMPAH = 5'b10110;  // 16, destination
localparam [4:0] LOC_TMPBH = 5'b10111;  // 17, destination
localparam [4:0] LOC_AX = 5'b11000;     // 18
localparam [4:0] LOC_CX = 5'b11001;     // 19
localparam [4:0] LOC_DX = 5'b11010;     // 1A
localparam [4:0] LOC_BX = 5'b11011;     // 1B
localparam [4:0] LOC_SP = 5'b11100;     // 1C
localparam [4:0] LOC_BP = 5'b11101;     // 1D
localparam [4:0] LOC_SI = 5'b11110;     // 1E
localparam [4:0] LOC_DI = 5'b11111;     // 1F
localparam [4:0] LOC_ONES = 5'b10101;   // 15, source
localparam [4:0] LOC_ZERO = 5'b10111;   // 17, source

localparam [4:0] ALU_LRCY = 5'b01010;
localparam [4:0] ALU_RRCY = 5'b01011;
localparam [4:0] ALU_XI = 5'b10001;

//-----------------------------------------------------------------  Bus control
// pc10-iii: z8086's bus state machine is replaced by requests to biu88. A
// type 6 microinstruction (or SUSP) makes one request; the EU stalls
// (bus_busy) until biu88 reports it done: a read in the T4 of its last byte
// cycle, where the next microinstruction runs (XTCE); a write in its last
// T3/Tw, and a SUSP when no code fetch runs or the running one reaches T4:
// the EU runs a clock later (busy_hold), except the RNI of a W,RNI, which
// reads the next opcode in that clock, and a SUSP done at once.
reg         bus_busy;   // a request or SUSP is outstanding
reg         wsusp;      // ... and it is a write or a SUSP
reg         rd_word;
reg         corr_wait;  // CORR: waiting for the bus to go idle
wire        done_now  = bus_busy & bus_done;
wire        busy_hold = done_now & wsusp & ~bus_done_imm & ~rni_pend;
wire        eu_hold   = bus_busy & ~bus_done | busy_hold | corr_wait;
wire        rd_pend   = done_now & ~wsusp;
wire [15:0] rd_data   = bus_rdata;
reg  [15:0] pc_new;     // the last value written to PC (taken by FLUSH)
reg         pc_wr_now;  // (comb) PC is written by this microinstruction
reg  [1:0]  seg_code;   // (comb) the request's segment, biu88 code
reg         seg_zero;   // (comb) segment 0 (interrupt vectors) or I/O
// OPR with the read data that arrived since the last ce
wire [15:0] opr_in  = rd_pend ? (rd_word ? rd_data : {OPR[15:8], rd_data[7:0]}) : OPR;

// biu88 code of a z8086 segment-override code {BPH,BPL}: 00 CS, 01 DS, 10 SS, 11 ES
function automatic [1:0] biu_seg(input [1:0] code);
    case (code)
    2'b00: biu_seg = 2'b10;
    2'b01: biu_seg = 2'b11;
    2'b10: biu_seg = 2'b01;
    default: biu_seg = 2'b00;
    endcase
endfunction

always @* begin
    seg_zero = 1'b0;
    case (uc[3:2])
    2'b00: seg_code = 2'b00;                 // DA -> ES
    2'b01: begin seg_code = 2'b00; seg_zero = 1'b1; end   // D0 -> segment 0 or I/O
    2'b10: seg_code = 2'b01;                 // DS -> SS
    default: seg_code = BPE ? biu_seg({BPH, BPL}) : (ea_uses_bp ? 2'b01 : 2'b11);
    endcase
    pc_wr_now = uc_d == LOC_M && M == LOC_PC || uc_d == LOC_N && N == LOC_PC || uc_d == LOC_PC;
end

always @(posedge clk) if (ce) begin
    if (!reset_n) begin
        corr_wait <= 1'b0;
        bus_busy <= 1'b0;
        req <= 1'b0; flush <= 1'b0; susp <= 1'b0;
        CS <= 16'hFFFF;
        pc_new <= 16'h0;
        AX <= 16'h0000;
        TMPA <= 16'h0000;
        TMPB <= 16'h0000;
        TMPC <= 16'h0000;
        IND  <= 16'h0000;
        OPR  <= 16'h0000;
    end else begin
        // the outputs to biu88 are this ce's events
        req <= 1'b0; flush <= 1'b0; susp <= 1'b0;
        if (done_now) bus_busy <= 1'b0;
        // read data that arrived since the last ce (a move to OPR below wins)
        OPR <= opr_in;

        // CORR: the BIU corrects IP when no transfer is running (XTCE: not
        // in T1-T3 or T4); that clock is the CORR's second
        if (corr_wait && (biu_t == 3'd0 || biu_t == 3'd3)) corr_wait <= 1'b0;
        if (ROME & ~stall & CORR) corr_wait <= 1'b1;
        // EU memory access start (type 6)
        if (ROME & ~stall & T6) begin
            req      <= 1'b1;
            req_wr   <= uc[6];
            req_inta <= uc[5];   // IRQ bit
            req_io   <= seg_zero & g_inout;
            req_seg0 <= seg_zero & ~g_inout;
            req_word <= ~L8_aux;
            req_seg  <= seg_code;
            req_addr <= IND_pre_update;
            bus_busy <= 1'b1;
            wsusp    <= uc[6];
            rd_word  <= ~L8_aux;
        end

        if (ROME & ~stall & SUSP) begin
            susp     <= 1'b1;
            bus_busy <= 1'b1;
            wsusp    <= 1'b1;
        end
        if (ROME & ~stall & FLUSH) begin
            flush    <= 1'b1;
            flush_ip <= pc_wr_now ? s_bus : pc_new;
        end
        if (ROME & ~stall & pc_wr_now) pc_new <= s_bus;

        // write to registers
        if (SC) begin
            TMPA <= 16'h0;
            TMPB <= 16'h0;
        end
        if (ROME && s_bus_rdy) begin
            uc_s_l <= uc_s;
            if (uc_d == LOC_M) begin
                if (ALUOPC != 5'b00111) write_loc(M, s_bus);  // pc10-iii: CMP keeps M (XTCE)
            end
            else if (uc_d == LOC_N)
                write_loc(N, s_bus);
            else
                write_loc(uc_d, s_bus);
        end
        if (ROME & ~stall) IND <= IND_next;
    end
end

// Select default segment for data cycles: DS unless BP participates, then SS;
// Segment override prefix (BPE/BPH/BPL) supersedes the default.
function automatic [15:0] seg_from_code(input [1:0] code);
    case (code)
    2'b00: seg_from_code = CS; 
    2'b01: seg_from_code = DS; 
    2'b10: seg_from_code = SS; 
    default: seg_from_code = ES;
    endcase
endfunction

//-----------------------------------------------------------------  Prefetch queue
// pc10-iii: the queue is biu88's. The EU sees its head (q_top) and reads it
// (q_rd): the opcode at FC, the ModR/M byte at SC, any other "Q" source.
assign     q_bus   = q_top;
assign     q_empty = q_none | (ROME & FLUSH);

always @(posedge clk) if (ce) begin
    if (!reset_n) begin
        q_rd <= 1'b0;
        q_rd_first <= 1'b0;
    end else begin
        q_rd_first <= FC & ~irq_take;
        q_rd <= ~q_empty & (
                  FC & ~irq_take |                   // first byte
                  (ROME & uc_s == LOC_Q & ~stall) |  // source is Q
                  (SC & ~g_1bl & modrm_present));    // ModR/M at SC
    end
end

//----------------------------------------------------------------- Loader
// Loader generates timing signals for the microcode sequencer:
// FC: when Q ready, load 1st byte into IR, uaddr(AR and CR), start group decode
// SC: group signals ready, Q ready if 2BR, loading first microcode, set microcode_active=1
// SC+1: microcode out, start execution, load uaddr_next
// SC+2: first microcode done, start executing 2nd microcode 

wire EXEC = loader_state[1];        // sequencer has control
// RNI and NXT as generated by ROM-OUT 144 to LOADER 130
// pc10-iii: the RNI of a type 6 microinstruction (Jenner's "W,RNI"/"R,RNI")
// takes effect when the transfer is done (rni_pend), as in Jenner's XTCE;
// z8086 started the next instruction in the clock of the request.
assign RNI = ROME & ~eu_hold & ~skip_rni & ~wr_m_mem &
                  T4 & uc[2:0] == 3'b000 |  // STU=0 when Typ=4
             rni_pend & ~(bus_busy & ~bus_done);
// pc10-iii: NX also comes from type 4 (STU = 5 NX, STU = 1 WB,NX), as in
// Jenner's disassembly; z8086 had it only in type 1. Before every STU = 5 word
// the ROM has an RNI word.
// For a memory destination, XTCE drops a type 1 NX (also for CMP: its test is on
// the microcode's ALU field, XI) and a WB,NX (not for CMP, which writes nothing).
// pc10-iii: RNI/NX suppression as in XTCE instead of z8086's writes_memory
// table: a microinstruction that writes M while M is the memory operand (and
// the ALU op is not CMP, which writes nothing) skips every later plain RNI of
// the instruction (it ends with W,RNI); a type 1 NX is dropped while M is
// memory unless the microinstruction's own ALU field is CMP; a WB,NX only
// counts when M is not memory or the op is CMP.
wire m_mem    = M == LOC_OPR;
wire alu_cmp  = ALUOPC == 5'b00111;
wire wr_m_mem = uc_d == LOC_M & m_mem & ~alu_cmp;
reg  skip_rni;
always @(posedge clk) if (ce) begin
    if (SC) skip_rni <= 1'b0;
    else if (ROME & ~stall & wr_m_mem) skip_rni <= 1'b1;
end
assign NXT = ROME & ~eu_hold &
             (T1 & uc[0] & ~(m_mem & uc[7:3] != 5'd7) |
              T4 & uc[2:0] == 3'd5 |
              T4 & uc[2:0] == 3'd1 & (~m_mem | alu_cmp));
wire uc_f = uc[10] == 1'b1;

// First Clock: ready to read the first byte of the instruction from Q
// pc10-iii: or to start an interrupt, which needs no byte (XTCE's readOpcode
// tests the interrupts first); after HLT only an interrupt starts one
assign FC = (loader_state == 2'd0 | loader_state == 2'd2 & (NXT | RNI)) &
            (irq_take | ~q_empty & ~halted);
// Second Clock: group decode is ready, ready to read the 2nd byte for 2BR instructions
//               or start microcode execution for 1-byte instructions
assign SC = (loader_state == 2'd1 | loader_state == 2'd3) & (g_2br_not | ~q_empty);

// translation ROM signals
wire t_mem = SC;
wire [4:0] t_mode_rm = t_mem ? {q_bus[7:6], q_bus[2:0]} :  // modrm: {mode[1:0], rm[2:0]}
                               {uc_typ[1], uc[3:0]};    // jump/call: {is_call, dest[3:0]}
reg t_disp_not_r;
wire t_disp_not = SC ? ~(q_bus[7] ^ q_bus[6]) : t_disp_not_r;  // mode=00 or 11
always @(posedge clk) if (ce) t_disp_not_r <= t_disp_not;
wire t_mem_read_not = g_modrm_not;  // ModR/M byte exists and performs read/modify/write on its argument.
// translation ROM output: goes to {AR, CR} for modrm and jump/call
// pc10-iii: the ROM is a RAM in z86_tables.sv
assign tr_idx = {t_mode_rm, t_mem_read_not, t_mem, t_disp_not};
wire [12:0] t_out = tr_out;
// pc10-iii: the group decode ROM, read at FC
assign grp_idx = irq_take ? 9'h100 : {1'b0, q_bus};

// Loader state machine
always @(posedge clk) if (ce) begin
    if (!reset_n) begin
        loader_state <= 2'd0;
    end else begin
        case (loader_state) 
        2'd0: if (FC)                loader_state <= 2'd1;
        2'd1: if (g_1bl)             loader_state <= 2'd0;
              else if (SC)           loader_state <= 2'd2;
        2'd2: if (FC & RNI)          loader_state <= 2'd1;
              else if (~FC & RNI)    loader_state <= 2'd0;
              else if (FC & NXT)     loader_state <= 2'd3;
        2'd3: if (SC & ~g_1bl)       loader_state <= 2'd2;
              else if (~SC)          loader_state <= 2'd1;
              else if (g_1bl)        loader_state <= 2'd0;
        endcase
    end
end

//----------------------------------------------------------------- Microcode sequencer

assign stall = (ROME & q_empty & (EXEC & uc_s == LOC_Q)) | eu_hold;
assign L8_next = g_w & ~IR[0] | g_len1 & IR[1] | g_forcebyte | IR[7:3] == 5'b1011_0;    // byte instruction
assign L8_aux_next = (g_w & ~IR[0] | g_forcebyte | IR[7:3] == 5'b1011_0);
always @(posedge clk) if (ce) begin
    if (SC) begin 
        L8 <= L8_next; 
        L8_aux <= L8_aux_next; 
    end
    if (ROME & ~stall & AR[8:5] == 4'b1000)   // INTR routine needs word operation
        L8_aux <= 1'b0;
end

// Microcode sequencing is a 3-stage pipeline:
// Stage 0 (FC): opcode (q_bus) -> u-addr ({AR,CR}). Once per instruction.
// Stage 1 (SC | loader_state[1] & ~stall): u-addr -> microcode, CR++, set ROME=1
// Stage 2 (ROME & ~stall): execute microcode
//  - if jump, ROME=0 and load new u-addr
always @(posedge clk) if (ce) begin
    if (!reset_n) begin
        ROME <= 1'b0;
        rni_pend <= 1'b0;
    end else begin
        if (~stall | SC)
            uc <= uc_word;      // pc10-iii: the word at {AR, CR} (z86_tables.sv)

        // Advance CR and set ROME
        ROME <= stall ? ROME : 1'b0;
        if (EXEC & ~RNI & ~stall) begin  // normal execution
            ROME <= 1'b1;
            CR <= CR + 4'b1;
        end
        // pc10-iii: a type 6 with RNI ends the microcode; RNI follows at done
        if (RNI) rni_pend <= 1'b0;
        if (ROME & ~stall & T6 & uc[4]) begin
            rni_pend <= 1'b1;
            ROME <= 1'b0;
        end

        // First cycle: load new instruction
        if (FC) begin                           
            if (irq_take) begin
                // On interrupt, go to 1r0000000.00ab 
                // ab: 00 (trap), 01 (NMI), 10 (INTR)
                {AR, CR} <= {9'b1_0000_0000, 2'b00, irq_ab};  // INTR microcode address
                IR <= 8'hCD;          // INT n

                // pc10-iii: the group decode ROM's entry for the interrupt
                // (index 0x100, as XTCE)
                {g_carry, g_len1, g_forcebyte, g_w, g_1bl, g_d,
                 g_seg_reg_bits, g_axal, g_cond, g_alu_top,
                 g_2br_not, g_prefix, g_grp345, g_modrm_not, g_inout} <= grp_out;
                g_alu_in_opcode <= 1'b0;
                M_next <= 3'b0;
                N_next <= 3'b0;
            end else begin
                // Set microcode entry address
                {AR, CR} <= {q_bus, 4'b0};
                IR <= q_bus;

                // group decode
                {g_carry, g_len1, g_forcebyte, g_w, g_1bl, g_d, g_seg_reg_bits, g_axal, g_cond, g_alu_top,
                 g_2br_not, g_prefix, g_grp345, g_modrm_not, g_inout} <= grp_out;  // pc10-iii: z86_tables.sv
                // non-group instructions
                g_alu_in_opcode <= ~(q_bus[7:4] == 4'hF & q_bus[2:1] == 2'b11 |   // group345
                                     q_bus[3:2] == 2'b0 & (q_bus[7:4] == 4'h8 | q_bus[7:4] == 4'hD)); // group 1 and 2

                // Store M/N for decode in SC and later
                M_next <= q_bus[2:0];               // M_next so NXT does not overwrite M
                N_next <= q_bus[5:3];
            end
        end
        // Second cycle: group decode complete
        if (SC & ~g_1bl) begin                  // Second Cycle
            ROME <= 1'b1;
            CR <= CR + 4'b1;
            // Capture ModR/M now
            if (modrm_present) begin
                automatic reg [4:0] M_expand, N_expand;
                automatic reg [8:0] AR_updated;   // Instruction start AR including GRP345
                ea_uses_bp <= (q_bus[7:6] != 2'b11) &
                                (q_bus[2:0] == 3'b010 | q_bus[2:0] == 3'b011 |
                                (q_bus[2:0] == 3'b110 & q_bus[7:6] != 2'b00));
                MOD1 <= q_bus[6];

                // Map REG field to N
                // This does not use L8_next because https://www.righto.com/2023/07/undocumented-8086-instructions.html:
                // "However, the register operations use only bit 0 to select a byte or word transfer."
                if (g_seg_reg_bits)
                    N_expand = {3'b0, q_bus[4:3]};
                else
                    N_expand = gpr_bus_code(q_bus[5:3], ~L8_aux_next, 1'b0);  // normal case

                // Update instruction start address for Group 3-5
                AR_updated = AR;
                if (SC & g_grp345) begin  // GRP3 -> F0h-F7h, GRP4,GRP5 -> F8h-FFh
                    AR_updated[2:0] = q_bus[5:3];
                    AR_updated[8] = IR[0];// MSB of AR should be IR[0] for group 3-5.
                    CR <= 4'b0;      
                    ROME <= 1'b0;         // bubble as AR is changed
                end

                // For register-only addressing (mod==11), map r/m to M directly
                if (q_bus[7:6] == 2'b11) begin
                    M_expand = gpr_bus_code(q_bus[2:0], ~L8_aux_next, 1'b0);
                    AR <= AR_updated;     // start directly from instruction start address
                end else begin
                    // Jump to EA microcode via translate() and save instruction start address
                    {AR, CR} <= t_out;    // EA microcode address
                    SR       <= {AR_updated, 4'b0}; // Save instruction start address
                    M_expand =  LOC_OPR;  // M is OPR for memory addressing
                    ROME     <= 1'b0;     // bubble like a microcode jump
                end

                if (g_d & IR[1]) begin  // swap M and N for instruction with d bit
                    M <= N_expand;
                    N <= M_expand;
                end else begin          // normal case
                    M <= M_expand;
                    N <= N_expand;
                end
            end else begin
                // No ModR/M: decode M and R from opcode fields
                M <= gpr_bus_code(M_next[2:0], ~L8_aux_next, g_axal); // decode M into 5-bit location code
                if (IR[7:5] == 3'b0 && IR[2:1] == 2'b11)    // PUSH/POP seg
                    N <= {3'b0, N_next[1:0]};       // N is segment register
                else
                    N <= gpr_bus_code(N_next[2:0], ~L8_aux_next, g_axal); // normal case
                ea_uses_bp <= 1'b0;
            end
        end
        // Branches
        if (ROME & ~stall) begin
            automatic reg taken;
            // Microcode execution: deal with jumps
            taken = 1'b0;
            if (T0 | T5 | T7) begin
                casez (uc[9:4])
                /// Both long and short jumps
                6'b??1_000: taken = 1'b1;  // UNC
                6'b??1_010: taken = ~Z16;  // NZ tests Z16
                6'b??1_011: taken = X0;    // X0
                6'b??1_100: taken = ~CF;   // NCY
                6'b??1_101: taken = F1;    // F1 flag is active
                6'b??1_110: taken = int_cond; // pc10-iii: INT, an interrupt is pending
                6'b??1_111: taken = XC;    // XC
                /// short jump only
                6'b000_000: taken = ZF ^ F1Z; // F1ZZ
                6'b000_001: taken = MOD1; 
                6'b000_010: taken = L8;   // L8: byte instruction or B0-B7
                6'b000_011: taken = ZF;   // Z
                6'b000_100: taken = CNT != 4'd0; // NCZ, Not Counter Zero
                6'b000_101: taken = test_n; // pc10-iii: TEST, the -TEST pin is not asserted (WAIT)
                6'b000_110: taken = OF;   // OF
                6'b000_111: taken = CF;   // CY
                6'b001_001: taken = ~F1;  // NF1: F1 flag is not active
                default: taken = 1'b0;
                endcase
                if (taken) begin
                    ROME <= 1'b0;    // one-cycle bubble as next ucode is useless
                    if (uc_typ[2]) begin  // far jump/call
                        {AR, CR} <= t_out;
                        if (uc_typ[1:0] == 2'b11) begin  // call - save return address
                            SR <= {AR, CR};
                        end
                    end else begin         // near jump/call
                        CR <= uc[3:0];
                    end
                end
            end
            // Type 6: bus ops, pause ucode
            // if (uc_typ == 3'd6) ROME <= 1'b0;
            // Type 4: bookkeeping operations
            if (RTN) begin      // Return to saved micro-address (used by EALOAD/EADONE)
                {AR, CR} <= SR;
                ROME <= 1'b0;
            end
        end
    end
end

// prefix handling. pc10-iii: as F1 below, the override is also cleared at the
// start (SC) of an instruction that follows a non-prefix one. z8086 cleared it
// only at RNI, and an SC in the clock of the previous instruction's RNI (NX
// overlap) took priority, so the override leaked into the next instruction:
// the Commodore PC BIOS 4.41 (F000:F18F) does MOV AL,CS:[BX+d16] then
// MOV [0065h],AL, which stored to F000:0065 and left the CGA disabled.
always @(posedge clk) if (ce) begin
    if (!reset_n) begin
        BPE <= 1'b0;
        BPL <= 1'b0;
        BPH <= 1'b0;
    end else if (SC) begin
        if (prev_np) begin
            BPE <= 1'b0;
            BPL <= 1'b0;
            BPH <= 1'b0;
        end
        if (g_prefix & ~IR[7]) begin
            BPE <= 1'b1;
            case ({IR[4:3]})
            2'b00: {BPH,BPL} <= 2'b11;  // 26: ES
            2'b01: {BPH,BPL} <= 2'b00;  // 2E: CS
            2'b10: {BPH,BPL} <= 2'b10;  // 36: SS
            2'b11: {BPH,BPL} <= 2'b01;  // 3E: DS
            endcase
        end
    end else if (RNI) begin
        BPE <= 1'b0;
        BPL <= 1'b0;
        BPH <= 1'b0;
    end
end

// Extended Condition Codes
always @* begin
    case (IR[3:1])
    3'h0: XC = OF;
    3'h1: XC = CF; 
    3'h2: XC = ZF;  
    3'h3: XC = CF | ZF;
    3'h4: XC = SF; 
    3'h5: XC = PF; 
    3'h6: XC = SF ^ OF;
    default: XC = (SF ^ OF) | ZF;
    endcase
    if (IR[0]) XC = ~XC;
end

// pc10-iii: interrupts at the instruction boundary, HLT, LOCK.
// - NMI: a rising edge (sampled at the 8088 clock edge) is pending until taken.
// - INTR: taken at a boundary when IF is set and was set at the start of the
//   instruction that ends there (after STI, POPF or IRET that set IF one more
//   instruction runs; MartyPC's interrupt_inhibit).
// - single step: TF at the start of the instruction (trap_arm); an instruction
//   that sets TF is not trapped, one that clears it is.
// - none after a prefix or a segment register load (MOV sr, POP sr: the group
//   ROM's "load segment register" class in XTCE), so a prefixed instruction is
//   never split and SS:SP is loaded together.
// - priority NMI, INTR, single step (MartyPC); the routine's entry is
//   1r0000000.00ab (XTCE: 0x1000 trap, 0x1001 NMI, 0x1002 INTR).
// - HLT (1BL): no instruction starts until an interrupt is taken; one halt bus
//   cycle (halt_req).
always @(posedge clk) if (ce) begin
    if (~reset_n) begin
        nmi_pending <= 1'b0;
        nmi_prev <= 1'b0;
        if_start <= 1'b0;
        trap_arm <= 1'b0;
        seg_inhibit <= 1'b0;
        halted <= 1'b0;
        halt_req <= 1'b0;
        lock <= 1'b0;
        prev_np <= 1'b1;
    end else begin
        nmi_prev <= nmi;
        if (nmi & ~nmi_prev) nmi_pending <= 1'b1;
        halt_req <= 1'b0;

        if (FC) begin
            seg_inhibit <= 1'b0;
            if_start <= F[9];
            if (irq_take) begin
                trap_arm <= 1'b0;
                halted <= 1'b0;
                if (nmi_pending) nmi_pending <= 1'b0;
            end else
                trap_arm <= F[8];
        end
        if (SC) begin
            if (g_prefix | IR == 8'h8E | IR[7:5] == 3'b000 & IR[2:0] == 3'b111)
                seg_inhibit <= 1'b1;
            if (IR == 8'hF4 & g_1bl) begin
                halted <= 1'b1;
                halt_req <= 1'b1;
            end
            // LOCK: from the LOCK prefix to the start of the instruction after
            // the locked one (XTCE)
            if (prev_np) lock <= 1'b0;
            if (IR == 8'hF0) lock <= 1'b1;
            prev_np <= ~g_prefix;
        end
    end
end

//----------------------------------------------------------------- Internal FFs

// Flag updates
always @(posedge clk) if (ce) begin
    if (ROME & ~stall) begin
        if (uc_f) F <= F2;  // update flags from ALU
        if (s_bus_rdy && uc_d == LOC_F) begin // setting F from s_bus
            F <= s_bus;
            // POPF sets fixed values for F[15:12], F[5], F[3], F[1]
            F[5] <= 1'b0; F[3] <= 1'b0; F[1] <= 1'b1;   
            F[15:12] <= popf_hi_is_f ? 4'hF : 4'h0;    // undefined bits differ in tests
        end
        if (CF1) F1 <= ~F1;      // Invert F1 flag
        if (RCY) F[0] <= 1'b0;   // Reset carry
        if (CCOF) begin          // Clear carry and overflow
            F[11] <= 1'b0;
            F[0] <= 1'b0;
        end
        if (SCOF) begin          // Set carry and overflow
            F[11] <= 1'b1;
            F[0] <= 1'b1;
        end
        if (CITF) begin          // Clear interrupt and trap flags
            F[8] <= 1'b0;
            F[9] <= 1'b0;
        end
        if ((ALUOPC == ALU_LRCY || ALUOPC == ALU_RRCY) && uc_s == LOC_SIGMA) begin 
            F[0] <= F2[0];      // LRCY/RRCY updates CF when SIGMA is source. used in CORD
        end
    end
    if (SC & g_1bl) begin  // 1-byte logic instructions
        case (IR[3:0])
        4'h5: F[0] <= ~F[0];  // CMC
        4'h8: F[0] <= 1'b0;   // CLC
        4'h9: F[0] <= 1'b1;   // STC
        4'hA: F[9] <= 1'b0;   // CLI
        4'hB: F[9] <= 1'b1;   // STI
        4'hC: F[10] <= 1'b0;  // CLD
        4'hD: F[10] <= 1'b1;  // STD
        default: ;
        endcase
    end
    // Prefix flags. pc10-iii: as XTCE, F1 is cleared at the start (SC) of an
    // instruction that follows a non-prefix one, then a REP prefix sets it
    // (not LOCK, F0). z8086 cleared it at RNI, which loses a REP prefix whose
    // SC comes in the clock of the previous instruction's RNI (NX overlap).
    if (SC) begin
        if (prev_np) F1 <= 1'b0;
        if (g_prefix & IR[7:1] == 7'b1111_001) F1 <= 1'b1;   // REP/REPZ/REPE active
        if (IR[7:6] == 2'b11 & IR != 8'hF0) F1Z <= IR[0];    // REPNZ/REPZ/LOOPNZ/LOOPZ active
    end
end

// Loop counter
always @(posedge clk) if (ce) begin
    if (ROME & ~stall) begin
        if (MAXC) CNT <= L8 ? 4'h7 : 4'hF;
        if (NCZ) CNT <= CNT - 4'b1;
    end
end

// Internal condition flags
always @(posedge clk) if (ce) begin
    if (ROME & ~stall) begin
        // NZ tests Z16. Z16 is updated when SIGMA is referenced as a move source.
        // So to update Z16 only, one uses "SIGMA -> no dest" in microcode.
        if (uc_s == LOC_SIGMA) Z16 <= SIGMA[15:0] == 16'd0;
    end
end

//----------------------------------------------------------------- ALU
// ALU operations
reg [1:0] alu_src;
always @(posedge clk) if (ce) begin
    if (!reset_n) begin
    end else begin
        if (FC) begin
            X <= q_bus[6:3];
        end
        if (SC & ~g_alu_in_opcode) begin
            if ((IR == 8'hF6 || IR == 8'hF7) && q_bus[5:3] == 3'b000)
                X[2:0] <= 3'b100;         // Force AND for TEST in GRP3
            else
                X[2:0] <= q_bus[5:3];     // overwrite X[5:3] with modrm[5:3] for GRP instructions
        end
        if (SC) begin  // for EA address calculation
            ALUOPC <= 5'b0;
            alu_src <= 2'b0;  // TMPA
        end
        if (ROME & uc_typ[2:1] == 2'b01) begin
            ALUOPC <= uc[7:3] == ALU_XI ? {g_alu_top, X} : uc[7:3];
            alu_src <= uc[2:1];
        end
    end
end

alu alu (
    .op(ALUOPC),
    .src(alu_src == 2'b00 ? TMPA : alu_src == 2'b01 ? TMPB : TMPC),
    .dst(TMPB),
    .is_byte(L8_aux),
    .flags(F),
    .update_carry(g_carry2),
    .result(SIGMA[15:0]),
    .flags_out(F2)
);

always @(posedge clk) if (ce) begin
    if (SC) g_carry2 <= g_carry;       // late version of g_carry: updated *after* SC
end

//----------------------------------------------------------------- S bus read
// Upper register location codes (explicit names for readability when used as destinations)

always @(*) begin
    s_bus_rdy = 1'b1;
    case (uc_s)
    LOC_M:    s_bus = read_loc(M);           // use M’s current location code
    LOC_N:    s_bus = read_loc(N);           // use N’s current location code (REG field)
    LOC_Q: begin
        s_bus     = read_loc(LOC_Q);
        s_bus_rdy = !q_empty;
    end
    default:  s_bus = read_loc(uc_s);
    endcase
end

function automatic [15:0] read_loc(input [4:0] loc);
    begin
        case (loc)
        // Upper registers (EDCBA = 00000..00110)
        LOC_ES:   read_loc = ES;                // RA (ES)
        LOC_CS:   read_loc = CS;                // RC (CS)
        LOC_SS:   read_loc = SS;                // RS (SS)
        LOC_DS:   read_loc = DS;                // RD (DS)
        LOC_PC:   read_loc = biu_ip;            // pc10-iii: the EU's IP from biu88
        LOC_IND:  read_loc = IND;               // IND
        LOC_OPR:  read_loc = opr_in;            // OPR (pc10-iii: with the read data of this ce)
        LOC_AL:   read_loc = {8'h00, AX[7:0]};  // AL as 16-bit
        LOC_AH:   read_loc = {8'h00, AX[15:8]}; // AH as 16-bit
        LOC_CL:   read_loc = {8'h00, CX[7:0]};  // CL as 16-bit
        LOC_CH:   read_loc = {8'h00, CX[15:8]}; // CH as 16-bit
        LOC_DL:   read_loc = {8'h00, DX[7:0]};  // DL as 16-bit
        LOC_DH:   read_loc = {8'h00, DX[15:8]}; // DH as 16-bit
        LOC_BL:   read_loc = {8'h00, BX[7:0]};  // BL as 16-bit
        LOC_BH:   read_loc = {8'h00, BX[15:8]}; // BH as 16-bit
        LOC_F:    read_loc = F;                 // F
        LOC_CR:   read_loc = CR;                // CR
        LOC_AX:   read_loc = AX;                // AX
        LOC_CX:   read_loc = CX;                // CX
        LOC_DX:   read_loc = DX;                // DX
        LOC_BX:   read_loc = BX;                // BX
        LOC_SP:   read_loc = SP;                // SP
        LOC_BP:   read_loc = BP;                // BP
        LOC_SI:   read_loc = SI;                // SI / IJ
        LOC_DI:   read_loc = DI;                // DI / IK
        LOC_TMPA: read_loc = TMPA;              // TMPA
        LOC_TMPB: read_loc = TMPB;              // TMPB
        LOC_TMPC: read_loc = TMPC;              // TMPC
        LOC_ONES: read_loc = 16'hFFFF;          // ONES
        LOC_ZERO: read_loc = 16'h0000;          // ZERO
        LOC_Q:    read_loc = {8'h00, q_bus};    // Q as 16-bit
        LOC_SIGMA:read_loc = SIGMA[15:0];       // SIGMA
        default:  read_loc = 16'hXXXX;
        endcase
    end
endfunction

//-----------------------------------------------------------------  D bus write
task automatic write_loc(input [4:0] loc, input [15:0] value);
    begin
        case (loc)
        // Upper registers (EDCBA = 00000..00110)
        LOC_ES:    ES <= value;                   // ES (pc10-iii: biu88 reads them)
        LOC_CS:    CS <= value;                   // CS
        LOC_SS:    SS <= value;                   // SS
        LOC_DS:    DS <= value;                   // DS
        // LOC_PC:    IP <= value;                   // PC (IP)
        LOC_OPR:   OPR <= value;                  // OPR (last bus word)
        LOC_AX:    AX <= value;                   // AX
        LOC_CX:    CX <= value;                   // CX
        LOC_DX:    DX <= value;                   // DX
        LOC_BX:    BX <= value;                   // BX
        LOC_SP:    SP <= value;                   // SP
        LOC_BP:    BP <= value;                   // BP
        LOC_SI:    SI <= value;                   // SI
        LOC_DI:    DI <= value;                   // DI
        LOC_AL:    AX[7:0]  <= value[7:0];        // AL
        LOC_CL:    CX[7:0]  <= value[7:0];        // CL
        LOC_DL:    DX[7:0]  <= value[7:0];        // DL
        LOC_BL:    BX[7:0]  <= value[7:0];        // BL
        LOC_AH:    AX[15:8] <= value[7:0];        // AH
        LOC_CH:    CX[15:8] <= value[7:0];        // CH
        LOC_DH:    DX[15:8] <= value[7:0];        // DH
        LOC_BH:    BX[15:8] <= value[7:0];        // BH
        LOC_TMPA:  TMPA <= value;
        LOC_TMPB:  TMPB <= value;
        LOC_TMPC:  TMPC <= value;
        LOC_TMPAL: TMPA[7:0] <= value[7:0];
        LOC_TMPBL: TMPB <= {{8{value[7]}}, value[7:0]};    // sign-extend (needed by [i] @1de)
        LOC_TMPAH: TMPA[15:8] <= value[7:0];
        LOC_TMPBH: TMPB[15:8] <= value[7:0];
        // LOC_IND: // IND is updated separately
        // LOC_F:   // F is updated separately
        default: ;
        endcase
    end
endtask

// IND update logic
always @* begin
    IND_pre_update = IND;
    if (uc_d == LOC_IND || uc_d == LOC_M && M == LOC_IND || uc_d == LOC_N && N == LOC_IND) begin
        IND_pre_update = s_bus;
    end
    // Post update to IND
    IND_next = IND_pre_update;
    if (uc_typ == 3'd6) case (uc[1:0])
    2'b00: IND_next = IND_pre_update + 16'h2;  // P2
    2'b01: begin                               // BL
        if (DF) begin
            IND_next = L8_aux ? IND_pre_update - 16'h1 : IND_pre_update - 16'h2;  
        end else begin
            IND_next = L8_aux ? IND_pre_update + 16'h1 : IND_pre_update + 16'h2;  
        end
    end
    2'b10: IND_next = IND_pre_update - 16'h2;  // M2
    default: ;        // P0
    endcase
end


//----------------------------------------------------------------- Helper functions

// pc10-iii: the group decode ROM, the microcode address decoder and the
// translation ROM are RAMs in z86_tables.sv (loaded from the bundle).

// Map “low 3 bits” + width into the 5-bit location code
function automatic [4:0] gpr_bus_code(input [2:0] rrr, input w, input axal);
    begin
        // This matches the S/D encoding
        // 11000 = AX, 01000 = AL, 10000 = AH, etc.
        if (axal) 
            gpr_bus_code = {w, 4'b1000};
        else if (w)  // word registers: AX..DI
            gpr_bus_code = {2'b11, rrr};
        else    // byte registers: AL..BH
            gpr_bus_code = {rrr[2] ? 3'b100 : 3'b010, rrr[1:0]};
    end
endfunction 

`ifdef VERILATOR
initial begin
    integer __flags_hi_opt;
    if ($value$plusargs("flags_hi_f=%d", __flags_hi_opt)) begin
        popf_hi_is_f = (__flags_hi_opt != 0);
    end
end
`endif

// pc10-iii
assign dbg_fc = FC;

assign req_data = ~L8_aux ? OPR : {8'b0, OPR[7:0]};
assign seg_cs = CS;
assign seg_ds = DS;
assign seg_es = ES;
assign seg_ss = SS;

endmodule
