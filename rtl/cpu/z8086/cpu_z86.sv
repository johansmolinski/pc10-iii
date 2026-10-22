// cpu_z86.sv - the 8088: z8086's EU (Intel's microcode, one microinstruction
// per 8088 clock) in front of biu88, the cycle-stepped 8088 BIU of pc10-iii
// (doc/z8086.md).
//
// Clocking: everything runs on `clk`; biu88 steps at `step` (one clk per 8088
// clock, at the CLK rising edge). The EU's clock enable is `step` delayed by
// EU_DELAY clk, so that the EU sees the BIU state after the step (the queue
// after a T4 push, a transfer's done pulse). Its events of that clock are then
// handed to biu88 as MCL86-style commands over the next clocks, all within the
// same 8088 clock (biu88 attributes EU events to the running 8088 clock); biu88
// samples them this many clocks after the EU's clock:
//   +2  segment register write   (register strobe 11, codes 0-3)
//   +3  queue read and pop       (strobe 01, QS code 01 first / 11 subsequent)
//   +4  bus request, FLUSH, SUSP or HALT (EU_BIU_COMMAND bit 9, an edge)
//   +6  SUSP, when the same microinstruction also flushed
// None of biu88's MCL86 timing aids (end counter, release, scheduled read,
// taken bytes) is used: the EU's own microcode sequence gives the timing.
//
// The EU changes state only at its clock enable (z86_eu.sv). What happens
// between two of them is tracked here: the transfer's done pulse, the read
// data, and INTR/NMI/TEST sampled at the 8088 clock edge.
//
// The microcode tables (z86_tables.sv) are loaded through ucl_* (the bundle
// file, one byte per clk) while the CPU is held in reset.

module cpu_z86 #(
    parameter int EU_DELAY = 3,
    parameter bit OVERLAY  = 1'b1
) (
    input             clk,
    input             reset,
    input             step,

    // microcode bundle load port (tools/mkucode.py)
    input             ucl_we,
    input      [12:0] ucl_addr,
    input      [7:0]  ucl_data,

    // 8088 pins (maximum mode)
    input             READY_IN,
    input             NMI,
    input             INTR,
    input             TEST_n,
    output            LOCK_n,
    output     [19:0] AD_OUT,
    input      [7:0]  AD_IN,
    output     [2:0]  S2_S0_OUT,
    output            S6_3_MUX,
    output     [1:0]  QS_OUT,
    output     [7:0]  QS_BYTE,
    output            ALE,

    // test only (SingleStepTests): install a prefetched queue
    input             tb_preload,
    input      [31:0] tb_queue,
    input      [2:0]  tb_queue_len,
    input      [15:0] tb_ip,

    output     [15:0] dbg_cmd,      // the command to biu88 (harness: flush detection)
    output            dbg_ce,
    output     [2:0]  dbg_t_state,
    output     [2:0]  dbg_ta_state,
    output     [2:0]  dbg_latch,
    output     [2:0]  dbg_queue_len,
    output     [15:0] dbg_cs,
    output     [15:0] dbg_ip
);

// ------------------------------------------------------------------ EU clock enable
reg [EU_DELAY-1:0] ce_sr = '0;
always @(posedge clk) ce_sr <= {ce_sr[EU_DELAY-2:0], step};
wire ce_step = ce_sr[EU_DELAY-1];
// in reset the EU is clocked every clk, so that its reset takes at any length
wire ce = ce_step | reset;
reg  ce_d1;
always @(posedge clk) ce_d1 <= ce_step & ~reset;
assign dbg_ce = ce_step;

// pins sampled at the 8088 clock edge
reg intr_q, nmi_q, test_q;
always @(posedge clk) if (step) begin
    intr_q <= INTR;
    nmi_q  <= NMI;
    test_q <= TEST_n;
end

// ------------------------------------------------------------------ tables
wire [12:0] ua;
wire [20:0] uc_word;
wire [8:0]  uc_row;
wire [7:0]  tr_idx;
wire [12:0] tr_out;
wire [8:0]  grp_idx;
wire [14:0] grp_out;
wire        genuine_8088;

z86_tables #(.OVERLAY(OVERLAY)) tables (
    .clk          (clk),
    .ucl_we       (ucl_we),
    .ucl_addr     (ucl_addr),
    .ucl_data     (ucl_data),
    .ua           (ua),
    .uc_word      (uc_word),
    .uc_row       (uc_row),
    .genuine_8088 (genuine_8088),
    .tr_idx       (tr_idx),
    .tr_out       (tr_out),
    .grp_idx      (grp_idx),
    .grp_out      (grp_out)
);

// ------------------------------------------------------------------ EU
wire        q_rd, q_rd_first, req, req_wr, req_io, req_word, req_inta, req_seg0;
wire [1:0]  req_seg;
wire [15:0] req_addr, req_data;
wire        flush, susp, seg_wr, halt_req, halted, eu_lock, rni_pend;
wire [15:0] flush_ip, seg_wr_val;
wire [1:0]  seg_wr_sel;
wire        biu_done;
wire [15:0] biu_return_data, pfq_addr_out;
wire [7:0]  pfq_top_byte;
wire        pfq_empty;
reg         bus_busy, busy_late, busy_hold, wsusp, rd_pend, rd_word;
reg  [15:0] rd_data;

