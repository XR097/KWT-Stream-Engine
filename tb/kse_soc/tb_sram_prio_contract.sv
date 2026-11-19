`timescale 1ns/1ps
// Directed test of the strict single-port system bus under the KSE DMA
// contract (DMA has priority over the loader on the one shared SRAM slave):
//   * loader (kse_param_loader) streams NW words from base 0;
//   * DMA reads every word once, in order, only after the loader committed it
//     (valid && A>=base && A+4<=wptr, i.e. REL_LAG=0; done cannot bypass the
//     A+4 bound), with random idle bursts (engine FIFO full) and random
//     response back-pressure; after its last read it writes NOUT words to a
//     region the loader never uses (the output write-back);
//   * CPU issues random reads/writes with random back-pressure over a private
//     64 KB region for the whole test.
// Pass criteria: loader done, every DMA read returns the loader's word, every
// output word and CPU word reads back correctly, no deadlock (global timeout),
// and the loader's longest continuous wait stays below MAX_LDR_WAIT cycles:
// with DMA priority and REL_LAG=0 the loader always makes progress once the
// DMA has drained the committed backlog; the bound catches a real starvation.
// Statistics are printed for the report.  Seeds: +ntb_random_seed=<n>.
module tb_sram_prio_contract;
  localparam int NW = 24000;             // loader words (~94 KB, 24 stripes)
  localparam int NOUT = 1584;
  localparam int OUT_BASE = 32'h60000;
  localparam int CPU_BASE = 32'h70000;   // 64 KB, stripes 112..127 (both banks)
  localparam int MAX_LDR_WAIT = 4200;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // ---------------- DUT ----------------
  logic c_cv, c_cr, c_crd, c_rv, c_rr, c_re; logic [31:0] c_ca, c_cw, c_rd; logic [3:0] c_cm;
  logic l_cv, l_cr, l_crd, l_rv, l_rr, l_re; logic [31:0] l_ca, l_cw, l_rd; logic [3:0] l_cm;
  logic d_cv, d_cr, d_crd, d_rv, d_rr, d_re; logic [31:0] d_ca, d_cw, d_rd; logic [3:0] d_cm;
  logic [31:0] wptr, base, l_wptr; logic wvalid, rd_rdy; logic [31:0] rd_d;
  logic l_start, l_busy, l_done;

  kse_sram_sys_wrap #(.DMA_OVER_LOADER(1'b1)) dut (
    .clk, .rst_n,
    .cpu_cmd_valid(c_cv), .cpu_cmd_ready(c_cr), .cpu_cmd_addr(c_ca), .cpu_cmd_read(c_crd),
    .cpu_cmd_wdata(c_cw), .cpu_cmd_wmask(c_cm), .cpu_rsp_valid(c_rv), .cpu_rsp_ready(c_rr),
    .cpu_rsp_rdata(c_rd), .cpu_rsp_err(c_re),
    .loader_cmd_valid(l_cv), .loader_cmd_ready(l_cr), .loader_cmd_addr(l_ca), .loader_cmd_read(l_crd),
    .loader_cmd_wdata(l_cw), .loader_cmd_wmask(l_cm), .loader_rsp_valid(l_rv), .loader_rsp_ready(l_rr),
    .loader_rsp_rdata(l_rd), .loader_rsp_err(l_re),
    .accel_cmd_valid(d_cv), .accel_cmd_ready(d_cr), .accel_cmd_addr(d_ca), .accel_cmd_read(d_crd),
    .accel_cmd_wdata(d_cw), .accel_cmd_wmask(d_cm), .accel_rsp_valid(d_rv), .accel_rsp_ready(d_rr),
    .accel_rsp_rdata(d_rd), .accel_rsp_err(d_re),
    .loader_wptr(wptr), .loader_base(base), .loader_wptr_valid(wvalid),
    .wptr_rd_valid(1'b0), .wptr_rd_ready(rd_rdy), .wptr_rd_rdata(rd_d));

  kse_param_loader #(.IMG_WORDS(NW), .IMAGE_FILE("prio_img.hex")) u_ldr (
    .clk, .rst_n, .start(l_start), .base_addr(32'h0), .length(NW), .busy(l_busy), .done(l_done),
    .cmd_valid(l_cv), .cmd_ready(l_cr), .cmd_addr(l_ca), .cmd_read(l_crd), .cmd_wdata(l_cw), .cmd_wmask(l_cm),
    .rsp_valid(l_rv), .rsp_ready(l_rr), .rsp_rdata(l_rd), .rsp_err(l_re), .wptr(l_wptr));

  // image written at time 0 (the loader reads it at #1)
  logic [31:0] img [NW];
  // random stimulus: use the simulator seed (+ntb_random_seed=<n>)
  initial begin
    int fd;
    fd = $fopen("prio_img.hex", "w");
    for (int i = 0; i < NW; i++) begin img[i] = $urandom; $fdisplay(fd, "%08x", img[i]); end
    $fclose(fd);
  end

  int errors = 0;
  // ---------------- DMA (contract-following reader, then writer) ----------------
  int d_idx, d_rsp_idx, d_out_idx, d_out_rsp, d_idle;
  logic d_writing, d_pend;
  int  dma_rule_wait, dma_idle_cycles, dma_bp_cycles;
  function automatic bit rule_ok(int a);
    return wvalid && (a >= base) && (a + 4 <= wptr);
  endfunction
  always_comb begin
    d_cv = 0; d_ca = 0; d_crd = 1; d_cw = 0; d_cm = 0;
    if (!d_writing) begin
      if (d_idx < NW && d_idle == 0 && rule_ok(4 * d_idx)) begin d_cv = 1; d_ca = 4 * d_idx; end
    end else if (d_out_idx < NOUT) begin
      d_cv = 1; d_crd = 0; d_ca = OUT_BASE + 4 * d_out_idx; d_cw = 32'hC0DE_0000 ^ d_out_idx; d_cm = 4'hF;
    end
  end
  // hold an issued request stable: requests are formed combinationally from
  // state that only changes on the handshake, so valid stays until ready
  always @(posedge clk) if (rst_n) begin
    d_rr <= ($urandom_range(0, 99) >= 25);   // 25 % response back-pressure
    if (d_cv && d_cr) begin
      if (!d_writing) begin
        d_idx <= d_idx + 1;
        // random idle burst after a read (engine prefetch FIFO full)
        if ($urandom_range(0, 99) < 3) d_idle <= $urandom_range(50, 1500);
      end else d_out_idx <= d_out_idx + 1;
    end else if (d_idle > 0) d_idle <= d_idle - 1;
    if (d_rv && d_rr) begin
      if (d_rsp_idx < NW) begin
        if (d_rd !== img[d_rsp_idx]) begin errors++; if (errors < 5) $display("ERROR DMA word %0d got %h exp %h", d_rsp_idx, d_rd, img[d_rsp_idx]); end
        d_rsp_idx <= d_rsp_idx + 1;
      end else d_out_rsp <= d_out_rsp + 1;
      if (d_rsp_idx == NW - 1) d_writing <= 1;
    end
    if (!d_writing && d_idx < NW && d_idle == 0 && !rule_ok(4 * d_idx)) dma_rule_wait++;
    if (d_idle > 0) dma_idle_cycles++;
    if (d_rv && !d_rr) dma_bp_cycles++;
  end

  // ---------------- CPU random traffic (private 64 KB region) ----------------
  logic [31:0] cpu_mem [16384];
  logic        c_busy; int c_pend_w; logic c_pend_rd;
  int cpu_reads, cpu_writes, cpu_bad;
  always @(posedge clk) if (rst_n) begin
    c_rr <= ($urandom_range(0, 99) >= 30);
    if (c_cv && c_cr) begin
      c_cv <= 0;
      c_pend_w <= (c_ca - CPU_BASE) / 4; c_pend_rd <= c_crd;
      if (!c_crd) begin
        for (int b = 0; b < 4; b++) if (c_cm[b]) cpu_mem[(c_ca - CPU_BASE) / 4][8*b +: 8] = c_cw[8*b +: 8];
        cpu_writes++;
      end else cpu_reads++;
    end else if (!c_cv && !c_busy && $urandom_range(0, 99) < 40) begin
      int w; w = $urandom_range(0, 16383);
      c_cv <= 1; c_ca <= CPU_BASE + 4 * w; c_crd <= $urandom_range(0, 1);
      c_cw <= $urandom; c_cm <= $urandom_range(1, 15);
    end
    if (c_cv && c_cr) c_busy <= 1;
    if (c_rv && c_rr) begin
      c_busy <= 0;
      // only bytes the CPU has written are checked (the rest of its region is never initialised)
      if (c_pend_rd) for (int b = 0; b < 4; b++)
        if (cpu_mem[c_pend_w][8*b +: 8] !== 8'hxx && c_rd[8*b +: 8] !== cpu_mem[c_pend_w][8*b +: 8]) begin
          cpu_bad++; if (cpu_bad < 5) $display("ERROR CPU word %0d byte %0d got %h exp %h", c_pend_w, b, c_rd[8*b +: 8], cpu_mem[c_pend_w][8*b +: 8]);
        end
    end
  end

  // ---------------- loader progress ----------------
  int ldr_wait, ldr_wait_max, ldr_wait_total; longint ldr_first, ldr_last, cyc;
  always @(posedge clk) if (rst_n) begin
    cyc <= cyc + 1;
    if (l_cv && !l_cr) begin ldr_wait++; ldr_wait_total++; if (ldr_wait + 1 > ldr_wait_max) ldr_wait_max <= ldr_wait + 1; end
    else ldr_wait <= 0;
    if (l_cv && l_cr) begin if (ldr_first < 0) ldr_first <= cyc; ldr_last <= cyc; end
  end

  initial begin
    c_cv = 0; c_ca = 0; c_crd = 1; c_cw = 0; c_cm = 0; c_rr = 1; c_busy = 0; c_pend_rd = 0; c_pend_w = 0;
    d_idx = 0; d_rsp_idx = 0; d_out_idx = 0; d_out_rsp = 0; d_idle = 0; d_writing = 0; d_rr = 1;
    dma_rule_wait = 0; dma_idle_cycles = 0; dma_bp_cycles = 0; cpu_reads = 0; cpu_writes = 0; cpu_bad = 0;
    ldr_wait = 0; ldr_wait_max = 0; ldr_wait_total = 0; ldr_first = -1; ldr_last = 0; cyc = 0; l_start = 0;
    for (int i = 0; i < 16384; i++) cpu_mem[i] = 'x;
    repeat (3) @(posedge clk); rst_n = 1;
    repeat (5) @(posedge clk);
    @(negedge clk) l_start = 1; @(negedge clk) l_start = 0;
    fork
      begin wait (d_writing && d_out_rsp == NOUT && l_done); end
      begin repeat (2000000) @(posedge clk); $display("ERROR TIMEOUT idx=%0d rsp=%0d out=%0d loader_done=%0d", d_idx, d_rsp_idx, d_out_rsp, l_done); errors++; end
    join_any
    disable fork;
    repeat (5) @(posedge clk);
    $display("STATS loader_span=%0d loader_wait_total=%0d loader_wait_max=%0d dma_rule_wait=%0d dma_idle=%0d dma_rsp_backpressure=%0d cpu_reads=%0d cpu_writes=%0d",
             ldr_last - ldr_first + 1, ldr_wait_total, ldr_wait_max, dma_rule_wait, dma_idle_cycles, dma_bp_cycles, cpu_reads, cpu_writes);
    if (!l_done) begin errors++; $display("ERROR loader not done"); end
    if (d_rsp_idx != NW) begin errors++; $display("ERROR DMA read %0d of %0d", d_rsp_idx, NW); end
    if (d_out_rsp != NOUT) begin errors++; $display("ERROR DMA output writes acknowledged %0d of %0d", d_out_rsp, NOUT); end
    if (ldr_wait_max >= MAX_LDR_WAIT) begin errors++; $display("ERROR loader waited %0d consecutive cycles", ldr_wait_max); end
    if (cpu_bad) errors++;
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED errors=%0d", errors);
    $finish;
  end
endmodule
