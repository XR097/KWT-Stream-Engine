`timescale 1ns/1ps
package kse_contract_pkg;
  import uvm_pkg::*;
  import kse_integration_pkg::*;
  `include "uvm_macros.svh"
  class test_kse_contract extends uvm_test;
    `uvm_component_utils(test_kse_contract)
    virtual kse_integration_if v;
    kse_integration_scoreboard sb;
    kse_port_driver drv[3];
    string negative;
    bit completed;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if(!uvm_config_db#(virtual kse_integration_if)::get(this,"","vif",v))`uvm_fatal("NOVIF","contract test")
      sb=kse_integration_scoreboard::type_id::create("sb",this);
      for(int p=0;p<3;p++)begin
        uvm_config_db#(int)::set(this,$sformatf("drv%0d",p),"port_id",p);
        drv[p]=kse_port_driver::type_id::create($sformatf("drv%0d",p),this);
      end
      void'($value$plusargs("NEGATIVE=%s",negative));
    endfunction
    task wr(int a,int d);
      logic[31:0] r;logic e;
      drv[1].access(0,a,d,15,0,r,e);
      if(e)`uvm_error("DRIVER_ERROR","unexpected loader response error")
    endtask
    task work();
      logic[31:0] r;logic e;
      v.reset_drive=0;v.contract_unit=1;v.image_words=1041;
      for(int p=0;p<5;p++)begin v.cv[p]=0;v.rr[p]=0;v.rd[p]=0;v.addr[p]=0;v.wd[p]=0;v.mask[p]=15;end
      repeat(5)@(negedge v.clk);v.reset_drive=1;
      repeat(3)@(negedge v.clk);
      wr('h40080000,0);
      if(negative=="early")begin wr('h40080004,4164);wr('h40080000,0);end
      if(negative=="grain")begin wr(0,0);wr('h40080004,4);wr('h40080000,0);end
      if(negative=="release")begin
        drv[0].access(0,0,32'h12345678,15,0,r,e);
        v.contract_reads=1;drv[2].access(1,0,0,15,0,r,e);v.contract_reads=0;
      end
      drv[1].burst(0,0,1024,32'habcd0000);
      wr('h40080004,4096);
      drv[1].burst(0,4096,17,32'habcd0000);
      wr('h40080004,4164);
      if(negative=="done")begin wr('h40080000,0);wr('h40080008,1);end
      else wr('h40080008,1);
      if(negative=="rollback")wr('h40080004,4160);
      // Finite high-priority traffic guarantees CPU service for this stimulus.
      // Exactly one CPU request waits behind eight DMA + eight loader words.
      fork
        drv[0].burst(0,'h70000,1,32'hcc000000);
        drv[1].burst(0,'h71000,8,32'hdd000000);
        drv[2].burst(0,'h72000,8,32'hee000000);
      join
      repeat(5)@(negedge v.clk);
      if(sb.triple_grants==0 || sb.max_wait[0]==0)`uvm_error("CONTRACT_STIMULUS","triple-request/CPU wait scenario not reached")
      if(negative=="" && sb.tail_publications!=1)`uvm_error("CONTRACT_TAIL","17-word final publication was not checked")
      completed=1;
    endtask
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      fork work();begin repeat(20000)@(posedge v.clk);`uvm_fatal("WATCHDOG","contract test timed out")end join_any
      disable fork;phase.drop_objection(this);
    endtask
    function void report_phase(uvm_phase phase);
      uvm_report_server s;s=uvm_report_server::get_server();
      if(completed)begin
        `uvm_info("KSE_CONTRACT_COMPLETE","contract stimulus complete",UVM_NONE)
        if(s.get_severity_count(UVM_ERROR)==0 && s.get_severity_count(UVM_FATAL)==0)`uvm_info("RESULT","TEST PASSED",UVM_NONE)
      end else `uvm_error("INCOMPLETE","contract test did not complete")
    endfunction
  endclass
endpackage
