/////////////////////////////////////////////////////////////////////
////                                                             ////
////  pfpu32_top_marocchino                                      ////
////  32-bit floating point top level for MAROCCHINO pipeline    ////
////                                                             ////
////  Author: Andrey Bacherov                                    ////
////          avbacherov@opencores.org                           ////
////                                                             ////
/////////////////////////////////////////////////////////////////////
////                                                             ////
//// Copyright (C) 2015 Andrey Bacherov                          ////
////                    avbacherov@opencores.org                 ////
////                                                             ////
//// This source file may be used and distributed without        ////
//// restriction provided that this copyright statement is not   ////
//// removed from the file and that any derivative work contains ////
//// the original copyright notice and the associated disclaimer.////
////                                                             ////
////     THIS SOFTWARE IS PROVIDED ``AS IS'' AND WITHOUT ANY     ////
//// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED   ////
//// TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS   ////
//// FOR A PARTICULAR PURPOSE. IN NO EVENT SHALL THE AUTHOR      ////
//// OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,         ////
//// INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES    ////
//// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE   ////
//// GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR        ////
//// BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF  ////
//// LIABILITY, WHETHER IN  CONTRACT, STRICT LIABILITY, OR TORT  ////
//// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT  ////
//// OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE         ////
//// POSSIBILITY OF SUCH DAMAGE.                                 ////
////                                                             ////
/////////////////////////////////////////////////////////////////////

// fpu operations:
// ==========================
// 0000 = add,
// 0001 = substract,
// 0010 = multiply,
// 0011 = divide,
// 0100 = i2f
// 0101 = f2i
// 0110 = unused (rem)
// 0111 = reserved
// 1xxx = comparison

`include "mor1kx-defines.v"

module pfpu32_top_marocchino
(
  // clock & reset
  input                             clk,
  input                             rst,
  // pipeline control
  input                             flush_i,
  input                             padv_wb_i,
  // Operands
  input                      [31:0] rfa_i,
  input                      [31:0] rfb_i,
  // FPU-32 arithmetic part
  input     [`OR1K_FPUOP_WIDTH-1:0] op_arith_i,
  input   [`OR1K_FPCSR_RM_SIZE-1:0] round_mode_i,
  output                            fp32_arith_valid_o,    // WB-latching ahead arithmetic ready flag
  output                     [31:0] wb_fp32_arith_res_o,   // arithmetic result
  output                            wb_fp32_arith_rdy_o,   // arithmetic ready flag
  output    [`OR1K_FPCSR_WIDTH-1:0] wb_fp32_arith_fpcsr_o, // arithmetic exceptions
  // FPU-32 comparison part
  input     [`OR1K_FPUOP_WIDTH-1:0] op_cmp_i,
  output                            wb_fp32_flag_set_o,   // comparison result
  output                            wb_fp32_flag_clear_o, // comparison result
  output    [`OR1K_FPCSR_WIDTH-1:0] wb_fp32_cmp_fpcsr_o   // comparison exceptions
);

// analysis of input values
//   split input a
wire        in_signa  = rfa_i[31];
wire [7:0]  in_expa   = rfa_i[30:23];
wire [22:0] in_fracta = rfa_i[22:0];
//   detect infinity a
wire in_expa_ff = &in_expa;
wire in_infa    = in_expa_ff & (~(|in_fracta));
//   signaling NaN: exponent is 8hff, [22] is zero,
//                  rest of fract is non-zero
//   quiet NaN: exponent is 8hff, [22] is 1
wire in_snan_a = in_expa_ff & (~in_fracta[22]) & (|in_fracta[21:0]);
wire in_qnan_a = in_expa_ff &   in_fracta[22];
//   denormalized/zero of a
wire in_opa_0  = ~(|rfa_i[30:0]);
wire in_opa_dn = (~(|in_expa)) & (|in_fracta);

//   split input b
wire        in_signb  = rfb_i[31];
wire [7:0]  in_expb   = rfb_i[30:23];
wire [22:0] in_fractb = rfb_i[22:0];
//   detect infinity b
wire in_expb_ff = &in_expb;
wire in_infb    = in_expb_ff & (~(|in_fractb));
//   detect NaNs in b
wire in_snan_b = in_expb_ff & (~in_fractb[22]) & (|in_fractb[21:0]);
wire in_qnan_b = in_expb_ff &   in_fractb[22];
//   denormalized/zero of a
wire in_opb_0  = ~(|rfb_i[30:0]);
wire in_opb_dn = (~(|in_expb)) & (|in_fractb);

