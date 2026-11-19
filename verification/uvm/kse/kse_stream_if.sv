`timescale 1ns/1ps
// Drivers use falling edges; monitors sample the actual accepting rising edge.
interface kse_stream_if(input logic clk, input logic rst_n);
  logic cmd_valid, cmd_ready, cmd_in_en, cmd_out_en;
  logic [3:0] cmd_layer;
  logic param_valid, param_ready;
  logic [31:0] param_data;
  logic act_in_valid, act_in_ready, act_out_valid, act_out_ready;
  logic [31:0] act_in_data, act_out_data;
  logic done, busy;
  // Read-only observation of synthesized signals, never used as expected data.
  wire [3:0] phase;
  wire a_en, a_we, b_en, b_we;
  wire [9:0] a_addr, b_addr;
  wire [255:0] a_wdata, b_wdata, tap_pre, tap_res;
  wire tap_pre_valid, tap_res_valid, ln_sel;
  wire [15:0] tap_tag;
  wire pf_valid, pf_ready;
  wire [127:0] pf_data;
  wire [31:0] pf_level; // observation is explicitly zero-extended from DUT width

  a_cmd_hold: assert property (@(posedge clk) disable iff(!rst_n)
    cmd_valid && !cmd_ready |=> cmd_valid && $stable({cmd_layer,cmd_in_en,cmd_out_en}))
    else $error("KSE command changed while stalled");
  a_param_hold: assert property (@(posedge clk) disable iff(!rst_n)
    param_valid && !param_ready |=> param_valid && $stable(param_data))
    else $error("KSE parameter changed while stalled");
  a_input_hold: assert property (@(posedge clk) disable iff(!rst_n)
    act_in_valid && !act_in_ready |=> act_in_valid && $stable(act_in_data))
    else $error("KSE input changed while stalled");
  a_output_hold: assert property (@(posedge clk) disable iff(!rst_n)
    act_out_valid && !act_out_ready |=> act_out_valid && $stable(act_out_data))
    else $error("KSE output changed while stalled");
  a_done_pulse: assert property (@(posedge clk) disable iff(!rst_n) done |=> !done)
    else $error("KSE done must be a pulse");
  // The optimized top may accept the next command while LN2 is still
  // draining.  Outside that early-command window, the original idle/ready
  // relation remains required.
  a_idle_busy: assert property (@(posedge clk) disable iff(!rst_n)
    !$isunknown({cmd_ready,busy,done,param_ready,act_in_ready,act_out_valid,phase}) &&
    ((!busy) ? cmd_ready : ((phase == 4'd10) || !cmd_ready)))
    else $error("KSE unknown control or inconsistent ready/busy");
  c_param_stall: cover property (@(posedge clk) disable iff(!rst_n) param_valid && !param_ready);
  c_output_stall: cover property (@(posedge clk) disable iff(!rst_n) act_out_valid && !act_out_ready);
  c_output_tail: cover property (@(posedge clk) disable iff(!rst_n)
    (act_out_valid && !act_out_ready) [*8] ##1 (act_out_valid && act_out_ready));
endinterface