z86_eu eu (
    .clk        (clk),
    .ce         (ce),
    .biu_t      (dbg_t_state),
    .reset_n    (~reset),
    .intr       (intr_q),
    .nmi        (nmi_q),
    .test_n     (test_q),
    .ua         (ua),
    .uc_word    (uc_word),
    .tr_idx     (tr_idx),
    .tr_out     (tr_out),
    .grp_idx    (grp_idx),
    .grp_out    (grp_out),
    .q_top      (pfq_top_byte),
    .q_none     (pfq_empty),
    .biu_ip     (pfq_addr_out),
    .q_rd       (q_rd),
    .q_rd_first (q_rd_first),
    .req        (req),
    .req_wr     (req_wr),
    .req_io     (req_io),
    .req_word   (req_word),
    .req_inta   (req_inta),
    .req_seg0   (req_seg0),
    .req_seg    (req_seg),
    .req_addr   (req_addr),
    .req_data   (req_data),
    .flush      (flush),
    .flush_ip   (flush_ip),
    .susp       (susp),
    .seg_wr     (seg_wr),
    .seg_wr_sel (seg_wr_sel),
    .seg_wr_val (seg_wr_val),
    .halt_req   (halt_req),
    .halted     (halted),
    .lock       (eu_lock),
    .rni_pend   (rni_pend),
    .bus_busy   (bus_busy),
    .busy_hold  (busy_hold),
    .rd_pend    (rd_pend),
    .rd_word    (rd_word),
    .rd_data    (rd_data),
    .dbg_fc     ()
);

// ------------------------------------------------------------------ the bus between two EU clocks
// A request or SUSP of the EU's clock is outstanding until biu88's done
// (timing as in Jenner's XTCE: a read's last byte completes in T3 and the next
// microinstruction runs in T4, which is where biu88 reports a read done; a
// write and a SUSP that waited for a fetch complete in the clock biu88 reports
// them, and the EU runs a clock later (busy_hold), except the RNI of a W,RNI,
// which reads the next opcode in that clock).
always @(posedge clk) begin
    if (reset) begin
        bus_busy <= 1'b0; busy_late <= 1'b0; busy_hold <= 1'b0; rd_pend <= 1'b0;
    end else begin
        if (ce_d1 && (req || susp)) begin
            bus_busy  <= 1'b1;
            busy_late <= 1'b0;
            wsusp     <= req ? req_wr : 1'b1;
            rd_word   <= req_word;
        end
        if (step && bus_busy) busy_late <= 1'b1;
        if (ce_step) rd_pend <= 1'b0;
        if (biu_done && bus_busy) begin
            bus_busy <= 1'b0;
            if (wsusp && (busy_late || step) && !rni_pend) busy_hold <= 1'b1;
            if (!wsusp) begin
                rd_pend <= 1'b1;
                rd_data <= biu_return_data;
            end
        end
        if (ce_step) busy_hold <= 1'b0;
    end
end

// ------------------------------------------------------------------ adapter
// EU events (levels from the clock after ce) -> MCL86 command sequence
reg  [2:0]  ph;
reg         l_seg, l_q, l_qf, l_req, l_flush, l_susp, l_halt;
reg  [1:0]  l_seg_sel;
reg  [15:0] l_seg_val;
reg  [4:0]  l_code;
reg  [1:0]  l_rseg;
reg  [15:0] l_r3, l_dout;

// MCL86 request codes (biu88.v): 0C/10 read byte/word, 12 word read at
// segment 0, 0E/13 write byte/word, 08/1A IN, 0A/1C OUT (R3 = port), 16 INTA
// (a word: the 8088 BIU makes two INTA cycles of it), 18 HALT, 19 flush
// (R3 = new IP), 1E SUSP
wire [4:0] code_now = req_inta ? 5'h16 :
                      req_io   ? (req_wr ? (req_word ? 5'h1C : 5'h0A) : (req_word ? 5'h1A : 5'h08)) :
                      req_seg0 ? 5'h12 :
                      req_wr   ? (req_word ? 5'h13 : 5'h0E) : (req_word ? 5'h10 : 5'h0C);

