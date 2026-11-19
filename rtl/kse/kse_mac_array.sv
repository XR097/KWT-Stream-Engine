`default_nettype none
// KSE weight-stationary MAC array, R reduction rows x C columns.
//
// PE(r,c) holds 32 bits for R32 or 64 bits for R16: 8/16 W4 slots or
// 4/8 int8 slots (K, V, W8), keeping total resident capacity constant.
// Each step multiplies the streamed
// vector a[r] (s8 or u8, i.e. a 9-bit signed operand) by slot `slot` of every
// PE and sums each column into a 24-bit accumulator (two's complement).
//
// Pipeline (step presented at in_* in cycle n):
//   S1  end of n    : a, control registered
//   S2  cycle n+1   : slot read, 9x8 products, 4-input partial sums -> regs
//   S3  cycle n+2   : column total, accumulate -> acc register
//   out cycle n+3   : out_valid/out_acc/out_tag (only for steps with last=1)
// Resident registers are written at the end of the cycle in which ld_* is
// presented; a step reads them during its S2 cycle.
//
// Loads: row-load writes ld_row_data[c] into PE(r,c) for every r with
// ld_row_we[r]; column-load writes ld_col_data[r] into PE(r,c) for every c
// with ld_col_we[c]. ld_w4 selects nibble (slot 0..SLOTS-1) or byte
// (slot 0..SLOTS/2-1).
module kse_mac_array #(
  parameter int R  = 32,
  parameter int C  = 32,
  parameter int TW = 16
) (
  input  logic              clk,
  input  logic              rst_n,
  // First projection column block has a separate two-nibble shadow. It
  // accepts parameter row loads while attention owns the main residents.
  input logic [R-1:0] pj_row_we,
  input logic [C*8-1:0] pj_row_data,
  input logic pj_slot, in_pj,
  // loads
  input  logic [R-1:0]      ld_row_we,
  input  logic [C*8-1:0]    ld_row_data,
  input  logic [C-1:0]      ld_col_we,
  input  logic [R*8-1:0]    ld_col_data,
  input  logic [3:0]        ld_slot,
  input  logic              ld_w4,
  // steps
  input  logic              in_valid,
  input  logic [R*8-1:0]    in_a,
  input  logic              in_uns,
  input  logic [3:0]        in_slot,
  input  logic              in_w4,
  input  logic              in_first,
  input  logic              in_last,
  input  logic [TW-1:0]     in_tag,
  // results
  output logic              out_valid,
  output logic [C*24-1:0]   out_acc,
  output logic [TW-1:0]     out_tag,
  // pipeline occupancy (S1/S2) for slot-free bookkeeping
  output logic              s2_valid,
  output logic              s2_last,
  output logic [TW-1:0]     s2_tag
);
  localparam int G  = (R + 3) / 4;     // partial sums per column
  localparam int SLOTS = (R == 16) ? 16 : 8;
  localparam int PW = 19;              // 4 x 17-bit products
  localparam int SW = 24;

  // ---------------- resident registers ----------------
  logic [SLOTS*4-1:0] wreg [R][C];
  logic [7:0] pjreg [R][C];
  for (genvar r = 0; r < R; r++) begin : g_pjr
    for (genvar c = 0; c < C; c++) begin : g_pjc
      always_ff @(posedge clk) if (pj_row_we[r])
        pjreg[r][c][4*pj_slot +: 4] <= pj_row_data[8*c +: 4];
    end
  end
  for (genvar r = 0; r < R; r++) begin : g_wr
    for (genvar c = 0; c < C; c++) begin : g_wc
      logic       we;
      logic [7:0] d;
      assign we = ld_row_we[r] | ld_col_we[c];
      assign d  = ld_row_we[r] ? ld_row_data[c*8 +: 8] : ld_col_data[r*8 +: 8];
      for (genvar k = 0; k < SLOTS; k++) begin : g_nib
        logic sel;
        assign sel = ld_w4 ? (ld_slot == 4'(k)) : (ld_slot[2:0] == 3'(k / 2));
        always_ff @(posedge clk) begin
          if (we && sel) wreg[r][c][4*k +: 4] <= (ld_w4 || (k % 2 == 0)) ? d[3:0] : d[7:4];
        end
      end
    end
  end

  // ---------------- S1 ----------------
  logic            s1_valid, s1_pj, s1_uns, s1_w4, s1_first, s1_last;
  logic [3:0]      s1_slot;
  logic [R*8-1:0]  s1_a;
  logic [TW-1:0]   s1_tag;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) s1_valid <= 1'b0;
    else        s1_valid <= in_valid;
  end
  always_ff @(posedge clk) begin
    if (in_valid) begin
      s1_a     <= in_a;
      s1_pj    <= in_pj;
      s1_uns   <= in_uns;
      s1_w4    <= in_w4;
      s1_slot  <= in_slot;
      s1_first <= in_first;
      s1_last  <= in_last;
      s1_tag   <= in_tag;
    end
  end

  // ---------------- S2: products and partial sums ----------------
  logic signed [PW-1:0] part_n [C][G];
  logic signed [PW-1:0] part_q [C][G];
  for (genvar c = 0; c < C; c++) begin : g_col
    logic signed [16:0] prod [R];
    for (genvar r = 0; r < R; r++) begin : g_pe
      logic signed [8:0] a9;
      logic signed [7:0] w8;
      logic [SLOTS*4-1:0] wv;
      assign wv = wreg[r][c];
      assign a9 = s1_uns ? $signed({1'b0, s1_a[r*8 +: 8]}) : $signed({s1_a[r*8+7], s1_a[r*8 +: 8]});
      always_comb begin
        if (s1_pj) w8 = $signed({{4{pjreg[r][c][4*s1_slot[0]+3]}}, pjreg[r][c][4*s1_slot[0] +: 4]});
        else if (s1_w4) w8 = $signed({{4{wv[4*s1_slot+3]}}, wv[4*s1_slot +: 4]});
        else       w8 = $signed(wv[8*s1_slot[2:0] +: 8]);
      end
      assign prod[r] = a9 * w8;
    end
    for (genvar g = 0; g < G; g++) begin : g_grp
      always_comb begin
        part_n[c][g] = '0;
        for (int k = 0; k < 4; k++) begin
          if (g * 4 + k < R) part_n[c][g] = part_n[c][g] + PW'(prod[g*4+k]);
        end
      end
      always_ff @(posedge clk) if (s1_valid) part_q[c][g] <= part_n[c][g];
    end
  end
  logic          s2v, s2_first;
  logic [TW-1:0] s2t;
  logic          s2l;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) s2v <= 1'b0;
    else        s2v <= s1_valid;
  end
  always_ff @(posedge clk) begin
    if (s1_valid) begin
      s2_first <= s1_first;
      s2l      <= s1_last;
      s2t      <= s1_tag;
    end
  end
  // S2 activity seen by the bookkeeping is the step in its S2 cycle, i.e. S1 regs
  assign s2_valid = s1_valid;
  assign s2_last  = s1_last;
  assign s2_tag   = s1_tag;

  // ---------------- S3: accumulate ----------------
  logic signed [SW-1:0] acc [C];
  for (genvar c = 0; c < C; c++) begin : g_acc
    logic signed [SW-1:0] tot;
    always_comb begin
      tot = '0;
      for (int g = 0; g < G; g++) tot = tot + SW'(part_q[c][g]);
    end
    always_ff @(posedge clk) begin
      if (s2v) acc[c] <= s2_first ? tot : acc[c] + tot;
    end
    assign out_acc[c*SW +: SW] = acc[c];
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) out_valid <= 1'b0;
    else        out_valid <= s2v & s2l;
  end
  always_ff @(posedge clk) if (s2v) out_tag <= s2t;
endmodule
`default_nettype wire
