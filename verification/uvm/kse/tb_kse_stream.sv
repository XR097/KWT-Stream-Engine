`timescale 1ns/1ps
module tb_kse_stream;
  import uvm_pkg::*;
  import kse_stream_pkg::*;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  kse_stream_if link(clk,rst_n);
  kse_top dut(
    .clk(clk),.rst_n(rst_n),
    .cmd_valid(link.cmd_valid),.cmd_ready(link.cmd_ready),.cmd_layer(link.cmd_layer),
    .cmd_in_en(link.cmd_in_en),.cmd_out_en(link.cmd_out_en),
    .param_valid(link.param_valid),.param_ready(link.param_ready),.param_data(link.param_data),
    .act_in_valid(link.act_in_valid),.act_in_ready(link.act_in_ready),.act_in_data(link.act_in_data),
    .act_out_valid(link.act_out_valid),.act_out_ready(link.act_out_ready),.act_out_data(link.act_out_data),
    .done(link.done),.busy(link.busy));
  assign link.phase=dut.phase;
  assign link.a_en=dut.a_en; assign link.a_we=dut.a_we;
  assign link.b_en=dut.b_en; assign link.b_we=dut.b_we;
  assign link.a_addr=dut.a_addr; assign link.b_addr=dut.b_addr;
  assign link.a_wdata=dut.a_wdata; assign link.b_wdata=dut.b_wdata;
  assign link.tap_pre_valid=dut.tap_pre_valid; assign link.tap_pre=dut.tap_pre;
  assign link.tap_res_valid=dut.tap_res_valid; assign link.tap_res=dut.tap_res;
  assign link.tap_tag=dut.tap_tag; assign link.ln_sel=dut.u_ln.selq;
  assign link.pf_valid=dut.pf_valid; assign link.pf_ready=dut.pf_ready;
  assign link.pf_data=dut.pf_data; assign link.pf_level=32'(dut.pf_level);
  initial begin repeat(5) @(negedge clk); rst_n=1; end
  initial begin
    string fsdb;
    $display("KSE_ENGINE_CONFIG R=%0d C=%0d SM_LANES=%0d LN_LANES=%0d PF_DEPTH=%0d", dut.R, dut.C, dut.SM_LANES, dut.LN_LANES, dut.PF_DEPTH);
    if($value$plusargs("fsdbfile=%s",fsdb)) begin
      $fsdbDumpfile(fsdb);
      $fsdbDumpvars(0,link);
    end
    uvm_config_db#(virtual kse_stream_if)::set(null,"uvm_test_top.*","vif",link);
    run_test();
  end
endmodule
