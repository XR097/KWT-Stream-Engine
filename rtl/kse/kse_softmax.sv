`default_nettype none
// Softmax over one 99-element score row (quantized reference softmax,
// compact Q15 exp table, P7, then u8 saturation):
//   delta = s - max; q8 = shift(delta, q8_sh); idx = rne(min(-q8, 4096), 4)
//   e = (q8 < -4096) ? 0 : EXP[idx]; total = sum(e)
//   p = clip(divide_rne(e << 7, total), 0, 255)
//
// Input: 4 beats of 32 bytes per row (bytes j = 32*beat + i, j >= 99 ignored).
// A new row may start only when row_ready=1; its 4 beats are then accepted
// unconditionally (they may arrive with gaps).  Output: 4 beats per row (out_beat = chunk index),
// bytes j >= 99 are 0.  Output has no back-pressure.
//
// Four row buffers: load+max -> exp sum (SUM_LANES per cycle) -> divide
// (LANES dividers, II=1).  Rows leave in order.
// Exp lane, 1-cycle latency: index computed and registered, ROM read after.
module kse_softmax_exp (
  input  logic              clk,
  input  logic signed [7:0] s,
  input  logic signed [7:0] mx,
  input  logic signed [7:0] q8_sh,
  input  logic              valid,
  output logic [15:0]       e
);
  logic signed [8:0]  delta;
  logic signed [23:0] q8;
  logic [23:0]        neg;
  logic [12:0]        idx;
  logic signed [13:0] cidx;
  logic [15:0]        rom;
  logic [8:0]         cidx_q;
  logic               zero_q;
  assign delta = 9'(s) - 9'(mx);
  kse_shift_rne #(.IW(9), .OW(24), .LMAX(15)) u_q8 (.x(delta), .sh(q8_sh), .y(q8));
  assign neg = -q8;
  assign idx = (neg > 24'd4096) ? 13'd4096 : neg[12:0];
  kse_shift_rne #(.IW(14), .OW(14), .LMAX(0)) u_c (.x($signed({1'b0, idx})), .sh(8'sd4), .y(cidx));
  always_ff @(posedge clk) begin
    cidx_q <= cidx[8:0];
    zero_q <= !valid || (q8 < -24'sd4096);
  end
  kse_exp_rom u_rom (.addr(cidx_q), .data(rom));
  assign e = zero_q ? 16'd0 : rom;
endmodule

module kse_softmax_core #(
  parameter int LANES     = 8,
  parameter int SUM_LANES = 32,
  parameter int NB = 2
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic signed [7:0] q8_sh,
  input  logic              in_valid,
  output logic              row_ready,
  output logic              buf_free,
  input  logic [255:0]      in_data,
  output logic              out_valid,
  output logic [1:0]        out_beat,
  output logic [255:0]      out_data
);
  localparam int N   = 99;
  localparam int NG  = (N + LANES - 1) / LANES;          // divide groups
  localparam int NSG = (N + SUM_LANES - 1) / SUM_LANES;  // sum groups
  localparam int GW  = $clog2(NG + 1);
  localparam int SGW = $clog2(NSG + 1);

  localparam int BW = $clog2(NB);
  // buffer state: 0 empty, 1 loading, 2 summing, 3 ready (wait divide)
  logic [1:0]        st   [NB];
  logic [7:0]        sbuf [NB][128];
  logic signed [7:0] bmax [NB];
  logic [21:0]       btot [NB];

  // ---------------- input register, load + max ----------------
  logic         iv;
  logic [255:0] idat;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) iv <= 1'b0;
    else        iv <= in_valid;
  end
  always_ff @(posedge clk) if (in_valid) idat <= in_data;
  logic [BW-1:0] lb;          // buffer being loaded / next to load
  logic [1:0] lbeat;
  assign row_ready = (st[lb] == 2'd0) && (lbeat == 2'd0) && !iv;
  // balanced max tree over the valid bytes of the beat
  logic signed [7:0] mt [63];
  for (genvar i = 0; i < 32; i++) begin : g_mleaf
    assign mt[31 + i] = (32 * lbeat + i < N) ? $signed(idat[i*8 +: 8]) : -8'sd128;
  end
  for (genvar i = 30; i >= 0; i--) begin : g_mnode
    assign mt[i] = (mt[2*i+1] > mt[2*i+2]) ? mt[2*i+1] : mt[2*i+2];
  end
  logic signed [7:0] bmax_n;
  assign bmax_n = (lbeat == 0 || mt[0] > bmax[lb]) ? mt[0] : bmax[lb];

  // ---------------- exp sum ----------------
  logic [BW-1:0] sb;      // buffer being summed
  logic [SGW-1:0]   sg;
  logic             sum_act;
  logic [15:0]      se   [SUM_LANES];
  logic [15:0]      se_q [SUM_LANES];
  logic             se_v, se_last, se_v1, se_last1;
  logic [BW-1:0] se_buf1, se_buf;
  logic [21:0]      sacc;
  logic             sacc_first;
  for (genvar l = 0; l < SUM_LANES; l++) begin : g_sum
    logic [7:0] j;
    assign j = 8'(sg * SUM_LANES + l);
    kse_softmax_exp u_e (.clk(clk), .s(sbuf[sb][j[6:0]]), .mx(bmax[sb]), .q8_sh(q8_sh),
                         .valid(sum_act && (j < N)), .e(se[l]));
  end
  logic [21:0] spart;
  always_comb begin
    spart = '0;
    for (int l = 0; l < SUM_LANES; l++) spart = spart + 22'(se_q[l]);
  end

  // ---------------- divide ----------------
  logic [BW-1:0] db;      // buffer being divided
  logic [GW-1:0]    dg;
  logic             div_act;
  logic [LANES-1:0] dq_v;
  logic [8:0]       dq    [LANES];
  logic [GW-1:0]    dq_g  [LANES];
  logic [21:0]   den1;
  logic [GW-1:0] dg1;
  always_ff @(posedge clk) begin
    den1 <= btot[db];
    dg1  <= dg;
  end
  for (genvar l = 0; l < LANES; l++) begin : g_div
    logic [7:0]  j;
    logic [15:0] e;
    logic        jv, jv1, dv_in;
    logic [22:0] dn_in;
    logic [21:0] dd_in;
    logic [GW-1:0] dt_in;
    assign j  = 8'(dg * LANES + l);
    assign jv = div_act && (j < N);
    kse_softmax_exp u_e (.clk(clk), .s(sbuf[db][j[6:0]]), .mx(bmax[db]), .q8_sh(q8_sh), .valid(jv), .e(e));
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin jv1 <= 1'b0; dv_in <= 1'b0; end
      else begin jv1 <= jv; dv_in <= jv1; end
    end
    always_ff @(posedge clk) begin
      dn_in <= {e, 7'd0};
      dd_in <= den1;
      dt_in <= dg1;
    end
    logic ovf;
    kse_udiv_rne #(.NW(23), .DW(22), .QW(8), .BPS(2), .TW(GW)) u_div (
      .clk(clk), .in_valid(dv_in), .in_n(dn_in), .in_d(dd_in), .in_tag(dt_in),
      .out_valid(dq_v[l]), .out_q(dq[l]), .out_ovf(ovf), .out_tag(dq_g[l]));
  end

  assign buf_free = div_act && (dg == GW'(NG - 1));

  // ---------------- output collect ----------------
  logic [7:0] obuf [128];
  logic [3:0] pend;   // chunk ready to emit (registered)

  function automatic logic [GW-1:0] chunk_end_group(input int k);
    int last;
    last = (k == 3) ? N - 1 : 32 * k + 31;
    return GW'(last / LANES);
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int b = 0; b < NB; b++) st[b] <= 2'd0;
      lb <= 1'b0; lbeat <= '0;
      sb <= 1'b0; sg <= '0; sum_act <= 1'b0;
      se_v <= 1'b0; se_last <= 1'b0; se_v1 <= 1'b0; se_last1 <= 1'b0;
      db <= 1'b0; dg <= '0; div_act <= 1'b0;
      pend <= '0;
      out_valid <= 1'b0;
    end else begin
      // load
      if (iv) begin
        bmax[lb] <= bmax_n;
        if (lbeat == 2'd3) begin
          st[lb] <= 2'd2;
          lb     <= lb + 1'b1;
          lbeat  <= '0;
        end else begin
          st[lb] <= 2'd1;
          lbeat  <= lbeat + 1'b1;
        end
      end
      // sum: start when buffer sb is in state 2
      se_buf1 <= sb;
      se_buf <= se_buf1;
      se_v1    <= sum_act;
      se_last1 <= sum_act && (sg == SGW'(NSG - 1));
      se_v     <= se_v1;
      se_last  <= se_last1;
      if (!sum_act) begin
        if (st[sb] == 2'd2) begin
          sum_act <= 1'b1;
          sg      <= '0;
        end
      end else begin
        if (sg == SGW'(NSG - 1)) begin sum_act <= 1'b0; sb <= sb + 1'b1; end
        else sg <= sg + 1'b1;
      end
      if (se_v) begin
        if (sacc_first) sacc <= spart;
        else            sacc <= sacc + spart;
        if (se_last) begin
          btot[se_buf] <= (sacc_first ? 22'd0 : sacc) + spart;
          st[se_buf] <= 2'd3;
        end
      end
      // divide: buffers are divided in order
      if (!div_act) begin
        if (st[db] == 2'd3) begin
          div_act <= 1'b1;
          dg      <= '0;
        end
      end else begin
        if (dg == GW'(NG - 1)) begin
          div_act <= 1'b0;
          st[db]  <= 2'd0;
          db      <= db + 1'b1;
        end else dg <= dg + 1'b1;
      end
      // collect
      out_valid <= 1'b0;
      if (dq_v[0]) begin
        for (int k = 0; k < 4; k++) if (dq_g[0] == chunk_end_group(k)) pend[k] <= 1'b1;
      end
      for (int k = 0; k < 4; k++) begin
        if (pend[k]) begin
          pend[k]   <= 1'b0;
          out_valid <= 1'b1;
          out_beat  <= 2'(k);
        end
      end
    end
  end

  // first sum group of a row
  logic se_first_q, se_first1;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin se_first_q <= 1'b0; se_first1 <= 1'b0; end
    else begin
      se_first1  <= sum_act && (sg == '0);
      se_first_q <= se_first1;
    end
  end
  assign sacc_first = se_first_q;

  always_ff @(posedge clk) begin
    if (iv)
      for (int i = 0; i < 32; i++) sbuf[lb][32*lbeat + i] <= idat[i*8 +: 8];
    if (se_v1)
      for (int l = 0; l < SUM_LANES; l++) se_q[l] <= se[l];
    for (int l = 0; l < LANES; l++) begin
      if (dq_v[l]) obuf[dq_g[l] * LANES + l] <= (dq[l] > 9'd255) ? 8'd255 : dq[l][7:0];
    end
  end

  // output data: registered obuf chunk, bytes >= N forced to zero
  always_comb begin
    for (int i = 0; i < 32; i++)
      out_data[i*8 +: 8] = (32 * out_beat + i < N) ? obuf[32 * out_beat + i] : 8'd0;
  end
endmodule
`default_nettype wire
