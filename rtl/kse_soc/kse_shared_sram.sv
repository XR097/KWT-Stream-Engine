// 512 KiB shared SRAM: ONE 32-bit ICB slave on the system bus.
//
// 64 x RAMSP4096X16 macros form one flat 128K x 32 array (32 groups of two
// 16-bit macros side by side).  The slave has a single command/response port:
// at most one word is accessed per cycle, one command is accepted per cycle,
// and a read returns one cycle later, exactly like the upstream
// sirv_1cyc_sram_ctrl stage (CUT_READY=0).  There is no second port, no bank
// parallelism and no private accelerator port; all three system-bus masters
// (CPU O5 memory path, parameter loader, NPU DMA) reach this slave only
// through the single ICB arbiter in kse_sys_bus.
//
// Progress registers are a separate logical bus target at 0x4008_0000.
// All data and doorbells enter through the SAME arbitrated command port.
`default_nettype none
module kse_shared_sram (
  input  logic        clk,
  input  logic        rst_n,

  // ------------------------------------------------------------------
  // System-bus slave port (single 32-bit ICB slave)
  // ------------------------------------------------------------------
  input  logic        cmd_valid,
  output logic        cmd_ready,
  input  logic [31:0] cmd_addr,
  input  logic        cmd_read,
  input  logic [31:0] cmd_wdata,
  input  logic [3:0]  cmd_wmask,
  output logic        rsp_valid,
  input  logic        rsp_ready,
  output logic [31:0] rsp_rdata,
  output logic        rsp_err,

  // ------------------------------------------------------------------
  // Loader write pointer status register
  // ------------------------------------------------------------------
  // Internal progress outputs, written only through BASE/WPTR/DONE ICB writes.
  output logic        loader_done,
  output logic [31:0] loader_wptr,
  output logic [31:0] loader_base,
  output logic        loader_wptr_valid,

  // Read-only MMIO stub for the same register (valid/ready, combinational
  // data; the SoC MMIO glue may register it).
  input  logic        wptr_rd_valid,
  output logic        wptr_rd_ready,
  output logic [31:0] wptr_rd_rdata
);

  // ------------------------------------------------------------------
  // Single controller + one flat macro array
  // ------------------------------------------------------------------
  logic        ram_cs, ctrl_cs, ram_we;
  logic [31:0] ctrl_rdata, progress_rdata, reg_rdata_q;
  logic reg_sel_q, reg_err_q;
  wire progress_sel = cmd_addr[31:4] == 28'h4008000;
  wire mem_sel = cmd_addr[31:20] == 12'h400 && !cmd_addr[19];
  // CPU uses full addresses; DMA and unit benches also use SRAM offsets.
  wire mem_offset = cmd_addr[31:19] == 0;
  wire mem_access = mem_sel || mem_offset;
  wire cmd_hs = cmd_valid && cmd_ready;
  wire reg_ok = progress_sel && cmd_addr[1:0] == 0 && cmd_addr[3:2] != 3 && (cmd_read || cmd_wmask == 4'hf);
  assign ram_cs = ctrl_cs && mem_access;
  assign rsp_rdata = reg_sel_q ? reg_rdata_q : ctrl_rdata;
  assign rsp_err = reg_err_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin reg_sel_q <= 0; reg_rdata_q <= 0; reg_err_q <= 0; end
    else if (cmd_hs) begin
      reg_sel_q <= !mem_access;
      reg_rdata_q <= progress_rdata;
      reg_err_q <= !mem_access && !reg_ok;
    end
  end
  logic [16:0] ram_addr;
  logic [3:0]  ram_wem;
  logic [31:0] ram_din, ram_dout;

  kse_sram_ctrl u_ctrl (
    .clk       (clk),
    .rst_n     (rst_n),
    .cmd_valid (cmd_valid),
    .cmd_ready (cmd_ready),
    .cmd_addr  (cmd_addr),
    .cmd_read  (cmd_read),
    .cmd_wdata (cmd_wdata),
    .cmd_wmask (cmd_wmask),
    .rsp_valid (rsp_valid),
    .rsp_ready (rsp_ready),
    .rsp_rdata (ctrl_rdata),
    .rsp_err   (),
    .ram_cs    (ctrl_cs),
    .ram_we    (ram_we),
    .ram_addr  (ram_addr),
    .ram_wem   (ram_wem),
    .ram_din   (ram_din),
    .ram_dout  (ram_dout)
  );

  kse_sram_bank u_bank (
    .clk      (clk),
    .rst_n    (rst_n),
    .ram_cs   (ram_cs),
    .ram_we   (ram_we),
    .ram_addr (ram_addr),
    .ram_wem  (ram_wem),
    .ram_din  (ram_din),
    .ram_dout (ram_dout)
  );

  kse_load_progress u_progress (
    .clk(clk), .rst_n(rst_n),
    .write_en(cmd_hs && reg_ok && !cmd_read),
    .offset(cmd_addr[3:2]), .wdata(cmd_wdata), .rdata(progress_rdata),
    .base(loader_base), .wptr(loader_wptr), .valid(loader_wptr_valid), .done(loader_done));
  assign wptr_rd_ready = 1'b1;
  assign wptr_rd_rdata = wptr_rd_valid ? loader_wptr : 32'b0;

`ifndef SYNTHESIS
  // The slave accepts at most one command per cycle, and it never accepts a
  // command while the previous response is still stalled.
  always @(posedge clk) if (rst_n) begin
    if (cmd_valid && cmd_ready && rsp_valid && !rsp_ready)
      $error("kse_shared_sram: command accepted while the previous response is stalled");
  end
