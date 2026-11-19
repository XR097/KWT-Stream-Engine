package kse_numeric_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `uvm_analysis_imp_decl(_request)
  `uvm_analysis_imp_decl(_actual)
  class kse_num_item extends uvm_sequence_item;
    `uvm_object_utils(kse_num_item)
    int op;
    logic [63:0] a,b,c,d,e,f,y,z;
    longint cycle;
    function new(string name="kse_num_item");super.new(name);endfunction
  endclass
  class num_queue;
    kse_num_item pending[$];
  endclass

  class kse_num_scoreboard extends uvm_component;
    `uvm_component_utils(kse_num_scoreboard)
    uvm_analysis_imp_request#(kse_num_item,kse_num_scoreboard) requests;
    uvm_analysis_imp_actual#(kse_num_item,kse_num_scoreboard) actuals;
    num_queue queues[10];longint compared[10],accepted[10];bit corrupt,hit;
    covergroup numerical with function sample(int op,bit ovf);
      option.per_instance=1;
      operation: coverpoint op {bins ops[]={[0:9]};}
      divider_overflow: coverpoint ovf;
    endgroup
    function new(string name,uvm_component parent);
      super.new(name,parent);requests=new("requests",this);actuals=new("actuals",this);numerical=new();
      foreach(queues[i]) begin queues[i]=new();compared[i]=0;accepted[i]=0;end
      corrupt=$test$plusargs("KSE_NUM_CORRUPT_EXPECTED");
    endfunction
    function void write_request(kse_num_item t);
      kse_num_item copy=new();copy.copy(t);
      // copy() has no field automation; make all compared fields explicit.
      copy.op=t.op;copy.a=t.a;copy.b=t.b;copy.c=t.c;copy.y=t.y;copy.z=t.z;copy.cycle=t.cycle;
      if(corrupt && !hit && t.op==0) begin copy.y^=1;hit=1;end
      queues[t.op].pending.push_back(copy);accepted[t.op]++;
    endfunction
    function void write_actual(kse_num_item t);
      kse_num_item expected;bit bad;
      if(t.op<0 || t.op>9 || queues[t.op].pending.size()==0) begin `uvm_error("KSE_NUM_EXTRA","unexpected numerical output") return;end
      expected=queues[t.op].pending.pop_front();bad=0;
      if(t.op==2 || t.op==3) begin
        bad=(t.z!==expected.z || t.c!==expected.c || (expected.z==0 && t.y!==expected.y));
        if(t.cycle-expected.cycle!=(t.op==2?4:15)) `uvm_error("KSE_NUM_LATENCY","divider latency/tag alignment")
      end else begin
        bad=(t.y!==expected.y);
        if((t.op==4 || t.op==9) && t.cycle-expected.cycle!=(t.op==4?9:6)) `uvm_error("KSE_NUM_LATENCY","isqrt latency")
      end
      if(bad) `uvm_error("KSE_NUM_SB",$sformatf("op=%0d index=%0d got=%016h expected=%016h",t.op,compared[t.op],t.y,expected.y))
      compared[t.op]++;numerical.sample(t.op,t.z[0]);
    endfunction
    function void check_phase(uvm_phase phase);
      foreach(queues[i]) if(queues[i].pending.size()!=0 || compared[i]!==accepted[i] || compared[i]==0) `uvm_error("KSE_NUM_MISSING","unconsumed or missing numerical checks")
    endfunction
    function void report_phase(uvm_phase phase);
      foreach(compared[i]) `uvm_info("KSE_NUM_COUNT",$sformatf("op=%0d accepted=%0d compared=%0d",i,accepted[i],compared[i]),UVM_LOW)
    endfunction
  endclass

  class kse_num_monitor extends uvm_component;
    `uvm_component_utils(kse_num_monitor)
    virtual kse_numeric_if vif;uvm_analysis_port#(kse_num_item) ap;
    longint cycle;logic[2:0] post_v;logic[7:0] previous_pre;
    function new(string name,uvm_component parent);super.new(name,parent);ap=new("ap",this);cycle=0;post_v=0;endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual kse_numeric_if)::get(this,"","vif",vif)) `uvm_fatal("KSE_NUM_CFG","missing vif")
    endfunction
    function void emit(int op,logic[63:0] y,logic[63:0] z=0,logic[63:0] tag=0);
      kse_num_item t=new();t.op=op;t.y=y;t.z=z;t.c=tag;t.cycle=cycle;ap.write(t);
    endfunction
    task run_phase(uvm_phase phase);
      forever begin
        @(posedge vif.clk);cycle++;#1;
        post_v={post_v[1:0],(vif.fire && vif.op==8)};
        if(!vif.rst_n || !vif.enabled) begin previous_pre=vif.post_pre;continue;end
        if(vif.fire) case(vif.op)
          0:emit(0,64'(vif.shifted));1:emit(1,64'(vif.saturated));
          5:emit(5,64'(vif.gelu));6:emit(6,64'(vif.exp_rom));7:emit(7,64'(vif.exp_lane));
          default:;
        endcase
        if(vif.div_sm_v===1) emit(2,64'(vif.div_sm_q),64'(vif.div_sm_ovf),64'(vif.div_sm_tag));
        if(vif.div_ln_v===1) emit(3,64'(vif.div_ln_q),64'(vif.div_ln_ovf),64'(vif.div_ln_tag));
        if(vif.sqrt2_done===1) emit(4,64'(vif.sqrt2));
        if(vif.sqrt3_done===1) emit(9,64'(vif.sqrt3));
        if(post_v[2]) emit(8,64'({vif.post_y,previous_pre}));
        if($isunknown({vif.div_sm_v,vif.div_ln_v,vif.sqrt2_done,vif.sqrt3_done})) `uvm_error("KSE_NUM_X","unknown valid after pipeline flush")
        previous_pre=vif.post_pre;
      end
    endtask
  endclass

  class kse_num_driver extends uvm_driver#(kse_num_item);
    `uvm_component_utils(kse_num_driver)
    virtual kse_numeric_if vif;uvm_analysis_port#(kse_num_item) expected;
    longint cycle;
    function new(string name,uvm_component parent);super.new(name,parent);expected=new("expected",this);cycle=0;endfunction
    function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual kse_numeric_if)::get(this,"","vif",vif)) `uvm_fatal("KSE_NUM_CFG","missing vif")
    endfunction
    task run_phase(uvm_phase phase);
      fork forever begin @(posedge vif.clk);cycle++;end join_none
      vif.enabled=0;vif.fire=0;vif.op=0;vif.a=0;vif.b=0;vif.c=0;vif.d=0;vif.e=0;vif.f=0;
      wait(vif.rst_n===1);repeat(20) @(negedge vif.clk);vif.enabled=1;
      forever begin
        seq_item_port.get_next_item(req);
        vif.fire=1;vif.op=4'(req.op);vif.a=req.a;vif.b=req.b;vif.c=req.c;vif.d=req.d;vif.e=req.e;vif.f=req.f;
        req.cycle=cycle+1;expected.write(req);
        if(req.op==4) begin
          kse_num_item other=new();other.op=9;other.a=req.a;other.y=req.y;other.z=req.z;other.cycle=cycle+1;expected.write(other);
        end
        @(negedge vif.clk);vif.fire=0;
        if(req.op==4) begin
          do @(negedge vif.clk);while(vif.sqrt2_done!==1);
        end
        if(req.op==8) repeat(2) @(negedge vif.clk);
        if((req.op==2 || req.op==3) && $urandom_range(0,3)==0) repeat($urandom_range(1,3)) @(negedge vif.clk);
        seq_item_port.item_done();
      end
    endtask
  endclass

  class kse_num_sequence extends uvm_sequence#(kse_num_item);
    `uvm_object_utils(kse_num_sequence)
    string file;
    function new(string name="kse_num_sequence");super.new(name);endfunction
    task body();
      int fd,n;logic[63:0] op;kse_num_item t;
      fd=$fopen(file,"r");if(fd==0) `uvm_fatal("KSE_NUM_FILE","cannot open vectors")
      while(!$feof(fd)) begin
        t=new();n=$fscanf(fd,"%h %h %h %h %h %h %h %h %h\n",op,t.a,t.b,t.c,t.d,t.e,t.f,t.y,t.z);
        if(n!=9 || op>8) `uvm_fatal("KSE_NUM_FILE","malformed vector")
        t.op=int'(op);start_item(t);finish_item(t);
      end
      $fclose(fd);
    endtask
  endclass

  class test_kse_numeric extends uvm_test;
    `uvm_component_utils(test_kse_numeric)
    kse_num_driver driver;kse_num_monitor monitor;kse_num_scoreboard sb;
    uvm_sequencer#(kse_num_item) sequencer;
    function new(string name,uvm_component parent);super.new(name,parent);endfunction
    function void build_phase(uvm_phase phase);
      driver=kse_num_driver::type_id::create("driver",this);monitor=kse_num_monitor::type_id::create("monitor",this);
      sb=kse_num_scoreboard::type_id::create("sb",this);sequencer=new("sequencer",this);
    endfunction
    function void connect_phase(uvm_phase phase);
      driver.seq_item_port.connect(sequencer.seq_item_export);driver.expected.connect(sb.requests);monitor.ap.connect(sb.actuals);
    endfunction
    task run_phase(uvm_phase phase);
      kse_num_sequence seq=new();phase.raise_objection(this);
      if(!$value$plusargs("VECTORS=%s",seq.file)) `uvm_fatal("KSE_NUM_CFG","VECTORS required")
      fork
        begin seq.start(sequencer);repeat(30) @(negedge driver.vif.clk);end
        begin repeat(1000000) @(posedge driver.vif.clk);`uvm_fatal("KSE_NUM_WATCHDOG","numeric progress deadline exceeded") end
      join_any
      disable fork;
      `uvm_info("KSE_NUM_COMPLETE","numerical vectors consumed",UVM_NONE)
      phase.drop_objection(this);
    endtask
    function void report_phase(uvm_phase phase);
      if(uvm_report_server::get_server().get_severity_count(UVM_ERROR)==0 && uvm_report_server::get_server().get_severity_count(UVM_FATAL)==0)
        `uvm_info("KSE_NUM_RESULT","TEST PASSED",UVM_NONE)
    endfunction
  endclass
endpackage
