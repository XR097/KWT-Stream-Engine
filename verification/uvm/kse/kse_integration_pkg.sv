`timescale 1ns/1ps
package kse_integration_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  class integration_expected;
    logic [31:0] addr, value;
    bit read, error;
    longint cycle;
  endclass

  // Independent reference uses public master/slave handshakes, never DUT grants.
  class kse_integration_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(kse_integration_scoreboard)
    virtual kse_integration_if v;
    integration_expected pending[5];
    byte unsigned mem[int unsigned];
    longint cycle,requests[5],responses[5],cancelled[5],reads[5],writes[5];
    longint stalls[5],rsp_stalls[5],max_wait[5],wait_run[5];
    longint arb_checks,watermark_checks,triple_grants,slave_requests,slave_responses;
    logic[31:0] wp_model,base_model;
    bit valid_model,done_model,in_reset=1;
    int committed_words,published_words,doorbells,tail_publications;
    int cpu_bound=200000;
    bit injected;
    bit cmd_x_pending[5];
    bit cmd_x_injected;
    string mutation;
    covergroup memory_cov with function sample(int p,bit read,int group_id,int m);
      option.per_instance=1;
      port_cp:coverpoint p {bins masters[]={[0:2]};}
      read_cp:coverpoint read;
      group_cp:coverpoint group_id {bins groups[]={[0:31]};}
      mask_cp:coverpoint m {bins masks[]={[0:15]};}
      master_group:cross port_cp,group_cp;
    endgroup
    function new(string n,uvm_component p);super.new(n,p);memory_cov=new;endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if(!uvm_config_db#(virtual kse_integration_if)::get(this,"","vif",v))`uvm_fatal("NOVIF","strict scoreboard")
      void'($value$plusargs("CHECKER_MUTATION=%s",mutation));
      void'($value$plusargs("CPU_WAIT_BOUND=%d",cpu_bound));
      cmd_x_injected=0;
    endfunction
    function automatic bit released(int unsigned a);
      return valid_model && a>=base_model && longint'(a)+4<=wp_model;
    endfunction
    function void sample_sram();
      int winner,accepted,owners;
      bit free_slot,observed,doorbell;
      integration_expected e;
      cycle++;
      if(v.rst_n!==1'b1)begin
        in_reset=1;wp_model=0;base_model=0;valid_model=0;done_model=0;
        committed_words=0;published_words=0;doorbells=0;tail_publications=0;
        foreach(pending[p])begin
          cmd_x_pending[p]=0;
          if(pending[p]!=null)begin cancelled[p]++;pending[p]=null;end
        end
        foreach(wait_run[p])wait_run[p]=0;
        return;
      end
      in_reset=0;
      if({v.wptr,v.base,v.wp_valid,v.loader_done}!=={wp_model,base_model,valid_model,done_model})
        `uvm_error("WATERMARK","registered progress differs from accepted bus writes")
      watermark_checks++;
      free_slot=1;owners=0;
      for(int p=0;p<3;p++)begin
        if($isunknown({v.cv[p],v.cr[p],v.rv[p],v.rr[p]}))`uvm_error("BUS_X","unknown handshake")
        if(v.rv[p] !== (pending[p]!=null))`uvm_error("RSP_LATENCY","response missing, repeated or wrong owner")
        if(pending[p]!=null)begin
          owners++;if(!v.rr[p])free_slot=0;
          if(v.rv[p] && !cmd_x_pending[p] && (v.err[p]!==pending[p].error || (pending[p].read && v.data[p]!==pending[p].value)))
            `uvm_error("SRAM_SB",$sformatf("port=%0d addr=%08h got=%08h expected=%08h",p,pending[p].addr,v.data[p],pending[p].value))
        end
      end
      if(owners>1)`uvm_error("OUTSTANDING","single slave has multiple outstanding owners")
      winner=-1;
      for(int p=0;p<3;p++)if(v.cv[p])winner=p;
      accepted=$countones(v.cv[2:0]&v.cr[2:0]);
      if(accepted>1 || (v.scv && v.scr)!=(accepted==1))`uvm_error("SINGLE_PORT","master/slave command conservation differs")
      for(int p=0;p<3;p++)begin
        observed=v.cv[p] && v.cr[p];
        if(mutation=="arbitration" && !injected && (&v.cv[2:0]) && free_slot && p==2)begin observed=0;injected=1;end
        if(observed !== (winner==p && free_slot))`uvm_error("ARBITER",$sformatf("cycle=%0d port=%0d grant=%b expected=%b",cycle,p,observed,winner==p && free_slot))
        arb_checks++;
        if(v.cv[p] && !v.cr[p])begin
          stalls[p]++;wait_run[p]++;if(wait_run[p]>max_wait[p])max_wait[p]=wait_run[p];
          if(p==0 && wait_run[p]==cpu_bound+1)`uvm_error("CPU_WAIT_BOUND",$sformatf("wait=%0d bound=%0d",wait_run[p],cpu_bound))
        end else wait_run[p]=0;
        if(v.rv[p] && v.rr[p])begin
          responses[p]++;
          if(mutation=="conservation" && !injected)begin responses[p]--;injected=1;end
          if(cmd_x_pending[p])cmd_x_pending[p]=0;
          if(p==1 && pending[p]!=null && !cmd_x_pending[p] && !pending[p].read && pending[p].addr<32'h80000)committed_words++;
          pending[p]=null;
        end
      end
      if((&v.cv[2:0]) && accepted)triple_grants++;
      if(v.scv && v.scr)slave_requests++;
      if(v.srv && v.srr)slave_responses++;
      for(int p=0;p<3;p++)if(v.cv[p] && v.cr[p])begin
        int unsigned a;logic[31:0] raw;
        raw=v.addr[p];a=raw & 32'h7fffc;
        // Restore the v2 four-state command contract on both sides of the
        // strict single-port bus.  !== alone is insufficient when both
        // payloads contain the same X bits.
        if($isunknown({v.addr[p],v.rd[p],v.mask[p]}) ||
           (!v.rd[p] && $isunknown(v.wd[p])) ||
           (v.scv && v.scr && $isunknown({v.saddr,v.sread,v.smask})) ||
           (v.scv && v.scr && !v.sread && $isunknown(v.swd))) begin
          `uvm_error("CMD_X",$sformatf("port=%0d command payload contains X/Z",p))
          // The designated negative injects X only on a final CPU write. Keep
          // its response paired so the residual log contains only CMD_X.
          if(cmd_x_injected || $isunknown({v.addr[p],v.rd[p],v.mask[p],v.wd[p]})) begin
            e=new;e.addr=0;e.read=0;e.value=0;e.error=0;
            pending[p]=e;cmd_x_pending[p]=1;requests[p]++;
            continue;
          end
        end
        if({v.saddr,v.sread,v.swd,v.smask}!=={raw,v.rd[p],v.wd[p],v.mask[p]})`uvm_error("BUS_PAYLOAD","slave command differs from winning master")
        e=new;e.addr=a;e.read=v.rd[p];e.cycle=cycle;e.value=0;e.error=0;
        doorbell=raw[31:4]==28'h4008000;
        if(doorbell)begin
          e.addr=raw;e.error=raw[1:0]!=0 || raw[3:2]==3 || (!v.rd[p] && v.mask[p]!=15);
          case(raw[3:2])0:e.value=base_model;1:e.value=wp_model;2:e.value={30'b0,valid_model,done_model};default:;endcase
          if(!e.error && !e.read)begin
            doorbells++;
            case(raw[3:2])
              0:begin base_model=v.wd[p];wp_model=v.wd[p];valid_model=1;done_model=0;committed_words=0;published_words=0;end
              1:begin
                if(v.wd[p]<wp_model)`uvm_error("WPTR_ROLLBACK","WPTR moved backwards")
                else if(v.wd[p]>base_model+4*committed_words)`uvm_error("EARLY_DOORBELL","WPTR covers words without completed write responses")
                else if(v.wd[p]!=base_model+4*committed_words ||
                        (committed_words-published_words!=1024 && committed_words!=v.image_words))
                  `uvm_error("WPTR_GRAIN","publication must cover 1024 words or the exact final tail")
                if(committed_words==v.image_words && committed_words%1024!=0)tail_publications++;
                wp_model=v.wd[p];published_words=committed_words;
              end
              2:begin
                if(v.wd[p][0] && (published_words!=v.image_words || committed_words!=v.image_words))`uvm_error("DONE_PUBLICATION","DONE before complete final publication")
                done_model=v.wd[p][0];
              end
              default:;
            endcase
          end
        end else if(e.read)begin
          reads[p]++;
          for(int k=0;k<4;k++)begin
            if(!mem.exists(a+k))`uvm_fatal("UNINITIALIZED_ORACLE",$sformatf("port=%0d address=%h",p,a+k))
            e.value[8*k+:8]=mem[a+k];
          end
          if(p==2 && v.contract_reads)begin
            observed=released(a);
            if(mutation=="release" && !injected)begin observed=0;injected=1;end
            if(!observed)`uvm_error("RELEASE_RULE","DMA read outside independently published interval")
          end
        end else begin
          writes[p]++;
          for(int k=0;k<4;k++)if(v.mask[p][k])mem[a+k]=v.wd[p][8*k+:8];
        end
        if(pending[p]!=null)`uvm_error("OUTSTANDING","master accepted before old response consumed")
        pending[p]=e;requests[p]++;
        if(!doorbell)memory_cov.sample(p,e.read,int'(a[18:14]),int'(v.mask[p]));
      end
    endfunction
    task run_phase(uvm_phase phase);forever begin @(posedge v.clk);sample_sram();end endtask
    function void check_phase(uvm_phase phase);
      for(int p=0;p<3;p++)begin
        if(pending[p]!=null || requests[p]!=responses[p]+cancelled[p])`uvm_error("COUNTS","request/response conservation failed")
        `uvm_info("SRAM_PORT",$sformatf("port=%0d req=%0d rsp=%0d cancelled=%0d read=%0d write=%0d cmd_stall=%0d rsp_stall=%0d max_wait=%0d",p,requests[p],responses[p],cancelled[p],reads[p],writes[p],stalls[p],rsp_stalls[p],max_wait[p]),UVM_NONE)
      end
      if(slave_requests!=slave_responses)`uvm_error("SLAVE_COUNTS","slave req != rsp")
      `uvm_info("STRICT_BUS",$sformatf("req=%0d rsp=%0d triple_grants=%0d cpu_max_wait=%0d bound=%0d doorbells=%0d tail=%0d",slave_requests,slave_responses,triple_grants,max_wait[0],cpu_bound,doorbells,tail_publications),UVM_NONE)
    endfunction
  endclass

  class kse_port_driver extends uvm_component;
    `uvm_component_utils(kse_port_driver)
    virtual kse_integration_if v;
    int port_id;
    bit cmd_x_injected;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if(!uvm_config_db#(virtual kse_integration_if)::get(this,"","vif",v)) `uvm_fatal("NOVIF","driver")
      if(!uvm_config_db#(int)::get(this,"","port_id",port_id)) `uvm_fatal("NOPORT","driver")
      cmd_x_injected=0;
    endfunction
    task access(bit read,logic[31:0] a,logic[31:0] d=0,logic[3:0] m=15,int delay=0,output logic[31:0] result,output logic error);
      @(negedge v.clk);v.cv[port_id]=1;v.addr[port_id]=a;v.rd[port_id]=read;v.wd[port_id]=d;v.mask[port_id]=m;v.rr[port_id]=0;
      // Checker-only negative: corrupt one final CPU command payload.  The
      // contract scoreboard must report CMD_X and pair its response.
      if(port_id==0 && $test$plusargs("INJECT_CMD_X") && !cmd_x_injected)begin
        v.addr[port_id]='x;v.rd[port_id]='x;v.wd[port_id]='x;v.mask[port_id]='x;
        cmd_x_injected=1;
      end
      do @(posedge v.clk);while(v.cr[port_id]!==1'b1);
      @(negedge v.clk);v.cv[port_id]=0;
      repeat(delay) @(negedge v.clk);
      v.rr[port_id]=1;
      do @(posedge v.clk);while(v.rv[port_id]!==1'b1);
      result=v.data[port_id];error=v.err[port_id];
      @(negedge v.clk);v.rr[port_id]=0;
    endtask
    task burst(bit read,int unsigned start,int words,logic[31:0] salt=0,int bubble=0);
      v.rr[port_id]=1;
      for(int i=0;i<words;i++) begin
        @(negedge v.clk);v.cv[port_id]=1;v.addr[port_id]=start+4*i;v.rd[port_id]=read;
        v.wd[port_id]=(start+4*i)^salt;v.mask[port_id]=15;
        if(port_id==0 && $test$plusargs("INJECT_CMD_X") && !cmd_x_injected)begin
          v.addr[port_id]='x;v.rd[port_id]='x;v.wd[port_id]='x;v.mask[port_id]='x;
          cmd_x_injected=1;
        end
        do @(posedge v.clk);while(v.cr[port_id]!==1'b1);
        if(bubble && $urandom_range(0,3)==0) begin
          @(negedge v.clk);v.cv[port_id]=0;repeat($urandom_range(1,bubble)) @(posedge v.clk);
        end
      end
      @(negedge v.clk);v.cv[port_id]=0;repeat(2) @(posedge v.clk);
      @(negedge v.clk);v.rr[port_id]=0;
    endtask
  endclass

endpackage
