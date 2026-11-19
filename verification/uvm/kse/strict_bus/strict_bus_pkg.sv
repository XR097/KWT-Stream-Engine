`timescale 1ns/1ps
package strict_bus_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  class strict_bus_test extends uvm_test;
    `uvm_component_utils(strict_bus_test)
    virtual strict_bus_if v;
    logic [31:0] mem[131072];
    bit known[131072];
    logic [31:0] mb=0, mw=0;
    bit mv=0, md=0;
    bit pending=0, exp_read, exp_err;
    logic [31:0] exp_data;
    int owner, accepted_at;
    int cyc=0, phase_id=0, req[3]='{default:0}, rsp[3]='{default:0}, cancel[3]='{default:0};
    int wait_now[3]='{default:0}, max_wait[3]='{default:0}, random_wait[3]='{default:0};
    int reads=0,writes=0,errors=0,stalls=0,triple=0,back_to_back=0,last_accept=-99;
    int masks_seen=0,groups_seen=0, boundary_seen=0, reset_cases=0;
    int phase_req[3]='{default:0};
    bit [2:0] cmd_held=0, rsp_held=0;
    logic [68:0] cmd_prev[3];
    logic [32:0] rsp_prev[3];
    bit slave_held=0;
    logic [68:0] slave_prev;
    bit [2:0] hs;
    string neg="";
    bit injected=0, quick=0;
    int illegal_wptr=0, before_init=0;

    covergroup contract_cg with function sample(int port_id,int group_id,int mask_id,bit read_cmd,int ph);
      option.per_instance=1;
      port_cp: coverpoint port_id { bins each_port[]={ [0:2] }; }
      group_cp: coverpoint group_id { bins each_group[]={ [0:31] }; }
      mask_cp: coverpoint mask_id { bins each_mask[]={ [0:15] }; }
      read_cp: coverpoint read_cmd;
      phase_cp: coverpoint ph { bins stages[]={ [0:8] }; }
      port_group: cross port_cp,group_cp;
    endgroup
    function new(string name="strict_bus_test",uvm_component parent=null);
      super.new(name,parent); contract_cg=new();
    endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if(!uvm_config_db#(virtual strict_bus_if)::get(this,"","vif",v)) `uvm_fatal("CONFIG","vif absent")
      void'($value$plusargs("NEG=%s",neg)); quick=$test$plusargs("QUICK");
    endfunction
    function bit mutate(string id);
      if(neg==id && !injected) begin
        injected=1; `uvm_info("NEG_INJECT",$sformatf("checker=%s cycle=%0d",id,cyc),UVM_LOW)
        return 1;
      end
      return 0;
    endfunction
    function void ck(bit ok,string id,string detail);
      if(!ok) `uvm_error(id,$sformatf("cycle=%0d phase=%0d %s",cyc,phase_id,detail))
    endfunction
    function logic [31:0] pattern(int a);
      return 32'h91e6b73d ^ (a * 32'h9e3779b9);
    endfunction
    function void issue(int p,logic[31:0] a,bit r,logic[31:0] d=0,logic[3:0] m=15);
      v.cv[p]=1;v.addr[p]=a;v.rd[p]=r;v.wd[p]=d;v.mask[p]=m;
    endfunction

    // Single independent global ordered reference queue: the contract permits
    // only one outstanding response. Read values are captured at acceptance,
    // byte writes update our own array, and nothing calls design-side TB code.
    task sample_bus();
      int count, winner, observed_owner, n, a, g;
      bit observed_valid, good, ismem, regok;
      logic [31:0] expected_groups, db_base, data_cmp;
      logic [68:0] payload;
      logic [32:0] response_payload;
      cyc++;
      if(!v.rst_n) begin
        ck(v.rv===0 && v.srv===0,"RESET","response visible during reset");
        return;
      end
      db_base=mb;
      if(mv && mutate("DOORBELL")) db_base^=4;
      ck({v.base,v.wptr,v.valid,v.done}==={db_base,mw,mv,md},"DOORBELL","progress register/reference mismatch");
      ck(v.wp_ready===1 && v.wp_data===(v.wp_read ? mw:32'b0),"DOORBELL","read-only WPTR observation mismatch");
      if(pending) begin
        observed_valid=v.srv;
        if(cyc==accepted_at+1 && mutate("LATENCY")) observed_valid=0;
        ck(observed_valid===1,"LATENCY","response missing at next cycle or while pending");
      end else begin
        observed_valid=(|v.rv) || v.srv;
        // Late response is injected at the checker observation boundary after
        // reset with no pending request. It cannot contaminate routing/data.
        if(reset_cases>0 && mutate("RESET")) observed_valid=1;
        ck(!observed_valid,"RESET","unsolicited/late response without a current-epoch command");
      end
      for(int p=0;p<3;p++) begin
        payload={v.addr[p],v.rd[p],v.wd[p],v.mask[p]};
        if(cmd_held[p]) begin
          if(mutate("CMD_HOLD")) payload^=1;
          ck(v.cv[p]===1 && payload===cmd_prev[p],"CMD_HOLD",$sformatf("master=%0d changed stalled command",p));
        end
        cmd_prev[p]={v.addr[p],v.rd[p],v.wd[p],v.mask[p]};
        cmd_held[p]=v.cv[p] && !v.cr[p];
        response_payload={v.err[p],v.data[p]};
        if(rsp_held[p]) begin
          if(mutate("RSP_HOLD")) response_payload^=1;
          ck(v.rv[p]===1 && response_payload===rsp_prev[p],"RSP_HOLD",$sformatf("master=%0d changed stalled response",p));
        end
        rsp_prev[p]={v.err[p],v.data[p]};
        rsp_held[p]=v.rv[p] && !v.rr[p];
        if(v.rv[p]) begin
          if(pending) begin
            observed_owner=p;
            if(mutate("ORDER")) observed_owner=(p+1)%3;
            ck(observed_owner==owner,"ORDER",$sformatf("response owner=%0d expected=%0d",observed_owner,owner));
            data_cmp=exp_data;
            if(exp_read && !exp_err && mutate("DATA")) data_cmp^=1;
            ck(v.err[p]===exp_err && (!exp_read || exp_err || v.data[p]===data_cmp),"DATA",
               $sformatf("master=%0d got=%08x/%b expected=%08x/%b",p,v.data[p],v.err[p],data_cmp,exp_err));
          end
          if(v.rr[p]) rsp[p]++;
          else stalls++;
        end
        if(v.cv[p] && !v.cr[p]) begin
          wait_now[p]++;
          if(wait_now[p]>max_wait[p]) max_wait[p]=wait_now[p];
          if(phase_id==7 && wait_now[p]>random_wait[p]) random_wait[p]=wait_now[p];
        end else wait_now[p]=0;
      end
      payload={v.sa,v.srd,v.swd,v.sm};
      if(slave_held) ck(v.scv===1 && payload===slave_prev,"CMD_HOLD","slave command changed under backpressure");
      slave_prev=payload;slave_held=v.scv && !v.scr;
      if(v.srv && v.srr) pending=0;
      hs=v.cv & v.cr;
      count=$countones(hs);
      n=count;
      if(count==1 && mutate("SINGLE_PORT")) n=2;
      ck(n<=1 && ((v.scv && v.scr)==(count==1)),"SINGLE_PORT","master/slave acceptance count mismatch");
      if(v.cv==7) triple++;
      if(count==1) begin
        ck(!pending,"SINGLE_PORT","new command while previous response unconsumed");
        winner=v.cv[2]?2:(v.cv[1]?1:0);
        n=winner;
        if(v.cv==7 && mutate("PRIORITY")) n=0;
        ck(hs[n]===1,"PRIORITY",$sformatf("grant=%b highest request=%0d",hs,n));
        for(int p=0;p<3;p++) if(hs[p]) begin
          owner=p;req[p]++;phase_req[p]++;
          ck({v.sa,v.srd,v.swd,v.sm}==={v.addr[p],v.rd[p],v.wd[p],v.mask[p]},"ORDER","slave payload does not match granted master");
        end
        if(cyc==last_accept+1) back_to_back++;
        last_accept=cyc;accepted_at=cyc;
        ismem=(v.sa<32'h80000) || (v.sa>=32'h40000000 && v.sa<32'h40080000);
        regok=(v.sa>=32'h40080000 && v.sa<=32'h40080008 && v.sa[1:0]==0 && (v.srd || v.sm==15));
        exp_read=v.srd;exp_err=!ismem && !regok;exp_data=0;
        if(ismem) begin
          a=(v.sa & 32'h7ffff)/4;g=a/4096;
          expected_groups=32'b1 << g;
          groups_seen|=(1<<g);
          if(a%4096==0 || a%4096==4095) boundary_seen++;
          if(v.srd) begin
            ck(known[a],"DATA",$sformatf("read before test initialization word=%0d",a));
            exp_data=mem[a]; reads++;
          end else begin
            for(int j=0;j<4;j++) if(v.sm[j]) mem[a][8*j+:8]=v.swd[8*j+:8];
            if(v.sm==15)known[a]=1;
            writes++;masks_seen|=(1<<v.sm);
          end
          contract_cg.sample(owner,g,int'(v.sm),v.srd,phase_id);
        end else begin
          expected_groups=0;
          if(exp_err) errors++;
          if(regok) begin
            case(v.sa[3:2])
              0: exp_data=mb;
              1: exp_data=mw;
              2: exp_data={30'b0,mv,md};
            endcase
            if(!v.srd) case(v.sa[3:2])
              0: begin mb=v.swd;mw=v.swd;mv=1;md=0;end
              1: begin
                if(!mv) before_init++;
                if(mv && v.swd<mw) illegal_wptr++;
                mw=v.swd;
              end
              2: md=v.swd[0];
            endcase
          end
        end
        if(ismem && mutate("GROUP_MAP")) expected_groups^=1;
        ck(v.groups===expected_groups,"GROUP_MAP",$sformatf("selected=%08x expected=%08x",v.groups,expected_groups));
        pending=1;
      end else ck(v.groups===0,"GROUP_MAP","macro enabled without a command");
    endtask
    task tick();
      @(posedge v.clk);sample_bus();@(negedge v.clk);
    endtask
    task drain();
      int n=0;
      v.rr=7;
      while((|v.cv)||pending) begin
        tick(); v.cv &= ~hs;
        n++; if(n>2000) `uvm_fatal("DRAIN","drain timeout")
      end
      repeat(2)tick();
    endtask
    task transaction(int p,logic[31:0] a,bit r,logic[31:0] d=0,logic[3:0] m=15,int hold=0);
      int n=0;
      issue(p,a,r,d,m);v.rr=7;
      do begin tick();n++;if(n>2000)`uvm_fatal("DRIVER","handshake timeout") end while(!hs[p]);
      v.cv[p]=0;
      if(hold>0) begin v.rr[p]=0;repeat(hold)tick();v.rr[p]=1;end
      while(pending)tick();
    endtask
    task reset_bus();
      if(pending)cancel[owner]++;
      pending=0;v.cv=0;v.rr=0;v.rst_n=0;
      cmd_held=0;rsp_held=0;slave_held=0;
      mb=0;mw=0;mv=0;md=0;
      repeat(3)tick();v.rst_n=1;v.rr=7;
      repeat(4)tick();
    endtask
    task stream(int port_id,int first,int length,bit r,bit full_address=0);
      bit accepted;
      for(int k=0;k<length;k++) begin
        issue(port_id,(first+k)*4+(full_address?32'h40000000:0),r,pattern(first+k));
        tick();accepted=hs[port_id];if(mutate("THROUGHPUT"))accepted=0;ck(accepted,"THROUGHPUT","single ready master failed to accept one command per cycle");
      end
      v.cv=0;drain();
    endtask
    task run_phase(uvm_phase phase);
      int size,idx,before_req[3],budget[3],launched[3],cpu_before;
      logic [31:0] a;
      phase.raise_objection(this);
      @(negedge v.clk);reset_bus();
      phase_id=0;
      // Real macros have no reset initialization: seed every location by ICB.
      size=quick?256:131072;
      stream(0,0,size,0,1);
      // Both sides of all 31 macro boundaries plus first/middle/last words.
      for(int g=0;g<32;g++) begin
        transaction(g%3,g*16384,0,pattern(g*4096));
        transaction((g+1)%3,g*16384+16380,0,pattern(g*4096+4095));
        transaction((g+2)%3,32'h40000000+g*16384,1);
        transaction(g%3,32'h40000000+g*16384+16380,1);
      end
      phase_id=1;
      for(int p=0;p<3;p++) for(int m=0;m<16;m++) begin
        transaction(p,32'h40000080+p*4,0,32'h5ac391e7^m,4'(m));
        transaction((p+1)%3,32'h80+p*4,1,0,15,3);
      end
      phase_id=2;v.rr=7;
      // Three sustained finite streams: DMA exclusively, then loader, then CPU.
      budget='{32,48,96};launched='{0,0,0};
      for(int p=0;p<3;p++)begin before_req[p]=req[p];issue(p,32'h100+p*4,1);end
      while((|v.cv)||pending) begin
        tick();
        for(int p=0;p<3;p++) if(hs[p]) begin
          launched[p]++;
          if(launched[p]==budget[p])v.cv[p]=0;
        end
      end
      for(int p=0;p<3;p++)ck(req[p]-before_req[p]==budget[p],"CONSERVATION","finite priority stream lost a request");
      // Stall DMA response while both other agents have stable waiting commands.
      issue(2,32'h100,1);v.rr=7;tick();v.cv[2]=0;v.rr[2]=0;
      issue(0,32'h104,1);issue(1,32'h108,1);
      repeat(12)tick();drain();
      phase_id=3;
      transaction(1,32'h40080004,0,32'h400); // before INIT: accepted, VALID remains zero
      transaction(0,32'h40080008,0,1); // DONE before INIT: status becomes 1 (invalid)
      transaction(2,32'h40080008,1);
      transaction(1,32'h40080000,0,32'h1000);
      transaction(0,32'h40080000,1);transaction(0,32'h40080004,1);transaction(0,32'h40080008,1);
      transaction(1,32'h40080004,0,32'h2000);
      transaction(2,32'h40080004,1,0,15,4);
      transaction(1,32'h40080004,0,32'h1800); // decreasing bound: explicit policy observation
      transaction(0,32'h40080004,1);
      transaction(1,32'h40080008,0,3);transaction(0,32'h40080008,1);
      transaction(1,32'h40080008,0,2);transaction(0,32'h40080008,1);
      phase_id=4;
      // Decode/width errors must leave every progress register unchanged.
      transaction(0,32'h4008000c,0,0);transaction(1,32'h4008000c,1);
      for(int i=1;i<4;i++)begin transaction(i%3,32'h40080000+i,0,0);transaction(i%3,32'h40080004+i,1);end
      for(int m=0;m<15;m++)transaction(m%3,32'h40080004,0,32'hdeadbeef,4'(m));
      transaction(2,32'h40080010,0,0);transaction(0,32'h400ffffc,1);transaction(1,32'h80000000,1);
      phase_id=5;
      // New BASE starts an empty interval, including zero length and rollback.
      for(int k=0;k<3;k++)begin
        transaction(1,32'h40080000,0,(k==0)?32'h3000:((k==1)?0:32'h4000));
        transaction(0,32'h40080004,1);transaction(1,32'h40080008,0,1);transaction(2,32'h40080008,1);
      end
      phase_id=6;
      for(int p=0;p<3;p++)begin
        // Cancel a real held response and another master's unaccepted request.
        issue(p,32'h80,1);v.rr=7;tick();v.cv[p]=0;v.rr[p]=0;
        issue((p+1)%3,32'h84,1);repeat(3)tick();
        reset_cases++;reset_bus();
        transaction(p,32'h80,1); // SRAM contents survive reset
        transaction(p,32'h40080008,1); // progress does not
      end
      phase_id=7;launched='{0,0,0};budget='{1200,1200,1200};
      cpu_before=req[0];
      for(int k=0;k<100000;k++)begin
        for(int p=0;p<3;p++)begin
          v.rr[p]=($urandom_range(0,99)<65);
          if(!v.cv[p] && launched[p]<budget[p] && $urandom_range(0,99)<(p==2?55:40))begin
            idx=$urandom_range(0,size-1);a=idx*4;
            if($urandom_range(0,1))a+=32'h40000000;
            issue(p,a,($urandom_range(0,99)<55),$urandom,4'($urandom_range(0,15)));
          end
        end
        tick();
        for(int p=0;p<3;p++)if(hs[p])begin launched[p]++;v.cv[p]=0;end
        if(launched[0]==budget[0]&&launched[1]==budget[1]&&launched[2]==budget[2])break;
        if(k==99999)`uvm_fatal("LIVENESS","finite typical load did not drain")
      end
      drain();ck(req[0]-cpu_before==1200,"CONSERVATION","CPU did not complete under gapped finite traffic");
      phase_id=8;
      stream(2,0,size,1,1);
      // Additional ready stream gives a clean no-bubble witness.
      stream(1,0,256,1);
      for(int p=0;p<3;p++) begin
        idx=rsp[p];if(p==0 && mutate("CONSERVATION"))idx++;
        ck(req[p]==idx+cancel[p],"CONSERVATION",$sformatf("port=%0d req=%0d rsp=%0d cancelled=%0d",p,req[p],idx,cancel[p]));
        `uvm_info("COUNTS",$sformatf("port=%0d req=%0d rsp=%0d cancelled=%0d max_wait=%0d random_max_wait=%0d",p,req[p],rsp[p],cancel[p],max_wait[p],random_wait[p]),UVM_LOW)
      end
      idx=masks_seen;if(mutate("COVERAGE"))idx^=1;
      ck(groups_seen=='1 && idx==65535 && reset_cases==3,"COVERAGE","required groups/masks/reset scenarios absent");
      if(neg!="")ck(injected,"NEG_MISSING","designated injection was not reached");
      `uvm_info("METRICS",$sformatf("cycles=%0d reads=%0d writes=%0d decode_errors=%0d response_stall_cycles=%0d triple_request_cycles=%0d consecutive_accepts=%0d boundary_accesses=%0d wp_before_init=%0d wp_decrease=%0d groups=%08x masks=%04x",cyc,reads,writes,errors,stalls,triple,back_to_back,boundary_seen,before_init,illegal_wptr,groups_seen,masks_seen),UVM_LOW)
      `uvm_info("COMPLETE","STRICT_BUS_COMPLETE",UVM_NONE)
      if(uvm_report_server::get_server().get_severity_count(UVM_ERROR)==0 && uvm_report_server::get_server().get_severity_count(UVM_FATAL)==0)$display("TEST PASSED");
      else $display("TEST FAILED");
      phase.drop_objection(this);
    endtask
  endclass
endpackage
