// xtide_card.sv - an XTIDE-compatible 8-bit ISA hard disk card on the card
// bus (doc/architecture.md section 3, doc/hdc.md): the option ROM socket for
// the XTIDE Universal BIOS, the register decoder of three XTIDE variants, the
// 8/16-bit data latch, and two ATA drives (ata_dev.sv) whose media are disk
// images behind the sector port.
//
// Register maps (port offsets from IO_BASE, default 300h):
//
//   variant 0, XT-CF / Lo-tech 8-bit IDE (XUB device types 7-9), 32 ports:
//     command block register n at 2n, control block register n at 10h + 2n
//     (alternate status / device control at 1Ch); A0 is not decoded except
//     at 01h: the high byte of the data register (a latch) in 16-bit mode,
//     the data register in 8-bit mode (SET FEATURES 01h). A 16-bit read is
//     IN AX,DX at 00h/01h; a 16-bit write is OUT DX,AX: 00h latches the low
//     byte, 01h writes the word.
//   variant 1, XTIDE rev 1 (type 4), 16 ports: command block 0-7, the data
//     latch at 08h, control block 09h-0Fh (device control at 0Eh). Reads of
//     00h take the word and latch its high byte for 08h; writes of 08h
//     latch the high byte, 00h writes the word.
//   variant 2, XTIDE rev 2 / rev 1 "Chuck mod" (type 5): rev 1 with A0 and A3
//     swapped, so the data low/high pair is 00h/01h (IN AX,DX) and device
//     control is at 07h.
// In 8-bit mode the data register (00h) moves one byte per access in every
// variant.
//
// The option ROM: 16 KB at ROM_BASE (C8000h), owned by the glue like the
// BIOS ROM (rom_addr / rom_rdata, 1 clk latency). The card does not answer
// at all while `enable` is low.
//
// IRQ: none by default (XUB's XT builds poll); IRQ = 2..7 wires INTRQ there.
// The card never inserts wait states.
//
// GPL-3.0-or-later, pc10-iii.

