// uart8250.sv - the PC10-III's serial port: an INS8250 (U402 of the PC10/20-III
// service manual's parts list) behind the Commodore gate array 5720, which
// selects it at 3F8h-3FFh or 2F8h-2FFh (230h bits 3-2, `com`) and routes its
// interrupt to IRQ4 (3F8h) or IRQ3 (2F8h). doc/ports.md section 2.
//
// The chip (National INS8250 data sheet; behaviour shared with the INS8250A/
// NS16450 where the 8250 does not differ; every assumption is [A] in
// doc/ports.md):
//   0 RBR (read) / THR (write), DLAB = 1: DLL     4 MCR  {LOOP, OUT2, OUT1, RTS, DTR}
//   1 IER {EDSSI, ELSI, ETBEI, ERBFI}, DLAB: DLM   5 LSR  {0, TEMT, THRE, BI, FE, PE, OE, DR}
//   2 IIR (read only; writes are ignored)          6 MSR  {DCD, RI, DSR, CTS, DDCD, TERI, DDSR, DCTS}
//   3 LCR {DLAB, BREAK, STICK, EPS, PEN, STB, WLS}  7 no scratch register (the 8250's: reads FFh)
// - Baud clock: the 8250's XTAL input is 1.8432 MHz, made from clk by an exact
//   fractional accumulator (clk = 315/11 MHz: + 12672 per clk, modulo 196875);
//   the divisor counts 1.8432 MHz ticks into the 16x clock. Writing DLL or DLM
//   restarts the counter; divisor 0 stops it.
// - Transmitter: THR -> TSR at the next 16x tick when the TSR is idle (THRE
//   set), start bit, 5-8 data bits LSB first, parity (odd/even/stick), 1, 1.5
//   (5 bits) or 2 stop bits; BREAK holds SOUT low.
// - Receiver: start bit found on a 16x tick, confirmed at its middle (else a
//   false start), the bits sampled at their middles; RBR, DR and the error bits
//   at the middle of the first stop bit; OE when DR was still set (the old
//   character is lost); BI for an all-zero character (RBR = 00h); after a
//   framing error or a break it waits for SIN to go high before the next start.
// - Interrupts, in this priority: receiver line status (OE/PE/FE/BI, cleared by
//   reading LSR), received data (DR, cleared by reading RBR), THR empty (set
//   when THR moves to the TSR and on every IER write with ETBEI = 1 while THRE
//   is set; cleared by writing THR or by reading IIR while IIR shows it), modem
//   status (the deltas, cleared by reading MSR). The INS8250's flaw (MAME's
//   ins8250.cpp: "the original 8250 pulses the interrupt line if a higher
//   priority interrupt is cleared"): when the highest pending source is cleared
//   while a lower one stays pending, INTR goes low for PULSE clk, so an
//   edge-triggered 8259 sees the next one (the 8250A/16450 keep INTR high).
// - Loopback (MCR bit 4): SOUT high, the TSR's output into the receiver (not
//   BREAK), SIN ignored, the four modem outputs inactive (high) and the modem
//   inputs taken from MCR: DTR -> DSR, RTS -> CTS, OUT1 -> RI, OUT2 -> DCD.
// - The board (IBM's convention, the PC10-III's own wiring not documented):
//   the interrupt reaches the bus only while the OUT2 pin is low (`irq`), so
//   not in loopback.
// - Reset (MR): IER, LCR, MCR, the LSR's error bits and DR, the MSR deltas and
//   both shift registers cleared, THRE/TEMT set, SOUT and the modem outputs
//   high. RBR, THR and the divisor latch keep their contents.
//
// The register reads are side-effect free until the strobe's last clk: the
// clears of RBR/LSR/MSR/IIR reads happen there (the value read is the value in
// that clk, which the board takes).
//
// GPL-3.0-or-later, pc10-iii.

module uart8250 #(
    // 1.8432 MHz = clk x BAUD_NUM / BAUD_DEN (exact for clk = 315/11 MHz)
    parameter int unsigned BAUD_NUM = 32'd12672,
    parameter int unsigned BAUD_DEN = 32'd196875,
    parameter int          PULSE    = 8            // the 8250's INTR pulse, in clk
) (
    input  logic        clk,
    input  logic        reset,

    input  logic [19:0] isa_addr,
    input  logic [19:0] isa_addr_next,
    input  logic        isa_aen_next,
    input  logic        isa_ior_n_next,
    input  logic        isa_iow_n_next,
    input  logic [7:0]  isa_dout,
    output logic [7:0]  isa_din,
    output logic        isa_dsel,
    input  logic        isa_ior_n,
    input  logic        isa_iow_n,
    input  logic        isa_aen,

    input  logic [1:0]  com,            // 230h bits 3-2: 01 2F8h, 10 3F8h, else off
    output logic        irq3,           // to the bus: INTR while OUT2 is low, at 2F8h
    output logic        irq4,           //   ... at 3F8h
    output logic        intr,           // the chip's INTR pin

    output logic        sout,
    input  logic        sin,            // asynchronous
    output logic        rts_n,
    output logic        dtr_n,
    output logic        out1_n,
    output logic        out2_n,
    input  logic        cts_n,          // asynchronous
    input  logic        dsr_n,
    input  logic        dcd_n,
    input  logic        ri_n
);

