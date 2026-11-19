`timescale 1ns/1ps
module tb_kse_shared_uvm;
  import uvm_pkg::*;
  import kse_contract_pkg::*;
  logic clk=0;
  always #5 clk=~clk;
  kse_integration_if link(clk);
  assign link.rst_n=link.reset_drive;
  assign link.mode=0;
  assign link.priority_mode=1;
  for(genvar p=0;p<5;p++)assign link.active[p]=(p<3);
  kse_sys_bus dut(
    .clk(clk),.rst_n(link.rst_n),
    .cpu_cmd_valid(link.cv[0]),
    .cpu_cmd_ready(link.cr[0]),
    .cpu_cmd_addr(link.addr[0]),
    .cpu_cmd_read(link.rd[0]),
    .cpu_cmd_wdata(link.wd[0]),
    .cpu_cmd_wmask(link.mask[0]),
    .cpu_rsp_valid(link.rv[0]),
    .cpu_rsp_ready(link.rr[0]),
    .cpu_rsp_rdata(link.data[0]),
    .cpu_rsp_err(link.err[0]),
    .ldr_cmd_valid(link.cv[1]),
    .ldr_cmd_ready(link.cr[1]),
    .ldr_cmd_addr(link.addr[1]),
    .ldr_cmd_read(link.rd[1]),
    .ldr_cmd_wdata(link.wd[1]),
    .ldr_cmd_wmask(link.mask[1]),
    .ldr_rsp_valid(link.rv[1]),
    .ldr_rsp_ready(link.rr[1]),
    .ldr_rsp_rdata(link.data[1]),
    .ldr_rsp_err(link.err[1]),
    .dma_cmd_valid(link.cv[2]),
    .dma_cmd_ready(link.cr[2]),
    .dma_cmd_addr(link.addr[2]),
    .dma_cmd_read(link.rd[2]),
    .dma_cmd_wdata(link.wd[2]),
    .dma_cmd_wmask(link.mask[2]),
    .dma_rsp_valid(link.rv[2]),
    .dma_rsp_ready(link.rr[2]),
    .dma_rsp_rdata(link.data[2]),
    .dma_rsp_err(link.err[2]),
    .sram_cmd_valid(link.scv),
    .sram_cmd_ready(link.scr),
    .sram_cmd_addr(link.saddr),
    .sram_cmd_read(link.sread),
    .sram_cmd_wdata(link.swd),
    .sram_cmd_wmask(link.smask),
    .sram_rsp_valid(link.srv),
    .sram_rsp_ready(link.srr),
    .sram_rsp_rdata(link.srdata),
    .sram_rsp_err(link.serr));
  kse_shared_sram memory(
    .clk(clk),.rst_n(link.rst_n),
    .cmd_valid(link.scv),
    .cmd_ready(link.scr),
    .cmd_addr(link.saddr),
    .cmd_read(link.sread),
    .cmd_wdata(link.swd),
    .cmd_wmask(link.smask),
    .rsp_valid(link.srv),
    .rsp_ready(link.srr),
    .rsp_rdata(link.srdata),
    .rsp_err(link.serr),
    .loader_wptr(link.wptr),.loader_base(link.base),.loader_wptr_valid(link.wp_valid),.loader_done(link.loader_done),
    .wptr_rd_valid(1'b0),.wptr_rd_ready(),.wptr_rd_rdata());
  initial begin
    string path;
    if($value$plusargs("fsdbfile=%s",path))begin $fsdbDumpfile(path);$fsdbDumpvars(0,tb_kse_shared_uvm);end
    uvm_config_db#(virtual kse_integration_if)::set(null,"uvm_test_top*","vif",link);
    run_test();
  end
endmodule
