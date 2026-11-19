// Single-port 32-bit ICB SRAM controller, 128K x 32 (one 512 KiB slave).
//
// Timing follows the E203 sirv_1cyc_sram_ctrl stage with CUT_READY=0:
//   * one command accepted per cycle (no bubble),
//   * a synchronous read returns one cycle later,
//   * a new command may be accepted in the same cycle the current response is
//     consumed (cmd_ready = !rsp_valid | rsp_ready).
// cmd_addr is the byte offset inside the 512 KiB window; bits [18:2] select
// the 128K-word physical array and bits above [18] are ignored (the SoC
// address decoder owns the region decode).
//
// Upstream sirv_sram_icb_ctrl puts a DP=1 bypbuf in front of this stage.  That
// is a bypassable elastic buffer (a CUT_READY=1 FIFO with an empty/FIFO bypass),
// not a fixed one-cycle register: when empty and the downstream is ready it is
// transparent, but under backpressure it can accept one command more than this
// core.  This design implements only the one-cycle control core: sustained
// throughput and unloaded read latency match, but the extra command elasticity
// does not.  Add an equivalent bypass buffer if wrapper-level equivalence is
// required.
module kse_sram_ctrl (
  input  logic        clk,
  input  logic        rst_n,

  // ICB command channel
  input  logic        cmd_valid,
  output logic        cmd_ready,
  input  logic [31:0] cmd_addr,
  input  logic        cmd_read,
  input  logic [31:0] cmd_wdata,
  input  logic [3:0]  cmd_wmask,

  // ICB response channel
  output logic        rsp_valid,
  input  logic        rsp_ready,
  output logic [31:0] rsp_rdata,
  output logic        rsp_err,

  // Synchronous SRAM port (one-cycle read latency)
  output logic        ram_cs,
  output logic        ram_we,
  output logic [16:0] ram_addr,
  output logic [3:0]  ram_wem,
  output logic [31:0] ram_din,
  input  logic [31:0] ram_dout
);

  logic rsp_valid_q;
  logic cmd_hs;

  assign cmd_hs    = cmd_valid & cmd_ready;
  assign cmd_ready = ~rsp_valid_q | rsp_ready;

  assign ram_cs    = cmd_hs;
  assign ram_we    = ~cmd_read;
  assign ram_addr  = cmd_addr[18:2];
  assign ram_wem   = cmd_read ? 4'b0000 : cmd_wmask;
  assign ram_din   = cmd_wdata;

  assign rsp_valid = rsp_valid_q;
  assign rsp_rdata = ram_dout;
  assign rsp_err   = 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)       rsp_valid_q <= 1'b0;
    else if (cmd_hs)  rsp_valid_q <= 1'b1;
    else if (rsp_ready) rsp_valid_q <= 1'b0;
  end

endmodule
