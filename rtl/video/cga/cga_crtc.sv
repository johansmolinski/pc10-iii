// cga_crtc.sv - Motorola MC6845 CRT controller, as used on the IBM CGA.
//
// A behavioural model on the character clock: one `cclk` pulse = one 6845
// CLK edge. The counter logic is a transliteration of MartyPC's
// devices/mc6845.rs (Crtc6845::tick, MIT, (c) 2022-2026 Daniel Balsom), which
// follows the "CRTC Compendium" of the Amstrad CPC scene for the 6845's
// internal behaviour. Modelled (see doc/cga.md section 3 for the list):
//   - R0..R17 with the Motorola write masks; R12-R17 readable as R14-R17 only
//     (others read 0xFF, as MartyPC returns); the address register is 5 bits
//     wide (MC6845 data sheet), MartyPC compares the full byte;
//   - register writes take effect at the next character clock: R0-R9 are
//     compared live by the coincidence circuits, so mid-frame writes act
//     where the beam is (Area 5150 / 8088 MPH style tricks);
//   - start address latched at the start of each frame; vertical total
//     adjust (R5) as an extra block of lines after the last row;
//   - "last line" management of the Compendium (12.4.1): a last line is not
//     accepted twice in a row, nor when an HSYNC is active at C0 = 0;
//   - HSYNC width R3[3:0], 0 = 16 characters (Motorola; 8088 MPH's colour
//     burst trick); VSYNC fixed at 16 lines (Motorola ignores R3[7:4]);
//   - interlace modes R8 = 01 (sync) and 11 (sync and video) with the
//     half-line field;
//   - cursor: start/end line R10/R11, R10[6:5] blink modes (non-blink,
//     off, 1/16 and 1/32 field rate), toggled at VSYNC start;
//   - light pen: `lp_strobe` copies the current address into R16/R17.
// Not modelled: skew (the Motorola 6845 has no skew bits; R8[5:4] are
// ignored), row address beyond the R9 mask, the Hitachi/UMC variants.
//
// The memory address is 14 bits (the chip's MA0-MA13); MartyPC keeps it in a
// u16 and therefore differs when the address passes 0x3FFF within a frame.
//
// GPL-3.0-or-later, pc10-iii.

module cga_crtc (
    input  logic        clk,
    input  logic        reset,
    input  logic        cclk,          // character clock enable (one clk)

    // register interface (one-clk strobes)
    input  logic        wr_addr,       // write the address register
    input  logic        wr_data,       // write the selected register
    input  logic [7:0]  din,
    output logic [7:0]  dout,          // read of the selected register
    input  logic        lp_strobe,     // latch the light pen address

    // outputs, valid from the clk after cclk
    output logic [13:0] ma,
    output logic [4:0]  ra,
    output logic        de,            // display enable
    output logic        hsync,
    output logic        vsync,
    output logic        cursor,        // combinational: registers + state
    output logic [4:0]  vsc            // VSYNC line counter (0-15)
);

// ------------------------------------------------------------ registers
logic [4:0] sel;
logic [7:0] r0, r1, r2;
logic [3:0] r3;           // HSYNC width; VSYNC width bits [7:4] ignored (Motorola)
logic [6:0] r4, r6, r7;
logic [4:0] r5, r9, r11;
logic [1:0] r8;
logic [6:0] r10;
logic [5:0] r12, r14, r16;
logic [7:0] r13, r15, r17;

wire [13:0] start_address  = {r12, r13};
wire [13:0] cursor_address = {r14, r15};
wire        cur_en         = r10[6:5] != 2'b01;
wire        cur_blinks     = r10[6];            // 10 = 1/16, 11 = 1/32
wire [4:0]  cur_start      = r10[4:0];
wire        isync          = r8[0];             // 01 or 11
wire        ivideo         = r8 == 2'b11;

// ------------------------------------------------------------ counter state
localparam logic [1:0] M_NORMAL = 2'd0, M_VTA = 2'd1, M_HALF = 2'd2;

