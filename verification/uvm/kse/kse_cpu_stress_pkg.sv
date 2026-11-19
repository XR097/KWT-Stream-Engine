`timescale 1ns/1ps
package kse_cpu_stress_pkg;
  import uvm_pkg::*;
  import kse_integration_pkg::*;
  import kse_network_pkg::*;
  `include "uvm_macros.svh"

  // Dedicated passive observer; the production SoC and shared v2/strict
  // network checker are unchanged. Scratch reference bytes come only from
  // accepted CPU writes, never from the SRAM model or design-side TB.
  class kse_cpu_stress_scoreboard extends kse_network_scoreboard;
    `uvm_component_utils(kse_cpu_stress_scoreboard)
    byte unsigned scratch[int unsigned];
    integration_expected cpu_pending;
    longint cpu_req,cpu_rsp,scratch_reads,scratch_writes,active_reads,active_writes;
    longint wait_now,wait_total,wait_max,rsp_cycle,rsp_latency_max;
    longint triple_cycles,active_req,active_wait_total,active_wait_max;
    longint masks[16];
    bit data_injected,require_stress;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      require_stress=!$test$plusargs("CPU_REFERENCE");
    endfunction
    function void sample_cpu();
      int unsigned a;
      logic[31:0] actual;
      bit in_window;
      if(v.rst_n!==1'b1)begin
        scratch.delete();cpu_pending=null;wait_now=0;return;
      end
      in_window=first_loader!=0 && !flag_done;
      if(in_window && (&v.cv[2:0]))triple_cycles++;
      if(v.cv[0] && !v.cr[0])wait_now++;
      if(v.rv[0] && v.rr[0])begin
        cpu_rsp++;
        if(cycle-rsp_cycle>rsp_latency_max)rsp_latency_max=cycle-rsp_cycle;
        if(cpu_pending!=null)begin
          actual=v.data[0];
          // One response-byte corruption in this observer only. No DUT force,
          // firmware failure, or cascading error in the shared SRAM checker.
          if($test$plusargs("CPU_CORRUPT_OBSERVED") && !data_injected)begin
            actual[7:0]^=8'h01;data_injected=1;
            `uvm_info("CPU_DATA_INJECTION","flipped one observed CPU read-response byte",UVM_NONE)
          end
          if(actual!==cpu_pending.value || v.err[0]!==1'b0)
            `uvm_error("CPU_DATA",$sformatf("addr=%08h got=%08h expected=%08h",cpu_pending.addr,actual,cpu_pending.value))
          cpu_pending=null;
        end
      end
      if(v.cv[0] && v.cr[0])begin
        cpu_req++;wait_total+=wait_now;
        if(wait_now>wait_max)wait_max=wait_now;
        if(in_window)begin
          active_req++;active_wait_total+=wait_now;
          if(wait_now>active_wait_max)active_wait_max=wait_now;
        end
        wait_now=0;rsp_cycle=cycle;
        a=v.addr[0] & 32'h7fffc;
        if(a>='h70000 && a<'h74000)begin
          if(v.rd[0])begin
            scratch_reads++;if(in_window)active_reads++;
            cpu_pending=new;cpu_pending.addr=a;cpu_pending.value='x;
            for(int k=0;k<4;k++)begin
              if(!scratch.exists(a+k))`uvm_fatal("CPU_ORACLE","scratch read before initialized CPU write")
              cpu_pending.value[8*k+:8]=scratch[a+k];
            end
          end else begin
            scratch_writes++;if(in_window)active_writes++;
            masks[v.mask[0]]++;
            for(int k=0;k<4;k++)if(v.mask[0][k])scratch[a+k]=v.wd[0][8*k+:8];
          end
        end
      end
    endfunction
    task run_phase(uvm_phase phase);
      forever begin
        @(posedge v.clk);
        sample_network();sample_cpu();sample_sram();
      end
    endtask
    function void check_phase(uvm_phase phase);
      super.check_phase(phase);
      if(require_stress && (cpu_req!=cpu_rsp || cpu_pending!=null || wait_now!=0 ||
          triple_cycles==0 || active_reads==0 || active_writes==0 || scratch_reads<32 ||
          masks[15]==0 || masks[2]==0 || masks[12]==0))
        `uvm_error("CPU_STRESS_COUNTS","CPU traffic, masks, overlap, or conservation incomplete")
      if($test$plusargs("CPU_CORRUPT_OBSERVED") && !data_injected)
        `uvm_error("CPU_INJECTION_MISSING","no scratch response to corrupt")
      `uvm_info("CPU_STRESS",$sformatf("req=%0d rsp=%0d scratch_reads=%0d scratch_writes=%0d active_reads=%0d active_writes=%0d triple_cycles=%0d wait_total=%0d wait_max=%0d wait_avg=%0.6f active_req=%0d active_wait_total=%0d active_wait_max=%0d active_wait_avg=%0.6f rsp_latency_max=%0d word_writes=%0d byte_writes=%0d half_writes=%0d data_injected=%0d",cpu_req,cpu_rsp,scratch_reads,scratch_writes,active_reads,active_writes,triple_cycles,wait_total,wait_max,cpu_req?real'(wait_total)/cpu_req:0.0,active_req,active_wait_total,active_wait_max,active_req?real'(active_wait_total)/active_req:0.0,rsp_latency_max,masks[15],masks[2],masks[12],data_injected),UVM_NONE)
    endfunction
  endclass

  class test_kse_cpu_stress extends test_kse_network;
    `uvm_component_utils(test_kse_cpu_stress)
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      kse_network_scoreboard::type_id::set_type_override(kse_cpu_stress_scoreboard::get_type());
      super.build_phase(phase);
    endfunction
  endclass
endpackage