// ------------------------------------------------------------ the bus
wire [9:0] base = com == 2'b10 ? 10'h3F8 : 10'h2F8;
wire       on   = com == 2'b01 || com == 2'b10;
wire sel    = on && !isa_aen && isa_addr[9:3] == base[9:3];
wire sel_nx = on && !isa_aen_next && isa_addr_next[9:3] == base[9:3] &&
              isa_addr_next[2:0] == isa_addr[2:0];
wire wr_end = sel && !isa_iow_n && !(sel_nx && !isa_iow_n_next);
wire rd_end = sel && !isa_ior_n && !(sel_nx && !isa_ior_n_next);
wire [2:0] ra = isa_addr[2:0];
wire [7:0] wd = isa_dout;

// ------------------------------------------------------------ registers
logic [7:0] rbr = 8'h00, thr = 8'h00, dll = 8'h00, dlm = 8'h00;
logic [3:0] ier = 4'h0;
logic [7:0] lcr = 8'h00;
logic [4:0] mcr = 5'h00;
logic       dr = 1'b0, oe = 1'b0, pe = 1'b0, fe = 1'b0, bi = 1'b0, thre = 1'b1, temt = 1'b1;
logic [3:0] dmsr = 4'h0;                     // DDCD, TERI, DDSR, DCTS
logic       thre_int = 1'b0;                   // the THR-empty interrupt source
wire        dlab = lcr[7];
wire        loop = mcr[4];
wire        wthr;                       // a THR write in this clk

// ------------------------------------------------------------ 1.8432 MHz, 16x clock
logic [17:0] acc = '0;
wire  [17:0] acc_n = acc + BAUD_NUM[17:0];
wire         xtick = acc_n >= BAUD_DEN[17:0];
always_ff @(posedge clk) acc <= xtick ? acc_n - BAUD_DEN[17:0] : acc_n;

logic [15:0] bcnt = '0;
wire  [15:0] divisor = {dlm, dll};
wire         b16 = xtick && divisor != 16'd0 && bcnt + 16'd1 >= divisor;

// ------------------------------------------------------------ modem inputs
logic [1:0] s_sin = 2'b11, s_cts = 2'b11, s_dsr = 2'b11, s_dcd = 2'b11, s_ri = 2'b11;
always_ff @(posedge clk) begin
    s_sin <= {s_sin[0], sin};
    s_cts <= {s_cts[0], cts_n};
    s_dsr <= {s_dsr[0], dsr_n};
    s_dcd <= {s_dcd[0], dcd_n};
    s_ri  <= {s_ri[0],  ri_n};
end
// the MSR's status bits {DCD, RI, DSR, CTS}, active high
wire [3:0] mst = loop ? {mcr[3], mcr[2], mcr[0], mcr[1]} : ~{s_dcd[1], s_ri[1], s_dsr[1], s_cts[1]};
logic [3:0] mst_q = 4'h0;

// ------------------------------------------------------------ frame format
wire [3:0] nbits = 4'd5 + {2'b00, lcr[1:0]};
wire       pen = lcr[3], eps = lcr[4], stick = lcr[5];
// the parity bit for the data d (the word's bits above nbits are 0)
function automatic logic par(input logic [7:0] d);
    par = stick ? !eps : (^d) ^ !eps;   // even: XOR of the bits; odd: its complement
endfunction
function automatic logic [7:0] wmask(input logic [7:0] d);
    wmask = d & (8'hFF >> (4'd8 - nbits));
endfunction

// ------------------------------------------------------------ transmitter
typedef enum logic [2:0] {T_IDLE, T_START, T_DATA, T_PAR, T_STOP} tstate_t;
tstate_t     ts = T_IDLE;
logic [7:0]  tsr = '0;
logic [3:0]  tph = '0;                       // 16x phase within the bit
logic [3:0]  tbit = '0;                      // data bits sent
logic [5:0]  tstop = '0;                     // 16x ticks of stop left
logic        tx_line = 1'b1;                   // the TSR's output (before BREAK)

