`timescale 1ns/1ps
// WP8 KSSOC-008 UVM environment: real E203 firmware drives the peripherals;
// the environment only observes buses/pads, drives the UART0 RX pad and
// judges the result with an independent scoreboard.
package wp8_soc_periph_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  localparam int NAPB = 10;
  localparam int NICB = 8;
  localparam int UART0_APB = 2;
  localparam int MAILBOX_ICB = 7;
  localparam int UART0_DIV = 15;               // firmware divisor latch value
  localparam int BIT_CYCLES = UART0_DIV + 1;   // uart_tx/uart_rx bit period
  localparam logic [31:0] MB_OFF = 32'h7E000;  // shared-SRAM window offset
  localparam logic [31:0] PHASE_RX_READY = 32'h5752_0001;
  localparam logic [31:0] STATUS_PASS = 32'h600D_0000;
  localparam int NREC = 59;

  string apb_name[NAPB] = '{"GPIOA", "GPIOB", "UART0", "UART1", "UART2", "SPI1", "SPI2", "I2C0", "I2C1", "PWM"};
  string icb_name[NICB] = '{"AON", "HCLKGEN", "QSPI0", "EXPL_AXI", "KSE_MMIO", "CLINT", "PLIC", "SHRAM"};
  logic [31:0] icb_base[NICB] = '{32'h1000_0000, 32'h1000_8000, 32'h1001_4000, 32'h1004_1000,
                                  32'h1100_0000, 32'h0200_0000, 32'h0C00_0000, 32'h4000_0000};
  logic [31:0] apb_base[NAPB] = '{32'h1001_2000, 32'h1004_0000, 32'h1001_3000, 32'h1002_3000, 32'h1003_3000,
                                  32'h1002_4000, 32'h1003_4000, 32'h1002_5000, 32'h1003_5000, 32'h1001_5000};

  class wp8_bus_txn extends uvm_sequence_item;
    bit apb;            // 1 = APB access phase, 0 = ICB command/response pair
    int port;
    bit read;
    logic [31:0] addr, wdata, rdata;
    logic err;
    `uvm_object_utils(wp8_bus_txn)
    function new(string name = "wp8_bus_txn"); super.new(name); endfunction
  endclass

  class wp8_byte_txn extends uvm_sequence_item;
    logic [7:0] data;
    `uvm_object_utils(wp8_byte_txn)
    function new(string name = "wp8_byte_txn"); super.new(name); endfunction
  endclass

  // ---------------- passive bus monitor (all APB and ICB ports) ----------------
  class wp8_bus_monitor extends uvm_monitor;
    `uvm_component_utils(wp8_bus_monitor)
    virtual wp8_soc_periph_if v;
    uvm_analysis_port #(wp8_bus_txn) ap;
    int icb_apb_cmd[NAPB], icb_apb_rsp[NAPB], apb_access[NAPB], zero_latency[NICB];
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      ap = new("ap", this);
      if (!uvm_config_db#(virtual wp8_soc_periph_if)::get(this, "", "vif", v)) `uvm_fatal("NOVIF", "bus monitor")
    endfunction
    task run_phase(uvm_phase phase);
      wp8_bus_txn pend[NICB][$];
      forever begin
        @(posedge v.clk);
        if (v.rst_n !== 1'b1) continue;
        for (int p = 0; p < NAPB; p++) begin
          if (v.icv[p] === 1'b1 && v.icr[p] === 1'b1) icb_apb_cmd[p]++;
          if (v.irv[p] === 1'b1 && v.irr[p] === 1'b1) icb_apb_rsp[p]++;
          if (v.psel[p] === 1'b1 && v.penable[p] === 1'b1) begin
            wp8_bus_txn t = wp8_bus_txn::type_id::create("apb");
            t.apb = 1; t.port = p; t.read = !v.pwrite[p]; t.addr = v.paddr[p];
            t.wdata = v.pwdata[p]; t.rdata = v.prdata[p]; t.err = 0;
            apb_access[p]++;
            ap.write(t);
          end
        end
        for (int p = 0; p < NICB; p++) begin
          wp8_bus_txn c = null;
          if (v.cv[p] === 1'b1 && v.cr[p] === 1'b1) begin
            c = wp8_bus_txn::type_id::create("icb");
            c.apb = 0; c.port = p; c.read = v.rd[p]; c.addr = v.addr[p]; c.wdata = v.wdata[p];
            if (v.rd[p] !== 1'b1 && v.wmask[p] !== 4'hf)
              `uvm_error("WP8_ICB", $sformatf("%s partial write mask=%h addr=%08h", icb_name[p], v.wmask[p], v.addr[p]))
          end
          if (v.rv[p] === 1'b1 && v.rr[p] === 1'b1) begin
            // in-order responses; a same-cycle response with an empty queue
            // answers this cycle's command (zero-latency slave, e.g. CLINT)
            wp8_bus_txn t = pend[p].size() ? pend[p].pop_front() : c;
            if (t == null) `uvm_error("WP8_ICB", $sformatf("%s response without command", icb_name[p]))
            else begin
              if (t == c) begin c = null; zero_latency[p]++; end
              t.rdata = v.rdata[p]; t.err = v.rerr[p];
              ap.write(t);
            end
          end
          if (c != null) pend[p].push_back(c);
        end
      end
    endtask
  endclass

  // ---------------- UART0 TX pad decoder (GPIOA pad 17) ----------------
  class wp8_uart_tx_monitor extends uvm_monitor;
    `uvm_component_utils(wp8_uart_tx_monitor)
    virtual wp8_soc_periph_if v;
    uvm_analysis_port #(wp8_byte_txn) ap;
    int frames, framing_bad;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      ap = new("ap", this);
      if (!uvm_config_db#(virtual wp8_soc_periph_if)::get(this, "", "vif", v)) `uvm_fatal("NOVIF", "uart tx monitor")
    endfunction
    function logic pad(); return v.gpioA_oval[17]; endfunction
    task run_phase(uvm_phase phase);
      // Arm once the pad is a driven output at idle high.
      do @(posedge v.clk); while (!(v.rst_n === 1'b1 && v.gpioA_oe[17] === 1'b1 && pad() === 1'b1));
      `uvm_info("WP8_UART_TX", "pad 17 armed (output enabled, idle high)", UVM_LOW)
      forever begin
        logic [7:0] b;
        @(posedge v.clk);
        if (v.gpioA_oe[17] !== 1'b1 || pad() === 1'bx || pad() === 1'bz)
          `uvm_error("WP8_UART_TX", $sformatf("pad 17 not a driven output oe=%b val=%b", v.gpioA_oe[17], pad()))
        if (pad() !== 1'b0) continue;
        // falling edge: sample mid start, mid data bits, mid stop
        repeat (BIT_CYCLES / 2) @(posedge v.clk);
        if (pad() !== 1'b0) begin framing_bad++; `uvm_error("WP8_UART_TX", "start bit not low at mid-bit"); continue; end
        for (int k = 0; k < 8; k++) begin
          repeat (BIT_CYCLES) @(posedge v.clk);
          b[k] = pad();
        end
        repeat (BIT_CYCLES) @(posedge v.clk);
        frames++;
        if (pad() !== 1'b1 || $isunknown(b)) begin
          framing_bad++;
          `uvm_error("WP8_UART_TX", $sformatf("frame %0d bad stop/unknown data stop=%b data=%b", frames - 1, pad(), b))
        end
        begin
          wp8_byte_txn t = wp8_byte_txn::type_id::create("tx");
          t.data = b;
          ap.write(t);
        end
      end
    endtask
  endclass

  // ---------------- UART0 RX pad driver (GPIOA pad 16) ----------------
  class wp8_uart_rx_driver extends uvm_component;
    `uvm_component_utils(wp8_uart_rx_driver)
    virtual wp8_soc_periph_if v;
    byte unsigned bytes[$];
    int sent;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual wp8_soc_periph_if)::get(this, "", "vif", v)) `uvm_fatal("NOVIF", "uart rx driver")
    endfunction
    task send_all();
      repeat (4 * BIT_CYCLES) @(posedge v.clk);
      foreach (bytes[i]) begin
        logic [9:0] frame = {1'b1, bytes[i], 1'b0};
        for (int k = 0; k < 10; k++) begin
          v.uart0_rx_pad <= frame[k];
          repeat (BIT_CYCLES) @(posedge v.clk);
        end
        repeat (2 * BIT_CYCLES) @(posedge v.clk);
        sent++;
      end
    endtask
  endclass

  `uvm_analysis_imp_decl(_bus)
  `uvm_analysis_imp_decl(_tx)

  typedef struct {bit read; logic [31:0] off; logic [31:0] data;} wp8_acc_t;

  // ---------------- scoreboard ----------------
  class wp8_soc_periph_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(wp8_soc_periph_scoreboard)
    uvm_analysis_imp_bus #(wp8_bus_txn, wp8_soc_periph_scoreboard) bus_imp;
    uvm_analysis_imp_tx #(wp8_byte_txn, wp8_soc_periph_scoreboard) tx_imp;
    byte unsigned msg[$], msg_expected[$], rx_bytes[$];
    logic [7:0] tx_seen[$], thr_seen[$], rbr_seen[$];
    wp8_acc_t apb_w[NAPB][$], apb_r[NAPB][$], icb_w[NICB][$], icb_r[NICB][$];
    logic [31:0] exp_rec[int];
    logic [31:0] rec_id[$], rec_val[$];
    logic [31:0] mb_status, mb_count;
    bit status_seen, rx_ready_seen, corrupt, uart0_dlab, strict_lsr;
    int mailbox_writes, icb_errors;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      string s = "KSSOC-008 UART0 OK";
      logic [31:0] lsr_boot;
      bus_imp = new("bus_imp", this);
      tx_imp = new("tx_imp", this);
      corrupt = $test$plusargs("WP8_SOC_CORRUPT");
      foreach (s[i]) msg.push_back(s[i]);
      msg.push_back(8'h0D); msg.push_back(8'h0A);
      strict_lsr = $test$plusargs("WP8_SOC_STRICT_BOOT_LSR");
      // Finding F1: the upstream GPIO input synchroniser resets to 0 while the RX
      // pads idle high, so each UART receives one spurious byte at reset release
      // and its first LSR read is 0x61.  +WP8_SOC_STRICT_BOOT_LSR expects the
      // documented reset value 0x60 instead (minimal reproduction of F1).
      lsr_boot = strict_lsr ? 32'h60 : 32'h61;
      msg_expected = msg;
      if (corrupt) msg_expected[0] ^= 8'h01;   // designated negative control
      rx_bytes = '{8'hA5, 8'h3C, 8'h00, 8'hFF};
      // Expected observations, derived independently from the upstream RTL.
      exp_rec[1] = lsr_boot; exp_rec[59] = 32'h60; exp_rec[2] = 0; exp_rec[3] = 0; exp_rec[4] = 20;
      exp_rec[5] = UART0_DIV; exp_rec[6] = 0; exp_rec[7] = 32'h83; exp_rec[8] = 32'h03;
      exp_rec[9] = 32'h05; exp_rec[10] = 0; exp_rec[11] = 32'h2_0000; exp_rec[12] = 32'h2_0000;
      exp_rec[13] = 32'h3_0000; exp_rec[14] = 32'h5_0000; exp_rec[15] = 32'h60;
      foreach (rx_bytes[i]) exp_rec[16 + i] = rx_bytes[i];
      exp_rec[20] = 32'h60;
      exp_rec[21] = lsr_boot; exp_rec[22] = 32'h5A; exp_rec[23] = 32'h01; exp_rec[24] = 32'h07; exp_rec[25] = 32'h02;
      exp_rec[26] = lsr_boot; exp_rec[27] = 32'hC3; exp_rec[28] = 32'h7E; exp_rec[29] = 32'h1B; exp_rec[30] = 32'h04;
      exp_rec[31] = 32'h5A01_C3A5; exp_rec[32] = 32'hA5A5_5A5A;
      exp_rec[33] = 3; exp_rec[34] = 32'hA5; exp_rec[35] = 3;
      exp_rec[36] = 32'h00FF_0010; exp_rec[37] = 32'h0003_1234;
      exp_rec[38] = 32'h1234_5678; exp_rec[39] = 32'hCAFE_F00D; exp_rec[40] = 0;
      exp_rec[41] = 32'h8765_4321; exp_rec[42] = 32'h0BAD_F00D;
      exp_rec[43] = 0; exp_rec[44] = 32'hBEEF; exp_rec[45] = 32'h5A;
      exp_rec[46] = 32'h1234; exp_rec[47] = 32'hA5; exp_rec[48] = 0;
      exp_rec[49] = 32'h4000_0000; exp_rec[50] = 32'h0004_4642; exp_rec[51] = 32'h100;
      exp_rec[52] = 32'hC0FF_EE01; exp_rec[53] = 0; exp_rec[54] = 32'h4B53_4531;
      exp_rec[55] = 32'hFFFF_FFFF; exp_rec[56] = 32'h89AB_CDEF; exp_rec[57] = 5; exp_rec[58] = 0;
    endfunction

    function void write_tx(wp8_byte_txn t);
      tx_seen.push_back(t.data);
    endfunction

    function void write_bus(wp8_bus_txn t);
      wp8_acc_t a;
      a.read = t.read;
      a.data = t.read ? t.rdata : t.wdata;
      if (t.apb) begin
        if ((t.addr & 32'hFFFF_F000) != apb_base[t.port])
          `uvm_error("WP8_APB", $sformatf("%s access outside its slot addr=%08h", apb_name[t.port], t.addr))
        a.off = t.addr & 32'hFFF;
        if (t.read) apb_r[t.port].push_back(a); else apb_w[t.port].push_back(a);
        if (t.port == UART0_APB) begin
          // RBR/THR/DLL share offset 0 and IER/DLM offset 4; LCR[7] (DLAB) selects
          if (!t.read && a.off == 'h0C) uart0_dlab = a.data[7];
          if (t.read && a.off == 0 && !uart0_dlab) rbr_seen.push_back(a.data[7:0]);
        end
        return;
      end
      if (t.err === 1'b1) begin icb_errors++; `uvm_error("WP8_ICB", $sformatf("%s error response addr=%08h", icb_name[t.port], t.addr)) end
      if (t.port == MAILBOX_ICB) begin
        logic [31:0] o = t.addr & 32'h7FFFC;
        if (t.read) return;   // stack/data never live here; reads are not expected
        if (o < MB_OFF || o >= MB_OFF + 32'h1000) return;
        mailbox_writes++;
        `uvm_info("WP8_MAILBOX", $sformatf("write off=%05h data=%08h", o, t.wdata), UVM_HIGH)
        if ($isunknown(t.wdata)) `uvm_error("WP8_MAILBOX", $sformatf("unknown data written off=%05h", o))
        if (o == MB_OFF + 4 && t.wdata == PHASE_RX_READY) rx_ready_seen = 1;
        else if (o == MB_OFF + 8) mb_count = t.wdata;
        else if (o == MB_OFF) begin mb_status = t.wdata; status_seen = 1; end
        else if (o >= MB_OFF + 32'h100 && o < MB_OFF + 32'h100 + 8 * NREC) begin
          if (((o - MB_OFF - 32'h100) >> 2) % 2 == 0) rec_id.push_back(t.wdata); else rec_val.push_back(t.wdata);
        end
        else if (o != MB_OFF + 4) `uvm_error("WP8_MAILBOX", $sformatf("unexpected mailbox write off=%05h data=%08h", o, t.wdata))
        return;
      end
      if ((t.addr & slot_mask(t.port)) != icb_base[t.port])
        `uvm_error("WP8_ICB", $sformatf("%s access outside its slot addr=%08h", icb_name[t.port], t.addr))
      a.off = t.addr - icb_base[t.port];
      if (t.read) icb_r[t.port].push_back(a); else icb_w[t.port].push_back(a);
    endfunction

    // CLINT decodes 64 KiB, PLIC 64 MiB; PPI slots are 4 KiB (O12 KSE uses 4 KiB)
    function logic [31:0] slot_mask(int port);
      return port == 5 ? 32'hFFFF_0000 : port == 6 ? 32'hFC00_0000 : 32'hFFFF_F000;
    endfunction

    function void expect_seq(string who, string kind, wp8_acc_t got[$], wp8_acc_t exp[$], bit check_data);
      if (got.size() != exp.size()) begin
        `uvm_error("WP8_BUS", $sformatf("%s %s count got=%0d expected=%0d", who, kind, got.size(), exp.size()))
        return;
      end
      foreach (exp[i])
        if (got[i].off !== exp[i].off || (check_data && got[i].data !== exp[i].data))
          `uvm_error("WP8_BUS", $sformatf("%s %s #%0d got off=%03h data=%08h expected off=%03h data=%08h",
                                          who, kind, i, got[i].off, got[i].data, exp[i].off, exp[i].data))
    endfunction

    function wp8_acc_t acc(logic [31:0] off, logic [31:0] data = 0, bit read = 0);
      acc.read = read; acc.off = off; acc.data = data;
    endfunction

    function void check_phase(uvm_phase phase);
      wp8_acc_t w[$], r[$];
      int seen_id[int];
      // 1. UART0 TX pad bytes against the expected message (negative control target)
      if (tx_seen.size() != msg_expected.size())
        `uvm_error("WP8_UART_TX", $sformatf("decoded %0d bytes expected %0d", tx_seen.size(), msg_expected.size()))
      foreach (tx_seen[i])
        if (i < msg_expected.size() && tx_seen[i] !== msg_expected[i])
          `uvm_error("WP8_UART_TX", $sformatf("byte=%0d got=%02h expected=%02h", i, tx_seen[i], msg_expected[i]))
      // 2. bus THR data == pad bytes (end-to-end through the modified TX FIFO)
      thr_seen.delete();
      begin
        bit dlab = 0;
        wp8_acc_t q[$] = apb_w[UART0_APB];
        foreach (q[i]) begin
          if (q[i].off == 'h0C) dlab = q[i].data[7];
          else if (q[i].off == 'h00 && !dlab) thr_seen.push_back(q[i].data[7:0]);
        end
      end
      if (thr_seen.size() != tx_seen.size())
        `uvm_error("WP8_UART_E2E", $sformatf("THR writes=%0d pad frames=%0d", thr_seen.size(), tx_seen.size()))
      else foreach (thr_seen[i]) if (thr_seen[i] !== tx_seen[i])
        `uvm_error("WP8_UART_E2E", $sformatf("frame %0d THR=%02h pad=%02h", i, thr_seen[i], tx_seen[i]))
      // 3. RX loopback seen on the bus (RBR reads with DLAB=0)
      if (rbr_seen.size() != rx_bytes.size())
        `uvm_error("WP8_UART_RX", $sformatf("RBR reads=%0d expected=%0d", rbr_seen.size(), rx_bytes.size()))
      else foreach (rx_bytes[i]) if (rbr_seen[i] !== rx_bytes[i])
        `uvm_error("WP8_UART_RX", $sformatf("byte=%0d RBR=%02h driven=%02h", i, rbr_seen[i], rx_bytes[i]))
      // 4. CPU records against the independent table
      if (!status_seen) `uvm_error("WP8_MAILBOX", "final status never written")
      else if (mb_status !== (STATUS_PASS | NREC))
        `uvm_error("WP8_MAILBOX", $sformatf("CPU status=%08h expected=%08h", mb_status, STATUS_PASS | NREC))
      if (mb_count !== NREC || rec_id.size() != NREC || rec_val.size() != NREC)
        `uvm_error("WP8_MAILBOX", $sformatf("records count=%0d ids=%0d values=%0d expected=%0d", mb_count, rec_id.size(), rec_val.size(), NREC))
      foreach (rec_id[i]) begin
        int id = int'(rec_id[i]);
        if (!exp_rec.exists(id) || seen_id.exists(id)) begin
          `uvm_error("WP8_REG", $sformatf("unknown or repeated record id=%0d", id)); continue;
        end
        seen_id[id] = 1;
        if (i < rec_val.size() && rec_val[i] !== exp_rec[id])
          `uvm_error("WP8_REG", $sformatf("id=%0d got=%08h expected=%08h", id, rec_val[i], exp_rec[id]))
      end
      // 5. exact bus traffic per peripheral (writes with data, reads by offset)
      // GPIOA
      w = '{acc('h08, 32'h2_0000), acc('h00, 32'h2_0000), acc('h1C, 32'h3_0000)};
      expect_seq("GPIOA", "writes", apb_w[0], w, 1);
      r = '{acc('h08), acc('h00), acc('h1C), acc('h04)};
      expect_seq("GPIOA", "reads", apb_r[0], r, 0);
      // GPIOB
      w = '{acc('h10, 32'hA5A5_5A5A)}; expect_seq("GPIOB", "writes", apb_w[1], w, 1);
      r = '{acc('h04), acc('h10)}; expect_seq("GPIOB", "reads", apb_r[1], r, 0);
      // UART0 configuration + 20 THR writes
      w = '{acc('h0C, 'h83), acc('h00, UART0_DIV), acc('h04, 0), acc('h0C, 'h03), acc('h04, 'h05), acc('h04, 0), acc('h08, 'h06)};
      foreach (msg[i]) w.push_back(acc('h00, msg[i]));
      expect_seq("UART0", "writes", apb_w[UART0_APB], w, 1);
      begin
        int lsr = 0, other = 0;
        wp8_acc_t q[$] = apb_r[UART0_APB];
        foreach (q[i]) if (q[i].off == 'h14) lsr++; else other++;
        // 8 config reads + 4 RBR reads; LSR polled at least 2 (TX) + 1 (TEMT) + 4 (RX) + 3 (boot/flush/final)
        if (other != 12 || lsr < 10)
          `uvm_error("WP8_BUS", $sformatf("UART0 reads non-LSR=%0d (expected 12) LSR=%0d (expected >=10)", other, lsr))
      end
      // UART1 / UART2
      w = '{acc('h0C, 'h87), acc('h00, 'h5A), acc('h04, 'h01), acc('h0C, 'h07), acc('h04, 'h02)};
      expect_seq("UART1", "writes", apb_w[3], w, 1);
      r = '{acc('h14), acc('h00), acc('h04), acc('h0C), acc('h04)};
      expect_seq("UART1", "reads", apb_r[3], r, 0);
      w = '{acc('h0C, 'h9B), acc('h00, 'hC3), acc('h04, 'h7E), acc('h0C, 'h1B), acc('h04, 'h04)};
      expect_seq("UART2", "writes", apb_w[4], w, 1);
      expect_seq("UART2", "reads", apb_r[4], r, 0);
      // SPI1 / SPI2
      w = '{acc('h0C, 32'h1234_5678), acc('h08, 32'hCAFE_F00D)}; expect_seq("SPI1", "writes", apb_w[5], w, 1);
      r = '{acc('h0C), acc('h08), acc('h04)}; expect_seq("SPI1", "reads", apb_r[5], r, 0);
      w = '{acc('h0C, 32'h8765_4321), acc('h08, 32'h0BAD_F00D)}; expect_seq("SPI2", "writes", apb_w[6], w, 1);
      r = '{acc('h0C), acc('h08)}; expect_seq("SPI2", "reads", apb_r[6], r, 0);
      // I2C0 / I2C1
      w = '{acc('h00, 32'hBEEF), acc('h10, 32'h5A)}; expect_seq("I2C0", "writes", apb_w[7], w, 1);
      r = '{acc('h0C), acc('h00), acc('h10)}; expect_seq("I2C0", "reads", apb_r[7], r, 0);
      w = '{acc('h00, 32'h1234), acc('h10, 32'hA5)}; expect_seq("I2C1", "writes", apb_w[8], w, 1);
      r = '{acc('h00), acc('h10), acc('h0C)}; expect_seq("I2C1", "reads", apb_r[8], r, 0);
      // PWM
      w = '{acc('h08, 32'h00FF_0010), acc('h0C, 32'h0003_1234)}; expect_seq("PWM", "writes", apb_w[9], w, 1);
      r = '{acc('h08), acc('h0C)}; expect_seq("PWM", "reads", apb_r[9], r, 0);
      // ICB targets (read data checked here too)
      w = '{acc('h80, 32'hC0FF_EE01)}; expect_seq("AON", "writes", icb_w[0], w, 1);
      r = '{acc('h80, 32'hC0FF_EE01, 1)}; expect_seq("AON", "reads", icb_r[0], r, 1);
      w.delete(); expect_seq("HCLKGEN", "writes", icb_w[1], w, 1);
      r = '{acc('h04, 32'h4000_0000, 1), acc('h08, 32'h0004_4642, 1), acc('h0C, 32'h100, 1)};
      expect_seq("HCLKGEN", "reads", icb_r[1], r, 1);
      w = '{acc('h00, 32'hA5), acc('h00, 3)}; expect_seq("QSPI0", "writes", icb_w[2], w, 1);
      r = '{acc('h00, 3, 1), acc('h00, 32'hA5, 1), acc('h00, 3, 1)}; expect_seq("QSPI0", "reads", icb_r[2], r, 1);
      w = '{acc('h00, 32'hDEAD_BEEF)}; expect_seq("EXPL_AXI", "writes", icb_w[3], w, 1);
      r = '{acc('h00, 0, 1)}; expect_seq("EXPL_AXI", "reads", icb_r[3], r, 1);
      w.delete(); expect_seq("KSE_MMIO", "writes", icb_w[4], w, 1);
      r = '{acc('h00, 32'h4B53_4531, 1)}; expect_seq("KSE_MMIO", "reads", icb_r[4], r, 1);
      w = '{acc('h4000, 32'h89AB_CDEF), acc('h4000, 32'hFFFF_FFFF)}; expect_seq("CLINT", "writes", icb_w[5], w, 1);
      r = '{acc('h4000, 32'hFFFF_FFFF, 1), acc('h4000, 32'h89AB_CDEF, 1)}; expect_seq("CLINT", "reads", icb_r[5], r, 1);
      w = '{acc('h0C, 5), acc('h0C, 0)}; expect_seq("PLIC", "writes", icb_w[6], w, 1);
      r = '{acc('h0C, 5, 1), acc('h0C, 0, 1)}; expect_seq("PLIC", "reads", icb_r[6], r, 1);
    endfunction
  endclass

  // ---------------- environment and test ----------------
  class wp8_soc_periph_env extends uvm_env;
    `uvm_component_utils(wp8_soc_periph_env)
    wp8_bus_monitor bus_mon;
    wp8_uart_tx_monitor tx_mon;
    wp8_uart_rx_driver rx_drv;
    wp8_soc_periph_scoreboard sb;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      bus_mon = wp8_bus_monitor::type_id::create("bus_mon", this);
      tx_mon = wp8_uart_tx_monitor::type_id::create("tx_mon", this);
      rx_drv = wp8_uart_rx_driver::type_id::create("rx_drv", this);
      sb = wp8_soc_periph_scoreboard::type_id::create("sb", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      bus_mon.ap.connect(sb.bus_imp);
      tx_mon.ap.connect(sb.tx_imp);
    endfunction
    function void check_phase(uvm_phase phase);
      // every ICB command into icb2apb produced exactly one APB access and one response
      for (int p = 0; p < NAPB; p++)
        if (bus_mon.apb_access[p] != bus_mon.icb_apb_cmd[p] || bus_mon.icb_apb_cmd[p] != bus_mon.icb_apb_rsp[p])
          `uvm_error("WP8_BUS", $sformatf("%s handshake mismatch apb=%0d icb_cmd=%0d icb_rsp=%0d", apb_name[p],
                     bus_mon.apb_access[p], bus_mon.icb_apb_cmd[p], bus_mon.icb_apb_rsp[p]))
    endfunction
  endclass

  class test_wp8_soc_periph extends uvm_test;
    `uvm_component_utils(test_wp8_soc_periph)
    wp8_soc_periph_env env;
    virtual wp8_soc_periph_if v;
    string firmware;
    int fw_words;
    longint cycles;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = wp8_soc_periph_env::type_id::create("env", this);
      if (!uvm_config_db#(virtual wp8_soc_periph_if)::get(this, "", "vif", v)) `uvm_fatal("NOVIF", "test")
      if (!$value$plusargs("FW=%s", firmware) || !$value$plusargs("FW_WORDS=%d", fw_words)) `uvm_fatal("FIRMWARE", "missing +FW/+FW_WORDS")
      for (int i = 0; i < 8192; i++) v.fw[i] = 'x;
      $readmemh(firmware, v.fw, 0, fw_words - 1);
    endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      env.rx_drv.bytes = env.sb.rx_bytes;
      // Pad reset asserted; ITCM is loaded only while the SoC is held in reset.
      v.erst_n = 1'b0;
      #200;
      v.fw_load = 1'b1; #20; v.fw_load = 1'b0;
      v.erst_n = 1'b1;
      wait (v.rst_n === 1'b1);
      `uvm_info("WP8_SOC", $sformatf("bus reset released at %0t, firmware words=%0d", $time, fw_words), UVM_LOW)
      fork
        begin
          wait (env.sb.rx_ready_seen);
          `uvm_info("WP8_UART_RX", "CPU ready, driving 4 bytes on pad 16", UVM_LOW)
          env.rx_drv.send_all();
        end
      join_none
      fork
        begin
          wait (env.sb.status_seen);
          repeat (200) @(posedge v.clk);
        end
        begin
          #3ms;
          `uvm_fatal("WP8_WATCHDOG", "CPU did not write the final status within 3 ms")
        end
      join_any
      disable fork;
      `uvm_info("WP8_SOC", $sformatf("final status=%08h at %0t", env.sb.mb_status, $time), UVM_LOW)
      phase.drop_objection(this);
    endtask
    function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      int errs = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
      `uvm_info("WP8_SUMMARY", $sformatf("uart_tx frames=%0d decoded=%0d expected=%0d framing_bad=%0d thr_writes=%0d",
                env.tx_mon.frames, env.sb.tx_seen.size(), env.sb.msg_expected.size(), env.tx_mon.framing_bad, env.sb.thr_seen.size()), UVM_NONE)
      `uvm_info("WP8_SUMMARY", $sformatf("uart_rx driven=%0d rbr_reads=%0d", env.rx_drv.sent, env.sb.rbr_seen.size()), UVM_NONE)
      `uvm_info("WP8_SUMMARY", $sformatf("cpu status=%08h records=%0d mailbox_writes=%0d", env.sb.mb_status, env.sb.rec_id.size(), env.sb.mailbox_writes), UVM_NONE)
      for (int p = 0; p < NAPB; p++)
        `uvm_info("WP8_BUSCOUNT", $sformatf("apb port=%s base=%08h writes=%0d reads=%0d apb_access=%0d icb_cmd=%0d icb_rsp=%0d",
                  apb_name[p], apb_base[p], env.sb.apb_w[p].size(), env.sb.apb_r[p].size(), env.bus_mon.apb_access[p],
                  env.bus_mon.icb_apb_cmd[p], env.bus_mon.icb_apb_rsp[p]), UVM_NONE)
      for (int p = 0; p < NICB - 1; p++)
        `uvm_info("WP8_BUSCOUNT", $sformatf("icb port=%s base=%08h writes=%0d reads=%0d zero_latency_rsp=%0d", icb_name[p], icb_base[p],
                  env.sb.icb_w[p].size(), env.sb.icb_r[p].size(), env.bus_mon.zero_latency[p]), UVM_NONE)
      `uvm_info("WP8_SOC_PERIPH_COMPLETE", "scoreboard evaluated", UVM_NONE)
      if (errs == 0) `uvm_info("WP8_SOC", "TEST PASSED", UVM_NONE)
    endfunction
  endclass
endpackage