typedef struct packed {
    logic [7:0]  hcc;           // C0
    logic [4:0]  vlc;           // C9
    logic [3:0]  vlci;          // C9 interlaced
    logic [6:0]  vcc;           // C4
    logic [4:0]  vsc;           // C3h
    logic [3:0]  hsc;           // C3l
    logic [5:0]  vtac;          // C5 (MartyPC compares > R5, so one bit more)
    logic        prev_last;     // previous line was a last line
    logic        last_line;
    logic        in_hsync;
    logic        in_vsync;
    logic        h_de;
    logic        v_de;
    logic        last_vbl;      // in the line after the 16th VSYNC line
    logic [1:0]  mode;
    logic        parity;        // interlace frame parity (0 even)
    logic [3:0]  frames;
    logic        blink;         // cursor blink state
    logic        cur_act;       // between cursor start and end line
    logic [13:0] vma;
    logic [13:0] vma_t;
    logic [13:0] sal;           // start address latch
} st_t;

st_t s;

function automatic logic [4:0] f_ra(st_t x);
    return ivideo ? {x.vlci, x.parity} : x.vlc;
endfunction

function automatic st_t f_start_of_frame(st_t xi);
    st_t x;
    x = xi;
    x.frames    = x.frames + 4'd1;
    if (isync) x.parity = ~x.parity;
    x.mode      = M_NORMAL;
    x.last_line = 1'b0;
    x.vtac      = 6'd0;
    x.vcc       = 7'd0;
    x.vlc       = 5'd0;
    x.vlci      = 4'd0;
    x.sal       = start_address;
    x.vma       = start_address;
    x.vma_t     = start_address;
    x.h_de      = 1'b1;
    x.v_de      = 1'b1;
    x.in_vsync  = 1'b0;
    return x;
endfunction

function automatic logic f_half(st_t x);
    return isync && !x.parity;
endfunction

function automatic st_t f_frame_end(st_t xi);
    st_t x;
    x = xi;
    if (f_half(x)) x.mode = M_HALF;
    else           x = f_start_of_frame(x);
    return x;
endfunction

