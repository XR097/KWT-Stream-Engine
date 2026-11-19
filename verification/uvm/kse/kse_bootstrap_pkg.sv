`include "uvm_macros.svh"
package kse_bootstrap_pkg;
  import uvm_pkg::*;

  class kse_icb_item extends uvm_sequence_item;
    `uvm_object_utils(kse_icb_item)
    bit read, response;
    int port_id;
    bit [31:0] addr, wdata;
    bit [3:0] wmask = 4'hf;
    int unsigned stall;
    // Four-state observations must not silently turn X/Z into zero.
    logic [31:0] rdata;
    logic err;
    function new(string name="kse_icb_item"); super.new(name); endfunction
  endclass

  class kse_icb_driver extends uvm_driver #(kse_icb_item);
    `uvm_component_utils(kse_icb_driver)
    virtual kse_icb_if vif;
    function new(string name, uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual kse_icb_if)::get(this,"","vif",vif))
        `uvm_fatal("NOVIF","missing ICB interface")
    endfunction
    task run_phase(uvm_phase phase);
      kse_icb_item req;
      vif.cmd_valid=0; vif.cmd_read=0; vif.cmd_addr=0;
      vif.cmd_wdata=0; vif.cmd_wmask=0; vif.rsp_ready=0;
      wait(vif.rst_n===1'b1);
      forever begin
        seq_item_port.get_next_item(req);
        @(negedge vif.clk);
        vif.cmd_read=req.read; vif.cmd_addr=req.addr;
        vif.cmd_wdata=req.wdata; vif.cmd_wmask=req.wmask; vif.cmd_valid=1;
        do @(posedge vif.clk); while (vif.cmd_ready!==1'b1);
        @(negedge vif.clk); vif.cmd_valid=0;
        repeat(req.stall) @(negedge vif.clk);
        vif.rsp_ready=1;
        do @(posedge vif.clk); while (vif.rsp_valid!==1'b1);
        req.rdata=vif.rsp_rdata; req.err=vif.rsp_err;
        @(negedge vif.clk); vif.rsp_ready=0;
        seq_item_port.item_done();
      end
    endtask
  endclass

  class kse_icb_monitor extends uvm_monitor;
    `uvm_component_utils(kse_icb_monitor)
    virtual kse_icb_if vif;
    int port_id;
    uvm_analysis_port #(kse_icb_item) ap;
    function new(string name, uvm_component parent); super.new(name,parent); ap=new("ap",this); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual kse_icb_if)::get(this,"","vif",vif))
        `uvm_fatal("NOVIF","missing monitor interface")
      if (!uvm_config_db#(int)::get(this,"","port_id",port_id))
        `uvm_fatal("NOPORT","missing monitor port index")
    endfunction
    task run_phase(uvm_phase phase);
      kse_icb_item t;
      forever begin
        @(posedge vif.clk);
        if (vif.rst_n===1'b1) begin
          if ($isunknown({vif.cmd_ready,vif.rsp_valid}))
            `uvm_error("ICB_X","unknown ready/valid after reset")
          // Consume the old response before a possible new same-cycle request.
          if (vif.rsp_valid===1'b1 && vif.rsp_ready===1'b1) begin
            t=kse_icb_item::type_id::create("rsp"); t.response=1; t.port_id=port_id;
            t.rdata=vif.rsp_rdata; t.err=vif.rsp_err; ap.write(t);
          end
          if (vif.cmd_valid===1'b1 && vif.cmd_ready===1'b1) begin
            t=kse_icb_item::type_id::create("cmd"); t.port_id=port_id;
            t.addr=vif.cmd_addr; t.read=vif.cmd_read; t.wdata=vif.cmd_wdata;
            t.wmask=vif.cmd_wmask; ap.write(t);
          end
        end
      end
    endtask
  endclass

  class kse_icb_agent extends uvm_agent;
    `uvm_component_utils(kse_icb_agent)
    kse_icb_driver driver;
    kse_icb_monitor monitor;
    uvm_sequencer #(kse_icb_item) sqr;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      driver=kse_icb_driver::type_id::create("driver",this);
      monitor=kse_icb_monitor::type_id::create("monitor",this);
      sqr=new("sqr",this);
    endfunction
    function void connect_phase(uvm_phase phase);
      driver.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  // Bootstrap oracle: documented idle MMIO contract and byte-addressed SRAM.
  // It predicts from observed requests, never from the DUT's internal storage.
  class kse_bootstrap_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(kse_bootstrap_scoreboard)
    uvm_analysis_imp #(kse_icb_item,kse_bootstrap_scoreboard) imp;
    kse_icb_item pending[3];
    byte unsigned memory[int unsigned];
    bit [31:0] ctrl;
    int requests, responses, checked_reads;
    bit corrupt_expected, corrupted;
    covergroup accesses with function sample(int port_id, bit read, bit err);
      option.per_instance=1;
      port_cp: coverpoint port_id { bins mmio={0}; bins cpu={1}; bins loader={2}; }
      direction_cp: coverpoint read;
      error_cp: coverpoint err;
      port_direction: cross port_cp,direction_cp;
    endgroup
    function new(string name,uvm_component parent);
      super.new(name,parent); imp=new("imp",this); accesses=new;
    endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase); corrupt_expected=$test$plusargs("SB_CORRUPT_EXPECTED");
    endfunction
    function void write(kse_icb_item t);
      kse_icb_item expected;
      int unsigned address;
      if (t.response) begin
        responses++;
        expected=pending[t.port_id];
        if (expected==null) begin `uvm_error("UNEXPECTED_RSP","response without request") return; end
        if (t.err!==expected.err || (expected.read && t.rdata!==expected.rdata))
          `uvm_error("KSE_SB",$sformatf("port=%0d addr=%08h got=%08h/%b expected=%08h/%b",
            t.port_id,expected.addr,t.rdata,t.err,expected.rdata,expected.err))
        if (expected.read) checked_reads++;
        accesses.sample(t.port_id,expected.read,expected.err);
        pending[t.port_id]=null;
        return;
      end
      requests++;
      if (pending[t.port_id]!=null) `uvm_error("OUTSTANDING","more than one request outstanding")
      expected=kse_icb_item::type_id::create("expected");
      expected.addr=t.addr; expected.read=t.read; expected.err=0; expected.rdata=0;
      if (t.port_id==0) begin
        // Only reset reads, CTRL read/write, and unmapped-page errors are
        // exercised here. Command execution and other RW registers are later tests.
        expected.err=(t.addr[23:12]!=0 || t.addr[11:2]>12);
        if (!expected.err && t.read) begin
          case(t.addr[11:2])
            0: expected.rdata=32'h4b534531;
            1: expected.rdata=ctrl;
            default: expected.rdata=0;
          endcase
        end
        if (!expected.err && !t.read && t.addr[11:2]==1 && t.wmask[0]) ctrl=t.wdata & 3;
      end else begin
        address=t.addr & 32'h0007fffc;
        for(int b=0;b<4;b++) begin
          if (t.read) begin
            if (!memory.exists(address+b)) `uvm_fatal("UNINITIALIZED_ORACLE","read before test initialization")
            expected.rdata[8*b+:8]=memory[address+b];
          end else if (t.wmask[b]) memory[address+b]=t.wdata[8*b+:8];
        end
      end
      if (corrupt_expected && !corrupted && t.read) begin
        expected.rdata ^= 1; corrupted=1;
      end
      pending[t.port_id]=expected;
    endfunction
    function void check_phase(uvm_phase phase);
      super.check_phase(phase);
      foreach(pending[p]) if(pending[p]!=null) `uvm_error("PENDING","unconsumed response")
      if (requests==0 || checked_reads==0 || responses!=requests)
        `uvm_error("COUNTS","missing traffic, reads or responses")
      `uvm_info("KSE_COUNTS",$sformatf("requests=%0d responses=%0d checked_reads=%0d",
        requests,responses,checked_reads),UVM_NONE)
    endfunction
  endclass

  class kse_access_seq extends uvm_sequence #(kse_icb_item);
    `uvm_object_utils(kse_access_seq)
    bit read;
    bit [31:0] addr,data;
    bit [3:0] mask=4'hf;
    int unsigned stall;
    function new(string name="kse_access_seq");super.new(name);endfunction
    task body();
      kse_icb_item t=kse_icb_item::type_id::create("access");
      start_item(t); t.read=read; t.addr=addr; t.wdata=data; t.wmask=mask; t.stall=stall; finish_item(t);
    endtask
  endclass

  class test_kse_bootstrap extends uvm_test;
    `uvm_component_utils(test_kse_bootstrap)
    kse_icb_agent agents[3];
    kse_bootstrap_scoreboard sb;
    virtual kse_icb_if mmio;
    bit completed;
    function new(string name,uvm_component parent);super.new(name,parent);endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      for(int p=0;p<3;p++) begin
        uvm_config_db#(int)::set(this,$sformatf("agent%0d.*",p),"port_id",p);
        agents[p]=kse_icb_agent::type_id::create($sformatf("agent%0d",p),this);
      end
      sb=kse_bootstrap_scoreboard::type_id::create("sb",this);
      if(!uvm_config_db#(virtual kse_icb_if)::get(this,"","mmio",mmio))
        `uvm_fatal("NOVIF","missing reset/IRQ observation interface")
    endfunction
    function void connect_phase(uvm_phase phase);
      foreach(agents[p]) agents[p].monitor.ap.connect(sb.imp);
    endfunction
    task access(int port_id,bit read,bit[31:0] addr,bit[31:0] data=0,bit[3:0] mask=15,int stall=0);
      kse_access_seq s=kse_access_seq::type_id::create("access_seq");
      s.read=read;s.addr=addr;s.data=data;s.mask=mask;s.stall=stall;
      s.start(agents[port_id].sqr);
    endtask
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      fork
        begin repeat(10000) @(posedge mmio.clk); `uvm_fatal("WATCHDOG","bootstrap did not finish") end
        begin
          wait(mmio.rst_n===1'b1);repeat(2) @(posedge mmio.clk);
          for(int r=0;r<13;r++)
            if(r!=8) access(0,1,32'h11000000+4*r,0,15,r%4);
          access(0,0,32'h11000004,32'hffffffff); access(0,1,32'h11000004,0,15,3);
          access(0,0,32'h11000004,0); access(0,1,32'h11000004);
          access(0,1,32'h11000034,0,15,2);access(0,1,32'h11001000);
          // Seeded patterns; edges cover both stripes, macro and region bounds.
          for(int i=0;i<8;i++) begin
            bit[31:0] address;
            case(i)
              0:address=0;1:address='hffc;2:address='h1000;3:address='h1ffc;
              4:address='h2000;5:address='h3fffc;6:address='h40000;7:address='h7fffc;
            endcase
            access(1,0,address,$urandom,15,2);
            access(2,1,address,0,15,3);
            access(2,0,address,$urandom,4'b0101,1);
            access(1,1,address,0,15,2);
          end
          repeat(3) @(posedge mmio.clk); completed=1;
        end
      join_any
      disable fork;
      phase.drop_objection(this);
    endtask
    function void report_phase(uvm_phase phase);
      uvm_report_server reports;
      super.report_phase(phase);
      reports=uvm_report_server::get_server();
      if(completed) begin
        `uvm_info("KSE_TEST_COMPLETE","bootstrap stimulus completed",UVM_NONE)
        if(reports.get_severity_count(UVM_ERROR)==0 && reports.get_severity_count(UVM_FATAL)==0)
          `uvm_info("KSE_RESULT","TEST PASSED",UVM_NONE)
      end
      else `uvm_error("INCOMPLETE","bootstrap did not finish")
    endfunction
  endclass
endpackage
