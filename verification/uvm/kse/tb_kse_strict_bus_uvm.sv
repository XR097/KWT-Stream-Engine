`timescale 1ns/1ps
module tb_kse_strict_bus_uvm;
  import uvm_pkg::*;
  import strict_bus_pkg::*;
  logic clk=0;
  always #5 clk=~clk;
  strict_bus_if b(clk);
  kse_sys_bus bus_dut (
    .clk(clk), .rst_n(b.rst_n),
    .cpu_cmd_valid(b.cv[0]), .cpu_cmd_ready(b.cr[0]), .cpu_cmd_addr(b.addr[0]),
    .cpu_cmd_read(b.rd[0]), .cpu_cmd_wdata(b.wd[0]), .cpu_cmd_wmask(b.mask[0]),
    .cpu_rsp_valid(b.rv[0]), .cpu_rsp_ready(b.rr[0]), .cpu_rsp_rdata(b.data[0]), .cpu_rsp_err(b.err[0]),
    .ldr_cmd_valid(b.cv[1]), .ldr_cmd_ready(b.cr[1]), .ldr_cmd_addr(b.addr[1]),
    .ldr_cmd_read(b.rd[1]), .ldr_cmd_wdata(b.wd[1]), .ldr_cmd_wmask(b.mask[1]),
    .ldr_rsp_valid(b.rv[1]), .ldr_rsp_ready(b.rr[1]), .ldr_rsp_rdata(b.data[1]), .ldr_rsp_err(b.err[1]),
    .dma_cmd_valid(b.cv[2]), .dma_cmd_ready(b.cr[2]), .dma_cmd_addr(b.addr[2]),
    .dma_cmd_read(b.rd[2]), .dma_cmd_wdata(b.wd[2]), .dma_cmd_wmask(b.mask[2]),
    .dma_rsp_valid(b.rv[2]), .dma_rsp_ready(b.rr[2]), .dma_rsp_rdata(b.data[2]), .dma_rsp_err(b.err[2]),
    .sram_cmd_valid(b.scv), .sram_cmd_ready(b.scr), .sram_cmd_addr(b.sa),
    .sram_cmd_read(b.srd), .sram_cmd_wdata(b.swd), .sram_cmd_wmask(b.sm),
    .sram_rsp_valid(b.srv), .sram_rsp_ready(b.srr), .sram_rsp_rdata(b.sd), .sram_rsp_err(b.serr));
  kse_shared_sram mem_dut (
    .clk(clk), .rst_n(b.rst_n), .cmd_valid(b.scv), .cmd_ready(b.scr), .cmd_addr(b.sa),
    .cmd_read(b.srd), .cmd_wdata(b.swd), .cmd_wmask(b.sm),
    .rsp_valid(b.srv), .rsp_ready(b.srr), .rsp_rdata(b.sd), .rsp_err(b.serr),
    .loader_base(b.base), .loader_wptr(b.wptr), .loader_wptr_valid(b.valid), .loader_done(b.done),
    .wptr_rd_valid(b.wp_read), .wptr_rd_ready(b.wp_ready), .wptr_rd_rdata(b.wp_data));
  assign b.groups=mem_dut.u_bank.grp_sel;
  initial begin
    string path;
    if ($value$plusargs("vcd=%s",path)) begin $dumpfile(path); $dumpvars(0,tb_kse_strict_bus_uvm); end
    uvm_config_db#(virtual strict_bus_if)::set(null,"uvm_test_top","vif",b);
    run_test("strict_bus_test");
  end
  initial begin #20000000; $fatal(1,"STRICT_BUS_WATCHDOG"); end
endmodule
