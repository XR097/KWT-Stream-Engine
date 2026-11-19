`default_nettype none
// KSE engine SoC wrapper: MMIO register slave (E203 PPI, ICB), streaming DMA
// master (32-bit ICB system-bus master toward the single shared-SRAM slave,
// through the kse_sys_bus arbiter), a two-entry command queue and the kse_top
// instance.
//
// MMIO map (offsets in the 4 KiB page, 32-bit accesses):
//   0x000 ID          RO  0x4B534531 ("KSE1")
//   0x004 CTRL        RW  [0] layer-done IRQ enable, [1] error IRQ enable
//   0x008 STATUS      RO  [0] kse_top busy, [1] any work outstanding,
//                         [3:2] pending commands, [4] queue full,
//                         [5] loader done, [6] loader watermark valid,
//                         [15:8] completed layers (mod 256)
//   0x00C IRQ_STATUS  W1C [0] layer done, [1] error
//   0x010 PARAM_ADDR  RW  byte offset of the next command's parameter segment
//   0x014 PARAM_LEN   RW  segment length in 32-bit words
//   0x018 IN_ADDR     RW  byte offset of the 1584-word input (in_en commands)
//   0x01C OUT_ADDR    RW  byte offset of the 1584-word output (out_en commands)
//   0x020 CMD         WO  push {out_en[9], in_en[8], layer[3:0]} together with
//                         the current PARAM_ADDR/PARAM_LEN/IN_ADDR/OUT_ADDR
//   0x024 LDR_WPTR    RO  loader watermark (shared SRAM status register)
//   0x028 LDR_BASE    RO  loader base
//   0x02C DONE_CNT    RO  completed layers since reset
//   0x030 ERR         RO  [0] CMD written while the queue was full,
//                         [1] DMA response error  (sticky until reset)
// Offsets outside 0x000..0x030 and anything beyond the first 4 KiB of the
// PPI slot return an ICB error.
//
// Addresses are byte offsets inside the 512 KiB shared SRAM ([18:0]; higher
// bits are ignored, so 0x4000_0000-based CPU addresses also work).
//
// Command queue: two pending commands (the executing command is held by
// kse_top).  Each command also queues its parameter segment; the parameter
// DMA streams segments back to back, so the next layer's parameters flow into
// the kse_top prefetch FIFO while the current layer runs.
//
// DMA: one request register, priorities output write > input read >
// parameter read.  Every read obeys the shared-SRAM release rule
//   valid && A >= base && A+4 <= wptr && (A+REL_LAG <= wptr || loader done)
// and reserves a slot in its 4-word stream buffer before it is issued, so the
// response channel is never back-pressured (rsp_ready = 1) and the port can
// sustain one word per cycle.  REL_LAG=0 (the strict-scheme default) reads
// only words the loader has already committed; the loader handshake that
// advances wptr is the same cycle in which the SRAM accepts the write, so the
// registered watermark is always safe.  REL_LAG=4096 keeps the old striped
// phase-separation rule for the historical comparison only.
//
// A layer is reported done (DONE_CNT, IRQ_STATUS[0]) after kse_top's done and,
// for out_en layers, after every output write has been acknowledged by the
// SRAM.  The next command is presented to kse_top only after the output path
// has drained.
module kse_eng_icb #(
  parameter int ACT_WORDS = 1584,
  parameter int BUF       = 4,
  parameter int ARRAY_R   = 32,
  parameter int SM_LANES  = 8,
  parameter int LN_LANES  = 8,
  parameter int PF_DEPTH  = 128,
  parameter int REL_LAG   = 0
) (
  input  logic        clk,
  input  logic        rst_n,

  // MMIO slave (PPI O12 slot)
  input  logic        mmio_cmd_valid,
  output logic        mmio_cmd_ready,
  input  logic [31:0] mmio_cmd_addr,
  input  logic        mmio_cmd_read,
  input  logic [31:0] mmio_cmd_wdata,
  input  logic [3:0]  mmio_cmd_wmask,
  output logic        mmio_rsp_valid,
  input  logic        mmio_rsp_ready,
  output logic [31:0] mmio_rsp_rdata,
  output logic        mmio_rsp_err,

  // DMA master (shared SRAM master port 2)
  output logic        dma_cmd_valid,
  input  logic        dma_cmd_ready,
  output logic [31:0] dma_cmd_addr,
  output logic        dma_cmd_read,
  output logic [31:0] dma_cmd_wdata,
  output logic [3:0]  dma_cmd_wmask,
  input  logic        dma_rsp_valid,
  output logic        dma_rsp_ready,
  input  logic [31:0] dma_rsp_rdata,
  input  logic        dma_rsp_err,

  // loader status (shared SRAM write-pointer register + loader done)
  input  logic [31:0] ldr_wptr,
  input  logic [31:0] ldr_base,
  input  logic        ldr_wptr_valid,
  input  logic        ldr_done,

  output logic        irq
);
  localparam int BW = $clog2(BUF);
  localparam logic [1:0] K_PAR = 2'd0, K_IN = 2'd1, K_OUT = 2'd2;

  // ------------------------------------------------------------------
  // kse_top
  // ------------------------------------------------------------------
  logic        k_cmd_valid, k_cmd_ready, k_in_en, k_out_en;
  logic [3:0]  k_layer;
  logic        k_par_valid, k_par_ready;
  logic [31:0] k_par_data;
  logic        k_in_valid, k_in_ready;
  logic [31:0] k_in_data;
  logic        k_out_valid, k_out_ready;
  logic [31:0] k_out_data;
  logic        k_done, k_busy;

  kse_top #(.R(ARRAY_R), .SM_LANES(SM_LANES), .LN_LANES(LN_LANES), .PF_DEPTH(PF_DEPTH)) u_kse (
    .clk(clk), .rst_n(rst_n),
    .cmd_valid(k_cmd_valid), .cmd_ready(k_cmd_ready), .cmd_layer(k_layer),
    .cmd_in_en(k_in_en), .cmd_out_en(k_out_en),
    .param_valid(k_par_valid), .param_ready(k_par_ready), .param_data(k_par_data),
    .act_in_valid(k_in_valid), .act_in_ready(k_in_ready), .act_in_data(k_in_data),
    .act_out_valid(k_out_valid), .act_out_ready(k_out_ready), .act_out_data(k_out_data),
    .done(k_done), .busy(k_busy));

  // ------------------------------------------------------------------
  // configuration registers
  // ------------------------------------------------------------------
  logic [1:0]  irq_en, irq_st, err_st;
  logic [16:0] cfg_paddr, cfg_iaddr, cfg_oaddr;   // word addresses
  logic [16:0] cfg_plen;
  logic [15:0] done_cnt;

  // ------------------------------------------------------------------
  // command queue (2 pending) and parameter segment queue (4)
  // ------------------------------------------------------------------
  // command entry: {out_en, in_en, layer, iaddr, oaddr}
  localparam int CQW = 1 + 1 + 4 + 17 + 17;
  logic           cq_push, cq_in_ready, cq_valid;
  logic [CQW-1:0] cq_in, cq_out;
  logic [1:0]     cq_cnt;
  logic           sq_push, sq_in_ready, sq_valid, sq_pop;
  logic [33:0]    sq_in, sq_out;
  logic [2:0]     sq_cnt;

  kse_soc_fifo #(.W(CQW), .DEPTH(2)) u_cq (
    .clk(clk), .rst_n(rst_n), .in_valid(cq_push), .in_ready(cq_in_ready), .in_data(cq_in),
    .out_valid(cq_valid), .out_ready(k_cmd_valid && k_cmd_ready), .out_data(cq_out), .count(cq_cnt));
  kse_soc_fifo #(.W(34), .DEPTH(4)) u_sq (
    .clk(clk), .rst_n(rst_n), .in_valid(sq_push), .in_ready(sq_in_ready), .in_data(sq_in),
    .out_valid(sq_valid), .out_ready(sq_pop), .out_data(sq_out), .count(sq_cnt));

  // ------------------------------------------------------------------
  // MMIO slave
  // ------------------------------------------------------------------
  logic        m_hs, m_wr, m_in_page;
  logic [9:0]  m_idx;
  logic        rsp_v_q, rsp_err_q;
  logic [31:0] rsp_d_q;
  logic        reg_ok;
  logic [31:0] rd_val;
  logic        layer_evt;     // a layer completed this cycle
  logic        dma_err_evt;

  assign mmio_cmd_ready = !rsp_v_q || mmio_rsp_ready;
  assign m_hs      = mmio_cmd_valid && mmio_cmd_ready;
  assign m_wr      = !mmio_cmd_read;
  assign m_in_page = (mmio_cmd_addr[23:12] == 12'h000);
  assign m_idx     = mmio_cmd_addr[11:2];
  assign reg_ok    = m_in_page && (m_idx <= 10'h00C);
  assign mmio_rsp_valid = rsp_v_q;
  assign mmio_rsp_rdata = rsp_d_q;
  assign mmio_rsp_err   = rsp_err_q;

  logic out_drained, any_work;
  logic done_wait;

  always_comb begin
    rd_val = 32'h0;
    case (m_idx)
      10'h000: rd_val = 32'h4B53_4531;
      10'h001: rd_val = {30'b0, irq_en};
      10'h002: rd_val = {16'b0, done_cnt[7:0], 1'b0, ldr_wptr_valid, ldr_done,
                         (cq_cnt == 2'd2), cq_cnt, any_work, k_busy};
      10'h003: rd_val = {30'b0, irq_st};
      10'h004: rd_val = {13'b0, cfg_paddr, 2'b00};
      10'h005: rd_val = {15'b0, cfg_plen};
      10'h006: rd_val = {13'b0, cfg_iaddr, 2'b00};
      10'h007: rd_val = {13'b0, cfg_oaddr, 2'b00};
      10'h009: rd_val = ldr_wptr;
      10'h00A: rd_val = ldr_base;
      10'h00B: rd_val = {16'b0, done_cnt};
      10'h00C: rd_val = {30'b0, err_st};
      default: rd_val = 32'h0;
    endcase
  end

  function automatic logic [31:0] wmerge(input logic [31:0] old, input logic [31:0] nw, input logic [3:0] m);
    for (int b = 0; b < 4; b++) wmerge[8*b +: 8] = m[b] ? nw[8*b +: 8] : old[8*b +: 8];
  endfunction

  logic wr_cmd, wr_irq;
  assign wr_cmd  = m_hs && m_wr && reg_ok && (m_idx == 10'h008);
  assign wr_irq  = m_hs && m_wr && reg_ok && (m_idx == 10'h003);
  assign cq_push = wr_cmd && cq_in_ready;
  assign sq_push = cq_push;            // sq has room whenever cq does (see below)
  assign cq_in   = {mmio_cmd_wdata[9], mmio_cmd_wdata[8], mmio_cmd_wdata[3:0], cfg_iaddr, cfg_oaddr};
  assign sq_in   = {cfg_paddr, cfg_plen};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsp_v_q <= 1'b0; rsp_err_q <= 1'b0; rsp_d_q <= 32'h0;
      irq_en <= 2'b00; irq_st <= 2'b00; err_st <= 2'b00;
      cfg_paddr <= '0; cfg_plen <= '0; cfg_iaddr <= '0; cfg_oaddr <= '0;
    end else begin
      if (m_hs) begin
        rsp_v_q   <= 1'b1;
        rsp_err_q <= !reg_ok;
        rsp_d_q   <= (mmio_cmd_read && reg_ok) ? rd_val : 32'h0;
      end else if (mmio_rsp_ready) begin
        rsp_v_q <= 1'b0;
      end
      if (m_hs && m_wr && reg_ok) begin
        case (m_idx)
          10'h001: irq_en <= wmerge({30'b0, irq_en}, mmio_cmd_wdata, mmio_cmd_wmask);
          10'h004: cfg_paddr <= mmio_cmd_wdata[18:2];
          10'h005: cfg_plen  <= mmio_cmd_wdata[16:0];
          10'h006: cfg_iaddr <= mmio_cmd_wdata[18:2];
          10'h007: cfg_oaddr <= mmio_cmd_wdata[18:2];
          default: ;
        endcase
      end
      // sticky errors
      if (wr_cmd && !cq_in_ready) err_st[0] <= 1'b1;
      if (dma_err_evt)            err_st[1] <= 1'b1;
      // IRQ status: set has priority over the W1C clear of the same cycle
      irq_st[0] <= (irq_st[0] && !(wr_irq && mmio_cmd_wdata[0])) || layer_evt;
      irq_st[1] <= (irq_st[1] && !(wr_irq && mmio_cmd_wdata[1])) ||
                   (wr_cmd && !cq_in_ready) || dma_err_evt;
    end
  end

  assign irq = |(irq_st & irq_en);

  // ------------------------------------------------------------------
  // command issue to kse_top
  // ------------------------------------------------------------------
  logic [10:0] in_left, out_left;
  logic [16:0] in_ptr, out_ptr;

  assign k_cmd_valid = cq_valid && out_drained;
  assign k_out_en    = cq_out[CQW-1];
  assign k_in_en     = cq_out[CQW-2];
  assign k_layer     = cq_out[CQW-3 -: 4];

  // ------------------------------------------------------------------
  // stream buffers
  // ------------------------------------------------------------------
  logic          pb_push, ib_push;
  logic [BW:0]   pb_cnt, ib_cnt, ob_cnt;
  logic          ob_valid, ob_pop;
  logic [31:0]   ob_data;
  logic          pb_in_ready_unused, ib_in_ready_unused, ob_in_ready;

  kse_soc_fifo #(.W(32), .DEPTH(BUF)) u_pbuf (
    .clk(clk), .rst_n(rst_n), .in_valid(pb_push), .in_ready(pb_in_ready_unused), .in_data(dma_rsp_rdata),
    .out_valid(k_par_valid), .out_ready(k_par_ready), .out_data(k_par_data), .count(pb_cnt));
  kse_soc_fifo #(.W(32), .DEPTH(BUF)) u_ibuf (
    .clk(clk), .rst_n(rst_n), .in_valid(ib_push), .in_ready(ib_in_ready_unused), .in_data(dma_rsp_rdata),
    .out_valid(k_in_valid), .out_ready(k_in_ready), .out_data(k_in_data), .count(ib_cnt));
  kse_soc_fifo #(.W(32), .DEPTH(BUF)) u_obuf (
    .clk(clk), .rst_n(rst_n), .in_valid(k_out_valid), .in_ready(ob_in_ready), .in_data(k_out_data),
    .out_valid(ob_valid), .out_ready(ob_pop), .out_data(ob_data), .count(ob_cnt));
  assign k_out_ready = ob_in_ready;

  // ------------------------------------------------------------------
  // DMA request register
  // ------------------------------------------------------------------
  logic        req_v;
  logic [1:0]  req_k;
  logic [16:0] req_a;
  logic [31:0] req_d;
  logic [BW:0] p_resv, i_resv;
  logic [2:0]  o_pend;              // loaded or outstanding output writes
  logic [16:0] p_ptr, p_left;

  // outstanding tags (kind of each issued command, in order)
  logic        tg_in_ready, tg_valid;
  logic [1:0]  tg_kind;
  logic [1:0]  tg_cnt;
  logic        cmd_hs, rsp_hs;

  assign dma_cmd_valid = req_v && tg_in_ready;
  assign dma_cmd_addr  = {13'b0, req_a, 2'b00};
  assign dma_cmd_read  = (req_k != K_OUT);
  assign dma_cmd_wdata = req_d;
  assign dma_cmd_wmask = 4'hF;
  assign dma_rsp_ready = 1'b1;
  assign cmd_hs = dma_cmd_valid && dma_cmd_ready;
  assign rsp_hs = dma_rsp_valid && tg_valid;

  kse_soc_fifo #(.W(2), .DEPTH(2)) u_tag (
    .clk(clk), .rst_n(rst_n), .in_valid(cmd_hs), .in_ready(tg_in_ready), .in_data(req_k),
    .out_valid(tg_valid), .out_ready(rsp_hs), .out_data(tg_kind), .count(tg_cnt));

  assign pb_push     = rsp_hs && (tg_kind == K_PAR);
  assign ib_push     = rsp_hs && (tg_kind == K_IN);
  assign dma_err_evt = rsp_hs && dma_rsp_err;

  // release rule (21-bit arithmetic, no wrap inside the 512 KiB window)
  localparam logic [20:0] REL_LAG_B = REL_LAG;
  function automatic logic allow(input logic [16:0] wa, input logic [31:0] wp, input logic [31:0] bs,
                                 input logic v, input logic dn);
    logic [20:0] a;
    a = {2'b00, wa, 2'b00};
    allow = v && (a >= bs[20:0]) && (a + 21'd4 <= wp[20:0]) &&
            ((a + REL_LAG_B <= wp[20:0]) || dn);
  endfunction

  logic ld, can_o, can_i, can_p, sel_o, sel_i, sel_p;
  assign ld    = !req_v || cmd_hs;
  assign can_o = ob_valid;
  assign can_i = (in_left != '0) && ({1'b0, ib_cnt} + {1'b0, i_resv} < BUF) &&
                 allow(in_ptr, ldr_wptr, ldr_base, ldr_wptr_valid, ldr_done);
  assign can_p = (p_left != '0) && ({1'b0, pb_cnt} + {1'b0, p_resv} < BUF) &&
                 allow(p_ptr, ldr_wptr, ldr_base, ldr_wptr_valid, ldr_done);
  assign sel_o = ld && can_o;
  assign sel_i = ld && !can_o && can_i;
  assign sel_p = ld && !can_o && !can_i && can_p;
  assign ob_pop = sel_o;
  assign sq_pop = sq_valid && (p_left == '0);

  logic k_cmd_hs;
  assign k_cmd_hs = k_cmd_valid && k_cmd_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      req_v <= 1'b0; req_k <= K_PAR; req_a <= '0; req_d <= '0;
      p_resv <= '0; i_resv <= '0; o_pend <= '0;
      p_ptr <= '0; p_left <= '0;
      in_ptr <= '0; in_left <= '0; out_ptr <= '0; out_left <= '0;
    end else begin
      if (ld) begin
        req_v <= sel_o || sel_i || sel_p;
        if (sel_o) begin req_k <= K_OUT; req_a <= out_ptr; req_d <= ob_data; end
        else if (sel_i) begin req_k <= K_IN; req_a <= in_ptr; end
        else if (sel_p) begin req_k <= K_PAR; req_a <= p_ptr; end
      end
      // reservations: +1 when a read is loaded, -1 when its data returns
      p_resv <= p_resv + {{BW{1'b0}}, sel_p} - {{BW{1'b0}}, pb_push};
      i_resv <= i_resv + {{BW{1'b0}}, sel_i} - {{BW{1'b0}}, ib_push};
      o_pend <= o_pend + {2'b0, sel_o} - {2'b0, rsp_hs && (tg_kind == K_OUT)};
      // parameter segment pointer
      if (sq_pop) begin
        p_ptr  <= sq_out[33:17];
        p_left <= sq_out[16:0];
      end else if (sel_p) begin
        p_ptr  <= p_ptr + 17'd1;
        p_left <= p_left - 17'd1;
      end
      // input / output streams of the executing command
      if (k_cmd_hs) begin
        in_ptr   <= cq_out[33:17];
        in_left  <= k_in_en ? ACT_WORDS[10:0] : 11'd0;
        out_ptr  <= cq_out[16:0];
        out_left <= k_out_en ? ACT_WORDS[10:0] : 11'd0;
      end else begin
        if (sel_i) begin in_ptr <= in_ptr + 17'd1; in_left <= in_left - 11'd1; end
        if (sel_o) begin out_ptr <= out_ptr + 17'd1; out_left <= out_left - 11'd1; end
      end
    end
  end

  // ------------------------------------------------------------------
  // layer completion
  // ------------------------------------------------------------------
  assign out_drained = !ob_valid && (o_pend == '0);
  assign any_work    = k_busy || cq_valid || done_wait || !out_drained || req_v ||
                       (p_left != '0) || sq_valid || (in_left != '0);
  assign layer_evt   = done_wait && out_drained;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      done_wait <= 1'b0; done_cnt <= '0;
    end else begin
      if (k_done) done_wait <= 1'b1;
      else if (layer_evt) done_wait <= 1'b0;
      if (layer_evt) done_cnt <= done_cnt + 16'd1;
    end
  end

`ifndef SYNTHESIS
  // the parameter segment queue (4) always has room when the command queue (2)
  // does: at most one segment belongs to the executing command and one may be
  // streaming ahead of it
  always @(posedge clk) if (rst_n) begin
    if (sq_push && !sq_in_ready) $error("kse_eng_icb: parameter segment queue overflow");
    if (dma_rsp_valid && !tg_valid) $error("kse_eng_icb: DMA response without outstanding command");
    if (k_done && done_wait)       $error("kse_eng_icb: second done before the previous layer drained");
  end
`endif
endmodule
`default_nettype wire
