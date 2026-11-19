`timescale 1ns/1ps
// WP8 KSSOC-008: passive view of the real E203 SoC peripheral buses and pads.
// APB ports (icb2apb outputs inside upstream e203_subsys_perips):
//   0 GPIOA 1 GPIOB 2 UART0 3 UART1 4 UART2 5 SPI1 6 SPI2 7 I2C0 8 I2C1 9 PWM
// ICB ports:
//   0 AON(PPI O0) 1 HCLKGEN(O1) 2 QSPI0(O4) 3 EXPL_AXI(O14) 4 KSE MMIO(O12)
//   5 CLINT 6 PLIC 7 shared SRAM CPU port (mailbox)
interface wp8_soc_periph_if(input logic clk);
  localparam int NAPB = 10;
  localparam int NICB = 8;
  logic rst_n;                       // bus_rst_n (kse_rst_n)
  logic erst_n = 1'b0;               // pad reset, driven by the test
  logic fw_load = 1'b0;
  logic [63:0] fw[8192];
  // pads
  logic [31:0] gpioA_oval, gpioA_oe, gpioB_oval, gpioB_oe;
  logic uart0_rx_pad = 1'b1;         // GPIOA pad 16 input, idle high
  // APB
  logic [NAPB-1:0] psel, penable, pwrite, icv, icr, irv, irr;
  logic [31:0] paddr[NAPB], pwdata[NAPB], prdata[NAPB];
  // ICB
  logic [NICB-1:0] cv, cr, rd, rv, rr, rerr;
  logic [31:0] addr[NICB], wdata[NICB], rdata[NICB];
  logic [3:0] wmask[NICB];

  for (genvar p = 0; p < NAPB; p++) begin : g_apb
    // icb2apb: PENABLE only follows a PSEL setup cycle with a stable address,
    // and every access phase lasts exactly one cycle (PREADY is not used).
    a_apb_access: assert property (@(posedge clk) disable iff (rst_n !== 1'b1)
      penable[p] |-> psel[p] && $past(psel[p]) && $stable(paddr[p]) && $stable(pwrite[p]))
      else $error("WP8 APB access phase without setup port=%0d", p);
    a_apb_single: assert property (@(posedge clk) disable iff (rst_n !== 1'b1)
      psel[p] && penable[p] |=> !penable[p])
      else $error("WP8 APB access phase longer than one cycle port=%0d", p);
    c_apb_write: cover property (@(posedge clk) disable iff (rst_n !== 1'b1) psel[p] && penable[p] && pwrite[p]);
    c_apb_read: cover property (@(posedge clk) disable iff (rst_n !== 1'b1) psel[p] && penable[p] && !pwrite[p]);
  end
  for (genvar p = 0; p < NICB; p++) begin : g_icb
    a_icb_hold: assert property (@(posedge clk) disable iff (rst_n !== 1'b1)
      cv[p] && !cr[p] |=> cv[p] && $stable(addr[p]) && $stable(rd[p]))
      else $error("WP8 ICB command changed under backpressure port=%0d", p);
    c_icb_cmd: cover property (@(posedge clk) disable iff (rst_n !== 1'b1) cv[p] && cr[p]);
  end
endinterface
