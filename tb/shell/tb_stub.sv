// tb_stub.sv - Verilator run of the stand-in pc_system (CORE/stub): raster timing, the RAM
// test against a model of pc_ram.vhd (2-clock ack), the ROM reader, the keyboard strobe.
module tb_stub;
    logic clk = 0, reset = 1;
    logic [19:0] ram_addr; logic ram_en, ram_we; logic [7:0] ram_wdata, ram_rdata; logic ram_ack;
    logic [15:0] rom_addr; logic [7:0] rom_rdata;
    logic vid_ce, hs, vs, hb, vb; logic [3:0] rgbi;
    logic [7:0] kbd_code = 0; logic kbd_valid = 0, kbd_busy; logic speaker;

    pc_system #(.RAM_KB(640)) dut (
        .clk(clk), .reset(reset),
        .ram_addr(ram_addr), .ram_en(ram_en), .ram_we(ram_we), .ram_wdata(ram_wdata),
        .ram_rdata(ram_rdata), .ram_ack(ram_ack),
        .rom_addr(rom_addr), .rom_rdata(rom_rdata),
        .vid_ce(vid_ce), .vid_rgbi(rgbi), .vid_hsync(hs), .vid_vsync(vs), .vid_hblank(hb), .vid_vblank(vb),
        .kbd_code(kbd_code), .kbd_valid(kbd_valid), .kbd_busy(kbd_busy),
        .ucl_we(1'b0), .ucl_addr(13'd0), .ucl_data(8'd0),
        .speaker(speaker), .dip_sw1(8'h2D));

    // pc_ram.vhd model: request registered, BRAM read, ack 2 clocks after ram_en
    logic [7:0] mem [0:655359];
    logic [19:0] a_q; logic en_q, we_q; logic [7:0] d_q, q;
    logic ack_q;
    always_ff @(posedge clk) begin
        a_q <= ram_addr; en_q <= ram_en; we_q <= ram_en & ram_we; d_q <= ram_wdata;
        if (we_q) mem[a_q] <= d_q;
        q <= mem[a_q];
        ack_q <= en_q;
    end
    assign ram_rdata = q;
    assign ram_ack = ack_q;

    // ROM: byte = low address byte ^ 0x5A, 1 clock
    always_ff @(posedge clk) rom_rdata <= rom_addr[7:0] ^ 8'h5A;

    initial begin
        longint n = 0, last_hs = -1, last_vs = -1, hper = 0, vper = 0;
        bit hs_d = 0, vs_d = 0;
        int sent = 0;
        while (n < 30_000_000) begin
            clk = 1; #1;
            clk = 0; #1;
            n++;
            if (n == 20) reset = 0;
            if (hs && !hs_d) begin if (last_hs >= 0) hper = n - last_hs; last_hs = n; end
            if (vs && !vs_d) begin if (last_vs >= 0) vper = n - last_vs; last_vs = n; end
            hs_d = hs; vs_d = vs;
            kbd_valid = 0;
            if (n == 1000 || n == 50000) begin
                if (!kbd_busy) begin kbd_code = (n == 1000) ? 8'h1E : 8'h9E; kbd_valid = 1; sent++; end
            end
        end
        $display("hsync period %0d clocks (expect %0d), vsync period %0d (expect %0d)", hper, 912*2, vper, 912*2*262);
        $display("RAM passes %0d errors %0d", dut.passes, dut.errors);
        $display("ROM F0000 %02x FFFF0 %02x FFFFF %02x", dut.rom_bytes[0], dut.rom_bytes[16], dut.rom_bytes[31]);
        $display("keyboard: last code %02x, count %0d", dut.last_code, dut.code_count);
        if (hper == 912*2 && vper == 912*2*262 && dut.passes >= 2 && dut.errors == 0 &&
            dut.rom_bytes[0] == 8'h5A && dut.rom_bytes[16] == (8'hF0 ^ 8'h5A) && dut.rom_bytes[31] == (8'hFF ^ 8'h5A) &&
            dut.last_code == 8'h9E && dut.code_count == 2)
            $display("PASS: stub pc_system");
        else
            $display("FAIL: stub pc_system");
        $finish;
    end
endmodule
