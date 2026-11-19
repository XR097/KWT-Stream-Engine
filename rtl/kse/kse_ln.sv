`default_nettype none
// Residual lane: r = sat8(shift(x, ax) + shift(y, ay))
// (quantized reference _residual followed by A8 saturation).
module kse_residual (
  input  logic signed [7:0] x,
  input  logic signed [7:0] y,
  input  logic signed [7:0] ax,
  input  logic signed [7:0] ay,
  output logic signed [7:0] r
);
  logic signed [15:0] sx, sy;
  logic signed [16:0] t;
  kse_shift_rne #(.IW(8), .OW(16), .LMAX(7)) u_x (.x(x), .sh(ax), .y(sx));
  kse_shift_rne #(.IW(8), .OW(16), .LMAX(7)) u_y (.x(y), .sh(ay), .y(sy));
  assign t = 17'(sx) + 17'(sy);
  kse_sat #(.IW(17), .OW(8)) u_s (.x(t), .y(r));
endmodule

// Residual + LayerNorm over 64 channels (quantized reference layernorm, method
// "reference", Q12/Q12), single-pass statistics:
//   S = sum(r), Q = sum(r^2); square_sum = 64^2*Q - 64*S^2  (== sum((64r-S)^2))
//   variance = rne(square_sum / 2^18); vq = shift(variance, vsh) + eps
//   den = 64 * isqrt(vq); num_e = shift(64 r_e - S, nsh)
//   n_e = divide_rne(num_e, den); out_e = sat8(shift(n_e * gamma_e, ash) + beta_e)
// The divider quotient is 30 bits; larger magnitudes (only possible for
// near-zero variance) are clamped to 2^30-1, which leaves the saturated output
// unchanged as long as ash <= 20 (checked by pack_params.py).
//
// Input: 2 beats per token (half 0 = channels 0..31, half 1 = 32..63), each
// with the residual operands x and y.  A token may start when tok_ready=1
// (or, for a producer that tracks credits, when one of the NB buffers is
// known to be free: buf_free pulses once per freed buffer, in order);
// both beats are then accepted unconditionally.  Output: 2 beats per token,
// no back-pressure.  NB token buffers: fill -> statistics/isqrt -> divide.
module kse_ln_core #(
  parameter int LANES = 8,
  parameter int NB    = 3
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic signed [7:0]  ax,
  input  logic signed [7:0]  ay,
  input  logic signed [7:0]  vsh,
  input  logic signed [7:0]  nsh,
  input  logic signed [7:0]  ash,
  input  logic [15:0]        eps,
  input  logic [64*16-1:0]   gamma,
  input  logic [64*8-1:0]    beta,
  output logic               tok_ready,
  output logic               buf_free,
  input  logic               in_valid,
  input  logic               in_half,
  input  logic [255:0]       in_x,
  input  logic [255:0]       in_y,
  output logic               out_valid,
  output logic               out_half,
  output logic [255:0]       out_data,
  // residual tap (registered residual values, for verification visibility)
  output logic               res_valid,
  output logic               res_half,
  output logic [255:0]       res_data
);
  localparam int NG  = 64 / LANES;
  localparam int GW  = (NG > 1) ? $clog2(NG) : 1;
  localparam int BW  = (NB > 1) ? $clog2(NB) : 1;

  function automatic logic [BW-1:0] nxt(input logic [BW-1:0] b);
    return (b == BW'(NB - 1)) ? '0 : b + 1'b1;
  endfunction

  // buffer state: 0 empty, 1 fill, 2 stat (wait V), 3 ready (wait/doing D)
  logic [1:0]          st   [NB];
  logic [7:0]          tbuf [NB][64];
  logic signed [13:0]  bS   [NB];
  logic [20:0]         bQ   [NB];
  logic [23:0]         bden [NB];

  // ---------------- input / R1: residual ----------------
  logic [BW-1:0] rb_in;
  logic          half0_seen;
  assign tok_ready = (st[rb_in] == 2'd0) && !half0_seen;
  logic [255:0]  rr_n;
  for (genvar i = 0; i < 32; i++) begin : g_res
    kse_residual u_r (.x(in_x[i*8 +: 8]), .y(in_y[i*8 +: 8]), .ax(ax), .ay(ay), .r(rr_n[i*8 +: 8]));
  end
  logic          r1_v, r1_half;
  logic [BW-1:0] r1_b;
  logic [255:0]  r1_d;
  assign res_valid = r1_v;
  assign res_half  = r1_half;
  assign res_data  = r1_d;

  // ---------------- R2: half sums ----------------
  logic signed [12:0] hs_n;
  logic [19:0]        hq_n;
  logic signed [15:0] sq_i;
  always_comb begin
    sq_i = '0;
    hs_n = '0;
    hq_n = '0;
    for (int i = 0; i < 32; i++) begin
      hs_n = hs_n + 13'($signed(r1_d[i*8 +: 8]));
      sq_i = 16'($signed(r1_d[i*8 +: 8])) * 16'($signed(r1_d[i*8 +: 8]));
      hq_n = hq_n + 20'(sq_i);
    end
  end
  logic               r2_v, r2_half;
  logic [BW-1:0]      r2_b;
  logic signed [12:0] r2_s;
  logic [19:0]        r2_q;
  logic signed [13:0] s_acc;
  logic [20:0]        q_acc;

  // ---------------- V: statistics, variance (P), isqrt (Q, two units) ----------------
  logic [BW-1:0]      pb, p_buf;
  logic [1:0]         pph;     // 0 idle, 1 ss, 2 variance, 3 vq
  logic               p_full;
  logic signed [33:0] ss_q;
  logic signed [15:0] var_q;
  logic [35:0]        vq_q;
  logic signed [26:0] s2;
  logic signed [33:0] ss_n;
  logic signed [15:0] var_n;
  logic signed [35:0] vqs_n;
  assign s2   = bS[pb] * bS[pb];
  assign ss_n = ($signed({1'b0, bQ[pb]}) <<< 12) - (34'(s2) <<< 6);
  kse_shift_rne #(.IW(34), .OW(16), .LMAX(0)) u_var (.x(ss_q), .sh(8'sd18), .y(var_n));
  kse_shift_rne #(.IW(16), .OW(36), .LMAX(20)) u_vq (.x(var_q), .sh(vsh), .y(vqs_n));
  logic [1:0]    sq_start, sq_busy, sq_done, q_act;
  logic [17:0]   root [2];
  logic [BW-1:0] q_buf [2];
  for (genvar u = 0; u < 2; u++) begin : g_sqrt
    kse_isqrt #(.IW(36), .BPC(2)) u_sqrt (.clk(clk), .rst_n(rst_n), .start(sq_start[u]), .n(vq_q),
                                          .root(root[u]), .busy(sq_busy[u]), .done(sq_done[u]));
  end
  assign sq_start[0] = p_full && !q_act[0];
  assign sq_start[1] = p_full && q_act[0] && !q_act[1];

  // ---------------- D: normalize/divide ----------------
  localparam int DTW = GW + 1;   // {sign, group}
  logic [BW-1:0]  db;
  logic           d_act;
  logic [GW-1:0]  dg;
  logic [LANES-1:0]   dv_o;
  logic [30:0]        dq_o  [LANES];
  logic               dovf_o[LANES];
  logic [GW:0]        dtag_o[LANES];
  logic [23:0]        den_q;
  logic               dv_q;
  logic [GW-1:0]      dg_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) dv_q <= 1'b0;
    else        dv_q <= d_act;
  end
  always_ff @(posedge clk) begin
    den_q <= bden[db];
    dg_q  <= dg;
  end
  for (genvar l = 0; l < LANES; l++) begin : g_div
    logic [5:0]         e;
    logic signed [15:0] c;
    logic signed [38:0] num;
    logic [37:0]        mag, mag_q;
    logic               sgn_q;
    assign e   = 6'(dg * LANES + l);
    assign c   = (16'($signed(tbuf[db][e])) <<< 6) - 16'(bS[db]);
    kse_shift_rne #(.IW(16), .OW(39), .LMAX(23)) u_n (.x(c), .sh(nsh), .y(num));
    assign mag = num[38] ? 38'(-num) : 38'(num);
    always_ff @(posedge clk) begin
      mag_q <= mag;
      sgn_q <= num[38];
    end
    kse_udiv_rne #(.NW(38), .DW(24), .QW(30), .BPS(2), .TW(DTW)) u_div (
      .clk(clk), .in_valid(dv_q), .in_n(mag_q), .in_d(den_q), .in_tag({sgn_q, dg_q}),
      .out_valid(dv_o[l]), .out_q(dq_o[l]), .out_ovf(dovf_o[l]), .out_tag(dtag_o[l]));
  end

  // ---------------- M0..M3: clamp/sign, gamma, shift, beta, saturate ----------------
  logic               m0_v, m1_v, m2_v, m3_v;
  logic [GW-1:0]      m0_g, m1_g, m2_g, m3_g;
  logic signed [31:0] m0_n [LANES];
  logic [15:0]        m0_gm [LANES];
  logic signed [48:0] m1_p [LANES];
  logic signed [48:0] m2_a [LANES];
  logic signed [7:0]  m2_b [LANES];
  logic [7:0]         m3_y [LANES];
  for (genvar l = 0; l < LANES; l++) begin : g_aff
    logic signed [31:0] nrm;
    logic [30:0]        qm;
    logic [5:0]         e1, e2;
    logic signed [48:0] aff;
    logic signed [49:0] t;
    logic signed [7:0]  ysat;
    assign qm  = dovf_o[l] ? 31'h3FFF_FFFF : dq_o[l];
    assign nrm = dtag_o[l][GW] ? -$signed({1'b0, qm}) : $signed({1'b0, qm});
    assign e1  = 6'(dtag_o[l][GW-1:0] * LANES + l);
    assign e2  = 6'(m1_g * LANES + l);
    kse_shift_rne #(.IW(49), .OW(49), .LMAX(0)) u_a (.x(m1_p[l]), .sh(ash), .y(aff));
    assign t = 50'(m2_a[l]) + 50'(m2_b[l]);
    kse_sat #(.IW(50), .OW(8)) u_s (.x(t), .y(ysat));
    always_ff @(posedge clk) begin
      if (dv_o[l]) begin
        m0_n[l]  <= nrm;
        m0_gm[l] <= gamma[e1*16 +: 16];
      end
      if (m0_v) m1_p[l] <= m0_n[l] * $signed({1'b0, m0_gm[l]});
      if (m1_v) begin
        m2_a[l] <= aff;
        m2_b[l] <= $signed(beta[e2*8 +: 8]);
      end
      if (m2_v) m3_y[l] <= ysat;
    end
  end

  logic [7:0] obuf [64];
  logic [1:0] pend;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int b = 0; b < NB; b++) st[b] <= 2'd0;
      rb_in <= '0; half0_seen <= 1'b0;
      r1_v <= 1'b0; r2_v <= 1'b0;
      pb <= '0; pph <= '0; p_full <= 1'b0; q_act <= '0;
      db <= '0; d_act <= 1'b0; dg <= '0;
      m0_v <= 1'b0; m1_v <= 1'b0; m2_v <= 1'b0; m3_v <= 1'b0; buf_free <= 1'b0;
      pend <= '0; out_valid <= 1'b0; out_half <= 1'b0;
    end else begin
      // input side
      r1_v <= in_valid;
      if (in_valid) begin
        if (!in_half) begin
          half0_seen <= 1'b1;
          st[rb_in]  <= 2'd1;
        end else begin
          half0_seen <= 1'b0;
          rb_in      <= nxt(rb_in);
        end
      end
      // R2 -> R3 accumulate
      r2_v <= r1_v;
      if (r2_v) begin
        if (!r2_half) begin
          s_acc <= 14'(r2_s);
          q_acc <= 21'(r2_q);
        end else begin
          bS[r2_b]  <= s_acc + 14'(r2_s);
          bQ[r2_b]  <= q_acc + 21'(r2_q);
          st[r2_b]  <= 2'd2;
        end
      end
      // V: P stage (ss, variance, vq) then Q stage (isqrt), in buffer order
      case (pph)
        2'd0: if (st[pb] == 2'd2 && !p_full) pph <= 2'd1;
        2'd1: pph <= 2'd2;
        2'd2: pph <= 2'd3;
        default: begin
          pph    <= 2'd0;
          p_full <= 1'b1;
          p_buf  <= pb;
          pb     <= nxt(pb);
        end
      endcase
      for (int u = 0; u < 2; u++) begin
        if (sq_start[u]) begin
          q_act[u] <= 1'b1;
          q_buf[u] <= p_buf;
          p_full   <= 1'b0;
        end
        if (q_act[u] && sq_done[u]) begin
          bden[q_buf[u]] <= {root[u], 6'd0};
          st[q_buf[u]]   <= 2'd3;
          q_act[u]       <= 1'b0;
        end
      end
      // D
      if (!d_act) begin
        if (st[db] == 2'd3) begin
          d_act <= 1'b1;
          dg    <= '0;
        end
      end else begin
        if (dg == GW'(NG - 1)) begin
          // continue with the next token without a bubble if it is ready
          d_act  <= (st[nxt(db)] == 2'd3);
          dg     <= '0;
          st[db] <= 2'd0;
          buf_free <= 1'b1;
          db     <= nxt(db);
        end else dg <= dg + 1'b1;
      end
      // M stages
      if (!(d_act && dg == GW'(NG - 1))) buf_free <= 1'b0;
      m0_v <= dv_o[0];
      m1_v <= m0_v;
      m2_v <= m1_v;
      m3_v <= m2_v;
      // output
      out_valid <= 1'b0;
      if (m3_v) begin
        if (m3_g == GW'(31 / LANES)) pend[0] <= 1'b1;
        if (m3_g == GW'(63 / LANES)) pend[1] <= 1'b1;
      end
      if (pend[0]) begin
        pend[0]   <= 1'b0;
        out_valid <= 1'b1;
        out_half  <= 1'b0;
      end else if (pend[1]) begin
        pend[1]   <= 1'b0;
        out_valid <= 1'b1;
        out_half  <= 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (in_valid) begin
      r1_d    <= rr_n;
      r1_half <= in_half;
      r1_b    <= rb_in;
    end
    if (r1_v) begin
      r2_s    <= hs_n;
      r2_q    <= hq_n;
      r2_half <= r1_half;
      r2_b    <= r1_b;
      for (int i = 0; i < 32; i++) tbuf[r1_b][32*r1_half + i] <= r1_d[i*8 +: 8];
    end
    if (pph == 2'd1) ss_q  <= ss_n;
    if (pph == 2'd2) var_q <= var_n;
    if (pph == 2'd3) vq_q  <= 36'(vqs_n) + 36'(eps);
    if (dv_o[0]) m0_g <= dtag_o[0][GW-1:0];
    if (m0_v)    m1_g <= m0_g;
    if (m1_v)    m2_g <= m1_g;
    if (m2_v)    m3_g <= m2_g;
    if (m3_v) for (int l = 0; l < LANES; l++) obuf[m3_g * LANES + l] <= m3_y[l];
  end

  always_comb begin
    for (int i = 0; i < 32; i++) out_data[i*8 +: 8] = obuf[32*out_half + i];
  end
endmodule
`default_nettype wire
