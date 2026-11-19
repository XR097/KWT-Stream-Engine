`timescale 1ns/1ps
module tb_kse_numeric;
  import uvm_pkg::*;
  import kse_numeric_pkg::*;
  logic clk=0,rst_n=0;
  always #5 clk=~clk;
  kse_numeric_if link(clk,rst_n);
  kse_shift_rne #(.IW(25),.OW(32),.LMAX(7)) u_shift(.x(link.a[24:0]),.sh(link.b[7:0]),.y(link.shifted));
  kse_sat #(.IW(32),.OW(8)) u_sat(.x(link.a[31:0]),.y(link.saturated));
  kse_udiv_rne #(.NW(23),.DW(22),.QW(8),.BPS(2),.TW(16)) u_div_sm(
    .clk(clk),.in_valid(link.fire && link.op==2),.in_n(link.a[22:0]),.in_d(link.b[21:0]),.in_tag(link.c[15:0]),
    .out_valid(link.div_sm_v),.out_q(link.div_sm_q),.out_ovf(link.div_sm_ovf),.out_tag(link.div_sm_tag));
  kse_udiv_rne #(.NW(38),.DW(24),.QW(30),.BPS(2),.TW(16)) u_div_ln(
    .clk(clk),.in_valid(link.fire && link.op==3),.in_n(link.a[37:0]),.in_d(link.b[23:0]),.in_tag(link.c[15:0]),
    .out_valid(link.div_ln_v),.out_q(link.div_ln_q),.out_ovf(link.div_ln_ovf),.out_tag(link.div_ln_tag));
  kse_isqrt #(.IW(36),.BPC(2)) u_sqrt2(.clk(clk),.rst_n(rst_n),.start(link.fire && link.op==4),.n(link.a[35:0]),
    .root(link.sqrt2),.busy(link.sqrt2_busy),.done(link.sqrt2_done));
  kse_isqrt #(.IW(36),.BPC(3)) u_sqrt3(.clk(clk),.rst_n(rst_n),.start(link.fire && link.op==4),.n(link.a[35:0]),
    .root(link.sqrt3),.busy(link.sqrt3_busy),.done(link.sqrt3_done));
  kse_gelu u_gelu(.x(link.a[7:0]),.layer(link.b[3:0]),.lo(link.c[7:0]),.hi(link.d[7:0]),.tail(link.e[7:0]),.y(link.gelu));
  kse_exp_rom u_exp(.addr(link.a[8:0]),.data(link.exp_rom));
  kse_softmax_exp u_exp_lane(.clk(clk),.s(link.a[7:0]),.mx(link.b[7:0]),.q8_sh(link.c[7:0]),.valid(link.d[0]),.e(link.exp_lane));
  kse_post_lane u_post(.clk(clk),.in_valid(link.fire && link.op==8),.acc(link.a[23:0]),.bias(link.b[15:0]),.sh(link.c[7:0]),
    .gelu_en(link.d[0]),.layer(link.e[3:0]),.gelu_lo(link.f[7:0]),.gelu_hi(link.f[15:8]),.gelu_tail(link.f[23:16]),.pre(link.post_pre),.y(link.post_y));
  initial begin repeat(5) @(negedge clk);rst_n=1;end
  initial begin
    string fsdb;
    if($value$plusargs("fsdbfile=%s",fsdb)) begin $fsdbDumpfile(fsdb);$fsdbDumpvars(0,link);end
    uvm_config_db#(virtual kse_numeric_if)::set(null,"uvm_test_top.*","vif",link);run_test();
  end
endmodule
