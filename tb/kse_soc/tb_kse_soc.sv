// KSE SoC testbench: complete E203 SoC (kse_e203_soc_top) running the KSE
// firmware, one 512 KiB shared SRAM slave (PDK RAMSP4096X16 models) behind the
// system-bus ICB arbiter, the streaming parameter loader
// (tb/kse_soc/kse_param_loader.sv) as a system-bus master, and the engine DMA
// as the other system-bus master.
//
// Per task (one golden sample):
//   1. SoC reset asserted (not timed).  Backdoor: shared SRAM cleared to 0,
//      engine row stores / prefetch FIFO macros poisoned to X, DTCM cleared,
//      firmware reloaded into ITCM, loader image (input + parameter stream v3)
//      read from file into the loader (computer-side file read, not timed).
//   2. Reset released; E203 boots from MROM -> ITCM, configures PLIC and the
//      engine and writes FLAG_START into shared SRAM.  On that CPU write the
//      bench starts the loader (base 0, 80592 words).
//   3. Window = loader's first write handshake .. CPU write handshake of
//      FLAG_DONE (edge difference of the hfclk counter).
//   4. Checks (all must hold, otherwise TEST FAILED): FLAG_DONE value is the
//      pass code; the 6336 output bytes in shared SRAM equal sample_XX_output
//      byte for byte (exact count); DMA wrote each of the 1584 output words
//      exactly once; DMA read each input/parameter word exactly once and got
//      the loader's word; every DMA read obeyed the release rule; loader wrote
//      exactly 80592 words; 12 layer completions; no timeout.
//
// plusargs: +DATA=<dir with task_XX_img.hex, task_XX_out.hex, tasks.txt>
//           +FW=<itcm hex> +NTASK=<n> +TASK0=<first> +TIMEOUT=<cycles per task>
//           +ACT=saif|fsdb +ACT_TASK=<k> +ACT_FILE=<name>   (activity of the SoC
//           over task k's window; fsdb needs +define+KSE_FSDB at compile time)
`timescale 1ns/10fs
`include "e203_defines.v"
module tb_kse_soc;
  // ---------------- memory map (mirrors firmware/kse/kse_soc.h) ----------------
  localparam int IN_OFF      = 32'h00000;
  localparam int PARAM_OFF   = 32'h018C0;
  localparam int OUT_OFF     = 32'h60000;
  localparam int FLAG_START  = 32'h7F000;
  localparam int FLAG_DONE   = 32'h7F004;
  localparam int PASS_CODE   = 32'h600D000C;
  localparam int IN_WORDS    = 1584;
  localparam int LAYER_WORDS = 6584;
  localparam int PAR_WORDS   = 12 * LAYER_WORDS;
  localparam int IMG_WORDS   = IN_WORDS + PAR_WORDS;   // 80592
  localparam int OUT_WORDS   = 1584;
  localparam real F_MHZ      = 150.0;

  // +CLK_HALF_NS=<ns> sets the hfextclk half period (default 2 ns, i.e. the
  // E203 bench); lfextclk keeps the bench ratio 16.5.  Activity dumps for power
  // use +CLK_HALF_NS=3.3335 so that SAIF time is real 150 MHz time.
  reg clk = 0, lfextclk = 0, rst_n = 0;
  real CLK_HALF = 2.0;
  initial if (!$value$plusargs("CLK_HALF_NS=%f", CLK_HALF)) CLK_HALF = 2.0;
  always #(CLK_HALF) clk = ~clk;
  always #(CLK_HALF * 16.5) lfextclk = ~lfextclk;

  // ---------------- SoC ----------------
  wire        kclk, krst_n;
  wire        l_cmd_valid, l_cmd_ready, l_cmd_read, l_rsp_valid, l_rsp_ready, l_rsp_err;
  wire [31:0] l_cmd_addr, l_cmd_wdata, l_rsp_rdata;
  wire [3:0]  l_cmd_wmask;
  wire [31:0] l_wptr;
  wire        l_busy, l_done;
  reg         l_start = 0;

  kse_e203_soc_top u_soc (
    .hfextclk(clk), .hfxoscen(), .lfextclk(lfextclk), .lfxoscen(),
    .io_pads_jtag_TCK_i_ival(1'b0), .io_pads_jtag_TMS_i_ival(1'b0), .io_pads_jtag_TDI_i_ival(1'b0),
    .io_pads_jtag_TDO_o_oval(), .io_pads_jtag_TDO_o_oe(),
    .io_pads_gpioA_i_ival(32'b0), .io_pads_gpioA_o_oval(), .io_pads_gpioA_o_oe(),
    .io_pads_gpioB_i_ival(32'b0), .io_pads_gpioB_o_oval(), .io_pads_gpioB_o_oe(),
    .io_pads_qspi0_sck_o_oval(), .io_pads_qspi0_cs_0_o_oval(),
    .io_pads_qspi0_dq_0_i_ival(1'b1), .io_pads_qspi0_dq_0_o_oval(), .io_pads_qspi0_dq_0_o_oe(),
    .io_pads_qspi0_dq_1_i_ival(1'b1), .io_pads_qspi0_dq_1_o_oval(), .io_pads_qspi0_dq_1_o_oe(),
    .io_pads_qspi0_dq_2_i_ival(1'b1), .io_pads_qspi0_dq_2_o_oval(), .io_pads_qspi0_dq_2_o_oe(),
    .io_pads_qspi0_dq_3_i_ival(1'b1), .io_pads_qspi0_dq_3_o_oval(), .io_pads_qspi0_dq_3_o_oe(),
    .io_pads_aon_erst_n_i_ival(rst_n), .io_pads_aon_pmu_dwakeup_n_i_ival(1'b1),
    .io_pads_aon_pmu_vddpaden_o_oval(), .io_pads_aon_pmu_padrst_o_oval(),
    .io_pads_bootrom_n_i_ival(1'b0), .io_pads_dbgmode0_n_i_ival(1'b1),
    .io_pads_dbgmode1_n_i_ival(1'b1), .io_pads_dbgmode2_n_i_ival(1'b1),
    .kse_ldr_cmd_valid(l_cmd_valid), .kse_ldr_cmd_ready(l_cmd_ready), .kse_ldr_cmd_addr(l_cmd_addr),
    .kse_ldr_cmd_read(l_cmd_read), .kse_ldr_cmd_wdata(l_cmd_wdata), .kse_ldr_cmd_wmask(l_cmd_wmask),
    .kse_ldr_rsp_valid(l_rsp_valid), .kse_ldr_rsp_ready(l_rsp_ready), .kse_ldr_rsp_rdata(l_rsp_rdata),
    .kse_ldr_rsp_err(l_rsp_err),
    .kse_clk(kclk), .kse_rst_n(krst_n));

  // ---------------- parameter loader (shared SRAM master 1) ----------------
  kse_param_loader #(.IMG_WORDS(IMG_WORDS), .IMAGE_FILE("kse_task_img.hex")) u_ldr (
    .clk(kclk), .rst_n(krst_n),
    .start(l_start), .base_addr(32'h0), .length(IMG_WORDS), .busy(l_busy), .done(l_done),
    .cmd_valid(l_cmd_valid), .cmd_ready(l_cmd_ready), .cmd_addr(l_cmd_addr), .cmd_read(l_cmd_read),
    .cmd_wdata(l_cmd_wdata), .cmd_wmask(l_cmd_wmask),
    .rsp_valid(l_rsp_valid), .rsp_ready(l_rsp_ready), .rsp_rdata(l_rsp_rdata), .rsp_err(l_rsp_err), .wptr(l_wptr));

  // ---------------- hierarchy ----------------
  `define MAIN u_soc.u_e203_subsys_top.u_e203_subsys_main
  `define CPU_TOP `MAIN.u_e203_cpu_top
  `define SYS `MAIN.u_kse_sys
  `define ENG `SYS.u_eng
  `define KSE `SYS.u_eng.u_kse
  `define ITCM `CPU_TOP.u_e203_srams.u_e203_itcm_ram.u_e203_itcm_gnrl_ram.g_macro
  `define DTCM `CPU_TOP.u_e203_srams.u_e203_dtcm_ram.u_e203_dtcm_gnrl_ram.g_macro

  // ---------------- backdoor: shared SRAM (PDK RAMSP4096X16: 512 x 128, mux 8) ----------------
  event sh_clear_ev, sh_dump_ev, eng_poison_ev;
  logic [15:0] sh_dump [32][2][4096];
  for (genvar g = 0; g < 32; g++) begin : g_shg
    always @(sh_clear_ev) begin
      for (int r = 0; r < 512; r++) begin
        `SYS.u_shram.u_bank.gen_grp[g].u_ram_lo.mem[r] = '0;
        `SYS.u_shram.u_bank.gen_grp[g].u_ram_hi.mem[r] = '0;
      end
    end
    always @(sh_dump_ev) begin
      for (int a = 0; a < 4096; a++) begin
        logic [127:0] rl, rh;
        rl = `SYS.u_shram.u_bank.gen_grp[g].u_ram_lo.mem[a >> 3];
        rh = `SYS.u_shram.u_bank.gen_grp[g].u_ram_hi.mem[a >> 3];
        for (int k = 0; k < 16; k++) begin
          sh_dump[g][0][a][k] = rl[8*k + (a & 7)];
          sh_dump[g][1][a][k] = rh[8*k + (a & 7)];
        end
      end
    end
  end
  function automatic logic [31:0] sh_word(input int off);
    int word, grp, ma;
    word = off >> 2;            // 128K x 32 flat array
    grp  = (word >> 12) & 5'h1F; // ram_addr[16:12]
    ma   = word & 12'hFFF;       // ram_addr[11:0]
    return {sh_dump[grp][1][ma], sh_dump[grp][0][ma]};
  endfunction

  // E203 ITCM (2 x 4 RAMSP4096X16) / DTCM (4 x 2) backdoor: ITCM loaded from
  // itcm_img (64-bit words), DTCM cleared
  event tcm_load_ev;
  logic [63:0] itcm_img [8192];
  for (genvar r = 0; r < 2; r++) begin : g_itr
    for (genvar c = 0; c < 4; c++) begin : g_itc
      always @(tcm_load_ev) begin
        for (int rr = 0; rr < 512; rr++) `ITCM.g_row[r].g_col[c].u_ram.mem[rr] = '0;
        for (int a = 0; a < 4096; a++) begin
          logic [15:0] w; logic [127:0] row;
          w = itcm_img[r*4096 + a][16*c +: 16];
          row = `ITCM.g_row[r].g_col[c].u_ram.mem[a >> 3];
          for (int k = 0; k < 16; k++) row[8*k + (a & 7)] = w[k];
          `ITCM.g_row[r].g_col[c].u_ram.mem[a >> 3] = row;
        end
      end
    end
  end
  for (genvar r = 0; r < 4; r++) begin : g_dtr
    for (genvar c = 0; c < 2; c++) begin : g_dtc
      always @(tcm_load_ev) for (int rr = 0; rr < 512; rr++) `DTCM.g_row[r].g_col[c].u_ram.mem[rr] = '0;
    end
  end

  // engine macros (PDK RAMSP1024X16: 256 x 64) poisoned to X between tasks
  for (genvar m = 0; m < 16; m++) begin : g_rs
    always @(eng_poison_ev) for (int r = 0; r < 256; r++) begin
      `KSE.u_rsa.g_mac[m].u_ram.mem[r] = 'x;
      `KSE.u_rsb.g_mac[m].u_ram.mem[r] = 'x;
    end
  end
  if (`KSE.ATT_VCTX) begin : g_optional_vctx
  for (genvar b = 0; b < 2; b++) begin : g_avb
    for (genvar m = 0; m < 16; m++) begin : g_avm
      always @(eng_poison_ev) begin
        for (int r = 0; r < $size(`KSE.g_vctx.u_rsvc.g_bank[b].g_mac[m].u_ram.mem); r++) begin
          `KSE.g_vctx.u_rsvc.g_bank[b].g_mac[m].u_ram.mem[r] = 'x;
        end
      end
    end
  end
  end
  if (`KSE.ATT_PROB && `KSE.PROB_BANKED) begin : g_optional_pbank
  for (genvar b = 0; b < 4; b++) begin : g_ppb
    for (genvar m = 0; m < ((b == 3) ? 2 : 16); m++) begin : g_ppm
      always @(eng_poison_ev)
        for (int r = 0; r < $size(`KSE.g_prob_banked.u_rsp.g_bank[b].g_mac[m].u_ram.mem); r++)
          `KSE.g_prob_banked.u_rsp.g_bank[b].g_mac[m].u_ram.mem[r] = 'x;
    end
  end
  end else if (`KSE.ATT_PROB) begin : g_optional_pplain
    for (genvar m = 0; m < 16; m++) begin : g_pm
      always @(eng_poison_ev) for (int r = 0; r < 256; r++)
        `KSE.g_prob_plain.u_rsp.g_mac[m].u_ram.mem[r] = 'x;
    end
  end
  if (`KSE.PF_DEPTH == 1024) begin : g_pf_1k
    for (genvar m = 0; m < 8; m++) begin : g_pf
      always @(eng_poison_ev) for (int r = 0; r < 256; r++) `KSE.u_pf.g_mac[m].g_1k.u_ram.mem[r] = 'x;
    end
  end else begin : g_pf_128
    for (genvar m = 0; m < 8; m++) begin : g_pf
      always @(eng_poison_ev) for (int r = 0; r < 128; r++) `KSE.u_pf.g_mac[m].g_128.u_ram.mem[r] = 'x;
    end
  end

  // ---------------- task data ----------------
  string DATA, FW, ACT, ACT_FILE;
  int    NTASK, TASK0, ACT_TASK;
  longint TMO;
  logic [31:0] img [IMG_WORDS];
  logic [31:0] exp_out [OUT_WORDS];
  int    task_sample [64], task_label [64];

  function automatic int count_lines(string path);
    int fd, n; string line;
    fd = $fopen(path, "r");
    if (fd == 0) return -1;
    n = 0;
    while ($fgets(line, fd)) if (line.len() > 1) n++;
    $fclose(fd);
    return n;
  endfunction

  // ---------------- monitors (all on the SoC bus clock) ----------------
  longint cyc;
  always @(posedge kclk) cyc <= cyc + 1;

  wire cpu_hs  = `SYS.cpu_cmd_valid && `SYS.cpu_cmd_ready;
  wire cpu_wr  = cpu_hs && !`SYS.cpu_cmd_read;
  wire [18:0] cpu_a = `SYS.cpu_cmd_addr[18:0];
  wire ldr_hs  = l_cmd_valid && l_cmd_ready;
  wire ldr_data_hs = ldr_hs && !l_cmd_read && l_cmd_addr < 4*IMG_WORDS;
  wire dma_hs  = `SYS.d_cmd_valid && `SYS.d_cmd_ready;
  wire dma_rd  = dma_hs && `SYS.d_cmd_read;
  wire dma_wr  = dma_hs && !`SYS.d_cmd_read;
  wire [18:0] dma_a = `SYS.d_cmd_addr[18:0];
  wire k_cmd_hs = `KSE.cmd_valid && `KSE.cmd_ready;
  wire k_done   = `KSE.done;
  wire core_wfi = `CPU_TOP.core_wfi;

  // Single shared-SRAM slave: exactly one bus master handshake and one SRAM
  // slave handshake per cycle, and at most one macro group (one low/high
  // 16-bit macro pair, i.e. one 32-bit word) accessed per cycle.
  wire        sram_hs      = `SYS.s_cmd_valid && `SYS.s_cmd_ready;
  wire [2:0]  bus_hs       = {cpu_hs, ldr_hs, dma_hs};
  wire [31:0] sram_grp_sel = `SYS.u_shram.u_bank.grp_sel;
`ifdef KSE_REL_LAG_4096
  localparam int REL_LAG = 4096;
`else
  localparam int REL_LAG = 0;
`endif

  // per-task state
  int     cur_task;
  logic   ldr_started;
  logic   in_task, in_win, start_seen, done_seen, task_fail;
  longint t_start_flag, t_ws, t_we, t_ldr_last, t_cmd [12], t_kdone [12], t_evt [12], t_irq_last;
  int     n_ldr, n_ldr_stall, n_cpu_sh, n_dma_rd, n_dma_wr, n_dma_bus_stall, n_dma_rule_wait;
  int     n_cpu_stall, n_sram_hs, n_sram_idle, n_bus_multi_hs, n_sram_hs_mismatch, n_sram_grp_ovf;
  int n_overlap_cmds;
  int qkv_overlap_steps[12];
  longint layer_ph[12][16];
  int     n_par_starve, n_in_starve, n_awake, n_irq_rise, n_kcmd, n_kdone, n_evt, n_rule_viol;
  int     n_rd_bad, n_wr_bad, n_in_rd, n_par_rd, n_eng_busy;
  logic [31:0] done_val;
  int     l0_ph [16], l1_ph [16];
  bit     loaded_seen [IMG_WORDS];
  int n_doorbell;
  bit     rd_seen [IMG_WORDS];
  bit     wr_seen [OUT_WORDS];
  logic   irq_q;
  logic [18:0] dma_pend_a;   // outstanding read address (one outstanding per master)
  logic   dma_pend_v;
  // release-rule reference (spec kse_shared_sram.md section 8), using the
  // registered loader status seen by the DMA in the same cycle
  function automatic bit rule_ok(input int a, input logic [31:0] wp, input logic [31:0] bs,
                                 input logic v, input logic dn);
    return v && (a >= bs) && (a + 4 <= wp) && ((a + REL_LAG <= wp) || dn);
  endfunction

  always @(posedge kclk) begin
    if (in_task && krst_n) begin
      // window markers
      if (cpu_wr && cpu_a == FLAG_START && !start_seen) begin
        start_seen <= 1; t_start_flag <= cyc;
        if (`SYS.cpu_cmd_wdata !== 32'h1) begin task_fail <= 1; $display("ERROR task FLAG_START value %h", `SYS.cpu_cmd_wdata); end
      end
      if (ldr_hs) begin
        if (!in_win && !done_seen) begin in_win <= 1; t_ws <= cyc; end
        if (ldr_data_hs) begin
          if (l_cmd_addr !== 4*n_ldr || l_cmd_wmask !== 4'hf || l_cmd_wdata !== img[n_ldr])
            begin task_fail <= 1; $display("ERROR loader data order/mask/value"); end
          loaded_seen[l_cmd_addr/4] <= 1;
          n_ldr++; t_ldr_last <= cyc;
        end else begin
          n_doorbell++;
          if (l_cmd_addr == 32'h40080004 && l_cmd_wdata > 4*n_ldr)
            begin task_fail <= 1; $display("ERROR early doorbell exceeds actual data writes"); end
        end
      end
      if (l_cmd_valid && !l_cmd_ready) n_ldr_stall++;
      if (cpu_wr && cpu_a == FLAG_DONE && !done_seen) begin
        done_seen <= 1; in_win <= 0; t_we <= cyc; done_val <= `SYS.cpu_cmd_wdata;
      end
      if (cpu_hs) n_cpu_sh++;
      // DMA reads: address coverage and release rule
      if (dma_rd) begin
        int a; a = dma_a;
        n_dma_rd++;
        // reference: the shared SRAM's registered watermark and the loader's own done
        if (!rule_ok(a, `SYS.wptr, `SYS.base, `SYS.wptr_valid, `SYS.ldr_done) || a >= 4*IMG_WORDS || !loaded_seen[a/4]) begin
          n_rule_viol++;
          if (n_rule_viol < 5) $display("ERROR DMA read 0x%05h violates the release rule (wptr 0x%05h done %0d)", a, `SYS.wptr, l_done);
        end
        if (a < 4 * IMG_WORDS) begin
          if (rd_seen[a/4]) begin n_rd_bad++; if (n_rd_bad < 5) $display("ERROR DMA read 0x%05h twice", a); end
          rd_seen[a/4] = 1;
          if (a < 4 * IN_WORDS) n_in_rd++; else n_par_rd++;
        end else begin
          n_rd_bad++; if (n_rd_bad < 5) $display("ERROR DMA read outside the loader image: 0x%05h", a);
        end
      end
      // read data must be the loader's word
      if (`SYS.d_rsp_valid && `SYS.d_rsp_ready && dma_pend_v) begin
        if (dma_pend_a < 4 * IMG_WORDS && `SYS.d_rsp_rdata !== img[dma_pend_a/4]) begin
          n_rd_bad++;
          if (n_rd_bad < 5) $display("ERROR DMA read 0x%05h returned %h, loader wrote %h", dma_pend_a, `SYS.d_rsp_rdata, img[dma_pend_a/4]);
        end
        if (`SYS.d_rsp_err) begin n_rd_bad++; $display("ERROR DMA response error"); end
      end
      if (`SYS.d_rsp_valid && `SYS.d_rsp_ready) dma_pend_v <= 0;
      if (dma_rd) begin dma_pend_v <= 1; dma_pend_a <= dma_a; end
      // DMA writes: exactly the output region, once each, golden data
      if (dma_wr) begin
        int a; a = dma_a;
        n_dma_wr++;
        if (a >= OUT_OFF && a < OUT_OFF + 4 * OUT_WORDS && `SYS.d_cmd_wmask == 4'hF) begin
          if (wr_seen[(a-OUT_OFF)/4]) begin n_wr_bad++; $display("ERROR DMA wrote 0x%05h twice", a); end
          wr_seen[(a-OUT_OFF)/4] = 1;
        end else begin
          n_wr_bad++; if (n_wr_bad < 5) $display("ERROR DMA write outside the output region: 0x%05h mask %h", a, `SYS.d_cmd_wmask);
        end
      end
      if (in_win) begin
        if (`SYS.d_cmd_valid && !`SYS.d_cmd_ready) n_dma_bus_stall++;
        if (`SYS.cpu_cmd_valid && !`SYS.cpu_cmd_ready) n_cpu_stall++;
        // one bus transaction per cycle and one SRAM slave handshake per cycle
        if (sram_hs) n_sram_hs++; else n_sram_idle++;
        if ($countones(bus_hs) > 1) begin
          n_bus_multi_hs++;
          if (n_bus_multi_hs < 5)
            $display("ERROR %0d master handshakes in one cycle (cpu %0b ldr %0b dma %0b)",
                     $countones(bus_hs), cpu_hs, ldr_hs, dma_hs);
        end
        if (sram_hs !== (|bus_hs)) begin
          n_sram_hs_mismatch++;
          if (n_sram_hs_mismatch < 5)
            $display("ERROR SRAM slave handshake %0b does not match a master handshake %0b", sram_hs, |bus_hs);
        end
        if ($countones(sram_grp_sel) > 1) begin
          n_sram_grp_ovf++;
          if (n_sram_grp_ovf < 5)
            $display("ERROR %0d SRAM macro groups accessed in one cycle", $countones(sram_grp_sel));
        end
        // parameter/input reads wanted but held back by the release rule
        if ((`ENG.p_left != 0 && `ENG.pb_cnt + `ENG.p_resv < 4 &&
             !rule_ok({`ENG.p_ptr, 2'b00}, `ENG.ldr_wptr, `ENG.ldr_base, `ENG.ldr_wptr_valid, `ENG.ldr_done)) ||
            (`ENG.in_left != 0 && `ENG.ib_cnt + `ENG.i_resv < 4 &&
             !rule_ok({`ENG.in_ptr, 2'b00}, `ENG.ldr_wptr, `ENG.ldr_base, `ENG.ldr_wptr_valid, `ENG.ldr_done)))
          n_dma_rule_wait++;

        // engine waiting for data
        if (`KSE.busy && `KSE.pf_level == 0 && `KSE.param_ready && !`KSE.param_valid) n_par_starve++;
        if (`KSE.act_in_ready && !`KSE.act_in_valid) n_in_starve++;
        if (`KSE.busy) begin
          n_eng_busy++;
          layer_ph[`KSE.layer][`KSE.phase]++;
          if (`KSE.prev_ln2_pending && `KSE.phase == 2 && `KSE.u_mm.u_arr.s2_valid)
            qkv_overlap_steps[`KSE.layer]++;
        end
        if (n_kcmd == 1 && n_kdone == 0) l0_ph[`KSE.phase]++;   // layer-0 phase profile
        if (n_kcmd == 2 && n_kdone == 1) l1_ph[`KSE.phase]++;   // layer-1 phase profile
        if (!core_wfi) n_awake++;
      end
      irq_q <= `SYS.irq;
      if (`SYS.irq && !irq_q) begin n_irq_rise++; t_irq_last <= cyc; end
      if (k_cmd_hs) begin
        if (n_kcmd < 12) t_cmd[n_kcmd] <= cyc;
        if (`KSE.cmd_layer != n_kcmd[3:0]) begin task_fail <= 1; $display("ERROR command %0d carries layer %0d", n_kcmd, `KSE.cmd_layer); end
        if (`KSE.cmd_in_en != (n_kcmd == 0) || `KSE.cmd_out_en != (n_kcmd == 11)) begin
          task_fail <= 1; $display("ERROR command %0d in_en/out_en %0d/%0d", n_kcmd, `KSE.cmd_in_en, `KSE.cmd_out_en);
        end
        if (`KSE.busy) n_overlap_cmds++;
        n_kcmd++;
      end
      if (k_done) begin if (n_kdone < 12) t_kdone[n_kdone] <= cyc; n_kdone++; end
      if (`ENG.layer_evt) begin if (n_evt < 12) t_evt[n_evt] <= cyc; n_evt++; end
    end
  end

  // loader start on the firmware's FLAG_START write (driven away from the edge)
  always @(negedge kclk) l_start <= in_task && start_seen && !l_busy && !l_done && !ldr_started;
  always @(posedge kclk) if (l_start) ldr_started <= 1;

  // ---------------- activity dump hooks ----------------
  // +ACT_TASK=k: window of task k only; +ACT_TASK=-1: SAIF accumulated over the
  // windows of every task run (toggle counting paused between windows), written
  // once at the end; its DURATION is the sum of the windows.
  logic act_on, act_region_set;
  always @(posedge kclk) begin
    if (ACT != "" && (cur_task == ACT_TASK || ACT_TASK < 0)) begin
      if (in_win && !act_on) begin
        act_on <= 1;
        if (ACT == "saif") begin
          // rtl_on: monitor RTL registers/variables as well as nets (the VCS
          // default monitors nets only, which drops all SystemVerilog logic
          // variables, i.e. almost the whole engine)
          if (!act_region_set) begin $set_gate_level_monitoring("rtl_on"); $set_toggle_region(tb_kse_soc.u_soc); act_region_set <= 1; end
          $toggle_start();
        end
`ifdef KSE_FSDB
        if (ACT == "fsdb") begin
          if (!act_region_set) begin $fsdbDumpfile(ACT_FILE); $fsdbDumpvars(0, tb_kse_soc.u_soc, "+mda"); act_region_set <= 1; end
          $fsdbDumpon;
        end
`endif
        $display("ACTIVITY %s on for task %0d at cycle %0d t_ns=%0.3f", ACT, cur_task, cyc, $realtime);
      end
      if (done_seen && act_on) begin
        act_on <= 0;
        if (ACT == "saif") $toggle_stop();
`ifdef KSE_FSDB
        if (ACT == "fsdb") $fsdbDumpoff;
`endif
        $display("ACTIVITY %s off at cycle %0d t_ns=%0.3f", ACT, cyc, $realtime);
      end
    end
  end
  task automatic act_finish();
    if (ACT == "saif" && act_region_set) begin
      $toggle_report(ACT_FILE, 1.0e-9, "tb_kse_soc.u_soc");
      $display("ACTIVITY saif written to %s", ACT_FILE);
    end
  endtask

  // ---------------- task sequence ----------------
  longint tot_win, worst_win, best_win;
  int n_pass, n_fail;

  task automatic reset_and_clear(int t);
    rst_n = 0;
    in_task = 0;
    repeat (20) @(posedge clk);
    // shared SRAM task data and parameter areas: cleared; engine state: reset +
    // macros poisoned; firmware reloaded (computer-side preparation, not timed)
    -> sh_clear_ev; -> eng_poison_ev;
    #0;
    for (int i = 0; i < 8192; i++) itcm_img[i] = '0;
    $readmemh(FW, itcm_img);
    -> tcm_load_ev;
    #0;
    for (int i = 0; i < IMG_WORDS; i++) begin img[i] = 'x; u_ldr.mem[i] = 'x; end
    $readmemh($sformatf("%s/task_%02d_img.hex", DATA, t), img);
    $readmemh($sformatf("%s/task_%02d_img.hex", DATA, t), u_ldr.mem);
    for (int i = 0; i < OUT_WORDS; i++) exp_out[i] = 'x;
    $readmemh($sformatf("%s/task_%02d_out.hex", DATA, t), exp_out);
    for (int i = 0; i < IMG_WORDS; i++) rd_seen[i] = 0;
    for (int i = 0; i < OUT_WORDS; i++) wr_seen[i] = 0;
    in_win = 0; start_seen = 0; done_seen = 0; task_fail = 0; ldr_started = 0;
    n_doorbell = 0;
    foreach (loaded_seen[i]) loaded_seen[i] = 0;
    n_ldr = 0; n_ldr_stall = 0; n_cpu_sh = 0; n_dma_rd = 0; n_dma_wr = 0; n_dma_bus_stall = 0;
    n_dma_rule_wait = 0; n_par_starve = 0; n_in_starve = 0; n_awake = 0; n_irq_rise = 0;
    n_cpu_stall = 0; n_sram_hs = 0; n_sram_idle = 0; n_bus_multi_hs = 0;
    n_sram_hs_mismatch = 0; n_sram_grp_ovf = 0;
    for (int l = 0; l < 12; l++) begin
      qkv_overlap_steps[l] = 0;
      for (int p = 0; p < 16; p++) layer_ph[l][p] = 0;
    end
    n_overlap_cmds = 0; n_kcmd = 0; n_kdone = 0; n_evt = 0; n_rule_viol = 0; n_rd_bad = 0; n_wr_bad = 0;
    for (int k = 0; k < 16; k++) begin l0_ph[k] = 0; l1_ph[k] = 0; end
    n_in_rd = 0; n_par_rd = 0; n_eng_busy = 0; dma_pend_v = 0; irq_q = 0; done_val = 'x;
    t_start_flag = -1; t_ws = -1; t_we = -1; t_ldr_last = -1; t_irq_last = -1;
    #1;
    rst_n = 1;
    in_task = 1;
  endtask

  task automatic run_task(int t);
    longint t_rel, win;
    int nerr, ncmp, nbad;
    reset_and_clear(t);
    t_rel = cyc;
    // wait for FLAG_DONE or timeout
    while (!done_seen && (cyc - t_rel) < TMO) @(posedge kclk);
    repeat (4) @(posedge kclk);
    nerr = 0;
    if (!done_seen) begin nerr++; $display("ERROR task %0d TIMEOUT after %0d cycles (layers done %0d)", t, TMO, n_evt); end
    if (done_val !== PASS_CODE) begin nerr++; $display("ERROR task %0d FLAG_DONE value %h", t, done_val); end
    // output compare from the shared SRAM macros
    -> sh_dump_ev; #0; #1;
    ncmp = 0; nbad = 0;
    for (int w = 0; w < OUT_WORDS; w++) begin
      logic [31:0] got; got = sh_word(OUT_OFF + 4 * w);
      for (int k = 0; k < 4; k++) begin
        ncmp++;
        if (got[8*k +: 8] !== exp_out[w][8*k +: 8]) begin
          nbad++;
          if (nbad <= 8) $display("MISMATCH task %0d output byte %0d got %h exp %h", t, 4*w + k, got[8*k +: 8], exp_out[w][8*k +: 8]);
        end
      end
      if (!wr_seen[w]) begin nerr++; if (nerr < 5) $display("ERROR task %0d output word %0d never written by the DMA", t, w); end
    end
    if (ncmp != 4 * OUT_WORDS) begin nerr++; $display("ERROR compared %0d bytes", ncmp); end
    for (int i = 0; i < IMG_WORDS; i++) if (!rd_seen[i]) begin nerr++; if (nerr < 8) $display("ERROR image word %0d never read by the DMA", i); end
    $display("DOORBELLS task=%0d count=%0d", t, n_doorbell);
    if (n_doorbell != (IMG_WORDS+u_ldr.publish_words-1)/u_ldr.publish_words+2)
      begin nerr++; $display("ERROR doorbell count"); end
    if (n_ldr != IMG_WORDS)   begin nerr++; $display("ERROR loader wrote %0d words, expected %0d", n_ldr, IMG_WORDS); end
    if (!l_done)              begin nerr++; $display("ERROR loader not done"); end
    if (n_in_rd != IN_WORDS || n_par_rd != PAR_WORDS) begin nerr++; $display("ERROR DMA read %0d input / %0d parameter words", n_in_rd, n_par_rd); end
    if (n_dma_wr != OUT_WORDS) begin nerr++; $display("ERROR DMA wrote %0d words, expected %0d", n_dma_wr, OUT_WORDS); end
    $display("CROSS_LAYER task=%0d early_commands=%0d", t, n_overlap_cmds);
    for (int l = 1; l < 12; l++) begin
      $display("CROSS_MAC task=%0d layer=%0d steps=%0d", t, l, qkv_overlap_steps[l]);
      if (`KSE.USE_SHADOW && qkv_overlap_steps[l] == 0) begin nerr++; $display("ERROR no next-layer QKV computation while previous LN2 active"); end
    end
    for (int l = 0; l < 12; l++)
      for (int p = 0; p < 16; p++) if (layer_ph[l][p])
        $display("LAYER_PHASE task=%0d layer=%0d phase=%0d cycles=%0d", t,l,p,layer_ph[l][p]);
    if (n_overlap_cmds != 11) begin nerr++; $display("ERROR expected 11 early layer handshakes"); end
    if (n_kcmd != 12 || n_kdone != 12 || n_evt != 12) begin nerr++; $display("ERROR commands %0d, kse done %0d, layer events %0d", n_kcmd, n_kdone, n_evt); end
    if (n_rule_viol || n_rd_bad || n_wr_bad || task_fail) begin nerr++; $display("ERROR rule violations %0d, bad reads %0d, bad writes %0d", n_rule_viol, n_rd_bad, n_wr_bad); end
    if (n_bus_multi_hs || n_sram_hs_mismatch || n_sram_grp_ovf) begin
      nerr++;
      $display("ERROR bus/slave port assertions: multi_hs %0d, hs_mismatch %0d, macro_group_overflow %0d",
               n_bus_multi_hs, n_sram_hs_mismatch, n_sram_grp_ovf);
    end
    if (!(t_ws >= 0 && t_we > t_ws)) begin nerr++; $display("ERROR window markers missing"); end
    win = t_we - t_ws;
    $display("TASK %0d sample=%0d label=%0d window_cycles=%0d compared_bytes=%0d mismatches=%0d errors=%0d %s",
             t, task_sample[t], task_label[t], win, ncmp, nbad, nerr, (nbad == 0 && nerr == 0) ? "PASS" : "FAIL");
    $display("BREAKDOWN task=%0d start_flag_to_first_write=%0d first_write_to_cmd0=%0d loader_span=%0d loader_words=%0d loader_stall=%0d",
             t, t_ws - t_start_flag, t_cmd[0] - t_ws, t_ldr_last - t_ws + 1, n_ldr, n_ldr_stall);
    $display("BREAKDOWN task=%0d engine_cmd0_to_done11=%0d kse_busy=%0d drain_done11_to_evt=%0d evt11_to_flag=%0d awake_cycles=%0d irqs=%0d",
             t, t_kdone[11] - t_cmd[0], n_eng_busy, t_evt[11] - t_kdone[11], t_we - t_evt[11], n_awake, n_irq_rise);
    $display("BREAKDOWN task=%0d dma_reads=%0d dma_writes=%0d dma_bus_stall=%0d dma_rule_wait=%0d param_starve=%0d act_in_starve=%0d cpu_shram_accesses=%0d cpu_stall=%0d",
             t, n_dma_rd, n_dma_wr, n_dma_bus_stall, n_dma_rule_wait, n_par_starve, n_in_starve, n_cpu_sh, n_cpu_stall);
    $display("BUS task=%0d sram_port_busy=%0d sram_port_idle=%0d window_cycles=%0d utilization=%.4f master_hs_multi=%0d sram_hs_mismatch=%0d macro_group_overflow=%0d",
             t, n_sram_hs + 1, n_sram_idle, win, (1.0 * (n_sram_hs + 1)) / (win + 1),
             n_bus_multi_hs, n_sram_hs_mismatch, n_sram_grp_ovf);
    for (int k = 0; k < 16; k++) if (l0_ph[k] || l1_ph[k])
      $display("PHASE task=%0d phase=%0d layer0_cycles=%0d layer1_cycles=%0d", t, k, l0_ph[k], l1_ph[k]);
    for (int l = 0; l < 12; l++)
      $display("LAYER task=%0d layer=%0d cmd=%0d done=%0d cycles=%0d gap_from_prev_done=%0d", t, l, t_cmd[l] - t_ws, t_kdone[l] - t_ws,
               t_kdone[l] - t_cmd[l], (l == 0) ? 0 : t_cmd[l] - t_kdone[l-1]);
    if (nbad == 0 && nerr == 0) begin n_pass++; tot_win += win; if (win > worst_win) worst_win = win; if (win < best_win) best_win = win; end
    else n_fail++;
  endtask

  // Negative test hooks.  +NEG_FORCE_DONE is the historical 4 KB-lag test
  // (only meaningful with KSE_REL_LAG_4096).  +NEG_EARLY_READ makes the DMA
  // believe the whole window is committed, so it reads words the loader has
  // not written; the bench must flag the release-rule and data violations.
  initial if ($test$plusargs("NEG_FORCE_DONE")) force `ENG.ldr_done = 1'b1;
  initial if ($test$plusargs("NEG_EARLY_READ")) begin
    force `ENG.ldr_wptr = 32'h0007_FFFC;
    force `ENG.ldr_wptr_valid = 1'b1;
  end

  initial begin
    int fd, a, b, c, n;
    if (!$value$plusargs("DATA=%s", DATA)) DATA = ".";
    if (!$value$plusargs("FW=%s", FW)) FW = "kse_fw.itcm.hex";
    if (!$value$plusargs("NTASK=%d", NTASK)) NTASK = 12;
    if (!$value$plusargs("TASK0=%d", TASK0)) TASK0 = 0;
    if (!$value$plusargs("TIMEOUT=%d", TMO)) TMO = 400000;
    if (!$value$plusargs("ACT=%s", ACT)) ACT = "";
    if (!$value$plusargs("ACT_TASK=%d", ACT_TASK)) ACT_TASK = 0;
    if (!$value$plusargs("ACT_FILE=%s", ACT_FILE)) ACT_FILE = (ACT == "fsdb") ? "kse_soc_window.fsdb" : "kse_soc_window.saif";
    cyc = 0; n_pass = 0; n_fail = 0; tot_win = 0; worst_win = 0; best_win = 64'h7fffffffffffffff; act_on = 0; act_region_set = 0;
    in_task = 0; cur_task = -1;
    n = 0;
    fd = $fopen({DATA, "/tasks.txt"}, "r");
    if (fd == 0) $fatal(1, "TEST FAILED: cannot open %s/tasks.txt", DATA);
    while ($fscanf(fd, "%d %d %d", a, b, c) == 3) begin task_sample[a] = b; task_label[a] = c; n++; end
    $fclose(fd);
    if (TASK0 + NTASK > n) $fatal(1, "TEST FAILED: tasks.txt has %0d tasks", n);
    for (int t = TASK0; t < TASK0 + NTASK; t++) begin
      if (count_lines($sformatf("%s/task_%02d_img.hex", DATA, t)) != IMG_WORDS ||
          count_lines($sformatf("%s/task_%02d_out.hex", DATA, t)) != OUT_WORDS)
        $fatal(1, "TEST FAILED: task %0d data files have the wrong length", t);
    end
    if (count_lines(FW) <= 0) $fatal(1, "TEST FAILED: firmware image %s missing", FW);
    #10;
    for (int t = TASK0; t < TASK0 + NTASK; t++) begin
      cur_task = t;
      run_task(t);
    end
    $display("==== KSE SoC regression ====");
    $display("SUMMARY tasks=%0d pass=%0d fail=%0d", NTASK, n_pass, n_fail);
    if (n_pass > 0)
      $display("SUMMARY total_window_cycles=%0d mean_window_cycles=%.1f min=%0d max=%0d throughput_at_150MHz=%.2f tasks/s",
               tot_win, real'(tot_win) / n_pass, best_win, worst_win, F_MHZ * 1.0e6 * n_pass / real'(tot_win));
    act_finish();
    if (n_fail == 0 && n_pass == NTASK) $display("TEST PASSED"); else $display("TEST FAILED");
    $finish;
  end
endmodule
