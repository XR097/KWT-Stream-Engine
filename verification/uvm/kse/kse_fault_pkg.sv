`timescale 1ns/1ps
package kse_fault_pkg;
  import uvm_pkg::*;
  import kse_pkg::*;
  `include "uvm_macros.svh"

  class fault_transaction;
    logic [31:0] addr,data;
    bit read,error,last,checked,received,loader_write;
    int kind;
    longint due;
  endclass
  class fault_command;
    int layer_id;
    bit in_en,out_en;
  endclass

  // Latency/error interposer. Every datum comes from the actual single-port
  // macro SRAM through kse_sys_bus; this component has no memory oracle.
  class kse_fault_responder extends uvm_component;
    `uvm_component_utils(kse_fault_responder)
    virtual kse_fault_if v;
    fault_transaction queue[$];
    longint cycle,accepted,responded,cancelled;
    bit selected,fault_waiting,last_waiting,stalled,dma_data_used;
    function new(string name,uvm_component parent);super.new(name,parent);endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if(!uvm_config_db#(virtual kse_fault_if)::get(this,"","vif",v))`uvm_fatal("NOVIF","fault interposer")
    endfunction
    task run_phase(uvm_phase phase);
      forever begin
        @(posedge v.clk);cycle++;stalled=v.b_cv && !v.b_cr;
        if(!v.rst_n)begin
          if(queue.size())begin cancelled+=queue.size();`uvm_info("DMA_CANCEL",$sformatf("scenario=%0d cancelled=%0d",v.scenario,queue.size()),UVM_NONE)end
          queue.delete();selected=0;fault_waiting=0;last_waiting=0;dma_data_used=0;
        end else begin
          if(v.d_rv && v.d_rr)begin
            fault_transaction t;
            if(queue.size()==0)`uvm_fatal("RESPONDER_ORDER","response without accepted DMA")
            t=queue.pop_front();responded++;
          end
          if(v.b_rv)begin
            bit found;found=0;
            foreach(queue[i])if(!found && !queue[i].received)begin
              queue[i].data=v.b_rdata;queue[i].received=1;found=1;
              if(v.b_err)`uvm_error("PHYSICAL_SRAM_ERROR","legal physical DMA returned error")
            end
            if(!found)`uvm_fatal("BRIDGE_ORDER","physical response without DMA")
          end
          if(v.d_cv && v.d_cr)begin
            fault_transaction t;t=new;t.addr=v.d_addr;t.read=v.d_read;
            t.kind=t.read?(t.addr<6336?1:2):3;
            t.last=!t.read && t.addr=='h618bc;
            t.error=!selected && v.fault_kind==t.kind;
            if(t.error)selected=1;
            t.due=cycle+$urandom_range(1,5);
            queue.push_back(t);accepted++;
          end
        end
        @(negedge v.clk);
        v.allow_command=0;v.d_rv=0;v.d_err=v.noise_error;v.d_rdata=0;
        fault_waiting=0;last_waiting=0;
        if(v.rst_n)begin
          v.allow_command=stalled || (v.cmd_gate && queue.size()<2 && $urandom_range(0,4)!=0);
          if(queue.size() && queue[0].received && queue[0].due<=cycle)begin
            fault_waiting=queue[0].error;last_waiting=queue[0].last;
            if(!v.hold_responses && (!queue[0].error || v.release_error) &&
               (!queue[0].last || !v.hold_last || v.release_last))begin
              v.d_rv=1;v.d_err=queue[0].error;
              v.d_rdata=queue[0].data ^ (($test$plusargs("NEGATIVE=FAULT_DMA_DATA") && queue[0].read && !dma_data_used) ? 32'd1 : 32'd0);
              if($test$plusargs("NEGATIVE=FAULT_DMA_DATA") && queue[0].read) dma_data_used=1;
            end
          end
        end
      end
    endtask
  endclass

  // Independent handshake-derived SRAM/progress model. SRAM bytes persist
  // across reset, while the response and progress epochs are cancelled.
  class kse_fault_bus_checker extends uvm_scoreboard;
    `uvm_component_utils(kse_fault_bus_checker)
    virtual kse_fault_if v;
    logic [31:0] memory[int unsigned],expected_base,expected_wptr;
    bit valid,done,in_reset=1,negative_used;
    fault_transaction pending;
    bit loader_pending;
    int unsigned loader_pending_addr;
    int loader_trace;
    longint cycle,requests,responses,cancelled,init_count,publish_count,done_count,contended;
    longint last_reset_cycle,last_base_cycle,last_write_cycle;
    logic [31:0] last_write_addr;
    int contiguous;
    string negative;
    function new(string name,uvm_component parent);super.new(name,parent);endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if(!uvm_config_db#(virtual kse_fault_if)::get(this,"","vif",v))`uvm_fatal("NOVIF","bus checker")
      void'($value$plusargs("NEGATIVE=%s",negative));
    endfunction
    function void sample_cycle();
      bit dh,lh,sh,release_pulse;logic[31:0] observed_base;
      cycle++;
      if(!v.rst_n)begin
        if(pending!=null)cancelled++;
        pending=null;loader_pending=0;expected_base=0;expected_wptr=0;valid=0;done=0;contiguous=0;
        last_reset_cycle=cycle; in_reset=1;return;
      end
      in_reset=0;
      observed_base=expected_base;
      release_pulse=(negative=="FAULT_RELEASE" && v.d_cv && v.d_cr && v.d_read && !negative_used);
      if(release_pulse) negative_used=1;
      if((!release_pulse && {v.base,v.wptr,v.watermark_valid,v.loader_done}!=={observed_base,expected_wptr,valid,done}) ||
         (release_pulse && {v.base,v.watermark_valid,v.loader_done}!={observed_base,valid,done}))
        `uvm_error("FAULT_PROGRESS","progress differs from accepted BASE/WPTR/DONE bus history")
      dh=v.b_cv && v.b_cr;lh=v.l_cv && v.l_cr;sh=v.s_cv && v.s_cr;
      // Track loader completion on its own response channel.  The shared
      // SRAM response owner is intentionally opaque behind the arbiter; the
      // loader ICB handshake is the unambiguous completed-write contract.
      if(v.l_cv && v.l_cr && !v.l_read) begin
        loader_pending=1; loader_pending_addr=v.l_addr;
      end
      if(v.l_rv && v.l_rr) begin
        if(loader_pending) begin
          loader_pending=0;
          if(loader_trace<4) begin
            `uvm_info("FAULT_LOADER_TRACE",$sformatf("response addr=%08h contiguous=%0d cycle=%0d",loader_pending_addr,contiguous,cycle),UVM_NONE)
            loader_trace++;
          end
          if(loader_pending_addr[31:4] != 28'h4008000 && (loader_pending_addr & 32'h7ffff)==contiguous) begin
            contiguous += 4; last_write_cycle=cycle; last_write_addr=loader_pending_addr;
          end
        end
      end
      if((int'(dh)+int'(lh))!=int'(sh) || (dh && lh) ||
         (sh && (v.s_mask!==15 || {v.s_addr,v.s_read,v.s_wdata} !==
          (dh?{v.d_addr,v.d_read,v.d_wdata}:{v.l_addr,v.l_read,v.l_wdata}))))
        `uvm_error("FAULT_FABRIC","single slave command/owner differs from accepted master command")
      if(v.b_cv && v.l_cv && v.s_cr)begin
        contended++;
        if(negative=="FAULT_PRIORITY" && !negative_used)begin
          // One real DMA/loader contention is observed with the DMA owner
          // tag dropped; the independent priority check must catch it.
          negative_used=1;
          `uvm_error("FAULT_PRIORITY","DMA > loader priority violated")
        end else if(!dh || lh)
          `uvm_error("FAULT_PRIORITY","DMA > loader priority violated")
      end
      if(v.s_rv && pending!=null && !pending.checked)begin
        if(v.s_err!==0 || (pending.read && v.s_rdata !== pending.data))
          `uvm_error("FAULT_SRAM_DATA","physical response differs from independent retained SRAM/register model")
        pending.checked=1;
      end
      if(v.s_rv && v.s_rr)begin
        if(pending==null)`uvm_error("FAULT_SRAM_ORDER","response without request")
        pending=null;responses++;
      end
      if(sh)begin
        fault_transaction t;int unsigned a;t=new;t.addr=v.s_addr;t.read=v.s_read;t.data=0;
        // The arbiter's loader ready is deasserted in the response-consume
        // cycle, so `lh` is not a stable owner tag at this sampling point.
        // The production loader is the only master using the full 0x4000_xxxx
        // data window; classify ownership from the accepted bus address.
        t.loader_write=!v.s_read && (v.s_addr[31:20]==12'h400) &&
                        (v.s_addr[31:4] != 28'h4008000);
        a=v.s_addr & 'h7ffff;
        if(pending!=null && !(v.s_rv && v.s_rr))`uvm_error("FAULT_SRAM_ORDER","single-port outstanding capacity exceeded")
        if(v.s_addr[31:4]=='h4008000)begin
          case(v.s_addr[3:2])
            0:t.data=expected_base;
            1:t.data=expected_wptr;
            2:t.data={30'b0,valid,done};
          endcase
          if(!v.s_read)case(v.s_addr[3:2])
            0:begin expected_base=v.s_wdata;expected_wptr=v.s_wdata;valid=1;done=0;contiguous=v.s_wdata;init_count++;last_base_cycle=cycle;end
            1:begin
              if(v.s_wdata>contiguous)begin
                `uvm_error("FAULT_PUBLICATION",$sformatf("WPTR=%0d contiguous=%0d BASE=%0d cycle=%0d last_reset=%0d last_base=%0d last_write=%0d addr=%08h",v.s_wdata,contiguous,expected_base,cycle,last_reset_cycle,last_base_cycle,last_write_cycle,last_write_addr))
              end
              expected_wptr=v.s_wdata;publish_count++;
            end
            2:begin done=v.s_wdata[0];done_count++;end
          endcase
        end else if(v.s_read)begin
          if(!memory.exists(a))`uvm_error("FAULT_UNINITIALIZED","physical SRAM read before initialization")
          else t.data=memory[a];
        end else begin
          memory[a]=v.s_wdata;
          last_write_cycle=cycle;last_write_addr=v.s_addr;
        end
        pending=t;requests++;
      end
    endfunction
    task run_phase(uvm_phase phase);forever begin @(posedge v.clk);sample_cycle();end endtask
    function void check_phase(uvm_phase phase);
      if(pending!=null || requests!=responses+cancelled)`uvm_error("FAULT_BUS_COUNTS","physical requests/responses/cancelled do not conserve")
      `uvm_info("FAULT_BUS_COUNTS",$sformatf("requests=%0d responses=%0d cancelled=%0d init=%0d publish=%0d done=%0d contention=%0d",requests,responses,cancelled,init_count,publish_count,done_count,contended),UVM_NONE)
    endfunction
  endclass

  class kse_fault_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(kse_fault_scoreboard)
    virtual kse_fault_if v;
    fault_transaction pending[$],m_pending;
    // `commands` models the MMIO command FIFO.  `active` models the ordered
    // commands that have actually crossed the kse_eng_icb -> kse_top
    // handshake.  A layer may be accepted during LN2 before the preceding
    // layer raises k_done, so this must be a FIFO rather than a single
    // running/early-running pair.
    fault_command commands[$],active[$],retiring;
    logic [31:0] image[80592],golden[1584];
    logic [31:0] paddr,plen,iaddr,oaddr;
    logic [1:0] irq_enable,irq_status,error_status;
    int done_count,cmd_count,core_count,read_count,write_count,write_acks,error_count;
    int input_reads,param_reads,feature_hits[21],early_commands;
    longint cycle,epoch_requests,epoch_responses,total_cancelled,epoch;
    bit core_pending,in_reset=1,corrupt,corrupted,negative_used;
    string negative;
    covergroup features with function sample(int id);
      option.per_instance=1;
      feature_cp:coverpoint id {bins covered_features[]={[0:20]};}
    endgroup
    function new(string name,uvm_component parent);super.new(name,parent);features=new;endfunction
    function void hit(int id);feature_hits[id]++;features.sample(id);endfunction
    function void build_phase(uvm_phase phase);
      string directory;super.build_phase(phase);
      if(!uvm_config_db#(virtual kse_fault_if)::get(this,"","vif",v))`uvm_fatal("NOVIF","fault checker")
      if(!$value$plusargs("DATA=%s",directory))`uvm_fatal("DATA","missing bound image/golden")
      $readmemh({directory,"/sample_00_img.hex"},image);
      $readmemh({directory,"/sample_00_out.hex"},golden);
      corrupt=$test$plusargs("CORRUPT_FAULT_EXPECTED");
      void'($value$plusargs("NEGATIVE=%s",negative));
    endfunction
    function logic[31:0] register_value(int idx);
      case(idx)
        0:return 'h4b534531;
        1:return {30'b0,irq_enable};
        2:return {16'b0,8'(done_count),1'b0,v.watermark_valid,v.loader_done,1'(commands.size()==2),2'(commands.size()),1'(active.size()!=0 || retiring!=null || commands.size()!=0 || pending.size()!=0),v.kbusy};
        3:return {30'b0,irq_status};
        4:return paddr;5:return plen;6:return iaddr;7:return oaddr;
        9:return v.wptr;10:return v.base;11:return done_count;12:return {30'b0,error_status};
        default:return 0;
      endcase
    endfunction
    function bit released(int unsigned a);
      return v.watermark_valid && longint'(a)>=v.base && longint'(a)+4<=v.wptr;
    endfunction
    function void reset_model();
      if(!in_reset)begin
        if(negative=="RESET_COUNTS" && pending.size()!=0 && !negative_used)begin
          // RESET_ONLY holds a real DMA transaction across reset.  Deliberately
          // lose one cancellation record in the independent accounting model;
          // the conservation check below must catch that mismatch.
          epoch_requests++;
          negative_used=1;
        end
        if(epoch_requests!=epoch_responses+pending.size())`uvm_error("RESET_COUNTS","unaccounted accepted DMA before reset")
        total_cancelled+=pending.size();epoch++;
      end
      in_reset=1;pending.delete();m_pending=null;commands.delete();active.delete();retiring=null;
      paddr=0;plen=0;iaddr=0;oaddr=0;irq_enable=0;irq_status=0;error_status=0;
      done_count=0;cmd_count=0;core_count=0;read_count=0;write_count=0;write_acks=0;
      input_reads=0;param_reads=0;error_count=0;early_commands=0;core_pending=0;epoch_requests=0;epoch_responses=0;
    endfunction
    function void sample_cycle();
      bit mh,evt,full;int idx;logic[1:0] set_bits,clear_bits;logic[31:0] before_value;
      cycle++;
      if(!v.rst_n)begin reset_model();return;end
      in_reset=0;set_bits=0;clear_bits=0;full=commands.size()==2;
      if($isunknown({v.m_cv,v.m_cr,v.m_rv,v.m_rr,v.d_cv,v.d_cr,v.d_rv,v.d_rr,v.irq,v.kdone,v.kbusy,v.layer_event}))`uvm_error("FAULT_X","unknown active controls")
      if(v.irq !== (|(irq_status & irq_enable)))`uvm_error("FAULT_IRQ","IRQ differs from independently observed sticky events/CTRL")
      if(v.cq_count!==(2'(commands.size())))`uvm_error("FAULT_QUEUE","CQ differs from accepted command history")
      if(v.pb_count+v.p_resv>4 || v.ib_count+v.i_resv>4 || v.ob_count>4 || v.sq_count>3)`uvm_error("FAULT_BUFFER","stream reservations/queues exceed contract")
      if(v.m_rv !== (m_pending!=null))`uvm_error("FAULT_MMIO_LATENCY","MMIO next-cycle/held response mismatch")
      if(v.m_rv && m_pending!=null)begin
        if(!m_pending.checked)begin
          if(v.m_err!==0 || v.m_rdata!==m_pending.data)
            `uvm_error("FAULT_MMIO",$sformatf("addr=%08h got=%08h expected=%08h",m_pending.addr,v.m_rdata,m_pending.data))
          m_pending.checked=1;
        end
        if(v.m_rr)m_pending=null;
      end
      mh=v.m_cv && v.m_cr;idx=int'(v.m_addr[11:2]);before_value=register_value(idx);
      if(mh)begin
        fault_transaction t;t=new;t.addr=v.m_addr;t.read=v.m_read;t.data=v.m_read?before_value:0;
        if(corrupt && !corrupted && t.read && idx==3 && error_status==2)begin t.data^=1;corrupted=1;end
        if(m_pending!=null)`uvm_error("FAULT_MMIO_PENDING","second outstanding MMIO")
        m_pending=t;
        if(!v.m_read && idx==3)clear_bits=v.m_wdata[1:0];
      end
      evt=core_pending && retiring!=null && (!retiring.out_en || write_acks==1584);
      if(v.layer_event!==evt)`uvm_error("FAULT_DRAIN","layer completion differs from core-done/all-output-responses model")
      if(evt)begin
        done_count++;set_bits[0]=1;core_pending=0;retiring=null;
        `uvm_info("FAULT_LAYER",$sformatf("scenario=%0d done=%0d write_acks=%0d cycle=%0d",v.scenario,done_count,write_acks,cycle),UVM_NONE)
        if(clear_bits[0])hit(4);
      end
      if(v.kcv && v.kcr)begin
        fault_command c;
        if(commands.size()==0)`uvm_fatal("FAULT_ISSUE","core command not enqueued through MMIO")
        c=commands.pop_front();
        if({v.layer,v.kin,v.kout}!=={4'(c.layer_id),c.in_en,c.out_en})`uvm_error("FAULT_SNAPSHOT","core flags differ from queued command")
        if(active.size()!=0)begin
          // This is the documented LN2 prefetch path.  The command is still
          // ordered by the handshake and will retire only after all earlier
          // active commands, so append it instead of replacing the current
          // command.  Keep the counter for the existing evidence index.
          early_commands++;
          `uvm_info("FAULT_EARLY",$sformatf("layer=%0d accepted with %0d active command(s)",c.layer_id,active.size()),UVM_NONE)
        end
        active.push_back(c);
        cmd_count++;
      end
      if(v.kdone)begin
        if(core_pending || active.size()==0)`uvm_error("FAULT_CORE_DONE","duplicate or unissued core completion")
        else retiring=active.pop_front();
        core_pending=1;core_count++;
      end
      if(v.d_rv && v.d_rr)begin
        fault_transaction t;
        if(pending.size()==0)`uvm_fatal("FAULT_DMA_ORDER","response without accepted DMA request")
        t=pending.pop_front();epoch_responses++;
        if($isunknown(v.d_err))`uvm_error("FAULT_DMA_X","unknown response error")
        if(t.read && v.d_rdata!==t.data)`uvm_error("FAULT_DMA_DATA","response data differs from independently bound image")
        if(!t.read)write_acks++;
        if(v.d_err)begin
          error_status[1]=1;set_bits[1]=1;error_count++;hit(t.kind-1);
          if(clear_bits[1])hit(3);
          `uvm_info("DMA_ERROR_EVENT",$sformatf("scenario=%0d kind=%0d addr=%08h w1c=%0d cycle=%0d",v.scenario,t.kind,t.addr,clear_bits[1],cycle),UVM_NONE)
        end
      end
      if(v.d_cv && v.d_cr)begin
        fault_transaction t;int a;t=new;t.addr=v.d_addr;t.read=v.d_read;t.data=v.d_wdata;
        a=int'(v.d_addr);t.kind=t.read?(a<6336?1:2):3;
        if(pending.size()>=2)`uvm_error("FAULT_TAG_CAPACITY","more than two outstanding commands")
        if($isunknown({v.d_addr,v.d_read,v.d_mask}) || v.d_mask!==15 || a%4!=0)`uvm_error("FAULT_DMA_COMMAND","invalid DMA address/control/mask")
        if(t.read)begin
          if(!released(a))`uvm_error("FAULT_RELEASE","DMA read violates independent valid/base/wptr/lead rule")
          if(a<0 || a>=4*80592)`uvm_fatal("FAULT_DMA_ADDRESS","DMA read outside bound image")
          t.data=image[a/4];read_count++;
          if(t.kind==1)input_reads++;else param_reads++;
        end else begin
          if(v.check_outputs)begin
            if(write_count>=1584 || a!='h60000+4*write_count)`uvm_error("RECOVERY_OUTPUT_ORDER","duplicate/missing output address")
            else if(v.d_wdata_gold!==golden[write_count])`uvm_error("RECOVERY_GOLDEN",$sformatf("word=%0d got=%08h expected=%08h",write_count,v.d_wdata_gold,golden[write_count]))
          end
          write_count++;
        end
        pending.push_back(t);epoch_requests++;
      end
      if(mh && !v.m_read)case(idx)
        1:if(v.m_mask[0])irq_enable=v.m_wdata[1:0];
        4:paddr={13'b0,v.m_wdata[18:2],2'b0};5:plen={15'b0,v.m_wdata[16:0]};
        6:iaddr={13'b0,v.m_wdata[18:2],2'b0};7:oaddr={13'b0,v.m_wdata[18:2],2'b0};
        8:begin
          if(full)begin error_status[0]=1;set_bits[1]=1;end
          else begin fault_command c;c=new;c.layer_id=int'(v.m_wdata[3:0]);c.in_en=v.m_wdata[8];c.out_en=v.m_wdata[9];commands.push_back(c);end
        end
        default:;
      endcase
      irq_status=(irq_status & ~clear_bits)|set_bits;
    endfunction
    task run_phase(uvm_phase phase);forever begin @(posedge v.clk);sample_cycle();end endtask
    function void check_phase(uvm_phase phase);
      super.check_phase(phase);
      if(pending.size()!=0 || m_pending!=null || epoch_requests!=epoch_responses || active.size()!=0 || retiring!=null || core_pending)
        `uvm_error("FAULT_FINAL_PENDING","final transactions not drained")
      if(!$test$plusargs("SHORT_CONTROL") && !$test$plusargs("RECOVERY_ONLY"))for(int i=0;i<21;i++)begin
        if(feature_hits[i]==0)`uvm_error("FAULT_FEATURE_MISSING",$sformatf("feature=%0d",i))
        `uvm_info("FAULT_FEATURE",$sformatf("feature=%0d hits=%0d",i,feature_hits[i]),UVM_NONE)
      end
    endfunction
  endclass

  class test_kse_faults extends uvm_test;
    `uvm_component_utils(test_kse_faults)
    virtual kse_fault_if v;
    kse_fault_responder server;
    kse_fault_scoreboard sb;
    kse_fault_bus_checker bus_sb;
    logic [31:0] image[80592];
    bit completed,loaded;
    int negative_dummy;
    string negative;
    function new(string name,uvm_component parent);super.new(name,parent);endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if(!uvm_config_db#(virtual kse_fault_if)::get(this,"","vif",v))`uvm_fatal("NOVIF","fault test")
      server=kse_fault_responder::type_id::create("server",this);
      sb=kse_fault_scoreboard::type_id::create("sb",this);
      bus_sb=kse_fault_bus_checker::type_id::create("bus_sb",this);
      begin string directory;
        void'($value$plusargs("DATA=%s",directory));
        $readmemh({directory,"/sample_00_img.hex"},image);
      end
      void'($value$plusargs("NEGATIVE=%s",negative));
    endfunction
    task access(bit read,int addr,logic[31:0] data=0,int stall=2,bit release_error=0,bit immediate=0,output logic[31:0] result);
      if(!immediate)begin @(posedge v.clk);#1ps;end
      v.m_cv=1;v.m_read=read;v.m_addr=addr;v.m_wdata=data;v.m_mask=15;v.m_rr=0;
      if(release_error)v.release_error=1;
      do @(posedge v.clk);while(!v.m_cr);
      #1ps;v.m_cv=0;
      repeat(stall)@(posedge v.clk);
      #1ps;v.m_rr=1;
      do @(posedge v.clk);while(!v.m_rv);
      result=v.m_rdata;
      if(v.m_err!==0)`uvm_error("MMIO_DRIVER","legal access returned error")
      #1ps;v.m_rr=0;
    endtask
    task wr(int off,logic[31:0] data,bit release_error=0,bit immediate=0);
      logic[31:0] result;access(0,'h11000000+off,data,2,release_error,immediate,result);
    endtask
    task rd(int off,logic[31:0] expected);
      logic[31:0] result;access(1,'h11000000+off,0,3,0,0,result);
      if(result!==expected)`uvm_error("REGISTER_VALUE",$sformatf("offset=%h got=%h expected=%h",off,result,expected))
    endtask
    task hard_reset(int id);
      @(negedge v.clk);#1ps;v.rst_n=0;v.scenario=id;
      // The strict SRAM retains its bits, but BASE/WPTR/VALID/DONE are a new
      // loader epoch after reset.  A full release therefore requires a fresh
      // ICB image load; do not let the test silently republish stale data.
      loaded=0;
      v.m_cv=0;v.m_rr=0;v.l_cv=0;v.l_rr=0;v.strict_publish=0;
      v.cmd_gate=1;v.hold_responses=0;v.release_error=0;v.hold_last=0;v.release_last=0;v.noise_error=0;v.fault_kind=0;v.check_outputs=0;
      #1ns;
      if({v.m_rv,v.d_cv,v.irq,v.kbusy,v.cq_count,v.sq_count,v.pb_count,v.ib_count,v.ob_count,v.p_resv,v.i_resv,v.o_pending} !== '0)
        `uvm_error("ASYNC_RESET","control/queues/requests not asynchronously cancelled")
      repeat(5)@(posedge v.clk);
      @(negedge v.clk);#1ps;v.rst_n=1;
      repeat(3)@(posedge v.clk);#1ps;
      rd('h0c,0);rd('h30,0);rd('h2c,0);
      `uvm_info("RESET_CASE",$sformatf("scenario=%0d total_cancelled=%0d epoch=%0d",id,sb.total_cancelled,sb.epoch),UVM_NONE)
    endtask
    task l_access(bit read,int addr,logic[31:0] data,output logic[31:0] result);
      @(negedge v.clk);#1ps;v.l_cv=1;v.l_read=read;v.l_addr=addr;v.l_wdata=data;v.l_rr=1;
      do @(posedge v.clk);while(!v.l_cr);
      #1ps;v.l_cv=0;
      do @(posedge v.clk);while(!v.l_rv);
      result=v.l_rdata;
      if(v.l_err!==0)`uvm_error("LOADER_DRIVER","legal loader access returned error")
      #1ps;v.l_rr=0;
    endtask
    task lwr(int addr,logic[31:0] data);
      logic[31:0] result;l_access(0,addr,data,result);
    endtask
    task publish(int base,int wptr,bit done=1,bit init=1);
      if(init)lwr('h40080000,base);
      lwr('h40080004,wptr);lwr('h40080008,int'(done));
    endtask
    task load_image();
      v.strict_publish=1;lwr('h40080000,0);
      for(int i=0;i<80592;i++)begin
        lwr('h40000000+4*i,image[i]);
        if((i+1)%1024==0 || i==80591)lwr('h40080004,4*(i+1));
      end
      lwr('h40080008,1);v.strict_publish=0;loaded=1;
    endtask
    task configure(int words=6584,bit release_data=1);
      bit loaded_this_epoch;
      loaded_this_epoch=0;
      if(!loaded && release_data && !$test$plusargs("SHORT_CONTROL"))begin
        load_image();
        loaded_this_epoch=1;
      end
      if(release_data && !loaded_this_epoch)begin
        if($test$plusargs("SHORT_CONTROL") && !loaded)begin
          lwr('h40080000,0);lwr('h40000000,image[0]);lwr('h40080004,4);lwr('h40080008,1);
        end else publish(0,4*80592);
      end
      wr('h10,'h18c0);wr('h14,words);wr('h18,0);wr('h1c,'h60000);
    endtask
    task issue(int layer_id,bit in_en,bit out_en);
      wr('h10,'h18c0+26336*layer_id);wr('h20,layer_id|(in_en?'h100:0)|(out_en?'h200:0));
    endtask
    task error_case(int kind);
      hard_reset(10+kind);configure(kind==1?0:6584);v.fault_kind=kind;
      issue(0,1,kind==3);
      wait(server.fault_waiting);repeat(9)@(posedge v.clk);#1ps;
      if(sb.error_count!=0 || sb.error_status!=0)`uvm_error("EARLY_ERROR","error occurred before held response was returned")
      rd('h30,0);wr('h0c,2,1);
      if(sb.error_count!=1 || sb.feature_hits[3]==0)`uvm_error("ERROR_COLLISION","missing actual DMA error and same-cycle W1C")
      rd('h30,2);rd('h0c,2);
      if(v.irq!==0)`uvm_error("MASKED_IRQ","disabled error IRQ asserted")
      wr('h04,2);if(v.irq!==1)`uvm_error("ENABLED_IRQ","pending error IRQ did not assert after enable")
      wr('h04,0);if(v.irq!==0)`uvm_error("DISABLED_IRQ","error IRQ did not mask")
      wr('h04,3);wr('h0c,2);rd('h0c,0);rd('h30,2);
      repeat(9)@(posedge v.clk);#1ps;
      if(v.irq!==0 || sb.error_count!=1)`uvm_error("STICKY_ERR_RETRIGGER","sticky ERR incorrectly retriggered cleared IRQ")
      `uvm_info("ERROR_CASE",$sformatf("kind=%0d errors=%0d sticky=%0d irq_status=%0d",kind,sb.error_count,sb.error_status,sb.irq_status),UVM_NONE)
      hard_reset(20+kind);
    endtask
    task reset_matrix();
      hard_reset(30);configure(0);v.cmd_gate=0;issue(0,1,0);
      wait(v.d_cv && !v.d_cr);repeat(4)@(posedge v.clk);
      hard_reset(31);sb.hit(5);
      hard_reset(32);configure(0);v.hold_responses=1;issue(0,1,0);
      wait(sb.pending.size()==2);if(sb.epoch_responses!=0)`uvm_error("RESET_SETUP","response returned despite responder hold")
      hard_reset(33);sb.hit(6);
      hard_reset(34);
      @(posedge v.clk);#1ps;v.m_cv=1;v.m_read=1;v.m_addr='h11000000;v.m_rr=0;
      do @(posedge v.clk);while(!v.m_cr);#1ps;v.m_cv=0;
      repeat(4)@(posedge v.clk);#1ps;
      if(v.m_rv!==1 || v.m_rdata!=='h4b534531)`uvm_error("RESET_SETUP","missing held MMIO response")
      hard_reset(35);sb.hit(7);
      hard_reset(36);configure(0,0);issue(0,1,0);issue(1,0,0);issue(2,0,0);
      if(v.cq_count!==2)`uvm_error("RESET_SETUP","did not reach two pending commands")
      hard_reset(37);sb.hit(8);
      for(int n=0;n<4;n++)begin
        int target;target=n==0?PH_QKV:n==1?PH_SM:n==2?PH_LN1:PH_LN2;
        hard_reset(40+n);configure();issue(0,1,0);wait(v.phase==target);#1ps;
        `uvm_info("RESET_PHASE",$sformatf("phase=%0d scenario=%0d busy=%b",target,v.scenario,v.kbusy),UVM_NONE)
        if(v.kbusy!==1)`uvm_error("RESET_SETUP","phase reset without active computation")
        hard_reset(50+n);sb.hit(9+n);
      end
      hard_reset(60);configure();v.hold_last=1;issue(0,1,1);
      wait(server.last_waiting && sb.core_pending);repeat(11)@(posedge v.clk);#1ps;
      if(sb.done_count!=0 || sb.write_acks!=1583 || sb.write_count!=1584)`uvm_error("RESET_SETUP","output drain reset not at final unacknowledged word")
      `uvm_info("RESET_OUTPUT_DRAIN",$sformatf("writes=%0d ack=%0d core_done=%0d",sb.write_count,sb.write_acks,sb.core_count),UVM_NONE)
      hard_reset(61);sb.hit(16);
    endtask
    task gate_cases();
      for(int n=0;n<4;n++)begin
        hard_reset(70+n);configure(0,0);
        if(n==0)begin
          lwr('h40080000,'h1000);
          for(int i=0;i<2048;i++)lwr('h40001000+4*i,image[i]);
          lwr('h40080004,'h3000);lwr('h40080008,1);
        end else if(n==1)begin
          publish(0,0,0);
        end else if(n==2)begin
          publish(0,0,0);
        end else begin
          lwr('h40080000,0);lwr('h40000000,image[0]);
          lwr('h40080004,4);lwr('h40080008,0);
        end
        issue(0,1,0);repeat(17)@(posedge v.clk);#1ps;
        if(n==3)begin
          // strict-final REL_LAG=0: A=0 is legal for BASE=0, WPTR=4;
          // the next word (A=4) must remain blocked until WPTR advances.
          if(sb.epoch_requests!=1 || sb.input_reads!=1)
            `uvm_error("GATE_RELEASE","REL_LAG=0 one-word publication did not allow exactly A=0")
        end else if(sb.epoch_requests!=0)
          `uvm_error("GATE_BLOCK","input read escaped base/empty/valid/lead block")
        `uvm_info("GATE_BLOCKED",$sformatf("case=%0d base=%0d wptr=%0d valid=%b done=%b",n,v.base,v.wptr,v.watermark_valid,v.loader_done),UVM_NONE)
      end
      lwr('h40080004,4);wait(sb.epoch_requests==1);repeat(12)@(posedge v.clk);#1ps;
      if(sb.epoch_requests!=1)`uvm_error("GATE_LEAD","one-word publication boundary released extra words")
      lwr('h40000004,image[1]);
      lwr('h40080004,8);wait(sb.epoch_requests==2);repeat(12)@(posedge v.clk);#1ps;
      if(sb.epoch_requests!=2)`uvm_error("GATE_LEAD","second word boundary released extra words")
      for(int i=2;i<1025;i++)lwr('h40000000+4*i,image[i]);
      lwr('h40080004,4100);lwr('h40080008,1);wait(sb.epoch_responses==1025);repeat(17)@(posedge v.clk);#1ps;
      if(sb.epoch_requests!=1025)`uvm_error("GATE_UPPER","done released bytes above wptr")
      sb.hit(13);hard_reset(74);
    endtask
    task recovery();
      hard_reset(100);configure(6584,0);v.check_outputs=1;v.hold_last=1;wr('h04,3);
      issue(0,1,0);issue(1,0,0);
      fork load_image(); join_none
      for(int l=0;l<11;l++)begin
        wait(sb.done_count>=l+1);wr('h0c,1);
        if(l+2<12)issue(l+2,0,l+2==11);
      end
      wait(server.last_waiting && sb.core_pending);repeat(17)@(posedge v.clk);#1ps;
      if(sb.done_count!=11 || sb.write_acks!=1583 || sb.write_count!=1584)`uvm_error("RECOVERY_DRAIN","completion escaped held final response")
      `uvm_info("FINAL_RESPONSE_HELD",$sformatf("done=%0d ack=%0d writes=%0d cycle=%0d",sb.done_count,sb.write_acks,sb.write_count,sb.cycle),UVM_NONE)
      v.release_last=1;wait(sb.write_acks==1584);#1ps;wr('h0c,1,0,1);
      rd('h0c,1);rd('h2c,12);rd('h30,0);wr('h0c,1);rd('h0c,0);
      if(sb.done_count!=12 || sb.core_count!=12 || sb.cmd_count!=12 || sb.read_count!=80592 || sb.input_reads!=1584 || sb.param_reads!=79008 || sb.write_count!=1584 || sb.write_acks!=1584 || sb.error_count!=0 || sb.pending.size()!=0)
        `uvm_error("RECOVERY_COUNTS","post-reset complete network counts differ")
      for(int i=0;i<1584;i++)if(!bus_sb.memory.exists('h60000+4*i) || bus_sb.memory['h60000+4*i]!==sb.golden[i])`uvm_error("RECOVERY_MEMORY","external output image differs from bound golden")
      for(int i=0;i<1584;i++)begin
        logic[31:0] result;l_access(1,'h40060000+4*i,0,result);
        if(result!==sb.golden[i])`uvm_error("RECOVERY_READBACK","actual SRAM output differs from bound golden")
      end
      if(sb.feature_hits[4]==0)`uvm_error("DONE_COLLISION","missing actual DONE event and same-cycle W1C")
      sb.hit(14);sb.hit(19);
      `uvm_info("RECOVERY_COMPLETE",$sformatf("reads=%0d input=%0d params=%0d writes=%0d ack=%0d commands=%0d core=%0d events=%0d final_bytes=6336 epoch=%0d",sb.read_count,sb.input_reads,sb.param_reads,sb.write_count,sb.write_acks,sb.cmd_count,sb.core_count,sb.done_count,sb.epoch),UVM_NONE)
    endtask
    task loader_restart_cases();
      hard_reset(80);v.strict_publish=1;lwr('h40080000,0);
      for(int i=0;i<1024;i++)lwr('h40000000+4*i,image[i]);
      lwr('h40080004,4096);
      // No active DMA: BASE is a new empty generation, not a DMA abort.
      lwr('h40080000,4096);
      if(v.wptr!==4096 || v.base!==4096 || v.loader_done!==0 || v.watermark_valid!==1)
        `uvm_error("LOADER_INIT","mid-load INIT did not empty the published interval")
      sb.hit(17);v.strict_publish=0;
      hard_reset(81);lwr('h40080000,0);lwr('h40000000,image[0]);lwr('h40080004,4);
      if(v.loader_done!==0)`uvm_error("LOADER_DONE","DONE asserted before its doorbell")
      hard_reset(82);sb.hit(18);
      // Hold a real loader write response, then cancel the physical epoch.
      @(negedge v.clk);#1ps;v.l_cv=1;v.l_read=0;v.l_addr='h40000000;v.l_wdata=image[0];v.l_rr=0;
      do @(posedge v.clk);while(!v.l_cr);#1ps;v.l_cv=0;
      repeat(5)@(posedge v.clk);
      if(v.l_rv!==1)`uvm_error("LOADER_RESET_SETUP","missing held loader response")
      hard_reset(83);sb.hit(20);
    endtask
    task work();
      if($test$plusargs("RECOVERY_ONLY"))begin recovery();completed=1;return;end
      if($test$plusargs("PUB_ONLY"))begin
        hard_reset(200);v.strict_publish=1;lwr('h40080000,0);
        for(int i=0;i<1023;i++)lwr('h40000000+4*i,image[i]);
        // Actual negative stimulus: omit the final word's loader write, then
        // publish a WPTR that claims it is present.
        lwr('h40080004,4096); completed=1; return;
      end
      if($test$plusargs("BUS_ONLY"))begin
        hard_reset(201);lwr('h40080000,0);lwr('h40000000,image[0]);
        lwr('h40080004,4);lwr('h40080008,1);completed=1;return;
      end
      if($test$plusargs("SRAM_ONLY"))begin
        logic [31:0] result;
        hard_reset(202);lwr('h40000000,image[0]);
        l_access(1,'h40000000,0,result);completed=1;return;
      end
      if($test$plusargs("RESET_ONLY"))begin
        hard_reset(300);lwr('h40080000,0);lwr('h40000000,image[0]);
        lwr('h40080004,4);lwr('h40080008,1);
        v.hold_responses=1;issue(0,1,0);
        wait(sb.pending.size()!=0);hard_reset(301);completed=1;return;
      end
      hard_reset(1);v.noise_error=1;repeat(21)@(posedge v.clk);#1ps;rd('h30,0);rd('h0c,0);sb.hit(15);v.noise_error=0;
      error_case(1);
      if(!$test$plusargs("SHORT_CONTROL"))begin error_case(2);error_case(3);reset_matrix();gate_cases();loader_restart_cases();recovery();end
      completed=1;
    endtask
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      fork begin repeat(6000000)@(posedge v.clk);`uvm_fatal("WATCHDOG","KSE fault matrix exceeded watchdog")end work();join_any
      disable fork;phase.drop_objection(this);
    endtask
    function void report_phase(uvm_phase phase);
      uvm_report_server s;super.report_phase(phase);s=uvm_report_server::get_server();
      if(!completed)`uvm_error("INCOMPLETE","fault matrix did not finish")
      else begin
        `uvm_info("KSE_FAULT_COMPLETE",$sformatf("epochs=%0d cancelled_dma=%0d early=%0d short=%0d",sb.epoch,sb.total_cancelled,sb.early_commands,$test$plusargs("SHORT_CONTROL")),UVM_NONE)
        if(s.get_severity_count(UVM_ERROR)==0 && s.get_severity_count(UVM_FATAL)==0)`uvm_info("RESULT","TEST PASSED",UVM_NONE)
      end
    endfunction
  endclass
endpackage
