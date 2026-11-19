// Project implementation of the E203 generic RAM wrapper (module sirv_gnrl_ram,
// same name and ports as upstream general/sirv_gnrl_ram.v, which is excluded
// from the KSE SoC file lists).  Upstream marks this module as the place "to
// add the ASIC ... here"; the KSE SoC maps the E203 ITCM (8192 x 64) and DTCM
// (16384 x 32) onto SMIC40 RAMSP4096X16 single-port macros so that synthesis
// and power analysis see real, characterized memories:
//   ITCM: 2 rows x 4 columns = 8 macros (64 KiB), DTCM: 4 rows x 2 columns = 8 macros (64 KiB).
// Any other geometry falls back to the upstream behavioral sirv_sim_ram.
//
// Timing is the same as sirv_sim_ram: one-cycle read, byte write mask; the
// output holds the last read word while the RAM is not read (the macro keeps
// Q when CEN=1 or on a write), which is what the E203 IFU hold-up relies on.
// EMA=3'b010 / EMAW=2'b00 (vendor defaults), RET1N=1; sd/ds/ls are unused.
module sirv_gnrl_ram
#(parameter DP = 32,
  parameter DW = 32,
  parameter FORCE_X2ZERO = 1,
  parameter MW = 4,
  parameter AW = 15
  ) (
  input            sd,
  input            ds,
  input            ls,

  input            rst_n,
  input            clk,
  input            cs,
  input            we,
  input [AW-1:0]   addr,
  input [DW-1:0]   din,
  input [MW-1:0]   wem,
  output[DW-1:0]   dout
);
  localparam USE_MACRO = ((DP == 8192) && (DW == 64) && (MW == 8)) ||
                         ((DP == 16384) && (DW == 32) && (MW == 4));
  generate
    if (USE_MACRO) begin : g_macro
      localparam NC = DW / 16;          // macro columns (16 bits each)
      localparam NR = DP / 4096;        // macro rows (4096 words each)
      localparam RW = (NR > 1) ? $clog2(NR) : 1;
      wire [RW-1:0] row = addr[AW-1:12];
      reg  [RW-1:0] row_q;
      wire [DW-1:0] q_row [0:NR-1];
      always @(posedge clk) if (cs && !we) row_q <= row;
      genvar r, c;
      for (r = 0; r < NR; r = r + 1) begin : g_row
        for (c = 0; c < NC; c = c + 1) begin : g_col
          wire sel = cs && (row == r);
          `ifdef ARM_UD_MODEL
          RAMSP4096X16 u_ram
          `else
          RAMSP4096X16_beh u_ram
          `endif
          (
            .Q    (q_row[r][16*c +: 16]),
            .CLK  (clk),
            .CEN  (~sel),
            .WEN  ({{8{~wem[2*c+1]}}, {8{~wem[2*c]}}}),
            .A    (addr[11:0]),
            .D    (din[16*c +: 16]),
            .EMA  (3'b010),
            .EMAW (2'b00),
            .GWEN (~(sel && we)),
            .RET1N(1'b1)
          );
        end
      end
      assign dout = q_row[row_q];
    end else begin : g_sim
      sirv_sim_ram #(
        .FORCE_X2ZERO (FORCE_X2ZERO),
        .DP (DP),
        .AW (AW),
        .MW (MW),
        .DW (DW)
      ) u_sirv_sim_ram (
        .clk   (clk),
        .din   (din),
        .addr  (addr),
        .cs    (cs),
        .we    (we),
        .wem   (wem),
        .dout  (dout)
      );
    end
  endgenerate
endmodule
