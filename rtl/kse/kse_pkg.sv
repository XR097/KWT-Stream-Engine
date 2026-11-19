`default_nettype none
// KSE constants: phases and row-store map (rows of 32 bytes).
package kse_pkg;
  localparam int T = 99;      // tokens
  localparam int D = 64;      // model width
  localparam int F = 256;     // MLP width

  localparam logic MEM_A = 1'b0;
  localparam logic MEM_B = 1'b1;

  // row store A
  localparam logic [9:0] A_X   = 10'd0;    // X / X1 / next X : 2 rows per token
  localparam logic [9:0] A_S   = 10'd200;  // scores S       : 4 rows per query
  localparam logic [9:0] A_CTX = 10'd600;  // context        : 2 rows per token
  localparam logic [9:0] A_F2  = 10'd800;  // fc2 output     : 2 rows per token
  // row store B
  localparam logic [9:0] B_Q   = 10'd0;    // Q (K at +200, V at +400): 2 rows per token
  localparam logic [9:0] B_K   = 10'd200;
  localparam logic [9:0] B_V   = 10'd400;
  localparam logic [9:0] B_P   = 10'd600;  // probabilities  : 4 rows per query (600..995)
  localparam logic [9:0] B_PJ  = 10'd0;    // proj output    : 2 rows per token
  localparam logic [9:0] B_H   = 10'd200;  // GELU output H  : 8 rows per token

  localparam logic [3:0] PH_IDLE = 4'd0;
  localparam logic [3:0] PH_IN   = 4'd1;
  localparam logic [3:0] PH_QKV  = 4'd2;
  localparam logic [3:0] PH_SC   = 4'd3;
  localparam logic [3:0] PH_SM   = 4'd4;
  localparam logic [3:0] PH_PV   = 4'd5;
  localparam logic [3:0] PH_PJ   = 4'd6;
  localparam logic [3:0] PH_LN1  = 4'd7;
  localparam logic [3:0] PH_FC1  = 4'd8;
  localparam logic [3:0] PH_FC2  = 4'd9;
  localparam logic [3:0] PH_LN2  = 4'd10;
  localparam logic [3:0] PH_OUT  = 4'd11;
  localparam logic [3:0] PH_FIN  = 4'd12;
endpackage
`default_nettype wire
