`timescale 1ns/1ps
// Testbench-only parameter loader (not synthesizable).
//
// Streams data and progress doorbells solely through its 32-bit ICB master.
// A publication follows completion of every covered data write response.
module kse_param_loader #(
  parameter int    IMG_WORDS  = 65536,
  parameter string IMAGE_FILE = "kse_sram_img.hex"
)(
  input  logic        clk,
  input  logic        rst_n,

  // Control
  input  logic        start,
  input  logic [31:0] base_addr,
  input  logic [31:0] length,
  output logic        busy,
  output logic        done,

  // ICB master
  output logic        cmd_valid,
  input  logic        cmd_ready,
  output logic [31:0] cmd_addr,
  output logic        cmd_read,
  output logic [31:0] cmd_wdata,
  output logic [3:0]  cmd_wmask,
  input  logic        rsp_valid,
  output logic        rsp_ready,
  input  logic [31:0] rsp_rdata,
  input  logic        rsp_err,

  // Local observation only; never connected to a SoC port.
  output logic [31:0] wptr
);

  logic [31:0] mem [0:IMG_WORDS-1];

  logic [31:0] base_q;
  logic [31:0] len_q;
  logic [31:0] idx_q;
  logic        busy_q;
  logic        img_loaded;

  // ------------------------------------------------------------------
  // Image loading: the testbench creates the hex file at time 0, so wait
  // one time unit before reading it.
  // ------------------------------------------------------------------
  task automatic load_image;
    int    fd;
    string fname;
    if (!$value$plusargs("LOADER_IMAGE=%s", fname)) fname = IMAGE_FILE;
    fd = $fopen(fname, "r");
    if (fd == 0) begin
      $fatal(1, "TEST FAILED: loader cannot open image file %s", fname);
    end
    $fclose(fd);
    $readmemh(fname, mem);
    img_loaded = 1'b1;
    $display("[LOADER] image loaded from %s", fname);
  endtask

  initial begin
    img_loaded = 1'b0;
    #1;
    load_image();
  end

  // Every progress publication is a real ordered ICB write. Drain ALL
  // preceding responses before publishing, including the final pointer/DONE.
  typedef enum logic [3:0] {IDLE, INIT, INIT_RSP, DATA, DRAIN,
                           PUBLISH, PUB_RSP, FINISH, FIN_RSP} state_t;
  state_t state;
  int publish_words;
  logic [31:0] tx_count, rx_count;
  initial begin
    if (!$value$plusargs("PUBLISH_WORDS=%d", publish_words)) publish_words = 1024;
    if (publish_words < 1) $fatal(1, "TEST FAILED: invalid publication grain");
  end
  assign busy = state != IDLE;
  assign busy_q = busy;
  assign cmd_valid = state inside {INIT, DATA, PUBLISH, FINISH};
  assign cmd_addr = state == INIT ? 32'h40080000 :
                    state == PUBLISH ? 32'h40080004 :
                    state == FINISH ? 32'h40080008 : base_q + (idx_q << 2);
  assign cmd_read = 0;
  assign cmd_wdata = state == INIT ? base_q :
                    state == PUBLISH ? ($test$plusargs("NEG_EARLY_DOORBELL") ? base_q+(len_q<<2) : wptr) :
                    state == FINISH ? 1 : mem[idx_q];
  assign cmd_wmask = 4'hf;
  assign rsp_ready = busy;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE; base_q <= 0; len_q <= 0; idx_q <= 0;
      tx_count <= 0; rx_count <= 0; done <= 0; wptr <= 0;
    end else begin
      if (cmd_valid && cmd_ready) tx_count <= tx_count + 1;
      if (rsp_valid && rsp_ready) begin
        rx_count <= rx_count + 1;
        if (rsp_err) $fatal(1, "TEST FAILED: loader ICB response error");
      end
      case (state)
        IDLE: if (start && img_loaded) begin
          if (length > IMG_WORDS) $fatal(1, "TEST FAILED: loader image too short");
          base_q <= base_addr; len_q <= length; idx_q <= 0;
          wptr <= base_addr; done <= 0; tx_count <= 0; rx_count <= 0;
          state <= INIT;
        end
        INIT: if (cmd_ready) state <= INIT_RSP;
        INIT_RSP: if (rx_count == tx_count) state <= len_q == 0 ? PUBLISH :
                       ($test$plusargs("NEG_EARLY_DOORBELL") ? PUBLISH : DATA);
        DATA: if (cmd_ready) begin
          idx_q <= idx_q + 1; wptr <= base_q + ((idx_q+1)<<2);
          if (idx_q+1 == len_q || (idx_q+1)%publish_words == 0) state <= DRAIN;
        end
        DRAIN: if (rx_count == tx_count) state <= PUBLISH;
        PUBLISH: if (cmd_ready) state <= PUB_RSP;
        PUB_RSP: if (rx_count == tx_count) state <= idx_q == len_q ? FINISH : DATA;
        FINISH: if (cmd_ready) state <= FIN_RSP;
        FIN_RSP: if (rx_count == tx_count) begin state <= IDLE; done <= 1; end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