module xtide_card #(
    parameter logic [9:0]  IO_BASE  = 10'h300,
    parameter logic [19:0] ROM_BASE = 20'hC8000,   // 16 KB aligned
    parameter int          IRQ      = 0,
    parameter int          CMD_US   = 5,
    parameter int          BLK_US   = 2,
    parameter int          RESET_US = 1000
) (
    input  logic        clk,
    input  logic        reset,          // RESET DRV

    // card bus (doc/architecture.md section 3)
    input  logic [19:0] isa_addr,
    input  logic [7:0]  isa_dout,
    output logic [7:0]  isa_din,
    output logic        isa_dsel,
    input  logic        isa_memr_n,
    input  logic        isa_ior_n,
    input  logic        isa_iow_n,
    input  logic        isa_aen,
    output logic        isa_ready,
    output logic [7:2]  isa_irq,

    // configuration
    input  logic        enable,         // the card is in a slot
    input  logic [1:0]  variant,        // 0 XT-CF / Lo-tech, 1 XTIDE rev 1, 2 XTIDE rev 2

    // option ROM (the glue's 16 KB block RAM)
    output logic [13:0] rom_addr,
    input  logic [7:0]  rom_rdata,

    // the drives: 0 = master, 1 = slave
    input  logic [1:0]       hd_present,
    input  logic [1:0][27:0] hd_sectors,
    input  logic [1:0][15:0] hd_cyls,
    input  logic [1:0][4:0]  hd_heads,
    input  logic [1:0][5:0]  hd_spt,
    output logic             hd_active,

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

// ------------------------------------------------------------ decode
typedef enum logic [1:0] { K_TF, K_LO, K_HI } kind_t;

wire [4:0] o      = isa_addr[4:0];
wire       io_win = variant == 2'd0 ? isa_addr[9:5] == IO_BASE[9:5] : isa_addr[9:4] == IO_BASE[9:4];
wire       sel_io = enable && !isa_aen && io_win && variant != 2'd3;
wire [3:0] r1     = variant == 2'd2 ? {o[0], o[2:1], o[3]} : o[3:0];   // rev 2: A0 <-> A3

kind_t      d_kind;
logic       d_cs1;
logic [2:0] d_reg;
always_comb begin
    if (variant == 2'd0) begin
        d_kind = o[4:1] == 4'd0 ? (o[0] ? K_HI : K_LO) : K_TF;
        d_cs1  = o[4];
        d_reg  = o[3:1];
    end else begin
        d_kind = r1[2:0] == 3'd0 ? (r1[3] ? K_HI : K_LO) : K_TF;
        d_cs1  = r1[3];
        d_reg  = r1[2:0];
    end
end

// ------------------------------------------------------------ bus strobes
logic       ior_d, iow_d;
logic [7:0] wdat_q;
wire        ior_fall = !isa_ior_n && ior_d;
wire        iow_fall = !isa_iow_n && iow_d;
wire        iow_rise = isa_iow_n && !iow_d;
wire        ior_rise = isa_ior_n && !ior_d;

always_ff @(posedge clk) begin
    ior_d <= isa_ior_n;
    iow_d <= isa_iow_n;
    if (!isa_iow_n) wdat_q <= isa_dout;     // the last value seen during the strobe
end

// option ROM window (memory decoders also answer DMA cycles)
wire       rom_sel = enable && !isa_memr_n && isa_addr[19:14] == ROM_BASE[19:14];

// ------------------------------------------------------------ the drives
logic        tf_rd, tf_wr, tf_cs1, tf_drive;
logic [2:0]  tf_reg;
logic [7:0]  tf_rdata;
logic        dat_rd, dat_wr, dat_word, mode8, intrq;
logic [15:0] dat_wdata, dat_q;

// write cycle: decoded at the strobe's start, done at its end
logic       w_cyc;
kind_t      w_kind;
logic       w_cs1;
logic [2:0] w_reg;
// read cycle
logic       r_cyc, r_drv;
// the data latches (separate for reads and writes, as on the XTIDE)
logic [7:0] lat_rd, lat_wr;

assign tf_cs1 = iow_rise ? w_cs1 : d_cs1;
assign tf_reg = iow_rise ? w_reg : d_reg;
assign tf_rd  = ior_fall && sel_io && d_kind == K_TF;
assign tf_wr  = iow_rise && w_cyc && w_kind == K_TF;

// 8-bit transfers: the data register at 00h (and at 01h on the XT-CF)
wire rd_lo    = ior_fall && sel_io && d_kind == K_LO;
wire rd_hi    = ior_fall && sel_io && d_kind == K_HI;
wire rd_hi8   = rd_hi && variant == 2'd0 && mode8;
wire wr_lo    = iow_rise && w_cyc && w_kind == K_LO;
wire wr_hi    = iow_rise && w_cyc && w_kind == K_HI;

always_comb begin
    dat_rd    = rd_lo || rd_hi8;
    dat_word  = !mode8;
    dat_wr    = 1'b0;
    dat_wdata = {8'h00, wdat_q};
    if (mode8) begin
        dat_wr = wr_lo || (wr_hi && variant == 2'd0);
    end else if (variant == 2'd0) begin
        dat_wr    = wr_hi;                      // OUT DX,AX: low at 00h, then high at 01h
        dat_wdata = {wdat_q, lat_wr};
    end else begin
        dat_wr    = wr_lo;                      // XTIDE: high to the latch first, then low
        dat_wdata = {lat_wr, wdat_q};
    end
end

always_ff @(posedge clk) begin
    if (reset) begin
        w_cyc <= 1'b0;
        r_cyc <= 1'b0;
        r_drv <= 1'b0;
    end else begin
        if (iow_fall) begin
            w_cyc  <= sel_io;
            w_kind <= d_kind;
            w_cs1  <= d_cs1;
            w_reg  <= d_reg;
        end
        if (iow_rise) w_cyc <= 1'b0;
        if (variant == 2'd0 ? wr_lo : wr_hi) lat_wr <= wdat_q;

        if (ior_fall) begin
            r_cyc <= sel_io;
            r_drv <= 1'b1;
            case (d_kind)
                K_TF: begin isa_din <= tf_rdata; r_drv <= tf_drive; end
                K_LO: begin isa_din <= dat_q[7:0]; if (!mode8) lat_rd <= dat_q[15:8]; end
                K_HI: isa_din <= rd_hi8 ? dat_q[7:0] : lat_rd;
                default: ;
            endcase
        end
        if (ior_rise) r_cyc <= 1'b0;
        if (rom_sel) isa_din <= rom_rdata;
    end
end

// ------------------------------------------------------------ option ROM
assign rom_addr = isa_addr[13:0];

assign isa_dsel  = (r_cyc && r_drv && !isa_ior_n) || rom_sel;
assign isa_ready = 1'b1;
always_comb begin
    isa_irq = 6'b000000;
    if (IRQ >= 2 && IRQ <= 7) isa_irq[IRQ] = intrq && enable;
end

ata_dev #(
    .CMD_US   (CMD_US),
    .BLK_US   (BLK_US),
    .RESET_US (RESET_US)
) u_ata (
    .clk         (clk),
    .reset       (reset),
    .tf_rd       (tf_rd),
    .tf_wr       (tf_wr),
    .tf_cs1      (tf_cs1),
    .tf_reg      (tf_reg),
    .tf_wdata    (wdat_q),
    .tf_rdata    (tf_rdata),
    .tf_drive    (tf_drive),
    .dat_rd      (dat_rd),
    .dat_wr      (dat_wr),
    .dat_word    (dat_word),
    .dat_wdata   (dat_wdata),
    .dat_q       (dat_q),
    .mode8       (mode8),
    .intrq       (intrq),
    .hd_present  (hd_present),
    .hd_sectors  (hd_sectors),
    .hd_cyls     (hd_cyls),
    .hd_heads    (hd_heads),
    .hd_spt      (hd_spt),
    .active      (hd_active),
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
