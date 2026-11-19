`timescale 1ns/1ps
package kse_network_pkg;
  import uvm_pkg::*;
  import kse_integration_pkg::*;
  `include "uvm_macros.svh"
  class network_command;
    int layer_id, paddr, plen, iaddr, oaddr;
    bit in_en,out_en;
  endclass
  class kse_network_scoreboard extends kse_integration_scoreboard;
    `uvm_component_utils(kse_network_scoreboard)
    network_command commands[$],segments[$];
    // Keep command issue and core completion as ordered queues.  The
    // optimized RTL may present kcv, kdone and layer_event on adjacent or
    // shared cycles; single running/retiring pointers lose layer identity.
    network_command active[$],completed[$];
    int cfg_paddr,cfg_plen,cfg_iaddr,cfg_oaddr;
    int seg_index,done_count;
    logic[1:0] irq_enable,irq_status,error_status;
    bit core_done,irq_old,ext_old,claimed,source_cleared;
    logic[31:0] image[80592],golden[1584];
    bit read_seen[80592],write_seen[1584];
    int sample_id, n_loader,n_read,n_write,n_ack,n_cmd,n_core_done,n_event,n_claim,n_complete,n_clear;
    int early_handshakes;
    int input_index,output_index,accepted_commands,overflow_commands,done_at_issue;
    int irq_rises,ext_rises,triple_requests,cpu_reads_active;
    int total_samples,metric_fd;
    longint window_transactions;
    int step=1;
    longint first_loader,last_flag,layer_cycles[12],last_output_ack;
    bit flag_start,flag_done,corrupt_output,output_corrupted;
    integration_expected mpending,ppending;
    bit config_prio,config_enable,config_threshold;
    covergroup network_cov with function sample(int layer_id,int event_kind);
      option.per_instance=1;
      layer_cp:coverpoint layer_id {bins layers[]={[0:11]};}
      event_cp:coverpoint event_kind {bins enqueue={0};bins issue={1};bins complete_layer={2};bins plic_claim={3};}
      layer_event:cross layer_cp,event_cp;
    endgroup
    function new(string n,uvm_component p);super.new(n,p);network_cov=new;endfunction
    function void build_phase(uvm_phase phase);
      string path;super.build_phase(phase);corrupt_output=$test$plusargs("CORRUPT_OUTPUT_EXPECTED");
      if($value$plusargs("METRICS=%s",path))begin metric_fd=$fopen(path,"w");if(!metric_fd)`uvm_fatal("METRICS","cannot open metrics file")end
    endfunction
    function void reset_network();
      commands.delete();segments.delete();active.delete();completed.delete();mpending=null;ppending=null;
      cfg_paddr=0;cfg_plen=0;cfg_iaddr=0;cfg_oaddr=0;seg_index=0;done_count=0;
      irq_enable=0;irq_status=0;error_status=0;core_done=0;irq_old=0;ext_old=0;
      claimed=0;source_cleared=0;config_prio=0;config_enable=0;config_threshold=0;
    endfunction
    function void start_sample(int id,string directory);
      sample_id=id;
      $readmemh($sformatf("%s/sample_%02d_img.hex",directory,id),image);
      $readmemh($sformatf("%s/sample_%02d_out.hex",directory,id),golden);
      foreach(read_seen[i])read_seen[i]=0;foreach(write_seen[i])write_seen[i]=0;
      n_loader=0;n_read=0;n_write=0;n_ack=0;n_cmd=0;n_core_done=0;n_event=0;n_claim=0;n_complete=0;n_clear=0;
      input_index=0;output_index=0;accepted_commands=0;overflow_commands=0;irq_rises=0;ext_rises=0;triple_requests=0;cpu_reads_active=0;early_handshakes=0;
      active.delete();completed.delete();
      window_transactions=0;first_loader=0;last_flag=0;last_output_ack=0;flag_start=0;flag_done=0;
      foreach(layer_cycles[i])layer_cycles[i]=0;
    endfunction
    function automatic logic[31:0] register_value(int index);
      case(index)
        0:return 32'h4b534531;
        1:return {30'b0,irq_enable};
        2:return {16'b0,8'(done_count),1'b0,v.wp_valid,v.loader_done,1'(commands.size()==2),2'(commands.size()),1'(active.size()!=0 || completed.size()!=0 || commands.size()!=0),v.kbusy};
        3:return {30'b0,irq_status};
        4:return cfg_paddr;5:return cfg_plen;6:return cfg_iaddr;7:return cfg_oaddr;
        9:return wp_model;10:return base_model;11:return done_count;12:return {30'b0,error_status};
        default:return 0;
      endcase
    endfunction
    function void sample_network();
      bit mh,wr,legal,push,full,evt;
      int idx,preq;
      logic[1:0] clear_bits,set_bits;
      network_command c,oc;
      integration_expected e;
      if(v.rst_n!==1'b1)begin reset_network();return;end
      if(v.cq_count!==2'(commands.size()))`uvm_error("CQ_COUNT","command queue differs from accepted MMIO history")
      if(v.irq!== (|(irq_status & irq_enable)))`uvm_error("IRQ_LEVEL","IRQ does not match independent sticky status/enable")
      if(v.sq_count>3 || v.pb_count+v.p_resv>4 || v.ib_count+v.i_resv>4 || v.ob_count>4)
        `uvm_error("BUFFER_BOUNDS","segment/stream buffer count or reservations exceed contract")
      if(v.irq && !irq_old)irq_rises++;irq_old=v.irq;
      if(v.ext_irq && !ext_old)ext_rises++;ext_old=v.ext_irq;
      if(v.rv[3])begin
        if(mpending==null)`uvm_error("MMIO_RESPONSE","unexpected MMIO response")
        else if(v.err[3]!==mpending.error || (mpending.read && v.data[3]!==mpending.value))
          `uvm_error("MMIO_SB",$sformatf("addr=%08h got=%08h/%b expected=%08h/%b",mpending.addr,v.data[3],v.err[3],mpending.value,mpending.error))
      end
      if(v.rv[3] && v.rr[3])mpending=null;
      mh=v.cv[3] && v.cr[3];wr=!v.rd[3];idx=int'(v.addr[3][11:2]);
      legal=v.addr[3][23:12]==0 && idx<=12;preq=commands.size();full=preq==2;
      push=mh && wr && legal && idx==8 && !full;
      clear_bits=(mh && wr && legal && idx==3)?v.wd[3][1:0]:2'b0;
      set_bits=0;
      if(mh)begin
        if(mpending!=null)`uvm_error("MMIO_OUTSTANDING","MMIO accepted a second outstanding request")
        e=new;e.addr=v.addr[3];e.read=v.rd[3];e.error=!legal;e.value=legal?register_value(idx):0;mpending=e;
      end
      // Completion must follow core done and every output response; this uses
      // observed transactions, not the DUT's out_drained calculation.
      // A layer event retires the oldest core-completed command.  Output
      // writes are still checked independently below, so an out_en command
      // cannot retire until all 1584 responses have been observed.
      evt=(completed.size()!=0) && (!completed[0].out_en || n_ack==1584);
      if(v.layer_event!==evt)`uvm_error("OUTPUT_DRAIN",$sformatf("sample=%0d event=%b expected=%b done=%b output_ack=%0d",sample_id,v.layer_event,evt,core_done,n_ack))
      if(v.layer_event)begin
        if(v.network)begin
          if(n_event>=12)`uvm_error("EXTRA_LAYER","more than 12 layer events")
          else layer_cycles[n_event]=cycle;
          if(completed.size()==0)`uvm_error("OUTPUT_DRAIN","layer event without a completed command")
          else network_cov.sample(completed[0].layer_id,2);
        end
        if(completed.size()!=0) begin
          if(v.network)`uvm_info("NETWORK_LAYER",$sformatf("sample=%0d layer=%0d cycle=%0d output_ack=%0d",sample_id,completed[0].layer_id,cycle,n_ack),UVM_NONE)
          completed.pop_front();
        end
        done_count++;n_event++;set_bits[0]=1;
      end
      if(v.kdone)begin
        if(active.size()==0)`uvm_error("CORE_DONE","duplicate/unissued core done")
        else begin
          completed.push_back(active.pop_front());
          n_core_done++;
        end
      end
      if(v.kcv && v.kcr)begin
        if(commands.size()==0)`uvm_error("CMD_ORDER","engine command without accepted MMIO enqueue")
        else begin
          c=commands.pop_front();
          // Early issue is a legal v2 handshake.  Count it for the contract,
          // but retain strict FIFO ordering and completion checks.
          if(active.size()!=0 || completed.size()!=0) begin
            if(v.network && n_cmd>0 && n_cmd<12) early_handshakes++;
          end
          if({v.layer,v.kin,v.kout}!=={4'(c.layer_id),c.in_en,c.out_en})`uvm_error("CMD_SNAPSHOT","layer/input/output flags differ from MMIO snapshot")
          if(v.network && (c.layer_id!=n_cmd || c.in_en!=(n_cmd==0) || c.out_en!=(n_cmd==11)))`uvm_error("NETWORK_COMMAND","unexpected 12-layer command sequence")
          active.push_back(c);n_cmd++;done_at_issue=done_count;
          if(v.network)network_cov.sample(c.layer_id,1);
        end
      end
      if(mh && wr && legal)case(idx)
        1:if(v.mask[3][0])irq_enable=v.wd[3][1:0];
        4:cfg_paddr={13'b0,v.wd[3][18:2],2'b0};
        5:cfg_plen=int'(v.wd[3][16:0]);
        6:cfg_iaddr={13'b0,v.wd[3][18:2],2'b0};
        7:cfg_oaddr={13'b0,v.wd[3][18:2],2'b0};
        8:begin
          if(full)begin error_status[0]=1;set_bits[1]=1;overflow_commands++;end
          else begin
            c=new;c.layer_id=int'(v.wd[3][3:0]);c.in_en=v.wd[3][8];c.out_en=v.wd[3][9];
            c.paddr=cfg_paddr;c.plen=cfg_plen;c.iaddr=cfg_iaddr;c.oaddr=cfg_oaddr;
            commands.push_back(c);segments.push_back(c);accepted_commands++;
            if(v.network)network_cov.sample(c.layer_id,0);
          end
        end
        default:;
      endcase
      if(mh && wr && legal && idx==3)begin n_clear++;if(claimed)source_cleared=1;end
      if(v.rv[2] && v.rr[2] && pending[2]!=null && !pending[2].read && v.network)begin n_ack++;last_output_ack=cycle;end
      if(v.rv[2] && v.rr[2] && v.err[2])begin error_status[1]=1;set_bits[1]=1;end
      irq_status=(irq_status & ~clear_bits)|set_bits;
      if(v.network)begin
        if(v.cv[1] && v.cr[1] && v.addr[1]==32'h40080000)first_loader=cycle;
        if(first_loader!=0 && !flag_done && v.scv && v.scr)window_transactions++;
        if(&v.cv[2:0])triple_requests++;
        if(v.cv[0] && v.cr[0] && v.rd[0] && v.cv[1] && v.cv[2])cpu_reads_active++;
        if(v.cv[1] && v.cr[1] && v.addr[1]<32'h80000)begin
          if(n_loader>=80592 || v.rd[1] || v.addr[1]!==32'(4*n_loader) || v.mask[1]!==4'hf || v.wd[1]!==image[n_loader])`uvm_error("LOADER_IMAGE","loader image/address/count differs from bound input")
          n_loader++;
        end
        if(v.cv[2] && v.cr[2])begin
          int a,i;a=int'(v.addr[2]);
          if(v.rd[2])begin
            if(a<0 || a>=4*80592 || a%4!=0)`uvm_error("DMA_ADDRESS","DMA read outside image")
            else begin
              i=a/4;
              if(read_seen[i])`uvm_error("DMA_DUPLICATE","DMA read repeated image word")
              read_seen[i]=1;n_read++;
              if(a<6336)begin
                if(a!=4*input_index || active.size()==0 || a!=active[0].iaddr+4*input_index)`uvm_error("DMA_INPUT","input address/order differs from queued command")
                input_index++;
              end else begin
                while(segments.size() && seg_index>=segments[0].plen)begin c=segments.pop_front();seg_index=0;end
                if(segments.size()==0 || a!=segments[0].paddr+4*seg_index)`uvm_error("DMA_SEGMENT","parameter address/length differs from MMIO enqueue snapshot")
                seg_index++;
              end
            end
          end else begin
            logic[31:0] expected;
            i=(a-'h60000)/4;
            oc = active.size()!=0 ? active[0] : (completed.size()!=0 ? completed[0] : null);
            if(oc==null || !oc.out_en || a!=oc.oaddr+4*output_index || i<0 || i>=1584 || v.mask[2]!==4'hf)`uvm_error("DMA_OUTPUT_ADDRESS","output address/count/mask differs from command")
            else begin
              expected=golden[i];
              if(corrupt_output && !output_corrupted)begin expected^=1;output_corrupted=1;end
              if(v.wd[2]!==expected)`uvm_error("NETWORK_GOLDEN",$sformatf("sample=%0d word=%0d got=%08h expected=%08h",sample_id,i,v.wd[2],expected))
              if(write_seen[i])`uvm_error("DMA_DUPLICATE","DMA output word repeated")
              write_seen[i]=1;n_write++;output_index++;
            end
          end
        end
        if(v.cv[0] && v.cr[0] && !v.rd[0])case(v.addr[0]&32'h7fffc)
          'h7f000:begin if(v.wd[0]!==32'h1 || v.mask[0]!==4'hf)`uvm_error("FLAG_START","CPU start flag is invalid") flag_start=1;end
          'h7f004:begin if(v.wd[0]!==32'h600d000c || v.mask[0]!==4'hf || n_event!=12 || n_ack!=1584)`uvm_error("FLAG_DONE","CPU done flag/error/completion ordering invalid") flag_done=1;last_flag=cycle;end
          default:;
        endcase
      end
      if(v.mode==3)begin
        if(v.rv[4] && v.rr[4])begin
          if(ppending==null || v.err[4])`uvm_error("PLIC_RSP","unpaired/error PLIC response")
          else if(ppending.read && ppending.addr==32'h0c200004)begin
            if(v.data[4]!==32'd17 || claimed || !config_prio || !config_enable || !config_threshold)`uvm_error("PLIC_CLAIM","claim is not enabled KSE source 17")
            claimed=1;source_cleared=0;n_claim++;if(v.network)network_cov.sample(n_claim-1,3);
          end
          ppending=null;
        end
        if(v.cv[4] && v.cr[4])begin
          if(ppending!=null)`uvm_error("PLIC_OUTSTANDING","PLIC second outstanding request")
          e=new;e.addr=v.addr[4];e.read=v.rd[4];ppending=e;
          if(!v.rd[4])case(v.addr[4])
            'h0c000044:begin if(v.wd[4]!==32'd1)`uvm_error("PLIC_CONFIG","source17 priority") config_prio=1;end
            'h0c002000:begin if(v.wd[4]!==32'h20000)`uvm_error("PLIC_CONFIG","source17 enable") config_enable=1;end
            'h0c200000:begin if(v.wd[4]!==32'd0)`uvm_error("PLIC_CONFIG","threshold") config_threshold=1;end
            'h0c200004:begin
              if(!claimed || !source_cleared || v.wd[4]!==32'd17 || v.irq)`uvm_error("PLIC_COMPLETE","complete before claim/clear or wrong source")
              claimed=0;n_complete++;
            end
            default:`uvm_error("PLIC_CONFIG","unexpected PLIC write")
          endcase
        end
      end
    endfunction
    task run_phase(uvm_phase phase);
      forever begin @(posedge v.clk);sample_network();sample_sram();end
    endtask
    function void finish_sample();
      if(n_loader!=80592 || n_read!=80592 || n_write!=1584 || n_ack!=1584 || n_cmd!=12 || n_core_done!=12 || n_event!=12 || accepted_commands!=12 || overflow_commands!=0 || input_index!=1584 || output_index!=1584)
        `uvm_error("NETWORK_COUNTS","incomplete/duplicate loader, DMA, command or completion counts")
      if(v.mode==3 && early_handshakes!=11)
        `uvm_error("NETWORK_EARLY",$sformatf("expected 11 early layer handshakes, observed %0d",early_handshakes))
      foreach(read_seen[i])if(!read_seen[i])`uvm_error("NETWORK_MISSING","missing DMA input/parameter word")
      foreach(write_seen[i])if(!write_seen[i])`uvm_error("NETWORK_MISSING","missing DMA output word")
      if(v.mode==3 && (!flag_start || !flag_done || n_claim!=12 || n_complete!=12 || n_clear!=12 || claimed || irq_status!=0 || irq_rises!=12 || ext_rises!=12))
        `uvm_error("NETWORK_INTERRUPTS","CPU flags/PLIC claim-clear-complete/IRQ counts incomplete")
      if(commands.size()!=0 || active.size()!=0 || completed.size()!=0 || error_status!=0 || irq_status!=0 || done_count!=12)
        `uvm_error("NETWORK_DRAIN","final queue/IRQ/errors/done state invalid")
      `uvm_info("NETWORK_SAMPLE",$sformatf("sample=%0d loader=%0d read=%0d write=%0d ack=%0d commands=%0d core_done=%0d events=%0d early_hs=%0d claims=%0d completes=%0d clears=%0d irq_rises=%0d ext_rises=%0d triple_requests=%0d cpu_reads_active=%0d window=%0d transactions=%0d reference_cycles=163328 reference_transactions=162850",sample_id,n_loader,n_read,n_write,n_ack,n_cmd,n_core_done,n_event,early_handshakes,n_claim,n_complete,n_clear,irq_rises,ext_rises,triple_requests,cpu_reads_active,(v.mode==3?last_flag:layer_cycles[11])-first_loader,window_transactions),UVM_NONE)
      if(metric_fd)begin
        $fdisplay(metric_fd,"sample\t%0d\t%0d\t%0d\t%0d\t%0d\t%0d\t%0d\t%0d\t%0d\t%0d\t%0d",sample_id,n_loader,n_read,n_write,n_ack,n_cmd,n_core_done,n_event,n_claim,n_complete,(v.mode==3?last_flag:layer_cycles[11])-first_loader);
        foreach(layer_cycles[l])$fdisplay(metric_fd,"layer\t%0d\t%0d\t%0d",sample_id,l,layer_cycles[l]);$fflush(metric_fd);
      end
      total_samples++;
    endfunction
  endclass

  class test_kse_network extends uvm_test;
    `uvm_component_utils(test_kse_network)
    virtual kse_integration_if v;
    kse_network_scoreboard sb;
    kse_port_driver drv[4];
    bit completed,scratch_done;
    string directory,firmware;
    int first=0,count=1,step=1,stall_mode=0,fw_words,watchdog_cycles=4000000;
    function new(string n,uvm_component p);super.new(n,p);endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if(!uvm_config_db#(virtual kse_integration_if)::get(this,"","vif",v))`uvm_fatal("NOVIF","network test")
      sb=kse_network_scoreboard::type_id::create("sb",this);
      for(int i=0;i<4;i++)begin
        uvm_config_db#(int)::set(this,$sformatf("drv%0d",i),"port_id",i);
        drv[i]=kse_port_driver::type_id::create($sformatf("drv%0d",i),this);
      end
      if(!$value$plusargs("DATA=%s",directory))`uvm_fatal("DATA","missing bound data directory")
      void'($value$plusargs("STEP=%d",step));void'($value$plusargs("FIRST=%d",first));void'($value$plusargs("COUNT=%d",count));void'($value$plusargs("STALL_MODE=%d",stall_mode));void'($value$plusargs("WATCHDOG_CYCLES=%d",watchdog_cycles));
      if(v.mode==3)begin
        if(!$value$plusargs("FW=%s",firmware) || !$value$plusargs("FW_WORDS=%d",fw_words))`uvm_fatal("FIRMWARE","missing firmware")
        for(int i=0;i<8192;i++)v.fw[i]='x;
        $readmemh(firmware,v.fw,0,fw_words-1);
      end
    endfunction
    task access(int port_id,bit read,int a,logic[31:0] d=0,int m=15,int delay=0);
      logic[31:0] r;logic e;drv[port_id].access(read,a,d,4'(m),delay,r,e);
    endtask
    task reset();
      v.reset_drive=0;v.init_v=0;v.auto_publish=0;v.network=0;scratch_done=0;
      v.cv[1]=0;v.rr[1]=0;v.addr[1]=0;v.rd[1]=0;v.wd[1]=0;v.mask[1]=15;
      if(v.mode!=3)begin v.cv[0]=0;v.rr[0]=0;v.addr[0]=0;v.rd[0]=0;v.wd[0]=0;v.mask[0]=15;v.cv[3]=0;v.rr[3]=0;v.addr[3]=0;v.rd[3]=0;v.wd[3]=0;v.mask[3]=15;end
      // The SoC bus clock may be stopped while the pad reset is asserted.
      // Firmware load/reset release must therefore use external simulation time.
      #200;
      if(v.mode==3)begin v.fw_load=1;#20;v.fw_load=0;v.reset_drive=1;end
      else begin @(negedge v.clk);v.fw_load=1;repeat(4)@(negedge v.clk);v.fw_load=0;v.reset_drive=1;end
      wait(v.rst_n===1'b1);repeat(3)@(negedge v.clk);
    endtask
    // Independent pipelined ICB loader: only bus transactions publish progress.
    task loader();
      if(v.mode==3)wait(sb.flag_start);
      access(1,0,'h40080000,0);
      v.rr[1]=1;
      for(int base=0;base<80592;base+=1024)begin
        int limit;limit=base+1024;if(limit>80592)limit=80592;
        for(int i=base;i<limit;i++)begin
          @(negedge v.clk);v.cv[1]=1;v.addr[1]=4*i;v.wd[1]=sb.image[i];v.rd[1]=0;v.mask[1]=15;
          do @(posedge v.clk);while(v.cr[1]!==1'b1);
          if(stall_mode && $urandom_range(0,7)==0)begin
            @(negedge v.clk);v.cv[1]=0;repeat($urandom_range(1,5))@(posedge v.clk);
          end
        end
        @(negedge v.clk);v.cv[1]=0;
        wait(sb.pending[1]==null);@(negedge v.clk);
        access(1,0,'h40080004,4*limit);
        v.rr[1]=1;
      end
      access(1,0,'h40080008,1);
    endtask
    task issue(int l);
      access(3,0,'h11000010,'h18c0+26336*l);
      access(3,0,'h11000020,l|(l==0?'h100:0)|(l==11?'h200:0));
    endtask
    task precheck();
      // Legal register writes and invalid-page writes, no undefined RO/unaligned
      // access assumptions. Hold data is checked throughout MMIO response stalls.
      for(int i=0;i<=12;i++)if(i!=8)access(3,1,'h11000000+4*i,0,15,i%4);
      access(3,0,'h11000004,3);access(3,0,'h11000004,0,2);access(3,1,'h11000004);
      for(int i=0;i<4;i++)begin
        access(3,0,'h11000010+4*i,$urandom);access(3,1,'h11000010+4*i,0,15,3);
      end
      for(int i=0;i<16;i++)begin access(3,0,'h11000034+4*i,'hffffffff);access(3,1,'h11000034+4*i);end
      access(3,0,'h11001000,'hffffffff);access(3,1,'h11001000);
      // No released data: first command executes and blocks on input; exactly
      // two more commands queue, a fourth must set sticky error and IRQ.
      access(3,0,'h11000010,0);access(3,0,'h11000014,0);
      access(3,0,'h11000020,'h100);
      access(3,0,'h11000020,1);access(3,0,'h11000020,2);access(3,0,'h11000020,3);
      access(3,1,'h11000008);access(3,1,'h11000030);access(3,1,'h1100000c);
      access(3,0,'h1100000c,2);access(3,1,'h1100000c);access(3,1,'h11000030);
      if(sb.overflow_commands!=1 || sb.error_status!=1 || sb.irq_status!=0)`uvm_error("QUEUE_CONTROL","queue overflow/W1C control ineffective")
    endtask
    task subsystem_control();
      access(3,0,'h11000004,3);access(3,0,'h11000018,0);access(3,0,'h1100001c,'h60000);access(3,0,'h11000014,6584);
      issue(0);issue(1);
      for(int l=0;l<12;l++)begin
        wait(sb.done_count>=l+1);@(negedge v.clk);
        access(3,1,'h1100000c,0,15,3);access(3,0,'h1100000c,1);
        access(3,1,'h1100002c);
        if(l+2<12)issue(l+2);
      end
      access(3,1,'h11000008);access(3,1,'h11000030);
      // Read actual shared SRAM through CPU ICB, independently of DMA monitor.
      wait(scratch_done);
      for(int i=0;i<1584;i++)begin
        logic[31:0] r;logic e;drv[0].access(1,'h60000+4*i,0,15,i%4,r,e);
        if(r!==sb.golden[i] || e)`uvm_error("OUTPUT_MEMORY","shared SRAM readback differs from golden")
      end
    endtask
    task check_physical_output();
      @(negedge v.clk);v.output_capture=1;wait(v.output_ack);@(negedge v.clk);v.output_capture=0;
      for(int i=0;i<1584;i++)begin
        int a,b,g,ma;logic[31:0] actual;
        a='h60000+4*i;b=0;g=(a>>14)&31;ma=(a>>2)&4095;
        actual={v.output_halves[b][g][1][ma],v.output_halves[b][g][0][ma]};
        if(actual!==sb.golden[i])`uvm_error("OUTPUT_MEMORY","physical SRAM output differs from golden")
      end
    endtask
    task work();
      if(v.mode==2)begin reset();precheck();end
      for(int id=first;id<first+count*step;id+=step)begin
        reset();sb.start_sample(id,directory);v.network=1;v.contract_reads=1;v.phase_id=5;
        fork
          loader();
          begin
            if(v.mode==2)subsystem_control();
            else begin wait(sb.flag_done);wait(sb.pending[0]==null);repeat(8)@(negedge v.clk);check_physical_output();end
          end
          begin
            if(v.mode==2 && stall_mode)begin
              // Disjoint CPU scratch region competes with loader and DMA.
              while(sb.done_count<12)begin
                access(0,0,'h70000+4*$urandom_range(0,1023),$urandom,$urandom_range(0,15),$urandom_range(0,5));
              end
            end
            scratch_done=1;
          end
        join
        repeat(8)@(negedge v.clk);sb.finish_sample();v.network=0;
      end
      completed=1;
    endtask
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      fork begin repeat(watchdog_cycles)@(posedge v.clk);`uvm_fatal("WATCHDOG","KSE network timed out")end work();join_any
      disable fork;phase.drop_objection(this);
    endtask
    function void report_phase(uvm_phase phase);
      uvm_report_server s;super.report_phase(phase);s=uvm_report_server::get_server();
      if(completed)begin
        `uvm_info("KSE_NETWORK_COMPLETE",$sformatf("network samples=%0d",sb.total_samples),UVM_NONE)
        if(s.get_severity_count(UVM_ERROR)==0 && s.get_severity_count(UVM_FATAL)==0)`uvm_info("RESULT","TEST PASSED",UVM_NONE)
      end else `uvm_error("INCOMPLETE","network test incomplete")
    endfunction
  endclass
endpackage
