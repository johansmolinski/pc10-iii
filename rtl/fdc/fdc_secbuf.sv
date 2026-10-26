// fdc_secbuf.sv - the FDC's sector buffer (2 slots x 512 bytes, one RAMB18)
// and the engine that moves a slot to or from the disk image over the
// sector port (doc/fdc.md, "Sector port").
//
// Port A belongs to the 765 (byte at a time, at the disk's byte rate), port B
// to the engine. The engine handles one transfer at a time:
//   read:  sp_req high with the address; the backend sends 512 bytes
//          (sp_rd_valid/sp_rd_data, any spacing, the card never stalls them)
//          and pulses sp_done (with or after the last byte);
//   write: sp_req high with sp_write = 1; the card offers 512 bytes
//          (sp_wr_valid/sp_wr_data, taken when sp_wr_ready = 1) and the
//          backend pulses sp_done once the data are stored.
//   sp_err with sp_done: the transfer failed. sp_req drops the clk after
//   sp_done; the next request comes at the earliest one clk later.
//
// GPL-3.0-or-later, pc10-iii.

module fdc_secbuf (
    input  logic        clk,
    input  logic        reset,

    // port A (the 765)
    input  logic [9:0]  a_addr,
    input  logic        a_we,
    input  logic [7:0]  a_wdata,
    output logic [7:0]  a_rdata,

    // transfer requests from the 765
    input  logic        x_start,
    input  logic        x_write,
    input  logic        x_fmt,          // pc10-iii (internal drive): a FORMAT TRACK commit
    input  logic        x_slot,
    input  logic [7:0]  x_cyl,
    input  logic        x_head,
    input  logic [7:0]  x_sec,
    input  logic [15:0] x_lba,          // computed by the card from the geometry
    input  logic        x_drive,        // physical drive (latched at x_start)
    output logic        x_busy,
    output logic        x_done,
    output logic        x_err,

    // sector port (to the MEGA65 glue)
    output logic        sp_req,
    output logic        sp_write,
    output logic        sp_fmt,
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
    input  logic        sp_err
);

// ------------------------------------------------------------ the RAM
// True dual-port, both ports on clk (UG901 template: one process per port).
logic [7:0] mem [1024];
logic [9:0] b_addr;
logic       b_we;
logic [7:0] b_wdata, b_rdata;

always @(posedge clk) begin
    if (a_we) mem[a_addr] <= a_wdata;
    a_rdata <= mem[a_addr];
end
always @(posedge clk) begin
    if (b_we) mem[b_addr] <= b_wdata;
    b_rdata <= mem[b_addr];
end

// ------------------------------------------------------------ the engine
logic       busy;
logic       slot;
logic [9:0] cnt;                        // bytes moved
logic       pend;                       // write: RAM read in flight

assign x_busy     = busy | x_start;
assign sp_wr_data = b_rdata;

always_ff @(posedge clk) begin
    x_done <= 1'b0;
    b_we   <= 1'b0;
    if (reset) begin
        busy <= 1'b0;
        sp_req <= 1'b0;
        sp_wr_valid <= 1'b0;
        pend <= 1'b0;
        x_err <= 1'b0;
    end else if (!busy) begin
        if (x_start) begin
            busy      <= 1'b1;
            slot      <= x_slot;
            sp_req    <= 1'b1;
            sp_write  <= x_write;
            sp_fmt    <= x_write && x_fmt;
            sp_drive  <= x_drive;
            sp_cyl    <= x_cyl;
            sp_head   <= x_head;
            sp_sector <= x_sec;
            sp_lba    <= x_lba;
            cnt       <= 10'd0;
            b_addr    <= {x_slot, 9'd0};
            pend      <= x_write;
            sp_wr_valid <= 1'b0;
        end
    end else begin
        if (!sp_write) begin
            if (sp_rd_valid && !cnt[9]) begin
                b_we    <= 1'b1;
                b_addr  <= {slot, cnt[8:0]};
                b_wdata <= sp_rd_data;
                cnt     <= cnt + 10'd1;
            end
        end else begin
            if (pend) begin
                pend <= 1'b0;
                sp_wr_valid <= 1'b1;
            end
            if (sp_wr_valid && sp_wr_ready) begin
                sp_wr_valid <= 1'b0;
                cnt <= cnt + 10'd1;
                if (cnt != 10'd511) begin
                    b_addr <= {slot, cnt[8:0] + 9'd1};
                    pend <= 1'b1;
                end
            end
        end
        if (sp_done) begin
            busy <= 1'b0;
            sp_req <= 1'b0;
            sp_wr_valid <= 1'b0;
            pend <= 1'b0;
            x_done <= 1'b1;
            // a read must have delivered all 512 bytes (counting a byte that
            // arrives together with sp_done)
            x_err <= sp_err || (!sp_write && cnt + 10'(sp_rd_valid) < 10'd512);
        end
    end
end

endmodule
