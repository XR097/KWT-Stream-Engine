`default_nettype none
// Row store: NM RAMSP1024X16 single-port macros side by side, one 2*NM-byte
// row per address.  Every access touches all macros, so each macro sees at
// most one read or one write per cycle.  Read data is valid one cycle after
// the read (macro behaviour).  Only full-row writes are used.
module kse_rowstore #(parameter int NM = 16) (
  input  logic              clk,
  input  logic              en,
  input  logic              we,
  input  logic [9:0]        addr,
  input  logic [NM*16-1:0]  wdata,
  output logic [NM*16-1:0]  rdata
);
  for (genvar m = 0; m < NM; m++) begin : g_mac
    `ifdef ARM_UD_MODEL
    RAMSP1024X16 u_ram
    `else
    RAMSP1024X16_beh u_ram
    `endif
      (
      .Q    (rdata[m*16 +: 16]),
      .CLK  (clk),
      .CEN  (~en),
      .WEN  (we ? 16'h0000 : 16'hFFFF),
      .A    (addr),
      .D    (wdata[m*16 +: 16]),
      .EMA  (3'b010),
      .EMAW (2'b00),
      .GWEN (~we),
      .RET1N(1'b1)
    );
  end
endmodule
// Two groups of real 128-deep single-port macros, selected by address bit 7.
module kse_rowstore256 (
  input logic clk, en, we,
  input logic [7:0] addr,
  input logic [255:0] wdata,
  output logic [255:0] rdata
);
  logic bank_q;
  logic [255:0] q [2];
  always_ff @(posedge clk) if (en) bank_q <= addr[7];
  assign rdata = q[bank_q];
  for (genvar b = 0; b < 2; b++) begin : g_bank
    for (genvar m = 0; m < 16; m++) begin : g_mac
      `ifdef ARM_UD_MODEL
      RAMSP128X16 u_ram
      `else
      RAMSP128X16_beh u_ram
      `endif
      (.Q(q[b][16*m +: 16]), .CLK(clk),
        .CEN(!(en && addr[7] == 1'(b))), .WEN(we ? 16'h0 : 16'hffff),
        .A(addr[6:0]), .D(wdata[16*m +: 16]), .EMA(3'b010), .EMAW(2'b00),
        .GWEN(~we), .RET1N(1'b1));
    end
  end
endmodule
// Probability beats occupy distinct real single-port groups. A read and a
// write may proceed together only when their beat-bank indices differ.
module kse_probstore (
  input logic clk, rd_en, wr_en,
  input logic [8:0] rd_addr, wr_addr,
  input logic [255:0] wdata,
  output logic [255:0] rdata
);
  logic [1:0] bank_q;
  logic [255:0] q [4];
  always_ff @(posedge clk) if (rd_en) bank_q <= rd_addr[1:0];
  assign rdata = q[bank_q];
  for (genvar b = 0; b < 4; b++) begin : g_bank
    logic we, en;
    logic [6:0] addr;
    assign we = wr_en && wr_addr[1:0] == 2'(b);
    assign en = we || (rd_en && rd_addr[1:0] == 2'(b));
    assign addr = we ? wr_addr[8:2] : rd_addr[8:2];
    for (genvar m = 0; m < ((b == 3) ? 2 : 16); m++) begin : g_mac
      `ifdef ARM_UD_MODEL
      RAMSP128X16 u_ram
      `else
      RAMSP128X16_beh u_ram
      `endif
      (.Q(q[b][16*m +: 16]), .CLK(clk), .CEN(~en),
        .WEN(we ? 16'h0 : 16'hffff), .A(addr), .D(wdata[16*m +: 16]),
        .EMA(3'b010), .EMAW(2'b00), .GWEN(~we), .RET1N(1'b1));
    end
    if (b == 3) assign q[b][255:32] = '0;
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rd_en && wr_en && rd_addr[1:0] == wr_addr[1:0])
    $error("kse_probstore: physical single-port collision");
`endif
endmodule
// V is consumed column-by-column before context overwrites the same column.
// Separate physical column banks permit last context column-0 writes while
// column-1 V is loaded. Each 128-deep macro remains strictly single-port.
module kse_vctxstore (
  input logic clk, rd_en, wr_en,
  input logic [7:0] rd_addr, wr_addr,
  input logic [255:0] wdata,
  output logic [255:0] rdata
);
  logic bank_q;
  logic [255:0] q [2];
  always_ff @(posedge clk) if (rd_en) bank_q <= rd_addr[0];
  assign rdata = q[bank_q];
  for (genvar b = 0; b < 2; b++) begin : g_bank
    logic we, en;
    logic [6:0] addr;
    assign we = wr_en && wr_addr[0] == 1'(b);
    assign en = we || (rd_en && rd_addr[0] == 1'(b));
    assign addr = we ? wr_addr[7:1] : rd_addr[7:1];
    for (genvar m = 0; m < 16; m++) begin : g_mac
      `ifdef ARM_UD_MODEL
      RAMSP128X16 u_ram
      `else
      RAMSP128X16_beh u_ram
      `endif
      (.Q(q[b][16*m +: 16]), .CLK(clk), .CEN(~en),
        .WEN(we ? 16'h0 : 16'hffff), .A(addr), .D(wdata[16*m +: 16]),
        .EMA(3'b010), .EMAW(2'b00), .GWEN(~we), .RET1N(1'b1));
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rd_en && wr_en && rd_addr[0] == wr_addr[0])
    $error("kse_vctxstore: physical single-port collision");
`endif
endmodule
`default_nettype wire
