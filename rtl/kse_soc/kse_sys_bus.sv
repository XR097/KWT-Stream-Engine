// System-bus ICB arbiter: three masters -> one slave.
//
// The 512 KiB shared SRAM is an ordinary 32-bit ICB slave on the system bus.
// The three masters that reach it are merged by ONE arbiter before that slave:
//   * CPU memory path (E203 BIU O5, 0x4000_0000..0x4007_FFFF),
//   * parameter loader (test-platform ICB master),
//   * NPU DMA (kse_eng_icb streaming master).
//
// The arbiter is the upstream E203 sirv_gnrl_icb_arbt (only instantiated, the
// third-party source is untouched) with ARBT_NUM=3 and its fixed-priority
// policy (ARBT_SCHEME=0): port 0 wins over port 1, which wins over port 2.
// The default mapping gives the NPU DMA port 0 and the loader port 1, so a
// data-hungry engine is served first while the loader fills the remaining
// cycles.  This is safe under the KSE DMA contract: the DMA read stream is
// finite and monotonic and stops at the loader release watermark, after which
// the loader gets the port; the loader therefore always makes progress and
// neither stream can deadlock.  DMA_OVER_LOADER=0 swaps ports 0/1 for the
// measured comparison in the strict-scheme report.  The CPU is port 2: the
// firmware only touches the shared SRAM for FLAG_START before the window and
// FLAG_DONE after the loader and the DMA are drained, so it cannot be starved
// in the measured flow.
//
// The upstream response-id pipe (FIFO_OUTS_NUM=1, a single entry)
// allows one outstanding transaction in the fabric and still sustains one
// command per cycle: a response is consumed in the same cycle the next
// command is accepted.  This was checked by the shared-SRAM unit tests and by
// the SoC regression.
`default_nettype none
module kse_sys_bus #(
  // 1: priority order DMA > loader > CPU (default for the SoC)
  // 0: priority order loader > DMA > CPU (measured comparison only)
  parameter bit DMA_OVER_LOADER = 1'b1
) (
  input  logic        clk,
  input  logic        rst_n,

  // ------------------------------------------------------------------
  // Master 0/2: CPU memory path (port selection depends on the parameter)
  // ------------------------------------------------------------------
  input  logic        cpu_cmd_valid,
  output logic        cpu_cmd_ready,
  input  logic [31:0] cpu_cmd_addr,
  input  logic        cpu_cmd_read,
  input  logic [31:0] cpu_cmd_wdata,
  input  logic [3:0]  cpu_cmd_wmask,
  output logic        cpu_rsp_valid,
  input  logic        cpu_rsp_ready,
  output logic [31:0] cpu_rsp_rdata,
  output logic        cpu_rsp_err,

  // ------------------------------------------------------------------
  // Master: parameter loader
  // ------------------------------------------------------------------
  input  logic        ldr_cmd_valid,
  output logic        ldr_cmd_ready,
  input  logic [31:0] ldr_cmd_addr,
  input  logic        ldr_cmd_read,
  input  logic [31:0] ldr_cmd_wdata,
  input  logic [3:0]  ldr_cmd_wmask,
  output logic        ldr_rsp_valid,
  input  logic        ldr_rsp_ready,
  output logic [31:0] ldr_rsp_rdata,
  output logic        ldr_rsp_err,

  // ------------------------------------------------------------------
  // Master: NPU DMA
  // ------------------------------------------------------------------
  input  logic        dma_cmd_valid,
  output logic        dma_cmd_ready,
  input  logic [31:0] dma_cmd_addr,
  input  logic        dma_cmd_read,
  input  logic [31:0] dma_cmd_wdata,
  input  logic [3:0]  dma_cmd_wmask,
  output logic        dma_rsp_valid,
  input  logic        dma_rsp_ready,
  output logic [31:0] dma_rsp_rdata,
  output logic        dma_rsp_err,

  // ------------------------------------------------------------------
  // Slave: the one shared 32-bit ICB SRAM slave
  // ------------------------------------------------------------------
  output logic        sram_cmd_valid,
  input  logic        sram_cmd_ready,
  output logic [31:0] sram_cmd_addr,
  output logic        sram_cmd_read,
  output logic [31:0] sram_cmd_wdata,
  output logic [3:0]  sram_cmd_wmask,
  input  logic        sram_rsp_valid,
  output logic        sram_rsp_ready,
  input  logic [31:0] sram_rsp_rdata,
  input  logic        sram_rsp_err
);
  localparam int P_DMA = DMA_OVER_LOADER ? 0 : 1;
  localparam int P_LDR = DMA_OVER_LOADER ? 1 : 0;
  localparam int P_CPU = 2;

  logic [2:0]       m_cmd_valid, m_cmd_ready, m_cmd_read;
  logic [2:0][31:0] m_cmd_addr, m_cmd_wdata;
  logic [2:0][3:0]  m_cmd_wmask;
  logic [2:0]       m_rsp_valid, m_rsp_ready, m_rsp_err;
  logic [2:0][31:0] m_rsp_rdata;

  // Port 0 is the highest-priority port of the upstream priority arbiter.
  assign m_cmd_valid[P_CPU] = cpu_cmd_valid;
  assign m_cmd_addr [P_CPU] = cpu_cmd_addr;
  assign m_cmd_read [P_CPU] = cpu_cmd_read;
  assign m_cmd_wdata[P_CPU] = cpu_cmd_wdata;
  assign m_cmd_wmask[P_CPU] = cpu_cmd_wmask;

  assign m_cmd_valid[P_LDR] = ldr_cmd_valid;
  assign m_cmd_addr [P_LDR] = ldr_cmd_addr;
  assign m_cmd_read [P_LDR] = ldr_cmd_read;
  assign m_cmd_wdata[P_LDR] = ldr_cmd_wdata;
  assign m_cmd_wmask[P_LDR] = ldr_cmd_wmask;

  assign m_cmd_valid[P_DMA] = dma_cmd_valid;
  assign m_cmd_addr [P_DMA] = dma_cmd_addr;
  assign m_cmd_read [P_DMA] = dma_cmd_read;
  assign m_cmd_wdata[P_DMA] = dma_cmd_wdata;
  assign m_cmd_wmask[P_DMA] = dma_cmd_wmask;

  assign cpu_cmd_ready = m_cmd_ready[P_CPU];
  assign ldr_cmd_ready = m_cmd_ready[P_LDR];
  assign dma_cmd_ready = m_cmd_ready[P_DMA];

  assign cpu_rsp_valid = m_rsp_valid[P_CPU];
  assign cpu_rsp_rdata = m_rsp_rdata[P_CPU];
  assign cpu_rsp_err   = m_rsp_err[P_CPU];
  assign ldr_rsp_valid = m_rsp_valid[P_LDR];
  assign ldr_rsp_rdata = m_rsp_rdata[P_LDR];
  assign ldr_rsp_err   = m_rsp_err[P_LDR];
  assign dma_rsp_valid = m_rsp_valid[P_DMA];
  assign dma_rsp_rdata = m_rsp_rdata[P_DMA];
  assign dma_rsp_err   = m_rsp_err[P_DMA];

  assign m_rsp_ready[P_CPU] = cpu_rsp_ready;
  assign m_rsp_ready[P_LDR] = ldr_rsp_ready;
  assign m_rsp_ready[P_DMA] = dma_rsp_ready;

  // Upstream E203 ICB arbiter, instantiated unchanged.  ARBT_SCHEME=0 is the
  // fixed-priority policy; ARBT_SCHEME=1 would reference sirv_gnrl_rrobin,
  // which this pinned third-party snapshot does not contain.
  sirv_gnrl_icb_arbt #(
    .AW               (32),
    .DW               (32),
    .USR_W            (1),
    .ARBT_SCHEME      (0),
    .FIFO_OUTS_NUM    (1),
    .FIFO_CUT_READY   (0),
    .ARBT_NUM         (3),
    .ALLOW_0CYCL_RSP  (1),
    .ARBT_PTR_W       (2)
  ) u_arb (
    .o_icb_cmd_valid    (sram_cmd_valid),
    .o_icb_cmd_ready    (sram_cmd_ready),
    .o_icb_cmd_read     (sram_cmd_read),
    .o_icb_cmd_addr     (sram_cmd_addr),
    .o_icb_cmd_wdata    (sram_cmd_wdata),
    .o_icb_cmd_wmask    (sram_cmd_wmask),
    .o_icb_cmd_burst    (),
    .o_icb_cmd_beat     (),
    .o_icb_cmd_lock     (),
    .o_icb_cmd_excl     (),
    .o_icb_cmd_size     (),
    .o_icb_cmd_usr      (),

    .o_icb_rsp_valid    (sram_rsp_valid),
    .o_icb_rsp_ready    (sram_rsp_ready),
    .o_icb_rsp_err      (sram_rsp_err),
    .o_icb_rsp_excl_ok  (1'b0),
    .o_icb_rsp_rdata    (sram_rsp_rdata),
    .o_icb_rsp_usr      (1'b0),

    .i_bus_icb_cmd_ready(m_cmd_ready),
    .i_bus_icb_cmd_valid(m_cmd_valid),
    .i_bus_icb_cmd_read (m_cmd_read),
    .i_bus_icb_cmd_addr (m_cmd_addr),
    .i_bus_icb_cmd_wdata(m_cmd_wdata),
    .i_bus_icb_cmd_wmask(m_cmd_wmask),
    .i_bus_icb_cmd_burst(6'b0),
    .i_bus_icb_cmd_beat (6'b0),
    .i_bus_icb_cmd_lock (3'b0),
    .i_bus_icb_cmd_excl (3'b0),
    .i_bus_icb_cmd_size (6'b0),
    .i_bus_icb_cmd_usr  (3'b0),

    .i_bus_icb_rsp_valid(m_rsp_valid),
    .i_bus_icb_rsp_ready(m_rsp_ready),
    .i_bus_icb_rsp_err  (m_rsp_err),
    .i_bus_icb_rsp_excl_ok(),
    .i_bus_icb_rsp_rdata(m_rsp_rdata),
    .i_bus_icb_rsp_usr  (),

    .clk                (clk),
    .rst_n              (rst_n)
  );

`ifndef SYNTHESIS
  wire [2:0] m_hs = m_cmd_valid & m_cmd_ready;
  wire       s_hs = sram_cmd_valid & sram_cmd_ready;

  // One bus transaction per cycle in each direction: at most one master
  // command is accepted, and it is exactly the command the single SRAM slave
  // accepts.  This is the bus-side half of the "single 32-bit slave" proof.
  always @(posedge clk) if (rst_n) begin
    if ($countones(m_hs) > 1)
      $error("kse_sys_bus: %0d master commands accepted in one cycle", $countones(m_hs));
    if (s_hs !== (|m_hs))
      $error("kse_sys_bus: slave handshake (%0b) and master handshake (%0b) disagree",
             s_hs, |m_hs);
    if (s_hs && sram_rsp_valid && !sram_rsp_ready)
      $error("kse_sys_bus: slave accepted a command while its response is stalled");
  end
`endif

endmodule
`default_nettype wire
