`timescale 1ns/1ps
// Testbench-only wrapper: the strict-scheme system bus (one ICB arbiter)
// followed by the single 32-bit shared-SRAM slave.  The unit tests instantiate
// this wrapper with the same three master ports the old crossbar-based DUT
// exposed, so the checker logic is unchanged; only the DUT hierarchy is now a
// bus with one slave instead of a 3x2 crossbar.
module kse_sram_sys_wrap #(
  // 1: DMA > loader priority (same as the delivered SoC)
  // 0: loader > DMA priority (contract/fairness comparisons)
  parameter bit DMA_OVER_LOADER = 1'b1
) (
  input  logic        clk,
  input  logic        rst_n,

  // Master 0: CPU memory path
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

  // Master 1: parameter loader
  input  logic        loader_cmd_valid,
  output logic        loader_cmd_ready,
  input  logic [31:0] loader_cmd_addr,
  input  logic        loader_cmd_read,
  input  logic [31:0] loader_cmd_wdata,
  input  logic [3:0]  loader_cmd_wmask,
  output logic        loader_rsp_valid,
  input  logic        loader_rsp_ready,
  output logic [31:0] loader_rsp_rdata,
  output logic        loader_rsp_err,

  // Master 2: accelerator DMA
  input  logic        accel_cmd_valid,
  output logic        accel_cmd_ready,
  input  logic [31:0] accel_cmd_addr,
  input  logic        accel_cmd_read,
  input  logic [31:0] accel_cmd_wdata,
  input  logic [3:0]  accel_cmd_wmask,
  output logic        accel_rsp_valid,
  input  logic        accel_rsp_ready,
  output logic [31:0] accel_rsp_rdata,
  output logic        accel_rsp_err,

  // Loader write pointer status register
  output logic [31:0] loader_wptr,
  output logic [31:0] loader_base,
  output logic        loader_wptr_valid,

  // Read-only MMIO stub
  input  logic        wptr_rd_valid,
  output logic        wptr_rd_ready,
  output logic [31:0] wptr_rd_rdata
);

  logic        s_cmd_valid, s_cmd_ready, s_cmd_read, s_rsp_valid, s_rsp_ready, s_rsp_err;
  logic [31:0] s_cmd_addr, s_cmd_wdata, s_rsp_rdata;
  logic [3:0]  s_cmd_wmask;

  kse_sys_bus #(.DMA_OVER_LOADER(DMA_OVER_LOADER)) u_bus (
    .clk(clk), .rst_n(rst_n),
    .cpu_cmd_valid(cpu_cmd_valid), .cpu_cmd_ready(cpu_cmd_ready),
    .cpu_cmd_addr(cpu_cmd_addr), .cpu_cmd_read(cpu_cmd_read),
    .cpu_cmd_wdata(cpu_cmd_wdata), .cpu_cmd_wmask(cpu_cmd_wmask),
    .cpu_rsp_valid(cpu_rsp_valid), .cpu_rsp_ready(cpu_rsp_ready),
    .cpu_rsp_rdata(cpu_rsp_rdata), .cpu_rsp_err(cpu_rsp_err),
    .ldr_cmd_valid(loader_cmd_valid), .ldr_cmd_ready(loader_cmd_ready),
    .ldr_cmd_addr(loader_cmd_addr), .ldr_cmd_read(loader_cmd_read),
    .ldr_cmd_wdata(loader_cmd_wdata), .ldr_cmd_wmask(loader_cmd_wmask),
    .ldr_rsp_valid(loader_rsp_valid), .ldr_rsp_ready(loader_rsp_ready),
    .ldr_rsp_rdata(loader_rsp_rdata), .ldr_rsp_err(loader_rsp_err),
    .dma_cmd_valid(accel_cmd_valid), .dma_cmd_ready(accel_cmd_ready),
    .dma_cmd_addr(accel_cmd_addr), .dma_cmd_read(accel_cmd_read),
    .dma_cmd_wdata(accel_cmd_wdata), .dma_cmd_wmask(accel_cmd_wmask),
    .dma_rsp_valid(accel_rsp_valid), .dma_rsp_ready(accel_rsp_ready),
    .dma_rsp_rdata(accel_rsp_rdata), .dma_rsp_err(accel_rsp_err),
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
    .loader_wptr(loader_wptr),
    .loader_base(loader_base),
    .loader_wptr_valid(loader_wptr_valid),
    .wptr_rd_valid(wptr_rd_valid),
    .wptr_rd_ready(wptr_rd_ready),
    .wptr_rd_rdata(wptr_rd_rdata)
  );

endmodule
