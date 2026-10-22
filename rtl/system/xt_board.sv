// xt_board.sv - the IBM 5160 system board logic around the 8088.
//
// Everything on clk (100.2273 MHz) with the enables of pc_clocks.sv. Parts:
//   - address latch (8282s) and the 8288 bus controller function, driven by
//     the BIU's T-state and bus status instead of reconstructing them from the
//     status pins;
//   - READY (8284 + the board's wait-state logic): one wait state on every
//     CPU I/O cycle, none on memory, IOCHRDY from the cards, and the DMA wait
//     (MartyPC's rules, cpu_808x/cycle.rs and bus/io.rs);
//   - DMA: 8237 (KF8237), the hold/AEN logic of the 5160 (from KFPC-XT /
//     MiSTer PCXT Bus_Arbiter.sv, MIT, kitune-san), the 74LS670 page registers,
//     refresh request DRQ0 from 8253 channel 1;
//   - 8259 PIC, 8253 PIT, 8255 PPI (KF8259/KF8253/KF8255, MIT, kitune-san),
//     NMI mask register, speaker, the keyboard interface;
//   - memory decode: system RAM (0-RAM_KB), BIOS ROM (F0000-FFFFF), the rest
//     to the card bus (doc/architecture.md section 3).
//
// Calibration points against MartyPC / real hardware are marked "CAL".
//
// GPL-3.0-or-later, pc10-iii.

module xt_board #(
    parameter int RAM_KB = 640,
    // simulation only: DRQ0 n CPU clocks late. MartyPC starts its refresh
    // schedule when its device loop sees the PIT write (here 7 clocks after
    // the 8253's reload); tb/sys sets this to compare traces past the first
    // refresh. 0 = the hardware.
    parameter int DRQ0_SKEW = 0
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        cpu_step,
    input  logic        cpu_fall,
    input  logic        pit_clk,

    // the CPU
    input  logic [19:0] cpu_ad,
    output logic [7:0]  cpu_din,
    input  logic [2:0]  cpu_s2_s0,
    input  logic        cpu_lock_n,
    input  logic [2:0]  cpu_bus_t,
    input  logic [2:0]  cpu_bus_type,
    output logic        cpu_ready,
    output logic        cpu_intr,
    output logic        cpu_nmi,

    // system RAM / BIOS ROM ports (doc/architecture.md section 4)
    output logic [19:0] ram_addr,
    output logic        ram_en,
    output logic        ram_we,
    output logic [7:0]  ram_wdata,
    input  logic [7:0]  ram_rdata,
    input  logic        ram_ack,
    output logic [15:0] rom_addr,
    input  logic [7:0]  rom_rdata,

    // the card bus (section 3)
    output logic [19:0] isa_addr,
    output logic [19:0] isa_addr_next,  // pc10-iii: isa_addr of the next clk (registered decodes)
    output logic        isa_aen_next,   // pc10-iii: isa_aen of the next clk
    output logic        isa_ior_n_next, // pc10-iii: isa_ior_n of the next clk (not in a reset's first clk)
    output logic        isa_iow_n_next, // pc10-iii: isa_iow_n of the next clk (not in a reset's first clk)
    output logic        isa_memr_n_next,// pc10-iii: isa_memr_n of the next clk (not in a reset's first clk)
    output logic        isa_memw_n_next,// pc10-iii: isa_memw_n of the next clk (not in a reset's first clk)
    output logic [7:0]  isa_dout,
    input  logic [7:0]  isa_din,
    input  logic        isa_dsel,       // a card drives isa_din
    output logic        isa_memr_n,
    output logic        isa_memw_n,
    output logic        isa_ior_n,
    output logic        isa_iow_n,
    output logic        isa_aen,
    output logic        isa_ale,
    input  logic        isa_ready,
    input  logic [7:2]  isa_irq,
    input  logic [3:1]  isa_drq,
    output logic [3:0]  isa_dack_n,
    output logic        isa_tc,

    // keyboard, speaker, switches
    input  logic [7:0]  kbd_code,
    input  logic        kbd_valid,
    output logic        kbd_busy,
    output logic        speaker,
    input  logic [7:0]  dip_sw1
);

