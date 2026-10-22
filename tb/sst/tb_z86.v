// tb_z86.v - z8086 EU + biu88 (rtl/cpu/z8086/cpu_z86.sv) for the
// SingleStepTests harness, with the dbg_* ports of tb_mcl86_biu88.v
// (make CPU=z86). The microcode bundle comes in through ucl_* (sst_run.cpp
// streams the file while the CPU is in reset).
//
// The harness's MCL86 conventions are mapped:
//   dbg_eu_cmd   the command to biu88 (the loader's JMP FAR = request 0x19);
//   dbg_rom_addr 0x0006 while the EU waits for an opcode (MCL86's main loop,
//                where the harness installs a prefetched queue), else 0x0100;
//   dbg_dispatch one clock after the EU's first clock (FC) of an instruction,
//                delayed until an outstanding EU transfer is done (a write
//                that ends an instruction is the test's);
//   dbg_ip       the EU's IP at that FC (the opcode's address);
//   dbg_flags    bit 1 cleared (MCL86's REP re-dispatch marker; the harness
//                sets it again).

module tb_mcl86 (
    input             core_clk,
    input             clk,
    input             step,
    input             tb_preload,
    input      [31:0] tb_queue,
    input      [2:0]  tb_queue_len,
    input      [15:0] tb_ip,
    input             reset,
    input      [7:0]  ad_in,
    input             ucl_we,
    input      [12:0] ucl_addr,
    input      [7:0]  ucl_data,

    output     [19:0] ad_out,
    output            ad_oe,
    output     [2:0]  s2_s0,
    output            s6_3_mux,
    output            lock_n,
    output     [1:0]  qs,
    output     [7:0]  qs_byte,
    output     [2:0]  dbg_t_state,
    output     [2:0]  dbg_ta_state,
    output     [2:0]  dbg_queue_len,

    output     [15:0] dbg_ax, dbg_bx, dbg_cx, dbg_dx,
    output     [15:0] dbg_sp, dbg_bp, dbg_si, dbg_di,
    output     [15:0] dbg_flags,
    output     [15:0] dbg_cs, dbg_ss, dbg_ds, dbg_es,
    output     [15:0] dbg_ip,
    output     [15:0] dbg_eu_cmd,
    output     [7:0]  dbg_pfq_top,
    output            dbg_dispatch,
    output     [12:0] dbg_rom_addr,
    output            dbg_holding,
    output     [2:0]  dbg_qlen,
    output     [15:0] dbg_pc,
    output            dbg_pfq_empty
);

wire ce;
// the loader's JMP FAR as MCL86's flush request (sst_run.cpp: bit 9, code 0x19)
assign dbg_eu_cmd = cpu.eu.flush ? 16'h0390 : 16'h0000;

cpu_z86 cpu (
    .clk          (core_clk),
    .reset        (reset),
    .step         (step),
    .ucl_we       (ucl_we),
    .ucl_addr     (ucl_addr),
    .ucl_data     (ucl_data),
    .READY_IN     (1'b1),
    .NMI          (1'b0),
    .INTR         (1'b0),
    .TEST_n       (1'b1),
    .LOCK_n       (lock_n),
    .AD_OUT       (ad_out),
    .AD_IN        (ad_in),
    .S2_S0_OUT    (s2_s0),
    .S6_3_MUX     (s6_3_mux),
    .QS_OUT       (qs),
    .QS_BYTE      (qs_byte),
    .ALE          (),
    .tb_preload   (tb_preload),
    .tb_queue     (tb_queue),
    .tb_queue_len (tb_queue_len),
    .tb_ip        (tb_ip),
    .dbg_ce       (ce),
    .dbg_t_state  (dbg_t_state),
    .dbg_ta_state (dbg_ta_state),
    .dbg_latch    (),
    .dbg_queue_len(dbg_queue_len),
    .dbg_cs       (),
    .dbg_ip       ()
);
assign ad_oe = 1'b1;

// the registers are final one EU clock after FC (with NX, the last
// microinstruction runs in the clock after FC) and after an outstanding write
wire fc_new = ce && cpu.eu.FC && !cpu.eu.irq_take;
reg        disp_pend, disp, disp_wait;
reg [15:0] ip_l;
always @(posedge core_clk) begin
    disp <= 1'b0;
    if (reset) disp_pend <= 1'b0;
    else if (fc_new) begin
        disp_pend <= 1'b1;
        disp_wait <= 1'b1;
        ip_l      <= cpu.eu.biu_ip;
    end else if (ce)
        disp_wait <= 1'b0;
    else if (disp_pend && !disp_wait && !(cpu.eu.bus_busy && !cpu.eu.bus_done)) begin
        disp_pend <= 1'b0;
        disp      <= 1'b1;
    end
end

assign dbg_ax        = cpu.eu.AX;
assign dbg_bx        = cpu.eu.BX;
assign dbg_cx        = cpu.eu.CX;
assign dbg_dx        = cpu.eu.DX;
assign dbg_sp        = cpu.eu.SP;
assign dbg_bp        = cpu.eu.BP;
assign dbg_si        = cpu.eu.SI;
assign dbg_di        = cpu.eu.DI;
assign dbg_flags     = cpu.eu.F & 16'hFFFD;
assign dbg_cs        = cpu.eu.CS;
assign dbg_ss        = cpu.eu.SS;
assign dbg_ds        = cpu.eu.DS;
assign dbg_es        = cpu.eu.ES;
assign dbg_ip        = ip_l;
assign dbg_pfq_top   = cpu.eu.IR;
assign dbg_dispatch  = disp;
assign dbg_rom_addr  = cpu.eu.loader_state == 2'd0 ? 13'h0006 : 13'h0100;
assign dbg_holding   = 1'b0;
assign dbg_qlen      = cpu.biu.o_qlen;
assign dbg_pc        = cpu.biu.o_pc;
assign dbg_pfq_empty = cpu.eu.q_none;

// +z86trace: one line per EU clock
reg trace_on = 1'b0;
initial if ($test$plusargs("z86trace")) trace_on = 1'b1;
always @(posedge core_clk) if (trace_on && ce)
    $display("      eu ls=%0d FC=%b SC=%b ROME=%b stall=%b busy=%b ua=%03h uc=%06h RNI=%b NXT=%b qe=%b qt=%02h IR=%02h M=%02h N=%02h",
             cpu.eu.loader_state, cpu.eu.FC, cpu.eu.SC, cpu.eu.ROME, cpu.eu.stall, cpu.eu.bus_busy,
             cpu.tables.uc_row, cpu.eu.uc, cpu.eu.RNI, cpu.eu.NXT, cpu.eu.q_empty, cpu.eu.q_top, cpu.eu.IR,
             cpu.eu.M, cpu.eu.N);

endmodule
