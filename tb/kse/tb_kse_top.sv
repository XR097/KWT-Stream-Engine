// KSE top-level testbench: plays the role of E203 (one command per layer) and
// of the parameter loader (streams params.hex word by word).  Compares
//   - every layer output on act_out (if out_en) with the golden trace and the
//     final output with sample_XX_output,
//   - every intermediate tensor (taps on the row-store write ports, on the
//     post-processing stage for fc1, and on the residual stage for res1/res2)
// element by element against the frozen golden traces.
//
// plusargs: +DATA=<dir> +SAMPLES=<n> +SAMPLE0=<first> +LAYERS=<n> +OUTALL=<0|1>
//           +TAPS=<0|1> +STALL=<pct param-port idle probability>
`timescale 1ns/1ps
module tb_kse_top #(parameter int ARRAY_R = 32, parameter int ARRAY_C = 32,
                   parameter int SM_LANES = 8, parameter int LN_LANES = 8);
  import kse_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic cmd_valid, cmd_ready, cmd_in_en, cmd_out_en;
  logic [3:0] cmd_layer;
  logic param_valid, param_ready;
  logic [31:0] param_data;
  logic act_in_valid, act_in_ready, act_out_valid, act_out_ready;
  logic [31:0] act_in_data, act_out_data;
  logic done, busy;
  kse_top #(.R(ARRAY_R), .C(ARRAY_C), .SM_LANES(SM_LANES), .LN_LANES(LN_LANES)) dut (.*);

  // ---------------- data ----------------
  localparam int LW  = 6584;          // words per layer (kse-param-stream-v3)
  localparam int NPW = LW * 12;
  localparam int NT  = 15;
  string TN [NT] = '{"input", "q", "k", "v", "score", "softmax", "context", "proj", "res1",
                     "ln1", "fc1", "gelu", "fc2", "res2", "output"};
  localparam int I_Q = 1, I_K = 2, I_V = 3, I_SC = 4, I_SM = 5, I_CX = 6, I_PJ = 7, I_R1 = 8,
                 I_L1 = 9, I_F1 = 10, I_GE = 11, I_F2 = 12, I_R2 = 13, I_OUT = 14, I_ACT = 15, I_FIN = 16;
  int WID [NT] = '{64, 64, 64, 64, 99, 99, 64, 64, 64, 64, 256, 256, 64, 64, 64};
  logic [31:0] params [NPW];
  logic [7:0]  tr [NT][12*99*256];
  logic [7:0]  sin [99*64];
  logic [7:0]  sout [99*64];
  longint cmp [17], bad [17];
  string  first_bad;
  int     nfirst;
  string  DATA;
  int     NS, S0, NL, OUTALL, TAPS, STALL;
  int OUTSTALL = 0;
  initial void'($value$plusargs("OUTSTALL=%d", OUTSTALL));
  always @(negedge clk) act_out_ready <= ($urandom_range(0,99) >= OUTSTALL);
  int     cur_s, cur_l;
  int     nerr, layers_done, timed_out, rows_l, pf_max;
  always @(posedge clk) begin
    if (dut.pf_valid && dut.pf_ready) rows_l <= rows_l + 1;
    if (dut.pf_level > pf_max) pf_max <= dut.pf_level;
  end
  longint cyc, hs_cyc, done_cyc;

  // free-running edge counter; record the edge that accepts a command and the
  // edge at which done is sampled high
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (cmd_valid && cmd_ready) hs_cyc <= cyc;
    if (done) done_cyc <= cyc;
  end

  function automatic int count_lines(string path);
    int fd, n; string line;
    fd = $fopen(path, "r");
    if (fd == 0) return -1;
    n = 0;
    while ($fgets(line, fd)) if (line.len() > 1) n++;
    $fclose(fd);
    return n;
  endfunction

  task automatic load_check(string path, int expect_n);
    int n;
    n = count_lines(path);
    if (n != expect_n) begin
      nerr++;
      $display("ERROR data file %s has %0d entries, expected %0d", path, n, expect_n);
    end
  endtask

  function automatic int idx(int ti, int l, int t, int c);
    return (l * 99 + t) * WID[ti] + c;
  endfunction

  task automatic check(int slot, int ti, int l, int t, int c, logic [7:0] got);
    logic [7:0] e;
    e = tr[ti][idx(ti, l, t, c)];
    cmp[slot]++;
    if (got !== e) begin
      bad[slot]++;
      if (nfirst < 20) begin
        $display("MISMATCH sample=%0d layer=%0d tensor=%s t=%0d c=%0d got=%0d exp=%0d time=%0t",
                 cur_s, l, (slot < NT) ? TN[slot] : "act_out", t, c, $signed(got), $signed(e), $time);
        if (nfirst == 0) first_bad = $sformatf("sample %0d layer %0d %s[%0d][%0d]", cur_s, l, (slot < NT) ? TN[slot] : "act_out", t, c);
        nfirst++;
      end
    end
  endtask

  // ---------------- tap monitors ----------------
  int r1_tok, r1_h, r2_tok, r2_h;
  always @(posedge clk) begin
    if (TAPS && rst_n) begin
      int ph, a;
      ph = dut.phase;
      // row store A writes
      if (dut.a_en && dut.a_we) begin
        a = dut.a_addr;
        for (int i = 0; i < 32; i++) begin
          logic [7:0] b; b = dut.a_wdata[i*8 +: 8];
          case (ph)
            PH_SC:  if (32*((a-A_S)%4) + i < 99) check(I_SC, I_SC, cur_l, (a-A_S)/4, 32*((a-A_S)%4) + i, b);
            PH_SM, PH_PV: check(I_CX, I_CX, cur_l, (a-A_CTX)/2, 32*((a-A_CTX)%2) + i, b);
            PH_PJ, PH_LN1: check(I_L1, I_L1, cur_l, a/2, 32*(a%2) + i, b);
            // during FC2 the concurrent LN2 writes rows below A_F2
            PH_FC2: if (a >= A_F2) check(I_F2, I_F2, cur_l, (a-A_F2)/2, 32*((a-A_F2)%2) + i, b);
                    else check(I_OUT, I_OUT, cur_l, a/2, 32*(a%2) + i, b);
            PH_LN2: check(I_OUT, I_OUT, cur_l, a/2, 32*(a%2) + i, b);
            default: ;
          endcase
        end
      end
      // row store B writes
      if (dut.b_en && dut.b_we) begin
        a = dut.b_addr;
        for (int i = 0; i < 32; i++) begin
          logic [7:0] b; b = dut.b_wdata[i*8 +: 8];
          case (ph)
            PH_QKV: check(I_Q + a/200, I_Q + a/200, cur_l, (a%200)/2, 32*(a%2) + i, b);
            PH_SC, PH_SM: if (32*((a-B_P)%4) + i < 99) check(I_SM, I_SM, cur_l, (a-B_P)/4, 32*((a-B_P)%4) + i, b);
            PH_PJ:  check(I_PJ, I_PJ, cur_l, a/2, 32*(a%2) + i, b);
            PH_LN1, PH_FC1: check(I_GE, I_GE, cur_l, (a-B_H)/8, 32*((a-B_H)%8) + i, b);
            default: ;
          endcase
        end
      end
      // fc1 before GELU: post stage-1 output
      if ((ph == PH_FC1 || ph == PH_LN1) && dut.tap_pre_valid) begin
        int tt, cb;
        tt = dut.tap_tag[6:0]; cb = dut.tap_tag[10:8];
        for (int i = 0; i < 32; i++) check(I_F1, I_F1, cur_l, tt, 32*cb + i, dut.tap_pre[i*8 +: 8]);
      end
      // residuals (in token order)
      if (dut.tap_res_valid) begin
        if (!dut.u_ln.selq) begin
          for (int i = 0; i < 32; i++) check(I_R1, I_R1, cur_l, r1_tok, 32*r1_h + i, dut.tap_res[i*8 +: 8]);
          r1_h++; if (r1_h == 2) begin r1_h = 0; r1_tok++; end
        end else begin
          for (int i = 0; i < 32; i++) check(I_R2, I_R2, cur_l, r2_tok, 32*r2_h + i, dut.tap_res[i*8 +: 8]);
          r2_h++; if (r2_h == 2) begin r2_h = 0; r2_tok++; end
        end
      end
    end
  end

  // ---------------- cycle accounting ----------------
  longint ph_cyc [16], ph_pw [16];
  longint layer_cyc, task_cyc;
  logic   counting;
  always @(posedge clk) begin
    if (counting) begin
      ph_cyc[dut.phase]++;
      if (param_valid && param_ready) ph_pw[dut.phase]++;
      task_cyc++;
    end
  end

  // ---------------- parameter source ----------------
  int pptr, pend;
  always @(posedge clk) begin
    if (param_valid && param_ready) pptr <= pptr + 1;
  end
  always @(negedge clk) begin
    param_valid = (pptr < pend) && ($urandom_range(0, 99) >= STALL);
    param_data  = (pptr < pend) ? params[pptr] : 32'hx;
  end

  // ---------------- act_out monitor ----------------
  int ow;
  always @(posedge clk) begin
    if (act_out_valid && act_out_ready) begin
      for (int i = 0; i < 4; i++) begin
        int e; e = 4*ow + i;
        check(I_ACT, I_OUT, cur_l, e / 64, e % 64, act_out_data[i*8 +: 8]);
        if (cur_l == 11) begin
          cmp[I_FIN]++;
          if (act_out_data[i*8 +: 8] !== sout[e]) begin
            bad[I_FIN]++;
            if (nfirst < 20) begin $display("MISMATCH final output sample=%0d e=%0d", cur_s, e); nfirst++; end
          end
        end
      end
      ow++;
    end
  end

  initial begin
    if (!$value$plusargs("DATA=%s", DATA)) DATA = ".";
    if (!$value$plusargs("SAMPLES=%d", NS)) NS = 1;
    if (!$value$plusargs("SAMPLE0=%d", S0)) S0 = 0;
    if (!$value$plusargs("LAYERS=%d", NL)) NL = 12;
    if (!$value$plusargs("OUTALL=%d", OUTALL)) OUTALL = 1;
    if (!$value$plusargs("TAPS=%d", TAPS)) TAPS = 1;
    if (!$value$plusargs("STALL=%d", STALL)) STALL = 0;
    nerr = 0; layers_done = 0; timed_out = 0; cyc = 0; pf_max = 0;
    load_check({DATA, "/params/params.hex"}, NPW);
    $readmemh({DATA, "/params/params.hex"}, params);
    for (int k = 0; k < 17; k++) begin cmp[k] = 0; bad[k] = 0; end
    for (int k = 0; k < 16; k++) begin ph_cyc[k] = 0; ph_pw[k] = 0; end
    nfirst = 0; first_bad = "none";
    cmd_valid = 0; act_in_valid = 0; act_out_ready = 1; pptr = 0; pend = 0; counting = 0; task_cyc = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    for (int s = S0; s < S0 + NS; s++) begin
      longint t0, tk0;
      cur_s = s;
      // clear per-sample data so stale or missing values cannot match
      for (int i = 0; i < 99*64; i++) begin sin[i] = 'x; sout[i] = 'x; end
      for (int k = 0; k < NT; k++) for (int i = 0; i < 12*99*256; i++) tr[k][i] = 'x;
      load_check($sformatf("%s/samples/s%02d_sample_input.hex", DATA, s), 99*64);
      load_check($sformatf("%s/samples/s%02d_sample_output.hex", DATA, s), 99*64);
      $readmemh($sformatf("%s/samples/s%02d_sample_input.hex", DATA, s), sin);
      $readmemh($sformatf("%s/samples/s%02d_sample_output.hex", DATA, s), sout);
      for (int k = 0; k < NT; k++) begin
        load_check($sformatf("%s/samples/s%02d_%s.hex", DATA, s, TN[k]), 12*99*WID[k]);
        $readmemh($sformatf("%s/samples/s%02d_%s.hex", DATA, s, TN[k]), tr[k]);
      end
      t0 = task_cyc;
      counting = 1;
      for (int l = 0; l < NL; l++) begin
        longint lc0;
        longint ph0 [16];
        lc0 = task_cyc; ph0 = ph_cyc;
        cur_l = l; r1_tok = 0; r1_h = 0; r2_tok = 0; r2_h = 0; ow = 0;
        // command
        @(negedge clk);
        cmd_valid = 1; cmd_layer = l; cmd_in_en = (l == 0); cmd_out_en = OUTALL || (l == NL - 1);
        @(posedge clk); while (!cmd_ready) @(posedge clk);
        // the parameter source starts with the first command and then streams
        // the whole task continuously (prefetch FIFO absorbs it)
        if (l == 0) begin pptr = 0; pend = NL * LW; end
        rows_l = 0;
        @(negedge clk); cmd_valid = 0;
        // input
        if (l == 0) begin
          for (int w = 0; w < 1584; w++) begin
            act_in_valid = 1;
            act_in_data = {sin[4*w+3], sin[4*w+2], sin[4*w+1], sin[4*w]};
            @(posedge clk); while (!act_in_ready) @(posedge clk);
            @(negedge clk);
          end
          act_in_valid = 0;
        end
        while (!done) @(posedge clk);
        #1;
        if (rows_l != LW / 4) begin nerr++; $display("ERROR layer %0d loader consumed %0d of %0d parameter rows", l, rows_l, LW / 4); end
        if (l == NL - 1 && pptr != pend) begin nerr++; $display("ERROR task consumed %0d of %0d parameter words", pptr, pend); end
        if (cmd_out_en && ow != 1584) begin nerr++; $display("ERROR layer %0d output words %0d", l, ow); end
        if (l == 0) tk0 = hs_cyc;
        $display("LAYER sample=%0d layer=%0d cycles=%0d edges_cmd_to_done=%0d", s, l, task_cyc - lc0, done_cyc - hs_cyc);
        for (int p = 0; p < 16; p++) if (ph_cyc[p] != ph0[p])
          $display("LAYER_PHASE sample=%0d layer=%0d phase=%0d cycles=%0d", s, l, p, ph_cyc[p]-ph0[p]);
        layers_done++;
      end
      counting = 0;
      $display("TASK sample=%0d cycles=%0d edges_cmd_to_done=%0d", s, task_cyc - t0, done_cyc - tk0);
    end
    report();
    $finish;
  end

  task automatic report();
    longint tc, tb;
    tc = 0; tb = 0;
    $display("==== comparison summary (elements) ====");
    for (int k = 1; k < 17; k++) begin
      string nm;
      if (k < NT) nm = TN[k]; else if (k == I_ACT) nm = "act_out(layer outputs)"; else nm = "final_output";
      $display("CMP %-24s compared=%0d mismatches=%0d", nm, cmp[k], bad[k]);
      tc += cmp[k]; tb += bad[k];
    end
    $display("==== phase cycles (all simulated layers) ====");
    for (int k = 0; k < 16; k++) if (ph_cyc[k] != 0) $display("PHASE %0d cycles=%0d param_words=%0d", k, ph_cyc[k], ph_pw[k]);
    $display("TOTAL compared=%0d mismatches=%0d first_mismatch=%s", tc, tb, first_bad);
    // exact expected comparison counts
    for (int k = 1; k < 17; k++) begin
      longint ex;
      if (k < NT) ex = TAPS ? longint'(NS) * NL * 99 * WID[k] : 0;
      else if (k == I_ACT) ex = longint'(NS) * (OUTALL ? NL : 1) * 6336;
      else ex = (NL == 12) ? longint'(NS) * 6336 : 0;
      if (cmp[k] != ex) begin
        nerr++;
        $display("ERROR %s compared %0d elements, expected %0d", (k < NT) ? TN[k] : (k == I_ACT ? "act_out" : "final_output"), cmp[k], ex);
      end
    end
    if (layers_done != NS * NL) begin nerr++; $display("ERROR completed %0d of %0d sample-layers", layers_done, NS * NL); end
    if (timed_out) nerr++;
    $display("PREFETCH max_rows=%0d", pf_max);
    $display("ERRORS=%0d layers_done=%0d", nerr, layers_done);
    if (tb == 0 && tc > 0 && nerr == 0) $display("TEST PASSED"); else $display("TEST FAILED");
  endtask

  initial begin
    longint lim;
    if (!$value$plusargs("TIMEOUT=%d", lim)) lim = 64'd400000000;
    #(lim);
    $display("TIMEOUT phase=%0d layer=%0d", dut.phase, cur_l);
    timed_out = 1;
    report();
    $finish;
  end
endmodule
