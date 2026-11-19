`timescale 1ns/1ps
interface kse_fault_if(input logic clk);
  logic rst_n=0;
  logic m_cv=0,m_cr,m_read=0,m_rv,m_rr=0,m_err;
  logic [31:0] m_addr=0,m_wdata=0,m_rdata;
  logic [3:0] m_mask=15;
  logic d_cv,d_cr,d_read,d_rv,d_rr,d_err;
  logic [31:0] d_addr,d_wdata,d_rdata,d_wdata_gold;
  logic [3:0] d_mask;
  // Loader and the physical bus are actual ICB paths, never progress drivers.
  logic l_cv=0,l_cr,l_read=0,l_rv,l_rr=0,l_err;
  logic [31:0] l_addr=0,l_wdata=0,l_rdata;
  logic b_cv,b_cr,b_rv,b_err;
  logic [31:0] b_rdata;
  bit allow_command=0,strict_publish=0;
  logic s_cv,s_cr,s_read,s_rv,s_rr,s_err;
  logic [31:0] s_addr,s_wdata,s_rdata;
  logic [3:0] s_mask;
  logic [31:0] wptr,base;
  logic watermark_valid,loader_done,irq;
  logic kcv,kcr,kin,kout,kdone,kbusy,layer_event;
  logic [3:0] layer,phase;
  logic [1:0] cq_count;
  logic [2:0] sq_count,pb_count,ib_count,ob_count,p_resv,i_resv,o_pending;
  bit cmd_gate=1,hold_responses=0,release_error=0,hold_last=0,release_last=0,noise_error=0;
  int fault_kind=0,scenario=0;
  bit check_outputs=0;
  a_mmio_cmd_hold: assert property(@(posedge clk) disable iff(!rst_n)
    m_cv && !m_cr |=> m_cv && $stable({m_read,m_addr,m_wdata,m_mask}))
    else $error("fault harness MMIO command changed while stalled");
  a_mmio_rsp_hold: assert property(@(posedge clk) disable iff(!rst_n)
    m_rv && !m_rr |=> m_rv && $stable({m_rdata,m_err}))
    else $error("fault harness MMIO response changed while stalled");
  a_dma_cmd_hold: assert property(@(posedge clk) disable iff(!rst_n)
    d_cv && !d_cr |=> d_cv && $stable({d_read,d_addr,d_wdata,d_mask}))
    else $error("fault harness DMA request changed while stalled");
  a_dma_rsp_ready: assert property(@(posedge clk) disable iff(!rst_n) d_rr===1'b1)
    else $error("fault harness DMA response not always ready");
  a_bridge_cmd_hold: assert property(@(posedge clk) disable iff(!rst_n)
    b_cv && !b_cr |=> b_cv && $stable({d_read,d_addr,d_wdata,d_mask}))
    else $error("fault bridge bus command changed while stalled");
  a_loader_hold: assert property(@(posedge clk) disable iff(!rst_n)
    l_cv && !l_cr |=> l_cv && $stable({l_read,l_addr,l_wdata}))
    else $error("fault loader command changed while stalled");
  a_loader_rsp_hold: assert property(@(posedge clk) disable iff(!rst_n)
    l_rv && !l_rr |=> l_rv && $stable({l_rdata,l_err}))
    else $error("fault loader response changed while stalled");
  c_mmio_cmd_stall: cover property(@(posedge clk) disable iff(!rst_n) m_cv && !m_cr ##1 m_cv && m_cr);
  c_mmio_rsp_stall: cover property(@(posedge clk) disable iff(!rst_n) m_rv && !m_rr ##1 m_rv && m_rr);
  c_dma_cmd_stall: cover property(@(posedge clk) disable iff(!rst_n) d_cv && !d_cr ##1 d_cv && d_cr);
endinterface
