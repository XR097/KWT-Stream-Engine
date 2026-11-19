`default_nettype none
// KSE parameter loader: consumes the per-layer parameter stream (format
// kse-param-stream-v3, tools/kse/pack_params.py, docs/spec/kse_top.md) in
// order, one 128-bit row (4 words) per cycle from the prefetch FIFO, and
// distributes it:
//   header      -> hdr_* registers (2 rows)
//   bias/shift  -> 4-entry per-column-block metadata buffer (entry = cbseq % 4)
//   W4 weights  -> MAC array row-loads (1 row = one PE row, 32 nibbles)
//   gamma/beta  -> LayerNorm parameter registers
// Back-pressure (param_ready=0) whenever the destination is not free:
//   - linears proj/fc1/fc2 wait for lin_gate_hi (attention no longer owns the
//     resident registers)
//   - a column block waits until its metadata entry is free
//     (cbseq < post_cb_done + 4); each of its KB reduction blocks waits until
//     its resident slot is free (ld_slot + 1 - fr_slot <= 8), so a K=256 block
//     can start loading into the slots already released by earlier blocks
//   - LN2 parameters wait for ln1_done
module kse_loader #(
  parameter int R = 32,
  parameter int C = 32,
  parameter bit USE_SHADOW = 1
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                start,
  input logic pre_start,
  output logic pre_busy, pre_ready,
  input  logic                param_valid,
  output logic                param_ready,
  input  logic [127:0]        param_data,
  // gating / bookkeeping
  input  logic                lin_gate_hi,
  input  logic                pj_gate,
  input  logic                ln1_done,
  input  logic [7:0]          fr_slot,
  input  logic [4:0]          post_cb_done,
  output logic [4:0]          ld_cb,
  output logic [1:0]          ln_cnt,
  output logic                done,
  // header
  output logic signed [7:0]   hdr_score_sh, hdr_q8_sh, hdr_ctx_sh, hdr_gelu_tail,
  output logic signed [7:0]   hdr_res1_ax, hdr_res1_ay, hdr_res2_ax, hdr_res2_ay,
  output logic signed [7:0]   hdr_ln1_vsh, hdr_ln1_nsh, hdr_ln1_ash, hdr_gelu_lo,
  output logic signed [7:0]   hdr_ln2_vsh, hdr_ln2_nsh, hdr_ln2_ash, hdr_gelu_hi,
  output logic [15:0]         hdr_ln1_eps, hdr_ln2_eps,
  // metadata
  output logic [4*C*16-1:0]   meta_bias,
  output logic [4*C*5-1:0]    meta_shift,
  output logic [3:0]          meta_bias_en,
  // LayerNorm parameters
  output logic [64*16-1:0]    ln_gamma,
  output logic [64*8-1:0]     ln_beta,
  // array row-load
  output logic [R-1:0]        lw_row_we,
  output logic [C*8-1:0]      lw_row_data,
  output logic                lw_shadow,
  output logic [3:0]          lw_slot
);
  typedef enum logic [3:0] {S_IDLE, S_HDR, S_GATE, S_BIAS, S_SHIFT, S_W, S_LNG, S_LNB, S_LN2W, S_DONE, S_PREF_HOLD} st_t;
  st_t st;
  logic prefetch_mode;
  assign pre_busy = prefetch_mode;
  assign pre_ready = prefetch_mode && st == S_PREF_HOLD && ld_cb != 0;

  logic [2:0]  lin;       // 0 q 1 k 2 v 3 proj 4 fc1 5 fc2
  logic [2:0]  cb;        // column block within linear
  logic [4:0]  cbseq;     // column block within layer
  logic [10:0] wcnt;      // word counter within field
  logic [7:0]  ld_slot;   // cumulative resident slots handed out
  logic [3:0]  sbase;
  logic [1:0]  entry;
  logic        lnsel;     // 0 LN1, 1 LN2

  logic [4:0] kb_of;
  logic [3:0] ncb_of;
  logic       bias_of;
  always_comb begin
    kb_of   = (lin == 3'd5) ? ((R == 16) ? 5'd16 : 5'd8) : ((R == 16) ? 5'd4 : 5'd2);
    ncb_of  = (lin == 3'd4) ? 4'd8 : 4'd2;
    bias_of = (lin >= 3'd3);
  end
  assign entry = cbseq[1:0];

  logic gate_ok;
  assign gate_ok = ((lin < 3'd3) || lin_gate_hi || (USE_SHADOW && pj_gate && lin == 3'd3 && cb == 0)) &&
                   (cbseq < post_cb_done + 5'd4);
  logic kb_ok;
  assign kb_ok = prefetch_mode || ((ld_slot + 8'd1 - fr_slot) <= ((R == 16) ? 8'd16 : 8'd8)) ||
                 (USE_SHADOW && lin == 3'd5 && cb == 3'd1 && wcnt < 11'd64);

  assign param_ready = (st == S_HDR) || (st == S_BIAS) || (st == S_SHIFT) || (st == S_W && kb_ok) ||
                       (st == S_LNG) || (st == S_LNB);
  logic acc_w;
  assign acc_w = param_valid && param_ready;

  // weight rows: row j of a column block = PE row j%32 of reduction block j/32
  logic [4:0]  wr;
  logic [3:0]  wkb;
  assign wr  = R == 16 ? wcnt[3:0] : wcnt[4:0];
  assign wkb = R == 16 ? wcnt[7:4] : {1'b0,wcnt[7:5]};

  logic        cb_fin;     // last word of a column block accepted this cycle
  logic        cb_fin_d;

  // metadata / LN storage
  logic [15:0] bias_r  [4][C];
  logic [4:0]  shift_r [4][C];
  for (genvar e = 0; e < 4; e++) begin : g_me
    for (genvar c = 0; c < C; c++) begin : g_mc
      assign meta_bias[(e*C+c)*16 +: 16] = bias_r[e][c];
      assign meta_shift[(e*C+c)*5 +: 5]  = shift_r[e][c];
    end
  end
  logic [15:0] gam_r [64];
  logic [7:0]  bet_r [64];
  for (genvar i = 0; i < 64; i++) begin : g_ln
    assign ln_gamma[i*16 +: 16] = gam_r[i];
    assign ln_beta[i*8 +: 8]    = bet_r[i];
  end

  assign cb_fin = acc_w && (st == S_W) && (wcnt == 11'((kb_of * R) - 1));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; lin <= '0; cb <= '0; cbseq <= '0; wcnt <= '0; ld_slot <= '0;
      ld_cb <= '0; ln_cnt <= '0; done <= 1'b0; lnsel <= 1'b0; cb_fin_d <= 1'b0;
      prefetch_mode <= 1'b0; meta_bias_en <= '0; lw_row_we <= '0; sbase <= '0;
    end else begin
      lw_row_we <= '0;
      cb_fin_d  <= cb_fin;
      if (cb_fin_d) ld_cb <= ld_cb + 1'b1;   // row write of the last word done this cycle
      case (st)
        S_IDLE: if (start) begin
          st <= S_HDR; wcnt <= '0; lin <= '0; cb <= '0; cbseq <= '0; ld_slot <= '0;
          ld_cb <= '0; ln_cnt <= '0; done <= 1'b0; lnsel <= 1'b0;
        end
        S_HDR: if (acc_w) begin
          if (wcnt == 11'd1) begin st <= S_GATE; wcnt <= '0; end
          else wcnt <= wcnt + 1'b1;
        end
        S_GATE: if (gate_ok) begin
          sbase <= (R == 16) ? ld_slot[3:0] : {1'b0,ld_slot[2:0]};
          meta_bias_en[entry] <= bias_of;
          wcnt <= '0;
          st <= bias_of ? S_BIAS : S_SHIFT;
        end
        S_BIAS: if (acc_w) begin
          if (wcnt == 11'd3) begin st <= S_SHIFT; wcnt <= '0; end
          else wcnt <= wcnt + 1'b1;
        end
        S_SHIFT: if (acc_w) begin
          if (wcnt == 11'd1) begin st <= S_W; wcnt <= '0; end
          else wcnt <= wcnt + 1'b1;
        end
        S_W: if (acc_w) begin
          lw_row_we <= R'(1) << wr;
          lw_slot   <= (R == 16) ? 4'(sbase + wkb) : {1'b0,3'(sbase[2:0] + wkb[2:0])};
          lw_shadow <= USE_SHADOW && ((lin == 3'd3 && cb == 0) || (lin == 3'd5 && cb == 1 && wkb < 2));
          if (wr == R-1) ld_slot <= ld_slot + 8'd1;   // one reduction block done
          if (cb_fin) begin
            cbseq   <= cbseq + 1'b1;
            wcnt    <= '0;
            if (4'(cb) == ncb_of - 1) begin
              cb <= '0;
              lin <= lin + 1'b1;
              if (lin == 3'd3) begin st <= S_LNG; lnsel <= 1'b0; end
              else if (lin == 3'd5) st <= S_LN2W;
              else st <= S_GATE;
            end else begin
              cb <= cb + 1'b1;
              st <= prefetch_mode ? S_PREF_HOLD : S_GATE;
            end
          end else wcnt <= wcnt + 1'b1;
        end
        S_LN2W: if (ln1_done) begin st <= S_LNG; lnsel <= 1'b1; wcnt <= '0; end
        S_LNG: if (acc_w) begin
          if (wcnt == 11'd7) begin st <= S_LNB; wcnt <= '0; end
          else wcnt <= wcnt + 1'b1;
        end
        S_LNB: if (acc_w) begin
          if (wcnt == 11'd3) begin
            wcnt   <= '0;
            ln_cnt <= ln_cnt + 1'b1;
            st     <= lnsel ? S_DONE : S_GATE;
          end else wcnt <= wcnt + 1'b1;
        end
        S_DONE: begin
          done <= 1'b1;
          if (start) begin
            st <= S_HDR; wcnt <= '0; lin <= '0; cb <= '0; cbseq <= '0; ld_slot <= '0;
            ld_cb <= '0; ln_cnt <= '0; done <= 1'b0; lnsel <= 1'b0;
          end else if (pre_start) begin
            // Old FC2 column 1 reads slots 0/1 from the PJ shadow. The
            // main slots and metadata entry 0 can hold next layer Q0.
            st <= S_HDR; wcnt <= '0; lin <= '0; cb <= '0; cbseq <= '0; ld_slot <= '0;
            ld_cb <= '0; prefetch_mode <= 1'b1;
          end
        end
        S_PREF_HOLD: if (start && pre_ready) begin
          st <= S_GATE; prefetch_mode <= 1'b0;
          ln_cnt <= '0; done <= 1'b0; lnsel <= 1'b0;
        end
        default: st <= S_IDLE;
      endcase
    end
  end

  // datapath registers (no reset needed)
  logic [31:0] pw [4];
  for (genvar k = 0; k < 4; k++) begin : g_pw
    assign pw[k] = param_data[k*32 +: 32];
  end
  always_ff @(posedge clk) begin
    if (acc_w) begin
      case (st)
        S_HDR: if (wcnt[0] == 1'b0) begin
          {hdr_gelu_tail, hdr_ctx_sh, hdr_q8_sh, hdr_score_sh} <= pw[0];
          {hdr_res2_ay, hdr_res2_ax, hdr_res1_ay, hdr_res1_ax} <= pw[1];
          {hdr_gelu_lo, hdr_ln1_ash, hdr_ln1_nsh, hdr_ln1_vsh} <= pw[2];
          {hdr_gelu_hi, hdr_ln2_ash, hdr_ln2_nsh, hdr_ln2_vsh} <= pw[3];
        end else begin
          {hdr_ln2_eps, hdr_ln1_eps} <= pw[0];
        end
        S_BIAS: for (int k = 0; k < 8; k++) bias_r[entry][8*wcnt[1:0] + k] <= param_data[16*k +: 16];
        S_SHIFT: for (int w = 0; w < 4; w++) begin
          for (int k = 0; k < 6; k++) begin
            if (24 * wcnt[0] + 6 * w + k < C) shift_r[entry][24*wcnt[0] + 6*w + k] <= pw[w][5*k +: 5];
          end
        end
        S_W: for (int c = 0; c < 32; c++) lw_row_data[c*8 +: 8] <= {4'd0, param_data[c*4 +: 4]};
        S_LNG: for (int k = 0; k < 8; k++) gam_r[8*wcnt[2:0] + k] <= param_data[16*k +: 16];
        S_LNB: for (int k = 0; k < 16; k++) bet_r[16*wcnt[1:0] + k] <= param_data[8*k +: 8];
        default: ;
      endcase
    end
  end
endmodule
`default_nettype wire
