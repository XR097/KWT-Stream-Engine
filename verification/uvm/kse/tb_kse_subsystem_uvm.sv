`timescale 1ns/1ps
module tb_kse_subsystem_uvm;
  import uvm_pkg::*;
  import kse_network_pkg::*;
  logic clk=0;
  always #5 clk=~clk;
  kse_integration_if link(clk);
  assign link.rst_n=link.reset_drive;
  assign link.mode=2;
  assign link.priority_mode=1;
  for(genvar p=0;p<5;p++)assign link.active[p]=(p<4);
  kse_accel_sys dut(
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
    .mmio_cmd_valid(link.cv[3]),
    .mmio_cmd_ready(link.cr[3]),
    .mmio_cmd_addr(link.addr[3]),
    .mmio_cmd_read(link.rd[3]),
    .mmio_cmd_wdata(link.wd[3]),
    .mmio_cmd_wmask(link.mask[3]),
    .mmio_rsp_valid(link.rv[3]),
    .mmio_rsp_ready(link.rr[3]),
    .mmio_rsp_rdata(link.data[3]),
    .mmio_rsp_err(link.err[3]),.irq());
  assign link.cv[2]=dut.d_cmd_valid;
  assign link.cr[2]=dut.d_cmd_ready;
  assign link.addr[2]=dut.d_cmd_addr;
  assign link.rd[2]=dut.d_cmd_read;
  assign link.wd[2]=dut.d_cmd_wdata;
  assign link.mask[2]=dut.d_cmd_wmask;
  assign link.rv[2]=dut.d_rsp_valid;
  assign link.rr[2]=dut.d_rsp_ready;
  assign link.data[2]=dut.d_rsp_rdata;
  assign link.err[2]=dut.d_rsp_err;
  assign link.loader_done=dut.ldr_done;
  assign link.scv=dut.s_cmd_valid;
  assign link.scr=dut.s_cmd_ready;
  assign link.srv=dut.s_rsp_valid;
  assign link.srr=dut.s_rsp_ready;
  assign link.saddr=dut.s_cmd_addr;
  assign link.sread=dut.s_cmd_read;
  assign link.swd=dut.s_cmd_wdata;
  assign link.smask=dut.s_cmd_wmask;
  assign link.wptr=dut.wptr;
  assign link.base=dut.base;
  assign link.wp_valid=dut.wptr_valid;
  assign link.irq=dut.irq;
  assign link.kcv=dut.u_eng.k_cmd_valid;
  assign link.kcr=dut.u_eng.k_cmd_ready;
  assign link.kin=dut.u_eng.k_in_en;
  assign link.kout=dut.u_eng.k_out_en;
  assign link.layer=dut.u_eng.k_layer;
  assign link.kdone=dut.u_eng.k_done;
  assign link.kbusy=dut.u_eng.k_busy;
  assign link.layer_event=dut.u_eng.layer_evt;
  assign link.cq_count=dut.u_eng.cq_cnt;
  assign link.sq_count=dut.u_eng.sq_cnt;
  assign link.pb_count=dut.u_eng.pb_cnt;
  assign link.ib_count=dut.u_eng.ib_cnt;
  assign link.ob_count=dut.u_eng.ob_cnt;
  assign link.p_resv=dut.u_eng.p_resv;
  assign link.i_resv=dut.u_eng.i_resv;
  assign link.o_pending=dut.u_eng.o_pend;
  assign link.done_wait=dut.u_eng.done_wait;
  assign link.ext_irq=0;
  initial begin
    string path;
    if($value$plusargs("fsdbfile=%s",path))begin $fsdbDumpfile(path);$fsdbDumpvars(0,tb_kse_subsystem_uvm);end
    uvm_config_db#(virtual kse_integration_if)::set(null,"uvm_test_top*","vif",link);
    run_test();
  end
endmodule
