`default_nettype none
// Parameter prefetch FIFO.  Accepts the 32-bit parameter stream at up to one
// word per cycle, independent of the layer sequencing, and delivers 128-bit
// rows (4 words, word 0 in [31:0]) to the loader at up to one row per cycle.
//
// Storage: 8 single-port macros side by side (128-bit rows), DEPTH rows
// (1024: RAMSP1024X16, 128: RAMSP128X16).  Completed input rows wait in a
// 2-row staging buffer; reads have priority and a staged row is written only
// in a cycle without a read, so the input stalls while the loader drains a
// burst and the staging buffer is full.  Read data goes into a 4-row output
// buffer (reads are issued while at most 2 rows are buffered or in flight
// beyond the one being consumed), so the loader can take one row per cycle
// and each macro sees at most one access per cycle.
module kse_pfifo #(parameter int DEPTH = 1024) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         in_valid,
  output logic         in_ready,
  input  logic [31:0]  in_data,
  output logic         out_valid,
  input  logic         out_ready,
  output logic [127:0] out_data,
  output logic [$clog2(DEPTH):0] level      // rows stored in the macros
);
  localparam int AW = $clog2(DEPTH);

  // ---------------- input assembly + staging ----------------
  logic [95:0]  abuf;
  logic [1:0]   aw;          // words in abuf
  logic [127:0] stg [2];
  logic [1:0]   wn;          // staged rows
  logic [127:0] wrow;
  logic [AW-1:0] wptr, rptr;
  logic [AW:0]  cnt;          // rows completed (staged + stored) not yet read
  logic         in_acc, row_done;
  assign in_ready = (cnt + 2 <= DEPTH) && !(aw == 2'd3 && wn == 2'd2);
  assign in_acc   = in_valid && in_ready;
  assign row_done = in_acc && (aw == 2'd3);

  // ---------------- read side ----------------
  logic [127:0] ob [4];
  logic [2:0]   ocnt;
  logic [1:0]   obw, obr;
  logic         rd_cond, rd_issue, rd_v, wpend;
  logic [AW:0]  stored;       // rows actually written
  assign rd_cond   = (stored != 0) && ((ocnt + 3'(rd_v)) <= 3'd2);
  assign wpend     = (wn != 0) && !rd_cond;
  assign rd_issue  = rd_cond && !wpend;
  assign out_valid = (ocnt != 0);
  assign out_data  = ob[obr];
  assign level     = stored;
  assign wrow      = stg[0];

  logic          m_en, m_we;
  logic [AW-1:0] m_a;
  logic [127:0]  m_q;
  assign m_en = wpend || rd_issue;
  assign m_we = wpend;
  assign m_a  = wpend ? wptr : rptr;

  for (genvar m = 0; m < 8; m++) begin : g_mac
    if (DEPTH == 1024) begin : g_1k
      `ifdef ARM_UD_MODEL
      RAMSP1024X16 u_ram
      `else
      RAMSP1024X16_beh u_ram
      `endif
      (.Q(m_q[m*16 +: 16]), .CLK(clk), .CEN(~m_en), .WEN(m_we ? 16'h0 : 16'hFFFF),
        .A(m_a), .D(wrow[m*16 +: 16]), .EMA(3'b010), .EMAW(2'b00), .GWEN(~m_we), .RET1N(1'b1));
    end else if (DEPTH == 128) begin : g_128
      `ifdef ARM_UD_MODEL
      RAMSP128X16 u_ram
      `else
      RAMSP128X16_beh u_ram
      `endif
      (.Q(m_q[m*16 +: 16]), .CLK(clk), .CEN(~m_en), .WEN(m_we ? 16'h0 : 16'hFFFF),
        .A(m_a), .D(wrow[m*16 +: 16]), .EMA(3'b010), .EMAW(2'b00), .GWEN(~m_we), .RET1N(1'b1));
    end else begin : g_bad
      $error("kse_pfifo: DEPTH must be 128 or 1024");
    end
  end

  logic pop;
  assign pop = out_valid && out_ready;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw <= '0; wn <= '0; wptr <= '0; rptr <= '0; cnt <= '0; stored <= '0;
      ocnt <= '0; obw <= '0; obr <= '0; rd_v <= 1'b0;
    end else begin
      rd_v <= rd_issue;
      // input
      if (in_acc) aw <= aw + 1'b1;
      wn <= wn + 2'(row_done) - 2'(wpend);
      if (wpend) wptr <= wptr + 1'b1;
      if (rd_issue) rptr <= rptr + 1'b1;
      stored <= stored + (AW+1)'(wpend) - (AW+1)'(rd_issue);
      cnt    <= cnt + (AW+1)'(row_done) - (AW+1)'(rd_issue);
      // output buffer
      if (rd_v) obw <= obw + 1'b1;
      if (pop) obr <= obr + 1'b1;
      ocnt <= ocnt + 3'(rd_v) - 3'(pop);
    end
  end
  always_ff @(posedge clk) begin
    if (in_acc && aw != 2'd3) abuf[aw*32 +: 32] <= in_data;
    // staging queue: stg[0] is the head
    if (wpend) stg[0] <= stg[1];
    if (row_done) begin
      if (wn == 2'd0 || (wn == 2'd1 && wpend)) stg[0] <= {in_data, abuf};
      else stg[1] <= {in_data, abuf};
    end
    if (rd_v) ob[obw] <= m_q;
  end
endmodule
`default_nettype wire
