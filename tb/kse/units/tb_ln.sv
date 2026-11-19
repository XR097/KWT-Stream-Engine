// Unit test: kse_ln_core (residual lanes + LayerNorm, the core instantiated in
// kse_top).  ln.txt tokens: kind ax ay vsh nsh ash eps gamma[64] beta[64]
// x[64] y[64] exp_res[64] exp_out[64].
//   kind 0: operators/ LN vectors (x = input, y = 0, shifts 0)  -> output
//   kind 1: sample_00 (input, proj) -> res1 (residual tap) and ln1
//   kind 2: sample_00 (ln1, fc2)    -> res2 (residual tap) and output
`timescale 1ns/1ps
module tb_ln;
  parameter int LANES = 8;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic signed [7:0] ax, ay, vsh, nsh, ash;
  logic [15:0] eps;
  logic [64*16-1:0] gamma;
  logic [64*8-1:0] beta;
  logic tok_ready, in_valid, in_half, out_valid, out_half, res_valid, res_half;
  logic [255:0] in_x, in_y, out_data, res_data;
  kse_ln_core #(.LANES(LANES)) dut (.clk(clk), .rst_n(rst_n), .ax(ax), .ay(ay), .vsh(vsh), .nsh(nsh), .ash(ash),
    .eps(eps), .gamma(gamma), .beta(beta), .tok_ready(tok_ready), .in_valid(in_valid), .in_half(in_half),
    .in_x(in_x), .in_y(in_y), .out_valid(out_valid), .out_half(out_half), .out_data(out_data),
    .res_valid(res_valid), .res_half(res_half), .res_data(res_data));

  localparam int MAXT = 3000;
  int KIND [MAXT];
  logic [7:0] CFG [MAXT][5];
  logic [15:0] EPS [MAXT];
  logic [15:0] G [MAXT][64];
  logic [7:0] B [MAXT][64], X [MAXT][64], Y [MAXT][64], ER [MAXT][64], EO [MAXT][64];
  int ntok, sent, recv, rrecv;
  int cmp_o [3], bad_o [3], cmp_r [3], bad_r [3];

  function automatic bit same_cfg(int a, int b);
    if (CFG[a] != CFG[b] || EPS[a] != EPS[b]) return 0;
    for (int i = 0; i < 64; i++) if (G[a][i] != G[b][i] || B[a][i] != B[b][i]) return 0;
    return 1;
  endfunction

  initial begin
    string path; int fd, n, k; logic [15:0] w;
    if (!$value$plusargs("VEC=%s", path)) path = "ln.txt";
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    ntok = 0;
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%d", k);
      if (n != 1) break;
      KIND[ntok] = k;
      for (int i = 0; i < 5; i++) begin n = $fscanf(fd, "%h", w); CFG[ntok][i] = w[7:0]; end
      n = $fscanf(fd, "%h", w); EPS[ntok] = w;
      for (int i = 0; i < 64; i++) begin n = $fscanf(fd, "%h", w); G[ntok][i] = w; end
      for (int i = 0; i < 64; i++) begin n = $fscanf(fd, "%h", w); B[ntok][i] = w[7:0]; end
      for (int i = 0; i < 64; i++) begin n = $fscanf(fd, "%h", w); X[ntok][i] = w[7:0]; end
      for (int i = 0; i < 64; i++) begin n = $fscanf(fd, "%h", w); Y[ntok][i] = w[7:0]; end
      for (int i = 0; i < 64; i++) begin n = $fscanf(fd, "%h", w); ER[ntok][i] = w[7:0]; end
      for (int i = 0; i < 64; i++) begin n = $fscanf(fd, "%h", w); EO[ntok][i] = w[7:0]; end
      ntok++;
    end
    $display("loaded %0d LN tokens", ntok);
  end

  task automatic apply_cfg(int t);
    ax = CFG[t][0]; ay = CFG[t][1]; vsh = CFG[t][2]; nsh = CFG[t][3]; ash = CFG[t][4]; eps = EPS[t];
    for (int i = 0; i < 64; i++) begin gamma[i*16 +: 16] = G[t][i]; beta[i*8 +: 8] = B[t][i]; end
  endtask

  initial begin
    in_valid = 0; sent = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(negedge clk);
    apply_cfg(0);
    while (sent < ntok) begin
      if (sent > 0 && !same_cfg(sent, sent - 1)) begin
        while (recv < sent) @(negedge clk);
        apply_cfg(sent);
      end
      while (!tok_ready) @(negedge clk);
      for (int hh = 0; hh < 2; hh++) begin
        in_valid = 1; in_half = hh[0];
        for (int i = 0; i < 32; i++) begin in_x[i*8 +: 8] = X[sent][32*hh+i]; in_y[i*8 +: 8] = Y[sent][32*hh+i]; end
        @(negedge clk);
        if ($urandom_range(0, 3) == 0) begin in_valid = 0; @(negedge clk); end
      end
      in_valid = 0;
      sent++;
    end
  end

  int oh, rh;
  initial begin
    recv = 0; rrecv = 0; oh = 0; rh = 0;
    for (int k = 0; k < 3; k++) begin cmp_o[k] = 0; bad_o[k] = 0; cmp_r[k] = 0; bad_r[k] = 0; end
    forever begin
      @(posedge clk); #1;
      if (res_valid) begin
        if (res_half != rh[0]) $display("RES half order error");
        if (KIND[rrecv] != 0) begin
          for (int i = 0; i < 32; i++) begin
            cmp_r[KIND[rrecv]]++;
            if (res_data[i*8 +: 8] !== ER[rrecv][32*rh+i]) begin
              bad_r[KIND[rrecv]]++;
              if (bad_r[KIND[rrecv]] <= 5) $display("MISMATCH res tok=%0d c=%0d got=%0d exp=%0d", rrecv, 32*rh+i, $signed(res_data[i*8 +: 8]), $signed(ER[rrecv][32*rh+i]));
            end
          end
        end
        rh++; if (rh == 2) begin rh = 0; rrecv++; end
      end
      if (out_valid) begin
        if (out_half != oh[0]) $display("OUT half order error");
        for (int i = 0; i < 32; i++) begin
          cmp_o[KIND[recv]]++;
          if (out_data[i*8 +: 8] !== EO[recv][32*oh+i]) begin
            bad_o[KIND[recv]]++;
            if (bad_o[KIND[recv]] <= 5) $display("MISMATCH out kind=%0d tok=%0d c=%0d got=%0d exp=%0d", KIND[recv], recv, 32*oh+i, $signed(out_data[i*8 +: 8]), $signed(EO[recv][32*oh+i]));
          end
        end
        oh++; if (oh == 2) begin oh = 0; recv++; end
        if (recv == ntok) begin
          int tc, tb;
          tc = 0; tb = 0;
          for (int k = 0; k < 3; k++) begin tc += cmp_o[k] + cmp_r[k]; tb += bad_o[k] + bad_r[k]; end
          $display("LN operators: out %0d/%0d mismatches", cmp_o[0], bad_o[0]);
          $display("LN sample_00 (input,proj)->res1: %0d/%0d  res1->ln1: %0d/%0d", cmp_r[1], bad_r[1], cmp_o[1], bad_o[1]);
          $display("LN sample_00 (ln1,fc2)->res2: %0d/%0d  res2->output: %0d/%0d", cmp_r[2], bad_r[2], cmp_o[2], bad_o[2]);
          $display("LN tokens=%0d compared=%0d mismatches=%0d cycles=%0d", recv, tc, tb, $time/10);
          if (tb == 0) $display("TEST PASSED"); else $display("TEST FAILED");
          $finish;
        end
      end
    end
  end
  initial begin #50000000; $display("TIMEOUT recv=%0d", recv); $display("TEST FAILED"); $finish; end
endmodule
