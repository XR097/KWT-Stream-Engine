`timescale 1ns/1ps
interface kse_icb_if(input logic clk, input logic rst_n);
  logic cmd_valid, cmd_ready, cmd_read;
  logic [31:0] cmd_addr, cmd_wdata;
  logic [3:0] cmd_wmask;
  logic rsp_valid, rsp_ready, rsp_err;
  logic [31:0] rsp_rdata;

  a_cmd_stable: assert property (@(posedge clk) disable iff (!rst_n)
    cmd_valid && !cmd_ready |=> cmd_valid &&
      $stable({cmd_read, cmd_addr, cmd_wdata, cmd_wmask}))
    else $error("KSE ICB command changed while stalled");
  // A write response has no defined data; check its err/valid but not rdata.
  logic pending_read;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) pending_read <= 0;
    else if (cmd_valid && cmd_ready) pending_read <= cmd_read;
  a_rsp_stable: assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid && !rsp_ready |=> rsp_valid && $stable(rsp_err) &&
      (!pending_read || $stable(rsp_rdata)))
    else $error("KSE ICB response changed while stalled");
  c_stall_release: cover property (@(posedge clk) disable iff (!rst_n)
    rsp_valid && !rsp_ready ##1 rsp_valid && rsp_ready);
endinterface