// the 8088 starts at FFFF:0000 after reset: the first EU clock flushes to IP 0
reg rst_flush;
always @(posedge clk) begin
    if (reset) begin
        ph <= 3'd0;
        rst_flush <= 1'b1;
        {l_seg, l_q, l_qf, l_req, l_flush, l_susp, l_halt} <= 7'd0;
    end else if (rst_flush & ce_step) begin
        rst_flush <= 1'b0;
        ph <= 3'd1;
        {l_seg, l_q, l_qf, l_req, l_susp, l_halt} <= 6'd0;
        l_flush <= 1'b1;  l_code <= 5'h19;  l_r3 <= 16'h0;
    end else if (ce_d1 && (seg_wr | q_rd | req | flush | susp | halt_req)) begin
        ph        <= 3'd1;
        l_seg     <= seg_wr;  l_seg_sel <= seg_wr_sel;  l_seg_val <= seg_wr_val;
        l_q       <= q_rd;    l_qf      <= q_rd_first;
        l_req     <= req;     l_flush   <= flush;  l_susp <= susp;  l_halt <= halt_req;
        l_code    <= flush ? 5'h19 : code_now;
        l_rseg    <= req_seg;
        l_r3      <= flush ? flush_ip : req_addr;
        l_dout    <= req_data;
    end else if (ph != 3'd0)
        ph <= ph == 3'd6 ? 3'd0 : ph + 3'd1;
end

// EU_BIU_COMMAND: [13:12] strobe, [11:10] segment, [9] request, [8:4] code,
// [3:2] QS code of a queue strobe
reg [15:0] cmd, dataout;
always @* begin
    cmd = 16'h0;
    dataout = l_dout;
    case (ph)
        3'd1: if (l_seg) begin
                  cmd = {2'b00, 2'b11, 2'b00, 1'b0, 3'b000, l_seg_sel, 2'b00, 2'b00};
                  dataout = l_seg_val;
              end
        3'd2: if (l_q) cmd = {2'b00, 2'b01, 2'b00, 1'b0, 5'h00, l_qf ? 2'b01 : 2'b11, 2'b00};
        3'd3: if (l_req | l_flush) cmd = {2'b00, 2'b00, l_rseg, 1'b1, l_code, 2'b00, 2'b00};
              else if (l_susp)     cmd = {2'b00, 2'b00, 2'b00, 1'b1, 5'h1E, 2'b00, 2'b00};
              else if (l_halt)     cmd = {2'b00, 2'b00, 2'b00, 1'b1, 5'h18, 2'b00, 2'b00};
        3'd5: if (l_susp & (l_req | l_flush))
                                   cmd = {2'b00, 2'b00, 2'b00, 1'b1, 5'h1E, 2'b00, 2'b00};
        default: ;
    endcase
end
assign dbg_cmd = cmd;

// ------------------------------------------------------------------ BIU
wire [15:0] biu_cs;
biu88 biu (
    .CORE_CLK_INT         (clk),
    .RESET_INT            (reset),
    .step                 (step),
    .READY_IN             (READY_IN),
    .NMI                  (NMI),
    .INTR                 (INTR),
    .LOCK_n               (LOCK_n),
    .AD_OE                (),
    .AD_OUT               (AD_OUT),
    .AD_IN                (AD_IN),
    .S2_S0_OUT            (S2_S0_OUT),
    .S6_3_MUX             (S6_3_MUX),
    .QS_OUT               (QS_OUT),
    .QS_BYTE              (QS_BYTE),
    .ALE                  (ALE),
    .EU_BIU_COMMAND       (cmd),
    .EU_BIU_DATAOUT       (dataout),
    .EU_REGISTER_R3       (l_r3),
    .EU_PREFIX_LOCK       (eu_lock),
    .eu_qread             (2'b00),
    // the 8088's INTA "word" is {2nd cycle, 1st cycle}: the genuine 8088
    // microcode takes the vector from the high byte; the overlay for an 8086
    // ROM expects it in the low byte, where the 8086's own second INTA access
    // puts it (doc/z8086.md section 5)
    .INTA_VEC_LO          (OVERLAY && !genuine_8088),
    .BIU_DONE             (biu_done),
    .BIU_CLK_COUNTER_ZERO (),
    .BIU_SEGMENT          (),
    .BIU_NMI_CAUGHT       (),
    .BIU_NMI_DEBOUNCE     (1'b0),
    .BIU_INTR             (),
    .PFQ_TOP_BYTE         (pfq_top_byte),
    .PFQ_EMPTY            (pfq_empty),
    .PFQ_ADDR_OUT         (pfq_addr_out),
    .BIU_REGISTER_ES      (),
    .BIU_REGISTER_SS      (),
    .BIU_REGISTER_CS      (biu_cs),
    .BIU_REGISTER_DS      (),
    .BIU_REGISTER_RM      (),
    .BIU_REGISTER_REG     (),
    .BIU_RETURN_DATA      (biu_return_data),
    .BIU_CYC              (),
    .BIU_SINCE_READ       (),
    .BIU_SINCE_DONE       (),
    .BIU_SR_PENDING       (),
    .tb_preload           (tb_preload),
    .tb_queue             (tb_queue),
    .tb_queue_len         (tb_queue_len),
    .tb_ip                (tb_ip),
    .dbg_t_state          (dbg_t_state),
    .dbg_ta_state         (dbg_ta_state),
    .dbg_latch            (dbg_latch),
    .dbg_queue_len        (dbg_queue_len)
);

assign dbg_cs = biu_cs;
assign dbg_ip = pfq_addr_out;

endmodule
