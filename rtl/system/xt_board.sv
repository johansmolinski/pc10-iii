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
    parameter int RAM_KB = 640
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
always_ff @(posedge clk)
    if (cpu_bus_t == T1) cpu_addr <= cpu_ad;
wire [7:0] cpu_dout = cpu_ad[7:0];      // write data from T2 on

// ------------------------------------------------------------ 8288 function
// Read commands and INTA: from the CLK falling edge in T1 to the start of T4.
// Write commands: from the falling edge in T2 (write data is on the bus from
// T2). CAL: the exact edges relative to OSC matter for the CGA's wait states.
logic cmd_rd, cmd_wr;
wire  in_cycle = cpu_bus_t == T1 || cpu_bus_t == T2 || cpu_bus_t == T3 || cpu_bus_t == TW;
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
logic aen;                              // DMA owns the bus
wire  cpu_memr = cmd_rd && (cpu_bus_type == ST_CODE || cpu_bus_type == ST_MEMR) && !aen;
wire  cpu_memw = cmd_wr && cpu_bus_type == ST_MEMW && !aen;
wire  cpu_ior  = cmd_rd && cpu_bus_type == ST_IOR && !aen;
wire  cpu_iow  = cmd_wr && cpu_bus_type == ST_IOW && !aen;
wire  inta     = cmd_rd && cpu_bus_type == ST_INTA;

// ------------------------------------------------------------ DMA: hold logic
logic       hold_request, hrq_ff1, hrq_ff2, hold_ack, dma_wait;
wire        cpu_passive = cpu_s2_s0[1] & cpu_s2_s0[0];       // S1 S0 = 11
always_ff @(posedge clk) begin
    if (reset) begin
        hrq_ff1 <= 1'b0;  hrq_ff2 <= 1'b0;  aen <= 1'b0;  dma_wait <= 1'b0;
    end else begin
        if (cpu_step) begin
            hrq_ff1  <= cpu_passive & cpu_lock_n & hold_request;
            // the DMA takes the bus only when the CPU is not inside a
            // transfer: at its T4 or with an idle bus (the status pins
            // go passive in T3 already). CAL: against MartyPC's HOLDA.
            aen      <= hold_ack && (aen || cpu_bus_t == T4 || cpu_bus_t == TI);
            dma_wait <= aen;
        end
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
logic [15:0] dma_addr;
logic [3:0]  dack_n;
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
    .output_highst_address  (),
    .hold_request           (hold_request),
    .dma_acknowledge        (dack_n),
    .address_enable         (),
    .address_strobe         (),
    .memory_read_n          (dma_memr_n),
    .memory_write_n         (dma_memw_n)
);

// 74LS670 page registers: 81 = ch2, 82 = ch3, 83 = ch1 (and ch0)
logic [3:0] page [4];
always_ff @(posedge clk) begin
    if (reset) begin
        page[0] <= 4'h0; page[1] <= 4'h0; page[2] <= 4'h0; page[3] <= 4'h0;
    end else if (cs_page && cpu_iow)
        page[bus_addr[1:0]] <= bus_wdata[3:0];
end
wire [3:0] dma_page = !dack_n[2] ? page[1] : !dack_n[3] ? page[2] : page[3];

// the bus address: the DMA's while it owns the bus, else the CPU's
assign bus_addr  = dma_owns && !(&dack_n) ? {dma_page, dma_addr} : cpu_addr;

// ------------------------------------------------------------ 8253
logic [7:0] pit_dout;
logic       out0, out1, out2;
logic [7:0] pb;                          // 8255 port B
logic       pb_io;
wire        pb_drv = !pb_io;

KF8253 u_pit (
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
logic out1_d;
always_ff @(posedge clk) begin
    out1_d <= out1;
    if (reset) drq0 <= 1'b0;
    else if (!dack_n[0]) drq0 <= 1'b0;
    else if (out1 && !out1_d) drq0 <= 1'b1;
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
    else if (cs_nmi && cpu_iow) nmi_en <= bus_wdata[7];
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

// RAM: one request at the start of each read or write strobe
logic       mem_rd_d, mem_wr_d;
logic [7:0] ram_q;
always_ff @(posedge clk) begin
    mem_rd_d <= !mem_rd_n;
    mem_wr_d <= !mem_wr_n;
    if (ram_ack && !ram_we) ram_q <= ram_rdata;
end
always_comb begin
    ram_addr  = bus_addr;
    ram_wdata = bus_wdata;
    ram_en    = 1'b0;
    ram_we    = 1'b0;
    if (sel_ram && !refresh) begin
        if (!mem_wr_n && !mem_wr_d) begin ram_en = 1'b1; ram_we = 1'b1; end
        else if (!mem_rd_n && !mem_rd_d) ram_en = 1'b1;
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
assign isa_ale    = cpu_bus_t == T1;
assign isa_dack_n = dack_n;
assign isa_tc     = !dma_eop;              // the 8237's EOP is active low

// ------------------------------------------------------------ CPU read data
always_comb begin
    if (inta)                              cpu_din = pic_dout;
    else if (cpu_ior && cs_dma)            cpu_din = dma_dout;
    else if (cpu_ior && cs_pic)            cpu_din = pic_dout;
    else if (cpu_ior && cs_pit)            cpu_din = pit_dout;
    else if (cpu_ior && cs_ppi)            cpu_din = ppi_dout;
    else if (cpu_memr && (sel_ram || sel_rom)) cpu_din = mem_rdata;
    else if (isa_dsel)                     cpu_din = isa_din;
    else                                   cpu_din = 8'hFF;
end

// ------------------------------------------------------------ READY
// 8284 READY: IOCHRDY and the DMA wait are synchronized on the falling CLK
// edge. The BIU samples READY as it enters T3 and each Tw (bus_t is still T2
// or T3/Tw then) to know whether that state is the last. Every CPU I/O cycle
// gets one wait state: its T3 is never the last.
logic rdy_sync;
always_ff @(posedge clk)
    if (reset) rdy_sync <= 1'b1;
    else if (cpu_fall) rdy_sync <= isa_ready & ~dma_wait;
wire io_cycle = cpu_bus_type == ST_IOR || cpu_bus_type == ST_IOW;
assign cpu_ready = rdy_sync && !(cpu_bus_t == T2 && io_cycle);

endmodule
