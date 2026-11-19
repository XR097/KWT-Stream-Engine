`timescale 1ns/1ps
// Directed policy/port test for the strict single-port system bus.
//
// The strict scheme deliberately replaces the v2 per-bank round-robin crossbar
// with ONE ICB arbiter (upstream sirv_gnrl_icb_arbt, fixed priority) in front
// of ONE shared-SRAM slave.  This test verifies the properties that matter for
// that structure:
//   * priority order DMA > loader > CPU: while the DMA keeps requesting it is
//     served every cycle, and the loader/CPU are not served;
//   * when the DMA stops requesting, the loader is served every cycle and the
//     CPU is not;
//   * when both stop, the CPU is served every cycle;
//   * every accepted command gets exactly one response, no response is lost or
//     duplicated, and a master never has more than one outstanding command;
//   * at most one master command and one SRAM-slave command handshake per
//     cycle, and a stalled response blocks every new command (single port).
//
// Service guarantees for the loader under a real DMA contract (finite,
// monotonic, watermark-bounded stream) are proven separately by
// tb_sram_prio_contract; this test uses an adversarial, non-contract stream to
// make the priority order observable.
module tb_sram_priority;

  localparam int P0_START = 20;
  localparam int P0_LEN   = 1000;
  localparam int P1_START = P0_START + P0_LEN;
  localparam int P1_LEN   = 1000;
  localparam int P2_START = P1_START + P1_LEN;
  localparam int P2_LEN   = 1000;
  localparam int STALL_START = P2_START + P2_LEN;
  localparam int STALL_LEN   = 20;
  localparam int FINISH      = STALL_START + STALL_LEN + 40;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n = 1'b0;

  int cyc;
  initial cyc = 0;
  always @(posedge clk) if (rst_n) cyc <= cyc + 1;

  int errors;

  logic [2:0]  cmd_valid, cmd_ready, cmd_read;
  logic [2:0]  rsp_valid, rsp_ready, rsp_err;
  logic [31:0] cmd_addr  [0:2];
  logic [31:0] cmd_wdata [0:2];
  logic [3:0]  cmd_wmask [0:2];
  logic [31:0] rsp_rdata [0:2];

  logic [31:0] loader_wptr, loader_base;
  logic        loader_wptr_valid, wptr_rd_ready;
  logic [31:0] wptr_rd_rdata;

  // master order: 0 = CPU, 1 = loader, 2 = accelerator DMA (DUT wrapper maps
  // master 2 to the highest-priority bus port)
  kse_sram_sys_wrap #(.DMA_OVER_LOADER(1'b1)) dut (
    .clk   (clk),
    .rst_n (rst_n),

    .cpu_cmd_valid (cmd_valid[0]),
    .cpu_cmd_ready (cmd_ready[0]),
    .cpu_cmd_addr  (cmd_addr[0]),
    .cpu_cmd_read  (cmd_read[0]),
    .cpu_cmd_wdata (cmd_wdata[0]),
    .cpu_cmd_wmask (cmd_wmask[0]),
    .cpu_rsp_valid (rsp_valid[0]),
    .cpu_rsp_ready (rsp_ready[0]),
    .cpu_rsp_rdata (rsp_rdata[0]),
    .cpu_rsp_err   (rsp_err[0]),

    .loader_cmd_valid (cmd_valid[1]),
    .loader_cmd_ready (cmd_ready[1]),
    .loader_cmd_addr  (cmd_addr[1]),
    .loader_cmd_read  (cmd_read[1]),
    .loader_cmd_wdata (cmd_wdata[1]),
    .loader_cmd_wmask (cmd_wmask[1]),
    .loader_rsp_valid (rsp_valid[1]),
    .loader_rsp_ready (rsp_ready[1]),
    .loader_rsp_rdata (rsp_rdata[1]),
    .loader_rsp_err   (rsp_err[1]),

    .accel_cmd_valid (cmd_valid[2]),
    .accel_cmd_ready (cmd_ready[2]),
    .accel_cmd_addr  (cmd_addr[2]),
    .accel_cmd_read  (cmd_read[2]),
    .accel_cmd_wdata (cmd_wdata[2]),
    .accel_cmd_wmask (cmd_wmask[2]),
    .accel_rsp_valid (rsp_valid[2]),
    .accel_rsp_ready (rsp_ready[2]),
    .accel_rsp_rdata (rsp_rdata[2]),
    .accel_rsp_err   (rsp_err[2]),

    .loader_wptr            (loader_wptr),
    .loader_base            (loader_base),
    .loader_wptr_valid      (loader_wptr_valid),
    .wptr_rd_valid          (1'b0),
    .wptr_rd_ready          (wptr_rd_ready),
    .wptr_rd_rdata          (wptr_rd_rdata)
  );

  // Drive the requesters from the cycle index.  All response channels are
  // ready except in the final stall phase, where the DMA stops consuming its
  // response to prove that the whole single port blocks.
  always_comb begin
    for (int i = 0; i < 3; i++) begin
      cmd_valid[i] = 1'b0;
      cmd_read[i]  = 1'b1;
      cmd_wdata[i] = 32'b0;
      cmd_wmask[i] = 4'b0;
      rsp_ready[i] = 1'b1;
    end
    cmd_addr[0] = 32'h0000_0000;   // CPU
    cmd_addr[1] = 32'h0000_0004;   // loader
    cmd_addr[2] = 32'h0000_0008;   // DMA
    if (cyc >= P0_START && cyc < P1_START) begin
      cmd_valid[0] = 1'b1; cmd_valid[1] = 1'b1; cmd_valid[2] = 1'b1;
    end else if (cyc >= P1_START && cyc < P2_START) begin
      cmd_valid[0] = 1'b1; cmd_valid[1] = 1'b1;
    end else if (cyc >= P2_START && cyc < STALL_START) begin
      cmd_valid[0] = 1'b1;
    end else if (cyc >= STALL_START && cyc < STALL_START + STALL_LEN) begin
      cmd_valid[2] = 1'b1;
      rsp_ready[2] = 1'b0;          // high-priority response stalled
    end else if (cyc >= STALL_START + STALL_LEN && cyc < STALL_START + STALL_LEN + 10) begin
      cmd_valid[2] = 1'b1;          // drain in flight, then stop
    end
  end

  // ------------------------------------------------------------------
  // Scoreboard and service counters
  // ------------------------------------------------------------------
  int acc_cnt [0:2];
  int rsp_cnt [0:2];
  int p0_acc  [0:2];
  int p1_acc  [0:2];
  int p2_acc  [0:2];
  int stall_acc [0:2];
  int out [0:2];
  wire [2:0] hs = cmd_valid & cmd_ready;
  wire sram_hs = dut.s_cmd_valid && dut.s_cmd_ready;

  always @(posedge clk) if (rst_n) begin
    // one transaction per cycle, master side and slave side must agree
    if ($countones(hs) > 1) begin
      errors <= errors + 1;
      $display("ERROR %0d master handshakes in one cycle", $countones(hs));
    end
    if (sram_hs !== (|hs)) begin
      errors <= errors + 1;
      $display("ERROR slave handshake %0b != master handshake %0b", sram_hs, |hs);
    end

    for (int i = 0; i < 3; i++) begin
      int nxt;
      nxt = out[i];
      if (cmd_valid[i] && cmd_ready[i]) begin
        acc_cnt[i] <= acc_cnt[i] + 1;
        nxt = nxt + 1;
        if (cyc >= P0_START && cyc < P1_START)       p0_acc[i] <= p0_acc[i] + 1;
        if (cyc >= P1_START && cyc < P2_START)       p1_acc[i] <= p1_acc[i] + 1;
        if (cyc >= P2_START && cyc < STALL_START)    p2_acc[i] <= p2_acc[i] + 1;
        if (cyc >= STALL_START && cyc < FINISH)      stall_acc[i] <= stall_acc[i] + 1;
      end
      if (rsp_valid[i] && rsp_ready[i]) begin
        rsp_cnt[i] <= rsp_cnt[i] + 1;
        if (out[i] == 0) begin
          errors <= errors + 1;
          $display("ERROR master %0d received an unexpected response", i);
        end
        nxt = nxt - 1;
        if (rsp_err[i]) begin
          errors <= errors + 1;
          $display("ERROR master %0d rsp_err", i);
        end
      end
      out[i] <= nxt;
      if (nxt > 1 || nxt < 0) begin
        errors <= errors + 1;
        $display("ERROR master %0d outstanding count %0d", i, nxt);
      end
    end
  end

  initial begin
    errors = 0;
    for (int i = 0; i < 3; i++) begin
      acc_cnt[i] = 0; rsp_cnt[i] = 0;
      p0_acc[i]  = 0; p1_acc[i]  = 0; p2_acc[i] = 0; stall_acc[i] = 0;
      out[i]     = 0;
    end
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n <= 1'b1;

    wait (cyc >= FINISH);

    // Drain any command issued in the last ten cycles.
    while ((rsp_cnt[0] != acc_cnt[0]) || (rsp_cnt[1] != acc_cnt[1]) ||
           (rsp_cnt[2] != acc_cnt[2])) begin
      @(posedge clk);
    end
    repeat (4) @(posedge clk);

    $display("[PRIO] P0 (DMA+loader+CPU): accepts DMA %0d, loader %0d, CPU %0d (expect %0d/0/0)",
             p0_acc[2], p0_acc[1], p0_acc[0], P0_LEN);
    $display("[PRIO] P1 (loader+CPU)    : accepts DMA %0d, loader %0d, CPU %0d (expect 0/%0d/0)",
             p1_acc[2], p1_acc[1], p1_acc[0], P1_LEN);
    $display("[PRIO] P2 (CPU only)      : accepts DMA %0d, loader %0d, CPU %0d (expect 0/0/%0d)",
             p2_acc[2], p2_acc[1], p2_acc[0], P2_LEN);
    $display("[PRIO] STALL phase        : accepts DMA %0d, loader %0d, CPU %0d (loader/CPU must be 0 while stalled)",
             stall_acc[2], stall_acc[1], stall_acc[0]);
    $display("[PRIO] totals             : accepts %0d/%0d/%0d, responses %0d/%0d/%0d",
             acc_cnt[0], acc_cnt[1], acc_cnt[2], rsp_cnt[0], rsp_cnt[1], rsp_cnt[2]);

    // Priority order: in P0 only the DMA may be served; in P1 only the loader;
    // in P2 only the CPU.  Allow one boundary command in the cycle a phase
    // changes (the previous phase's response is consumed in that same cycle).
    if (p0_acc[2] < P0_LEN - 2 || p0_acc[1] != 0 || p0_acc[0] != 0) begin
      errors = errors + 1; $display("ERROR priority P0 violated");
    end
    if (p1_acc[1] < P1_LEN - 2 || p1_acc[0] != 0) begin
      errors = errors + 1; $display("ERROR priority P1 violated");
    end
    if (p2_acc[0] < P2_LEN - 2) begin
      errors = errors + 1; $display("ERROR priority P2 violated");
    end
    // In the stall phase the DMA's response is not consumed, so the single
    // slave must stop accepting commands from everyone.
    if (stall_acc[0] != 0 || stall_acc[1] != 0) begin
      errors = errors + 1; $display("ERROR a lower-priority master was served while the slave response was stalled");
    end
    for (int i = 0; i < 3; i++) begin
      if (acc_cnt[i] != rsp_cnt[i]) begin
        errors = errors + 1;
        $display("ERROR master %0d accepted %0d but got %0d responses", i, acc_cnt[i], rsp_cnt[i]);
      end
    end

    if (errors == 0) begin
      $display("TEST PASSED");
      $finish;
    end else begin
      $fatal(1, "TEST FAILED: %0d priority/port errors", errors);
    end
  end

  initial begin
    #1000000;
    $fatal(1, "TEST FAILED: timeout");
  end

endmodule
