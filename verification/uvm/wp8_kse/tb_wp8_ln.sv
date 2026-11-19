`timescale 1ns/1ps
// KSNUM-012 unit bench: real kse_ln_core (production LANES/NB by default),
// driven only through its ports; expectations come from wp8_ln_vectors.py.
module tb_wp8_ln;
  import uvm_pkg::*;
  import wp8_ln_pkg::*;
  parameter int LANES = 8;
  parameter int NB    = 3;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  wp8_ln_if link(clk, rst_n);
  kse_ln_core #(.LANES(LANES), .NB(NB)) u_dut (
    .clk(clk), .rst_n(rst_n), .ax(link.ax), .ay(link.ay), .vsh(link.vsh), .nsh(link.nsh), .ash(link.ash),
    .eps(link.eps), .gamma(link.gamma), .beta(link.beta), .tok_ready(link.tok_ready), .buf_free(link.buf_free),
    .in_valid(link.in_valid), .in_half(link.in_half), .in_x(link.in_x), .in_y(link.in_y),
    .out_valid(link.out_valid), .out_half(link.out_half), .out_data(link.out_data),
    .res_valid(link.res_valid), .res_half(link.res_half), .res_data(link.res_data));
  // interface protocol assertions (outputs are never X after reset)
  a_known: assert property (@(posedge clk) disable iff (!rst_n) !$isunknown({link.out_valid, link.res_valid, link.tok_ready, link.buf_free}));
  a_out_data_known: assert property (@(posedge clk) disable iff (!rst_n) link.out_valid |-> !$isunknown({link.out_half, link.out_data}));
  a_res_data_known: assert property (@(posedge clk) disable iff (!rst_n) link.res_valid |-> !$isunknown({link.res_half, link.res_data}));
  c_back_to_back_out: cover property (@(posedge clk) disable iff (!rst_n) link.out_valid && link.out_half ##1 link.out_valid && !link.out_half);
  c_tok_ready_low: cover property (@(posedge clk) disable iff (!rst_n) !link.tok_ready);
  initial begin repeat (5) @(negedge clk); rst_n = 1; end
  initial begin
    string fsdb;
    if ($value$plusargs("fsdbfile=%s", fsdb)) begin $fsdbDumpfile(fsdb); $fsdbDumpvars(0, tb_wp8_ln); end
    uvm_config_db#(virtual wp8_ln_if)::set(null, "uvm_test_top.*", "vif", link);
    uvm_config_db#(int)::set(null, "uvm_test_top", "lanes", LANES);
    uvm_config_db#(int)::set(null, "uvm_test_top", "nb", NB);
    run_test();
  end
endmodule
