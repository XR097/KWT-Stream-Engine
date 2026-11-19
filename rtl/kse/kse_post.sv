`default_nettype none
// Post-processing lane: y = sat8(shift_rne(acc + bias, sh)), then optional
// GELU (middle ROM, zero below the window, shifted/saturated tail above).
// Stage 0 (registered): acc + bias, shift amount, GELU enable.
// Stage 1 (registered): shift, saturate -> pre (also the fc1 tensor).
// Stage 2 (registered): GELU or pass-through -> y.
// pre is valid 2 cycles and y 3 cycles after in_valid.
module kse_post_lane (
  input  logic              clk,
  input  logic              in_valid,
  input  logic signed [23:0] acc,
  input  logic signed [15:0] bias,
  input  logic signed [7:0] sh,
  input  logic              gelu_en,
  input  logic [3:0]        layer,
  input  logic signed [7:0] gelu_lo,
  input  logic signed [7:0] gelu_hi,
  input  logic signed [7:0] gelu_tail,
  output logic signed [7:0] pre,
  output logic signed [7:0] y
);
  logic signed [24:0] sum_q;
  logic signed [7:0]  sh_q;
  logic               v_q, g0_q;
  always_ff @(posedge clk) begin
    v_q <= in_valid;
    if (in_valid) begin
      sum_q <= 25'(acc) + 25'(bias);
      sh_q  <= sh;
      g0_q  <= gelu_en;
    end
  end
  logic signed [31:0] shifted;
  logic signed [7:0]  sat;
  kse_shift_rne #(.IW(25), .OW(32), .LMAX(7)) u_sh (.x(sum_q), .sh(sh_q), .y(shifted));
  kse_sat #(.IW(32), .OW(8)) u_sat (.x(shifted), .y(sat));
  logic gelu_q;
  always_ff @(posedge clk) begin
    if (v_q) begin
      pre    <= sat;
      gelu_q <= g0_q;
    end
  end
  logic signed [7:0] g;
  kse_gelu u_gelu (.x(pre), .layer(layer), .lo(gelu_lo), .hi(gelu_hi), .tail(gelu_tail), .y(g));
  always_ff @(posedge clk) y <= gelu_q ? g : pre;
endmodule

// GELU middle-table evaluation (quantized reference gelu, method
// "middle"): address = clip(x - lo, 0, 255); x < lo -> 0; x > hi -> tail.
module kse_gelu (
  input  logic signed [7:0] x,
  input  logic [3:0]        layer,
  input  logic signed [7:0] lo,
  input  logic signed [7:0] hi,
  input  logic signed [7:0] tail,
  output logic signed [7:0] y
);
  logic signed [8:0]  a9;
  logic [7:0]         addr;
  logic signed [7:0]  mid, ts;
  logic signed [15:0] tsh;
  assign a9   = 9'(x) - 9'(lo);
  assign addr = a9[8] ? 8'd0 : a9[7:0];
  kse_gelu_rom u_rom (.layer(layer), .addr(addr), .data(mid));
  kse_shift_rne #(.IW(8), .OW(16), .LMAX(7)) u_tail (.x(x), .sh(tail), .y(tsh));
  kse_sat #(.IW(16), .OW(8)) u_tsat (.x(tsh), .y(ts));
  always_comb begin
    if (x < lo)      y = 8'sd0;
    else if (x > hi) y = ts;
    else             y = mid;
  end
endmodule
`default_nettype wire
