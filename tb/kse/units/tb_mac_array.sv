// Unit test: kse_mac_array (the array instantiated in kse_mm) against an
// independent integer reference kept in the testbench.  Random row/column
// loads (W4 nibble and int8 byte slots), random streamed vectors (s8 and u8),
// random reduction lengths 1..8 per output.
`timescale 1ns/1ps
module tb_mac_array;
  parameter int R = 32, C = 32, TW = 16;
  parameter int NCYC = 40000;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic [R-1:0] ld_row_we; logic [C*8-1:0] ld_row_data;
  logic [C-1:0] ld_col_we; logic [R*8-1:0] ld_col_data;
  logic [3:0] ld_slot; logic ld_w4;
  logic in_valid, in_uns, in_w4, in_first, in_last; logic [R*8-1:0] in_a; logic [3:0] in_slot; logic [TW-1:0] in_tag;
  logic out_valid; logic [C*24-1:0] out_acc; logic [TW-1:0] out_tag;
  logic s2_valid, s2_last; logic [TW-1:0] s2_tag;
  logic [R-1:0] pj_row_we = '0;
  logic [C*8-1:0] pj_row_data = '0;
  logic pj_slot = 0, in_pj = 0;
  kse_mac_array #(.R(R), .C(C), .TW(TW)) dut (.*);

  logic [31:0] model [R][C];
  longint acc_m [C];
  longint expq [$][C];
  int ntag, got, cmp, bad;

  function automatic int wval(int r, int c, int slot, bit w4);
    logic [31:0] v; v = model[r][c];
    if (w4) return $signed(v[4*slot +: 4]);
    else    return $signed(v[8*slot[1:0] +: 8]);
  endfunction

  initial begin
    int kb, k, kbn; bit grp;
    ld_row_we = '0; ld_col_we = '0; in_valid = 0; in_first = 0; in_last = 0; ntag = 0;
    for (int r = 0; r < R; r++) for (int c = 0; c < C; c++) model[r][c] = 'x;
    repeat (3) @(posedge clk); rst_n = 1;
    // initialise every PE so no X reaches the reference
    @(negedge clk);
    for (int s = 0; s < 4; s++) begin
      ld_row_we = '1; ld_w4 = 0; ld_slot = 4'(s);
      for (int c = 0; c < C; c++) ld_row_data[c*8 +: 8] = $urandom;
      for (int r = 0; r < R; r++) for (int c = 0; c < C; c++) model[r][c][8*s +: 8] = ld_row_data[c*8 +: 8];
      @(negedge clk);
    end
    ld_row_we = '0;
    kb = 0; kbn = 1;
    for (int cyc = 0; cyc < NCYC; cyc++) begin
      // random load this cycle
      ld_row_we = '0; ld_col_we = '0;
      k = $urandom_range(0, 5);
      ld_w4 = $urandom_range(0, 1); ld_slot = $urandom_range(0, 7);
      if (k == 0) begin
        ld_row_we = {$urandom, $urandom};
        for (int c = 0; c < C; c++) ld_row_data[c*8 +: 8] = $urandom;
      end else if (k == 1) begin
        ld_col_we = {$urandom, $urandom};
        for (int r = 0; r < R; r++) ld_col_data[r*8 +: 8] = $urandom;
      end
      for (int r = 0; r < R; r++) for (int c = 0; c < C; c++) begin
        bit we; logic [7:0] d;
        we = ld_row_we[r] | ld_col_we[c];
        d = ld_row_we[r] ? ld_row_data[c*8 +: 8] : ld_col_data[r*8 +: 8];
        if (we) begin
          if (ld_w4) model[r][c][4*ld_slot +: 4] = d[3:0];
          else       model[r][c][8*ld_slot[1:0] +: 8] = d;
        end
      end
      // random step this cycle
      in_valid = ($urandom_range(0, 7) != 0);
      if (in_valid) begin
        if (kb == 0) kbn = $urandom_range(1, 8);
        in_first = (kb == 0); in_last = (kb == kbn - 1);
        in_uns = $urandom_range(0, 1); in_w4 = $urandom_range(0, 1); in_slot = $urandom_range(0, 7);
        for (int r = 0; r < R; r++) in_a[r*8 +: 8] = $urandom;
        in_tag = TW'(ntag);
        for (int c = 0; c < C; c++) begin
          longint s; s = 0;
          for (int r = 0; r < R; r++) begin
            int a; a = in_uns ? int'(in_a[r*8 +: 8]) : int'($signed(in_a[r*8 +: 8]));
            s += a * wval(r, c, in_slot, in_w4);
          end
          acc_m[c] = (in_first ? 0 : acc_m[c]) + s;
        end
        if (in_last) begin
          longint e [C];
          for (int c = 0; c < C; c++) e[c] = acc_m[c];
          expq.push_back(e);
          ntag++;
          kb = 0;
        end else kb++;
      end
      @(negedge clk);
    end
    in_valid = 0; ld_row_we = '0; ld_col_we = '0;
    repeat (10) @(negedge clk);
    $display("MAC_ARRAY R=%0d C=%0d outputs=%0d compared=%0d mismatches=%0d", R, C, got, cmp, bad);
    if (bad == 0 && got == ntag && got > 0) $display("TEST PASSED"); else $display("TEST FAILED");
    $finish;
  end

  initial begin
    got = 0; cmp = 0; bad = 0;
    forever begin
      @(posedge clk); #1;
      if (out_valid) begin
        longint e [C];
        e = expq.pop_front();
        if (out_tag != TW'(got)) begin bad++; $display("TAG error got %0d exp %0d", out_tag, got); end
        for (int c = 0; c < C; c++) begin
          logic [23:0] ev; ev = e[c][23:0];
          cmp++;
          if (out_acc[c*24 +: 24] !== ev) begin
            bad++; if (bad <= 10) $display("MISMATCH out=%0d col=%0d got=%0d exp=%0d", got, c, $signed(out_acc[c*24 +: 24]), $signed(ev));
          end
        end
        got++;
      end
    end
  end
endmodule
