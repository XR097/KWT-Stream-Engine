`timescale 1ns/1ps
interface kse_integration_if(input logic clk);
  // 0 CPU SRAM, 1 loader SRAM, 2 DMA SRAM, 3 MMIO, 4 PLIC.
  logic rst_n, reset_drive=0;
  logic [4:0] cv, cr, rd, rv, rr, err;
  logic [31:0] addr[5], wd[5], data[5];
  logic [3:0] mask[5];
  logic init_v=0, auto_publish=0, manual_we=0;
  wire loader_done;
  logic scv,scr,srv,srr,sread;
  logic [31:0] saddr,swd,srdata;
  logic serr;
  logic [3:0] smask;
  int image_words=80592;
  bit contract_unit=0;
  logic [31:0] init_base=0, manual_wp=0;
  logic [31:0] wptr, base;
  logic wp_valid, wp_we;
  logic [31:0] wp_next;
  logic wp_read=0, wp_ready;
  logic [31:0] wp_data;
  int mode, priority_mode, phase_id=0;
  bit contract_reads=0, network=0;
  logic irq, ext_irq;
  logic kcv, kcr, kin, kout, kdone, kbusy, layer_event;
  logic [3:0] layer;
  logic [1:0] cq_count;
  logic [2:0] sq_count, pb_count, ib_count, ob_count;
  logic [2:0] p_resv, i_resv, o_pending;
  logic done_wait;
  logic fw_load=0, fw_ack=0;
  logic [63:0] fw[8192];
  logic [15:0] output_halves[1][32][2][4096];
  logic output_capture=0, output_ack=0;
  bit active[5];
  // Verification-only external response injection.  The DUT response pins
  // are muxed with these controls in tb_kse_shared_uvm; production RTL is
  // never modified or forced.
  bit late_response_active=0;
  int late_response_port=0;
  logic [31:0] late_response_data=32'h0;
  logic late_response_error=0;
  assign wp_we = auto_publish ? (cv[1] && cr[1] && !rd[1]) : manual_we;
  assign wp_next = auto_publish ? addr[1]+32'd4 : manual_wp;
  for(genvar p=0;p<5;p++) begin: g_protocol
    logic pending_read;
    always @(posedge clk or negedge rst_n)
      if(!rst_n) pending_read<=0;
      else if(cv[p] && cr[p]) pending_read<=rd[p];
    a_cmd_hold: assert property(@(posedge clk) disable iff(!rst_n || !active[p])
      cv[p] && !cr[p] |=> cv[p] && $stable({addr[p],rd[p],wd[p],mask[p]}))
      else $error("integration command changed under backpressure port=%0d",p);
    a_rsp_hold: assert property(@(posedge clk) disable iff(!rst_n || !active[p])
      rv[p] && !rr[p] |=> rv[p] && $stable(err[p]) && (!pending_read || $stable(data[p])))
      else $error("integration response changed under backpressure port=%0d",p);
    c_cmd_stall: cover property(@(posedge clk) disable iff(!rst_n || !active[p]) cv[p] && !cr[p] ##1 cv[p] && cr[p]);
    c_rsp_stall: cover property(@(posedge clk) disable iff(!rst_n || !active[p]) rv[p] && !rr[p] ##1 rv[p] && rr[p]);
  end
endinterface
