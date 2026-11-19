`timescale 1ns/1ps
// KSNUM-014 elaboration wrapper: instantiate the real kse_top with the R/C/LANES
// selected by +define+WP8_R/WP8_C/WP8_SM/WP8_LN. Current RTL supports
// R=16/32, C=32; default SM/LN lanes are 8.
// Legal builds also run a short reset/idle check (cmd_ready=1, busy=0, done=0).
`ifndef WP8_R
`define WP8_R 32
`endif
`ifndef WP8_C
`define WP8_C 32
`endif
`ifndef WP8_SM
`define WP8_SM 8
`endif
`ifndef WP8_LN
`define WP8_LN 8
`endif
module wp8_rc_top;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  wire cmd_ready, param_ready, act_in_ready, act_out_valid, done, busy;
  wire [31:0] act_out_data;
  kse_top #(.R(`WP8_R), .C(`WP8_C), .SM_LANES(`WP8_SM), .LN_LANES(`WP8_LN)) u_dut (
    .clk(clk), .rst_n(rst_n), .cmd_valid(1'b0), .cmd_ready(cmd_ready), .cmd_layer(4'd0), .cmd_in_en(1'b0),
    .cmd_out_en(1'b0), .param_valid(1'b0), .param_ready(param_ready), .param_data(32'd0),
    .act_in_valid(1'b0), .act_in_ready(act_in_ready), .act_in_data(32'd0),
    .act_out_valid(act_out_valid), .act_out_ready(1'b1), .act_out_data(act_out_data), .done(done), .busy(busy));
  initial begin
    int bad = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (50) begin
      @(negedge clk);
      if (cmd_ready !== 1'b1 || busy !== 1'b0 || done !== 1'b0 || act_out_valid !== 1'b0) bad++;
    end
    $display("WP8_RC_IDLE R=%0d C=%0d SM=%0d LN=%0d bad_cycles=%0d", `WP8_R, `WP8_C, `WP8_SM, `WP8_LN, bad);
    if (bad == 0) $display("WP8_RC_COMPLETE TEST PASSED");
    else $display("WP8_RC_COMPLETE TEST FAILED");
    $finish;
  end
endmodule
