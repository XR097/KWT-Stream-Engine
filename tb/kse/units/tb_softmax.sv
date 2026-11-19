// Unit test: kse_softmax_core (the core instantiated in kse_top).
// softmax.txt rows: tag q8_sh x[99] exp[99]; tag 0 = operators/ vectors
// (softmax_uniform/extreme, 12 layers), tag 1 = sample_00 score->softmax.
`timescale 1ns/1ps
module tb_softmax;
  parameter int LANES = 8;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic signed [7:0] q8_sh;
  logic in_valid, row_ready, out_valid;
  logic [255:0] in_data, out_data;
  logic [1:0] out_beat;
  kse_softmax_core #(.LANES(LANES)) dut (.clk(clk), .rst_n(rst_n), .q8_sh(q8_sh), .in_valid(in_valid),
    .row_ready(row_ready), .in_data(in_data), .out_valid(out_valid), .out_beat(out_beat), .out_data(out_data));

  localparam int MAXR = 4000;
  logic [7:0] X [MAXR][99];
  logic [7:0] E [MAXR][99];
  logic [7:0] Q [MAXR];
  int TAG [MAXR];
  int nrows, sent, recv, cmp, bad, cmp_tag [2], bad_tag [2];
  int ob;

  initial begin
    string path; int fd, n, tag; logic [7:0] q, b;
    if (!$value$plusargs("VEC=%s", path)) path = "softmax.txt";
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    nrows = 0;
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%d %h", tag, q);
      if (n != 2) break;
      for (int j = 0; j < 99; j++) begin n = $fscanf(fd, "%h", b); X[nrows][j] = b; end
      for (int j = 0; j < 99; j++) begin n = $fscanf(fd, "%h", b); E[nrows][j] = b; end
      Q[nrows] = q; TAG[nrows] = tag; nrows++;
    end
    $display("loaded %0d softmax rows", nrows);
  end

  // driver
  initial begin
    in_valid = 0; in_data = '0; sent = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(negedge clk);
    q8_sh = Q[0];
    while (sent < nrows) begin
      // configuration is per layer: drain before changing it
      if (Q[sent] != q8_sh) begin
        while (recv < sent) @(negedge clk);
        q8_sh = Q[sent];
      end
      while (!row_ready) @(negedge clk);
      for (int k = 0; k < 4; k++) begin
        in_valid = 1;
        for (int i = 0; i < 32; i++) in_data[i*8 +: 8] = (32*k+i < 99) ? X[sent][32*k+i] : 8'hA5;
        @(negedge clk);
        // random gap between beats
        if ($urandom_range(0, 3) == 0) begin in_valid = 0; @(negedge clk); end
      end
      in_valid = 0;
      sent++;
    end
  end

  // checker
  initial begin
    recv = 0; cmp = 0; bad = 0; ob = 0;
    cmp_tag = '{0, 0}; bad_tag = '{0, 0};
    forever begin
      @(posedge clk); #1;
      if (out_valid) begin
        if (out_beat != 2'(ob)) begin bad++; $display("BEAT ORDER error row %0d", recv); end
        for (int i = 0; i < 32; i++) begin
          int j; j = 32*ob + i;
          if (j < 99) begin
            cmp++; cmp_tag[TAG[recv]]++;
            if (out_data[i*8 +: 8] !== E[recv][j]) begin
              bad++; bad_tag[TAG[recv]]++;
              if (bad <= 10) $display("MISMATCH row=%0d j=%0d got=%0d exp=%0d", recv, j, out_data[i*8 +: 8], E[recv][j]);
            end
          end else if (out_data[i*8 +: 8] !== 8'd0) begin
            bad++; $display("PAD nonzero row=%0d j=%0d", recv, j);
          end
        end
        ob++;
        if (ob == 4) begin ob = 0; recv++; end
        if (recv == nrows) begin
          $display("SOFTMAX rows=%0d compared=%0d mismatches=%0d (operators: %0d/%0d, sample_00 score->softmax: %0d/%0d)",
                   recv, cmp, bad, cmp_tag[0], bad_tag[0], cmp_tag[1], bad_tag[1]);
          $display("SOFTMAX cycles=%0d", $time/10);
          if (bad == 0) $display("TEST PASSED"); else $display("TEST FAILED");
          $finish;
        end
      end
    end
  end
  initial begin #50000000; $display("TIMEOUT recv=%0d", recv); $display("TEST FAILED"); $finish; end
endmodule
