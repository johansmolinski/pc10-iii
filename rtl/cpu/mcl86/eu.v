//
//
//  File Name   :  mcl86_eu_core.v
//  Used on     :  
//  Author      :  Ted Fried, MicroCore Labs
//  Creation    :  10/8/2015
//  Code Type   :  Synthesizable
//
//   Description:
//   ============
//   
//  Execution Unit of the i8088 processor - Microsequencer
//
//------------------------------------------------------------------------
//
// Modification History:
// =====================
//
// Revision 1.0 10/8/15 
// Initial revision
//
// Revision 2.0 11/6/22 
// Changed overflow flag calculation into rtl instead of microcode
//
// Revision 3.0 9/29/2025 
// For DIV overflow AX and DX are restored to initial values
//
// pc10-iii (2026-10-21): 8K-word microcode ROM (EU8Kx32, read enable) and the
// SYNC microinstruction for cycle-exact timing: type 0 with a non-zero
// immediate stalls the microsequencer until
//   bit 15 = 0: the instruction has run n 8088 clocks (n = bits 11:0, counted
//               by the BIU from the cycle in which it read the opcode, input
//               EU_CYC; the EU's own dispatch may come later), or
//   bit 15 = 1: n 8088 clocks have passed since the SYNC started waiting
//               (input EU_STEP marks every 8088 clock), or
//   bit 14 = 1: n 8088 clocks have passed since the last queue read (input
//               EU_SINCE_READ; e.g. a displacement after the ModR/M byte), or
//   bits 15:14 = 11: n 8088 clocks have passed since the last EU bus
//               transfer ended (input EU_SINCE_DONE).
// Type 0 with immediate 0 stays a NOP. Note that the microcode addresses
// 0x09C9, 0x0A03, 0x0E76, 0x0F02 and 0x0F11 are compared below; code there
// must not move.
//
//
//------------------------------------------------------------------------
//
// Copyright (c) 2020 Ted Fried
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
//------------------------------------------------------------------------


module mcl86_eu_core
  (  
    input               CORE_CLK_INT,           // Core Clock
    input               RESET_INT,              // Pipelined 8088 RESET pin
    input               TEST_N_INT,             // Pipelined 8088 TEST_n pin
    input               EU_STEP,                // pc10-iii: one CORE_CLK per 8088 clock
    input      [11:0]   EU_CYC,                 // pc10-iii: 8088 clocks since the opcode read (BIU)
    input      [11:0]   EU_SINCE_READ,          // pc10-iii: 8088 clocks since the last queue read (BIU)
    input      [11:0]   EU_SINCE_DONE,          // pc10-iii: 8088 clocks since an EU transfer ended (BIU)
    input               EU_SR_PENDING,          // pc10-iii: the BIU's scheduled read is pending (system_signals[14])
    output     [1:0]    EU_QREAD,               // pc10-iii: the EU uses the queue top: 01 opcode, 11 other

    
    output [15:0]       EU_BIU_COMMAND,         // EU to BIU Signals
    output [15:0]       EU_BIU_DATAOUT,         
    output [15:0]       EU_REGISTER_R3, 
    output              EU_PREFIX_LOCK,
    output              EU_FLAG_I,          
    
    
    input               BIU_DONE,               // BIU to EU Signals
    input               BIU_CLK_COUNTER_ZERO,
    input               BIU_NMI_CAUGHT,
    output              BIU_NMI_DEBOUNCE,
    input               BIU_INTR,

    
    input [7:0]         PFQ_TOP_BYTE,
    input               PFQ_EMPTY,
    input[15:0]         PFQ_ADDR_OUT,

    
    input [15:0]        BIU_REGISTER_ES,
    input [15:0]        BIU_REGISTER_SS,
    input [15:0]        BIU_REGISTER_CS,
    input [15:0]        BIU_REGISTER_DS,
    input [15:0]        BIU_REGISTER_RM,
    input [15:0]        BIU_REGISTER_REG,
    input [15:0]        BIU_RETURN_DATA

  );

//------------------------------------------------------------------------
      

// Internal Signals

