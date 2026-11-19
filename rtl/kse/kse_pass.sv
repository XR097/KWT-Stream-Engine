`default_nettype none
// Row-store adapters for the Softmax and LayerNorm cores.

// Softmax phase: read S rows from A (4 per query), write P rows to B.
// Query t is started only when t < row_avail (Softmax may run during the last
// S column block); reads wait while a_busy (another unit writes A).  The
// output count rows_done tells PV which probability rows are complete.
module kse_sm_pass #(parameter int LANES = 8, parameter int NB = 2) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              start,
  output logic              done,
  input  logic [6:0]        row_avail,
  input  logic              a_busy,
  output logic [6:0]        rows_done,
  output logic              active,
  input  logic signed [7:0] q8_sh,
  output logic              a_rd_en,
  output logic [9:0]        a_rd_addr,
  input  logic [255:0]      rdata_a,
  output logic              b_wr_en,
  output logic [9:0]        b_wr_addr,
  output logic [255:0]      b_wr_data
);
  import kse_pkg::*;
  logic       run, issuing, rd_v;
  logic [6:0] ti, to;
  logic [1:0] k, cool;
  logic       row_ready, o_v, buf_free;
  logic [2:0] credit;
  logic reserve;
  logic [1:0] o_beat;
  logic [255:0] o_data;
  kse_softmax_core #(.LANES(LANES), .NB(NB)) u_core (
    .clk(clk), .rst_n(rst_n), .q8_sh(q8_sh), .in_valid(rd_v), .row_ready(row_ready), .buf_free(buf_free), .in_data(rdata_a),
    .out_valid(o_v), .out_beat(o_beat), .out_data(o_data));

  logic rd_now;
  assign reserve = run && !issuing && ti < 7'd99 && ti < row_avail && credit != 0;
  assign rd_now    = issuing && !a_busy;
  assign a_rd_en   = rd_now;
  assign a_rd_addr = A_S + {1'b0, ti, 2'b00} + 10'(k);
  assign rows_done = to;
  assign active    = run;
  assign b_wr_en   = o_v;
  assign b_wr_addr = B_P + {1'b0, to, 2'b00} + 10'(o_beat);
  assign b_wr_data = o_data;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      credit <= 3'(NB);
      run <= 1'b0; issuing <= 1'b0; rd_v <= 1'b0; ti <= '0; to <= '0; k <= '0; cool <= '0; done <= 1'b0;
    end else begin
      done <= 1'b0;
      credit <= credit - 3'(reserve) + 3'(buf_free);
      rd_v <= rd_now;
      if (cool != 0) cool <= cool - 1'b1;
      if (start) begin
        credit <= 3'(NB);
        run <= 1'b1; ti <= '0; to <= '0; k <= '0; cool <= '0; issuing <= 1'b0;
      end else if (run) begin
        if (issuing) begin
          if (rd_now) begin
            if (k == 2'd3) begin
              issuing <= 1'b0; k <= '0; ti <= ti + 1'b1; cool <= 2'd3;
            end else k <= k + 1'b1;
          end
        end else if (reserve) begin
          issuing <= 1'b1;
        end
        if (o_v && o_beat == 2'd3) begin
          to <= to + 1'b1;
          if (to == 7'd98) begin run <= 1'b0; done <= 1'b1; end
        end
      end
    end
  end
endmodule

// Residual + LayerNorm phase.
//   sel 0 (LN1): x = A[X] (input), y = B[PJ] (proj)  -> A[X]
//   sel 1 (LN2): x = A[X] (ln1),   y = A[F2] (fc2)   -> A[X]
// Token t is started only when t < tok_avail (LN2 may run concurrently with
// the last FC2 column block) and a core token buffer is free (credits).
// Port A is shared: when a_busy (the matrix engine writes A this cycle) the
// pass does nothing on A; otherwise a queued output row is written first,
// then reads are issued.  In-place is safe because a token's rows are read
// before its output rows are written.
module kse_ln_pass #(parameter int LANES = 8, parameter int NB = 6) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              start,
  input  logic              sel,
  output logic              done,
  input  logic [6:0]        tok_avail,
  input  logic              a_busy,
  input  logic              b_busy,       // LN1: B is written by FC1 this cycle
  output logic [6:0]        tok_written,  // tokens whose two output rows are in A
  input  logic signed [7:0] ax, ay, vsh, nsh, ash,
  input  logic [15:0]       eps,
  input  logic [64*16-1:0]  gamma,
  input  logic [64*8-1:0]   beta,
  output logic              a_en,
  output logic              a_we,
  output logic [9:0]        a_addr,
  output logic [255:0]      a_wdata,
  input  logic [255:0]      rdata_a,
  output logic              b_en,
  output logic [9:0]        b_addr,
  input  logic [255:0]      rdata_b,
  output logic              active,
  // verification visibility
  output logic              tap_res_valid,
  output logic [255:0]      tap_res
);
  import kse_pkg::*;
  logic        run, act, selq;
  logic [6:0]  ti, to;
  logic [1:0]  step;
  logic        tok_ready, buf_free, o_v, o_half, res_half;
  logic [3:0]  credit;       // free token buffers in the core
  logic [255:0] o_data;
  logic        c_v, c_half;
  logic [255:0] c_x, c_y, xhold;
  // Snapshot the active LN layer so the next layer header/weights can load
  // while these tokens are still in the residual/statistic/affine pipeline.
  logic signed [7:0] ax_q, ay_q, vsh_q, nsh_q, ash_q;
  logic [15:0] eps_q;
  always_ff @(posedge clk) if (start) begin
    ax_q <= ax; ay_q <= ay; vsh_q <= vsh; nsh_q <= nsh; ash_q <= ash;
    eps_q <= eps;
  end
  kse_ln_core #(.LANES(LANES), .NB(NB)) u_core (
    .clk(clk), .rst_n(rst_n), .ax(ax_q), .ay(ay_q), .vsh(vsh_q), .nsh(nsh_q), .ash(ash_q), .eps(eps_q),
    .gamma(gamma), .beta(beta), .tok_ready(tok_ready), .buf_free(buf_free), .in_valid(c_v), .in_half(c_half),
    .in_x(c_x), .in_y(c_y), .out_valid(o_v), .out_half(o_half), .out_data(o_data),
    .res_valid(tap_res_valid), .res_half(res_half), .res_data(tap_res));
  // Gamma/beta stay in the loader until this LN has drained. Only header
  // scalars need a snapshot when the next layer header is accepted early.
`ifndef SYNTHESIS
  logic [64*16-1:0] gamma_held;
  logic [64*8-1:0] beta_held;
  always_ff @(posedge clk) begin
    if (start) begin gamma_held <= gamma; beta_held <= beta; end
    else if (rst_n && run && (gamma !== gamma_held || beta !== beta_held))
      $error("kse_ln_pass: live affine parameters changed while LN active");
  end
