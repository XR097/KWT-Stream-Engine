`default_nettype none
// Small register FIFO (valid/ready on both sides), used for the engine DMA
// stream buffers.  DEPTH must be a power of two.  count is the number of
// stored entries (0..DEPTH).
module kse_soc_fifo #(
  parameter int W     = 32,
  parameter int DEPTH = 4
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     in_valid,
  output logic                     in_ready,
  input  logic [W-1:0]             in_data,
  output logic                     out_valid,
  input  logic                     out_ready,
  output logic [W-1:0]             out_data,
  output logic [$clog2(DEPTH):0]   count
);
  localparam int AW = $clog2(DEPTH);
  logic [W-1:0]  mem [DEPTH];
  logic [AW-1:0] wp, rp;
  logic          push, pop;

  assign in_ready  = (count != DEPTH[AW:0]);
  assign out_valid = (count != '0);
  assign out_data  = mem[rp];
  assign push      = in_valid && in_ready;
  assign pop       = out_valid && out_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wp <= '0; rp <= '0; count <= '0;
    end else begin
      if (push) wp <= wp + 1'b1;
      if (pop)  rp <= rp + 1'b1;
      count <= count + {{AW{1'b0}}, push} - {{AW{1'b0}}, pop};
    end
  end

  always_ff @(posedge clk) if (push) mem[wp] <= in_data;
endmodule
`default_nettype wire
