`default_nettype none
// KSE arithmetic primitives.  All rounding follows the integer quantization reference:
//   shift(x, s): s > 0 -> round-half-to-even right shift, s < 0 -> left shift
//   divide(n, d): round-half-to-even on the magnitude, sign restored after
//   sqrt(n): floor
// No wide '/', '%' or loops that unroll into deep combinational chains are
// used; division and square root are registered restoring iterations.

// Signed shift with round-half-even.  sh in [-LMAX, +inf): right shifts larger
// than IW+1 saturate to IW+1 (result 0, exact); left shifts are bounded by
// LMAX (caller/packer guarantees).  OW must hold IW+LMAX bits.
module kse_shift_rne #(
  parameter int IW   = 25,
  parameter int OW   = 25,
  parameter int LMAX = 0
) (
  input  logic signed [IW-1:0] x,
  input  logic signed [7:0]    sh,
  output logic signed [OW-1:0] y
);
  localparam int EW = (IW + 2 > OW) ? IW + 2 : OW;
  localparam int SW = $clog2(IW + 2) + 1;
  logic signed [EW-1:0] ext, fl;
  logic        [EW-1:0] mask, rem, half;
  logic        [SW-1:0] shc;
  logic        [7:0]    nl;
  logic                 inc;
  always_comb begin
    ext  = EW'(x);
    shc  = '0;
    fl   = '0;
    mask = '0;
    rem  = '0;
    half = '0;
    inc  = 1'b0;
    nl   = '0;
    if (!sh[7]) begin
      shc  = (sh > 8'(IW + 1)) ? SW'(IW + 1) : SW'(sh);
      fl   = ext >>> shc;
      mask = ~({EW{1'b1}} << shc);
      rem  = ext & mask;
      half = (shc == 0) ? '0 : ({{(EW-1){1'b0}}, 1'b1} << (shc - 1));
      inc  = (shc != 0) && ((rem > half) || ((rem == half) && fl[0]));
      y    = OW'(fl + EW'(inc));
    end else begin
      nl = -sh;
      if (LMAX == 0) nl = '0;
      else if (nl > 8'(LMAX)) nl = 8'(LMAX);
      y  = OW'(ext <<< nl);
    end
  end
endmodule

// Signed saturation to OW bits.
module kse_sat #(parameter int IW = 32, parameter int OW = 8) (
  input  logic signed [IW-1:0] x,
  output logic signed [OW-1:0] y
);
  localparam logic signed [IW-1:0] HI = IW'((1 <<< (OW - 1)) - 1);
  localparam logic signed [IW-1:0] LO = -IW'(1 <<< (OW - 1));
  always_comb begin
    if (x > HI)      y = HI[OW-1:0];
    else if (x < LO) y = LO[OW-1:0];
    else             y = x[OW-1:0];
  end
endmodule

// Pipelined unsigned restoring divider with round-half-even output.
// Computes q = round_half_even(n / d) when n < d * 2^QW; otherwise ovf=1
// (q is then meaningless).  BPS quotient bits per registered stage, II = 1.
// Latency = ceil(QW/BPS) + 1 cycles from in_* to out_*.
module kse_udiv_rne #(
  parameter int NW  = 23,
  parameter int DW  = 22,
  parameter int QW  = 8,
  parameter int BPS = 2,
  parameter int TW  = 1
) (
  input  logic          clk,
  input  logic          in_valid,
  input  logic [NW-1:0] in_n,
  input  logic [DW-1:0] in_d,
  input  logic [TW-1:0] in_tag,
  output logic          out_valid,
  output logic [QW:0]   out_q,
  output logic          out_ovf,
  output logic [TW-1:0] out_tag
);
  localparam int NS = (QW + BPS - 1) / BPS;
  localparam int HW = (NW > QW) ? NW - QW : 1;   // high part width

  logic [DW-1:0] rem_s [0:NS];
  logic [QW-1:0] nq_s  [0:NS];
  logic [DW-1:0] d_s   [0:NS];
  logic          ovf_s [0:NS];
  logic          v_s   [0:NS];
  logic [TW-1:0] tag_s [0:NS];

  // stage 0 (combinational from inputs)
  localparam int MW = (HW > DW) ? HW : DW;
  logic [HW-1:0] hi0;
  logic [MW-1:0] hz, dz;
  always_comb begin
    if (NW > QW) hi0 = HW'(in_n >> QW);
    else         hi0 = '0;
    hz = MW'(hi0);
    dz = MW'(in_d);
    ovf_s[0] = (hz >= dz);
    rem_s[0] = ovf_s[0] ? '0 : DW'(hi0);
    nq_s[0]  = QW'(in_n);
    d_s[0]   = in_d;
    v_s[0]   = in_valid;
    tag_s[0] = in_tag;
  end

  for (genvar s = 0; s < NS; s++) begin : g_stage
    localparam int K = ((QW - s * BPS) >= BPS) ? BPS : (QW - s * BPS);
    logic [DW-1:0] rr;
    logic [QW-1:0] qq;
    logic [DW:0]   trial;
    always_comb begin
      rr = rem_s[s];
      qq = nq_s[s];
      trial = '0;
      for (int k = 0; k < K; k++) begin
        trial = {rr, qq[QW-1]};
        qq    = qq << 1;
        if (trial >= {1'b0, d_s[s]}) begin
          rr    = DW'(trial - {1'b0, d_s[s]});
          qq[0] = 1'b1;
        end else begin
          rr = trial[DW-1:0];
        end
      end
    end
    always_ff @(posedge clk) begin
      rem_s[s+1] <= rr;
      nq_s[s+1]  <= qq;
      d_s[s+1]   <= d_s[s];
      ovf_s[s+1] <= ovf_s[s];
      v_s[s+1]   <= v_s[s];
      tag_s[s+1] <= tag_s[s];
    end
  end

  // rounding stage
  logic [DW:0] twice;
  logic        inc;
  always_comb begin
    twice = {rem_s[NS], 1'b0};
    inc   = (twice > {1'b0, d_s[NS]}) || ((twice == {1'b0, d_s[NS]}) && nq_s[NS][0]);
  end
  always_ff @(posedge clk) begin
    out_valid <= v_s[NS];
    out_q     <= {1'b0, nq_s[NS]} + (QW+1)'(inc);
    out_ovf   <= ovf_s[NS];
    out_tag   <= tag_s[NS];
  end
endmodule

// Iterative floor square root (bit-pair restoring, same algorithm as
// IntegerISA.sqrt).  IW even.  BPC root bits per cycle.
// start (1 cycle) -> busy for ceil((IW/2)/BPC) cycles -> done pulse, root valid
// until the next start.
module kse_isqrt #(parameter int IW = 36, parameter int BPC = 3) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              start,
  input  logic [IW-1:0]     n,
  output logic [IW/2-1:0]   root,
  output logic              busy,
  output logic              done
);
  localparam int RW = IW / 2;
  localparam int NC = RW / BPC;
  if ((IW % 2) != 0 || (RW % BPC) != 0) begin : g_bad_param
    $error("kse_isqrt: IW must be even and IW/2 divisible by BPC");
  end
  logic [IW-1:0]   bits_q;
  logic [RW+1:0]   rem_q;
  logic [$clog2(NC+1)-1:0] cnt;
  logic [IW-1:0]   b_n;
  logic [RW+1:0]   r_n;
  logic [RW-1:0]   root_n;
  logic [RW+1:0]   trial, sub;
  always_comb begin
    b_n = bits_q;
    r_n = rem_q;
    root_n = root;
    trial = '0;
    sub = '0;
    for (int k = 0; k < BPC; k++) begin
      trial = {r_n[RW-1:0], b_n[IW-1:IW-2]};
      sub   = {root_n, 2'b01};
      b_n   = b_n << 2;
      if (trial >= sub) begin
        r_n    = trial - sub;
        root_n = {root_n[RW-2:0], 1'b1};
      end else begin
        r_n    = trial;
        root_n = {root_n[RW-2:0], 1'b0};
      end
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0;
      done <= 1'b0;
      cnt  <= '0;
    end else begin
      done <= 1'b0;
      if (start) begin
        busy <= 1'b1;
        cnt  <= '0;
      end else if (busy) begin
        if (cnt == NC - 1) begin
          busy <= 1'b0;
          done <= 1'b1;
        end
        cnt <= cnt + 1'b1;
      end
    end
  end
  always_ff @(posedge clk) begin
    if (start) begin
      bits_q <= n;
      rem_q  <= '0;
      root   <= '0;
    end else if (busy) begin
      bits_q <= b_n;
      rem_q  <= r_n;
      root   <= root_n;
    end
  end
endmodule
`default_nettype wire
