// msm6242.sv - the PC10-III's real-time clock: an OKI MSM6242B (U401, sheet
// 9-4 of the PC10/20-III service manual) at I/O 2C0h-2CFh, doc/rtc.md.
//
// The chip: 16 nibble registers, A3-A0 = SA3-SA0, D3-D0 on the board's data
// bus, CS0' from the Commodore gate array 5720 (U602), which decodes 2C0h-2CFh
// with AEN low while 230h bit 6 is set (`enable`); CS1 and ALE are tied to the
// battery-backed supply, STD.P only to a 10K pull-up (no interrupt). Reads
// drive D7-D4 as 1 (they float on the board: [A], doc/rtc.md section 3).
//
//   0 S1   1 S10  2 MI1  3 MI10  4 H1  5 H10 (bit 2 PM/AM)  6 D1  7 D10
//   8 MO1  9 MO10 A Y1   B Y10   C W   D CD {30s ADJ, IRQ FLAG, BUSY, HOLD}
//   E CE {t1, t0, ITRPT/STND, MASK}    F CF {TEST, 24/12, STOP, REST}
//
// The model (OKI FEDL6242B-02, Epson's compatible RTC-72421 manual for what
// OKI leaves open; every assumption is [A] in doc/rtc.md section 4):
// - 32.768 kHz from clk by an exact fractional accumulator (clk = 315/11 MHz:
//   + 11 x 32768 per clk, modulo 315,000,000), a 15-bit divider; the 1 Hz
//   carry steps the BCD counters (seconds .. years, the weekday with the day).
//   REST clears the divider from the 1/256 s stage up, STOP stops it from the
//   8192 Hz stage up; TEST clocks the seconds at 8192 Hz [A] (OKI: 5.4 kHz).
// - HOLD = 1 holds the 1 Hz carry; one held carry is applied when HOLD goes
//   back to 0. BUSY is set when an increment executes and is cleared only by
//   a 16.384 kHz sample with HOLD = 0 once the increment window (183 us [A],
//   Epson: 190 us max) is over; with HOLD = 1 it keeps its value.
// - 30 s ADJ: 122 us after the write [A] the seconds go to 00, with a minute
//   carry from 30 s on; the divider is cleared from the 1/256 s stage up.
// - 12/24 h (CF bit 2, writable only while REST = 1), PM in H10 bit 2 (reads
//   0 in 24 h mode), 12-hour counting 12, 1 .. 11; leap years: year mod 4.
// - STD.P/IRQ FLAG: events 1/64 s, 1 s, 1 min, 1 h (t1 t0), MASK, interrupt
//   (until a 0 is written) or standard pulse (7.8125 ms) mode.
// - No reset: the chip is battery backed and keeps time across PC resets; its
//   power-up state is the FPGA's initial values (01.01.1980 00:00:00, 24 h).
//
// The MEGA65's battery RTC (doc/rtc.md section 5):
// - seed: M2M's main_rtc_i (MiSTer's 65-bit format, BCD, years since 2000,
//   bit 64 a toggle on every new value from the I2C RTC). The chip takes a new
//   value (valid BCD, stable for 8 clk) unless HOLD is set (it waits) or the PC
//   has set the clock since power-up (it ignores it). Years: PC10 = (M2M + 20)
//   mod 100 (the BIOS counts from 1980), the weekday M2M 0 = Monday -> W 1.
// - write-back: `clk_set` pulses for one clk when the PC has set the clock (a
//   write to S1..W, or a 30 s adjust) and HOLD, STOP and ADJ are all clear
//   again; `now` is the clock, live, in M2M's register order (hundredths,
//   seconds, minutes, hours (24 h), day, month, year since 2000 = (PC10 + 80)
//   mod 100, weekday 0 = Monday), for the glue to copy into the MEGA65's RTC.
//
// GPL-3.0-or-later, pc10-iii.

module msm6242 #(
    // 32.768 kHz = clk x OSC_NUM / OSC_DEN (exact for clk = 315/11 MHz)
    parameter int unsigned OSC_NUM = 32'd360448,       // 11 x 32768
    parameter int unsigned OSC_DEN = 32'd315000000
) (
    input  logic        clk,

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

    input  logic        enable,         // 230h bit 6

    input  logic [64:0] seed,           // M2M main_rtc_i
    output logic        clk_set,        // one clk: the PC has set the clock
    output logic [63:0] now             // the clock, M2M's internal register order
);

