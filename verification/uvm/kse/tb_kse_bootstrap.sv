`timescale 1ns/1ps
module tb_kse_bootstrap;
  import uvm_pkg::*;
  import kse_bootstrap_pkg::*;
  logic clk=0, rst_n=0, irq;
  always #5 clk=~clk;
  kse_icb_if mmio(clk,rst_n), cpu(clk,rst_n), loader(clk,rst_n);
  kse_accel_sys dut(
    .clk(clk),.rst_n(rst_n),
    .cpu_cmd_valid(cpu.cmd_valid),.cpu_cmd_ready(cpu.cmd_ready),.cpu_cmd_read(cpu.cmd_read),
    .cpu_cmd_addr(cpu.cmd_addr),.cpu_cmd_wdata(cpu.cmd_wdata),.cpu_cmd_wmask(cpu.cmd_wmask),
    .cpu_rsp_valid(cpu.rsp_valid),.cpu_rsp_ready(cpu.rsp_ready),.cpu_rsp_rdata(cpu.rsp_rdata),.cpu_rsp_err(cpu.rsp_err),
    .mmio_cmd_valid(mmio.cmd_valid),.mmio_cmd_ready(mmio.cmd_ready),.mmio_cmd_read(mmio.cmd_read),
    .mmio_cmd_addr(mmio.cmd_addr),.mmio_cmd_wdata(mmio.cmd_wdata),.mmio_cmd_wmask(mmio.cmd_wmask),
    .mmio_rsp_valid(mmio.rsp_valid),.mmio_rsp_ready(mmio.rsp_ready),.mmio_rsp_rdata(mmio.rsp_rdata),.mmio_rsp_err(mmio.rsp_err),
    .ldr_cmd_valid(loader.cmd_valid),.ldr_cmd_ready(loader.cmd_ready),.ldr_cmd_read(loader.cmd_read),
    .ldr_cmd_addr(loader.cmd_addr),.ldr_cmd_wdata(loader.cmd_wdata),.ldr_cmd_wmask(loader.cmd_wmask),
    .ldr_rsp_valid(loader.rsp_valid),.ldr_rsp_ready(loader.rsp_ready),.ldr_rsp_rdata(loader.rsp_rdata),.ldr_rsp_err(loader.rsp_err),
    .irq(irq));
  a_idle_irq: assert property (@(posedge clk) disable iff(!rst_n) irq===1'b0)
    else $error("unexpected IRQ during idle bootstrap");
  initial begin repeat(5) @(negedge clk); rst_n=1; end
  initial begin
    string fsdb;
    if($value$plusargs("fsdbfile=%s",fsdb)) begin
      $fsdbDumpfile(fsdb); $fsdbDumpvars(0,tb_kse_bootstrap);
    end
    uvm_config_db#(virtual kse_icb_if)::set(null,"uvm_test_top.agent0.*","vif",mmio);
    uvm_config_db#(virtual kse_icb_if)::set(null,"uvm_test_top.agent1.*","vif",cpu);
    uvm_config_db#(virtual kse_icb_if)::set(null,"uvm_test_top.agent2.*","vif",loader);
    uvm_config_db#(virtual kse_icb_if)::set(null,"uvm_test_top","mmio",mmio);
    run_test();
  end
endmodule
