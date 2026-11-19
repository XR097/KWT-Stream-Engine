`timescale 1ns/1ps
interface kse_numeric_if(input logic clk,input logic rst_n);
  logic enabled,fire;
  logic [3:0] op;
  logic [63:0] a,b,c,d,e,f;
  wire [31:0] shifted;
  wire [7:0] saturated,gelu;
  wire [15:0] exp_rom,exp_lane;
  wire div_sm_v,div_sm_ovf,div_ln_v,div_ln_ovf;
  wire [8:0] div_sm_q;
  wire [30:0] div_ln_q;
  wire [15:0] div_sm_tag,div_ln_tag;
  wire [17:0] sqrt2,sqrt3;
  wire sqrt2_busy,sqrt3_busy,sqrt2_done,sqrt3_done;
  wire [7:0] post_pre,post_y;
endinterface
