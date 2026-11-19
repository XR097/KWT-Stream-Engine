// Unit test: kse_post_lane (the lane instantiated 32x in kse_mm).
// Vectors: tools/kse/gen_tb_data.py units -> post.txt; every expected value
// is a frozen golden tensor element (q/k/v/proj/fc1/gelu/fc2/score/context
// of sample_00, all 12 layers, plus the GELU operator vectors).
// One vector per cycle; pre is registered 2 edges and y 3 edges after the input is applied.
`timescale 1ns/1ps
module tb_post;
  logic clk = 0;
  always #5 clk = ~clk;
  logic              v;
  logic signed [23:0] acc;
  logic signed [15:0] bias;
  logic signed [7:0] sh, lo, hi, tail, pre, y;
  logic              gelu;
  logic [3:0]        layer;
  kse_post_lane dut (.clk(clk), .in_valid(v), .acc(acc), .bias(bias), .sh(sh), .gelu_en(gelu),
                     .layer(layer), .gelu_lo(lo), .gelu_hi(hi), .gelu_tail(tail), .pre(pre), .y(y));
  localparam int MAXV = 1000000;
  logic [23:0] A [MAXV]; logic [15:0] B [MAXV]; logic [7:0] S [MAXV], L [MAXV], H [MAXV], TL [MAXV], P [MAXV], Y [MAXV];
  logic G [MAXV]; logic [3:0] LY [MAXV];
  int nv, cmp, bad;
  initial begin
    string path; int fd, n;
    if (!$value$plusargs("VEC=%s", path)) path = "post.txt";
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    nv = 0;
    while (!$feof(fd) && nv < MAXV) begin
      n = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h\n", A[nv], B[nv], S[nv], G[nv], LY[nv], L[nv], H[nv], TL[nv], P[nv], Y[nv]);
      if (n != 10) break;
      nv++;
    end
    cmp = 0; bad = 0; v = 0;
    @(negedge clk);
    for (int i = 0; i < nv + 2; i++) begin
      if (i < nv) begin
        v = 1; acc = A[i]; bias = B[i]; sh = S[i]; gelu = G[i]; layer = LY[i]; lo = L[i]; hi = H[i]; tail = TL[i];
      end else v = 0;
      // configuration (layer/GELU window) of the vector currently in stage 2
      if (i >= 1 && i - 1 < nv) begin layer = LY[i-1]; lo = L[i-1]; hi = H[i-1]; tail = TL[i-1]; end
      @(posedge clk); #1;
      if (i >= 1 && i - 1 < nv) begin
        cmp++;
        if (pre !== P[i-1]) begin bad++; if (bad <= 10) $display("MISMATCH pre idx=%0d got=%0d exp=%0d", i-1, pre, $signed(P[i-1])); end
      end
      if (i >= 2 && i - 2 < nv) begin
        cmp++;
        if (y !== Y[i-2]) begin bad++; if (bad <= 10) $display("MISMATCH y idx=%0d got=%0d exp=%0d", i-2, y, $signed(Y[i-2])); end
      end
      @(negedge clk);
    end
    $display("POST vectors=%0d compared=%0d mismatches=%0d", nv, cmp, bad);
    if (bad == 0 && nv > 0) $display("TEST PASSED"); else $display("TEST FAILED");
    $finish;
  end
endmodule
