`timescale 1ns/1ps
module tb_kse_soc_uvm;
  import uvm_pkg::*;
  import kse_network_pkg::*;
  logic clk=0,lfclk=0;
  wire kclk,krst_n;
  always #5 clk=~clk;
  always #82.5 lfclk=~lfclk;
  kse_integration_if link(kclk);
  assign link.rst_n=krst_n;
  assign link.mode=3;
  assign link.priority_mode=1;
  for(genvar p=0;p<5;p++)assign link.active[p]=1;
  kse_e203_soc_top u_soc (
    .hfextclk(clk), .hfxoscen(), .lfextclk(lfclk), .lfxoscen(),
    .io_pads_jtag_TCK_i_ival(1'b0), .io_pads_jtag_TMS_i_ival(1'b0), .io_pads_jtag_TDI_i_ival(1'b0),
    .io_pads_jtag_TDO_o_oval(), .io_pads_jtag_TDO_o_oe(),
    .io_pads_gpioA_i_ival(32'b0), .io_pads_gpioA_o_oval(), .io_pads_gpioA_o_oe(),
    .io_pads_gpioB_i_ival(32'b0), .io_pads_gpioB_o_oval(), .io_pads_gpioB_o_oe(),
    .io_pads_qspi0_sck_o_oval(), .io_pads_qspi0_cs_0_o_oval(),
    .io_pads_qspi0_dq_0_i_ival(1'b1), .io_pads_qspi0_dq_0_o_oval(), .io_pads_qspi0_dq_0_o_oe(),
    .io_pads_qspi0_dq_1_i_ival(1'b1), .io_pads_qspi0_dq_1_o_oval(), .io_pads_qspi0_dq_1_o_oe(),
    .io_pads_qspi0_dq_2_i_ival(1'b1), .io_pads_qspi0_dq_2_o_oval(), .io_pads_qspi0_dq_2_o_oe(),
    .io_pads_qspi0_dq_3_i_ival(1'b1), .io_pads_qspi0_dq_3_o_oval(), .io_pads_qspi0_dq_3_o_oe(),
    .io_pads_aon_erst_n_i_ival(link.reset_drive), .io_pads_aon_pmu_dwakeup_n_i_ival(1'b1),
    .io_pads_aon_pmu_vddpaden_o_oval(), .io_pads_aon_pmu_padrst_o_oval(),
    .io_pads_bootrom_n_i_ival(1'b0), .io_pads_dbgmode0_n_i_ival(1'b1),
    .io_pads_dbgmode1_n_i_ival(1'b1), .io_pads_dbgmode2_n_i_ival(1'b1),
    .kse_ldr_cmd_valid(link.cv[1]), .kse_ldr_cmd_ready(link.cr[1]), .kse_ldr_cmd_addr(link.addr[1]),
    .kse_ldr_cmd_read(link.rd[1]), .kse_ldr_cmd_wdata(link.wd[1]), .kse_ldr_cmd_wmask(link.mask[1]),
    .kse_ldr_rsp_valid(link.rv[1]), .kse_ldr_rsp_ready(link.rr[1]), .kse_ldr_rsp_rdata(link.data[1]),
    .kse_ldr_rsp_err(link.err[1]),
    .kse_clk(kclk), .kse_rst_n(krst_n));

  assign link.cv[2]=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.d_cmd_valid;
  assign link.cr[2]=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.d_cmd_ready;
  assign link.addr[2]=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.d_cmd_addr;
  assign link.rd[2]=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.d_cmd_read;
  assign link.wd[2]=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.d_cmd_wdata;
  assign link.mask[2]=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.d_cmd_wmask;
  assign link.rv[2]=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.d_rsp_valid;
  assign link.rr[2]=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.d_rsp_ready;
  assign link.data[2]=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.d_rsp_rdata;
  assign link.err[2]=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.d_rsp_err;
  assign link.loader_done=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.ldr_done;
  assign link.scv=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.s_cmd_valid;
  assign link.scr=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.s_cmd_ready;
  assign link.srv=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.s_rsp_valid;
  assign link.srr=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.s_rsp_ready;
  assign link.saddr=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.s_cmd_addr;
  assign link.sread=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.s_cmd_read;
  assign link.swd=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.s_cmd_wdata;
  assign link.smask=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.s_cmd_wmask;
  assign link.wptr=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.wptr;
  assign link.base=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.base;
  assign link.wp_valid=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.wptr_valid;
  assign link.irq=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.irq;
  assign link.kcv=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.k_cmd_valid;
  assign link.kcr=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.k_cmd_ready;
  assign link.kin=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.k_in_en;
  assign link.kout=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.k_out_en;
  assign link.layer=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.k_layer;
  assign link.kdone=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.k_done;
  assign link.kbusy=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.k_busy;
  assign link.layer_event=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.layer_evt;
  assign link.cq_count=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.cq_cnt;
  assign link.sq_count=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.sq_cnt;
  assign link.pb_count=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.pb_cnt;
  assign link.ib_count=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.ib_cnt;
  assign link.ob_count=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.ob_cnt;
  assign link.p_resv=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.p_resv;
  assign link.i_resv=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.i_resv;
  assign link.o_pending=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.o_pend;
  assign link.done_wait=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_eng.done_wait;
  assign link.cv[0]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_shram_icb_cmd_valid;
  assign link.cr[0]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_shram_icb_cmd_ready;
  assign link.addr[0]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_shram_icb_cmd_addr;
  assign link.rd[0]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_shram_icb_cmd_read;
  assign link.wd[0]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_shram_icb_cmd_wdata;
  assign link.mask[0]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_shram_icb_cmd_wmask;
  assign link.rv[0]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_shram_icb_rsp_valid;
  assign link.rr[0]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_shram_icb_rsp_ready;
  assign link.data[0]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_shram_icb_rsp_rdata;
  assign link.err[0]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_shram_icb_rsp_err;
  assign link.cv[3]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_mmio_icb_cmd_valid;
  assign link.cr[3]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_mmio_icb_cmd_ready;
  assign link.addr[3]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_mmio_icb_cmd_addr;
  assign link.rd[3]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_mmio_icb_cmd_read;
  assign link.wd[3]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_mmio_icb_cmd_wdata;
  assign link.mask[3]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_mmio_icb_cmd_wmask;
  assign link.rv[3]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_mmio_icb_rsp_valid;
  assign link.rr[3]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_mmio_icb_rsp_ready;
  assign link.data[3]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_mmio_icb_rsp_rdata;
  assign link.err[3]=u_soc.u_e203_subsys_top.u_e203_subsys_main.kse_mmio_icb_rsp_err;
  assign link.cv[4]=u_soc.u_e203_subsys_top.u_e203_subsys_main.plic_icb_cmd_valid;
  assign link.cr[4]=u_soc.u_e203_subsys_top.u_e203_subsys_main.plic_icb_cmd_ready;
  assign link.addr[4]=u_soc.u_e203_subsys_top.u_e203_subsys_main.plic_icb_cmd_addr;
  assign link.rd[4]=u_soc.u_e203_subsys_top.u_e203_subsys_main.plic_icb_cmd_read;
  assign link.wd[4]=u_soc.u_e203_subsys_top.u_e203_subsys_main.plic_icb_cmd_wdata;
  assign link.mask[4]=u_soc.u_e203_subsys_top.u_e203_subsys_main.plic_icb_cmd_wmask;
  assign link.rv[4]=u_soc.u_e203_subsys_top.u_e203_subsys_main.plic_icb_rsp_valid;
  assign link.rr[4]=u_soc.u_e203_subsys_top.u_e203_subsys_main.plic_icb_rsp_ready;
  assign link.data[4]=u_soc.u_e203_subsys_top.u_e203_subsys_main.plic_icb_rsp_rdata;
  assign link.err[4]=u_soc.u_e203_subsys_top.u_e203_subsys_main.plic_icb_rsp_err;
  assign link.ext_irq=u_soc.u_e203_subsys_top.u_e203_subsys_main.plic_ext_irq;
  for(genvar r=0;r<2;r++)begin:g_itrow
    for(genvar c=0;c<4;c++)begin:g_itcol
      always @(posedge link.fw_load)begin
        for(int rr=0;rr<512;rr++) u_soc.u_e203_subsys_top.u_e203_subsys_main.u_e203_cpu_top.u_e203_srams.u_e203_itcm_ram.u_e203_itcm_gnrl_ram.g_macro.g_row[r].g_col[c].u_ram.mem[rr]='x;
        for(int a=0;a<4096;a++)begin
          logic[15:0] w;logic[127:0] row;
          w=link.fw[r*4096+a][16*c+:16];
          row=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_e203_cpu_top.u_e203_srams.u_e203_itcm_ram.u_e203_itcm_gnrl_ram.g_macro.g_row[r].g_col[c].u_ram.mem[a>>3];
          for(int k=0;k<16;k++)row[8*k+(a&7)]=w[k];
          u_soc.u_e203_subsys_top.u_e203_subsys_main.u_e203_cpu_top.u_e203_srams.u_e203_itcm_ram.u_e203_itcm_gnrl_ram.g_macro.g_row[r].g_col[c].u_ram.mem[a>>3]=row;
        end
      end
    end
  end
  for(genvar b=0;b<1;b++)begin:g_outbank
    for(genvar g=0;g<32;g++)begin:g_outgroup
      always @(posedge link.output_capture)begin
        for(int a=0;a<4096;a++)begin
          logic[127:0] lo,hi;
          lo=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_shram.u_bank.gen_grp[g].u_ram_lo.mem[a>>3];
          hi=u_soc.u_e203_subsys_top.u_e203_subsys_main.u_kse_sys.u_shram.u_bank.gen_grp[g].u_ram_hi.mem[a>>3];
          for(int k=0;k<16;k++)begin
            link.output_halves[b][g][0][a][k]=lo[8*k+(a&7)];
            link.output_halves[b][g][1][a][k]=hi[8*k+(a&7)];
          end
        end
      end
    end
  end
  always @(posedge link.output_capture)begin #1;link.output_ack=1;end
  always @(negedge link.output_capture)link.output_ack=0;
  initial begin
    string path;
    if($value$plusargs("fsdbfile=%s",path))begin $fsdbDumpfile(path);$fsdbDumpvars(0,tb_kse_soc_uvm);end
    uvm_config_db#(virtual kse_integration_if)::set(null,"uvm_test_top*","vif",link);
    run_test();
  end
endmodule
