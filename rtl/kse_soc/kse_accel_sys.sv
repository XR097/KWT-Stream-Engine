`default_nettype none
// KSE accelerator subsystem placed inside the E203 main subsystem:
//   * one system-bus ICB arbiter (kse_sys_bus, upstream sirv_gnrl_icb_arbt)
//     merging three masters: CPU O5 memory path, parameter loader and NPU DMA;
//   * one 512 KiB shared SRAM slave (kse_shared_sram, not counted as engine
//     area) behind that arbiter: 0x4000_0000..0x4007_FFFF, one 32-bit
//     transaction per cycle, no second port and no bank parallelism;
//   * kse_eng_icb: MMIO slave on the PPI O12 slot (0x1100_0000, 4 KiB used),
//     streaming DMA (a system-bus master through the arbiter), command queue
//     and kse_top; IRQ to PLIC source 17.
//
// Compile-time comparison hooks (never enabled in the delivered SoC):
//   +define+KSE_ARB_LOADER_FIRST : swap the priority order to loader > DMA
//   +define+KSE_REL_LAG_4096     : restore the old 4 KB release lag
`ifdef KSE_ARB_LOADER_FIRST
  `define KSE_DMA_OVER_LOADER 1'b0
`else
  `define KSE_DMA_OVER_LOADER 1'b1
`endif
`ifdef KSE_REL_LAG_4096
  `define KSE_REL_LAG 4096
`else
  `define KSE_REL_LAG 0
`endif

`ifdef KSE_LANES16
  `define KSE_SM_LANES 16
  `define KSE_LN_LANES 16
`else
  `define KSE_SM_LANES 8
  `define KSE_LN_LANES 8
`endif

`ifdef KSE_ARRAY_R16
  `define KSE_ARRAY_ROWS 16
`else
  `define KSE_ARRAY_ROWS 32