`endif
  assign active = run;

  // output row queue (depth 4)
  logic [255:0] oq [4];
  logic [9:0]   oqa [4];
  logic [1:0]   oqw, oqr;
  logic [2:0]   oqn;
  logic         oq_pop;
  logic [7:0]   rows_wr;
  assign tok_written = rows_wr[7:1];
  assign oq_pop = (oqn != 0) && !a_busy;

  // read issue
  logic       issue;
  logic       last_step;
  assign issue     = run && act && !a_busy && (oqn == 0) && (selq || !b_busy);
  assign last_step = selq ? (step == 2'd3) : (step == 2'd1);
  always_comb begin
    a_en = 1'b0; a_we = 1'b0; a_addr = '0; a_wdata = oq[oqr];
    b_en = 1'b0; b_addr = '0;
    if (oq_pop) begin
      a_en = 1'b1; a_we = 1'b1; a_addr = oqa[oqr];
    end else if (issue) begin
      a_en = 1'b1;
      if (!selq) begin
        a_addr = A_X + {2'b0, ti, 1'b0} + 10'(step[0]);
        b_en   = 1'b1;
        b_addr = B_PJ + {2'b0, ti, 1'b0} + 10'(step[0]);
      end else begin
        a_addr = (step[0] ? A_F2 : A_X) + {2'b0, ti, 1'b0} + 10'(step[1]);
      end
    end
  end

  // data return
  logic       d_v, d_y, d_half;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) d_v <= 1'b0;
    else        d_v <= issue;
  end
  always_ff @(posedge clk) begin
    d_y    <= selq ? step[0] : 1'b1;
    d_half <= selq ? step[1] : step[0];
    if (d_v && !d_y) xhold <= rdata_a;
    if (o_v) begin
      oq[oqw]  <= o_data;
      oqa[oqw] <= A_X + {2'b0, to, 1'b0} + 10'(o_half);
    end
  end
  assign c_v    = d_v && d_y;
  assign c_half = d_half;
  assign c_x    = selq ? xhold : rdata_a;
  assign c_y    = selq ? rdata_a : rdata_b;

  logic can_start;
  assign can_start = !act && (ti < 7'd99) && (ti < tok_avail) && (credit != 0);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      run <= 1'b0; act <= 1'b0; ti <= '0; to <= '0; step <= '0; done <= 1'b0; selq <= 1'b0;
      credit <= 4'(NB); oqw <= '0; oqr <= '0; oqn <= '0; rows_wr <= '0;
    end else begin
      if (oq_pop) rows_wr <= rows_wr + 1'b1;
      done <= 1'b0;
      if (o_v) oqw <= oqw + 1'b1;
      if (oq_pop) oqr <= oqr + 1'b1;
      oqn <= oqn + 3'(o_v) - 3'(oq_pop);
      if (start) begin
        run <= 1'b1; act <= 1'b0; ti <= '0; to <= '0; step <= '0; selq <= sel;
        credit <= 4'(NB); rows_wr <= '0;
      end else if (run) begin
        // a token is started only with a free core buffer reserved for it
        credit <= credit - 4'(can_start) + 4'(buf_free);
        if (act) begin
          if (issue) begin
            if (last_step) begin
              act <= 1'b0; step <= '0; ti <= ti + 1'b1;
            end else step <= step + 1'b1;
          end
        end else if (can_start) begin
          act <= 1'b1;
        end
        if (o_v && o_half) to <= to + 1'b1;
        // finished when all 99 tokens are out and the queue has drained
        if (to == 7'd99 && oqn == 0) begin run <= 1'b0; done <= 1'b1; end
      end
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) if (o_v && oqn == 3'd4 && !oq_pop) $error("kse_ln_pass: output queue overflow");
`endif
endmodule
`default_nettype wire
