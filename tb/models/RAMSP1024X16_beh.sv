// Behavioral stand-in for the SMIC 40LL RAMSP1024X16 single-port SRAM.
//
// Port names, polarity and one-cycle read latency implement the RTL contract
// (CLK, CEN/WEN/GWEN active low, EMA/EMAW tied off by the bank wrapper).  Set
// `ARM_UD_MODEL to instantiate the PDK model instead; see
// rtl/kse_soc/kse_shared_sram.sv.
//
// Simulation convenience: the array is zero-initialized so tests that read
// uninitialized words are deterministic.  The real macro has no reset and
// returns X until a word has been written.
module RAMSP1024X16_beh (
  output logic [15:0] Q,
  input  logic        CLK,
  input  logic        CEN,
  input  logic [15:0] WEN,
  input  logic [9:0] A,
  input  logic [15:0] D,
  input  logic [2:0]  EMA,
  input  logic [1:0]  EMAW,
  input  logic        GWEN,
  input  logic        RET1N
);

  logic [15:0] mem [0:1023];
  logic [15:0] q_r;

  initial begin
    for (int i = 0; i < 1024; i = i + 1) mem[i] = 16'h0000;
    q_r = 16'h0000;
  end

  always @(posedge CLK) begin
    if (!CEN) begin
      if (!GWEN) begin
        // Bit-level write enable, active low.
        for (int b = 0; b < 16; b = b + 1)
          if (!WEN[b]) mem[A][b] <= D[b];
      end else begin
        q_r <= mem[A];
      end
    end
  end

  assign Q = q_r;

  // Tie-off pins are not modeled.
  wire unused_tieoff = ^{EMA, EMAW, RET1N};

endmodule
