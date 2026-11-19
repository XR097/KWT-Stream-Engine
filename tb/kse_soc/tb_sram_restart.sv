`timescale 1ns/1ps
// Directed test for the loader write-pointer restart protocol.
//
// The loader is started several times without resetting the DUT:
//   A) first load at a non-zero base (0x1000), 4 words;
//   B) restart at base 0 (a lower address), 4 words;
//   C) zero-length load at 0x3000;
//   D) non-zero base 0x2000, 4 words.
// Before each load the destination is poisoned, and a DMA-like reader only
// issues addresses inside [loader_base, loader_wptr).  If start does not
// re-publish the initial watermark (or loader_wptr_valid does not drop in the
// start cycle), the reader can read the poison of an address that the new
// image has not written yet; the directed test fails.
module tb_sram_restart;

  localparam int IMG_WORDS = 2048;
  localparam int STRIPE_BYTES = 4096;
  localparam int RD_IDLE = 0;
  localparam int RD_CMD  = 1;
  localparam int RD_RSP  = 2;
  localparam logic [31:0] POISON = 32'hDEAD_BEEF;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n = 1'b0;

  logic [31:0] img_mem [0:IMG_WORDS-1];

  function automatic logic [31:0] img_word(input int unsigned i);
    img_word = 32'hA5A5_0000 | (i & 32'h0000_FFFF);
  endfunction

  initial begin
    int fd;
    fd = $fopen("kse_sram_restart_img.hex", "w");
    if (fd == 0) begin
      $display("[RST] cannot create restart image");
      $fatal(1, "TEST FAILED: restart image");
    end
    for (int i = 0; i < IMG_WORDS; i = i + 1) begin
      img_mem[i] = img_word(i);
      $fdisplay(fd, "%08x", img_word(i));
    end
    $fclose(fd);
  end

  // ------------------------------------------------------------------
  // Ports
  // ------------------------------------------------------------------
  // CPU: poison writer / independent reader
  logic        cpu_cmd_valid, cpu_cmd_ready, cpu_cmd_read;
  logic [31:0] cpu_cmd_addr, cpu_cmd_wdata;
  logic [3:0]  cpu_cmd_wmask;
  logic        cpu_rsp_valid, cpu_rsp_ready, cpu_rsp_err;
  logic [31:0] cpu_rsp_rdata;

  // Loader
  logic        ldr_start, ldr_busy, ldr_done;
  logic [31:0] ldr_base, ldr_len;
  logic        ldr_cmd_valid, ldr_cmd_ready, ldr_cmd_read;
  logic [31:0] ldr_cmd_addr, ldr_cmd_wdata;
  logic [3:0]  ldr_cmd_wmask;
  logic        ldr_rsp_valid, ldr_rsp_ready, ldr_rsp_err;
  logic [31:0] ldr_rsp_rdata;
  logic [31:0] ldr_wptr_local;

  // DMA-like reader
  logic        rd_cmd_valid, rd_cmd_ready, rd_cmd_read;
  logic [31:0] rd_cmd_addr, rd_cmd_wdata;
  logic [3:0]  rd_cmd_wmask;
  logic        rd_rsp_valid, rd_rsp_ready, rd_rsp_err;
  logic [31:0] rd_rsp_rdata;
  logic        rd_en;
  logic [31:0] rd_base;
  int          rd_len, rd_idx, rd_err;
  logic [1:0]  rd_state;
  logic [31:0] rd_addr;

  logic [31:0] loader_wptr, loader_base;
  logic        loader_wptr_valid;
  logic        wptr_rd_ready;
  logic [31:0] wptr_rd_rdata;

  int errors;
  int init_cycle_err;

  // ------------------------------------------------------------------
  // DUT
  // ------------------------------------------------------------------
  kse_sram_sys_wrap dut (
    .clk   (clk),
    .rst_n (rst_n),

    .cpu_cmd_valid (cpu_cmd_valid),
    .cpu_cmd_ready (cpu_cmd_ready),
    .cpu_cmd_addr  (cpu_cmd_addr),
    .cpu_cmd_read  (cpu_cmd_read),
    .cpu_cmd_wdata (cpu_cmd_wdata),
    .cpu_cmd_wmask (cpu_cmd_wmask),
    .cpu_rsp_valid (cpu_rsp_valid),
    .cpu_rsp_ready (cpu_rsp_ready),
    .cpu_rsp_rdata (cpu_rsp_rdata),
    .cpu_rsp_err   (cpu_rsp_err),

    .loader_cmd_valid (ldr_cmd_valid),
    .loader_cmd_ready (ldr_cmd_ready),
    .loader_cmd_addr  (ldr_cmd_addr),
    .loader_cmd_read  (ldr_cmd_read),
    .loader_cmd_wdata (ldr_cmd_wdata),
    .loader_cmd_wmask (ldr_cmd_wmask),
    .loader_rsp_valid (ldr_rsp_valid),
    .loader_rsp_ready (ldr_rsp_ready),
    .loader_rsp_rdata (ldr_rsp_rdata),
    .loader_rsp_err   (ldr_rsp_err),

    .accel_cmd_valid (rd_cmd_valid),
    .accel_cmd_ready (rd_cmd_ready),
    .accel_cmd_addr  (rd_cmd_addr),
    .accel_cmd_read  (rd_cmd_read),
    .accel_cmd_wdata (rd_cmd_wdata),
    .accel_cmd_wmask (rd_cmd_wmask),
    .accel_rsp_valid (rd_rsp_valid),
    .accel_rsp_ready (rd_rsp_ready),
    .accel_rsp_rdata (rd_rsp_rdata),
    .accel_rsp_err   (rd_rsp_err),

    .loader_wptr            (loader_wptr),
    .loader_base            (loader_base),
    .loader_wptr_valid      (loader_wptr_valid),
    .wptr_rd_valid          (1'b1),
    .wptr_rd_ready          (wptr_rd_ready),
    .wptr_rd_rdata          (wptr_rd_rdata)
  );

  // ------------------------------------------------------------------
  // Reference DMA release rule (same criterion as the specification).
  // A + 4 <= wptr is an independent upper bound that done must not bypass:
  // a zero-length load (base == wptr) releases nothing, and A == wptr is
  // always rejected.  done only lifts the 4 KB lag rule for the tail stripe.
  // Addresses stay in the 512 KB domain, so a+4/a+4096 cannot wrap.
  // ------------------------------------------------------------------
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
                                            loader_base, loader_wptr_valid);
  endfunction

  // ------------------------------------------------------------------
  // Loader component
  // ------------------------------------------------------------------
  kse_param_loader #(
    .IMG_WORDS (IMG_WORDS),
    .IMAGE_FILE("kse_sram_restart_img.hex")
  ) u_loader (
    .clk       (clk),
    .rst_n     (rst_n),
    .start     (ldr_start),
    .base_addr (ldr_base),
    .length    (ldr_len),
    .busy      (ldr_busy),
    .done      (ldr_done),
    .cmd_valid (ldr_cmd_valid),
    .cmd_ready (ldr_cmd_ready),
    .cmd_addr  (ldr_cmd_addr),
    .cmd_read  (ldr_cmd_read),
    .cmd_wdata (ldr_cmd_wdata),
    .cmd_wmask (ldr_cmd_wmask),
    .rsp_valid (ldr_rsp_valid),
    .rsp_ready (ldr_rsp_ready),
    .rsp_rdata (ldr_rsp_rdata),
    .rsp_err   (ldr_rsp_err),
    .wptr            (ldr_wptr_local)
  );

  // ------------------------------------------------------------------
  // DMA-like reader: only issue inside [loader_base, loader_wptr).
  // ------------------------------------------------------------------
  assign rd_cmd_valid = (rd_state == RD_CMD);
  assign rd_cmd_addr  = rd_addr;
  assign rd_cmd_read  = 1'b1;
  assign rd_cmd_wdata = 32'b0;
  assign rd_cmd_wmask = 4'b0;
  assign rd_rsp_ready = (rd_state == RD_RSP);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_state <= RD_IDLE;
      rd_idx   <= 0;
      rd_addr  <= 32'b0;
      rd_err   <= 0;
      rd_base  <= 32'b0;
      rd_len   <= 0;
      rd_en    <= 1'b0;
    end else begin
      case (rd_state)
        RD_IDLE: begin
          if (rd_en && (rd_idx < rd_len) &&
              dma_word_allowed_now(rd_base + (rd_idx << 2), ldr_done)) begin
            rd_addr  <= rd_base + (rd_idx << 2);
            rd_state <= RD_CMD;
          end
        end
        RD_CMD: if (rd_cmd_valid && rd_cmd_ready) rd_state <= RD_RSP;
        RD_RSP: if (rd_rsp_valid) begin
          if (rd_rsp_err) begin
            rd_err <= rd_err + 1;
            $display("[RST] reader rsp_err at %08x", rd_addr);
          end else if (rd_rsp_rdata !== img_mem[rd_idx]) begin
            rd_err <= rd_err + 1;
            $display("[RST] reader mismatch at %08x: got %08x exp %08x (idx %0d)",
                     rd_addr, rd_rsp_rdata, img_mem[rd_idx], rd_idx);
          end
          rd_idx   <= rd_idx + 1;
          rd_state <= RD_IDLE;
        end
      endcase
    end
  end

  // Check BASE's bus commit replaces the prior interval and clears DONE.
  always @(posedge clk) if (rst_n && ldr_cmd_valid && ldr_cmd_ready &&
                            ldr_cmd_addr == 32'h40080000) begin
    #1;
    if (loader_wptr !== ldr_base || loader_base !== ldr_base ||
        !loader_wptr_valid || dut.u_shram.loader_done) begin
      init_cycle_err++;
      $display("[RST] BASE doorbell failed to initialize an empty interval");
    end
  end

  // ------------------------------------------------------------------
  // CPU helpers
  // ------------------------------------------------------------------
  task automatic cpu_write(input logic [31:0] a, input logic [31:0] d);
    @(posedge clk);
    cpu_cmd_valid <= 1'b1;
    cpu_cmd_addr  <= a;
    cpu_cmd_read  <= 1'b0;
    cpu_cmd_wdata <= d;
    cpu_cmd_wmask <= 4'hF;
    cpu_rsp_ready <= 1'b0;
    do @(posedge clk); while (!cpu_cmd_ready);
    cpu_cmd_valid <= 1'b0;
    cpu_rsp_ready <= 1'b1;
    do @(posedge clk); while (!cpu_rsp_valid);
    cpu_rsp_ready <= 1'b0;
  endtask

  task automatic cpu_read(input logic [31:0] a, output logic [31:0] d);
    @(posedge clk);
    cpu_cmd_valid <= 1'b1;
    cpu_cmd_addr  <= a;
    cpu_cmd_read  <= 1'b1;
    cpu_cmd_wdata <= 32'b0;
    cpu_cmd_wmask <= 4'b0;
    cpu_rsp_ready <= 1'b0;
    do @(posedge clk); while (!cpu_cmd_ready);
    cpu_cmd_valid <= 1'b0;
    do @(posedge clk); while (!cpu_rsp_valid);
    d = cpu_rsp_rdata;
    cpu_rsp_ready <= 1'b1;
    @(posedge clk);
    cpu_rsp_ready <= 1'b0;
  endtask

  // ------------------------------------------------------------------
  // Test helpers
  // ------------------------------------------------------------------
  task automatic poison(input logic [31:0] a, input int n);
    for (int i = 0; i < n; i = i + 1)
      cpu_write(a + (i << 2), POISON);
  endtask

  task automatic start_load(input logic [31:0] base, input logic [31:0] len);
    ldr_base  <= base;
    ldr_len   <= len;
    @(posedge clk);
    ldr_start <= 1'b1;
    @(posedge clk);
    ldr_start <= 1'b0;
    wait (ldr_cmd_valid && ldr_cmd_ready && ldr_cmd_addr == 32'h40080000);
    @(posedge clk); #1;
    if (loader_wptr !== base) begin
      errors = errors + 1;
      $display("[RST] after start: wptr %08x, expected base %08x", loader_wptr, base);
    end
    if (loader_base !== base) begin
      errors = errors + 1;
      $display("[RST] after start: base %08x, expected %08x", loader_base, base);
    end
    if (!loader_wptr_valid) begin
      errors = errors + 1;
      $display("[RST] after start: loader_wptr_valid low");
    end
    if (ldr_wptr_local !== base) begin
      errors = errors + 1;
      $display("[RST] local wptr %08x, expected %08x", ldr_wptr_local, base);
    end
  endtask

  task automatic start_reader(input logic [31:0] base, input int len);
    while ((rd_state != RD_IDLE) || rd_en) @(posedge clk);
    rd_base <= base;
    rd_len  <= len;
    rd_idx  <= 0;
    rd_err  <= 0;
    rd_en   <= 1'b1;
  endtask

  task automatic wait_loader_done(input int limit);
    int t;
    t = 0;
    while (!ldr_done) begin
      @(posedge clk);
      t = t + 1;
      if (t > limit) begin
        errors = errors + 1;
        $display("[RST] loader done timeout");
        return;
      end
    end
  endtask

  task automatic wait_reader_done(input int limit);
    int t;
    t = 0;
    while (rd_idx < rd_len) begin
      @(posedge clk);
      t = t + 1;
      if (t > limit) begin
        errors = errors + 1;
        $display("[RST] reader done timeout (idx %0d of %0d)", rd_idx, rd_len);
        return;
      end
    end
    rd_en <= 1'b0;
    @(posedge clk);
  endtask

  task automatic check_pointer(input logic [31:0] base, input int len, input string tag);
    if (loader_wptr !== (base + (len << 2))) begin
      errors = errors + 1;
      $display("[RST] %s: wptr %08x, expected %08x", tag, loader_wptr,
               base + (len << 2));
    end
    if (loader_base !== base) begin
      errors = errors + 1;
      $display("[RST] %s: base %08x, expected %08x", tag, loader_base, base);
    end
    if (!loader_wptr_valid) begin
      errors = errors + 1;
      $display("[RST] %s: loader_wptr_valid low", tag);
    end
    if (wptr_rd_rdata !== loader_wptr) begin
      errors = errors + 1;
      $display("[RST] %s: MMIO wptr %08x != %08x", tag, wptr_rd_rdata, loader_wptr);
    end
  endtask

  // ------------------------------------------------------------------
  // Boundary checks for the reference DMA release rule
  // ------------------------------------------------------------------
  task automatic check_dma_boundaries(input logic [31:0] base,
                                      input int          len,
                                      input string       tag);
    logic [31:0] last;
    if (len == 0) begin
      // Zero-length load: valid=1, wptr=base, done=1.  The A+4 bound must
      // reject A=base even though done is high.
      if (dma_word_allowed_now(base, 1'b1)) begin
        errors = errors + 1;
        $display("[RST] %s: zero-length done allowed A=base %08x", tag, base);
      end
      if (dma_word_allowed_now(base, 1'b0)) begin
        errors = errors + 1;
        $display("[RST] %s: zero-length not-done allowed A=base %08x", tag, base);
      end
    end else begin
      last = base + (len << 2) - 4;
      if (!dma_word_allowed_now(base, 1'b1)) begin
        errors = errors + 1;
        $display("[RST] %s: first word %08x rejected after done", tag, base);
      end
      if (!dma_word_allowed_now(last, 1'b1)) begin
        errors = errors + 1;
        $display("[RST] %s: last word %08x rejected after done", tag, last);
      end
      if (dma_word_allowed_now(base + (len << 2), 1'b1)) begin
        errors = errors + 1;
        $display("[RST] %s: A==wptr %08x allowed after done",
                 tag, base + (len << 2));
      end
      // If the 4 KB lag rule does not hold, done=0 must reject the last word.
      if (((last + STRIPE_BYTES) > loader_wptr) &&
          dma_word_allowed_now(last, 1'b0)) begin
        errors = errors + 1;
        $display("[RST] %s: done=0 allowed tail word %08x", tag, last);
      end
    end
    // The base itself is the lower bound: base-4 must be rejected.
    if ((base >= 4) && dma_word_allowed_now(base - 4, 1'b1)) begin
      errors = errors + 1;
      $display("[RST] %s: below-base address %08x allowed", tag, base - 4);
    end
  endtask

  // ------------------------------------------------------------------
  // Main sequence
  // ------------------------------------------------------------------
  initial begin
    logic [31:0] d;
    errors = 0;
    init_cycle_err = 0;
    cpu_cmd_valid = 0;
    cpu_cmd_addr  = 0;
    cpu_cmd_read  = 0;
    cpu_cmd_wdata = 0;
    cpu_cmd_wmask = 0;
    cpu_rsp_ready = 0;
    ldr_start = 0;
    ldr_base  = 0;
    ldr_len   = 0;

    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n <= 1'b1;
    repeat (4) @(posedge clk);

    // A: first load at a non-zero base.
    poison(32'h0000_1000, 4);
    start_load(32'h0000_1000, 4);
    start_reader(32'h0000_1000, 4);
    wait_loader_done(1000);
    wait_reader_done(1000);
    check_pointer(32'h0000_1000, 4, "load A");
    cpu_read(32'h40080000, d);
    if (d !== 32'h1000) begin errors++; $display("[RST] bus BASE read failed"); end
    cpu_read(32'h40080004, d);
    if (d !== 32'h1010) begin errors++; $display("[RST] bus WPTR read failed"); end
    cpu_read(32'h40080008, d);
    if (d !== 3) begin errors++; $display("[RST] bus DONE/VALID read failed"); end
    check_dma_boundaries(32'h0000_1000, 4, "load A");
    if (rd_err != 0) begin
      errors = errors + 1;
      $display("[RST] load A reader errors: %0d", rd_err);
    end

    // B: restart at base 0 without resetting the DUT.  The destination is
    // poisoned, so a stale watermark that lets the reader run early shows up
    // as a data mismatch.
    poison(32'h0000_0000, 4);
    start_load(32'h0000_0000, 4);
    start_reader(32'h0000_0000, 4);
    wait_loader_done(1000);
    wait_reader_done(1000);
    check_pointer(32'h0000_0000, 4, "load B");
    check_dma_boundaries(32'h0000_0000, 4, "load B");
    if (rd_err != 0) begin
      errors = errors + 1;
      $display("[RST] load B reader errors: %0d", rd_err);
    end

    // C: zero-length load at a third base.  The watermark must become the
    // base and the poison must remain untouched.
    poison(32'h0000_3000, 1);
    start_load(32'h0000_3000, 0);
    wait_loader_done(100);
    check_pointer(32'h0000_3000, 0, "load C");
    check_dma_boundaries(32'h0000_3000, 0, "load C");
    cpu_read(32'h0000_3000, d);
    if (d !== POISON) begin
      errors = errors + 1;
      $display("[RST] zero-length load wrote %08x at base, expected poison", d);
    end

    // D: another non-zero base, with a poisoned word just below it.  The
    // published base must be 0x2000 and the reader must stay in [base, wptr).
    poison(32'h0000_1FFC, 1);
    poison(32'h0000_2000, 4);
    start_load(32'h0000_2000, 4);
    start_reader(32'h0000_2000, 4);
    wait_loader_done(1000);
    wait_reader_done(1000);
    check_pointer(32'h0000_2000, 4, "load D");
    check_dma_boundaries(32'h0000_2000, 4, "load D");
    if (rd_err != 0) begin
      errors = errors + 1;
      $display("[RST] load D reader errors: %0d", rd_err);
    end

    // E: one full 4 KB stripe plus a 6-word tail (1030 words).  The tail is
    // released only by done; the A+4 bound still rejects A == wptr.
    poison(32'h0000_4000, 1030);
    start_load(32'h0000_4000, 1030);
    start_reader(32'h0000_4000, 1030);
    wait_loader_done(20000);
    wait_reader_done(20000);
    check_pointer(32'h0000_4000, 1030, "load E");
    check_dma_boundaries(32'h0000_4000, 1030, "load E");
    if (rd_err != 0) begin
      errors = errors + 1;
      $display("[RST] load E reader errors: %0d", rd_err);
    end

    // Final MMIO sanity.
    if (wptr_rd_ready !== 1'b1) begin
      errors = errors + 1;
      $display("[RST] wptr_rd_ready is not 1");
    end

    errors = errors + init_cycle_err;

    if (errors == 0) begin
      $display("TEST PASSED");
      $finish;
    end else begin
      $fatal(1, "TEST FAILED: %0d restart errors", errors);
    end
  end

  initial begin
    #1000000;
    $fatal(1, "TEST FAILED: timeout");
  end

endmodule
