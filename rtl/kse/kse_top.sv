`default_nettype none
// KSE (KWT Stream Engine) top: one command = one KWT-1 encoder layer.
//
// Interfaces (all valid/ready, 32-bit words):
//   cmd    : cmd_layer (0..11), cmd_in_en (load X from act_in first),
//            cmd_out_en (stream the layer output on act_out at the end)
//   param  : the parameter stream (kse-param-stream-v3), continuous across
//            layers, buffered in a prefetch FIFO, back-pressured when it is full
//   act_in : 1584 words = 99x64 int8 row-major, little-endian bytes
//   act_out: 1584 words, same layout
//   done   : 1-cycle pulse when the layer (and its output stream) is complete
//
// Phases (strictly sequential; the loader runs concurrently):
//   IN -> QKV -> SC -> SM -> PV -> PJ -> LN1 -> FC1 -> FC2 -> LN2 -> OUT
// Logical A/B addresses are routed to independent Q/K, V, P and context
// macro groups; see docs/spec/kse_top.md for the physical map.
module kse_top #(
  parameter int R        = 32,
  parameter int C        = 32,
  parameter int SM_LANES = 8,
  parameter int LN_LANES = 8,
  // Ablation options: defaults retain control scheduling without extra RAM.
  parameter bit ATT_VCTX = 0,
  parameter bit ATT_PROB = 0,
  parameter bit PROB_BANKED = 0,
  parameter int SM_BUFFERS = 2,
  parameter bit USE_SHADOW = 0,
  parameter int PF_DEPTH = 128      // prefetch FIFO rows (128-bit): 1024 or 128
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        cmd_valid,
  output logic        cmd_ready,
  input  logic [3:0]  cmd_layer,
  input  logic        cmd_in_en,
  input  logic        cmd_out_en,
  input  logic        param_valid,
  output logic        param_ready,
  input  logic [31:0] param_data,
  input  logic        act_in_valid,
  output logic        act_in_ready,
  input  logic [31:0] act_in_data,
  output logic        act_out_valid,
  input  logic        act_out_ready,
  output logic [31:0] act_out_data,
  output logic        done,
  output logic        busy
);
  import kse_pkg::*;
  if ((R != 16 && R != 32) || C != 32) begin : g_bad_param
    $error("kse_top: supported array shapes are R=16/32,C=32");
  end

  // ---------------- phase control ----------------
  logic [3:0] phase;
  logic       started;
  logic [3:0] layer;
  logic       in_en, out_en;
  logic       lin_gate_hi, ln1_done;
  logic ln1_started, ln1_fin, ln1_go;
  logic       ldr_start, layer_start;
  logic       mm_start, sm_start, ln_start, in_start, out_start;
  logic       mm_done, sm_done, ln_done, in_done, out_done;
  logic       ldr_done;
  logic [1:0] ln_cnt;

  logic [10:0] mm_wr_count;
  logic next_pre_go, next_pre_started, pre_busy, pre_ready;
  logic ln_active, prev_ln2_pending, early_ready, early_hs;
  assign early_ready = (phase == PH_LN2) && !out_en && !cmd_in_en && ln_active && ldr_done && (!pre_busy || pre_ready);
  assign early_hs = early_ready && cmd_valid;
  assign cmd_ready = ((phase == PH_IDLE) && (!pre_busy || pre_ready)) || early_ready;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) prev_ln2_pending <= 1'b0;
    else if (early_hs) prev_ln2_pending <= 1'b1;
    else if (ln_done) prev_ln2_pending <= 1'b0;
  end
  assign busy      = (phase != PH_IDLE);

  logic start_now;
  always_comb begin
    start_now = 1'b0;
    case (phase)
      PH_IN, PH_QKV, PH_SC, PH_PJ, PH_FC2, PH_OUT: start_now = !started;
      PH_FC1: start_now = 1'b0;         // started early by fc1_go
      PH_SM, PH_PV: start_now = 1'b0;   // started early by sm_go / pv_go
      PH_LN1: start_now = !started && (ln_cnt >= 2'd1);
      PH_LN2: start_now = 1'b0;   // LN2 is started by ln2_go (possibly during FC2)
      default: start_now = 1'b0;
    endcase
  end
  assign in_start  = start_now && (phase == PH_IN);
  // attention overlap: Softmax starts with SC (rows gated by the last S
  // column block), PV starts as soon as SC is done (tokens gated by the
  // probability rows already written)
  logic sm_started, sm_fin, pv_started, pv_fin, sm_go, pv_go;
  logic [3:0] mm_phase;
  assign sm_go     = !sm_started && (phase == PH_SC);
  assign pv_go     = !pv_started && (phase == PH_SM);
  // FC1 starts while LN1 runs; its tokens are gated by the LN1 rows written
  logic fc1_started, fc1_fin, fc1_go;
  assign fc1_go    = !fc1_started && (phase == PH_LN1) && started;
  assign mm_start  = (start_now && (phase == PH_QKV || phase == PH_SC ||
                                    phase == PH_PJ || phase == PH_FC2)) || pv_go || fc1_go;
  assign mm_phase  = pv_go ? PH_PV : (fc1_go ? PH_FC1 : phase);
  assign sm_start  = sm_go;
  // LN2 starts as soon as its parameters are loaded, during the last FC2 column
  // block; tokens are gated by the FC2 output rows already written
  logic ln2_started, ln2_fin, ln2_go;
  assign next_pre_go = USE_SHADOW && !next_pre_started && phase == PH_FC2 && !out_en &&
                       cmd_valid && !cmd_in_en && ln2_started && mm_wr_count >= 11'd99;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) next_pre_started <= 1'b0;
    else if (layer_start) next_pre_started <= 1'b0;
    else if (next_pre_go) next_pre_started <= 1'b1;
  end
  assign ln2_go    = !ln2_started && (ln_cnt >= 2'd2) && (phase == PH_FC2 || phase == PH_LN2);
  assign ln1_go = !ln1_started && ln_cnt >= 2'd1 && (phase == PH_PJ || phase == PH_LN1);
  assign ln_start = ln1_go || ln2_go;
  logic out_started, out_fin;
  assign out_start = out_en && ln2_started && !out_started;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin out_started <= 1'b0; out_fin <= 1'b0; end
    else if (layer_start) begin out_started <= 1'b0; out_fin <= 1'b0; end
    else begin
      if (out_start) out_started <= 1'b1;
      if (out_done) out_fin <= 1'b1;
    end
  end

  logic phase_done;
  always_comb begin
    case (phase)
      PH_IN:  phase_done = in_done;
      PH_SM:  phase_done = sm_fin;
      PH_PV:  phase_done = pv_fin;
      PH_FC1: phase_done = fc1_fin;
      PH_LN1: phase_done = ln1_fin;
      PH_LN2: phase_done = ln2_fin;
      PH_OUT: phase_done = out_fin;
      default: phase_done = mm_done;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      phase <= PH_IDLE; started <= 1'b0; layer <= '0; in_en <= 1'b0; out_en <= 1'b0;
      lin_gate_hi <= 1'b0; ln1_done <= 1'b0; ln1_started <= 1'b0; ln1_fin <= 1'b0; done <= 1'b0; ldr_start <= 1'b0; layer_start <= 1'b0;
      ln2_started <= 1'b0; ln2_fin <= 1'b0;
      sm_started <= 1'b0; sm_fin <= 1'b0; pv_started <= 1'b0; pv_fin <= 1'b0;
      fc1_started <= 1'b0; fc1_fin <= 1'b0;
    end else begin
      if (ln1_go) ln1_started <= 1'b1;
      if (ln1_started && ln_done) ln1_fin <= 1'b1;
      if (ln2_go) ln2_started <= 1'b1;
      if (sm_go) sm_started <= 1'b1;
      if (pv_go) pv_started <= 1'b1;
      if (sm_started && sm_done) sm_fin <= 1'b1;
      if (pv_started && mm_done) pv_fin <= 1'b1;
      if (fc1_go) fc1_started <= 1'b1;
      if (fc1_started && mm_done) fc1_fin <= 1'b1;
      if (ln2_started && ln_done) ln2_fin <= 1'b1;
      done <= 1'b0; ldr_start <= 1'b0; layer_start <= 1'b0;
      if (start_now) started <= 1'b1;
      if ((phase == PH_IDLE && cmd_valid && cmd_ready) || early_hs) begin
          layer <= cmd_layer; in_en <= cmd_in_en; out_en <= cmd_out_en;
          lin_gate_hi <= 1'b0; ln1_done <= 1'b0; ln1_started <= 1'b0; ln1_fin <= 1'b0; ln2_started <= 1'b0; ln2_fin <= 1'b0;
          sm_started <= 1'b0; sm_fin <= 1'b0; pv_started <= 1'b0; pv_fin <= 1'b0;
          fc1_started <= 1'b0; fc1_fin <= 1'b0;
          ldr_start <= 1'b1; layer_start <= 1'b1;
          started <= 1'b0;
          phase <= cmd_in_en ? PH_IN : PH_QKV;
      end else begin
      case (phase)
        PH_FIN: if (ldr_done) begin
          done <= 1'b1; phase <= PH_IDLE;
        end
        default: if ((started || phase == PH_LN2 || phase == PH_SM || phase == PH_PV || phase == PH_FC1) && phase_done) begin
          started <= 1'b0;
          case (phase)
            PH_IN:  phase <= PH_QKV;
            PH_QKV: phase <= PH_SC;
            PH_SC:  phase <= PH_SM;
            PH_SM:  phase <= PH_PV;
            PH_PV:  begin phase <= PH_PJ; lin_gate_hi <= 1'b1; end
            PH_PJ:  phase <= PH_LN1;
            PH_LN1: begin phase <= PH_FC1; ln1_done <= 1'b1; end
            PH_FC1: phase <= PH_FC2;
            PH_FC2: phase <= PH_LN2;
            PH_LN2: phase <= out_en ? PH_OUT : PH_FIN;
            default: phase <= PH_FIN;
          endcase
        end
      endcase
      end
      if (prev_ln2_pending && ln_done) done <= 1'b1;
    end
  end

  // ---------------- loader ----------------
  logic signed [7:0] h_score_sh, h_q8_sh, h_ctx_sh, h_gelu_tail, h_res1_ax, h_res1_ay, h_res2_ax, h_res2_ay;
  logic signed [7:0] h_ln1_vsh, h_ln1_nsh, h_ln1_ash, h_gelu_lo, h_ln2_vsh, h_ln2_nsh, h_ln2_ash, h_gelu_hi;
  logic [15:0]       h_ln1_eps, h_ln2_eps;
  logic [4:0]        ld_cb, post_cb_done;
  logic [7:0]        fr_slot;
  logic [4*C*16-1:0] meta_bias;
  logic [4*C*5-1:0]  meta_shift;
  logic [3:0]        meta_bias_en;
  logic [64*16-1:0]  ln_gamma;
  logic [64*8-1:0]   ln_beta;
  logic [R-1:0]      lw_row_we;
  logic [C*8-1:0]    lw_row_data;
  logic [3:0]        lw_slot;
  logic lw_shadow;
  // parameter prefetch FIFO: accepts the stream continuously, independent of
  // the layer sequencing; the loader takes 128-bit rows
  logic         pf_valid, pf_ready;
  logic [127:0] pf_data;
  logic [$clog2(PF_DEPTH):0] pf_level;
  kse_pfifo #(.DEPTH(PF_DEPTH)) u_pf (
    .clk(clk), .rst_n(rst_n), .in_valid(param_valid), .in_ready(param_ready), .in_data(param_data),
    .out_valid(pf_valid), .out_ready(pf_ready), .out_data(pf_data), .level(pf_level));

  kse_loader #(.R(R), .C(C), .USE_SHADOW(USE_SHADOW)) u_ldr (
    .clk(clk), .rst_n(rst_n), .start(ldr_start), .pre_start(next_pre_go), .pre_busy(pre_busy), .pre_ready(pre_ready),
    .param_valid(pf_valid), .param_ready(pf_ready), .param_data(pf_data),
    .lin_gate_hi(lin_gate_hi), .pj_gate(phase == PH_SC || phase == PH_SM || phase == PH_PV), .ln1_done(ln1_done), .fr_slot(fr_slot), .post_cb_done(post_cb_done),
    .ld_cb(ld_cb), .ln_cnt(ln_cnt), .done(ldr_done),
    .hdr_score_sh(h_score_sh), .hdr_q8_sh(h_q8_sh), .hdr_ctx_sh(h_ctx_sh), .hdr_gelu_tail(h_gelu_tail),
    .hdr_res1_ax(h_res1_ax), .hdr_res1_ay(h_res1_ay), .hdr_res2_ax(h_res2_ax), .hdr_res2_ay(h_res2_ay),
    .hdr_ln1_vsh(h_ln1_vsh), .hdr_ln1_nsh(h_ln1_nsh), .hdr_ln1_ash(h_ln1_ash), .hdr_gelu_lo(h_gelu_lo),
    .hdr_ln2_vsh(h_ln2_vsh), .hdr_ln2_nsh(h_ln2_nsh), .hdr_ln2_ash(h_ln2_ash), .hdr_gelu_hi(h_gelu_hi),
    .hdr_ln1_eps(h_ln1_eps), .hdr_ln2_eps(h_ln2_eps),
    .meta_bias(meta_bias), .meta_shift(meta_shift), .meta_bias_en(meta_bias_en),
    .ln_gamma(ln_gamma), .ln_beta(ln_beta),
    .lw_row_we(lw_row_we), .lw_row_data(lw_row_data), .lw_slot(lw_slot), .lw_shadow(lw_shadow));

  // ---------------- row stores ----------------
  logic         a_en, a_we, b_en, b_we;
  logic [9:0]   a_addr, b_addr;
  logic [255:0] a_wdata, b_wdata, a_rdata, b_rdata;
  logic pp_rd_en; logic [8:0] pp_rd_addr;
  logic ap_en, ap_we, bp_en, bp_we, vp_en, vp_we, pp_en, pp_we, cp_en, cp_we;
  logic [9:0] ap_addr, bp_addr, pp_addr;
  logic [7:0] vp_addr, cp_addr;
  logic [255:0] vp_data, pp_data, cp_data, vp_q, pp_q, cp_q, mm_b_q;
  logic [1:0] mm_bank_q;
  logic [255:0] mm_a_q;
  kse_rowstore #(.NM(16)) u_rsa (.clk(clk), .en(ap_en), .we(ap_we), .addr(ap_addr), .wdata(a_wdata), .rdata(a_rdata));
  kse_rowstore #(.NM(16)) u_rsb (.clk(clk), .en(bp_en), .we(bp_we), .addr(bp_addr), .wdata(b_wdata), .rdata(b_rdata));

  logic [255:0] vc_q;
  assign vp_q = vc_q;
  assign cp_q = vc_q;
  if (ATT_VCTX) begin : g_vctx
  kse_vctxstore u_rsvc (.clk(clk),
    .rd_en((vp_en && !vp_we) || (cp_en && !cp_we)),
    .rd_addr((cp_en && !cp_we) ? cp_addr : vp_addr),
    .wr_en((vp_en && vp_we) || (cp_en && cp_we)),
    .wr_addr((cp_en && cp_we) ? cp_addr : vp_addr),
    .wdata((cp_en && cp_we) ? cp_data : vp_data), .rdata(vc_q));
  end else assign vc_q = '0;
  if (ATT_PROB && PROB_BANKED) begin : g_prob_banked
  kse_probstore u_rsp (.clk(clk),
    .rd_en(pp_rd_en), .rd_addr(pp_rd_addr), .wr_en(pp_en && pp_we), .wr_addr(pp_addr[8:0]), .wdata(pp_data), .rdata(pp_q));

  end else if (ATT_PROB) begin : g_prob_plain
    // One actual single-port group. SM writes take priority over PV reads.
    kse_rowstore #(.NM(16)) u_rsp (.clk(clk), .en(pp_rd_en || (pp_en && pp_we)),
      .we(pp_en && pp_we), .addr((pp_en && pp_we) ? pp_addr : {1'b0,pp_rd_addr}),
      .wdata(pp_data), .rdata(pp_q));
  end else assign pp_q = '0;

  // ---------------- matrix engine ----------------
  logic         mm_rd_en, mm_rd_mem, mm_wr_en, mm_wr_mem;
  logic [9:0]   mm_rd_addr, mm_wr_addr;
  logic [255:0] mm_wr_data;
  logic         tap_pre_valid;
  logic [255:0] tap_pre;

  logic         mm_rd_hold;
  logic [6:0]   mm_tok_avail, sm_rows_done, sm_row_avail;
  logic         sm_active;
  logic [6:0]   ln_tok_written;
  logic         ln_a_en;
  logic [15:0]  tap_tag;
  kse_mm #(.R(R), .C(C), .USE_SHADOW(USE_SHADOW)) u_mm (
    .clk(clk), .rst_n(rst_n), .start(mm_start), .phase(mm_phase), .done(mm_done), .layer(layer),
    .lw_shadow(lw_shadow),
    .rd_hold(mm_rd_hold), .tok_avail(mm_tok_avail),
    .score_sh(h_score_sh), .ctx_sh(h_ctx_sh), .gelu_lo(h_gelu_lo), .gelu_hi(h_gelu_hi), .gelu_tail(h_gelu_tail),
    .ld_cb(ld_cb), .meta_bias(meta_bias), .meta_shift(meta_shift), .meta_bias_en(meta_bias_en),
    .lw_row_we(lw_row_we), .lw_row_data(lw_row_data), .lw_slot(lw_slot),
    .fr_slot(fr_slot), .post_cb_done(post_cb_done), .layer_start(layer_start),
    .rd_en(mm_rd_en), .rd_mem(mm_rd_mem), .rd_addr(mm_rd_addr), .rdata_a(mm_a_q), .rdata_b(mm_b_q),
    .wr_en(mm_wr_en), .wr_mem(mm_wr_mem), .wr_addr(mm_wr_addr), .wr_data(mm_wr_data),
    .tap_pre_valid(tap_pre_valid), .tap_pre(tap_pre), .tap_tag(tap_tag), .wr_count(mm_wr_count));

  // ---------------- softmax ----------------
  logic         sm_a_rd_en, sm_b_wr_en;
  logic [9:0]   sm_a_rd_addr, sm_b_wr_addr;
  logic [255:0] sm_b_wr_data;
  // S(t,3) is the last row of query t, written by the last SC column block
  assign sm_row_avail = (phase == PH_SC) ? ((mm_wr_count >= 11'd198) ? 7'((mm_wr_count - 11'd198) >> 1) : 7'd0) : 7'd99;
  assign mm_tok_avail = prev_ln2_pending ? ln_tok_written : (phase == PH_SM) ? sm_rows_done : ((phase == PH_LN1) ? ln_tok_written : 7'd99);
  logic sm_port_conflict;
  assign sm_port_conflict = sm_active && sm_b_wr_en &&
      (ATT_PROB ? (phase != PH_SC && mm_rd_addr >= B_P &&
                    (!PROB_BANKED || mm_rd_addr[1:0] == sm_b_wr_addr[1:0])) :
                  (phase == PH_SC || mm_rd_addr >= B_P || !ATT_VCTX));
  assign mm_rd_hold = sm_port_conflict ||
      ((phase == PH_LN1 || prev_ln2_pending || (phase == PH_PJ && !ATT_VCTX)) && ln_a_en);
  kse_sm_pass #(.LANES(SM_LANES), .NB(SM_BUFFERS)) u_sm (
    .clk(clk), .rst_n(rst_n), .start(sm_start), .done(sm_done), .q8_sh(h_q8_sh),
    .row_avail(sm_row_avail), .a_busy(mm_wr_en && mm_wr_mem == MEM_A && (phase == PH_SC || !ATT_VCTX)), .rows_done(sm_rows_done), .active(sm_active),
    .a_rd_en(sm_a_rd_en), .a_rd_addr(sm_a_rd_addr), .rdata_a(a_rdata),
    .b_wr_en(sm_b_wr_en), .b_wr_addr(sm_b_wr_addr), .b_wr_data(sm_b_wr_data));

  // ---------------- residual + layernorm ----------------
  logic         ln_sel;
  logic         ln_a_we, ln_b_en;
  logic [9:0]   ln_a_addr, ln_b_addr;
  logic [255:0] ln_a_wdata;
  logic         tap_res_valid;
  logic [255:0] tap_res;
  assign ln_sel = (phase == PH_FC2 || phase == PH_LN2);
  logic [6:0]  ln_tok_avail;
  logic        ln_a_busy;
  assign ln_tok_avail = (phase == PH_PJ) ? ((mm_wr_count >= 11'd99) ? 7'(mm_wr_count-11'd99) : 7'd0) : (phase == PH_FC2) ? ((mm_wr_count >= 11'd99) ? 7'(mm_wr_count - 11'd99) : 7'd0) : 7'd99;
  assign ln_a_busy    = (phase == PH_FC2) && mm_wr_en && (mm_wr_mem == MEM_A);
  kse_ln_pass #(.LANES(LN_LANES)) u_ln (
    .clk(clk), .rst_n(rst_n), .start(ln_start), .sel(ln_sel), .done(ln_done),
    .tok_avail(ln_tok_avail), .a_busy(ln_a_busy), .active(ln_active),
    .b_busy((phase == PH_LN1 || phase == PH_PJ) && mm_wr_en && mm_wr_mem == MEM_B), .tok_written(ln_tok_written),
    .ax(ln_sel ? h_res2_ax : h_res1_ax), .ay(ln_sel ? h_res2_ay : h_res1_ay),
    .vsh(ln_sel ? h_ln2_vsh : h_ln1_vsh), .nsh(ln_sel ? h_ln2_nsh : h_ln1_nsh),
    .ash(ln_sel ? h_ln2_ash : h_ln1_ash), .eps(ln_sel ? h_ln2_eps : h_ln1_eps),
    .gamma(ln_gamma), .beta(ln_beta),
    .a_en(ln_a_en), .a_we(ln_a_we), .a_addr(ln_a_addr), .a_wdata(ln_a_wdata), .rdata_a(a_rdata),
    .b_en(ln_b_en), .b_addr(ln_b_addr), .rdata_b(b_rdata),
    .tap_res_valid(tap_res_valid), .tap_res(tap_res));

  // ---------------- activation input ----------------
  logic         in_run;
  logic [10:0]  in_cnt;
  logic [223:0] in_buf;
  logic         in_wr;
  logic [9:0]   in_row;
  logic [255:0] in_row_data;
  assign act_in_ready = in_run;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin in_run <= 1'b0; in_cnt <= '0; in_wr <= 1'b0; in_done <= 1'b0; end
    else begin
      in_wr <= 1'b0; in_done <= 1'b0;
      if (in_start) begin in_run <= 1'b1; in_cnt <= '0; end
      else if (in_run && act_in_valid) begin
        in_cnt <= in_cnt + 1'b1;
        if (in_cnt[2:0] == 3'd7) in_wr <= 1'b1;
        if (in_cnt == 11'd1583) in_run <= 1'b0;
      end
      if (in_wr && in_row == A_X + 10'd197) in_done <= 1'b1;
    end
  end
  always_ff @(posedge clk) begin
    if (in_run && act_in_valid) begin
      if (in_cnt[2:0] == 3'd7) begin
        in_row_data <= {act_in_data, in_buf};
        in_row      <= A_X + 10'(in_cnt[10:3]);
      end else in_buf[in_cnt[2:0]*32 +: 32] <= act_in_data;
    end
  end

  // ---------------- activation output ----------------
  logic         out_run;
  logic [7:0]   out_rd_row;      // rows issued
  logic         out_rd_en, out_rd_v;
  logic [255:0] ofifo [2];
  logic [1:0]   ocount;          // rows buffered
  logic         owp, orp;
  logic [2:0]   owi;
  logic [10:0]  out_cnt;
  logic         out_pop;
  assign out_rd_en     = out_run && (out_rd_row < 8'd198) &&
                         ((phase == PH_OUT) || ((phase == PH_FC2 || phase == PH_LN2) &&
                          out_rd_row < {ln_tok_written, 1'b0} && !ln_a_en &&
                          !(mm_wr_en && mm_wr_mem == MEM_A))) && ((2'(ocount) + 2'(out_rd_v)) < 2'd2);
  assign act_out_valid = out_run && (ocount != 0);
  assign act_out_data  = ofifo[orp][owi*32 +: 32];
  assign out_pop       = act_out_valid && act_out_ready && (owi == 3'd7);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_run <= 1'b0; out_rd_row <= '0; out_rd_v <= 1'b0; ocount <= '0; owp <= 1'b0; orp <= 1'b0;
      owi <= '0; out_cnt <= '0; out_done <= 1'b0;
    end else begin
      out_done <= 1'b0;
      out_rd_v <= out_rd_en;
      if (out_start) begin
        out_run <= 1'b1; out_rd_row <= '0; ocount <= '0; owp <= 1'b0; orp <= 1'b0; owi <= '0; out_cnt <= '0;
      end else if (out_run) begin
        if (out_rd_en) out_rd_row <= out_rd_row + 1'b1;
        if (out_rd_v) owp <= ~owp;
        ocount <= ocount + 2'(out_rd_v) - 2'(out_pop);
        if (act_out_valid && act_out_ready) begin
          owi <= owi + 1'b1;
          out_cnt <= out_cnt + 1'b1;
          if (owi == 3'd7) orp <= ~orp;
          if (out_cnt == 11'd1583) begin out_run <= 1'b0; out_done <= 1'b1; end
        end
      end
    end
  end
  always_ff @(posedge clk) if (out_rd_v) ofifo[owp] <= a_rdata;

  // ---------------- row-store port multiplexing ----------------
  always_comb begin
    a_en = 1'b0; a_we = 1'b0; a_addr = '0; a_wdata = mm_wr_data;
    b_en = 1'b0; b_we = 1'b0; b_addr = '0; b_wdata = mm_wr_data;
    case (phase)
      PH_IN: begin
        a_en = in_wr; a_we = 1'b1; a_addr = in_row; a_wdata = in_row_data;
      end
      PH_QKV, PH_PJ, PH_FC1, PH_FC2: begin
        if ((phase == PH_FC2 && ln_active) || (phase == PH_QKV && prev_ln2_pending) || (phase == PH_PJ && ln_active)) begin
          // LN2 runs concurrently: it uses A whenever FC2 does not write it
          a_en = ln_a_en; a_we = ln_a_we; a_addr = ln_a_addr; a_wdata = ln_a_wdata;
        end
        if (mm_rd_en && mm_rd_mem == MEM_A && (phase != PH_PJ || !ATT_VCTX)) begin a_en = 1'b1; a_addr = mm_rd_addr; end
        if (mm_wr_en && mm_wr_mem == MEM_A) begin a_en = 1'b1; a_we = 1'b1; a_addr = mm_wr_addr; a_wdata = mm_wr_data; end
        if (phase == PH_PJ && ln_b_en) begin b_en = 1'b1; b_addr = ln_b_addr; end
        if (mm_rd_en && mm_rd_mem == MEM_B) begin b_en = 1'b1; b_addr = mm_rd_addr; end
        if (mm_wr_en && mm_wr_mem == MEM_B) begin b_en = 1'b1; b_we = 1'b1; b_addr = mm_wr_addr; end
      end
      PH_SC, PH_SM, PH_PV: begin
        // SC/PV read B and write A; Softmax reads A and writes B.
        // A: matrix writes win, Softmax reads wait (a_busy).
        // B: Softmax writes win, matrix reads wait (rd_hold).
        if (sm_a_rd_en) begin a_en = 1'b1; a_addr = sm_a_rd_addr; end
        if (mm_wr_en) begin a_en = 1'b1; a_we = 1'b1; a_addr = mm_wr_addr; a_wdata = mm_wr_data; end
        if (mm_rd_en) begin b_en = 1'b1; b_addr = mm_rd_addr; end
        if (sm_b_wr_en) begin b_en = 1'b1; b_we = 1'b1; b_addr = sm_b_wr_addr; b_wdata = sm_b_wr_data; end
      end
      PH_LN1: begin
        // LN1 with FC1 starting behind it: LN1 owns A (FC1 reads wait via
        // rd_hold), FC1 writes to B win (LN1 waits via b_busy)
        if (mm_rd_en && mm_rd_mem == MEM_A) begin a_en = 1'b1; a_addr = mm_rd_addr; end
        if (ln_a_en) begin a_en = 1'b1; a_we = ln_a_we; a_addr = ln_a_addr; a_wdata = ln_a_wdata; end
        if (ln_b_en) begin b_en = 1'b1; b_addr = ln_b_addr; end
        if (mm_wr_en && mm_wr_mem == MEM_B) begin b_en = 1'b1; b_we = 1'b1; b_addr = mm_wr_addr; b_wdata = mm_wr_data; end
      end
      PH_LN2: begin
        a_en = ln_a_en; a_we = ln_a_we; a_addr = ln_a_addr; a_wdata = ln_a_wdata;
        b_en = ln_b_en; b_addr = ln_b_addr;
      end
      PH_OUT: begin
        a_en = out_rd_en; a_addr = A_X + 10'(out_rd_row);
      end
      default: ;
    endcase
    if (out_rd_en) begin a_en = 1'b1; a_we = 1'b0; a_addr = A_X + 10'(out_rd_row); end
  end

  // Logical taps are invariant across physical storage configurations.
  assign pp_rd_en = ATT_PROB && mm_rd_en && (phase == PH_SM || phase == PH_PV) && mm_rd_addr >= B_P;
  assign pp_rd_addr = 9'(mm_rd_addr-B_P);
  assign mm_a_q = (phase == PH_PJ && ATT_VCTX) ? cp_q : a_rdata;
  always_ff @(posedge clk) if (mm_rd_en) begin
    if (ATT_PROB && (phase == PH_SM || phase == PH_PV) && mm_rd_addr >= B_P) mm_bank_q <= 2'd2;
    else if (ATT_VCTX && (phase == PH_SM || phase == PH_PV) && mm_rd_addr < B_P) mm_bank_q <= 2'd1;
    else mm_bank_q <= 2'd0;
  end
  assign mm_b_q = (mm_bank_q == 2'd2) ? pp_q : ((mm_bank_q == 2'd1) ? vp_q : b_rdata);
  always_comb begin
    ap_en = a_en; ap_we = a_we; ap_addr = a_addr; bp_en = b_en; bp_we = b_we; bp_addr = b_addr;
    vp_en = 1'b0; vp_we = 1'b0; vp_addr = 8'(b_addr-B_V); vp_data = b_wdata;
    pp_en = 1'b0; pp_we = 1'b0; pp_addr = mm_rd_addr-B_P; pp_data = sm_b_wr_data;
    cp_en = 1'b0; cp_we = 1'b0; cp_addr = 8'(mm_wr_addr-A_CTX); cp_data = mm_wr_data;
    if (ATT_VCTX && phase == PH_QKV && b_we && b_addr >= B_V) begin
      bp_en = 1'b0; vp_en = b_en; vp_we = b_we;
    end
    if (phase == PH_SC || phase == PH_SM || phase == PH_PV) begin
      bp_en = mm_rd_en && (phase == PH_SC ||
          (mm_rd_addr < B_P ? !ATT_VCTX : !ATT_PROB));
      bp_we = 1'b0; bp_addr = mm_rd_addr;
      if (phase != PH_SC) begin
        vp_en = ATT_VCTX && mm_rd_en && mm_rd_addr < B_P;
        vp_addr = 8'(mm_rd_addr-B_V);
        pp_en = ATT_PROB && mm_rd_en && mm_rd_addr >= B_P;
        if (ATT_VCTX) begin
          ap_en = sm_a_rd_en; ap_we = 1'b0; ap_addr = sm_a_rd_addr;
          cp_en = mm_wr_en; cp_we = 1'b1;
        end
      end
      if (sm_b_wr_en) begin
        if (ATT_PROB) begin pp_en = 1'b1; pp_we = 1'b1; pp_addr = sm_b_wr_addr-B_P; end
        else begin bp_en = 1'b1; bp_we = 1'b1; bp_addr = sm_b_wr_addr; end
      end
    end
    if (phase == PH_PJ && ATT_VCTX) begin
      ap_en = ln_a_en; ap_we = ln_a_we; ap_addr = ln_a_addr;
      cp_en = mm_rd_en; cp_addr = 8'(mm_rd_addr-A_CTX);
    end
  end

`ifndef SYNTHESIS
  // a single-port macro must never see a read and a write in the same cycle
  always_ff @(posedge clk) begin
    if ((phase == PH_QKV || phase == PH_SC || phase == PH_PV || phase == PH_PJ || phase == PH_FC1 || phase == PH_FC2) &&
        mm_rd_en && mm_wr_en && (mm_rd_mem == mm_wr_mem))
      $error("kse_top: row-store port conflict in phase %0d", phase);
    if ((phase == PH_SC || phase == PH_SM || phase == PH_PV) &&
        ((sm_a_rd_en && mm_wr_en && (phase == PH_SC || !ATT_VCTX)) ||
         (mm_rd_en && sm_port_conflict)))
      $error("kse_top: attention port conflict in phase %0d", phase);
    if (phase == PH_LN1 && ((ln_a_en && mm_rd_en) || (ln_b_en && mm_wr_en)))
      $error("kse_top: LN1/FC1 port conflict");
  end
`endif
endmodule
`default_nettype wire