// detection of some exceptions
//   a nan input -> qnan output
wire in_snan = in_snan_a | in_snan_b;
wire in_qnan = in_qnan_a | in_qnan_b;
//   sign of output nan
wire in_anan_sign = (in_snan_a | in_qnan_a) ? in_signa :
                                              in_signb;

// restored exponents
wire [9:0] in_exp10a = {2'd0,in_expa[7:1],(in_expa[0] | in_opa_dn)};
wire [9:0] in_exp10b = {2'd0,in_expb[7:1],(in_expb[0] | in_opb_dn)};
// restored fractionals
wire [23:0] in_fract24a = {((~in_opa_dn) & (~in_opa_0)),in_fracta};
wire [23:0] in_fract24b = {((~in_opb_dn) & (~in_opb_0)),in_fractb};


// comparator
//   MSB (set by decode stage) indicates FPU instruction
wire op_cmp = op_cmp_i[`OR1K_FPUOP_WIDTH-1] & op_cmp_i[3];
//   Get rid of top bit to form comparison type opcode
wire [`OR1K_FPUOP_WIDTH-1:0] op_cmp_type = {1'b0,op_cmp_i[`OR1K_FPUOP_WIDTH-2:0]};
//   Support for ADD/SUB
wire addsub_agtb_o, addsub_aeqb_o;
//   Module istance
pfpu32_fcmp_marocchino u_f32_cmp
(
  // clocks, resets and other controls
  .clk                    (clk),
  .rst                    (rst),
  .flush_i                (flush_i),  // flush pipe
  .padv_wb_i              (padv_wb_i),// advance output latches
  // command
  .fpu_op_is_comp_i       (op_cmp),
  .cmp_type_i             (op_cmp_type),
  // operand 'a' related inputs
  .signa_i                (in_signa),
  .exp10a_i               (in_exp10a),
  .fract24a_i             (in_fract24a),
  .snana_i                (in_snan_a),
  .qnana_i                (in_qnan_a),
  .infa_i                 (in_infa),
  .zeroa_i                (in_opa_0),
  // operand 'b' related inputs
  .signb_i                (in_signb),
  .exp10b_i               (in_exp10b),
  .fract24b_i             (in_fract24b),
  .snanb_i                (in_snan_b),
  .qnanb_i                (in_qnan_b),
  .infb_i                 (in_infb),
  .zerob_i                (in_opb_0),
  // support addsub
  .addsub_agtb_o          (addsub_agtb_o),
  .addsub_aeqb_o          (addsub_aeqb_o),
  // outputs
  .wb_fp32_flag_set_o     (wb_fp32_flag_set_o),   // comparison result
  .wb_fp32_flag_clear_o   (wb_fp32_flag_clear_o), // comparison result
  .wb_fp32_cmp_fpcsr_o    (wb_fp32_cmp_fpcsr_o)   // comparison exceptions
);


// MSB (set by decode stage) indicates FPU instruction
wire op_arith = op_arith_i[`OR1K_FPUOP_WIDTH-1];
// alias to extract operation type
wire [3:0] op_arith_type = op_arith_i[3:0];

// advance arithmetic FPU units
wire arith_adv = ~fp32_arith_valid_o | padv_wb_i;


// addition / substraction
//   command detection
wire op_sub    = (op_arith_type == 4'd1) & op_arith;
wire op_add    = (op_arith_type == 4'd0) & op_arith;
wire add_start = op_add | op_sub;
//   connection wires
wire        add_rdy_o;       // add/sub is ready
wire        add_sign_o;      // add/sub signum
wire        add_sub_0_o;     // flag that actual substruction is performed and result is zero
wire  [4:0] add_shl_o;       // do left shift in align stage
wire  [9:0] add_exp10shl_o;  // exponent for left shift align
wire  [9:0] add_exp10sh0_o;  // exponent for no shift in align
wire [27:0] add_fract28_o;   // fractional with appended {r,s} bits
wire        add_inv_o;       // add/sub invalid operation flag
wire        add_inf_o;       // add/sub infinity output reg
wire        add_snan_o;      // add/sub signaling NaN output reg
wire        add_qnan_o;      // add/sub quiet NaN output reg
wire        add_anan_sign_o; // add/sub signum for output nan
//   module istance
pfpu32_addsub u_f32_addsub
(
  .clk              (clk),
  .rst              (rst),
  .flush_i          (flush_i),   // flush pipe
  .adv_i            (arith_adv), // advance pipe
  .start_i          (add_start), 
  .is_sub_i         (op_sub),    // 1: substruction, 0: addition
  // input 'a' related values
  .signa_i          (in_signa),
  .exp10a_i         (in_exp10a),
  .fract24a_i       (in_fract24a),
  .infa_i           (in_infa),
  // input 'b' related values
  .signb_i          (in_signb),
  .exp10b_i         (in_exp10b),
  .fract24b_i       (in_fract24b),
  .infb_i           (in_infb),
  // 'a'/'b' related
  .snan_i           (in_snan),
  .qnan_i           (in_qnan),
  .anan_sign_i      (in_anan_sign),
  .addsub_agtb_i    (addsub_agtb_o),
  .addsub_aeqb_i    (addsub_aeqb_o),
  // outputs
  .add_rdy_o        (add_rdy_o),       // add/sub is ready
  .add_sign_o       (add_sign_o),      // add/sub signum
  .add_sub_0_o      (add_sub_0_o),     // flag that actual substruction is performed and result is zero
  .add_shl_o        (add_shl_o),       // do left shift in align stage
  .add_exp10shl_o   (add_exp10shl_o),  // exponent for left shift align
  .add_exp10sh0_o   (add_exp10sh0_o),  // exponent for no shift in align
  .add_fract28_o    (add_fract28_o),   // fractional with appended {r,s} bits
  .add_inv_o        (add_inv_o),       // add/sub invalid operation flag
  .add_inf_o        (add_inf_o),       // add/sub infinity output reg
  .add_snan_o       (add_snan_o),      // add/sub signaling NaN output reg
  .add_qnan_o       (add_qnan_o),      // add/sub quiet NaN output reg
  .add_anan_sign_o  (add_anan_sign_o)  // add/sub signum for output nan
);

// MUL/DIV combined pipeline
//   command detection
wire op_mul    = (op_arith_type == 4'd2) & op_arith;
wire op_div    = (op_arith_type == 4'd3) & op_arith;
wire mul_start = op_mul | op_div;
//   MUL/DIV common outputs
wire        mul_rdy_o;       // mul is ready
wire        mul_sign_o;      // mul signum
wire  [4:0] mul_shr_o;       // do right shift in align stage
wire  [9:0] mul_exp10shr_o;  // exponent for right shift align
wire        mul_shl_o;       // do left shift in align stage
wire  [9:0] mul_exp10shl_o;  // exponent for left shift align
wire  [9:0] mul_exp10sh0_o;  // exponent for no shift in align
wire [27:0] mul_fract28_o;   // fractional with appended {r,s} bits
wire        mul_inv_o;       // mul invalid operation flag
wire        mul_inf_o;       // mul infinity output reg
wire        mul_snan_o;      // mul signaling NaN output reg
wire        mul_qnan_o;      // mul quiet NaN output reg
wire        mul_anan_sign_o; // mul signum for output nan
//   DIV additional outputs
wire        div_op_o;        // operation is division
wire        div_sign_rmnd_o; // signum or reminder for IEEE compliant rounding
wire        div_dbz_o;       // division by zero flag
//   module istance
pfpu32_muldiv u_f32_muldiv
(
  .clk                (clk),
  .rst                (rst),
  .flush_i            (flush_i),   // flush pipe
  .adv_i              (arith_adv), // advance pipe
  .start_i            (mul_start),
  .is_div_i           (op_div),
  // input 'a' related values
  .signa_i            (in_signa),
  .exp10a_i           (in_exp10a),
  .fract24a_i         (in_fract24a),
  .infa_i             (in_infa),
  .zeroa_i            (in_opa_0),
  // input 'b' related values
  .signb_i            (in_signb),
  .exp10b_i           (in_exp10b),
  .fract24b_i         (in_fract24b),
  .infb_i             (in_infb),
  .zerob_i            (in_opb_0),
  // 'a'/'b' related
  .snan_i             (in_snan),        
  .qnan_i             (in_qnan),
  .anan_sign_i        (in_anan_sign),
  // MUL/DIV common outputs
  .muldiv_rdy_o       (mul_rdy_o),       // mul is ready
  .muldiv_sign_o      (mul_sign_o),      // mul signum
  .muldiv_shr_o       (mul_shr_o),       // do right shift in align stage
  .muldiv_exp10shr_o  (mul_exp10shr_o),  // exponent for right shift align
  .muldiv_shl_o       (mul_shl_o),       // do left shift in align stage
  .muldiv_exp10shl_o  (mul_exp10shl_o),  // exponent for left shift align
  .muldiv_exp10sh0_o  (mul_exp10sh0_o),  // exponent for no shift in align
  .muldiv_fract28_o   (mul_fract28_o),   // fractional with appended {r,s} bits
  .muldiv_inv_o       (mul_inv_o),       // mul invalid operation flag
  .muldiv_inf_o       (mul_inf_o),       // mul infinity output reg
  .muldiv_snan_o      (mul_snan_o),      // mul signaling NaN output reg
  .muldiv_qnan_o      (mul_qnan_o),      // mul quiet NaN output reg
  .muldiv_anan_sign_o (mul_anan_sign_o), // mul signum for output nan
  // DIV additional outputs
  .div_op_o           (div_op_o),        // operation is division
  .div_sign_rmnd_o    (div_sign_rmnd_o), // signum of reminder for IEEE compliant rounding
  .div_dbz_o          (div_dbz_o)        // division by zero flag
);

// convertor
//   i2f command detection
wire i2f_start = (op_arith_type == 4'd4) & op_arith;
//   i2f connection wires
wire        i2f_rdy_o;       // i2f is ready
wire        i2f_sign_o;      // i2f signum
wire  [3:0] i2f_shr_o;
wire  [7:0] i2f_exp8shr_o;
wire  [4:0] i2f_shl_o;
wire  [7:0] i2f_exp8shl_o;
wire  [7:0] i2f_exp8sh0_o;
wire [31:0] i2f_fract32_o;
//   i2f module instance
pfpu32_i2f u_i2f_cnv
(
  .clk            (clk),
  .rst            (rst),
  .flush_i        (flush_i),   // flush pipe
  .adv_i          (arith_adv), // advance pipe
  .start_i        (i2f_start), // start conversion
  .opa_i          (rfa_i),
  .i2f_rdy_o      (i2f_rdy_o),     // i2f is ready
  .i2f_sign_o     (i2f_sign_o),    // i2f signum
  .i2f_shr_o      (i2f_shr_o),
  .i2f_exp8shr_o  (i2f_exp8shr_o),
  .i2f_shl_o      (i2f_shl_o),
  .i2f_exp8shl_o  (i2f_exp8shl_o),
  .i2f_exp8sh0_o  (i2f_exp8sh0_o),
  .i2f_fract32_o  (i2f_fract32_o)
);
//   f2i signals
wire f2i_start = (op_arith_type == 4'd5) & op_arith;
//   f2i connection wires
wire        f2i_rdy_o;       // f2i is ready
wire        f2i_sign_o;      // f2i signum
wire [23:0] f2i_int24_o;     // f2i fractional
wire  [4:0] f2i_shr_o;       // f2i required shift right value
wire  [3:0] f2i_shl_o;       // f2i required shift left value   
wire        f2i_ovf_o;       // f2i overflow flag
wire        f2i_snan_o;      // f2i signaling NaN output reg
//    f2i module instance
pfpu32_f2i u_f2i_cnv
(
  .clk          (clk),
  .rst          (rst),
  .flush_i      (flush_i),        // flush pipe
  .adv_i        (arith_adv),      // advance pipe
  .start_i      (f2i_start),      // start conversion
  .signa_i      (in_signa),       // input 'a' related values
  .exp10a_i     (in_exp10a),
  .fract24a_i   (in_fract24a),
  .snan_i       (in_snan),         // 'a'/'b' related
  .qnan_i       (in_qnan),
  .f2i_rdy_o    (f2i_rdy_o),       // f2i is ready
  .f2i_sign_o   (f2i_sign_o),      // f2i signum
  .f2i_int24_o  (f2i_int24_o),     // f2i fractional
  .f2i_shr_o    (f2i_shr_o),       // f2i required shift right value
  .f2i_shl_o    (f2i_shl_o),       // f2i required shift left value   
  .f2i_ovf_o    (f2i_ovf_o),       // f2i overflow flag
  .f2i_snan_o   (f2i_snan_o)       // f2i signaling NaN output reg
);


// multiplexing and rounding
pfpu32_rnd_marocchino u_f32_rnd
(
  // clocks, resets and other controls
  .clk             (clk),
  .rst             (rst),
  .flush_i         (flush_i),         // flush pipe
  .adv_i           (arith_adv),       // advance pipe
  .padv_wb_i       (padv_wb_i),       // advance output latches
  .rmode_i         (round_mode_i),    // rounding mode
  // from add/sub
  .add_rdy_i       (add_rdy_o),       // add/sub is ready
  .add_sign_i      (add_sign_o),      // add/sub signum
  .add_sub_0_i     (add_sub_0_o),     // flag that actual substruction is performed and result is zero
  .add_shl_i       (add_shl_o),       // do left shift in align stage
  .add_exp10shl_i  (add_exp10shl_o),  // exponent for left shift align
  .add_exp10sh0_i  (add_exp10sh0_o),  // exponent for no shift in align
  .add_fract28_i   (add_fract28_o),   // fractional with appended {r,s} bits
  .add_inv_i       (add_inv_o),       // add/sub invalid operation flag
  .add_inf_i       (add_inf_o),       // add/sub infinity
  .add_snan_i      (add_snan_o),      // add/sub signaling NaN
  .add_qnan_i      (add_qnan_o),      // add/sub quiet NaN
  .add_anan_sign_i (add_anan_sign_o), // add/sub signum for output nan
  // from mul
  .mul_rdy_i       (mul_rdy_o),       // mul is ready
  .mul_sign_i      (mul_sign_o),      // mul signum
  .mul_shr_i       (mul_shr_o),       // do right shift in align stage
  .mul_exp10shr_i  (mul_exp10shr_o),  // exponent for right shift align
  .mul_shl_i       (mul_shl_o),       // do left shift in align stage
  .mul_exp10shl_i  (mul_exp10shl_o),  // exponent for left shift align
  .mul_exp10sh0_i  (mul_exp10sh0_o),  // exponent for no shift in align
  .mul_fract28_i   (mul_fract28_o),   // fractional with appended {r,s} bits
  .mul_inv_i       (mul_inv_o),       // mul invalid operation flag
  .mul_inf_i       (mul_inf_o),       // mul infinity 
  .mul_snan_i      (mul_snan_o),      // mul signaling NaN
  .mul_qnan_i      (mul_qnan_o),      // mul quiet NaN
  .mul_anan_sign_i (mul_anan_sign_o), // mul signum for output nan
  .div_op_i        (div_op_o),         // MUL/DIV output is division
  .div_sign_rmnd_i (div_sign_rmnd_o),  // signum or reminder for IEEE compliant rounding
  .div_dbz_i       (div_dbz_o),        // division by zero flag
  // from i2f
  .i2f_rdy_i       (i2f_rdy_o),       // i2f is ready
  .i2f_sign_i      (i2f_sign_o),      // i2f signum
  .i2f_shr_i       (i2f_shr_o),
  .i2f_exp8shr_i   (i2f_exp8shr_o),
  .i2f_shl_i       (i2f_shl_o),
  .i2f_exp8shl_i   (i2f_exp8shl_o),
  .i2f_exp8sh0_i   (i2f_exp8sh0_o),
  .i2f_fract32_i   (i2f_fract32_o),
  // from f2i
  .f2i_rdy_i       (f2i_rdy_o),       // f2i is ready
  .f2i_sign_i      (f2i_sign_o),      // f2i signum
  .f2i_int24_i     (f2i_int24_o),     // f2i fractional
  .f2i_shr_i       (f2i_shr_o),       // f2i required shift right value
  .f2i_shl_i       (f2i_shl_o),       // f2i required shift left value   
  .f2i_ovf_i       (f2i_ovf_o),       // f2i overflow flag
  .f2i_snan_i      (f2i_snan_o),      // f2i signaling NaN
  // outputs
  .fp32_arith_valid_o     (fp32_arith_valid_o),
  .wb_fp32_arith_res_o    (wb_fp32_arith_res_o),
  .wb_fp32_arith_rdy_o    (wb_fp32_arith_rdy_o),
  .wb_fp32_arith_fpcsr_o  (wb_fp32_arith_fpcsr_o)
);

endmodule // pfpu32_top_marocchino