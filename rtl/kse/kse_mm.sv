`default_nettype none
// KSE matrix engine: MAC array + 32 post-processing lanes + the sequencer for
// every matrix phase of a layer.
//
//   phase  stationary operand            streamed rows          output rows
//   QKV    Wq/Wk/Wv (loader, W4)          X  A[X+2t+kb]          Q/K/V B[0/200/400 + 2t + cb]
//   SC     K   (column-load from B)       Q  B[Q+2t+kb]          S    A[S+4t+cb]
//   PV     V   (row-load from B)          P  B[P+4t+kb] (u8)     ctx  A[CTX+2t+cb]
//   PJ     Wproj (loader)                 ctx A[CTX+2t+kb]       proj B[PJ+2t+cb]
//   FC1    Wfc1  (loader), GELU           X1 A[X+2t+kb]          H    B[H+8t+cb]
//   FC2    Wfc2  (loader), K=256          H  B[H+8t+kb]          F2   A[F2+2t+cb]
//
// Each column block (cb, 32 output channels) streams all 99 tokens; a token
// takes KB consecutive steps (one 32-byte row each) and produces one output
// row.  Linear phases wait for the loader (ld_cb > cbseq); attention phases
// load K/V themselves through the B port before streaming.
module kse_mm #(
  parameter int R = 32,
  parameter int C = 32,
  parameter bit USE_SHADOW = 1
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               start,
  input  logic [3:0]         phase,      // kse_pkg::PH_*
  output logic               done,       // pulse
  input  logic [3:0]         layer,
  input  logic signed [7:0]  score_sh, ctx_sh, gelu_lo, gelu_hi, gelu_tail,
  // loader interface
  input  logic [4:0]         ld_cb,
  input  logic [4*C*16-1:0]  meta_bias,
  input  logic [4*C*5-1:0]   meta_shift,
  input  logic [3:0]         meta_bias_en,
  input  logic [R-1:0]       lw_row_we,
  input  logic [C*8-1:0]     lw_row_data,
  input  logic [3:0]         lw_slot,
  output logic [7:0]         fr_slot,
  output logic [4:0]         post_cb_done,
  input  logic               layer_start,  // clears the per-layer bookkeeping
  input  logic               lw_shadow,
  input  logic               rd_hold,      // row-store read port taken by another unit
  input  logic [6:0]         tok_avail,    // PV/FC1: input rows of tokens < tok_avail are written
  // row stores
  output logic               rd_en,
  output logic               rd_mem,       // 0 A, 1 B
  output logic [9:0]         rd_addr,
  input  logic [255:0]       rdata_a,
  input  logic [255:0]       rdata_b,
  output logic               wr_en,
  output logic               wr_mem,
  output logic [9:0]         wr_addr,
  output logic [255:0]       wr_data,
  // verification visibility: post stage-1 values (fc1 before GELU)
  output logic               tap_pre_valid,
  output logic [255:0]       tap_pre,
  output logic [15:0]        tap_tag,
  output logic [10:0]        wr_count     // output rows written in this phase
);
  import kse_pkg::*;
  localparam int TW = 16;

  // ---------------- phase configuration ----------------
  logic [3:0] ph;
  logic       is_lin, is_sc, is_pv;
  logic [4:0] cb_first;
  logic [3:0] cb_count, ncb;
  logic [4:0] kbn;
  logic       in_mem, out_mem;
  logic [9:0] in_base, out_base, ld_base;
  logic       gelu_en;
  always_comb begin
    is_lin = 1'b1; is_sc = 1'b0; is_pv = 1'b0;
    cb_first = 5'd0; cb_count = 4'd2; kbn = (R == 16) ? 5'd4 : 5'd2; ncb = 4'd2;
    in_mem = MEM_A; out_mem = MEM_B; in_base = 10'd0; out_base = 10'd0; ld_base = 10'd0;
    gelu_en = 1'b0;
    case (ph)
      PH_QKV: begin cb_first = 5'd0;  cb_count = 4'd6; in_base = A_X;   out_base = B_Q; end
      PH_PJ:  begin cb_first = 5'd6;  in_base = A_CTX; out_base = B_PJ; end
      PH_FC1: begin cb_first = 5'd8;  cb_count = 4'd8; ncb = 4'd8; in_base = A_X; out_base = B_H; gelu_en = 1'b1; end
      PH_FC2: begin cb_first = 5'd16; kbn = (R == 16) ? 5'd16 : 5'd8; in_mem = MEM_B; out_mem = MEM_A; in_base = B_H; out_base = A_F2; end
      PH_SC:  begin is_lin = 1'b0; is_sc = 1'b1; cb_count = 4'd4; in_mem = MEM_B; out_mem = MEM_A;
                    in_base = B_Q; out_base = A_S; ld_base = B_K; ncb = 4'd4; end
      PH_PV:  begin is_lin = 1'b0; is_pv = 1'b1; kbn = (R == 16) ? 5'd8 : 5'd4; in_mem = MEM_B; out_mem = MEM_A;
                    in_base = B_P; out_base = A_CTX; ld_base = B_V; end
      default: ;
    endcase
  end

  // ---------------- sequencer ----------------
  typedef enum logic [2:0] {M_IDLE, M_WAITW, M_LOAD, M_ZERO, M_STREAM, M_DRAIN} mst_t;
  mst_t ms;
  logic [3:0]  cbl;        // local column block
  logic [6:0]  t;
  logic [4:0]  kb;
  logic [8:0]  li;         // load index (doubled in R=16 column-load mode)
  logic [7:0]  mm_slot;    // cumulative slots of linear column blocks started
  logic [3:0]  sbase;
  logic [4:0]  cbseq;
  logic [5:0]  nvalid;     // valid K columns in this SC column block
  logic [10:0] wr_cnt;
  logic [10:0] wr_total;
  logic [7:0]  li0;
  assign li0 = (R == 16) ? li[8:1] : li[7:0];

  assign cbseq = cb_first + 5'(cbl);
  always_comb begin
    if (cbl == 4'd3) nvalid = 6'd3;          // keys 96..98
    else             nvalid = 6'd32;
  end

  // issue-cycle control (registered into *_d for the cycle the data returns)
  logic          st_v, st_first, st_last, st_lastcb;
  logic [3:0]    st_slot;
  logic [TW-1:0] st_tag;
  logic          lo_v, lo_col, lo_zero;
  logic [4:0]    lo_idx;
  logic [3:0]    lo_slot;
  logic [31:0]   lo_mask;

  // issue is held while another unit owns the read port, and (PV, FC1) until
  // the input rows of the streamed token have been written (Softmax / LN1)
  logic hold;
  assign hold = rd_hold || ((is_pv || ph == PH_FC1 || ph == PH_QKV) && ms == M_STREAM && t >= tok_avail);
  always_comb begin
    rd_en = 1'b0; rd_mem = in_mem; rd_addr = '0;
    st_v = 1'b0; st_first = (kb == 5'd0); st_last = (kb == kbn - 1);
    st_lastcb = st_last && (t == 7'd98);
    st_slot = is_lin ? ((R == 16) ? 4'(sbase + kb) : {1'b0,3'(sbase[2:0] + kb[2:0])}) :
                       (is_sc ? ((R == 16) ? {1'b0,cbl[0],kb[1:0]} : {2'b0,cbl[0],kb[0]}) : kb[3:0]);
    st_tag = {st_lastcb, cbseq[1:0], 2'b0, cbl[2:0], 1'b0, t};
    lo_v = 1'b0; lo_col = is_sc; lo_zero = 1'b0; lo_idx = '0; lo_slot = '0; lo_mask = '0;
    case (ms)
      M_STREAM: begin
        rd_en   = !hold;
        rd_mem  = in_mem;
          rd_addr = in_base + 10'(t) * 10'(kbn >> (R == 16)) +
                    10'(R == 16 ? (kb >> 1) : kb);
        st_v    = !hold;
      end
      M_LOAD: begin
        rd_en = !hold;
        rd_mem = MEM_B;
        lo_v = !hold;
        if (is_sc) begin
          // li = 2*c + kb
          lo_idx  = li0[5:1];
          lo_slot = (R == 16) ? {li0[6],li0[0],li[0]} : {1'b0,li0[6],li0[0]};
          rd_addr = ld_base + 10'({cbl[1],6'd0} + 7'(li0[7:1])) * 10'd2 + 10'(li0[0]);
        end else begin
          // li = 32*kb + r  (token j = li)
          lo_idx  = (R == 16) ? {1'b0,li[3:0]} : li[4:0];
          lo_slot = (R == 16) ? {1'b0,li[6:4]} : {2'b0,li[6:5]};
          rd_addr = ld_base + 10'(li) * 10'd2 + 10'(cbl[0]);
        end
      end
      M_ZERO: begin
        lo_v = 1'b1; lo_zero = 1'b1;
        if (is_sc) begin
          lo_slot = (R == 16) ? {1'b0,1'b1,li[1:0]} : {2'b0,1'b1,li[0]};
          lo_mask = 32'hfffffff8;
        end else begin
          lo_slot = (R == 16) ? (li[0] ? 4'd7 : 4'd6) : 4'd3;
          lo_mask = ((R == 16) && li[0]) ? 32'hFFFF_FFFF : 32'hFFFF_FFF8;     // rows 3..31 of kb 3 (tokens 99..127)
        end
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ms <= M_IDLE; cbl <= '0; t <= '0; kb <= '0; li <= '0; mm_slot <= '0; sbase <= '0;
      done <= 1'b0; ph <= PH_IDLE;
    end else begin
      done <= 1'b0;
      if (layer_start) mm_slot <= '0;
      case (ms)
        M_IDLE: if (start) begin
          ph <= phase; cbl <= '0; t <= '0; kb <= '0; li <= '0;
          ms <= (phase == PH_SC || phase == PH_PV) ? M_LOAD : M_WAITW;
        end
        M_WAITW: if (ld_cb > cbseq) begin
          sbase <= (R == 16) ? mm_slot[3:0] : {1'b0,mm_slot[2:0]};
          mm_slot <= mm_slot + 8'(kbn);
          ms <= M_STREAM;
        end
        M_LOAD: if (!hold) begin
          if ((is_sc && li == (cbl[1] ? ((R == 16) ? 9'd139 : 9'd69) : ((R == 16) ? 9'd255 : 9'd127))) ||
              (is_pv && li == 9'd98)) begin
            li <= '0;
            ms <= (is_sc && !cbl[1]) ? M_STREAM : M_ZERO;
          end else li <= li + 1'b1;
        end
        M_ZERO: begin
          if (li < ((R == 16) ? (is_sc ? 9'd3 : 9'd1) : (is_sc ? 9'd1 : 9'd0))) li <= li + 1'b1;
          else begin li <= '0; ms <= M_STREAM; end
        end
        M_STREAM: if (!hold) begin
          if (kb == kbn - 1) begin
            kb <= '0;
            if (is_sc) begin
              if (!cbl[0]) cbl <= cbl + 1'b1;
              else if (t == 7'd98) begin
                t <= '0;
                if (cbl[1]) ms <= M_DRAIN;
                else begin cbl <= 4'd2; li <= '0; ms <= M_LOAD; end
              end else begin cbl <= cbl - 1'b1; t <= t + 1'b1; end
            end else if (t == 7'd98) begin
              t <= '0;
              if (cbl == cb_count - 1) ms <= M_DRAIN;
              else begin
                cbl <= cbl + 1'b1;
                ms  <= is_lin ? M_WAITW : M_LOAD;
              end
            end else t <= t + 1'b1;
          end else kb <= kb + 1'b1;
        end
        M_DRAIN: if (wr_cnt == wr_total) begin
          ms <= M_IDLE; done <= 1'b1; ph <= PH_IDLE;
        end
        default: ms <= M_IDLE;
      endcase
    end
  end

  // ---------------- data-return cycle ----------------
  logic          d_st_v, d_first, d_last, d_lo_v, d_lo_col, d_lo_zero, d_uns, d_w4;
  logic [3:0]    d_slot, d_lo_slot;
  logic          d_lo_half;
  logic [TW-1:0] d_tag;
  logic [4:0]    d_lo_idx;
  logic [31:0]   d_lo_mask;
  logic          d_mem;
  logic          d_half;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin d_st_v <= 1'b0; d_lo_v <= 1'b0; end
    else begin d_st_v <= st_v; d_lo_v <= lo_v; end
  end
  always_ff @(posedge clk) begin
    d_first <= st_first; d_last <= st_last; d_slot <= st_slot; d_tag <= st_tag;
    d_uns <= is_pv; d_w4 <= is_lin; d_mem <= rd_mem;
    d_half <= (R == 16) ? kb[0] : 1'b0;
    d_lo_col <= lo_col; d_lo_zero <= lo_zero; d_lo_slot <= lo_slot; d_lo_idx <= lo_idx; d_lo_mask <= lo_mask;
    d_lo_half <= (R == 16) ? li[0] : 1'b0;
  end
  logic [255:0] rdata;
  assign rdata = d_mem ? rdata_b : rdata_a;
  logic [R*8-1:0] arr_in;
  assign arr_in = (R == 16) ? (d_half ? rdata[255:128] : rdata[127:0]) : rdata;

  // load stage (registered, presented to the array one cycle after data return)
  logic [R-1:0]   a_row_we;
  logic [C*8-1:0] a_row_data;
  logic [C-1:0]   a_col_we;
  logic [R*8-1:0] a_col_data;
  logic [3:0]     a_ld_slot;
  logic           a_ld_w4;
  logic [R-1:0]   m_row_we;
  logic [C-1:0]   m_col_we;
  logic [255:0]   m_ld_data;
  logic [3:0]     m_ld_slot;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_row_we <= '0; m_col_we <= '0; end
    else begin
      m_row_we <= '0; m_col_we <= '0;
      if (d_lo_v) begin
        if (d_lo_zero) begin
          if (d_lo_col) m_col_we <= d_lo_mask; else m_row_we <= d_lo_mask;
        end else begin
          if (d_lo_col) m_col_we <= C'(1) << d_lo_idx; else m_row_we <= R'(1) << d_lo_idx;
        end
      end
    end
  end
  always_ff @(posedge clk) begin
    if (d_lo_v) begin
      m_ld_data <= d_lo_zero ? '0 : ((R == 16 && d_lo_col) ? (d_lo_half ? rdata[255:128] : rdata[127:0]) : rdata);
      m_ld_slot <= d_lo_slot;
    end
  end
  logic att;
  assign att = is_sc | is_pv;
  always_comb begin
    if (att) begin
      a_row_we = m_row_we; a_row_data = m_ld_data; a_col_we = m_col_we; a_col_data = m_ld_data;
      a_ld_slot = m_ld_slot; a_ld_w4 = 1'b0;
    end else begin
      a_row_we = lw_row_we & {R{!lw_shadow}}; a_row_data = lw_row_data; a_col_we = '0; a_col_data = '0;
      a_ld_slot = lw_slot; a_ld_w4 = 1'b1;
    end
  end

  // ---------------- array ----------------
  logic          o_v, s2v, s2l;
  logic [C*24-1:0] o_acc;
  logic [TW-1:0] o_tag, s2t;
  kse_mac_array #(.R(R), .C(C), .TW(TW)) u_arr (
    .clk(clk), .rst_n(rst_n),
    .pj_row_we(lw_row_we & {R{lw_shadow}}),
    .pj_row_data(lw_row_data), .pj_slot(lw_slot[0]), .in_pj(USE_SHADOW && ((ph == PH_PJ && d_tag[10:8] == 0) || (ph == PH_FC2 && d_tag[10:8] == 1 && d_slot < 2))),
    .ld_row_we(a_row_we), .ld_row_data(a_row_data), .ld_col_we(a_col_we), .ld_col_data(a_col_data),
    .ld_slot(a_ld_slot), .ld_w4(a_ld_w4),
    .in_valid(d_st_v), .in_a(arr_in), .in_uns(d_uns), .in_slot(d_slot), .in_w4(d_w4),
    .in_first(d_first), .in_last(d_last), .in_tag(d_tag),
    .out_valid(o_v), .out_acc(o_acc), .out_tag(o_tag),
    .s2_valid(s2v), .s2_last(s2l), .s2_tag(s2t));

  // slot bookkeeping: a linear column block frees its slots when its last step
  // reads the resident registers (S2)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) fr_slot <= '0;
    else if (layer_start) fr_slot <= '0;
    else if (s2v && s2l && s2t[15] && is_lin) fr_slot <= fr_slot + 8'(kbn);
  end

  // ---------------- post-processing ----------------
  logic [1:0] o_entry;
  assign o_entry = o_tag[14:13];
  logic [255:0] pre_v, y_v;
  for (genvar c = 0; c < C; c++) begin : g_post
    logic signed [15:0] bias;
    logic signed [7:0]  sh;
    always_comb begin
      if (is_lin) begin
        bias = meta_bias_en[o_entry] ? $signed(meta_bias[(o_entry*C + c)*16 +: 16]) : 16'sd0;
        sh   = 8'($signed(meta_shift[(o_entry*C + c)*5 +: 5]));
      end else begin
        bias = 16'sd0;
        sh   = is_sc ? score_sh : ctx_sh;
      end
    end
    kse_post_lane u_lane (.clk(clk), .in_valid(o_v), .acc($signed(o_acc[c*24 +: 24])), .bias(bias), .sh(sh),
                          .gelu_en(gelu_en), .layer(layer), .gelu_lo(gelu_lo), .gelu_hi(gelu_hi),
                          .gelu_tail(gelu_tail), .pre(pre_v[c*8 +: 8]), .y(y_v[c*8 +: 8]));
  end
  logic          p1_v, p2_v, p3_v;
  logic [TW-1:0] p1_tag, p2_tag, p3_tag;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin p1_v <= 1'b0; p2_v <= 1'b0; p3_v <= 1'b0; end
    else begin p1_v <= o_v; p2_v <= p1_v; p3_v <= p2_v; end
  end
  always_ff @(posedge clk) begin
    if (o_v)  p1_tag <= o_tag;
    if (p1_v) p2_tag <= p1_tag;
    if (p2_v) p3_tag <= p2_tag;
  end
  assign tap_pre_valid = p2_v;
  assign tap_pre       = pre_v;
  assign tap_tag       = p2_tag;

  // output row address from the tag
  logic [6:0] w_t;
  logic [2:0] w_cbl;
  assign w_t   = p3_tag[6:0];
  assign w_cbl = p3_tag[10:8];
  always_comb begin
    wr_en   = p3_v;
    wr_mem  = out_mem;
    wr_data = y_v;
    if (is_lin)
      wr_addr = out_base + 10'(w_t) * 10'(ncb) + ((ph == PH_QKV) ? 10'(w_cbl[2:1]) * 10'd200 + 10'(w_cbl[0]) : 10'(w_cbl));
    else if (is_sc)
      wr_addr = out_base + 10'(w_t) * 10'd4 + 10'(w_cbl);
    else
      wr_addr = out_base + 10'(w_t) * 10'd2 + 10'(w_cbl);
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin wr_cnt <= '0; post_cb_done <= '0; end
    else begin
      if (start) wr_cnt <= '0;
      else if (p3_v) wr_cnt <= wr_cnt + 1'b1;
      if (layer_start) post_cb_done <= '0;
      else if (p3_v && p3_tag[15] && is_lin) post_cb_done <= post_cb_done + 1'b1;
    end
  end
  assign wr_total = 11'(cb_count) * 11'd99;
  assign wr_count = wr_cnt;
endmodule
`default_nettype wire