reg  eu_add_carry;
reg  eu_add_carry8;
reg  eu_add_aux_carry;
reg  eu_add_overflow16;
reg  eu_add_overflow8;
reg  eu_stall_pipeline;
reg  eu_flag_t_d;
reg  biu_done_d1;
reg  biu_done_d2;
reg  eu_tr_latched;
reg  biu_done_caught;
reg  eu_biu_req_d1;
reg  intr_enable_delayed;
reg  eu_overflow_override;
reg  eu_add_overflow8_fixed;
reg  eu_add_overflow16_fixed;
reg  idiv_opcode;
wire eu_prefix_rep;
wire eu_prefix_repnz;
wire eu_tf_debounce;
wire eu_prefix_lock;
wire eu_biu_req;
wire eu_parity;
wire eu_flag_o;
wire eu_flag_d;
wire eu_flag_i;
wire eu_flag_t; 
wire eu_flag_s;
wire eu_flag_z;
wire eu_flag_a;
wire eu_flag_p;
wire eu_flag_c;
wire eu_opcode_jump_call;
wire intr_asserted;
wire eu_jump_boolean;
reg  [12:0] eu_rom_address;
reg  [11:0] eu_sync_rel;            // pc10-iii: relative SYNC countdown
reg         eu_sync_armed;
reg         new_instruction_d1;
wire        eu_sync_wait;
reg  [51:0] eu_calling_address;
reg  [15:0] eu_register_ax;
reg  [15:0] initial_ax;
reg  [15:0] eu_register_bx;
reg  [15:0] eu_register_cx;
reg  [15:0] eu_register_dx;
reg  [15:0] initial_dx;
reg  [15:0] eu_register_sp;
reg  [15:0] eu_register_bp;
reg  [15:0] eu_register_si;
reg  [15:0] eu_register_di;
reg  [15:0] eu_flags;
reg  [15:0] eu_register_r0;
reg  [15:0] eu_register_r1;
reg  [15:0] eu_register_r2;
reg  [15:0] eu_register_r3;
reg  [15:0] eu_biu_command;
reg  [15:0] eu_biu_dataout;
reg  [15:0] eu_alu_last_result;
wire [15:0] adder_out;
wire [16:0] carry;
wire [2:0]  eu_opcode_type;
wire [3:0]  eu_opcode_dst_sel;
wire [3:0]  eu_opcode_op0_sel;
wire [3:0]  eu_opcode_op1_sel;
wire [15:0] eu_opcode_immediate;
wire [2:0]  eu_opcode_jump_src;
wire [3:0]  eu_opcode_jump_cond;
wire [15:0] system_signals;
wire [15:0] eu_alu2;
wire [15:0] eu_alu3;
wire [15:0] eu_alu4;
wire [15:0] eu_alu5;
wire [15:0] eu_alu6;
wire [15:0] eu_alu7;
wire [15:0] eu_alu_out;
wire [15:0] eu_operand0;
wire [15:0] eu_operand1;
wire [31:0] eu_rom_data;
wire [15:0] add_total;
wire [15:0] sub_total;
wire [15:0] adc_total;
wire [15:0] sbb_total;




//------------------------------------------------------------------------
//
// EU Microcode RAM.  4Kx32 DPRAM
//
//------------------------------------------------------------------------                                    

EU8Kx32      EU8Kx32_i (
  
  .clka     (CORE_CLK_INT),
  .ena      (~eu_sync_wait),
  .addra    (eu_rom_address[12:0]),
  .douta    (eu_rom_data)
  
  );

  
  
//------------------------------------------------------------------------
//
// Combinationals
//
//------------------------------------------------------------------------

assign EU_BIU_COMMAND       = eu_biu_command;
assign EU_BIU_DATAOUT       = eu_biu_dataout;
assign EU_REGISTER_R3       = eu_register_r3;
assign EU_FLAG_I            = intr_enable_delayed;
assign EU_PREFIX_LOCK       = eu_prefix_lock;


// EU ROM opcode decoder
assign eu_opcode_type       = eu_rom_data[30:28];
assign eu_opcode_dst_sel    = eu_rom_data[27:24];
assign eu_opcode_op0_sel    = eu_rom_data[23:20];
assign eu_opcode_op1_sel    = eu_rom_data[19:16];
assign eu_opcode_immediate  = eu_rom_data[15:0];

assign eu_opcode_jump_call  = eu_rom_data[24];
assign eu_opcode_jump_src   = eu_rom_data[22:20];
assign eu_opcode_jump_cond  = eu_rom_data[19:16];