// ------------------------------------------------------------ the bus
wire sel    = enable && !isa_aen && isa_addr[9:4] == 6'h2C;
wire sel_nx = enable && !isa_aen_next && isa_addr_next[9:4] == 6'h2C &&
              isa_addr_next[3:0] == isa_addr[3:0];
// a write acts in the strobe's last clk (the WR' rising edge)
wire wr_end = sel && !isa_iow_n && !(sel_nx && !isa_iow_n_next);
wire [3:0] ra = isa_addr[3:0];
wire [3:0] wd = isa_dout[3:0];

// ------------------------------------------------------------ registers
typedef struct packed {
    logic [3:0] s1;   logic [2:0] s10;
    logic [3:0] mi1;  logic [2:0] mi10;
    logic [3:0] h1;   logic [1:0] h10;  logic pm;
    logic [3:0] d1;   logic [1:0] d10;
    logic [3:0] mo1;  logic       mo10;
    logic [3:0] y1;   logic [3:0] y10;
    logic [2:0] w;
} tm_t;

tm_t  t = '{s1: 4'd0, s10: 3'd0, mi1: 4'd0, mi10: 3'd0, h1: 4'd0, h10: 2'd0, pm: 1'b0,
            d1: 4'd1, d10: 2'd0, mo1: 4'd1, mo10: 1'b0, y1: 4'd0, y10: 4'd0, w: 3'd2};
logic hold = 1'b0, irq = 1'b0, adj = 1'b0;
logic [3:0] ce = 4'h0;                   // t1, t0, ITRPT/STND, MASK
logic rest = 1'b0, stop = 1'b0, h24 = 1'b1, test = 1'b0;
logic busy = 1'b0;                       // the BUSY status bit
logic pend = 1'b0;                       // a 1 Hz carry held by HOLD

// ------------------------------------------------------------ 32.768 kHz
logic [29:0] acc = '0;
wire  [29:0] acc_n = acc + OSC_NUM[29:0];
wire         tick  = acc_n >= OSC_DEN[29:0];
always_ff @(posedge clk) acc <= tick ? acc_n - OSC_DEN[29:0] : acc_n;

logic [14:0] div = '0;
logic        half = 1'b0;                // 16.384 kHz phase
logic [2:0]  busy_cnt = '0;              // the increment window, in ticks
logic [2:0]  adj_cnt = '0;
logic [8:0]  irq_cnt = '0;               // standard pulse: 256 ticks = 7.8125 ms