`endif

endmodule

// ----------------------------------------------------------------------
// Flat 512 KiB array: 32 macro groups deep x 2 macros wide (32 x 4096 x
// 16 bits = 128K x 32).  ram_addr[16:12] selects the group, ram_addr[11:0]
// the macro word.  Only the selected group sees CEN active, so at most one
// 32-bit word (one low/high macro pair) is accessed per cycle.  The response
// group is registered so back-to-back commands to different groups keep the
// right Q.
// ----------------------------------------------------------------------
module kse_sram_bank (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        ram_cs,
  input  logic        ram_we,
  input  logic [16:0] ram_addr,
  input  logic [3:0]  ram_wem,
  input  logic [31:0] ram_din,
  output logic [31:0] ram_dout
);

  logic [4:0]  grp_rsp_q;
  logic [31:0] grp_sel;
  wire  [31:0] q_bus [0:31];

  // ICB byte mask (active high) -> macro bit write enable (active low).
  wire [15:0] wen_lo = {{8{~ram_wem[1]}}, {8{~ram_wem[0]}}};
  wire [15:0] wen_hi = {{8{~ram_wem[3]}}, {8{~ram_wem[2]}}};

  genvar g;
  generate
    for (g = 0; g < 32; g = g + 1) begin : gen_grp
      assign grp_sel[g] = ram_cs && (ram_addr[16:12] == g);
      wire sel  = grp_sel[g];
      wire cen  = ~sel;
      wire gwen = ~(sel && ram_we);
      logic [15:0] q_lo, q_hi;

      `ifdef ARM_UD_MODEL
      RAMSP4096X16 u_ram_lo (
      `else
      RAMSP4096X16_beh u_ram_lo (
      `endif
        .CLK  (clk),
        .CEN  (cen),
        .WEN  (wen_lo),
        .A    (ram_addr[11:0]),
        .D    (ram_din[15:0]),
        .Q    (q_lo),
        .EMA  (3'b010),   // vendor default (same as the engine row stores)
        .EMAW (2'b00),
        .GWEN (gwen),
        .RET1N(1'b1)
      );

      `ifdef ARM_UD_MODEL
      RAMSP4096X16 u_ram_hi (
      `else
      RAMSP4096X16_beh u_ram_hi (
      `endif
        .CLK  (clk),
        .CEN  (cen),
        .WEN  (wen_hi),
        .A    (ram_addr[11:0]),
        .D    (ram_din[31:16]),
        .Q    (q_hi),
        .EMA  (3'b010),   // vendor default (same as the engine row stores)
        .EMAW (2'b00),
        .GWEN (gwen),
        .RET1N(1'b1)
      );

      assign q_bus[g] = {q_hi, q_lo};
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)       grp_rsp_q <= 5'd0;
    else if (ram_cs)  grp_rsp_q <= ram_addr[16:12];
  end

  assign ram_dout = q_bus[grp_rsp_q];

`ifndef SYNTHESIS
  // At most one 32-bit word (one macro group, i.e. one low/high pair) may be
  // accessed per cycle.  This is the structural proof that the shared array
  // is a single-port slave, not a multi-bank parallel store.
  always @(posedge clk) if (rst_n) begin
    if ($countones(grp_sel) > 1)
      $error("kse_sram_bank: %0d macro groups accessed in one cycle", $countones(grp_sel));
    if (ram_cs && (grp_sel == 32'b0))
      $error("kse_sram_bank: ram_cs asserted without selecting a macro group");
  end
`endif

endmodule
`default_nettype wire

// A doorbell is visible only after its real bus write handshake. BASE
// initializes an empty interval and clears DONE. WPTR is an exclusive bound.
module kse_load_progress (
  input logic clk, rst_n, write_en,
  input logic [1:0] offset,
  input logic [31:0] wdata,
  output logic [31:0] rdata, base, wptr,
  output logic valid, done
);
  always_comb case (offset)
    0: rdata = base;
    1: rdata = wptr;
    2: rdata = {30'b0, valid, done};
    default: rdata = 0;
  endcase
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin base <= 0; wptr <= 0; valid <= 0; done <= 0; end
    else if (write_en) case (offset)
      0: begin base <= wdata; wptr <= wdata; valid <= 1; done <= 0; end
      1: wptr <= wdata;
      2: done <= wdata[0];
      default: ;
    endcase
  end
endmodule