// ------------------------------------------------------------ receiver
typedef enum logic [2:0] {R_IDLE, R_START, R_DATA, R_PAR, R_STOP, R_MARK} rstate_t;
rstate_t     rs = R_IDLE;
logic [7:0]  rsr = '0;
logic [3:0]  rph = '0;
logic [3:0]  rbit = '0;
logic        rpar = 1'b0;                      // the received parity bit
wire         rx_in = loop ? tx_line : s_sin[1];

// ------------------------------------------------------------ interrupts
wire src_rls  = ier[2] && (oe || pe || fe || bi);
wire src_rda  = ier[0] && dr;
wire src_thre = ier[1] && thre_int;
wire src_ms   = ier[3] && dmsr != 4'h0;
wire [3:0] iir = src_rls ? 4'b0110 : src_rda ? 4'b0100 : src_thre ? 4'b0010 :
                 src_ms ? 4'b0000 : 4'b0001;
wire       pending = !iir[0];
logic [3:0] iir_q = 4'b0001;                      // the last clk's identification
logic [$clog2(PULSE + 1) - 1:0] pulse = '0;

assign wthr = wr_end && ra == 3'd0 && !dlab;
// THR -> TSR at a 16x tick when the TSR is idle or ends its stop bits, unless THR is written now
wire tload = b16 && !thre && !wthr && (ts == T_IDLE || (ts == T_STOP && tstop == 6'd1));
// the stop bits in 16x ticks: 1, 2, or 1.5 for 5-bit characters
wire [5:0] stop_len = !lcr[2] ? 6'd16 : nbits == 4'd5 ? 6'd24 : 6'd32;

// ------------------------------------------------------------ the read port
logic [7:0] rd;
always_comb begin
    case (ra)
        3'd0: rd = dlab ? dll : rbr;
        3'd1: rd = dlab ? dlm : {4'h0, ier};
        3'd2: rd = {4'h0, iir};
        3'd3: rd = lcr;
        3'd4: rd = {3'b000, mcr};
        3'd5: rd = {1'b0, temt, thre, bi, fe, pe, oe, dr};
        3'd6: rd = {mst_q, dmsr};
        default: rd = 8'hFF;            // no scratch register
    endcase
end
assign isa_dsel = sel && !isa_ior_n;
assign isa_din  = isa_dsel ? rd : 8'h00;

