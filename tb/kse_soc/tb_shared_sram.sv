`timescale 1ns/1ps
// Unit test for the 512 KB shared SRAM and the parameter loader.
//
// Phase 1 (streaming): the loader writes a 64K-word pseudo-random image while
// the DMA reads the same region one 4 KB stripe behind loader_wptr; the CPU
// master runs random read/write traffic in a separate 256 KB region.  Every
// DMA read is compared with the image and every CPU read with a shadow model.
// Phase 2 (backpressure): three random masters hammer the full 512 KB with
// random read/write traffic and randomly deasserted rsp_ready; a final
// sequential sweep rereads all 128K words against the shadow model.
module tb_shared_sram;

  localparam int MEM_WORDS    = 131072;      // 512 KB
  localparam int LOAD_WORDS   = 65536;       // 256 KB parameter image
  localparam int STRIPE_BYTES = 4096;        // 4 KB stripe
  localparam int CPU_BASE     = 32'h0004_0000;
  localparam int CPU_WORDS    = 65536;       // 256 KB CPU region
  localparam int RM_TRANS     = 4000;        // random transactions per master
  localparam int SS_START     = 8192;        // steady-state window
  localparam int SS_END       = 61440;

  logic clk;
  logic rst_n;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  int cyc;
  initial cyc = 0;
  always @(posedge clk) if (rst_n) cyc <= cyc + 1;

  // ------------------------------------------------------------------
  // Deterministic parameter image and shadow memory
  // ------------------------------------------------------------------
  logic [31:0] shadow [0:MEM_WORDS-1];

  function automatic logic [31:0] img_word(input int unsigned idx);
    logic [31:0] x;
    x = (idx * 32'h9E37_79B9) + 32'h7F4A_7C15;
    x = x ^ (x >> 16);
    x = x * 32'h85EB_CA6B;
    x = x ^ (x >> 13);
    x = x * 32'hC2B2_AE35;
    x = x ^ (x >> 16);
    return x;
  endfunction

  initial begin
    int    fd;
    string img_path;
    if (!$value$plusargs("LOADER_IMAGE=%s", img_path))
      img_path = "kse_sram_img.hex";
    fd = $fopen(img_path, "w");
    if (fd == 0) begin
      $fatal(1, "TEST FAILED: cannot create %s", img_path);
    end
    for (int i = 0; i < LOAD_WORDS; i = i + 1)
      $fdisplay(fd, "%08x", img_word(i));
    $fclose(fd);
    $display("[TB] wrote %0d-word parameter image to %s", LOAD_WORDS, img_path);
  end

  initial begin
    for (int i = 0; i < MEM_WORDS; i = i + 1)
      shadow[i] = (i < LOAD_WORDS) ? img_word(i) : 32'b0;
  end

  // ------------------------------------------------------------------
  // DUT-side buses
  // ------------------------------------------------------------------
  logic        d_cpu_cmd_valid, d_cpu_cmd_ready, d_cpu_cmd_read;
  logic [31:0] d_cpu_cmd_addr, d_cpu_cmd_wdata;
  logic [3:0]  d_cpu_cmd_wmask;
  logic        d_cpu_rsp_valid, d_cpu_rsp_ready, d_cpu_rsp_err;
  logic [31:0] d_cpu_rsp_rdata;

  logic        d_loader_cmd_valid, d_loader_cmd_ready, d_loader_cmd_read;
  logic [31:0] d_loader_cmd_addr, d_loader_cmd_wdata;
  logic [3:0]  d_loader_cmd_wmask;
  logic        d_loader_rsp_valid, d_loader_rsp_ready, d_loader_rsp_err;
  logic [31:0] d_loader_rsp_rdata;

  logic        d_accel_cmd_valid, d_accel_cmd_ready, d_accel_cmd_read;
  logic [31:0] d_accel_cmd_addr, d_accel_cmd_wdata;
  logic [3:0]  d_accel_cmd_wmask;
  logic        d_accel_rsp_valid, d_accel_rsp_ready, d_accel_rsp_err;
  logic [31:0] d_accel_rsp_rdata;

  logic [31:0] loader_wptr;
  logic        wptr_rd_valid, wptr_rd_ready;
  logic [31:0] wptr_rd_rdata;

  // ------------------------------------------------------------------
  // Phase 1 drivers
  // ------------------------------------------------------------------
  // Loader component (master 1)
  logic        p1_loader_cmd_valid, p1_loader_cmd_ready, p1_loader_cmd_read;
  logic [31:0] p1_loader_cmd_addr, p1_loader_cmd_wdata;
  logic [3:0]  p1_loader_cmd_wmask;
  logic        p1_loader_rsp_valid, p1_loader_rsp_ready, p1_loader_rsp_err;
  logic [31:0] p1_loader_rsp_rdata;

  logic        loader_start, loader_busy, loader_done;
  logic [31:0] loader_base, loader_len;
  logic [31:0] loader_wptr_local, loader_base_pub;
  logic        loader_wptr_valid;

  // DMA model (master 2)
  logic        dma_en;
  logic        p1_dma_cmd_valid, p1_dma_cmd_ready, p1_dma_cmd_read;
  logic [31:0] p1_dma_cmd_addr, p1_dma_cmd_wdata;
  logic [3:0]  p1_dma_cmd_wmask;
  logic        p1_dma_rsp_valid, p1_dma_rsp_ready, p1_dma_rsp_err;
  logic [31:0] p1_dma_rsp_rdata;
  int          dma_issue_idx, dma_resp_idx;
  int          dma_err_cnt;

  // CPU model (master 0)
  typedef enum logic [1:0] {CPU_IDLE, CPU_CMD, CPU_RSP} cpu_state_t;
  cpu_state_t  cpu_state;
  logic        p1_cpu_cmd_valid, p1_cpu_cmd_ready, p1_cpu_cmd_read;
  logic [31:0] p1_cpu_cmd_addr, p1_cpu_cmd_wdata;
  logic [3:0]  p1_cpu_cmd_wmask;
  logic        p1_cpu_rsp_valid, p1_cpu_rsp_ready, p1_cpu_rsp_err;
  logic [31:0] p1_cpu_rsp_rdata;
  logic [31:0] cpu_addr_q, cpu_wdata_q, cpu_exp_q;
  logic        cpu_read_q;
  logic [3:0]  cpu_wmask_q;
  int          cpu_gap, cpu_txn_cnt, cpu_err_cnt;
  logic        cpu_stop;
  logic        cpu_init_phase, cpu_init_done;
  int          init_issue_idx, init_rsp_idx;
  logic [31:0] cpu_rnd_q;

  function automatic logic [31:0] cpu_rand;
    logic [31:0] x;
    x = cpu_rnd_q;
    x = x ^ (x << 13);
    x = x ^ (x >> 17);
    x = x ^ (x << 5);
    cpu_rnd_q = x;
    return x;
  endfunction

  // ------------------------------------------------------------------
  // Phase 2 random masters
  // ------------------------------------------------------------------
  logic        rm0_cmd_valid, rm0_cmd_ready, rm0_cmd_read;
  logic [31:0] rm0_cmd_addr, rm0_cmd_wdata;
  logic [3:0]  rm0_cmd_wmask;
  logic        rm0_rsp_valid, rm0_rsp_ready, rm0_rsp_err;
  logic [31:0] rm0_rsp_rdata;
  logic        rm0_rand_done, rm0_done;
  int unsigned rm0_err_cnt, rm0_bp_cnt;

  logic        rm1_cmd_valid, rm1_cmd_ready, rm1_cmd_read;
  logic [31:0] rm1_cmd_addr, rm1_cmd_wdata;
  logic [3:0]  rm1_cmd_wmask;
  logic        rm1_rsp_valid, rm1_rsp_ready, rm1_rsp_err;
  logic [31:0] rm1_rsp_rdata;
  logic        rm1_rand_done, rm1_done;
  int unsigned rm1_err_cnt, rm1_bp_cnt;

  logic        rm2_cmd_valid, rm2_cmd_ready, rm2_cmd_read;
  logic [31:0] rm2_cmd_addr, rm2_cmd_wdata;
  logic [3:0]  rm2_cmd_wmask;
  logic        rm2_rsp_valid, rm2_rsp_ready, rm2_rsp_err;
  logic [31:0] rm2_rsp_rdata;
  logic        rm2_rand_done, rm2_done;
  int unsigned rm2_err_cnt, rm2_bp_cnt;

  wire [31:0] rm0_shadow_rd = shadow[rm0_cmd_addr[18:2]];
  wire [31:0] rm1_shadow_rd = shadow[rm1_cmd_addr[18:2]];
  wire [31:0] rm2_shadow_rd = shadow[rm2_cmd_addr[18:2]];

  logic phase2, sweep_go;
  int   cyc_init_done, cyc_p2_start, cyc_rand_done, cyc_sweep_done;

  // ------------------------------------------------------------------
  // DUT
  // ------------------------------------------------------------------
  kse_sram_sys_wrap dut (
    .clk   (clk),
    .rst_n (rst_n),

    .cpu_cmd_valid (d_cpu_cmd_valid),
    .cpu_cmd_ready (d_cpu_cmd_ready),
    .cpu_cmd_addr  (d_cpu_cmd_addr),
    .cpu_cmd_read  (d_cpu_cmd_read),
    .cpu_cmd_wdata (d_cpu_cmd_wdata),
    .cpu_cmd_wmask (d_cpu_cmd_wmask),
    .cpu_rsp_valid (d_cpu_rsp_valid),
    .cpu_rsp_ready (d_cpu_rsp_ready),
    .cpu_rsp_rdata (d_cpu_rsp_rdata),
    .cpu_rsp_err   (d_cpu_rsp_err),

    .loader_cmd_valid (d_loader_cmd_valid),
    .loader_cmd_ready (d_loader_cmd_ready),
    .loader_cmd_addr  (d_loader_cmd_addr),
    .loader_cmd_read  (d_loader_cmd_read),
    .loader_cmd_wdata (d_loader_cmd_wdata),
    .loader_cmd_wmask (d_loader_cmd_wmask),
    .loader_rsp_valid (d_loader_rsp_valid),
    .loader_rsp_ready (d_loader_rsp_ready),
    .loader_rsp_rdata (d_loader_rsp_rdata),
    .loader_rsp_err   (d_loader_rsp_err),

    .accel_cmd_valid (d_accel_cmd_valid),
    .accel_cmd_ready (d_accel_cmd_ready),
    .accel_cmd_addr  (d_accel_cmd_addr),
    .accel_cmd_read  (d_accel_cmd_read),
    .accel_cmd_wdata (d_accel_cmd_wdata),
    .accel_cmd_wmask (d_accel_cmd_wmask),
    .accel_rsp_valid (d_accel_rsp_valid),
    .accel_rsp_ready (d_accel_rsp_ready),
    .accel_rsp_rdata (d_accel_rsp_rdata),
    .accel_rsp_err   (d_accel_rsp_err),

    .loader_wptr            (loader_wptr),
    .loader_base            (loader_base_pub),
    .loader_wptr_valid      (loader_wptr_valid),
    .wptr_rd_valid     (wptr_rd_valid),
    .wptr_rd_ready     (wptr_rd_ready),
    .wptr_rd_rdata     (wptr_rd_rdata)
  );

  assign wptr_rd_valid = 1'b1;

  // ------------------------------------------------------------------
  // Loader instance
  // ------------------------------------------------------------------
  kse_param_loader #(.IMG_WORDS(LOAD_WORDS)) u_loader (
    .clk       (clk),
    .rst_n     (rst_n),
    .start     (loader_start),
    .base_addr (loader_base),
    .length    (loader_len),
    .busy      (loader_busy),
    .done      (loader_done),
    .cmd_valid (p1_loader_cmd_valid),
    .cmd_ready (p1_loader_cmd_ready),
    .cmd_addr  (p1_loader_cmd_addr),
    .cmd_read  (p1_loader_cmd_read),
    .cmd_wdata (p1_loader_cmd_wdata),
    .cmd_wmask (p1_loader_cmd_wmask),
    .rsp_valid (p1_loader_rsp_valid),
    .rsp_ready (p1_loader_rsp_ready),
    .rsp_rdata (p1_loader_rsp_rdata),
    .rsp_err   (p1_loader_rsp_err),
    .wptr            (loader_wptr_local)
  );

  // ------------------------------------------------------------------
  // Phase 1/2 master muxing
  // ------------------------------------------------------------------
  assign d_cpu_cmd_valid = phase2 ? rm0_cmd_valid : p1_cpu_cmd_valid;
  assign d_cpu_cmd_addr  = phase2 ? rm0_cmd_addr  : p1_cpu_cmd_addr;
  assign d_cpu_cmd_read  = phase2 ? rm0_cmd_read  : p1_cpu_cmd_read;
  assign d_cpu_cmd_wdata = phase2 ? rm0_cmd_wdata : p1_cpu_cmd_wdata;
  assign d_cpu_cmd_wmask = phase2 ? rm0_cmd_wmask : p1_cpu_cmd_wmask;
  assign d_cpu_rsp_ready = phase2 ? rm0_rsp_ready : p1_cpu_rsp_ready;
  assign p1_cpu_cmd_ready = phase2 ? 1'b0 : d_cpu_cmd_ready;
  assign rm0_cmd_ready    = phase2 ? d_cpu_cmd_ready : 1'b0;
  assign p1_cpu_rsp_valid = phase2 ? 1'b0 : d_cpu_rsp_valid;
  assign rm0_rsp_valid    = phase2 ? d_cpu_rsp_valid : 1'b0;
  assign p1_cpu_rsp_rdata = d_cpu_rsp_rdata;
  assign rm0_rsp_rdata    = d_cpu_rsp_rdata;
  assign p1_cpu_rsp_err   = d_cpu_rsp_err;
  assign rm0_rsp_err      = d_cpu_rsp_err;

  assign d_loader_cmd_valid = phase2 ? rm1_cmd_valid : p1_loader_cmd_valid;
  assign d_loader_cmd_addr  = phase2 ? rm1_cmd_addr  : p1_loader_cmd_addr;
  assign d_loader_cmd_read  = phase2 ? rm1_cmd_read  : p1_loader_cmd_read;
  assign d_loader_cmd_wdata = phase2 ? rm1_cmd_wdata : p1_loader_cmd_wdata;
  assign d_loader_cmd_wmask = phase2 ? rm1_cmd_wmask : p1_loader_cmd_wmask;
  assign d_loader_rsp_ready = phase2 ? rm1_rsp_ready : p1_loader_rsp_ready;
  assign p1_loader_cmd_ready = phase2 ? 1'b0 : d_loader_cmd_ready;
  assign rm1_cmd_ready       = phase2 ? d_loader_cmd_ready : 1'b0;
  assign p1_loader_rsp_valid = phase2 ? 1'b0 : d_loader_rsp_valid;
  assign rm1_rsp_valid       = phase2 ? d_loader_rsp_valid : 1'b0;
  assign p1_loader_rsp_rdata = d_loader_rsp_rdata;
  assign rm1_rsp_rdata       = d_loader_rsp_rdata;
  assign p1_loader_rsp_err   = d_loader_rsp_err;
  assign rm1_rsp_err         = d_loader_rsp_err;

  assign d_accel_cmd_valid = phase2 ? rm2_cmd_valid : p1_dma_cmd_valid;
  assign d_accel_cmd_addr  = phase2 ? rm2_cmd_addr  : p1_dma_cmd_addr;
  assign d_accel_cmd_read  = phase2 ? rm2_cmd_read  : p1_dma_cmd_read;
  assign d_accel_cmd_wdata = phase2 ? rm2_cmd_wdata : p1_dma_cmd_wdata;
  assign d_accel_cmd_wmask = phase2 ? rm2_cmd_wmask : p1_dma_cmd_wmask;
  assign d_accel_rsp_ready = phase2 ? rm2_rsp_ready : p1_dma_rsp_ready;
  assign p1_dma_cmd_ready = phase2 ? 1'b0 : d_accel_cmd_ready;
  assign rm2_cmd_ready    = phase2 ? d_accel_cmd_ready : 1'b0;
  assign p1_dma_rsp_valid = phase2 ? 1'b0 : d_accel_rsp_valid;
  assign rm2_rsp_valid    = phase2 ? d_accel_rsp_valid : 1'b0;
  assign p1_dma_rsp_rdata = d_accel_rsp_rdata;
  assign rm2_rsp_rdata    = d_accel_rsp_rdata;
  assign p1_dma_rsp_err   = d_accel_rsp_err;
  assign rm2_rsp_err      = d_accel_rsp_err;

  // ------------------------------------------------------------------
  // Random masters
  // ------------------------------------------------------------------
  kse_rand_master #(
    .SEED(101), .N_TRANS(RM_TRANS), .MEM_WORDS(MEM_WORDS), .DO_SWEEP(1'b1)
  ) u_rm0 (
    .clk(clk), .rst_n(rst_n), .enable(phase2), .sweep_go(sweep_go),
    .cmd_valid(rm0_cmd_valid), .cmd_ready(rm0_cmd_ready),
    .cmd_addr(rm0_cmd_addr), .cmd_read(rm0_cmd_read),
    .cmd_wdata(rm0_cmd_wdata), .cmd_wmask(rm0_cmd_wmask),
    .rsp_valid(rm0_rsp_valid), .rsp_ready(rm0_rsp_ready),
    .rsp_rdata(rm0_rsp_rdata), .rsp_err(rm0_rsp_err),
    .shadow_rd_data(rm0_shadow_rd),
    .rand_done(rm0_rand_done), .done(rm0_done), .err_cnt(rm0_err_cnt),
    .bp_cnt(rm0_bp_cnt)
  );

  kse_rand_master #(
    .SEED(202), .N_TRANS(RM_TRANS), .MEM_WORDS(MEM_WORDS), .DO_SWEEP(1'b0)
  ) u_rm1 (
    .clk(clk), .rst_n(rst_n), .enable(phase2), .sweep_go(sweep_go),
    .cmd_valid(rm1_cmd_valid), .cmd_ready(rm1_cmd_ready),
    .cmd_addr(rm1_cmd_addr), .cmd_read(rm1_cmd_read),
    .cmd_wdata(rm1_cmd_wdata), .cmd_wmask(rm1_cmd_wmask),
    .rsp_valid(rm1_rsp_valid), .rsp_ready(rm1_rsp_ready),
    .rsp_rdata(rm1_rsp_rdata), .rsp_err(rm1_rsp_err),
    .shadow_rd_data(rm1_shadow_rd),
    .rand_done(rm1_rand_done), .done(rm1_done), .err_cnt(rm1_err_cnt),
    .bp_cnt(rm1_bp_cnt)
  );

  kse_rand_master #(
    .SEED(303), .N_TRANS(RM_TRANS), .MEM_WORDS(MEM_WORDS), .DO_SWEEP(1'b0)
  ) u_rm2 (
    .clk(clk), .rst_n(rst_n), .enable(phase2), .sweep_go(sweep_go),
    .cmd_valid(rm2_cmd_valid), .cmd_ready(rm2_cmd_ready),
    .cmd_addr(rm2_cmd_addr), .cmd_read(rm2_cmd_read),
    .cmd_wdata(rm2_cmd_wdata), .cmd_wmask(rm2_cmd_wmask),
    .rsp_valid(rm2_rsp_valid), .rsp_ready(rm2_rsp_ready),
    .rsp_rdata(rm2_rsp_rdata), .rsp_err(rm2_rsp_err),
    .shadow_rd_data(rm2_shadow_rd),
    .rand_done(rm2_rand_done), .done(rm2_done), .err_cnt(rm2_err_cnt),
    .bp_cnt(rm2_bp_cnt)
  );

  // ------------------------------------------------------------------
  // Shadow update: every write that completes updates the reference model.
  // ------------------------------------------------------------------
  always @(posedge clk) begin
    if (d_cpu_cmd_valid && d_cpu_cmd_ready && !d_cpu_cmd_read)
      for (int b = 0; b < 4; b++)
        if (d_cpu_cmd_wmask[b])
          shadow[d_cpu_cmd_addr[18:2]][8*b +: 8] <= d_cpu_cmd_wdata[8*b +: 8];
    if (d_loader_cmd_valid && d_loader_cmd_ready && !d_loader_cmd_read && d_loader_cmd_addr < 32'h80000)
      for (int b = 0; b < 4; b++)
        if (d_loader_cmd_wmask[b])
          shadow[d_loader_cmd_addr[18:2]][8*b +: 8] <= d_loader_cmd_wdata[8*b +: 8];
    if (d_accel_cmd_valid && d_accel_cmd_ready && !d_accel_cmd_read)
      for (int b = 0; b < 4; b++)
        if (d_accel_cmd_wmask[b])
          shadow[d_accel_cmd_addr[18:2]][8*b +: 8] <= d_accel_cmd_wdata[8*b +: 8];
  end

  // ------------------------------------------------------------------
  // Phase 1: DMA model, one stripe behind loader_wptr
  // ------------------------------------------------------------------
  // Reference DMA release rule.  The A+4 bound is independent of done: a
  // zero-length load (base == wptr) must not release any read, and a read at
  // A == wptr must always be rejected.  done only lifts the 4 KB lag rule.
  // All live inputs are explicit arguments: a function used in a continuous
  // assignment is only re-evaluated for its arguments, not for globals read
  // inside the function body.
  function automatic logic dma_word_allowed(input logic [31:0] a,
                                            input logic        stream_done,
                                            input logic [31:0] wptr,
                                            input logic [31:0] base,
                                            input logic        valid);
    dma_word_allowed = valid &&
                       (a >= base) &&
                       ((a + 32'd4) <= wptr) &&
                       ((((a + STRIPE_BYTES) <= wptr) || stream_done));
  endfunction

  function automatic logic dma_word_allowed_now(input logic [31:0] a,
                                                input logic        stream_done);
    dma_word_allowed_now = dma_word_allowed(a, stream_done, loader_wptr,
                                            loader_base_pub, loader_wptr_valid);
  endfunction

  wire [31:0] dma_byte_addr = dma_issue_idx << 2;
  wire        dma_safe      = dma_word_allowed(dma_byte_addr, loader_done,
                                               loader_wptr, loader_base_pub,
                                               loader_wptr_valid);
  wire        dma_has_work  = (dma_issue_idx < LOAD_WORDS);

  assign p1_dma_cmd_valid = dma_en && dma_has_work && dma_safe;
  assign p1_dma_cmd_addr  = dma_byte_addr;
  assign p1_dma_cmd_read  = 1'b1;
  assign p1_dma_cmd_wdata = 32'b0;
  assign p1_dma_cmd_wmask = 4'b0;
  assign p1_dma_rsp_ready = 1'b1;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dma_issue_idx <= 0;
      dma_resp_idx  <= 0;
      dma_err_cnt   <= 0;
    end else if (dma_en) begin
      if (p1_dma_cmd_valid && p1_dma_cmd_ready)
        dma_issue_idx <= dma_issue_idx + 1;

      if (p1_dma_rsp_valid && p1_dma_rsp_ready) begin
        if (p1_dma_rsp_err) begin
          dma_err_cnt <= dma_err_cnt + 1;
          $display("[TB] DMA rsp_err at word %0d", dma_resp_idx);
        end else if (p1_dma_rsp_rdata !== img_word(dma_resp_idx)) begin
          dma_err_cnt <= dma_err_cnt + 1;
          if (dma_err_cnt < 10)
            $display("[TB] DMA mismatch word %0d: got %08x exp %08x",
                     dma_resp_idx, p1_dma_rsp_rdata, img_word(dma_resp_idx));
        end
        dma_resp_idx <= dma_resp_idx + 1;
      end
    end
  end

  // ------------------------------------------------------------------
  // Phase 1: CPU random traffic on the upper 256 KB
  // ------------------------------------------------------------------
  wire [31:0] safe_loader_words =
      (loader_wptr > STRIPE_BYTES) ? ((loader_wptr - STRIPE_BYTES) >> 2) : 32'd0;

  // Before the streaming test the CPU zero-fills the upper 256 KB so that a
  // real macro model (no reset, X until written) is usable as well.
  assign p1_cpu_cmd_valid = cpu_init_phase ? (init_issue_idx < CPU_WORDS)
                                           : (cpu_state == CPU_CMD);
  assign p1_cpu_cmd_addr  = cpu_init_phase ? (CPU_BASE + (init_issue_idx << 2))
                                           : cpu_addr_q;
  assign p1_cpu_cmd_read  = cpu_init_phase ? 1'b0 : cpu_read_q;
  assign p1_cpu_cmd_wdata = cpu_init_phase ? 32'b0 : cpu_wdata_q;
  assign p1_cpu_cmd_wmask = cpu_init_phase ? 4'hF : cpu_wmask_q;
  assign p1_cpu_rsp_ready = cpu_init_phase ? 1'b1 : (cpu_state == CPU_RSP);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_state   <= CPU_IDLE;
      cpu_gap     <= 20;
      cpu_txn_cnt <= 0;
      cpu_err_cnt <= 0;
      cpu_addr_q  <= 32'b0;
      cpu_wdata_q <= 32'b0;
      cpu_read_q  <= 1'b0;
      cpu_wmask_q <= 4'b0;
      cpu_exp_q   <= 32'b0;
      cpu_rnd_q   <= 32'h1ACE_B00C;
      cpu_init_phase <= 1'b1;
      cpu_init_done  <= 1'b0;
      init_issue_idx <= 0;
      init_rsp_idx   <= 0;
    end else if (cpu_init_phase) begin
      if (p1_cpu_cmd_valid && p1_cpu_cmd_ready) init_issue_idx <= init_issue_idx + 1;
      if (p1_cpu_rsp_valid && p1_cpu_rsp_ready) begin
        init_rsp_idx <= init_rsp_idx + 1;
        if (p1_cpu_rsp_err) begin
          cpu_err_cnt <= cpu_err_cnt + 1;
          $display("[TB] CPU init rsp_err at %08x", CPU_BASE + (init_issue_idx << 2));
        end
      end
      if ((init_issue_idx == CPU_WORDS) && (init_rsp_idx == CPU_WORDS)) begin
        cpu_init_phase <= 1'b0;
        cpu_init_done  <= 1'b1;
        cpu_gap        <= 20;
      end
    end else begin
      case (cpu_state)
        CPU_IDLE: begin
          if (cpu_stop) begin
            cpu_gap <= 1;
          end else if (cpu_gap > 0) begin
            cpu_gap <= cpu_gap - 1;
          end else begin
            cpu_gap <= 32 + (cpu_rand() % 65);
            if (((cpu_rand() % 100) < 25) && (safe_loader_words != 0)) begin
              // Read a word that the loader committed at least one stripe ago.
              cpu_addr_q  <= ((cpu_rand() % safe_loader_words) << 2);
              cpu_read_q  <= 1'b1;
              cpu_wdata_q <= 32'b0;
              cpu_wmask_q <= 4'b0;
            end else begin
              cpu_addr_q  <= CPU_BASE + ((cpu_rand() % CPU_WORDS) << 2);
              cpu_read_q  <= (cpu_rand() % 2);
              cpu_wdata_q <= cpu_rand();
              cpu_wmask_q <= (cpu_rand() % 15) + 1;   // exercise byte enables
            end
            cpu_state <= CPU_CMD;
          end
        end

        CPU_CMD: begin
          if (p1_cpu_cmd_valid && p1_cpu_cmd_ready) begin
            cpu_txn_cnt <= cpu_txn_cnt + 1;
            if (cpu_read_q) cpu_exp_q <= shadow[cpu_addr_q[18:2]];
            // Every ICB command, including a write, has a response that the
            // master must consume; otherwise the bank response channel locks.
            cpu_state <= CPU_RSP;
          end
        end

        CPU_RSP: begin
          if (p1_cpu_rsp_valid) begin
            if (p1_cpu_rsp_err) begin
              cpu_err_cnt <= cpu_err_cnt + 1;
              $display("[TB] CPU rsp_err at %08x", cpu_addr_q);
            end else if (cpu_read_q && (p1_cpu_rsp_rdata !== cpu_exp_q)) begin
              cpu_err_cnt <= cpu_err_cnt + 1;
              if (cpu_err_cnt < 10)
                $display("[TB] CPU read mismatch at %08x: got %08x exp %08x",
                         cpu_addr_q, p1_cpu_rsp_rdata, cpu_exp_q);
            end
            cpu_state <= CPU_IDLE;
          end
        end

        default: cpu_state <= CPU_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // Phase 1 statistics
  // ------------------------------------------------------------------
  wire loader_hs = p1_loader_cmd_valid && p1_loader_cmd_ready;
  wire dma_hs    = p1_dma_cmd_valid && p1_dma_cmd_ready;
  wire cpu_hs    = p1_cpu_cmd_valid && p1_cpu_cmd_ready;

  int loader_hs_cnt, dma_hs_cnt, cpu_hs_cnt;
  int loader_first_cyc, loader_last_cyc, dma_first_cyc, dma_last_cyc;
  int loader_stall_cnt, dma_stall_cnt, cpu_stall_cnt;
  int both_hs_cnt, conflict_cnt;
  int conf_ld_dma, conf_cpu_ld, conf_cpu_dma;
  int ss_cyc, ss_loader_hs, ss_dma_hs;
  int load_err_cnt;
  int req_b0, req_b1, conflict_inc;

  always @(posedge clk) begin
    if (rst_n && !phase2) begin
      if (loader_hs && p1_loader_cmd_addr < 32'h80000) begin
        if (loader_hs_cnt == 0) loader_first_cyc <= cyc;
        loader_hs_cnt  <= loader_hs_cnt + 1;
        loader_last_cyc <= cyc;
      end
      if (dma_hs) begin
        if (dma_hs_cnt == 0) dma_first_cyc <= cyc;
        dma_hs_cnt  <= dma_hs_cnt + 1;
        dma_last_cyc <= cyc;
      end
      if (cpu_hs) cpu_hs_cnt <= cpu_hs_cnt + 1;

      if (loader_hs && dma_hs) both_hs_cnt <= both_hs_cnt + 1;

      if (p1_loader_cmd_valid && !p1_loader_cmd_ready) loader_stall_cnt <= loader_stall_cnt + 1;
      if (p1_dma_cmd_valid && !p1_dma_cmd_ready)       dma_stall_cnt    <= dma_stall_cnt + 1;
      if (p1_cpu_cmd_valid && !p1_cpu_cmd_ready)       cpu_stall_cnt    <= cpu_stall_cnt + 1;

      if (p1_loader_rsp_valid && p1_loader_rsp_ready && p1_loader_rsp_err) begin
        load_err_cnt <= load_err_cnt + 1;
        $display("[TB] loader rsp_err");
      end

      // A bank conflict is a cycle in which two or more masters ask the same
      // bank for a new command.
      req_b0 = 0;
      req_b1 = 0;
      if (p1_cpu_cmd_valid)    begin if (p1_cpu_cmd_addr[12])    req_b1 = req_b1 + 1; else req_b0 = req_b0 + 1; end
      if (p1_loader_cmd_valid) begin if (p1_loader_cmd_addr[12]) req_b1 = req_b1 + 1; else req_b0 = req_b0 + 1; end
      if (p1_dma_cmd_valid)    begin if (p1_dma_cmd_addr[12])    req_b1 = req_b1 + 1; else req_b0 = req_b0 + 1; end
      conflict_inc = 0;
      if (req_b0 > 1) conflict_inc = conflict_inc + 1;
      if (req_b1 > 1) conflict_inc = conflict_inc + 1;
      if (conflict_inc != 0) conflict_cnt <= conflict_cnt + conflict_inc;

      if (p1_loader_cmd_valid && p1_dma_cmd_valid &&
          (p1_loader_cmd_addr[12] == p1_dma_cmd_addr[12]))
        conf_ld_dma <= conf_ld_dma + 1;
      if (p1_cpu_cmd_valid && p1_loader_cmd_valid &&
          (p1_cpu_cmd_addr[12] == p1_loader_cmd_addr[12]))
        conf_cpu_ld <= conf_cpu_ld + 1;
      if (p1_cpu_cmd_valid && p1_dma_cmd_valid &&
          (p1_cpu_cmd_addr[12] == p1_dma_cmd_addr[12]))
        conf_cpu_dma <= conf_cpu_dma + 1;

      if ((loader_hs_cnt > 0) &&
          (cyc >= loader_first_cyc + SS_START) &&
          (cyc <  loader_first_cyc + SS_END)) begin
        ss_cyc       <= ss_cyc + 1;
        if (loader_hs) ss_loader_hs <= ss_loader_hs + 1;
        if (dma_hs)    ss_dma_hs    <= ss_dma_hs + 1;
      end
    end
  end

  initial begin
    loader_hs_cnt = 0; dma_hs_cnt = 0; cpu_hs_cnt = 0;
    loader_first_cyc = 0; loader_last_cyc = 0; dma_first_cyc = 0; dma_last_cyc = 0;
    loader_stall_cnt = 0; dma_stall_cnt = 0; cpu_stall_cnt = 0;
    both_hs_cnt = 0; conflict_cnt = 0;
    conf_ld_dma = 0; conf_cpu_ld = 0; conf_cpu_dma = 0;
    ss_cyc = 0; ss_loader_hs = 0; ss_dma_hs = 0;
    load_err_cnt = 0;
  end

  // ------------------------------------------------------------------
  // Reporting
  // ------------------------------------------------------------------
  task automatic report_stream_stats;
    real loader_rate, dma_rate, ss_loader_rate, ss_dma_rate;
    int  loader_win, dma_win;
    loader_win = loader_last_cyc - loader_first_cyc + 1;
    dma_win    = dma_last_cyc - dma_first_cyc + 1;
    loader_rate = (loader_win > 0) ? (1.0 * LOAD_WORDS / loader_win) : 0.0;
    dma_rate    = (dma_win > 0)    ? (1.0 * LOAD_WORDS / dma_win)    : 0.0;
    ss_loader_rate = (ss_cyc > 0) ? (1.0 * ss_loader_hs / ss_cyc) : 0.0;
    ss_dma_rate    = (ss_cyc > 0) ? (1.0 * ss_dma_hs / ss_cyc)    : 0.0;

    $display("");
    $display("================ streaming phase statistics ================");
    $display("[STAT] loader : %0d words, cycles %0d..%0d (%0d), %.3f word/cycle, %0d stalls",
             LOAD_WORDS, loader_first_cyc, loader_last_cyc, loader_win, loader_rate,
             loader_stall_cnt);
    $display("[STAT] DMA    : %0d words, cycles %0d..%0d (%0d), %.3f word/cycle, %0d stalls",
             LOAD_WORDS, dma_first_cyc, dma_last_cyc, dma_win, dma_rate, dma_stall_cnt);
    $display("[STAT] steady window is [loader_first+%0d, loader_first+%0d): %0d cycles, loader %.3f, DMA %.3f word/cycle",
             SS_START, SS_END, ss_cyc, ss_loader_rate, ss_dma_rate);
    $display("[STAT] memory init (CPU zero-fill upper 256 KB): %0d cycles", cyc_init_done);
    $display("[STAT] loader+DMA command in the same cycle: %0d", both_hs_cnt);
    $display("[STAT] bank demand-conflict cycles: %0d (loader/DMA %0d, CPU/loader %0d, CPU/DMA %0d)",
             conflict_cnt, conf_ld_dma, conf_cpu_ld, conf_cpu_dma);
    $display("[STAT] arbitration stalls: loader %0d, DMA %0d, CPU %0d (%0d CPU transactions)",
             loader_stall_cnt, dma_stall_cnt, cpu_stall_cnt, cpu_txn_cnt);
    $display("[STAT] total cycles: %0d", cyc);
    $display("============================================================");
    $display("");
  endtask

  // ------------------------------------------------------------------
  // Main sequence
  // ------------------------------------------------------------------
  initial begin
    loader_start = 1'b0;
    loader_base  = 32'b0;
    loader_len   = 32'b0;
    dma_en       = 1'b0;
    cpu_stop     = 1'b0;
    phase2       = 1'b0;
    sweep_go     = 1'b0;

    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    // Wait for the CPU zero-fill of the upper 256 KB.
    wait (cpu_init_done === 1'b1);
    cyc_init_done = cyc;

    loader_base  <= 32'b0;
    loader_len   <= LOAD_WORDS;
    loader_start <= 1'b1;
    @(posedge clk);
    loader_start <= 1'b0;
    dma_en       <= 1'b1;

    wait (loader_done === 1'b1);
    wait (dma_resp_idx == LOAD_WORDS);

    // The strict bus gives the CPU the lowest priority, so its phase-1 random
    // traffic is starved while the loader/DMA stream.  Now that both are
    // quiet, let it run its traffic so the CPU path is still exercised with
    // real SRAM reads/writes (including byte masks) before the phase-2 mux.
    wait (cpu_txn_cnt >= 600 || cyc > cyc_init_done + 400000);
    cpu_stop <= 1'b1;
    wait (cpu_state == CPU_IDLE);
    repeat (4) @(posedge clk);

    report_stream_stats;

    phase2 <= 1'b1;
    cyc_p2_start = cyc;
    wait (rm0_rand_done === 1'b1 && rm1_rand_done === 1'b1 && rm2_rand_done === 1'b1);
    cyc_rand_done = cyc;
    repeat (2) @(posedge clk);
    sweep_go <= 1'b1;
    wait (rm0_done === 1'b1);
    cyc_sweep_done = cyc;
    repeat (4) @(posedge clk);

    finish_test;
  end

  task automatic finish_test;
    int total_err;
    total_err = cpu_err_cnt + dma_err_cnt + load_err_cnt
              + int'(rm0_err_cnt) + int'(rm1_err_cnt) + int'(rm2_err_cnt);

    $display("================== backpressure phase =====================");
    $display("[STAT] 3 x %0d random commands, rsp_ready randomly low 35%% of pending beats",
             RM_TRANS);
    $display("[STAT] backpressure beats: rm0 %0d, rm1 %0d, rm2 %0d",
             rm0_bp_cnt, rm1_bp_cnt, rm2_bp_cnt);
    $display("[STAT] phase2 timing: random %0d cycles, sweep %0d cycles (%0d words)",
             cyc_rand_done - cyc_p2_start, cyc_sweep_done - cyc_rand_done, MEM_WORDS);
    $display("[STAT] random master 0 (with sweep): %0d errors", rm0_err_cnt);
    $display("[STAT] random master 1            : %0d errors", rm1_err_cnt);
    $display("[STAT] random master 2            : %0d errors", rm2_err_cnt);
    $display("[STAT] CPU read errors %0d, DMA errors %0d, loader errors %0d",
             cpu_err_cnt, dma_err_cnt, load_err_cnt);
    $display("[STAT] loader_wptr = 0x%08x (expect 0x%08x), MMIO read = 0x%08x",
             loader_wptr, LOAD_WORDS * 4, wptr_rd_rdata);
    $display("============================================================");

    if (loader_hs_cnt != LOAD_WORDS) begin
      total_err = total_err + 1;
      $display("[TB] loader issued %0d words, expected %0d", loader_hs_cnt, LOAD_WORDS);
    end
    if (dma_resp_idx != LOAD_WORDS) begin
      total_err = total_err + 1;
      $display("[TB] DMA received %0d words, expected %0d", dma_resp_idx, LOAD_WORDS);
    end
    if (cpu_txn_cnt < 500) begin
      total_err = total_err + 1;
      $display("[TB] CPU transaction count too small: %0d", cpu_txn_cnt);
    end
    if (loader_wptr !== LOAD_WORDS * 4) begin
      total_err = total_err + 1;
      $display("[TB] loader_wptr mismatch");
    end
    if (wptr_rd_rdata !== loader_wptr) begin
      total_err = total_err + 1;
      $display("[TB] MMIO wptr read mismatch");
    end
    if (loader_wptr_local !== loader_wptr) begin
      total_err = total_err + 1;
      $display("[TB] loader local wptr %08x != published %08x",
               loader_wptr_local, loader_wptr);
    end
    if (!loader_wptr_valid) begin
      total_err = total_err + 1;
      $display("[TB] loader_wptr_valid is low after the load");
    end
    if (loader_base_pub !== 0) begin
      total_err = total_err + 1;
      $display("[TB] loader_base %08x, expected 0", loader_base_pub);
    end

    // Reference-DMA boundary checks: the last word is released, A == wptr is
    // not, and the A+4 bound is not bypassed by done.
    if (!dma_word_allowed_now(0, 1'b1)) begin
      total_err = total_err + 1;
      $display("[TB] dma_word_allowed(base) rejected after a complete load");
    end
    if (!dma_word_allowed_now((LOAD_WORDS - 1) * 4, 1'b1)) begin
      total_err = total_err + 1;
      $display("[TB] dma_word_allowed(last word) rejected");
    end
    if (dma_word_allowed_now(LOAD_WORDS * 4, 1'b1)) begin
      total_err = total_err + 1;
      $display("[TB] dma_word_allowed(A == wptr) accepted");
    end

    if (total_err == 0) begin
      $display("");
      $display("TEST PASSED");
      $finish;
    end else begin
      $fatal(1, "TEST FAILED: %0d errors", total_err);
    end
  endtask

  // Watchdog
  initial begin
    #20_000_000;
    $fatal(1, "TEST FAILED: timeout");
  end

endmodule

// ----------------------------------------------------------------------
// Random ICB master for the backpressure phase.
//
// Keeps one command outstanding (the crossbar contract), presents the next
// command immediately after the previous one is accepted, randomizes
// rsp_ready, and checks every response and every backpressured data beat
// against the shadow model.  The DO_SWEEP instance re-reads the whole memory
// sequentially after sweep_go.
// ----------------------------------------------------------------------
module kse_rand_master #(
  parameter int SEED      = 1,
  parameter int N_TRANS   = 4000,
  parameter int MEM_WORDS = 131072,
  parameter bit DO_SWEEP  = 1'b0
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        enable,
  input  logic        sweep_go,

  output logic        cmd_valid,
  input  logic        cmd_ready,
  output logic [31:0] cmd_addr,
  output logic        cmd_read,
  output logic [31:0] cmd_wdata,
  output logic [3:0]  cmd_wmask,

  input  logic        rsp_valid,
  output logic        rsp_ready,
  input  logic [31:0] rsp_rdata,
  input  logic        rsp_err,

  input  logic [31:0] shadow_rd_data,

  output logic        rand_done,
  output logic        done,
  output int unsigned err_cnt,
  output int unsigned bp_cnt
);

  localparam logic [1:0] MODE_IDLE  = 2'd0;
  localparam logic [1:0] MODE_RAND  = 2'd1;
  localparam logic [1:0] MODE_SWEEP = 2'd2;
  localparam logic [1:0] MODE_FIN   = 2'd3;

  logic [31:0] rnd_q;

  function automatic logic [31:0] rnd;
    logic [31:0] x;
    x = rnd_q;
    x = x ^ (x << 13);
    x = x ^ (x >> 17);
    x = x ^ (x << 5);
    rnd_q = x;
    return x;
  endfunction

  logic [1:0]  mode;
  logic        issue_valid;
  logic [31:0] issue_addr;
  logic        issue_read;
  logic [31:0] issue_wdata;
  logic [3:0]  issue_wmask;

  logic [31:0] issue_cnt;
  logic [31:0] resp_cnt;
  logic        pend_valid;
  logic        pend_read;
  logic [31:0] pend_exp;
  logic        rsp_ready_q;

  logic [31:0] sweep_idx;
  logic [31:0] sweep_cnt;
  logic [31:0] sweep_rsp_cnt;

  int unsigned err_cnt_q;
  int unsigned bp_cnt_q;
  logic        rand_done_q;
  logic        sweep_started;
  int unsigned err_inc;

  wire cmd_hs = cmd_valid & cmd_ready;
  wire rsp_hs = rsp_valid & rsp_ready;

  assign cmd_valid = issue_valid && ((mode == MODE_RAND) || (mode == MODE_SWEEP));
  assign cmd_addr  = issue_addr;
  assign cmd_read  = issue_read;
  assign cmd_wdata = issue_wdata;
  assign cmd_wmask = issue_read ? 4'b0000 : issue_wmask;
  // The sweep is a final integrity pass: no artificial backpressure.
  assign rsp_ready = (mode == MODE_SWEEP) ? 1'b1
                   : (pend_valid ? rsp_ready_q : 1'b1);

  assign rand_done = rand_done_q;
  assign done      = (mode == MODE_FIN);
  assign err_cnt   = err_cnt_q;
  assign bp_cnt    = bp_cnt_q;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rnd_q          <= SEED[31:0];
      mode           <= MODE_IDLE;
      issue_valid    <= 1'b0;
      issue_addr     <= 32'b0;
      issue_read     <= 1'b0;
      issue_wdata    <= 32'b0;
      issue_wmask    <= 4'hF;
      issue_cnt      <= 32'b0;
      resp_cnt       <= 32'b0;
      pend_valid     <= 1'b0;
      pend_read      <= 1'b0;
      pend_exp       <= 32'b0;
      rsp_ready_q    <= 1'b1;
      sweep_idx      <= 32'b0;
      sweep_cnt      <= 32'b0;
      sweep_rsp_cnt  <= 32'b0;
      err_cnt_q      <= 0;
      bp_cnt_q       <= 0;
      rand_done_q    <= 1'b0;
      sweep_started  <= 1'b0;
    end else begin
      err_inc = 0;

      // Random response backpressure while a response is pending.
      rsp_ready_q <= ((rnd() % 100) >= 35);

      if (mode == MODE_IDLE && enable) begin
        mode        <= MODE_RAND;
        issue_valid <= 1'b1;
        issue_addr  <= (rnd() % MEM_WORDS) << 2;
        issue_read  <= rnd() % 2;
        issue_wdata <= rnd();
        issue_wmask <= (rnd() % 15) + 1;
        issue_cnt   <= 32'b0;
        resp_cnt    <= 32'b0;
        pend_valid  <= 1'b0;
      end

      // Count backpressured response beats.
      if (rsp_valid && !rsp_ready) bp_cnt_q <= bp_cnt_q + 1;

      // Read data must stay stable while the response is backpressured.
      if (rsp_valid && !rsp_ready && pend_valid && pend_read && (rsp_rdata !== pend_exp)) begin
        err_inc = err_inc + 1;
        if (err_cnt_q < 10)
          $display("[RM %0d] read data changed under backpressure: got %08x exp %08x",
                   SEED, rsp_rdata, pend_exp);
      end

      if (cmd_hs) begin
        if (pend_valid && !rsp_hs) begin
          err_inc = err_inc + 1;
          if (err_cnt_q < 10)
            $display("[RM %0d] second command accepted while a response is outstanding", SEED);
        end
        pend_valid <= 1'b1;
        pend_read  <= issue_read;
        pend_exp   <= issue_read ? shadow_rd_data : issue_wdata;

        if (mode == MODE_RAND) begin
          issue_cnt <= issue_cnt + 1;
          if ((issue_cnt + 1) >= N_TRANS) begin
            issue_valid <= 1'b0;
          end else begin
            issue_addr  <= (rnd() % MEM_WORDS) << 2;
            issue_read  <= rnd() % 2;
            issue_wdata <= rnd();
            issue_wmask <= (rnd() % 15) + 1;
          end
        end else if (mode == MODE_SWEEP) begin
          sweep_cnt <= sweep_cnt + 1;
          if ((sweep_cnt + 1) >= MEM_WORDS) begin
            issue_valid <= 1'b0;
          end else begin
            sweep_idx  <= sweep_idx + 1;
            issue_addr <= (sweep_idx + 1) << 2;
          end
        end
      end

      if (rsp_hs) begin
        if (!pend_valid) begin
          err_inc = err_inc + 1;
          if (err_cnt_q < 10)
            $display("[RM %0d] unexpected response (duplicate or lost ordering)", SEED);
        end else begin
          if (rsp_err) begin
            err_inc = err_inc + 1;
            if (err_cnt_q < 10) $display("[RM %0d] rsp_err", SEED);
          end
          if (pend_read && (rsp_rdata !== pend_exp)) begin
            err_inc = err_inc + 1;
            if (err_cnt_q < 10)
              $display("[RM %0d] read mismatch at %08x: got %08x exp %08x",
                       SEED, issue_addr, rsp_rdata, pend_exp);
          end
        end

        if (mode == MODE_RAND)       resp_cnt       <= resp_cnt + 1;
        else if (mode == MODE_SWEEP) sweep_rsp_cnt <= sweep_rsp_cnt + 1;

        if (!cmd_hs) pend_valid <= 1'b0;
      end

      if (err_inc != 0) err_cnt_q <= err_cnt_q + err_inc;

      // Random phase drained.
      if (mode == MODE_RAND && !rand_done_q &&
          (issue_cnt == N_TRANS) && (resp_cnt == N_TRANS) && !pend_valid) begin
        rand_done_q <= 1'b1;
        if (DO_SWEEP) begin
          mode        <= MODE_SWEEP;
          issue_valid <= 1'b0;
        end else begin
          mode <= MODE_FIN;
        end
      end

      // Start the final sequential sweep once everyone else is quiet.
      if (mode == MODE_SWEEP && !sweep_started && sweep_go) begin
        sweep_started <= 1'b1;
        issue_valid <= 1'b1;
        issue_read  <= 1'b1;
        issue_wdata <= 32'b0;
        issue_addr  <= 32'b0;
        sweep_idx   <= 32'b0;
        sweep_cnt   <= 32'b0;
        sweep_rsp_cnt <= 32'b0;
      end

      // Sweep drained.
      if (mode == MODE_SWEEP && !issue_valid &&
          (sweep_cnt == MEM_WORDS) && (sweep_rsp_cnt == MEM_WORDS) && !pend_valid) begin
        mode <= MODE_FIN;
      end
    end
  end

endmodule