// ------------------------------------------------------------ T-states, status
localparam logic [2:0] TI = 3'd0, T1 = 3'd1, T2 = 3'd2, T3 = 3'd3, TW = 3'd4, T4 = 3'd5;
localparam logic [2:0] ST_INTA = 3'd0, ST_IOR = 3'd1, ST_IOW = 3'd2, ST_HALT = 3'd3,
                       ST_CODE = 3'd4, ST_MEMR = 3'd5, ST_MEMW = 3'd6, ST_PASV = 3'd7;

// ------------------------------------------------------------ address latch
logic [19:0] cpu_addr;
wire  [19:0] cpu_addr_next = cpu_bus_t == T1 ? cpu_ad : cpu_addr;   // its D input
always_ff @(posedge clk)
    cpu_addr <= cpu_addr_next;
wire [7:0] cpu_dout = cpu_ad[7:0];      // write data from T2 on

// ------------------------------------------------------------ 8288 function
// Read commands and INTA: from the CLK falling edge in T1 to the start of T4.
// Write commands: from the falling edge in T2 (write data is on the bus from
// T2). CAL: the exact edges relative to OSC matter for the CGA's wait states.
//
// Timing (pc10-iii, doc/timing.md): one command register per bus status
// instead of cmd_rd/cmd_wr ANDed with the CPU's live bus status, so the
// strobes are a register (and AEN) away from the cards. The same thing: the
// status (latch) only changes when a cycle starts (T1 out of Ti/T4/Tinit) or
// in its T4, and the registers are cleared in any clk whose T-state is not
// T1-Tw, so whenever a command register is set the status is the one it was
// set for (checked in simulation against the original expressions below).
logic cmd_memr, cmd_memw, cmd_ior, cmd_iow, cmd_inta;
wire  in_cycle = cpu_bus_t == T1 || cpu_bus_t == T2 || cpu_bus_t == T3 || cpu_bus_t == TW;
always_ff @(posedge clk) begin
    if (reset || !in_cycle) begin
        cmd_memr <= 1'b0;  cmd_memw <= 1'b0;
        cmd_ior  <= 1'b0;  cmd_iow  <= 1'b0;  cmd_inta <= 1'b0;
    end else if (cpu_fall) begin
        if (cpu_bus_t == T1) begin
            if (cpu_bus_type == ST_CODE || cpu_bus_type == ST_MEMR) cmd_memr <= 1'b1;
            if (cpu_bus_type == ST_IOR)  cmd_ior  <= 1'b1;
            if (cpu_bus_type == ST_INTA) cmd_inta <= 1'b1;
        end
        if (cpu_bus_t == T2) begin
            if (cpu_bus_type == ST_MEMW) cmd_memw <= 1'b1;
            if (cpu_bus_type == ST_IOW)  cmd_iow  <= 1'b1;
        end
    end
end
logic aen;                              // DMA owns the bus
wire  cpu_memr = cmd_memr && !aen;
wire  cpu_memw = cmd_memw && !aen;
wire  cpu_ior  = cmd_ior  && !aen;
wire  cpu_iow  = cmd_iow  && !aen;
wire  inta     = cmd_inta;

`ifndef SYNTHESIS
// the original 8288 function, as a reference for the registers above
logic cmd_rd, cmd_wr;
wire  is_read  = cpu_bus_type == ST_CODE || cpu_bus_type == ST_MEMR ||
                 cpu_bus_type == ST_IOR  || cpu_bus_type == ST_INTA;
wire  is_write = cpu_bus_type == ST_MEMW || cpu_bus_type == ST_IOW;
always_ff @(posedge clk) begin
    if (reset || !in_cycle) begin
        cmd_rd <= 1'b0;
        cmd_wr <= 1'b0;
    end else if (cpu_fall) begin
        if (cpu_bus_t == T1 && is_read)  cmd_rd <= 1'b1;
        if (cpu_bus_t == T2 && is_write) cmd_wr <= 1'b1;
    end
end
always_ff @(posedge clk)
    if (!reset && (
        cpu_memr != (cmd_rd && (cpu_bus_type == ST_CODE || cpu_bus_type == ST_MEMR) && !aen) ||
        cpu_memw != (cmd_wr && cpu_bus_type == ST_MEMW && !aen) ||
        cpu_ior  != (cmd_rd && cpu_bus_type == ST_IOR && !aen) ||
        cpu_iow  != (cmd_wr && cpu_bus_type == ST_IOW && !aen) ||
        inta     != (cmd_rd && cpu_bus_type == ST_INTA)))
        $fatal(1, "xt_board: command registers differ from the 8288 function");
`endif

