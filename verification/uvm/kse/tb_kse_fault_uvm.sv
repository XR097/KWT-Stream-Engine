`timescale 1ns/1ps
module tb_kse_fault_uvm;
  import uvm_pkg::*;
  import kse_fault_pkg::*;
  logic clk=0;
  always #5 clk=~clk;
  kse_fault_if link(clk);
  logic irq_raw,release_used,golden_used,progress_used,irq_used=0,queue_used=0,drain_used,fabric_used,sram_used,sram_read_seen;
  logic [31:0] base_raw,wptr_raw;
  logic valid_raw,done_raw;
  logic [1:0] cq_raw;
  logic layer_event_raw;
  logic [31:0] dma_addr_raw,dma_wdata_raw,dma_rdata_raw;
  logic dma_cv_raw,dma_cr_raw,dma_read_raw,dma_rv_raw,dma_rr_raw,dma_err_raw;
  logic [3:0] dma_mask_raw;
  logic [31:0] sram_rdata_raw,sram_addr_raw,sram_wdata_raw;
  logic sram_cv_raw,sram_cr_raw,sram_read_raw,sram_rv_raw,sram_rr_raw,sram_err_raw;
  logic [3:0] sram_mask_raw;
  bit neg_progress,neg_fabric,neg_sram,neg_irq,neg_queue,neg_drain,neg_release,neg_golden;
  initial begin
    neg_progress=$test$plusargs("NEGATIVE=FAULT_PROGRESS"); neg_fabric=$test$plusargs("NEGATIVE=FAULT_FABRIC");
    neg_sram=$test$plusargs("NEGATIVE=FAULT_SRAM_DATA"); neg_irq=$test$plusargs("NEGATIVE=FAULT_IRQ");
    neg_queue=$test$plusargs("NEGATIVE=FAULT_QUEUE"); neg_drain=$test$plusargs("NEGATIVE=FAULT_DRAIN");
    neg_release=$test$plusargs("NEGATIVE=FAULT_RELEASE"); neg_golden=$test$plusargs("NEGATIVE=RECOVERY_GOLDEN");
  end
  always @(posedge clk or negedge link.rst_n) begin
    if(!link.rst_n) begin release_used<=0;golden_used<=0;progress_used<=0;drain_used<=0;fabric_used<=0;sram_used<=0;sram_read_seen<=0;end
    else begin
      if(neg_release && dma_cv_raw && dma_cr_raw && dma_read_raw) release_used<=1;
      if(neg_golden && dma_cv_raw && dma_cr_raw && !dma_read_raw) golden_used<=1;
      if(neg_progress) progress_used<=1;
      if(neg_irq) irq_used<=1;
      if(neg_queue && link.rst_n && !queue_used) queue_used<=1;
      if(neg_drain && dut.layer_evt) drain_used<=1;
      if(neg_fabric && sram_cv_raw && sram_cr_raw) fabric_used<=1;
      if(neg_sram && sram_cv_raw && sram_cr_raw && sram_read_raw) sram_read_seen<=1;
      if(neg_sram && sram_rv_raw && sram_rr_raw && sram_read_seen) sram_used<=1;
    end
  end
  // Same production engine/bus/SRAM as kse_accel_sys. The sole test shim
  // buffers real DMA bus responses and injects errors/latency at that boundary.
  // CPU is idle; fixed-priority DMA > loader > CPU remains the real bus.
  assign link.b_cv=link.d_cv && link.allow_command;
  kse_sys_bus bus_dut(
    .clk(clk),.rst_n(link.rst_n),
    .cpu_cmd_valid(1'b0),.cpu_cmd_ready(),.cpu_cmd_addr(32'b0),.cpu_cmd_read(1'b1),
    .cpu_cmd_wdata(32'b0),.cpu_cmd_wmask(4'hf),.cpu_rsp_valid(),.cpu_rsp_ready(1'b1),.cpu_rsp_rdata(),.cpu_rsp_err(),
    .ldr_cmd_valid(link.l_cv),.ldr_cmd_ready(link.l_cr),.ldr_cmd_addr(link.l_addr),.ldr_cmd_read(link.l_read),
    .ldr_cmd_wdata(link.l_wdata),.ldr_cmd_wmask(4'hf),.ldr_rsp_valid(link.l_rv),.ldr_rsp_ready(link.l_rr),.ldr_rsp_rdata(link.l_rdata),.ldr_rsp_err(link.l_err),
    .dma_cmd_valid(link.b_cv),.dma_cmd_ready(link.b_cr),.dma_cmd_addr(link.d_addr),.dma_cmd_read(link.d_read),
    .dma_cmd_wdata(link.d_wdata),.dma_cmd_wmask(link.d_mask),.dma_rsp_valid(link.b_rv),.dma_rsp_ready(1'b1),.dma_rsp_rdata(link.b_rdata),.dma_rsp_err(link.b_err),
    .sram_cmd_valid(sram_cv_raw),.sram_cmd_ready(sram_cr_raw),.sram_cmd_addr(sram_addr_raw),.sram_cmd_read(sram_read_raw),
    .sram_cmd_wdata(sram_wdata_raw),.sram_cmd_wmask(sram_mask_raw),.sram_rsp_valid(sram_rv_raw),.sram_rsp_ready(sram_rr_raw),.sram_rsp_rdata(link.s_rdata),.sram_rsp_err(sram_err_raw));
  kse_shared_sram shared_dut(
    .clk(clk),.rst_n(link.rst_n),.cmd_valid(link.s_cv),.cmd_ready(sram_cr_raw),.cmd_addr(link.s_addr),.cmd_read(link.s_read),
    .cmd_wdata(link.s_wdata),.cmd_wmask(link.s_mask),.rsp_valid(sram_rv_raw),.rsp_ready(link.s_rr),.rsp_rdata(sram_rdata_raw),.rsp_err(sram_err_raw),
    .loader_wptr(wptr_raw),.loader_base(base_raw),.loader_wptr_valid(valid_raw),.loader_done(done_raw),
    .wptr_rd_valid(1'b0),.wptr_rd_ready(),.wptr_rd_rdata());
  kse_eng_icb #(.REL_LAG(0)) dut(
    .clk(clk),.rst_n(link.rst_n),
    .mmio_cmd_valid(link.m_cv),.mmio_cmd_ready(link.m_cr),.mmio_cmd_addr(link.m_addr),
    .mmio_cmd_read(link.m_read),.mmio_cmd_wdata(link.m_wdata),.mmio_cmd_wmask(link.m_mask),
    .mmio_rsp_valid(link.m_rv),.mmio_rsp_ready(link.m_rr),.mmio_rsp_rdata(link.m_rdata),.mmio_rsp_err(link.m_err),
    .dma_cmd_valid(dma_cv_raw),.dma_cmd_ready(dma_cr_raw),.dma_cmd_addr(dma_addr_raw),
    .dma_cmd_read(dma_read_raw),.dma_cmd_wdata(dma_wdata_raw),.dma_cmd_wmask(dma_mask_raw),
    .dma_rsp_valid(dma_rv_raw),.dma_rsp_ready(dma_rr_raw),.dma_rsp_rdata(dma_rdata_raw),.dma_rsp_err(dma_err_raw),
    .ldr_wptr(link.wptr),.ldr_base(link.base),.ldr_wptr_valid(link.watermark_valid),.ldr_done(link.loader_done),.irq(irq_raw));
  assign link.d_cv=dma_cv_raw;
  assign dma_cr_raw=link.b_cr && link.allow_command;
  assign link.d_cr=dma_cr_raw;
  assign link.d_addr=dma_addr_raw;
  assign link.d_read=dma_read_raw; assign link.d_wdata=dma_wdata_raw; assign link.d_wdata_gold=(neg_golden && !dma_read_raw && !golden_used) ? (dma_wdata_raw ^ 32'd1) : dma_wdata_raw;
  assign link.d_mask=dma_mask_raw; assign dma_rv_raw=link.d_rv; assign link.d_rr=dma_rr_raw; assign dma_rdata_raw=link.d_rdata; assign dma_err_raw=link.d_err;
  assign link.wptr=(neg_release && link.rst_n && dma_cv_raw && dma_cr_raw && dma_read_raw && !release_used) ?
                   ((wptr_raw>=4) ? (wptr_raw-4) : 0) :
                   ((neg_progress && !progress_used) ? (wptr_raw ^ 32'd4) : wptr_raw);
  assign link.base=base_raw; assign link.watermark_valid=valid_raw; assign link.loader_done=done_raw;
  assign link.irq=(neg_irq && link.rst_n && !irq_used) ? (irq_raw ^ 1'b1) : irq_raw;
  assign link.cq_count=(neg_queue && link.rst_n && !queue_used) ? (dut.cq_cnt ^ 2'b1) : dut.cq_cnt;
  assign link.layer_event=(neg_drain && !drain_used && dut.layer_evt) ? (dut.layer_evt ^ 1'b1) : dut.layer_evt;
  assign link.s_cv=sram_cv_raw; assign link.s_cr=sram_cr_raw;
  assign link.s_addr=(neg_fabric && !fabric_used) ? (sram_addr_raw ^ 32'd4) : sram_addr_raw;
  assign link.s_read=sram_read_raw; assign link.s_wdata=sram_wdata_raw; assign link.s_mask=sram_mask_raw;
  assign link.s_rv=sram_rv_raw; assign link.s_rr=sram_rr_raw; assign link.s_rdata=(neg_sram && sram_read_seen && !sram_used) ? (sram_rdata_raw ^ 32'd1) : sram_rdata_raw; assign link.s_err=sram_err_raw;
  assign link.kcv=dut.k_cmd_valid;
  assign link.kcr=dut.k_cmd_ready;
  assign link.kin=dut.k_in_en;
  assign link.kout=dut.k_out_en;
  assign link.layer=dut.k_layer;
  assign link.kdone=dut.k_done;
  assign link.kbusy=dut.k_busy;
  assign link.phase=dut.u_kse.phase;
  assign link.sq_count=dut.sq_cnt;
  assign link.pb_count=dut.pb_cnt;
  assign link.ib_count=dut.ib_cnt;
  assign link.ob_count=dut.ob_cnt;
  assign link.p_resv=dut.p_resv;
  assign link.i_resv=dut.i_resv;
  assign link.o_pending=dut.o_pend;
  initial begin
    string path;
    if($value$plusargs("fsdbfile=%s",path))begin $fsdbDumpfile(path);$fsdbDumpvars(0,tb_kse_fault_uvm);end
    uvm_config_db#(virtual kse_fault_if)::set(null,"uvm_test_top*","vif",link);
    run_test();
  end
endmodule
