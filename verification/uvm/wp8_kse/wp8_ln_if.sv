`timescale 1ns/1ps
// KSNUM-012: pin-level interface of kse_ln_core (residual + LayerNorm).
interface wp8_ln_if(input logic clk, input logic rst_n);
  logic signed [7:0] ax, ay, vsh, nsh, ash;
  logic [15:0]       eps;
  logic [64*16-1:0]  gamma;
  logic [64*8-1:0]   beta;
  logic              in_valid, in_half;
  logic [255:0]      in_x, in_y;
  wire               tok_ready, buf_free;
  wire               out_valid, out_half, res_valid, res_half;
  wire [255:0]       out_data, res_data;
  clocking mon_cb @(posedge clk);
    input tok_ready, buf_free, out_valid, out_half, out_data, res_valid, res_half, res_data, in_valid, in_half;
  endclocking
endinterface