// ------------------------------------------------------------ DMA: hold logic
logic       hold_request, hold_request_next, hrq_ff1, hrq_ff2, hold_ack, dma_wait;
logic       aen_next, dma_wait_next;    // their D inputs (for the bus address register)
wire        cpu_passive = cpu_s2_s0[1] & cpu_s2_s0[0];       // S1 S0 = 11
always_comb begin
    aen_next      = aen;
    dma_wait_next = dma_wait;
    if (reset) begin
        aen_next      = 1'b0;
        dma_wait_next = 1'b0;
    end else if (cpu_step) begin
        // AEN one CPU clock after HOLDA (hrq_ff1: HRQ with passive status,
        // i.e. the CPU in T3/Tw/T4/Ti, and no LOCK), also in the CPU's T4,
        // and it ends in the clock where the 8237 drops HRQ (enters SI): five
        // clocks for a transfer (S1 S2 S3 SW S4). CAL: MartyPC (HLDA, then S1
        // with AEN on the next clock).
        aen_next      = hold_ack && hold_request_next;
        dma_wait_next = aen;
    end
end
always_ff @(posedge clk) begin
    aen      <= aen_next;
    dma_wait <= dma_wait_next;
    if (reset) begin
        hrq_ff1 <= 1'b0;  hrq_ff2 <= 1'b0;
    end else begin
        if (cpu_step)
            hrq_ff1  <= cpu_passive & cpu_lock_n & hold_request;
        if (cpu_fall)
            hrq_ff2 <= !hold_request ? 1'b0 : hrq_ff2 ? 1'b1 : hrq_ff1;
    end
end
// CAL: PCXT acknowledges on ff1 already (one clock less per refresh)
assign hold_ack = hold_request & (hrq_ff1 | hrq_ff2);
wire   dma_owns = dma_wait & aen;

// ------------------------------------------------------------ I/O decode (board)
logic [19:0] bus_addr;
wire  board_io = !aen && bus_addr[9:8] == 2'b00;
wire  cs_dma   = board_io && bus_addr[7:5] == 3'd0;   // 00-1F
wire  cs_pic   = board_io && bus_addr[7:5] == 3'd1;   // 20-3F
wire  cs_pit   = board_io && bus_addr[7:5] == 3'd2;   // 40-5F
wire  cs_ppi   = board_io && bus_addr[7:5] == 3'd3;   // 60-7F
wire  cs_page  = board_io && bus_addr[7:5] == 3'd4;   // 80-9F
wire  cs_nmi   = board_io && bus_addr[7:5] == 3'd5;   // A0-BF

// ------------------------------------------------------------ 8237
logic [7:0]  dma_dout;
logic        dma_ior_n, dma_iow_n, dma_memr_n, dma_memw_n, dma_eop;
logic        dma_ior_n_next, dma_iow_n_next, dma_memr_n_next, dma_memw_n_next;
logic [15:0] dma_addr, dma_addr_next;
logic [3:0]  dack_n, dack_n_next;
logic        drq0;
logic [7:0]  bus_wdata;                  // data the writing master drives
wire         io_rd_n    = ~cpu_ior & dma_ior_n;
wire         io_wr_n    = ~cpu_iow & dma_iow_n;
wire         mem_rd_n   = ~cpu_memr & dma_memr_n;
wire         mem_wr_n   = ~cpu_memw & dma_memw_n;