assign  eu_operand0 = (eu_opcode_op0_sel==4'h0) ? eu_register_ax  :
                      (eu_opcode_op0_sel==4'h1) ? eu_register_bx  :
                      (eu_opcode_op0_sel==4'h2) ? eu_register_cx  :
                      (eu_opcode_op0_sel==4'h3) ? eu_register_dx  :
                      (eu_opcode_op0_sel==4'h4) ? eu_register_sp  :
                      (eu_opcode_op0_sel==4'h5) ? eu_register_bp  :
                      (eu_opcode_op0_sel==4'h6) ? eu_register_si  :
                      (eu_opcode_op0_sel==4'h7) ? eu_register_di  :
                      (eu_opcode_op0_sel==4'h8) ? eu_flags        :
                      (eu_opcode_op0_sel==4'h9) ? eu_register_r0  :
                      (eu_opcode_op0_sel==4'hA) ? eu_register_r1  :
                      (eu_opcode_op0_sel==4'hB) ? eu_register_r2  :
                      (eu_opcode_op0_sel==4'hC) ? eu_register_r3  :
                      (eu_opcode_op0_sel==4'hD) ? eu_biu_command  :
                      (eu_opcode_op0_sel==4'hE) ? system_signals  :
                                                  16'h0           ;

                                                 
assign  eu_operand1 = (eu_opcode_op1_sel==4'h0) ? BIU_REGISTER_ES     :
                      (eu_opcode_op1_sel==4'h1) ? BIU_REGISTER_SS     :
                      (eu_opcode_op1_sel==4'h2) ? BIU_REGISTER_CS     :
                      (eu_opcode_op1_sel==4'h3) ? BIU_REGISTER_DS     :
                      (eu_opcode_op1_sel==4'h4) ? { 8'h00 , PFQ_TOP_BYTE }  :
                      (eu_opcode_op1_sel==4'h5) ? BIU_REGISTER_RM     :
                      (eu_opcode_op1_sel==4'h6) ? BIU_REGISTER_REG    :
                      (eu_opcode_op1_sel==4'h7) ? BIU_RETURN_DATA     :
                      (eu_opcode_op1_sel==4'h8) ? PFQ_ADDR_OUT        :
                      (eu_opcode_op1_sel==4'h9) ? eu_register_r0      :
                      (eu_opcode_op1_sel==4'hA) ? eu_register_r1      :
                      (eu_opcode_op1_sel==4'hB) ? eu_register_r2      :
                      (eu_opcode_op1_sel==4'hC) ? eu_register_r3      :
                      (eu_opcode_op1_sel==4'hD) ? eu_alu_last_result  :  
                      (eu_opcode_op1_sel==4'hE) ? system_signals      :
                                                  eu_opcode_immediate ;



// JUMP condition codes
assign eu_jump_boolean = ( (idiv_opcode=='h1) && (eu_rom_address == 'h0E76) && (eu_register_ax[15:7]!='h0)) ? 1'b1 :
                         ( (idiv_opcode=='h1) && (eu_rom_address == 'h0F02) && ( (eu_register_dx!='h0) || (eu_register_ax[15]!='h0) )) ? 1'b1 :
                         (eu_opcode_jump_cond==4'h0)                               ? 1'b1 : // unconditional jump
                         (eu_opcode_jump_cond==4'h1 && eu_alu_last_result!=16'h0)  ? 1'b1 : 
                         (eu_opcode_jump_cond==4'h2 && eu_alu_last_result==16'h0)  ? 1'b1 : 
                                                                                     1'b0 ;

	  
	  
                                                  
// Consolidated system signals
assign system_signals[14]   = EU_SR_PENDING;     // pc10-iii
assign system_signals[13]   = eu_add_carry8;      
assign system_signals[12]   = BIU_CLK_COUNTER_ZERO;   
assign system_signals[11]   = eu_add_overflow16;      
assign system_signals[9]    = eu_add_overflow8;   
assign system_signals[8]    = eu_tr_latched;
assign system_signals[7]    = ~PFQ_EMPTY;     
assign system_signals[6]    = biu_done_caught;    
assign system_signals[5]    = TEST_N_INT;     
assign system_signals[4]    = eu_add_aux_carry;   
assign system_signals[3]    = BIU_NMI_CAUGHT;     
assign system_signals[2]    = eu_parity;      
assign system_signals[1]    = intr_asserted;      
assign system_signals[0]    = eu_add_carry;   


assign eu_prefix_repnz      = eu_flags[15];
assign eu_prefix_rep        = eu_flags[14];
assign eu_prefix_lock       = eu_flags[13];
assign BIU_NMI_DEBOUNCE     = eu_flags[12];
assign eu_flag_o            = eu_flags[11];
assign eu_flag_d            = eu_flags[10];
assign eu_flag_i            = eu_flags[9];
assign eu_flag_t            = eu_flags[8];
assign eu_flag_s            = eu_flags[7];
assign eu_flag_z            = eu_flags[6];
assign eu_tf_debounce       = eu_flags[5];
assign eu_flag_a            = eu_flags[4];
assign eu_nmi_pending       = eu_flags[3];
assign eu_flag_p            = eu_flags[2];
assign eu_flag_temp         = eu_flags[1];
assign eu_flag_c            = eu_flags[0];



// EU ALU Operations
// ------------------------------------------
//     eu_alu0 = NOP
//     eu_alu1 = JUMP
assign eu_alu2 = adder_out;                                     // ADD
assign eu_alu3 = { eu_operand0[7:0] , eu_operand0[15:8] };      // BYTESWAP
assign eu_alu4 = eu_operand0 & eu_operand1;                     // AND
assign eu_alu5 = eu_operand0 | eu_operand1;                     // OR
assign eu_alu6 = eu_operand0 ^ eu_operand1;                     // XOR
assign eu_alu7 = { 1'b0 , eu_operand0[15:1] };                  // SHR




// Mux the ALU operations
assign eu_alu_out = (eu_opcode_type==3'h2) ? eu_alu2 :   
                    (eu_opcode_type==3'h3) ? eu_alu3 :
                    (eu_opcode_type==3'h4) ? eu_alu4 :
                    (eu_opcode_type==3'h5) ? eu_alu5 :
                    (eu_opcode_type==3'h6) ? eu_alu6 :
                    (eu_opcode_type==3'h7) ? eu_alu7 :
                                             20'hEEEEE;

    
  


// Generate 16-bit full adder for the EU
// pc10-iii (100 MHz): one adder (a carry chain) instead of the ripple of
// full adders in LUTs; the carry into bit i is a[i] ^ b[i] ^ sum[i], the same
// bits as before.
//assign carry[0] = 1'b0;
//genvar i;
//generate
//  for (i=0; i < 16; i=i+1) 
//    begin : GEN_ADDER
//      assign adder_out[i] =  eu_operand0[i] ^ eu_operand1[i] ^ carry[i];     
//      assign carry[i+1]   = (eu_operand0[i] & eu_operand1[i]) | (eu_operand0[i] & carry[i]) | (eu_operand1[i] & carry[i]);  
//    end
//endgenerate
wire [16:0] adder_sum = {1'b0, eu_operand0} + {1'b0, eu_operand1};
assign adder_out  = adder_sum[15:0];
assign carry[0]   = 1'b0;
assign carry[15:1] = eu_operand0[15:1] ^ eu_operand1[15:1] ^ adder_sum[15:1];
assign carry[16]  = adder_sum[16];

assign eu_parity = ~(eu_alu_last_result[0]^eu_alu_last_result[1]^eu_alu_last_result[2]^eu_alu_last_result[3]^eu_alu_last_result[4]^eu_alu_last_result[5]^eu_alu_last_result[6]^eu_alu_last_result[7]);


assign eu_biu_req                      = eu_biu_command[9];

assign intr_asserted = BIU_INTR & intr_enable_delayed;


assign new_instruction = (eu_rom_address[12:8]==5'h01) ? 1'b1 : 1'b0;   

// pc10-iii: SYNC - a type 0 microinstruction with a non-zero immediate waits
wire eu_is_sync   = eu_opcode_type==3'h0 && eu_rom_data[31]==1'b0 &&
                    eu_opcode_immediate!=16'h0 && eu_stall_pipeline==1'b0;
wire eu_sync_done = eu_opcode_immediate[15:14]==2'b11 ?
                        (EU_SINCE_DONE >= eu_opcode_immediate[11:0]) :
                    eu_opcode_immediate[15] ?
                        (eu_sync_armed && eu_sync_rel==12'h0) :
                    eu_opcode_immediate[14] ?
                        (EU_SINCE_READ >= eu_opcode_immediate[11:0]) :
                        (EU_CYC >= eu_opcode_immediate[11:0]);
assign eu_sync_wait = eu_is_sync && !eu_sync_done;

// pc10-iii: the EU uses the byte on top of the queue. The first use of a byte
// is the real chip's queue read (the BIU reports it on QS): a jump through the
// opcode table (source 1) reads an opcode or prefix; the ModR/M jump (source 2)
// or any operand from PFQ_TOP_BYTE reads a subsequent byte.
// pc10-iii (100 MHz): the same decode from registers, as directly as
// possible (the BIU acts on it in the same clock):
// - a SYNC is a type 0 microinstruction: whenever the type below is not 0,
//   eu_sync_wait is 0, so it is left out;
// - eu_jump_boolean with eu_alu_last_nz (= eu_alu_last_result != 0, kept as
//   a register), and its two IDIV terms with eu_q_at_0E75/eu_q_at_0F01: the
//   microinstruction in eu_rom_data comes from the address before
//   eu_rom_address whenever the pipeline does not stall (a stall follows
//   every jump; a SYNC holds both), so eu_rom_address == 0x0E76 there is the
//   word read from 0x0E75, which those registers note when it is read.
reg  eu_alu_last_nz;
reg  eu_q_at_0E75, eu_q_at_0F01;
wire eu_ax_hi_nz = eu_register_ax[15:7]!='h0;
wire eu_dx_ax_ov = eu_register_dx!='h0 || eu_register_ax[15]!='h0;
wire eu_jump_boolean_q = ( (idiv_opcode=='h1) && eu_q_at_0E75 && eu_ax_hi_nz ) ? 1'b1 :
                         ( (idiv_opcode=='h1) && eu_q_at_0F01 && eu_dx_ax_ov ) ? 1'b1 :
                         (eu_opcode_jump_cond==4'h0)                           ? 1'b1 :
                         (eu_opcode_jump_cond==4'h1 && eu_alu_last_nz)         ? 1'b1 :
                         (eu_opcode_jump_cond==4'h2 && !eu_alu_last_nz)        ? 1'b1 :
                                                                                 1'b0 ;
wire eu_uop_live = eu_stall_pipeline==1'b0;
assign EU_QREAD = (eu_uop_live && eu_opcode_type==3'h1 && eu_jump_boolean_q &&
                   eu_opcode_jump_src==3'h1)                              ? 2'b01 :
                  (eu_uop_live && eu_opcode_type==3'h1 && eu_jump_boolean_q &&
                   eu_opcode_jump_src==3'h2)                              ? 2'b11 :
                  (eu_uop_live && eu_opcode_type!=3'h0 && eu_opcode_type!=3'h1 &&
                   eu_opcode_op1_sel==4'h4)                               ? 2'b11 :
                                                                            2'b00 ;

        
assign add_total = eu_register_r0 + eu_register_r1;
assign adc_total = eu_register_r0 + eu_register_r1 + eu_flag_c;
assign sub_total = eu_register_r0 - eu_register_r1;
assign sbb_total = eu_register_r0 - eu_register_r1 - eu_flag_c;


//------------------------------------------------------------------------------------------  
//
// EU Microsequencer
//
//------------------------------------------------------------------------------------------

always @(posedge CORE_CLK_INT)
begin : EU_MICROSEQUENCER

  if (RESET_INT==1'b1)
    begin
      biu_done_d1 <= 'h0;
      biu_done_d2 <= 'h0;
      eu_biu_req_d1 <= 'h0;
      biu_done_caught <= 'h0;
      eu_flag_t_d <= 'h0;
      eu_tr_latched <= 'h0;
      eu_add_carry <= 'h0;
      eu_add_carry8 <= 'h0;
      eu_add_aux_carry <= 'h0;
      eu_add_overflow16 <= 'h0;
      eu_add_overflow8 <= 'h0;
      eu_alu_last_result <= 'h0;
      eu_register_ax  <= 'h0;
      eu_register_bx  <= 'h0;
      eu_register_cx  <= 'h0;
      eu_register_dx  <= 'h0;
      eu_register_sp  <= 'h0;
      eu_register_bp  <= 'h0;
      eu_register_si  <= 'h0;
      eu_register_di  <= 'h0;
      eu_flags <= 'h0;
      eu_register_r0 <= 'h0;
      eu_register_r1 <= 'h0;
      eu_register_r2 <= 'h0;
      eu_register_r3 <= 'h0;
      eu_biu_command <= 'h0;
      eu_biu_dataout <= 'h0;
      eu_stall_pipeline <= 'h0;
      eu_rom_address <= 13'h0020;
      eu_calling_address <= 'h0;
      eu_sync_rel <= 'h0;
      eu_sync_armed <= 1'b0;
      new_instruction_d1 <= 1'b0;
      eu_alu_last_nz <= 1'b0;
      eu_q_at_0E75 <= 1'b0;
      eu_q_at_0F01 <= 1'b0;
      intr_enable_delayed <= 1'b0;
	  idiv_opcode <= 'h0;
    end
    
else    
  begin     
  
    // pc10-iii: relative SYNC
    new_instruction_d1 <= new_instruction;
    // pc10-iii: the ROM word now read comes from 0x0E75 / 0x0F01 (see EU_QREAD)
    if (eu_sync_wait==1'b0)
      begin
        eu_q_at_0E75 <= eu_rom_address == 13'h0E75;
        eu_q_at_0F01 <= eu_rom_address == 13'h0F01;
      end
    if (eu_is_sync==1'b1 && eu_opcode_immediate[15:14]==2'b10 && eu_sync_armed==1'b0)
      begin
        eu_sync_armed <= 1'b1;
        eu_sync_rel   <= eu_opcode_immediate[11:0];
      end
    else if (eu_is_sync==1'b1 && eu_sync_done==1'b1)
      eu_sync_armed <= 1'b0;
    else if (EU_STEP==1'b1 && eu_sync_rel!=12'h0)
      eu_sync_rel <= eu_sync_rel - 1'b1;

    // Delay the INTR enable flag until after the next instruction begins.
    // No delay when it is disabled.
    if (eu_flag_i==1'b0)
      begin
        intr_enable_delayed <= 1'b0;
      end
    else
    if (new_instruction==1'b1)
      begin
        intr_enable_delayed <= eu_flag_i;
      end
      
    // Latch the TF flag on its rising edge.
    eu_flag_t_d <= eu_flag_t;
    if (eu_flag_t_d==1'b0 && eu_flag_t==1'b1) 
      begin
        eu_tr_latched <= 1'b1;
      end
    else if (eu_tf_debounce==1'b1)
      begin
        eu_tr_latched <= 1'b0;
      end
        
        
        
    // Latch the done bit from the biu.
    // Debounce it when the request is released.
    biu_done_d1 <= BIU_DONE;
    biu_done_d2 <= biu_done_d1;
    eu_biu_req_d1 <= eu_biu_req;    
    if (biu_done_d2==1'b0 && biu_done_d1==1'b1)
      biu_done_caught <= 1'b1;
    else if (eu_biu_req_d1==1'b1 && eu_biu_req==1'b0)
      biu_done_caught <= 1'b0;
           

    // ADD - Byte
    //
    if (eu_rom_address == 16'h09C9)
      begin
        eu_overflow_override <= 1'b1;
           
       if ( ( (eu_register_r0[7]==1'b0) && (eu_register_r1[7]==1'b0) && (add_total[7]==1'b1) ) ||
            ( (eu_register_r0[7]==1'b1) && (eu_register_r1[7]==1'b1) && (add_total[7]==1'b0) ) )
         begin
           eu_add_overflow8_fixed <= 1'b1;
         end
       else
          begin
           eu_add_overflow8_fixed <= 1'b0;
         end
      end			  
			  
    // ADC - Byte
    //
    if (eu_rom_address == 16'h0A03)
      begin
        eu_overflow_override <= 1'b1;
           
       if ( ( (eu_register_r0[7]==1'b0) && (eu_register_r1[7]==1'b0) && (adc_total[7]==1'b1) ) ||
            ( (eu_register_r0[7]==1'b1) && (eu_register_r1[7]==1'b1) && (adc_total[7]==1'b0) ) )
         begin
           eu_add_overflow8_fixed <= 1'b1;
         end
       else
          begin
           eu_add_overflow8_fixed <= 1'b0;
         end
      end

    // SUB - Byte
    //
    if (eu_rom_address == 16'h0A46)
      begin
        eu_overflow_override <= 1'b1;
       
       if ( ( (eu_register_r0[7]==1'b0) && (eu_register_r1[7]==1'b1) && (sub_total[7]==1'b1) ) ||
            ( (eu_register_r0[7]==1'b1) && (eu_register_r1[7]==1'b0) && (sub_total[7]==1'b0) ) )
          begin
           eu_add_overflow8_fixed <= 1'b1;
         end
       else
          begin
           eu_add_overflow8_fixed <= 1'b0;
         end
      end
  
    // SBB - Byte
    //
    if (eu_rom_address == 16'h0AAE)
      begin
        eu_overflow_override <= 1'b1;
       
       if ( ( (eu_register_r0[7]==1'b0) && (eu_register_r1[7]==1'b1) && (sbb_total[7]==1'b1) ) ||
            ( (eu_register_r0[7]==1'b1) && (eu_register_r1[7]==1'b0) && (sbb_total[7]==1'b0) ) )
          begin
           eu_add_overflow8_fixed <= 1'b1;
         end
       else
          begin
           eu_add_overflow8_fixed <= 1'b0;
         end
      end 

    // ADD - Word
    //
    if (eu_rom_address == 16'h09CC)
      begin
        eu_overflow_override <= 1'b1;
           
       if ( ( (eu_register_r0[15]==1'b0) && (eu_register_r1[15]==1'b0) && (add_total[15]==1'b1) ) ||
            ( (eu_register_r0[15]==1'b1) && (eu_register_r1[15]==1'b1) && (add_total[15]==1'b0) ) )
         begin
           eu_add_overflow16_fixed <= 1'b1;
         end
       else
          begin
           eu_add_overflow16_fixed <= 1'b0;
         end
      end
  
    // ADC - Word
    //
    if (eu_rom_address == 16'h0A12)
      begin
        eu_overflow_override <= 1'b1;
           
       if ( ( (eu_register_r0[15]==1'b0) && (eu_register_r1[15]==1'b0) && (adc_total[15]==1'b1) ) ||
            ( (eu_register_r0[15]==1'b1) && (eu_register_r1[15]==1'b1) && (adc_total[15]==1'b0) ) )
         begin
           eu_add_overflow16_fixed <= 1'b1;
         end
       else
          begin
           eu_add_overflow16_fixed <= 1'b0;
         end
      end

    // SUB - Word
    //
    if (eu_rom_address == 16'h0A52)
      begin
        eu_overflow_override <= 1'b1;
       
       if ( ( (eu_register_r0[15]==1'b0) && (eu_register_r1[15]==1'b1) && (sub_total[15]==1'b1) ) ||
            ( (eu_register_r0[15]==1'b1) && (eu_register_r1[15]==1'b0) && (sub_total[15]==1'b0) ) )
          begin
           eu_add_overflow16_fixed <= 1'b1;
         end
       else
          begin
           eu_add_overflow16_fixed <= 1'b0;
         end
      end
  
    // SBB - Word
    //
    if (eu_rom_address == 16'h0ABA)
      begin
        eu_overflow_override <= 1'b1;
       
       if ( ( (eu_register_r0[15]==1'b0) && (eu_register_r1[15]==1'b1) && (sbb_total[15]==1'b1) ) ||
            ( (eu_register_r0[15]==1'b1) && (eu_register_r1[15]==1'b0) && (sbb_total[15]==1'b0) ) )
          begin
           eu_add_overflow16_fixed <= 1'b1;
         end
       else
          begin
           eu_add_overflow16_fixed <= 1'b0;
         end
      end
  
  
    // Debounce the overflow flag override when microcode returns to the main loop
	// Store initial values of AX and DX
	//
	if (eu_rom_address == 'h0011)
	  begin
	    eu_overflow_override <= 1'b0;
	    initial_ax <= eu_register_ax;
	    initial_dx <= eu_register_dx;
		idiv_opcode <= 'h0;
	  end
  
  	if ( (eu_rom_address=='h0E54) || (eu_rom_address=='h0ED0) )
	  begin
	    idiv_opcode <= 'h1;
	  end

           
    // Generate and store flags for addition
    if (eu_stall_pipeline==1'b0 && eu_opcode_type==3'h2)
      begin
        eu_add_carry       <= carry[16];
        eu_add_carry8      <= carry[8];
        eu_add_aux_carry   <= carry[4];
        eu_add_overflow16  <= (eu_overflow_override==1'b1) ? eu_add_overflow16_fixed : (carry[16] ^ carry[15]);
        eu_add_overflow8   <= (eu_overflow_override==1'b1) ? eu_add_overflow8_fixed  : (carry[8]  ^ carry[7] );         
      end

    
    // Register writeback   
    if (eu_stall_pipeline==1'b0 && eu_opcode_type!=3'h0 && eu_opcode_type!=3'h1) 
      begin       
        eu_alu_last_result <= eu_alu_out[15:0];
        eu_alu_last_nz     <= eu_alu_out[15:0] != 16'h0;    // pc10-iii
        case (eu_opcode_dst_sel)  // synthesis parallel_case
          4'h0 : eu_register_ax   <= eu_alu_out[15:0];
          4'h1 : eu_register_bx   <= eu_alu_out[15:0];
          4'h2 : eu_register_cx   <= eu_alu_out[15:0];
          4'h3 : eu_register_dx   <= eu_alu_out[15:0];
          4'h4 : eu_register_sp   <= eu_alu_out[15:0];
          4'h5 : eu_register_bp   <= eu_alu_out[15:0];
          4'h6 : eu_register_si   <= eu_alu_out[15:0];
          4'h7 : eu_register_di   <= eu_alu_out[15:0];
          4'h8 : eu_flags         <= eu_alu_out[15:0];
          4'h9 : eu_register_r0   <= eu_alu_out[15:0];
          4'hA : eu_register_r1   <= eu_alu_out[15:0];
          4'hB : eu_register_r2   <= eu_alu_out[15:0];
          4'hC : eu_register_r3   <= eu_alu_out[15:0];
          4'hD : eu_biu_command   <= eu_alu_out[15:0];
          //4'hE : ;             
          4'hF : eu_biu_dataout   <= eu_alu_out[15:0];
          default :  ;
        endcase
    end
	
	// Restore initial values of AX and DX upon entering overflow DIV0 microcode
	//
	if (eu_rom_address == 'h0F11)
	  begin
	    eu_register_ax <= initial_ax;
	    eu_register_dx <= initial_dx;
	  end
  

    // JUMP Opcode
    if (eu_stall_pipeline==1'b0 && eu_opcode_type==3'h1 && eu_jump_boolean==1'b1)
      begin
        eu_stall_pipeline <= 1'b1;
          
         // For subroutine CALLs, store next opcode address
        if (eu_opcode_jump_call==1'b1)
          begin
            eu_calling_address[51:0] <= {eu_calling_address[38:0] , eu_rom_address[12:0] };  // 4 deep calling addresses
          end           

        case (eu_opcode_jump_src)  // synthesis parallel_case
          3'h0 : eu_rom_address <= eu_opcode_immediate[12:0];
          3'h1 : eu_rom_address <= { 4'b0 , 1'b1 , PFQ_TOP_BYTE }; // If only used for primary opcode jump, maybe make fixed prepend rather than immediate value prepend?
          3'h2 : eu_rom_address <= { eu_opcode_immediate[4:0], PFQ_TOP_BYTE[7:6] , PFQ_TOP_BYTE[2:0] , 3'b000 }; // Rearranged mod_reg_rm byte - imm,MOD,RM,000
          3'h3 : begin
                   eu_rom_address <= eu_calling_address[12:0];
                   eu_calling_address[38:0] <= eu_calling_address[51:13];
                 end
          3'h4 : eu_rom_address <= { eu_opcode_immediate[7:0],  eu_biu_dataout[3:0] , 1'b0 };  // Jump table for EA register fetch decoding.  Jump Addresses decoded from biu_dataout.
          3'h5 : eu_rom_address <= { eu_opcode_immediate[6:0],  eu_biu_dataout[3:0] , 2'b00 }; // Jump table for EA register writeback decoding.  Jump Addresses decoded from biu_dataout.
          3'h6 : eu_rom_address <= { eu_opcode_immediate[12:3], eu_biu_dataout[5:3] };         // Jump table for instructions that share same opcode and decode using the REG field.
                     
          default :  ;
        endcase 
      end
                
    else if (eu_sync_wait==1'b0)   // pc10-iii: SYNC holds address and ROM output
      begin
        eu_stall_pipeline <= 1'b0; // Debounce the pipeline stall
        eu_rom_address <= eu_rom_address + 1'b1; 
      end
   
end
end // EU Microsequencer



 
endmodule // eu.v