// ------------------------------------------------------------ the chip
always_ff @(posedge clk) begin
    if (reset) begin
        ier <= 4'h0;  lcr <= 8'h00;  mcr <= 5'h00;
        dr <= 1'b0;  oe <= 1'b0;  pe <= 1'b0;  fe <= 1'b0;  bi <= 1'b0;
        thre <= 1'b1;  temt <= 1'b1;  thre_int <= 1'b0;
        dmsr <= 4'h0;  mst_q <= mst;
        ts <= T_IDLE;  tx_line <= 1'b1;  tph <= '0;  tbit <= '0;  tstop <= '0;  tsr <= '0;
        rs <= R_IDLE;  rph <= '0;  rbit <= '0;  rsr <= '0;  rpar <= 1'b0;
        bcnt <= '0;
        iir_q <= 4'b0001;  pulse <= '0;
    end else begin
        // ---- baud counter
        if (xtick) bcnt <= (divisor == 16'd0 || bcnt + 16'd1 >= divisor) ? 16'd0 : bcnt + 16'd1;

        // ---- modem status deltas (a read clears them below; a change wins)
        mst_q <= mst;
        if (rd_end && ra == 3'd6) dmsr <= 4'h0;
        if (mst[0] != mst_q[0]) dmsr[0] <= 1'b1;                // DCTS
        if (mst[1] != mst_q[1]) dmsr[1] <= 1'b1;                // DDSR
        if (mst_q[2] && !mst[2]) dmsr[2] <= 1'b1;               // TERI: RI went inactive
        if (mst[3] != mst_q[3]) dmsr[3] <= 1'b1;                // DDCD

        // ---- register writes
        if (wr_end) begin
            case (ra)
                3'd0: if (dlab) begin dll <= wd; bcnt <= '0; end
                      else begin thr <= wd; thre <= 1'b0; temt <= 1'b0; thre_int <= 1'b0; end
                3'd1: if (dlab) begin dlm <= wd; bcnt <= '0; end
                      else begin
                          ier <= wd[3:0];
                          if (wd[1] && thre) thre_int <= 1'b1;
                      end
                3'd3: lcr <= wd;
                3'd4: mcr <= wd[4:0];
                default: ;
            endcase
        end

        // ---- register reads (their clears at the strobe's end)
        if (rd_end) begin
            case (ra)
                3'd0: if (!dlab) dr <= 1'b0;
                3'd2: if (iir == 4'b0010) thre_int <= 1'b0;
                3'd5: begin oe <= 1'b0; pe <= 1'b0; fe <= 1'b0; bi <= 1'b0; end
                default: ;
            endcase
        end

        // ---- transmitter, on the 16x clock: a character from THR when idle or at
        // the end of the stop bits (back to back)
        if (b16) begin
            if (tload) begin
                tsr <= wmask(thr);  thre <= 1'b1;  thre_int <= 1'b1;
                ts <= T_START;  tph <= '0;  tx_line <= 1'b0;
            end else
                case (ts)
                    T_START: begin
                        tph <= tph + 4'd1;
                        if (tph == 4'd15) begin ts <= T_DATA; tbit <= '0; tx_line <= tsr[0]; end
                    end
                    T_DATA: begin
                        tph <= tph + 4'd1;
                        if (tph == 4'd15) begin
                            if (tbit + 4'd1 != nbits) begin
                                tbit <= tbit + 4'd1;
                                tx_line <= tsr[3'(tbit + 4'd1)];
                            end else if (pen) begin
                                ts <= T_PAR;  tx_line <= par(tsr);
                            end else begin
                                ts <= T_STOP;  tx_line <= 1'b1;  tstop <= stop_len;
                            end
                        end
                    end
                    T_PAR: begin
                        tph <= tph + 4'd1;
                        if (tph == 4'd15) begin ts <= T_STOP;  tx_line <= 1'b1;  tstop <= stop_len; end
                    end
                    T_STOP: begin
                        tstop <= tstop - 6'd1;
                        if (tstop == 6'd1) begin
                            ts <= T_IDLE;
                            if (thre && !wthr) temt <= 1'b1;
                        end
                    end
                    default: ts <= T_IDLE;
                endcase
        end

        // ---- receiver, on the 16x clock: the start bit's middle 8 ticks after it
        // was seen (rph counts from the tick that saw it), every later bit 16 ticks on
        if (b16) begin
            case (rs)
                R_IDLE:
                    if (!rx_in) begin rs <= R_START; rph <= 4'd1; end
                R_START: begin
                    rph <= rph + 4'd1;
                    if (rph == 4'd7) begin
                        if (rx_in) rs <= R_IDLE;                 // a false start
                        else begin rs <= R_DATA; rph <= 4'd0; rbit <= '0; rsr <= '0; end
                    end
                end
                R_DATA: begin
                    rph <= rph + 4'd1;
                    if (rph == 4'd15) begin
                        rsr[rbit[2:0]] <= rx_in;
                        rbit <= rbit + 4'd1;
                        if (rbit + 4'd1 == nbits) rs <= pen ? R_PAR : R_STOP;
                    end
                end
                R_PAR: begin
                    rph <= rph + 4'd1;
                    if (rph == 4'd15) begin rpar <= rx_in; rs <= R_STOP; end
                end
                R_STOP: begin
                    rph <= rph + 4'd1;
                    if (rph == 4'd15) begin
                        rbr <= rsr;
                        // an overrun unless RBR was read in this clk; an OE that LSR showed in this clk is cleared
                        oe  <= (oe && !(rd_end && ra == 3'd5)) || (dr && !(rd_end && ra == 3'd0 && !dlab));
                        dr  <= 1'b1;
                        if (pen && rpar != par(rsr)) pe <= 1'b1;
                        if (!rx_in) fe <= 1'b1;
                        if (!rx_in && rsr == 8'h00 && !(pen && rpar)) bi <= 1'b1;
                        rs <= rx_in ? R_IDLE : R_MARK;
                    end
                end
                R_MARK:
                    if (rx_in) rs <= R_IDLE;
                default: rs <= R_IDLE;
            endcase
        end

        // ---- the INS8250's INTR pulse
        iir_q <= iir;
        if (pulse != '0) pulse <= pulse - 1'b1;
        else if (!iir_q[0] && pending && iir_q != iir && iir_q[2:1] > iir[2:1]) pulse <= PULSE[$bits(pulse) - 1:0];
    end
end

assign intr   = pending && pulse == '0;
assign sout   = loop || (tx_line && !lcr[6]);
assign rts_n  = loop || !mcr[1];
assign dtr_n  = loop || !mcr[0];
assign out1_n = loop || !mcr[2];
assign out2_n = loop || !mcr[3];
assign irq4   = intr && !out2_n && com == 2'b10;
assign irq3   = intr && !out2_n && com == 2'b01;

endmodule
