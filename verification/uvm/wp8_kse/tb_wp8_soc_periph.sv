`timescale 1ns/1ps
// WP8 KSSOC-008: real E203 SoC (kse_e203_soc_top) peripheral/UART platform test.
// The CPU runs validation firmware from ITCM (loaded only during reset); the
// testbench observes buses and pads, drives pad inputs (UART0 RX on GPIOA[16])
// and keeps the KSE loader port idle.  No CPU path is forced.
module tb_wp8_soc_periph;
  import uvm_pkg::*;
  import wp8_soc_periph_pkg::*;
  logic clk = 0, lfclk = 0;
  wire kclk, krst_n;
  always #5 clk = ~clk;
  always #82.5 lfclk = ~lfclk;

  `define WP8_MAIN u_soc.u_e203_subsys_top.u_e203_subsys_main
  `define WP8_PER  u_soc.u_e203_subsys_top.u_e203_subsys_main.u_e203_subsys_perips

  wp8_soc_periph_if pif(`WP8_PER.clk);
  assign pif.rst_n = krst_n;

  // GPIOA inputs: pad 16 = UART0 RX (driven by the env), pad 18 = UART2 RX idle high.
  // GPIOB inputs: fixed pattern read by the CPU; pad 16 = UART1 RX idle high.
  wire [31:0] gpioA_in = {13'b0, 1'b1, 1'b0, pif.uart0_rx_pad, 16'b0};
  wire [31:0] gpioB_in = 32'h5A01_C3A5;

  kse_e203_soc_top u_soc (
    .hfextclk(clk), .hfxoscen(), .lfextclk(lfclk), .lfxoscen(),
    .io_pads_jtag_TCK_i_ival(1'b0), .io_pads_jtag_TMS_i_ival(1'b0), .io_pads_jtag_TDI_i_ival(1'b0),
    .io_pads_jtag_TDO_o_oval(), .io_pads_jtag_TDO_o_oe(),
    .io_pads_gpioA_i_ival(gpioA_in), .io_pads_gpioA_o_oval(pif.gpioA_oval), .io_pads_gpioA_o_oe(pif.gpioA_oe),
    .io_pads_gpioB_i_ival(gpioB_in), .io_pads_gpioB_o_oval(pif.gpioB_oval), .io_pads_gpioB_o_oe(pif.gpioB_oe),
    .io_pads_qspi0_sck_o_oval(), .io_pads_qspi0_cs_0_o_oval(),
    .io_pads_qspi0_dq_0_i_ival(1'b1), .io_pads_qspi0_dq_0_o_oval(), .io_pads_qspi0_dq_0_o_oe(),
    .io_pads_qspi0_dq_1_i_ival(1'b1), .io_pads_qspi0_dq_1_o_oval(), .io_pads_qspi0_dq_1_o_oe(),
    .io_pads_qspi0_dq_2_i_ival(1'b1), .io_pads_qspi0_dq_2_o_oval(), .io_pads_qspi0_dq_2_o_oe(),
    .io_pads_qspi0_dq_3_i_ival(1'b1), .io_pads_qspi0_dq_3_o_oval(), .io_pads_qspi0_dq_3_o_oe(),
    .io_pads_aon_erst_n_i_ival(pif.erst_n), .io_pads_aon_pmu_dwakeup_n_i_ival(1'b1),
    .io_pads_aon_pmu_vddpaden_o_oval(), .io_pads_aon_pmu_padrst_o_oval(),
    .io_pads_bootrom_n_i_ival(1'b0), .io_pads_dbgmode0_n_i_ival(1'b1),
    .io_pads_dbgmode1_n_i_ival(1'b1), .io_pads_dbgmode2_n_i_ival(1'b1),
    // KSE loader port idle: no command, response always accepted, no
    // write-pointer initialisation/publication, loader not done.
    .kse_ldr_cmd_valid(1'b0), .kse_ldr_cmd_ready(), .kse_ldr_cmd_addr(32'b0),
    .kse_ldr_cmd_read(1'b0), .kse_ldr_cmd_wdata(32'b0), .kse_ldr_cmd_wmask(4'b0),
    .kse_ldr_rsp_valid(), .kse_ldr_rsp_ready(1'b1), .kse_ldr_rsp_rdata(),
    .kse_ldr_rsp_err(),
    .kse_ldr_wptr_init(1'b0), .kse_ldr_wptr_init_value(32'b0),
    .kse_ldr_wptr_we(1'b0), .kse_ldr_wptr_wdata(32'b0), .kse_ldr_done(1'b0),
    .kse_clk(kclk), .kse_rst_n(krst_n));

  // ---- passive APB taps (icb2apb outputs inside upstream e203_subsys_perips) ----
  `define WP8_APB(IDX, P) \
    assign pif.psel[IDX] = `WP8_PER.P``_apb_pselx; \
    assign pif.penable[IDX] = `WP8_PER.P``_apb_penable; \
    assign pif.pwrite[IDX] = `WP8_PER.P``_apb_pwrite; \
    assign pif.paddr[IDX] = `WP8_PER.P``_apb_paddr; \
    assign pif.pwdata[IDX] = `WP8_PER.P``_apb_pwdata; \
    assign pif.prdata[IDX] = `WP8_PER.P``_apb_prdata; \
    assign pif.icv[IDX] = `WP8_PER.P``_apb_icb_cmd_valid; \
    assign pif.icr[IDX] = `WP8_PER.P``_apb_icb_cmd_ready; \
    assign pif.irv[IDX] = `WP8_PER.P``_apb_icb_rsp_valid; \
    assign pif.irr[IDX] = `WP8_PER.P``_apb_icb_rsp_ready;
  `WP8_APB(0, gpioA)
  `WP8_APB(1, gpioB)
  `WP8_APB(2, uart0)
  `WP8_APB(3, uart1)
  `WP8_APB(4, uart2)
  `WP8_APB(5, spi1)
  `WP8_APB(6, spi2)
  `WP8_APB(7, i2c0)
  `WP8_APB(8, i2c1)
  `WP8_APB(9, pwm)

  // ---- passive ICB taps ----
  `define WP8_ICB(IDX, H, MASK, ERR) \
    assign pif.cv[IDX] = H``_cmd_valid; \
    assign pif.cr[IDX] = H``_cmd_ready; \
    assign pif.rd[IDX] = H``_cmd_read; \
    assign pif.addr[IDX] = H``_cmd_addr; \
    assign pif.wdata[IDX] = H``_cmd_wdata; \
    assign pif.wmask[IDX] = MASK; \
    assign pif.rv[IDX] = H``_rsp_valid; \
    assign pif.rr[IDX] = H``_rsp_ready; \
    assign pif.rdata[IDX] = H``_rsp_rdata; \
    assign pif.rerr[IDX] = ERR;
  `WP8_ICB(0, `WP8_PER.i_aon_icb, 4'hf, `WP8_PER.i_aon_icb_rsp_err)
  `WP8_ICB(1, `WP8_PER.hclkgen_icb, `WP8_PER.hclkgen_icb_cmd_wmask, `WP8_PER.hclkgen_icb_rsp_err)
  `WP8_ICB(2, `WP8_PER.qspi0_icb, 4'hf, 1'b0)
  `WP8_ICB(3, `WP8_PER.expl_axi_icb, `WP8_PER.expl_axi_icb_cmd_wmask, `WP8_PER.expl_axi_icb_rsp_err)
  `WP8_ICB(4, `WP8_MAIN.kse_mmio_icb, `WP8_MAIN.kse_mmio_icb_cmd_wmask, `WP8_MAIN.kse_mmio_icb_rsp_err)
  `WP8_ICB(5, `WP8_MAIN.clint_icb, `WP8_MAIN.clint_icb_cmd_wmask, `WP8_MAIN.clint_icb_rsp_err)
  `WP8_ICB(6, `WP8_MAIN.plic_icb, `WP8_MAIN.plic_icb_cmd_wmask, `WP8_MAIN.plic_icb_rsp_err)
  `WP8_ICB(7, `WP8_MAIN.kse_shram_icb, `WP8_MAIN.kse_shram_icb_cmd_wmask, `WP8_MAIN.kse_shram_icb_rsp_err)

  // ---- ITCM load during reset (same macro mapping as tb_kse_soc_uvm) ----
  for (genvar r = 0; r < 2; r++) begin : g_itrow
    for (genvar c = 0; c < 4; c++) begin : g_itcol
      always @(posedge pif.fw_load) begin
        for (int rr = 0; rr < 512; rr++) `WP8_MAIN.u_e203_cpu_top.u_e203_srams.u_e203_itcm_ram.u_e203_itcm_gnrl_ram.g_macro.g_row[r].g_col[c].u_ram.mem[rr] = 'x;
        for (int a = 0; a < 4096; a++) begin
          logic [15:0] w; logic [127:0] row;
          w = pif.fw[r*4096+a][16*c+:16];
          row = `WP8_MAIN.u_e203_cpu_top.u_e203_srams.u_e203_itcm_ram.u_e203_itcm_gnrl_ram.g_macro.g_row[r].g_col[c].u_ram.mem[a>>3];
          for (int k = 0; k < 16; k++) row[8*k+(a&7)] = w[k];
          `WP8_MAIN.u_e203_cpu_top.u_e203_srams.u_e203_itcm_ram.u_e203_itcm_gnrl_ram.g_macro.g_row[r].g_col[c].u_ram.mem[a>>3] = row;
        end
      end
    end
  end

  initial begin
    string path;
    if ($value$plusargs("fsdbfile=%s", path)) begin $fsdbDumpfile(path); $fsdbDumpvars(0, tb_wp8_soc_periph); end
    uvm_config_db#(virtual wp8_soc_periph_if)::set(null, "uvm_test_top*", "vif", pif);
    run_test();
  end
endmodule
