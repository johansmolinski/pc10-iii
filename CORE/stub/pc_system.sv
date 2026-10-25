// pc_system.sv - STAND-IN for the real PC (rtl/system/pc_system.sv): a shell-only test
// pattern with the same module name and ports (doc/architecture.md section 4). It lives in
// CORE/stub so it never collides with rtl/; build it with tools/gen_xpr.py --stub. The font
// and floppy ports are ignored / tied off.
//
// What it does, so that every path of the shell can be checked on the screen:
//   * video: a CGA-like raster on the 14.31818 MHz enable (clk / 2): 912 dots x 262 lines
//     (15.70 kHz, 59.92 Hz), 640 x 200 active, hsync dots 720-799, vsync lines 224-226,
//     blanks covering the syncs. Text (8 x 8 font) shows the values below, then 16 colour
//     bars of the RGBI palette, inside a white one-pixel frame.
//   * keyboard: shows the last scan code and the number of codes received; kbd_busy is held
//     for 100 us after each code (like a board that takes a while to read it); a make code
//     starts a 100 ms beep (~1 kHz) on the speaker.
//   * BIOS ROM: reads F0000-F000F and FFFF0-FFFFF continuously and shows them (right-aligned
//     image: the last 16 bytes of the file are at FFFF0).
//   * RAM: an endless write-then-verify test of 00000-9FFFF (RAM_KB) through the memory
//     port (one request at a time, waits for ram_ack): passes, errors and the first bad
//     address. With the OSM's memory size below 640 KB the addresses above it fail - the
//     glue reads 0xFF there - which shows that switch working.
//   * dip_sw1 is shown.
// vid_rgbi = {I, R, G, B}.
//
// done by Johan Smolinski in 2026 and licensed under GPL v3

