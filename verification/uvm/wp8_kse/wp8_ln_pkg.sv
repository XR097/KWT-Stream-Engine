// KSNUM-012 UVM environment for kse_ln_core: constant/extreme/alternating rows,
// variance/isqrt boundaries, production LN parameters and token/tag alignment.
package wp8_ln_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `uvm_analysis_imp_decl(_exp)
  `uvm_analysis_imp_decl(_res)
  `uvm_analysis_imp_decl(_out)

  class wp8_ln_item extends uvm_sequence_item;
    `uvm_object_utils(wp8_ln_item)
    bit is_set;
    int set_id, tok_id, ntok, gap_half, gap_tok;
    int ax, ay, vsh, nsh, ash, eps;
    logic [64*16-1:0] gamma;
    logic [64*8-1:0]  beta;
    logic [511:0] x, y, er, eo, data;
    longint t_in, t_obs;
    function new(string name = "wp8_ln_item"); super.new(name); endfunction
  endclass

  class wp8_ln_sequence extends uvm_sequence #(wp8_ln_item);
    `uvm_object_utils(wp8_ln_sequence)
    string file;
    function new(string name = "wp8_ln_sequence"); super.new(name); endfunction
    task body();
      int fd, n; string tag; wp8_ln_item t;
      fd = $fopen(file, "r");
      if (fd == 0) `uvm_fatal("WP8_LN_FILE", {"cannot open ", file})
      while (1) begin
        n = $fscanf(fd, "%s", tag);
        if (n != 1) break;
        t = wp8_ln_item::type_id::create("t");
        if (tag == "S") begin
          t.is_set = 1;
          n = $fscanf(fd, "%d %d %d %d %d %d %d %d %h %h", t.set_id, t.ax, t.ay, t.vsh, t.nsh, t.ash, t.eps, t.ntok, t.gamma, t.beta);
          if (n != 10) `uvm_fatal("WP8_LN_FILE", "malformed set line")
        end else if (tag == "T") begin
          t.is_set = 0;
          n = $fscanf(fd, "%d %d %h %h %h %h %d %d", t.set_id, t.tok_id, t.x, t.y, t.er, t.eo, t.gap_half, t.gap_tok);
          if (n != 8) `uvm_fatal("WP8_LN_FILE", "malformed token line")
        end else `uvm_fatal("WP8_LN_FILE", {"bad tag ", tag})
        start_item(t); finish_item(t);
      end
      $fclose(fd);
    endtask
  endclass

  class wp8_ln_driver extends uvm_driver #(wp8_ln_item);
    `uvm_component_utils(wp8_ln_driver)
    virtual wp8_ln_if vif;
    uvm_analysis_port #(wp8_ln_item) expected;
    int unsigned sent, done, sets;
    longint cycle;
    function new(string name, uvm_component parent); super.new(name, parent); expected = new("expected", this); endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual wp8_ln_if)::get(this, "", "vif", vif)) `uvm_fatal("WP8_LN_CFG", "missing vif")
    endfunction
    task drain();
      while (done != sent) @(negedge vif.clk);
    endtask
    task run_phase(uvm_phase phase);
      vif.in_valid = 0; vif.in_half = 0; vif.in_x = 'x; vif.in_y = 'x;
      vif.ax = 0; vif.ay = 0; vif.vsh = 0; vif.nsh = 0; vif.ash = 0; vif.eps = 0; vif.gamma = '0; vif.beta = '0;
      fork
        forever begin @(posedge vif.clk); cycle++; if (vif.out_valid === 1'b1 && vif.out_half === 1'b1) done++; end
      join_none
      wait (vif.rst_n === 1'b1);
      repeat (10) @(negedge vif.clk);
      forever begin
        seq_item_port.get_next_item(req);
        if (req.is_set) begin
          drain();
          repeat (4) @(negedge vif.clk);
          vif.ax = 8'(req.ax); vif.ay = 8'(req.ay); vif.vsh = 8'(req.vsh); vif.nsh = 8'(req.nsh);
          vif.ash = 8'(req.ash); vif.eps = 16'(req.eps); vif.gamma = req.gamma; vif.beta = req.beta;
          sets++;
          repeat (2) @(negedge vif.clk);
        end else begin
          while (vif.tok_ready !== 1'b1) @(negedge vif.clk);
          vif.in_valid = 1; vif.in_half = 0; vif.in_x = req.x[255:0]; vif.in_y = req.y[255:0];
          @(negedge vif.clk);
          vif.in_valid = 0; vif.in_x = 'x; vif.in_y = 'x;
          repeat (req.gap_half) @(negedge vif.clk);
          vif.in_valid = 1; vif.in_half = 1; vif.in_x = req.x[511:256]; vif.in_y = req.y[511:256];
          req.t_in = cycle + 1;
          expected.write(req);
          sent++;
          @(negedge vif.clk);
          vif.in_valid = 0; vif.in_half = 0; vif.in_x = 'x; vif.in_y = 'x;
          repeat (req.gap_tok) @(negedge vif.clk);
        end
        seq_item_port.item_done();
      end
    endtask
  endclass

  class wp8_ln_monitor extends uvm_component;
    `uvm_component_utils(wp8_ln_monitor)
    virtual wp8_ln_if vif;
    uvm_analysis_port #(wp8_ln_item) res_ap, out_ap;
    bit res_hi, out_hi; logic [255:0] res_lo, out_lo;
    int unsigned buf_free_pulses, half_errors;
    longint cycle;
    function new(string name, uvm_component parent);
      super.new(name, parent); res_ap = new("res_ap", this); out_ap = new("out_ap", this);
    endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual wp8_ln_if)::get(this, "", "vif", vif)) `uvm_fatal("WP8_LN_CFG", "missing vif")
    endfunction
    task run_phase(uvm_phase phase);
      wp8_ln_item t;
      forever begin
        @(vif.mon_cb);
        cycle++;
        if (vif.rst_n !== 1'b1) continue;
        if (vif.mon_cb.buf_free === 1'b1) buf_free_pulses++;
        if (vif.mon_cb.res_valid === 1'b1) begin
          if (vif.mon_cb.res_half !== res_hi) begin `uvm_error("WP8_LN_HALF", $sformatf("residual half order: got %b expected %b", vif.mon_cb.res_half, res_hi)) half_errors++; end
          if (!res_hi) res_lo = vif.mon_cb.res_data;
          else begin t = wp8_ln_item::type_id::create("r"); t.data = {vif.mon_cb.res_data, res_lo}; t.t_obs = cycle; res_ap.write(t); end
          res_hi = !res_hi;
        end
        if (vif.mon_cb.out_valid === 1'b1) begin
          if (vif.mon_cb.out_half !== out_hi) begin `uvm_error("WP8_LN_HALF", $sformatf("output half order: got %b expected %b", vif.mon_cb.out_half, out_hi)) half_errors++; end
          if (!out_hi) out_lo = vif.mon_cb.out_data;
          else begin t = wp8_ln_item::type_id::create("o"); t.data = {vif.mon_cb.out_data, out_lo}; t.t_obs = cycle; out_ap.write(t); end
          out_hi = !out_hi;
        end
      end
    endtask
  endclass

  class wp8_ln_scoreboard extends uvm_component;
    `uvm_component_utils(wp8_ln_scoreboard)
    uvm_analysis_imp_exp #(wp8_ln_item, wp8_ln_scoreboard) exp_imp;
    uvm_analysis_imp_res #(wp8_ln_item, wp8_ln_scoreboard) res_imp;
    uvm_analysis_imp_out #(wp8_ln_item, wp8_ln_scoreboard) out_imp;
    wp8_ln_item q_res[$], q_out[$];
    int unsigned accepted, res_cmp, out_cmp, res_bytes, out_bytes, bad_res, bad_out;
    longint lat_min = 1 << 30, lat_max = 0;
    bit corrupt, corrupted;
    int set_seen[int];
    covergroup cg_ln with function sample(int kind, bit sat_hi, bit sat_lo, bit zero);
      option.per_instance = 1;
      cp_set: coverpoint kind { bins sets[] = {[0:3]}; }
      cp_hi: coverpoint sat_hi; cp_lo: coverpoint sat_lo; cp_zero: coverpoint zero;
    endgroup
    function new(string name, uvm_component parent);
      super.new(name, parent);
      exp_imp = new("exp_imp", this); res_imp = new("res_imp", this); out_imp = new("out_imp", this);
      corrupt = $test$plusargs("WP8_LN_CORRUPT_EXPECTED");
      cg_ln = new();
    endfunction
    function void write_exp(wp8_ln_item t);
      wp8_ln_item c = wp8_ln_item::type_id::create("c");
      c.set_id = t.set_id; c.tok_id = t.tok_id; c.er = t.er; c.eo = t.eo; c.t_in = t.t_in;
      if (corrupt && !corrupted) begin c.eo[0] = ~c.eo[0]; corrupted = 1; end
      q_res.push_back(c); q_out.push_back(c); accepted++; set_seen[t.set_id] = 1;
    endfunction
    function void write_res(wp8_ln_item t);
      wp8_ln_item e;
      if (q_res.size() == 0) begin `uvm_error("WP8_LN_EXTRA", "residual token without stimulus") return; end
      e = q_res.pop_front(); res_cmp++; res_bytes += 64;
      if (t.data !== e.er) begin
        bad_res++;
        `uvm_error("WP8_LN_RES", $sformatf("set=%0d token=%0d got=%0128h expected=%0128h", e.set_id, e.tok_id, t.data, e.er))
      end
    endfunction
    function void write_out(wp8_ln_item t);
      wp8_ln_item e; bit hi, lo, z;
      if (q_out.size() == 0) begin `uvm_error("WP8_LN_EXTRA", "output token without stimulus") return; end
      e = q_out.pop_front(); out_cmp++; out_bytes += 64;
      if (t.t_obs - e.t_in < lat_min) lat_min = t.t_obs - e.t_in;
      if (t.t_obs - e.t_in > lat_max) lat_max = t.t_obs - e.t_in;
      if (t.data !== e.eo) begin
        int first = -1;
        for (int i = 0; i < 64; i++) if (first < 0 && t.data[8*i +: 8] !== e.eo[8*i +: 8]) first = i;
        bad_out++;
        `uvm_error("WP8_LN_OUT", $sformatf("set=%0d token=%0d first_channel=%0d got=%02h expected=%02h", e.set_id, e.tok_id, first, t.data[8*first +: 8], e.eo[8*first +: 8]))
      end
      hi = 0; lo = 0; z = 0;
      for (int i = 0; i < 64; i++) begin
        if (e.eo[8*i +: 8] == 8'h7f) hi = 1;
        if (e.eo[8*i +: 8] == 8'h80) lo = 1;
        if (e.eo[8*i +: 8] == 8'h00) z = 1;
      end
      cg_ln.sample(e.set_id < 24 ? 0 : e.set_id < 36 ? 1 : e.set_id < 42 ? 2 : 3, hi, lo, z);
    endfunction
    function void check_phase(uvm_phase phase);
      if (q_res.size() || q_out.size() || res_cmp != accepted || out_cmp != accepted || accepted == 0)
        `uvm_error("WP8_LN_MISSING", $sformatf("accepted=%0d res=%0d out=%0d pending=%0d/%0d", accepted, res_cmp, out_cmp, q_res.size(), q_out.size()))
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("WP8_LN_COUNT", $sformatf("sets=%0d tokens=%0d res_compared=%0d out_compared=%0d res_bytes=%0d out_bytes=%0d bad_res=%0d bad_out=%0d latency_min=%0d latency_max=%0d",
                set_seen.num(), accepted, res_cmp, out_cmp, res_bytes, out_bytes, bad_res, bad_out, lat_min, lat_max), UVM_NONE)
    endfunction
  endclass

  class test_wp8_ln extends uvm_test;
    `uvm_component_utils(test_wp8_ln)
    wp8_ln_driver drv; wp8_ln_monitor mon; wp8_ln_scoreboard sb;
    uvm_sequencer #(wp8_ln_item) sqr;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      drv = wp8_ln_driver::type_id::create("drv", this); mon = wp8_ln_monitor::type_id::create("mon", this);
      sb = wp8_ln_scoreboard::type_id::create("sb", this); sqr = new("sqr", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      drv.seq_item_port.connect(sqr.seq_item_export); drv.expected.connect(sb.exp_imp);
      mon.res_ap.connect(sb.res_imp); mon.out_ap.connect(sb.out_imp);
    endfunction
    task run_phase(uvm_phase phase);
      wp8_ln_sequence seq = wp8_ln_sequence::type_id::create("seq");
      int lanes, nb;
      phase.raise_objection(this);
      if (!$value$plusargs("VECTORS=%s", seq.file)) `uvm_fatal("WP8_LN_CFG", "VECTORS required")
      void'(uvm_config_db#(int)::get(this, "", "lanes", lanes)); void'(uvm_config_db#(int)::get(this, "", "nb", nb));
      `uvm_info("WP8_LN_CONFIG", $sformatf("kse_ln_core LANES=%0d NB=%0d", lanes, nb), UVM_NONE)
      fork
        begin seq.start(sqr); drv.drain(); repeat (40) @(negedge drv.vif.clk); end
        begin repeat (2000000) @(posedge drv.vif.clk); `uvm_fatal("WP8_LN_WATCHDOG", "LN progress deadline exceeded") end
      join_any
      disable fork;
      `uvm_info("WP8_LN_DRAIN", $sformatf("sent=%0d done=%0d buf_free=%0d sets=%0d", drv.sent, drv.done, mon.buf_free_pulses, drv.sets), UVM_NONE)
      if (mon.buf_free_pulses != drv.sent) `uvm_error("WP8_LN_BUFFREE", $sformatf("buf_free pulses %0d != tokens %0d", mon.buf_free_pulses, drv.sent))
      `uvm_info("WP8_LN_COMPLETE", "LayerNorm vectors consumed", UVM_NONE)
      phase.drop_objection(this);
    endtask
    function void report_phase(uvm_phase phase);
      uvm_report_server s = uvm_report_server::get_server();
      if (s.get_severity_count(UVM_ERROR) == 0 && s.get_severity_count(UVM_FATAL) == 0)
        `uvm_info("WP8_LN_RESULT", "TEST PASSED", UVM_NONE)
    endfunction
  endclass
endpackage
