package kse_stream_pkg;
  import uvm_pkg::*;
  import kse_pkg::*;
  `include "uvm_macros.svh"
  localparam int LW=6584, NPW=12*LW, ACT_WORDS=kse_pkg::T*D/4, NT=15;
  typedef enum {CMD, PARAM, INPUT_WORD, OUTPUT_WORD, COMPLETE, TENSOR, PREFETCH_ROW} event_kind;

  class kse_stream_item extends uvm_sequence_item;
    `uvm_object_utils(kse_stream_item)
    event_kind kind;
    logic [255:0] data;
    logic [3:0] layer;
    logic in_en,out_en;
    int tensor,tok,col;
    longint cycle;
    function new(string name="kse_stream_item"); super.new(name); endfunction
  endclass

  class kse_network_request extends uvm_sequence_item;
    `uvm_object_utils(kse_network_request)
    int sample, layers=12, outall=1, mode=0;
    string data_dir;
    function new(string name="kse_network_request"); super.new(name); endfunction
  endclass

  class kse_stream_monitor extends uvm_component;
    `uvm_component_utils(kse_stream_monitor)
    virtual kse_stream_if vif;
    uvm_analysis_port#(kse_stream_item) ap;
    longint cycle;
    int r_tok[2],r_half[2], max_pf;
    longint p_stall,o_stall,i_idle;
    covergroup traffic;
      option.per_instance=1;
      phase: coverpoint vif.phase { bins stages[]={[0:12]}; }
      param_pressure: coverpoint (vif.param_valid && !vif.param_ready);
      out_pressure: coverpoint (vif.act_out_valid && !vif.act_out_ready);
    endgroup
    function new(string name,uvm_component parent);
      super.new(name,parent); ap=new("ap",this); traffic=new();
      cycle=0;max_pf=0;p_stall=0;o_stall=0;i_idle=0;
    endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual kse_stream_if)::get(this,"","vif",vif)) `uvm_fatal("KSE_CFG","missing vif")
    endfunction
    function void emit(event_kind kind, logic [255:0] data='0, int ti=0,int tok=0,int col=0);
      kse_stream_item item=new();
      item.kind=kind; item.data=data; item.tensor=ti; item.tok=tok; item.col=col;
      item.layer=vif.cmd_layer; item.in_en=vif.cmd_in_en; item.out_en=vif.cmd_out_en; item.cycle=cycle;
      ap.write(item);
    endfunction
    task run_phase(uvm_phase phase);
      int a,ti,t,c,sel;
      forever begin
        @(posedge vif.clk); cycle++;
        if(!vif.rst_n) continue;
        traffic.sample();
        if(vif.pf_level>max_pf) max_pf=vif.pf_level;
        if(vif.param_valid && !vif.param_ready) p_stall++;
        if(vif.act_out_valid && !vif.act_out_ready) o_stall++;
        if(vif.act_in_ready && !vif.act_in_valid) i_idle++;
        if(vif.cmd_valid && vif.cmd_ready) begin
          foreach(r_tok[k]) begin r_tok[k]=0; r_half[k]=0; end
          emit(CMD);
        end
        if(vif.param_valid && vif.param_ready) emit(PARAM,256'(vif.param_data));
        if(vif.act_in_valid && vif.act_in_ready) emit(INPUT_WORD,256'(vif.act_in_data));
        if(vif.act_out_valid && vif.act_out_ready) emit(OUTPUT_WORD,256'(vif.act_out_data));
        if(vif.pf_valid && vif.pf_ready) emit(PREFETCH_ROW,256'(vif.pf_data));
        // Observe the final row-store ports so an internal result that was
        // overwritten/dropped by arbitration cannot count as a checkpoint.
        if(vif.a_en && vif.a_we) begin
          if($isunknown({vif.a_addr,vif.a_wdata,vif.phase})) `uvm_error("KSE_X","unknown A write")
          a=int'(vif.a_addr); ti=-1; t=0;c=0;
          case(vif.phase)
            PH_IN: begin ti=0;t=a/2;c=32*(a%2);end
            PH_SC: begin ti=4;t=(a-200)/4;c=32*((a-200)%4);end
            PH_SM,PH_PV: begin ti=6;t=(a-600)/2;c=32*((a-600)%2);end
            // Optimization round 2 can start LN1 during PJ; its residual
            // writes still use the same A-store layout and golden tensor.
            PH_PJ,PH_LN1: begin ti=9;t=a/2;c=32*(a%2);end
            PH_FC2: if(a>=800) begin ti=12;t=(a-800)/2;c=32*((a-800)%2);end
                    else begin ti=14;t=a/2;c=32*(a%2);end
            PH_LN2: begin ti=14;t=a/2;c=32*(a%2);end
            default: `uvm_error("KSE_TAP","A write in unexpected phase")
          endcase
          if(ti>=0) emit(TENSOR,vif.a_wdata,ti,t,c);
        end
        if(vif.b_en && vif.b_we) begin
          if($isunknown({vif.b_addr,vif.b_wdata,vif.phase})) `uvm_error("KSE_X","unknown B write")
          a=int'(vif.b_addr);ti=-1;t=0;c=0;
          case(vif.phase)
            PH_QKV: begin ti=1+a/200;t=(a%200)/2;c=32*(a%2);end
            PH_SC,PH_SM: begin ti=5;t=(a-600)/4;c=32*((a-600)%4);end
            PH_PJ: begin ti=7;t=a/2;c=32*(a%2);end
            PH_LN1,PH_FC1: begin ti=11;t=(a-200)/8;c=32*((a-200)%8);end
            default: `uvm_error("KSE_TAP","B write in unexpected phase")
          endcase
          if(ti>=0) emit(TENSOR,vif.b_wdata,ti,t,c);
        end
        if(vif.tap_pre_valid && (vif.phase==PH_LN1 || vif.phase==PH_FC1)) begin
          if($isunknown({vif.tap_tag,vif.tap_pre})) `uvm_error("KSE_X","unknown FC1 tap")
          emit(TENSOR,vif.tap_pre,10,int'(vif.tap_tag[6:0]),32*int'(vif.tap_tag[10:8]));
        end
        if(vif.tap_res_valid) begin
          if($isunknown({vif.ln_sel,vif.tap_res})) `uvm_error("KSE_X","unknown residual tap")
          sel=int'(vif.ln_sel);
          emit(TENSOR,vif.tap_res,sel?13:8,r_tok[sel],32*r_half[sel]);
          r_half[sel]++;if(r_half[sel]==2) begin r_half[sel]=0;r_tok[sel]++;end
        end
        if(vif.done) emit(COMPLETE);
      end
    endtask
    function void report_phase(uvm_phase phase);
      `uvm_info("KSE_TRAFFIC",$sformatf("param_stall=%0d output_stall=%0d input_idle=%0d max_pf=%0d",p_stall,o_stall,i_idle,max_pf),UVM_LOW)
    endfunction
  endclass

  class kse_stream_scoreboard extends uvm_subscriber#(kse_stream_item);
    `uvm_component_utils(kse_stream_scoreboard)
    string names[NT]='{"input","q","k","v","score","softmax","context","proj","res1","ln1","fc1","gelu","fc2","res2","output"};
    int wid[NT]='{64,64,64,64,99,99,64,64,64,64,256,256,64,64,64};
    logic [7:0] tr[NT][12*kse_pkg::T*F], sin[kse_pkg::T*D], sout[kse_pkg::T*D];
    logic [31:0] params[NPW];
    bit seen[longint];
    longint counts[NT], total[NT], last_out_cycle;
    int sample,layers,outall,cur_layer,cmds,dones,pwords,iwords,owords,prows,padding[2];
    longint outputs,final_bytes;
    bit active,corrupt,corrupted,drop, drop_hit;
    covergroup checkpoints with function sample(int ti,int li);
      option.per_instance=1;
      tensor: coverpoint ti {bins tensors[]={[0:14]};}
      layer: coverpoint li {bins layers[]={[0:11]};}
      tensor_layer: cross tensor,layer;
    endgroup
    function new(string name,uvm_component parent);
      super.new(name,parent); checkpoints=new();
      foreach(total[k]) total[k]=0;outputs=0;final_bytes=0;last_out_cycle=0;
      corrupt=$test$plusargs("KSE_CORRUPT_EXPECTED"); drop=$test$plusargs("KSE_DROP_CHECKPOINT");
    endfunction
    function void load_sample(string dir,int s,int nl,int oa);
      logic [7:0] buffer[12*kse_pkg::T*F];
      if(active) `uvm_fatal("KSE_LIFECYCLE","new sample while active")
      sample=s;layers=nl;outall=oa;cmds=0;dones=0;pwords=0;iwords=0;prows=0;cur_layer=-1;
      $readmemh({dir,"/params/params.hex"},params,0,NPW-1);
      $readmemh($sformatf("%s/samples/s%02d_sample_input.hex",dir,s),sin,0,kse_pkg::T*D-1);
      $readmemh($sformatf("%s/samples/s%02d_sample_output.hex",dir,s),sout,0,kse_pkg::T*D-1);
      foreach(names[k]) begin
        $readmemh($sformatf("%s/samples/s%02d_%s.hex",dir,s,names[k]),buffer,0,12*kse_pkg::T*wid[k]-1);
        for(int i=0;i<12*kse_pkg::T*wid[k];i++) tr[k][i]=buffer[i];
      end
    endfunction
    function void compare_byte(string id,logic[7:0] got,logic[7:0] expected,int ti,int tok,int col);
      if(corrupt && !corrupted && ti==14) begin expected^=1;corrupted=1;end
      if(got!==expected) `uvm_error(id,$sformatf("sample=%0d layer=%0d tensor=%0d token=%0d col=%0d got=%02h expected=%02h",sample,cur_layer,ti,tok,col,got,expected))
    endfunction
    function void write(kse_stream_item t);
      kse_stream_item item=t;
      int ti,tok,c,e;longint key;logic[127:0] expected_row;
      case(item.kind)
        CMD: begin
          if(active || cmds>=layers || {item.layer,item.in_en,item.out_en} !== {4'(cmds),1'(cmds==0),1'(outall || cmds==layers-1)})
            `uvm_error("KSE_CMD","unexpected command or lifecycle")
          active=1;cur_layer=cmds;cmds++;owords=0;seen.delete();
          foreach(counts[k]) counts[k]=0;
          padding[0]=0;padding[1]=0;
        end
        PARAM: begin
          if(pwords>=layers*LW || item.data[31:0]!==params[pwords]) `uvm_error("KSE_PARAM","parameter stream data/count mismatch")
          pwords++;
        end
        PREFETCH_ROW: begin
          expected_row='x;
          if(prows<layers*LW/4) for(int i=0;i<4;i++) expected_row[i*32+:32]=params[4*prows+i];
          if(item.data[127:0]!==expected_row || prows>=layers*LW/4) `uvm_error("KSE_PFIFO","prefetch row ordering/data/count mismatch")
          prows++;
        end
        INPUT_WORD: begin
          if(!active || cur_layer!=0 || iwords>=ACT_WORDS) `uvm_error("KSE_INPUT","unexpected activation input")
          else for(int i=0;i<4;i++) compare_byte("KSE_INPUT",item.data[i*8+:8],sin[4*iwords+i],0,(4*iwords+i)/D,(4*iwords+i)%D);
          iwords++;
        end
        OUTPUT_WORD: begin
          if(!active || !(outall || cur_layer==layers-1) || owords>=ACT_WORDS) `uvm_error("KSE_OUTPUT","unexpected activation output")
          else for(int i=0;i<4;i++) begin
            e=4*owords+i;
            compare_byte("KSE_OUTPUT",item.data[i*8+:8],tr[14][cur_layer*kse_pkg::T*D+e],15,e/D,e%D);
            outputs++;
            if(cur_layer==11) begin compare_byte("KSE_FINAL",item.data[i*8+:8],sout[e],16,e/D,e%D);final_bytes++;end
          end
          owords++;last_out_cycle=item.cycle;
        end
        TENSOR: begin
          ti=item.tensor;tok=item.tok;c=item.col;
          if(!active || ti<0 || ti>=NT || tok<0 || tok>=kse_pkg::T || c<0 || c>=((wid[ti]+31)/32)*32)
            `uvm_error("KSE_TAP_RANGE","unexpected checkpoint/address")
          else begin
            checkpoints.sample(ti,cur_layer);
            for(int i=0;i<32;i++) begin
              if(c+i>=wid[ti]) begin
                if(item.data[i*8+:8]!==0) `uvm_error("KSE_PADDING","nonzero tail padding")
                if(ti==4 || ti==5) padding[ti-4]++;
              end else begin
                key=longint'(ti)*kse_pkg::T*F+tok*wid[ti]+c+i;
                if(drop && !drop_hit && ti==1) begin drop_hit=1;continue;end
                if(seen.exists(key)) `uvm_error("KSE_DUPLICATE","duplicate tensor element")
                seen[key]=1;counts[ti]++;total[ti]++;
                compare_byte("KSE_GOLDEN",item.data[i*8+:8],tr[ti][(cur_layer*kse_pkg::T+tok)*wid[ti]+c+i],ti,tok,c+i);
              end
            end
          end
        end
        COMPLETE: begin
          if(!active || prows!=(cur_layer+1)*LW/4 || iwords!=ACT_WORDS || owords!=((outall || cur_layer==layers-1)?ACT_WORDS:0))
            `uvm_error("KSE_COMPLETE","completion before exact input/parameter/output consumption")
          if((outall || cur_layer==layers-1) && item.cycle<=last_out_cycle) `uvm_error("KSE_DRAIN","done before last output accepted")
          foreach(counts[k]) begin
            if(counts[k]!=((k==0 && cur_layer!=0)?0:kse_pkg::T*wid[k]))
              `uvm_error("KSE_MISSING",$sformatf("sample=%0d layer=%0d tensor=%0d count=%0d expected=%0d",sample,cur_layer,k,counts[k],(k==0 && cur_layer!=0)?0:kse_pkg::T*wid[k]))
          end
          if(padding[0]!=kse_pkg::T*29 || padding[1]!=kse_pkg::T*29) `uvm_error("KSE_PADDING_COUNT","missing score/probability padding checks")
          dones++;active=0;
          `uvm_info("KSE_LAYER",$sformatf("sample=%0d layer=%0d cycle=%0d param_in=%0d loader_rows=%0d input_words=%0d output_words=%0d",sample,cur_layer,item.cycle,pwords,prows,iwords,owords),UVM_LOW)
        end
      endcase
    endfunction
    function void finish_sample();
      if(active || cmds!=layers || dones!=layers || pwords!=layers*LW || prows!=layers*LW/4) `uvm_error("KSE_COUNTS","incomplete sample")
    endfunction
    function void report_phase(uvm_phase phase);
      foreach(total[k]) `uvm_info("KSE_COMPARE",$sformatf("tensor=%s bytes=%0d",names[k],total[k]),UVM_LOW)
      `uvm_info("KSE_COMPARE",$sformatf("act_out_bytes=%0d final_bytes=%0d corrupt_hit=%0d drop_hit=%0d",outputs,final_bytes,corrupted,drop_hit),UVM_LOW)
    endfunction
  endclass

  class kse_network_driver extends uvm_driver#(kse_network_request);
    `uvm_component_utils(kse_network_driver)
    virtual kse_stream_if vif;
    logic[31:0] params[NPW];logic[7:0] act[kse_pkg::T*D];
    function new(string name,uvm_component parent);super.new(name,parent);endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual kse_stream_if)::get(this,"","vif",vif)) `uvm_fatal("KSE_CFG","missing vif")
    endfunction
    task run_phase(uvm_phase phase);
      vif.cmd_valid=0;vif.cmd_layer=0;vif.cmd_in_en=0;vif.cmd_out_en=0;
      vif.param_valid=0;vif.param_data=0;vif.act_in_valid=0;vif.act_in_data=0;vif.act_out_ready=0;
      wait(vif.rst_n===1);repeat(2) @(negedge vif.clk);
      forever begin
        seq_item_port.get_next_item(req);drive_network(req);seq_item_port.item_done();
      end
    endtask
    task drive_network(kse_network_request job);
      bit started;
      $readmemh({job.data_dir,"/params/params.hex"},params,0,NPW-1);
      $readmemh($sformatf("%s/samples/s%02d_sample_input.hex",job.data_dir,job.sample),act,0,kse_pkg::T*D-1);
      started=0;
      fork
        begin : commands
          for(int l=0;l<job.layers;l++) begin
            @(negedge vif.clk);
            vif.cmd_valid=1;vif.cmd_layer=4'(l);vif.cmd_in_en=(l==0);vif.cmd_out_en=job.outall || l==job.layers-1;
            do @(posedge vif.clk);while(vif.cmd_ready!==1);
            started=1;
            @(negedge vif.clk);vif.cmd_valid=0;
            do @(posedge vif.clk);while(vif.done!==1);
          end
        end
        begin : parameters
          wait(started);@(negedge vif.clk);
          for(int p=0;p<job.layers*LW;p++) begin
            vif.param_valid=0;
            if(job.mode) repeat($urandom_range(0,job.mode==1?2:6)) @(negedge vif.clk);
            vif.param_valid=1;vif.param_data=params[p];
            do @(posedge vif.clk);while(vif.param_ready!==1);
            @(negedge vif.clk);
          end
          vif.param_valid=0;
        end
        begin : inputs
          wait(started);@(negedge vif.clk);
          for(int w=0;w<ACT_WORDS;w++) begin
            vif.act_in_valid=0;
            if(job.mode) repeat($urandom_range(0,3)) @(negedge vif.clk);
            vif.act_in_valid=1;
            for(int b=0;b<4;b++) vif.act_in_data[8*b+:8]=act[4*w+b];
            do @(posedge vif.clk);while(vif.act_in_ready!==1);
            @(negedge vif.clk);
          end
          vif.act_in_valid=0;
        end
        begin : outputs
          wait(started);@(negedge vif.clk);
          for(int w=0;w<ACT_WORDS*(job.outall?job.layers:1);w++) begin
            vif.act_out_ready=0;
            while(vif.act_out_valid!==1) @(negedge vif.clk);
            if(job.mode) repeat((w%ACT_WORDS==0 || w%ACT_WORDS==ACT_WORDS-1)?12:$urandom_range(0,3)) @(negedge vif.clk);
            vif.act_out_ready=1;
            do @(posedge vif.clk);while(vif.act_out_valid!==1);
            @(negedge vif.clk);
          end
          vif.act_out_ready=0;
        end
      join
      repeat(3) @(negedge vif.clk);
    endtask
  endclass

  class kse_network_sequence extends uvm_sequence#(kse_network_request);
    `uvm_object_utils(kse_network_sequence)
    kse_network_request job;
    function new(string name="kse_network_sequence");super.new(name);endfunction
    task body();start_item(job);finish_item(job);endtask
  endclass

  class test_kse_stream extends uvm_test;
    `uvm_component_utils(test_kse_stream)
    kse_network_driver driver;
    uvm_sequencer#(kse_network_request) sequencer;
    kse_stream_monitor monitor;
    kse_stream_scoreboard sb;
    function new(string name,uvm_component parent);super.new(name,parent);endfunction
    function void build_phase(uvm_phase phase);
      driver=kse_network_driver::type_id::create("driver",this);
      sequencer=new("sequencer",this);monitor=kse_stream_monitor::type_id::create("monitor",this);
      sb=kse_stream_scoreboard::type_id::create("sb",this);
    endfunction
    function void connect_phase(uvm_phase phase);
      driver.seq_item_port.connect(sequencer.seq_item_export);monitor.ap.connect(sb.analysis_export);
    endfunction
    task run_phase(uvm_phase phase);
      string dir;int first=0,ns=1,nl=12,oa=1,mode=0;
      phase.raise_objection(this);
      if(!$value$plusargs("DATA=%s",dir)) `uvm_fatal("KSE_CFG","DATA required")
      void'($value$plusargs("SAMPLE0=%d",first));void'($value$plusargs("SAMPLES=%d",ns));
      void'($value$plusargs("LAYERS=%d",nl));void'($value$plusargs("OUTALL=%d",oa));void'($value$plusargs("MODE=%d",mode));
      if(first<0 || ns<1 || first+ns>24 || nl<1 || nl>12 || oa<0 || oa>1 || mode<0 || mode>2) `uvm_fatal("KSE_CFG","invalid matrix")
      fork
        begin
          for(int s=first;s<first+ns;s++) begin
            kse_network_sequence seq=new();seq.job=new();
            sb.load_sample(dir,s,nl,oa);
            seq.job.sample=s;seq.job.layers=nl;seq.job.outall=oa;seq.job.mode=mode;seq.job.data_dir=dir;
            seq.start(sequencer);sb.finish_sample();
          end
        end
        begin
          repeat(ns*nl*200000) @(posedge driver.vif.clk);
          `uvm_fatal("KSE_WATCHDOG","network progress deadline exceeded")
        end
      join_any
      disable fork;
      `uvm_info("KSE_STREAM_COMPLETE",$sformatf("samples=%0d first=%0d layers=%0d mode=%0d outall=%0d",ns,first,nl,mode,oa),UVM_NONE)
      phase.drop_objection(this);
    endtask
    function void report_phase(uvm_phase phase);
      if(uvm_report_server::get_server().get_severity_count(UVM_ERROR)==0 && uvm_report_server::get_server().get_severity_count(UVM_FATAL)==0)
        `uvm_info("KSE_RESULT","TEST PASSED",UVM_NONE)
    endfunction
  endclass
endpackage