function automatic st_t f_last_line(st_t xi);
    st_t x;
    x = xi;
    case (x.mode)
        M_NORMAL:
            if (r5 != 5'd0) begin
                x.mode      = M_VTA;
                x.last_line = 1'b0;
            end else if (f_half(x))
                x.mode = M_HALF;
            else
                x = f_frame_end(x);
        M_HALF:  x = f_start_of_frame(x);
        default: ;
    endcase
    return x;
endfunction

// One character clock (Crtc6845::tick).
function automatic st_t f_tick(st_t xi);
    st_t x;
    logic c4_r4, c0_r0, c0_r0_half, c9_r9_half, c9_r9, split;
    x          = xi;
    c4_r4      = x.vcc == r4;
    c0_r0      = x.hcc == r0;
    c0_r0_half = x.hcc == (r0 >> 1);
    c9_r9_half = x.vlc == (r9 >> 1);
    c9_r9      = x.vlc == r9;
    split      = ivideo && c9_r9_half;

    if (x.hcc == 8'd0) begin
        // start of line
        if (f_ra(x) == cur_start && x.mode != M_VTA) x.cur_act = 1'b1;
        if (x.vcc == 7'd0 && x.vlc == 5'd0) x.vma = x.sal;
        if (x.vcc == r4)
            begin
                x.last_line = c9_r9 && !x.prev_last && !x.in_hsync;
                x.vtac      = 6'd0;
            end
        else
            x.last_line = 1'b0;
    end

    x.hcc = x.hcc + 8'd1;
    if (x.hcc == 8'd0) begin
        x.h_de = 1'b1;
        if (x.vcc == 7'd0) x.vma = x.sal;
    end
    x.vma = x.vma + 14'd1;

    if (x.in_hsync) begin
        x.hsc = x.hsc - 4'd1;
        if (x.hsc == 4'd0) begin
            x.prev_last = c4_r4 && c9_r9;
            if (x.in_vsync) begin
                x.vsc = x.vsc + 5'd1;
                if (x.vsc == 5'd16) begin
                    x.last_vbl = 1'b1;
                    x.vsc      = 5'd0;
                    x.in_vsync = 1'b0;
                end
            end
            x.in_hsync = 1'b0;
        end
    end

    if (x.hcc == r1) begin
        if (c9_r9 || split) x.vma_t = x.vma;
        x.h_de = 1'b0;
    end

    if (x.hcc == r2) begin
        x.in_hsync = 1'b1;
        x.hsc      = r3;
    end

    if (c0_r0) begin
        // end of line
        if (f_ra(x) == r11 && x.mode != M_VTA) x.cur_act = 1'b0;
        if (x.last_vbl) begin
            x.last_vbl = 1'b0;
            x.in_vsync = 1'b0;
        end
        x.hcc  = 8'd0;
        x.h_de = 1'b1;
        x.vma  = x.vma_t;
        if (c9_r9) begin
            x.vlc  = 5'd0;
            x.vlci = 4'd0;
            x.vcc  = x.vcc + 7'd1;
            if (x.vcc == r7) begin
                x.in_vsync = 1'b1;
                if (cur_blinks && (r10[5] ? x.frames[3:0] == 4'd0 : x.frames[2:0] == 3'd0))
                    x.blink = ~x.blink;
            end
            if (x.last_line) x = f_last_line(x);
        end else begin
            if (split) x.vlci = 4'd0;
            else       x.vlci = x.vlci + 4'd1;
            x.vlc = x.vlc + 5'd1;
            if (f_ra(x) == cur_start && x.mode != M_VTA) x.cur_act = 1'b1;
        end
        if (x.vcc == r6) x.v_de = 1'b0;
        if (x.mode == M_VTA) begin
            x.vtac = x.vtac + 6'd1;
            if (x.vtac > {1'b0, r5}) x = f_frame_end(x);
        end
    end else if (x.mode == M_HALF && c0_r0_half)
        x = f_last_line(x);

    return x;
endfunction

// ------------------------------------------------------------ sequential
// A register write in the same clk as a character clock acts after it.
st_t s_next;
always_comb begin
    s_next = cclk ? f_tick(s) : s;
    // leaving interlaced sync resets the field parity (MartyPC)
    if (wr_data && sel == 5'd8 && r8[0] && !din[0]) s_next.parity = 1'b0;
end

always_ff @(posedge clk) begin
    if (reset) begin
        s   <= '0;
        sel <= 5'd0;
        r0 <= 8'd0; r1 <= 8'd0; r2 <= 8'd0; r3 <= 4'd0;
        r4 <= 7'd0; r5 <= 5'd0; r6 <= 7'd0; r7 <= 7'd0;
        r8 <= 2'd0; r9 <= 5'd0; r10 <= 7'd0; r11 <= 5'd0;
        r12 <= 6'd0; r13 <= 8'd0; r14 <= 6'd0; r15 <= 8'd0;
        r16 <= 6'd0; r17 <= 8'd0;
    end else begin
        s <= s_next;
        if (lp_strobe) begin
            r16 <= s_next.vma[13:8];
            r17 <= s_next.vma[7:0];
        end
        if (wr_addr) sel <= din[4:0];
        if (wr_data)
            case (sel)
                5'd0:  r0  <= din;
                5'd1:  r1  <= din;
                5'd2:  r2  <= din;
                5'd3:  r3  <= din[3:0];
                5'd4:  r4  <= din[6:0];
                5'd5:  r5  <= din[4:0];
                5'd6:  r6  <= din[6:0];
                5'd7:  r7  <= din[6:0];
                5'd8:  r8  <= din[1:0];
                5'd9:  r9  <= din[4:0];
                5'd10: r10 <= din[6:0];
                5'd11: r11 <= din[4:0];
                5'd12: r12 <= din[5:0];
                5'd13: r13 <= din;
                5'd14: r14 <= din[5:0];
                5'd15: r15 <= din;
                default: ;
            endcase
    end
end

// ------------------------------------------------------------ outputs
assign ma     = s.vma;
assign ra     = f_ra(s);
assign de     = s.h_de && s.v_de;
assign hsync  = s.in_hsync;
assign vsync  = s.in_vsync;
assign vsc    = s.vsc;
assign cursor = cur_en && s.cur_act && s.vma == cursor_address && (!cur_blinks || s.blink);

always_comb
    case (sel)
        5'd14:   dout = {2'b00, r14};
        5'd15:   dout = r15;
        5'd16:   dout = {2'b00, r16};
        5'd17:   dout = r17;
        default: dout = 8'hFF;
    endcase

endmodule