module pc_system #(
    parameter int RAM_KB = 640,
    // the real pc_system's configuration (ignored by the stand-in)
    parameter bit CGA_FIT = 1'b1,
    parameter int MDA_FIT = 0,
    parameter bit FE2010A = 1'b0,
    parameter bit PVC4_FIT = 1'b0
) (
    input  logic        clk,          // 28.63636 MHz
    input  logic        reset,        // synchronous, active high

    output logic [19:0] ram_addr,
    output logic        ram_en,
    output logic        ram_we,
    output logic [7:0]  ram_wdata,
    input  logic [7:0]  ram_rdata,
    input  logic        ram_ack,

    output logic [15:0] rom_addr,
    input  logic [7:0]  rom_rdata,

    output logic        vid_ce,
    output logic [3:0]  vid_rgbi,
    output logic        vid_hsync,
    output logic        vid_vsync,
    output logic        vid_hblank,
    output logic        vid_vblank,

    // (ports of the real pc_system that the stand-in ignores or ties off)
    input  logic        font_we,
    input  logic [12:0] font_addr,
    input  logic [7:0]  font_data,
    input  logic        font_thin,
    input  logic [1:0]  font_addr_hi,
    input  logic        font_cbm,
    input  logic [1:0]  cbm_dip,
    output logic        vid_mono,
    output logic        vid_monomode,

    input  logic        ucl_we,       // the 8088's microcode load port (ignored)
    input  logic [12:0] ucl_addr,
    input  logic [7:0]  ucl_data,
    input  logic [1:0]       drv_80trk,
    input  logic [1:0]       img_present,
    input  logic [1:0]       img_wp,
    input  logic [1:0][7:0]  img_tracks,
    input  logic [1:0][1:0]  img_heads,
    input  logic [1:0][5:0]  img_spt,
    output logic [1:0]       drv_motor,
    output logic             fdc_active,
    output logic [1:0]       drv_select,
    output logic             drv_step,
    output logic             drv_step_in,
    output logic        sp_req,
    output logic        sp_write,
    output logic        sp_drive,
    output logic [7:0]  sp_cyl,
    output logic        sp_head,
    output logic [7:0]  sp_sector,
    output logic [15:0] sp_lba,
    input  logic        sp_rd_valid,
    input  logic [7:0]  sp_rd_data,
    output logic        sp_wr_valid,
    output logic [7:0]  sp_wr_data,
    input  logic        sp_wr_ready,
    input  logic        sp_done,
    input  logic        sp_err,
    input  logic             hdc_enable,
    input  logic [1:0]       hdc_variant,
    output logic [13:0]      hdc_rom_addr,
    input  logic [7:0]       hdc_rom_rdata,
    input  logic [1:0]       hd_present,
    input  logic [1:0][27:0] hd_sectors,
    input  logic [1:0][15:0] hd_cyls,
    input  logic [1:0][4:0]  hd_heads,
    input  logic [1:0][5:0]  hd_spt,
    output logic             hd_active,
    output logic        hd_sp_req,
    output logic        hd_sp_write,
    output logic        hd_sp_drive,
    output logic [27:0] hd_sp_lba,
    input  logic        hd_sp_rd_valid,
    input  logic [7:0]  hd_sp_rd_data,
    output logic        hd_sp_wr_valid,
    output logic [7:0]  hd_sp_wr_data,
    input  logic        hd_sp_wr_ready,
    input  logic        hd_sp_done,
    input  logic        hd_sp_err,

    input  logic [7:0]  kbd_code,
    input  logic        kbd_valid,
    output logic        kbd_busy,

    output logic        speaker,

    input  logic [7:0]  dip_sw1
);

    localparam logic [639:0] T0 = "  PC10-III FOR MEGA65 - M2M SHELL WITH A STAND-IN PC_SYSTEM (CORE/STUB)         ";
    localparam logic [639:0] T2 = "  KEYBOARD   LAST CODE: ##   CODES: ####                                        ";
    localparam logic [639:0] T4 = "  BIOS F0000: ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##                   ";
    localparam logic [639:0] T5 = "  BIOS FFFF0: ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ##                   ";
    localparam logic [639:0] T7 = "  RAM TEST   PASSES: ####   ERRORS: ####   FIRST BAD: #####                     ";
    localparam logic [639:0] T9 = "  DIP SW1: ##   SPEAKER: A SHORT BEEP ON EVERY KEY PRESS                        ";
    localparam logic [639:0] T11 = "  RGBI COLOURS 0-15 (6 = BROWN), A WHITE FRAME AROUND 640 X 200                 ";

    function automatic logic [63:0] stub_glyph(input logic [7:0] c);
        case (c)
            8'h20: stub_glyph = 64'h0000000000000000;
            8'h21: stub_glyph = 64'h3078783030003000;
            8'h22: stub_glyph = 64'h006C6C2800000000;
            8'h23: stub_glyph = 64'h6C6CFE6CFE6C6C00;
            8'h24: stub_glyph = 64'h0E17130E70B89870;
            8'h25: stub_glyph = 64'h00C6CC183066C600;
            8'h26: stub_glyph = 64'h386C3876DCCC7600;
            8'h27: stub_glyph = 64'h0018383000000000;
            8'h28: stub_glyph = 64'h1830606060301800;
            8'h29: stub_glyph = 64'h6030181818306000;
            8'h2A: stub_glyph = 64'h00663CFF3C660000;
            8'h2B: stub_glyph = 64'h0010107C10100000;
            8'h2C: stub_glyph = 64'h0000000018383000;
            8'h2D: stub_glyph = 64'h0000007C00000000;
            8'h2E: stub_glyph = 64'h0000000018180000;
            8'h2F: stub_glyph = 64'h060C183060C08000;
            8'h30: stub_glyph = 64'h7CC6CEDEF6E67C00;
            8'h31: stub_glyph = 64'h307030303030FC00;
            8'h32: stub_glyph = 64'h78CC0C3860CCFC00;
            8'h33: stub_glyph = 64'h78CC0C380CCC7800;
            8'h34: stub_glyph = 64'h1C3C6CCCFE0C1E00;
            8'h35: stub_glyph = 64'hFCC0F80C0CCC7800;
            8'h36: stub_glyph = 64'h3860C0F8CCCC7800;
            8'h37: stub_glyph = 64'hFCCC0C1830303000;
            8'h38: stub_glyph = 64'h78CCCC78CCCC7800;
            8'h39: stub_glyph = 64'h78CCCC7C0C187000;
            8'h3A: stub_glyph = 64'h0030300000303000;
            8'h3B: stub_glyph = 64'h0030300000307060;
            8'h3C: stub_glyph = 64'h0006061818606000;
            8'h3D: stub_glyph = 64'h00007C00007C0000;
            8'h3E: stub_glyph = 64'h0060601818060600;
            8'h3F: stub_glyph = 64'h78CC0C1830003000;
            8'h40: stub_glyph = 64'h3C7E184266666624;
            8'h41: stub_glyph = 64'h3078CCCCFCCCCC00;
            8'h42: stub_glyph = 64'hFC66667C6666FC00;
            8'h43: stub_glyph = 64'h3C66C0C0C0663C00;
            8'h44: stub_glyph = 64'hF86C6666666CF800;
            8'h45: stub_glyph = 64'hFE6268786862FE00;
            8'h46: stub_glyph = 64'hFE6268786860F000;
            8'h47: stub_glyph = 64'h3C66C0C0CE663E00;
            8'h48: stub_glyph = 64'hCCCCCCFCCCCCCC00;
            8'h49: stub_glyph = 64'h7830303030307800;
            8'h4A: stub_glyph = 64'h1E0C0C0CCCCC7800;
            8'h4B: stub_glyph = 64'hE6666C786C66E600;
            8'h4C: stub_glyph = 64'hF06060606266FE00;
            8'h4D: stub_glyph = 64'hC6EEFEFED6C6C600;
            8'h4E: stub_glyph = 64'hC6E6F6DECEC6C600;
            8'h4F: stub_glyph = 64'h386CC6C6C66C3800;
            8'h50: stub_glyph = 64'hFC66667C6060F000;
            8'h51: stub_glyph = 64'h78CCCCCCDC781C00;
            8'h52: stub_glyph = 64'hFC66667C6C66E600;
            8'h53: stub_glyph = 64'h78CC603018CC7800;
            8'h54: stub_glyph = 64'hFCB4303030307800;
            8'h55: stub_glyph = 64'hCCCCCCCCCCCCFC00;
            8'h56: stub_glyph = 64'hCCCCCCCCCC783000;
            8'h57: stub_glyph = 64'hC6C6C6D6FEEEC600;
            8'h58: stub_glyph = 64'h00C66C38386CC600;
            8'h59: stub_glyph = 64'hCCCCCC7830307800;
            8'h5A: stub_glyph = 64'hFEC68C183266FE00;
            8'h5B: stub_glyph = 64'h7860606060607800;
            8'h5C: stub_glyph = 64'hC06030180C060200;
            8'h5D: stub_glyph = 64'h7818181818187800;
            8'h5E: stub_glyph = 64'h10386CC600000000;
            8'h5F: stub_glyph = 64'h00000000000000FF;
            default: stub_glyph = 64'h0;
        endcase
    endfunction

    assign drv_motor = 2'b00;
    assign fdc_active = 1'b0;
    assign drv_select = 2'b00;
    assign drv_step = 1'b0;
    assign drv_step_in = 1'b0;
    assign {sp_req, sp_write, sp_drive, sp_head, sp_wr_valid} = '0;
    assign {sp_cyl, sp_sector, sp_lba, sp_wr_data} = '0;
    // no hard disk card in the stand-in
    assign hdc_rom_addr = '0;
    assign {hd_active, hd_sp_req, hd_sp_write, hd_sp_drive, hd_sp_wr_valid} = '0;
    assign {hd_sp_lba, hd_sp_wr_data} = '0;

    function automatic logic [7:0] hexc(input logic [3:0] n);
        hexc = (n < 4'd10) ? (8'h30 + {4'h0, n}) : (8'h37 + {4'h0, n});
    endfunction

    // ------------------------------------------------------------------------------------
    // 14.31818 MHz enable
    // ------------------------------------------------------------------------------------

    logic div2 = 1'b0;
    always_ff @(posedge clk) div2 <= !div2;
    wire ce_14m = !div2;
    assign vid_ce = ce_14m;
    assign vid_mono = 1'b0;
    assign vid_monomode = 1'b0;

    // ------------------------------------------------------------------------------------
    // Raster
    // ------------------------------------------------------------------------------------

    logic [9:0] hc = '0;
    logic [8:0] vc = '0;
    always_ff @(posedge clk) begin
        if (ce_14m) begin
            if (hc == 10'd911) begin
                hc <= '0;
                vc <= (vc == 9'd261) ? 9'd0 : vc + 9'd1;
            end else
                hc <= hc + 10'd1;
        end
    end

    // ------------------------------------------------------------------------------------
    // Things to show
    // ------------------------------------------------------------------------------------

    logic [7:0]  last_code = '0;
    logic [15:0] code_count = '0;
    logic [13:0] busy_cnt = '0;
    logic [23:0] beep = '0;
    logic [15:0] tone = '0;
    logic        spk = 1'b0;

    always_ff @(posedge clk) begin
        if (busy_cnt != 0) busy_cnt <= busy_cnt - 14'd1;
        if (beep != 0) begin
            beep <= beep - 24'd1;
            if (tone == 16'd14317) begin           // ~1 kHz
                tone <= '0;
                spk  <= ~spk;
            end else
                tone <= tone + 16'd1;
        end else
            spk <= 1'b0;
        if (kbd_valid && busy_cnt == 0) begin
            last_code  <= kbd_code;
            code_count <= code_count + 16'd1;
            busy_cnt   <= 14'd2864;                   // 100 us
            if (!kbd_code[7]) beep <= 24'd2_863_636;  // 100 ms
        end
        if (reset) begin
            last_code  <= '0;
            code_count <= '0;
            busy_cnt   <= '0;
            beep       <= '0;
            spk        <= 1'b0;
        end
    end
    assign kbd_busy = (busy_cnt != 0);
    assign speaker  = spk;

    // BIOS ROM: F0000-F000F and FFFF0-FFFFF, round robin, 1 clk latency
    logic [4:0] ridx = '0, ridx_d = '0;
    logic [7:0] rom_bytes [0:31];
    always_ff @(posedge clk) begin
        ridx   <= ridx + 5'd1;
        ridx_d <= ridx;
        rom_bytes[ridx_d] <= rom_rdata;
    end
    assign rom_addr = ridx[4] ? {12'hFFF, ridx[3:0]} : {12'h000, ridx[3:0]};

    // RAM test
    localparam logic [19:0] RAM_TOP = 20'(RAM_KB * 1024 - 1);
    typedef enum logic [1:0] {S_WR, S_WR_WAIT, S_RD, S_RD_WAIT} t_state;
    t_state      st = S_WR;
    logic [19:0] ta = '0;
    logic [7:0]  seed = '0;
    logic [15:0] passes = '0;
    logic [15:0] errors = '0;
    logic [19:0] first_bad = '0;

    function automatic logic [7:0] pattern(input logic [19:0] a, input logic [7:0] s);
        pattern = a[7:0] ^ a[15:8] ^ {a[19:16], a[19:16]} ^ s;
    endfunction

    always_ff @(posedge clk) begin
        ram_en <= 1'b0;
        case (st)
            S_WR: begin
                ram_addr  <= ta;
                ram_we    <= 1'b1;
                ram_wdata <= pattern(ta, seed);
                ram_en    <= 1'b1;
                st        <= S_WR_WAIT;
            end
            S_WR_WAIT: if (ram_ack) begin
                if (ta == RAM_TOP) begin
                    ta <= '0;
                    st <= S_RD;
                end else begin
                    ta <= ta + 20'd1;
                    st <= S_WR;
                end
            end
            S_RD: begin
                ram_addr <= ta;
                ram_we   <= 1'b0;
                ram_en   <= 1'b1;
                st       <= S_RD_WAIT;
            end
            S_RD_WAIT: if (ram_ack) begin
                if (ram_rdata != pattern(ta, seed)) begin
                    if (errors == 0) first_bad <= ta;
                    if (errors != 16'hFFFF) errors <= errors + 16'd1;
                end
                if (ta == RAM_TOP) begin
                    ta     <= '0;
                    seed   <= seed + 8'd1;
                    passes <= passes + 16'd1;
                    st     <= S_WR;
                end else begin
                    ta <= ta + 20'd1;
                    st <= S_RD;
                end
            end
        endcase
        if (reset) begin
            st        <= S_WR;
            ta        <= '0;
            seed      <= '0;
            passes    <= '0;
            errors    <= '0;
            first_bad <= '0;
            ram_en    <= 1'b0;
        end
    end

    // ------------------------------------------------------------------------------------
    // Text
    // ------------------------------------------------------------------------------------

    function automatic logic [7:0] tbyte(input logic [639:0] t, input logic [6:0] col);
        tbyte = t[(79 - col) * 8 +: 8];
    endfunction

    wire [6:0] col = hc[9:3];
    wire [4:0] row = vc[7:3];

    // the character at (row, col): the static text, with the live fields filled in
    logic [7:0] ch;
    always_comb begin
        logic [6:0] rc;
        logic [4:0] bi;
        ch = 8'h20;
        rc = '0;
        bi = '0;
        if (col < 7'd80) begin
            case (row)
                5'd0:  ch = tbyte(T0, col);
                5'd2:  begin
                           ch = tbyte(T2, col);
                           if (col == 24) ch = hexc(last_code[7:4]);
                           if (col == 25) ch = hexc(last_code[3:0]);
                           if (col >= 36 && col <= 39) ch = hexc(code_count[(39 - col) * 4 +: 4]);
                       end
                5'd4, 5'd5: begin
                           ch = (row == 5'd4) ? tbyte(T4, col) : tbyte(T5, col);
                           if (col >= 14 && col <= 61) begin
                               rc = col - 7'd14;
                               bi = {(row == 5'd5), 4'(rc / 3)};
                               if (rc % 3 == 0) ch = hexc(rom_bytes[bi][7:4]);
                               if (rc % 3 == 1) ch = hexc(rom_bytes[bi][3:0]);
                           end
                       end
                5'd7:  begin
                           ch = tbyte(T7, col);
                           if (col >= 21 && col <= 24) ch = hexc(passes[(24 - col) * 4 +: 4]);
                           if (col >= 36 && col <= 39) ch = hexc(errors[(39 - col) * 4 +: 4]);
                           if (col >= 54 && col <= 58) ch = hexc(first_bad[(58 - col) * 4 +: 4]);
                       end
                5'd9:  begin
                           ch = tbyte(T9, col);
                           if (col == 11) ch = hexc(dip_sw1[7:4]);
                           if (col == 12) ch = hexc(dip_sw1[3:0]);
                       end
                5'd11: ch = tbyte(T11, col);
                default: ch = 8'h20;
            endcase
        end
    end

    // ------------------------------------------------------------------------------------
    // Pixel pipeline: hc/vc hold for 7 clocks, the three stages settle in 3; the outputs
    // take the result at the next ce_14m, together with the syncs of the same hc/vc.
    // ------------------------------------------------------------------------------------

    logic [7:0]  a_ch;
    logic [2:0]  a_gx, a_gy;
    logic        a_text, a_bar, a_frame, a_active;
    logic [3:0]  a_bar_col;

    always_ff @(posedge clk) begin
        a_ch     <= ch;
        a_gx     <= hc[2:0];
        a_gy     <= vc[2:0];
        a_active <= (hc < 10'd640) && (vc < 9'd200);
        a_text   <= (vc < 9'd96);
        a_bar    <= (vc >= 9'd104) && (vc < 9'd200);
        a_frame  <= (hc == 10'd0) || (hc == 10'd639) || (vc == 9'd0) || (vc == 9'd199);
        a_bar_col <= 4'd0;
        for (int i = 1; i < 16; i++)
            if (hc >= 10'(40 * i)) a_bar_col <= 4'(i);
    end

    logic [63:0] b_glyph;
    logic [2:0]  b_gx, b_gy;
    logic        b_text, b_bar, b_frame, b_active;
    logic [3:0]  b_bar_col;

    always_ff @(posedge clk) begin
        b_glyph   <= stub_glyph(a_ch);
        b_gx      <= a_gx;
        b_gy      <= a_gy;
        b_text    <= a_text;
        b_bar     <= a_bar;
        b_frame   <= a_frame;
        b_active  <= a_active;
        b_bar_col <= a_bar_col;
    end

    logic [3:0] c_rgbi;
    always_ff @(posedge clk) begin
        if (!b_active)
            c_rgbi <= 4'd0;
        else if (b_frame)
            c_rgbi <= 4'd15;                                          // white frame
        else if (b_text)
            c_rgbi <= b_glyph[63 - {b_gy, b_gx}] ? 4'd14 : 4'd1;      // yellow on blue
        else if (b_bar)
            c_rgbi <= b_bar_col;
        else
            c_rgbi <= 4'd0;
    end

    always_ff @(posedge clk) begin
        if (ce_14m) begin
            vid_rgbi   <= c_rgbi;
            vid_hblank <= (hc >= 10'd640);
            vid_vblank <= (vc >= 9'd200);
            vid_hsync  <= (hc >= 10'd720) && (hc < 10'd800);
            vid_vsync  <= (vc >= 9'd224) && (vc < 9'd227);
        end
    end

endmodule