`endif

module kse_accel_sys (
  input  logic        clk,
  input  logic        rst_n,
  // CPU memory path (O5)
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
  // MMIO (O12)
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
  // parameter loader master (ICB only)
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
  output logic        irq
);
  // NPU DMA master toward the bus arbiter.
  logic        d_cmd_valid, d_cmd_ready, d_cmd_read, d_rsp_valid, d_rsp_ready, d_rsp_err;
  logic [31:0] d_cmd_addr, d_cmd_wdata, d_rsp_rdata;
  logic [3:0]  d_cmd_wmask;

  // Bus slave side of the one shared SRAM.
  logic        s_cmd_valid, s_cmd_ready, s_cmd_read, s_rsp_valid, s_rsp_ready, s_rsp_err;
  logic [31:0] s_cmd_addr, s_cmd_wdata, s_rsp_rdata;
  logic [3:0]  s_cmd_wmask;

  // Loader watermark published by the SRAM status register.
  logic [31:0] wptr, base, wptr_rd_unused;
  logic        ldr_done;
  logic        wptr_valid, wptr_rd_ready_unused;

  // ------------------------------------------------------------------
  // System bus: three masters -> one SRAM slave
  // ------------------------------------------------------------------
  kse_sys_bus #(.DMA_OVER_LOADER(`KSE_DMA_OVER_LOADER)) u_bus (
    .clk(clk), .rst_n(rst_n),
    .cpu_cmd_valid(cpu_cmd_valid), .cpu_cmd_ready(cpu_cmd_ready),
    .cpu_cmd_addr(cpu_cmd_addr), .cpu_cmd_read(cpu_cmd_read),
    .cpu_cmd_wdata(cpu_cmd_wdata), .cpu_cmd_wmask(cpu_cmd_wmask),
    .cpu_rsp_valid(cpu_rsp_valid), .cpu_rsp_ready(cpu_rsp_ready),
    .cpu_rsp_rdata(cpu_rsp_rdata), .cpu_rsp_err(cpu_rsp_err),
    .ldr_cmd_valid(ldr_cmd_valid), .ldr_cmd_ready(ldr_cmd_ready),
    .ldr_cmd_addr(ldr_cmd_addr), .ldr_cmd_read(ldr_cmd_read),
    .ldr_cmd_wdata(ldr_cmd_wdata), .ldr_cmd_wmask(ldr_cmd_wmask),
    .ldr_rsp_valid(ldr_rsp_valid), .ldr_rsp_ready(ldr_rsp_ready),
    .ldr_rsp_rdata(ldr_rsp_rdata), .ldr_rsp_err(ldr_rsp_err),
    .dma_cmd_valid(d_cmd_valid), .dma_cmd_ready(d_cmd_ready),
    .dma_cmd_addr(d_cmd_addr), .dma_cmd_read(d_cmd_read),
    .dma_cmd_wdata(d_cmd_wdata), .dma_cmd_wmask(d_cmd_wmask),
    .dma_rsp_valid(d_rsp_valid), .dma_rsp_ready(d_rsp_ready),
    .dma_rsp_rdata(d_rsp_rdata), .dma_rsp_err(d_rsp_err),
    .sram_cmd_valid(s_cmd_valid), .sram_cmd_ready(s_cmd_ready),
    .sram_cmd_addr(s_cmd_addr), .sram_cmd_read(s_cmd_read),
    .sram_cmd_wdata(s_cmd_wdata), .sram_cmd_wmask(s_cmd_wmask),
    .sram_rsp_valid(s_rsp_valid), .sram_rsp_ready(s_rsp_ready),
    .sram_rsp_rdata(s_rsp_rdata), .sram_rsp_err(s_rsp_err)
  );

  kse_shared_sram u_shram (
    .clk(clk), .rst_n(rst_n),
    .cmd_valid(s_cmd_valid), .cmd_ready(s_cmd_ready),
    .cmd_addr(s_cmd_addr), .cmd_read(s_cmd_read),
    .cmd_wdata(s_cmd_wdata), .cmd_wmask(s_cmd_wmask),
    .rsp_valid(s_rsp_valid), .rsp_ready(s_rsp_ready),
    .rsp_rdata(s_rsp_rdata), .rsp_err(s_rsp_err),
    .loader_done(ldr_done), .loader_wptr(wptr), .loader_base(base), .loader_wptr_valid(wptr_valid),
    .wptr_rd_valid(1'b0), .wptr_rd_ready(wptr_rd_ready_unused),
    .wptr_rd_rdata(wptr_rd_unused));

  // ------------------------------------------------------------------
  // Engine wrapper: MMIO + streaming DMA master + kse_top
  // ------------------------------------------------------------------
  kse_eng_icb #(.REL_LAG(`KSE_REL_LAG), .ARRAY_R(`KSE_ARRAY_ROWS), .SM_LANES(`KSE_SM_LANES), .LN_LANES(`KSE_LN_LANES)) u_eng (
    .clk(clk), .rst_n(rst_n),
    .mmio_cmd_valid(mmio_cmd_valid), .mmio_cmd_ready(mmio_cmd_ready),
    .mmio_cmd_addr(mmio_cmd_addr), .mmio_cmd_read(mmio_cmd_read),
    .mmio_cmd_wdata(mmio_cmd_wdata), .mmio_cmd_wmask(mmio_cmd_wmask),
    .mmio_rsp_valid(mmio_rsp_valid), .mmio_rsp_ready(mmio_rsp_ready),
    .mmio_rsp_rdata(mmio_rsp_rdata), .mmio_rsp_err(mmio_rsp_err),
    .dma_cmd_valid(d_cmd_valid), .dma_cmd_ready(d_cmd_ready),
    .dma_cmd_addr(d_cmd_addr), .dma_cmd_read(d_cmd_read),
    .dma_cmd_wdata(d_cmd_wdata), .dma_cmd_wmask(d_cmd_wmask),
    .dma_rsp_valid(d_rsp_valid), .dma_rsp_ready(d_rsp_ready),
    .dma_rsp_rdata(d_rsp_rdata), .dma_rsp_err(d_rsp_err),
    .ldr_wptr(wptr), .ldr_base(base), .ldr_wptr_valid(wptr_valid), .ldr_done(ldr_done),
    .irq(irq));
endmodule
`default_nettype wire