KF8237 u_dma (
    .clock                  (clk),
    .cpu_ce_posedge         (cpu_step),
    .cpu_ce_negedge         (cpu_fall),
    .reset                  (reset),
    .chip_select_n          (~cs_dma),
    .ready                  (isa_ready),            // CAL: XT DMA wait state
    .hold_acknowledge       (aen),           // the gated grant (see aen); CAL
    .dma_request            ({isa_drq, drq0}),
    .data_bus_in            (bus_wdata),
    .data_bus_out           (dma_dout),
    .io_read_n_in           (io_rd_n),
    .io_read_n_out          (dma_ior_n),
    .io_read_n_io           (),
    .io_write_n_in          (io_wr_n),
    .io_write_n_out         (dma_iow_n),
    .io_write_n_io          (),
    .end_of_process_n_in    (1'b1),
    .end_of_process_n_out   (dma_eop),
    .address_in             (bus_addr[3:0]),
    .address_out            (dma_addr),
    .address_out_next       (dma_addr_next),    // pc10-iii
    .output_highst_address  (),
    .hold_request           (hold_request),
    .hold_request_next      (hold_request_next),
    .dma_acknowledge        (dack_n),           // a register (pc10-iii)
    .dma_acknowledge_next   (dack_n_next),
    .address_enable         (),
    .address_strobe         (),
    .memory_read_n          (dma_memr_n),
    .memory_write_n         (dma_memw_n),
    .io_read_n_next         (dma_ior_n_next),   // pc10-iii
    .io_write_n_next        (dma_iow_n_next),
    .memory_read_n_next     (dma_memr_n_next),
    .memory_write_n_next    (dma_memw_n_next)
);

// 74LS670 page registers: 81 = ch2, 82 = ch3, 83 = ch1 (and ch0)
logic [3:0] page [4], page_next [4];
always_comb begin
    page_next = page;
    if (reset) begin
        page_next[0] = 4'h0; page_next[1] = 4'h0; page_next[2] = 4'h0; page_next[3] = 4'h0;
    end else if (cs_page && cpu_iow)
        page_next[bus_addr[1:0]] = cpu_dout[3:0];   // = bus_wdata: CPU writes need !aen (pc10-iii)
end
always_ff @(posedge clk) page <= page_next;

// the bus address: the DMA's while it owns the bus, else the CPU's.
// Timing (pc10-iii): a register, loaded with the original expression on the D
// inputs of the registers it is made of (dma_wait, aen, DACK, the page
// registers, the 8237's address, the address latch), so it holds the original
// value in every clk (checked in simulation): the cards, the RAM and the ROM
// decode a register. Originally:
//   wire [3:0] dma_page = !dack_n[2] ? page[1] : !dack_n[3] ? page[2] : page[3];
//   assign bus_addr  = dma_owns && !(&dack_n) ? {dma_page, dma_addr} : cpu_addr;
wire        dma_owns_next = dma_wait_next && aen_next;
wire [3:0]  dma_page_next = !dack_n_next[2] ? page_next[1] : !dack_n_next[3] ? page_next[2] : page_next[3];
wire [19:0] bus_addr_next = dma_owns_next && !(&dack_n_next) ? {dma_page_next, dma_addr_next} : cpu_addr_next;
always_ff @(posedge clk)
    bus_addr <= bus_addr_next;

`ifndef SYNTHESIS
always_ff @(posedge clk)
    if (!reset && cpu_iow && bus_wdata != cpu_dout)
        $fatal(1, "xt_board: CPU I/O write while the DMA drives the data bus");
wire [3:0] dma_page_ref = !dack_n[2] ? page[1] : !dack_n[3] ? page[2] : page[3];
always_ff @(posedge clk)
    if (!reset && bus_addr != (dma_owns && !(&dack_n) ? {dma_page_ref, dma_addr} : cpu_addr))
        $fatal(1, "xt_board: the bus address register differs from the original");
`endif

// ------------------------------------------------------------ 8253
logic [7:0] pit_dout;
logic       out0, out1, out2;
logic [7:0] pb;                          // 8255 port B
logic       pb_io;
wire        pb_drv = !pb_io;

// OUT1 before the BIOS programs counter 1: high (the 8253 leaves it
// undefined). Low would make the mode-2 control word a rising edge, so DRQ0
// would wait, masked, until the BIOS unmasks channel 0; MartyPC's refresh
// (a schedule from the count write, no request before its first terminal
// count) has no such request. CAL: MartyPC.
KF8253 #(.COUNTER_1_OUT_INIT(1'b1)) u_pit (
    .clock          (clk),
    .reset          (reset),
    .chip_select_n  (~cs_pit),
    .read_enable_n  (io_rd_n),
    .write_enable_n (io_wr_n),
    .address        (bus_addr[1:0]),
    .data_bus_in    (bus_wdata),
    .data_bus_out   (pit_dout),
    .counter_0_clock(pit_clk),
    .counter_0_gate (1'b1),
    .counter_0_out  (out0),
    .counter_1_clock(pit_clk),
    .counter_1_gate (1'b1),
    .counter_1_out  (out1),
    .counter_2_clock(pit_clk),
    .counter_2_gate (pb_drv & pb[0]),
    .counter_2_out  (out2)
);

assign speaker = out2 & pb_drv & pb[1];

// DRQ0: a rising OUT1 sets the refresh request, DACK0 clears it (74LS74)
logic out1_d, out1_s;
generate if (DRQ0_SKEW == 0) begin : g_drq0
    assign out1_s = out1;
end else begin : g_drq0_skew
    logic [DRQ0_SKEW*21-1:0] sh;
    always_ff @(posedge clk) sh <= {sh[DRQ0_SKEW*21-2:0], out1};
    assign out1_s = sh[DRQ0_SKEW*21-1];
end endgenerate
always_ff @(posedge clk) begin
    out1_d <= out1_s;
    if (reset) drq0 <= 1'b0;
    else if (!dack_n[0]) drq0 <= 1'b0;
    else if (out1_s && !out1_d) drq0 <= 1'b1;
end

// ------------------------------------------------------------ 8259
logic [7:0] pic_dout;
logic       pic_int;
logic       kbd_irq;

KF8259 u_pic (
    .clock                          (clk),
    .reset                          (reset),
    .chip_select_n                  (~cs_pic),
    .read_enable_n                  (io_rd_n),
    .write_enable_n                 (io_wr_n),
    .address                        (bus_addr[0]),
    .data_bus_in                    (bus_wdata),
    .data_bus_out                   (pic_dout),
    .data_bus_io                    (),
    .cascade_in                     (3'b000),
    .cascade_out                    (),
    .cascade_io                     (),
    .slave_program_n                (1'b1),
    .buffer_enable                  (),
    .slave_program_or_enable_buffer (),
    .interrupt_acknowledge_n        (~inta),
    .interrupt_to_cpu               (pic_int),
    .interrupt_request              ({isa_irq, kbd_irq, out0})
);
assign cpu_intr = pic_int;

// ------------------------------------------------------------ 8255
// 5160: A = keyboard scan code; B = outputs; C = switch nibble (PB3 selects
// SW1 5-8 vs 1-4) in PC0-3, OUT2 in PC5.
logic [7:0] ppi_dout, kbd_data;
logic [7:0] pc_in;
assign pc_in = {1'b0, 1'b0, out2, 1'b0, pb[3] ? dip_sw1[7:4] : dip_sw1[3:0]};

KF8255 u_ppi (
    .clock          (clk),
    .reset          (reset),
    .chip_select_n  (~cs_ppi),
    .read_enable_n  (io_rd_n),
    .write_enable_n (io_wr_n),
    .address        (bus_addr[1:0]),
    .data_bus_in    (bus_wdata),
    .data_bus_out   (ppi_dout),
    .port_a_in      (kbd_data),
    .port_a_out     (),
    .port_a_io      (),
    .port_b_in      (8'h00),
    .port_b_out     (pb),
    .port_b_io      (pb_io),
    .port_c_in      (pc_in),
    .port_c_out     (),
    .port_c_io      ()
);

// ------------------------------------------------------------ NMI mask (A0)
logic nmi_en;
always_ff @(posedge clk)
    if (reset) nmi_en <= 1'b0;
    else if (cs_nmi && cpu_iow) nmi_en <= cpu_dout[7];      // = bus_wdata (pc10-iii)
assign cpu_nmi = 1'b0 & nmi_en;          // no parity / IO channel check yet

// ------------------------------------------------------------ keyboard
// The 5160's keyboard interface: a code arrives (after the time a real
// keyboard needs to send it), raises IRQ1 and sits in port A until PB7
// clears it. PB6 low holds the keyboard clock; a hold of more than ~10 ms
// resets the keyboard, which answers 0xAA. Codes from the glue wait in a
// small FIFO.
logic [7:0] kfifo [16];
logic [3:0] kf_rd, kf_wr;
logic [4:0] kf_n;
logic       kbd_full;
logic [15:0] kbd_delay;                  // cpu clocks until the next code lands
logic [16:0] kbd_hold;                   // cpu clocks PB6 has been low
logic       kbd_selftest;
wire        pb6 = pb_drv ? pb[6] : 1'b1;
wire        pb7 = pb_drv ? pb[7] : 1'b0;
localparam int KBD_SEND  = 4773;         // ~1 ms: 11 bits at ~11 kHz
localparam int KBD_RESET = 47727;        // ~10 ms

assign kbd_busy = kf_n == 5'd16;
assign kbd_irq  = kbd_full;

wire kf_push = kbd_valid && kf_n != 5'd16;
logic kf_pop;
always_comb begin
    kf_pop = 1'b0;
    if (!reset && cpu_step && pb6 && !kbd_full && !pb7 && !kbd_selftest &&
        kf_n != 5'd0 && kbd_delay == 16'd0)
        kf_pop = 1'b1;
end

always_ff @(posedge clk) begin
    if (reset) begin
        kf_rd <= 4'd0;  kf_wr <= 4'd0;  kf_n <= 5'd0;
        kbd_full <= 1'b0;  kbd_data <= 8'h00;
        kbd_delay <= 16'(KBD_SEND);  kbd_hold <= 17'd0;  kbd_selftest <= 1'b0;
    end else begin
        if (kf_push) begin
            kfifo[kf_wr] <= kbd_code;
            kf_wr <= kf_wr + 4'd1;
        end
        if (kf_pop) kf_rd <= kf_rd + 4'd1;
        kf_n <= kf_n + 5'(kf_push) - 5'(kf_pop);

        if (pb7) begin
            kbd_full <= 1'b0;
            kbd_data <= 8'h00;
        end
        if (cpu_step) begin
            if (!pb6) begin
                if (kbd_hold != 17'h1FFFF) kbd_hold <= kbd_hold + 17'd1;
                kbd_delay <= 16'(KBD_SEND);
            end else begin
                if (kbd_hold >= 17'(KBD_RESET)) kbd_selftest <= 1'b1;
                kbd_hold <= 17'd0;
                if (!kbd_full && !pb7 && (kbd_selftest || kf_n != 5'd0)) begin
                    if (kbd_delay != 16'd0)
                        kbd_delay <= kbd_delay - 16'd1;
                    else begin
                        kbd_delay <= 16'(KBD_SEND);
                        kbd_full  <= 1'b1;
                        if (kbd_selftest) begin
                            kbd_selftest <= 1'b0;
                            kbd_data <= 8'hAA;
                        end else
                            kbd_data <= kfifo[kf_rd];
                    end
                end
            end
        end
    end
end

// ------------------------------------------------------------ memory decode
localparam logic [19:0] RAM_TOP = 20'(RAM_KB * 1024);
wire  sel_ram = bus_addr < RAM_TOP;
wire  sel_rom = bus_addr[19:16] == 4'hF;
wire  refresh = !dack_n[0];

// the data a writing master drives: the CPU; in a DMA cycle the side being
// read: the I/O card (I/O-to-memory) or the memory (memory-to-I/O)
logic [7:0] mem_rdata;
always_comb begin
    if (!dma_owns)          bus_wdata = cpu_dout;
    else if (!dma_memr_n)   bus_wdata = mem_rdata;
    else                    bus_wdata = isa_din;
end

// RAM: one request at the start of each read or write strobe, per bus owner:
// a CPU cycle that a DMA transfer held (AEN from its T1 on) gets its strobe
// when AEN falls, right after the 8237's (refresh: DACK0, no RAM access), so
// the two strobes are one low level on the bus and only the owner tells them
// apart
logic       cpu_rd_d, cpu_wr_d, dma_rd_d, dma_wr_d;
logic [7:0] ram_q;
always_ff @(posedge clk) begin
    cpu_rd_d <= cpu_memr;
    cpu_wr_d <= cpu_memw;
    dma_rd_d <= !dma_memr_n;
    dma_wr_d <= !dma_memw_n;
    if (ram_ack && !ram_we) ram_q <= ram_rdata;
end
always_comb begin
    ram_addr  = bus_addr;
    ram_wdata = bus_wdata;
    ram_en    = 1'b0;
    ram_we    = 1'b0;
    // (DACK0 can outlast AEN by part of a clock: the refresh condition is the
    // DMA's only)
    if (sel_ram) begin
        if ((cpu_memw && !cpu_wr_d) || (!refresh && !dma_memw_n && !dma_wr_d)) begin ram_en = 1'b1; ram_we = 1'b1; end
        else if ((cpu_memr && !cpu_rd_d) || (!refresh && !dma_memr_n && !dma_rd_d)) ram_en = 1'b1;
    end
end
assign rom_addr = bus_addr[15:0];
assign mem_rdata = sel_ram ? ram_q : sel_rom ? rom_rdata : isa_din;

// ------------------------------------------------------------ card bus
assign isa_addr   = bus_addr;
assign isa_dout   = bus_wdata;
assign isa_memr_n = mem_rd_n;
assign isa_memw_n = mem_wr_n;
assign isa_ior_n  = io_rd_n;
assign isa_iow_n  = io_wr_n;
assign isa_aen    = aen;
assign isa_addr_next = bus_addr_next;
assign isa_aen_next  = aen_next;

// pc10-iii (timing): the I/O strobes' values in the next clk, from the D
// inputs of the command registers, AEN and the 8237's strobe registers, for
// cards that register their strobe edges (the FDC). Equal to the next clk's
// strobes except in the first clk of a PC reset (the 8237's asynchronous
// clear), where such a card is in reset itself (doc/timing.md 2.11).
logic cmd_ior_next, cmd_iow_next, cmd_memr_next, cmd_memw_next;
always_comb begin
    cmd_ior_next  = cmd_ior;
    cmd_iow_next  = cmd_iow;
    cmd_memr_next = cmd_memr;
    cmd_memw_next = cmd_memw;
    if (reset || !in_cycle) begin
        cmd_ior_next  = 1'b0;
        cmd_iow_next  = 1'b0;
        cmd_memr_next = 1'b0;
        cmd_memw_next = 1'b0;
    end else if (cpu_fall) begin
        if (cpu_bus_t == T1 && cpu_bus_type == ST_IOR) cmd_ior_next = 1'b1;
        if (cpu_bus_t == T2 && cpu_bus_type == ST_IOW) cmd_iow_next = 1'b1;
        if (cpu_bus_t == T1 && (cpu_bus_type == ST_CODE || cpu_bus_type == ST_MEMR)) cmd_memr_next = 1'b1;
        if (cpu_bus_t == T2 && cpu_bus_type == ST_MEMW) cmd_memw_next = 1'b1;
    end
end
assign isa_ior_n_next  = ~(cmd_ior_next  && !aen_next) & dma_ior_n_next;
assign isa_iow_n_next  = ~(cmd_iow_next  && !aen_next) & dma_iow_n_next;
assign isa_memr_n_next = ~(cmd_memr_next && !aen_next) & dma_memr_n_next;
assign isa_memw_n_next = ~(cmd_memw_next && !aen_next) & dma_memw_n_next;
`ifndef SYNTHESIS
logic ior_n_pred, iow_n_pred, memr_n_pred, memw_n_pred;
always_ff @(posedge clk) begin
    ior_n_pred  <= isa_ior_n_next;
    iow_n_pred  <= isa_iow_n_next;
    memr_n_pred <= isa_memr_n_next;
    memw_n_pred <= isa_memw_n_next;
end
always_ff @(posedge clk)
    if (!reset && (ior_n_pred != io_rd_n || iow_n_pred != io_wr_n ||
                   memr_n_pred != mem_rd_n || memw_n_pred != mem_wr_n))
        $fatal(1, "xt_board: next strobes mispredicted");
`endif
assign isa_ale    = cpu_bus_t == T1;
assign isa_dack_n = dack_n;
assign isa_tc     = !dma_eop;              // the 8237's EOP is active low

// ------------------------------------------------------------ CPU read data
// Timing (pc10-iii): the priority chain below decides only which source, and
// the memory and card data (block RAM outputs) go through one 4:1
// multiplexer at the end. The same function as the original:
//   if (inta)                              cpu_din = pic_dout;
//   else if (cpu_ior && cs_dma)            cpu_din = dma_dout;
//   else if (cpu_ior && cs_pic)            cpu_din = pic_dout;
//   else if (cpu_ior && cs_pit)            cpu_din = pit_dout;
//   else if (cpu_ior && cs_ppi)            cpu_din = ppi_dout;
//   else if (cpu_memr && (sel_ram || sel_rom)) cpu_din = mem_rdata;
//   else if (isa_dsel)                     cpu_din = isa_din;
//   else                                   cpu_din = 8'hFF;
localparam logic [1:0] DIN_ROM = 2'd0, DIN_RAM = 2'd1, DIN_ISA = 2'd2, DIN_REG = 2'd3;
logic [1:0] din_src;
logic [7:0] din_reg;
always_comb begin
    din_src = DIN_REG;
    din_reg = 8'hFF;
    if (inta)                              din_reg = pic_dout;
    else if (cpu_ior && cs_dma)            din_reg = dma_dout;
    else if (cpu_ior && cs_pic)            din_reg = pic_dout;
    else if (cpu_ior && cs_pit)            din_reg = pit_dout;
    else if (cpu_ior && cs_ppi)            din_reg = ppi_dout;
    else if (cpu_memr && sel_ram)          din_src = DIN_RAM;
    else if (cpu_memr && sel_rom)          din_src = DIN_ROM;
    else if (isa_dsel)                     din_src = DIN_ISA;
end
always_comb
    case (din_src)
        DIN_ROM: cpu_din = rom_rdata;
        DIN_RAM: cpu_din = ram_q;
        DIN_ISA: cpu_din = isa_din;
        default: cpu_din = din_reg;
    endcase
`ifndef SYNTHESIS
logic [7:0] cpu_din_ref;
always_comb begin
    if (inta)                              cpu_din_ref = pic_dout;
    else if (cpu_ior && cs_dma)            cpu_din_ref = dma_dout;
    else if (cpu_ior && cs_pic)            cpu_din_ref = pic_dout;
    else if (cpu_ior && cs_pit)            cpu_din_ref = pit_dout;
    else if (cpu_ior && cs_ppi)            cpu_din_ref = ppi_dout;
    else if (cpu_memr && (sel_ram || sel_rom)) cpu_din_ref = mem_rdata;
    else if (isa_dsel)                     cpu_din_ref = isa_din;
    else                                   cpu_din_ref = 8'hFF;
end
always_ff @(posedge clk)
    if (!reset && cpu_din !== cpu_din_ref)
        $fatal(1, "xt_board: CPU read data differs from the original multiplexer");
`endif

// ------------------------------------------------------------ READY
// 8284 READY: IOCHRDY and the DMA wait are synchronized on the falling CLK
// edge. The BIU samples READY as it enters T3 and each Tw (bus_t is still T2
// or T3/Tw then) to know whether that state is the last. Every CPU I/O cycle
// gets one wait state: its T3 is never the last.
logic rdy_sync;
always_ff @(posedge clk)
    if (reset) rdy_sync <= 1'b1;
    // the DMA wait: from the CPU clock where AEN rises (S1) to one clock
    // after it falls. CAL: MartyPC (DMA wait states from S1).
    else if (cpu_fall) rdy_sync <= isa_ready & ~(aen | dma_wait);
wire io_cycle = cpu_bus_type == ST_IOR || cpu_bus_type == ST_IOW;
assign cpu_ready = rdy_sync && !(cpu_bus_t == T2 && io_cycle);

endmodule