// the divider's next value (only at a tick)
logic [14:0] div_n;
always_comb begin
    div_n = div;
    div_n[1:0] = div[1:0] + 2'd1;
    if (div[1:0] == 2'd3 && !stop) div_n[14:2] = div[14:2] + 13'd1;
    if (rest) div_n[14:7] = '0;
end
wire c1hz   = tick && !test && !stop && !rest && div == 15'h7FFF;
wire ctest  = tick && test && div[1:0] == 2'd3;
wire e64    = tick && div[8] && !div_n[8] && !rest;      // carry out of the 1/128 s stage

// ------------------------------------------------------------ counting
function automatic logic leap(input logic [3:0] y10, input logic [3:0] y1);
    // binary year mod 4 == 0
    leap = y10[0] ? (y1 == 4'd2 || y1 == 4'd6) : (y1 == 4'd0 || y1 == 4'd4 || y1 == 4'd8);
endfunction

function automatic logic [4:0] mlen(input logic mo10, input logic [3:0] mo1, input logic lp);
    logic [4:0] m;
    m = mo10 ? 5'd10 + {1'b0, mo1} : {1'b0, mo1};
    case (m)
        5'd2:                     mlen = lp ? 5'd29 : 5'd28;
        5'd4, 5'd6, 5'd9, 5'd11:  mlen = 5'd30;
        default:                  mlen = 5'd31;
    endcase
endfunction

typedef struct packed { tm_t t; logic cm; logic ch; } inc_t;   // + minute, hour carry

// one step from the seconds (from_min = 0) or from the minutes (the 30 s adjust)
function automatic inc_t step(input tm_t a, input logic from_min, input logic m24);
    inc_t r;
    logic c;
    logic [5:0] day;
    r.t = a;  r.cm = 1'b0;  r.ch = 1'b0;
    c = from_min;
    if (!from_min) begin
        if (a.s10 == 3'd5 && a.s1 == 4'd9) begin r.t.s10 = 3'd0; r.t.s1 = 4'd0; c = 1'b1; end
        else if (a.s1 == 4'd9) begin r.t.s1 = 4'd0; r.t.s10 = a.s10 + 3'd1; end
        else r.t.s1 = a.s1 + 4'd1;
    end
    r.cm = c;
    if (c) begin
        c = 1'b0;
        if (a.mi10 == 3'd5 && a.mi1 == 4'd9) begin r.t.mi10 = 3'd0; r.t.mi1 = 4'd0; c = 1'b1; end
        else if (a.mi1 == 4'd9) begin r.t.mi1 = 4'd0; r.t.mi10 = a.mi10 + 3'd1; end
        else r.t.mi1 = a.mi1 + 4'd1;
    end
    r.ch = c;
    if (c) begin
        c = 1'b0;
        if (m24) begin
            if (a.h10 == 2'd2 && a.h1 == 4'd3) begin r.t.h10 = 2'd0; r.t.h1 = 4'd0; c = 1'b1; end
            else if (a.h1 == 4'd9) begin r.t.h1 = 4'd0; r.t.h10 = a.h10 + 2'd1; end
            else r.t.h1 = a.h1 + 4'd1;
        end else begin
            // 12, 1 .. 11; 11 -> 12 flips PM/AM, 11 PM -> 12 AM is the day's carry
            if (a.h10[0] && a.h1 == 4'd1) begin
                r.t.h1 = 4'd2;  r.t.pm = !a.pm;  c = a.pm;
            end else if (a.h10[0] && a.h1 == 4'd2) begin
                r.t.h10[0] = 1'b0;  r.t.h1 = 4'd1;
            end else if (a.h1 == 4'd9) begin
                r.t.h1 = 4'd0;  r.t.h10[0] = 1'b1;
            end else r.t.h1 = a.h1 + 4'd1;
        end
    end
    if (c) begin
        r.t.w = (a.w >= 3'd6) ? 3'd0 : a.w + 3'd1;
        c = 1'b0;
        day = {2'b00, a.d10} * 6'd10 + {2'b00, a.d1};
        if (day >= {1'b0, mlen(a.mo10, a.mo1, leap(a.y10, a.y1))}) begin
            r.t.d10 = 2'd0;  r.t.d1 = 4'd1;  c = 1'b1;
        end else if (a.d1 == 4'd9) begin r.t.d1 = 4'd0; r.t.d10 = a.d10 + 2'd1; end
        else r.t.d1 = a.d1 + 4'd1;
    end
    if (c) begin
        c = 1'b0;
        if (a.mo10 && a.mo1 == 4'd2) begin r.t.mo10 = 1'b0; r.t.mo1 = 4'd1; c = 1'b1; end
        else if (a.mo1 == 4'd9) begin r.t.mo1 = 4'd0; r.t.mo10 = 1'b1; end
        else r.t.mo1 = a.mo1 + 4'd1;
    end
    if (c) begin
        if (a.y1 == 4'd9) begin
            r.t.y1 = 4'd0;
            r.t.y10 = (a.y10 == 4'd9) ? 4'd0 : a.y10 + 4'd1;
        end else r.t.y1 = a.y1 + 4'd1;
    end
    return r;
endfunction

// ------------------------------------------------------------ the seed
function automatic logic bcd_ok(input logic [7:0] v, input logic [7:0] lo, input logic [7:0] hi);
    bcd_ok = v[3:0] <= 4'd9 && v[7:4] <= 4'd9 && v >= lo && v <= hi;
endfunction

wire seed_ok = bcd_ok(seed[7:0], 8'h00, 8'h59) && bcd_ok(seed[15:8], 8'h00, 8'h59) &&
               bcd_ok(seed[23:16], 8'h00, 8'h23) && bcd_ok(seed[31:24], 8'h01, 8'h31) &&
               bcd_ok(seed[39:32], 8'h01, 8'h12) && bcd_ok(seed[47:40], 8'h00, 8'h99);

logic [63:0] seed_q = '0;
logic [3:0]  seed_stable = '0;
logic        seed_tog = 1'b0;            // the toggle last taken
logic        owned = 1'b0;               // the PC has set the clock since power-up
always_ff @(posedge clk) begin
    seed_q <= seed[63:0];
    if (seed[63:0] != seed_q) seed_stable <= '0;
    else if (seed_stable != 4'hF) seed_stable <= seed_stable + 4'd1;
end
wire seed_new  = seed[64] != seed_tog && seed[63:0] == seed_q && seed_stable >= 4'd8;
wire seed_load = seed_new && !owned && !hold && seed_ok;

// the seed in the chip's form: hours in the current 12/24 h mode
tm_t sv;
always_comb begin
    logic [4:0] hb, h12;
    h12 = 5'd0;
    sv.s1 = seed[3:0];    sv.s10 = seed[6:4];
    sv.mi1 = seed[11:8];  sv.mi10 = seed[14:12];
    hb = {3'd0, seed[21:20]} * 5'd10 + {1'b0, seed[19:16]};
    if (h24) begin
        sv.h1 = seed[19:16];  sv.h10 = seed[21:20];  sv.pm = 1'b0;
    end else begin
        h12 = (hb == 5'd0) ? 5'd12 : (hb > 5'd12) ? hb - 5'd12 : hb;
        sv.pm  = hb >= 5'd12;
        sv.h10 = {1'b0, h12 >= 5'd10};
        sv.h1  = (h12 >= 5'd10) ? h12[3:0] - 4'd10 : h12[3:0];
    end
    sv.d1 = seed[27:24];   sv.d10 = seed[29:28];
    sv.mo1 = seed[35:32];  sv.mo10 = seed[36];
    sv.y1 = seed[43:40];
    sv.y10 = (seed[47:44] >= 4'd8) ? seed[47:44] - 4'd8 : seed[47:44] + 4'd2;   // + 20 years
    sv.w  = (seed[50:48] >= 3'd6) ? 3'd0 : seed[50:48] + 3'd1;                  // Monday = 0 -> 1
end

// ------------------------------------------------------------ the clock
wire  inc_1hz = (c1hz || ctest) && !hold;          // an executed 1 Hz step
wire  wr_cd   = wr_end && ra == 4'hD;
wire  rel     = wr_cd && hold && !wd[0] && pend;   // HOLD released: the held carry
wire  inc_now = inc_1hz || rel;
wire  adj_end = adj && tick && adj_cnt == 3'd1;
wire  adj_up  = t.s10 >= 3'd3;
inc_t st;                                          // from the seconds, or the minutes (adjust)
assign st = step(t, adj_end, h24);
logic dirty   = 1'b0;

always_ff @(posedge clk) begin
    clk_set <= 1'b0;

    if (tick) begin
        div  <= div_n;
        half <= !half;
        if (busy_cnt != 3'd0) busy_cnt <= busy_cnt - 3'd1;
        if (adj_cnt != 3'd0) adj_cnt <= adj_cnt - 3'd1;
        // BUSY clears only on a 16 kHz sample with HOLD = 0 after the window
        if (half && !hold) busy <= busy_cnt != 3'd0;
        // the standard pulse's end
        if (!stop && irq_cnt != 9'd0) begin
            irq_cnt <= irq_cnt - 9'd1;
            if (irq_cnt == 9'd1 && !ce[1]) irq <= 1'b0;
        end
    end

    // the 1 Hz carry: held while HOLD = 1 (one carry), applied at the release
    if ((c1hz || ctest) && hold) pend <= 1'b1;
    if (rel) pend <= c1hz || ctest;

    // the 30 s adjust takes the step in its clk (the seconds go to 00 anyway)
    if (adj_end) begin
        if (adj_up) t <= st.t;
        t.s1  <= 4'd0;
        t.s10 <= 3'd0;
        adj   <= 1'b0;
        div[14:7] <= '0;
        dirty <= 1'b1;
    end else if (inc_now) begin
        t <= st.t;
    end
    if (inc_now) begin
        busy <= 1'b1;
        busy_cnt <= 3'd6;
    end

    // STD.P / IRQ FLAG
    begin
        logic ev;
        case (ce[3:2])
            2'd0:    ev = e64;
            2'd1:    ev = inc_now;
            2'd2:    ev = adj_end ? adj_up : inc_now && st.cm;
            default: ev = adj_end ? adj_up && st.ch : inc_now && st.ch;
        endcase
        // interrupt mode: a new event while the flag is set is ignored;
        // standard pulse mode: the pulse starts again
        if (ev && !ce[0] && (!irq || !ce[1])) begin
            irq <= 1'b1;
            irq_cnt <= 9'd256;
        end
    end

    // the seed
    // taken (or ignored: the PC owns the clock, invalid BCD); while HOLD is set it waits
    if (seed_new && (owned || !hold)) seed_tog <= seed[64];
    if (seed_load) begin
        t <= sv;
        div <= '0;
        pend <= 1'b0;
    end

    // the CPU's writes
    if (wr_end) begin
        case (ra)
            4'h0: t.s1   <= wd;
            4'h1: t.s10  <= wd[2:0];
            4'h2: t.mi1  <= wd;
            4'h3: t.mi10 <= wd[2:0];
            4'h4: t.h1   <= wd;
            4'h5: begin t.h10 <= wd[1:0]; t.pm <= wd[2]; end
            4'h6: t.d1   <= wd;
            4'h7: t.d10  <= wd[1:0];
            4'h8: t.mo1  <= wd;
            4'h9: t.mo10 <= wd[0];
            4'hA: t.y1   <= wd;
            4'hB: t.y10  <= wd;
            4'hC: t.w    <= wd[2:0];
            4'hD: begin
                hold <= wd[0];
                if (!wd[2]) begin irq <= 1'b0; irq_cnt <= 9'd0; end
                if (wd[3] && !adj) begin adj <= 1'b1; adj_cnt <= 3'd4; end
            end
            4'hE: ce <= wd;
            4'hF: begin
                rest <= wd[0];
                stop <= wd[1];
                if (rest) h24 <= wd[2];
                test <= wd[3];
            end
        endcase
        if (ra <= 4'hC) dirty <= 1'b1;
    end

    if (dirty && !hold && !stop && !adj && !(wr_end && ra <= 4'hC)) begin
        clk_set <= 1'b1;
        owned <= 1'b1;
        dirty <= 1'b0;
    end
end

// ------------------------------------------------------------ reads
logic [3:0] rd;
always_comb begin
    case (ra)
        4'h0: rd = t.s1;
        4'h1: rd = {1'b0, t.s10};
        4'h2: rd = t.mi1;
        4'h3: rd = {1'b0, t.mi10};
        4'h4: rd = t.h1;
        4'h5: rd = {1'b0, t.pm && !h24, t.h10};
        4'h6: rd = t.d1;
        4'h7: rd = {2'b00, t.d10};
        4'h8: rd = t.mo1;
        4'h9: rd = {3'b000, t.mo10};
        4'hA: rd = t.y1;
        4'hB: rd = t.y10;
        4'hC: rd = {1'b0, t.w};
        4'hD: rd = {adj, irq, busy, hold};
        4'hE: rd = ce;
        default: rd = {test, h24, stop, rest};
    endcase
end
assign isa_dsel = sel && !isa_ior_n;
assign isa_din  = isa_dsel ? {4'hF, rd} : 8'h00;

// ------------------------------------------------------------ the clock for the MEGA65
always_comb begin
    logic [21:0] hp;
    logic [6:0]  hu;
    logic [13:0] tq;
    logic [3:0]  tens;
    logic [4:0]  hb, h;
    // hundredths from the divider: div x 100 / 32768, in BCD
    hp   = {7'd0, div} * 22'd100;
    hu   = hp[21:15];
    tq   = {7'd0, hu} * 14'd103;                   // / 10 for 0..99: x 103 / 1024
    tens = tq[13:10];
    hb   = 5'd0;
    h    = 5'd0;
    now[7:0]   = {tens, hu[3:0] - {tens[2:0], 1'b0} - {tens[0], 3'b000}};
    now[15:8]  = {1'b0, t.s10, t.s1};
    now[23:16] = {1'b0, t.mi10, t.mi1};
    if (h24) begin
        now[31:24] = {2'b00, t.h10, t.h1};
    end else begin
        hb = {4'd0, t.h10[0]} * 5'd10 + {1'b0, t.h1};
        h  = (hb == 5'd12 ? 5'd0 : hb) + (t.pm ? 5'd12 : 5'd0);
        now[31:24] = (h >= 5'd20) ? {4'd2, h[3:0] - 4'd4} : (h >= 5'd10) ? {4'd1, h[3:0] - 4'd10} : {4'd0, h[3:0]};
    end
    now[39:32] = {2'b00, t.d10, t.d1};
    now[47:40] = {3'b000, t.mo10, t.mo1};
    now[55:48] = {(t.y10 >= 4'd2) ? t.y10 - 4'd2 : t.y10 + 4'd8, t.y1};      // - 20 years
    now[63:56] = {5'd0, (t.w == 3'd0) ? 3'd6 : t.w - 3'd1};                  // Sunday = 0 -> 6
end

endmodule
