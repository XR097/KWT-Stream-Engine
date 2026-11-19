# DC area of the logic added for the KSE SoC integration (SMIC40LL RVT
# tt_typical_max 1.10 V 25 C, 150 MHz, same constraints as tools/kse/synth_kse.tcl).
# Run from an output directory outside the repository:
#   KSE_REPO=<repo> dc_shell -no_home_init -f <repo>/tools/kse_soc/synth_added.tcl > dc.log 2>&1
# Designs (one after another):
#   eng      kse_eng_icb with kse_top left unresolved (black box, 0 area): MMIO registers,
#            command/segment queues, stream buffers, DMA request/release logic
#   sram     kse_shared_sram: one 32-bit ICB slave, flat 128K x 32 macro array
#            (macros from .db, reported separately)
#   bus      kse_sys_bus: upstream sirv_gnrl_icb_arbt 3 -> 1, no macros
#   plic18   kse_sirv_plic_top (sources 1..17)
#   plic17   upstream sirv_plic_top (sources 1..16)
set REPO $env(KSE_REPO)
set CLK_PERIOD 6.667
set E $REPO/third-party/e203/rtl/e203
set_app_var search_path [concat [get_app_var search_path] [list $E/core $E/perips]]
source $REPO/tools/kse_soc/syn_common.tcl
set_host_options -max_cores 2

proc constrain {} {
  global CLK_PERIOD
  create_clock -name clk -period $CLK_PERIOD [get_ports clk]
  set_clock_uncertainty 0.1 [get_clocks clk]
  set inputs [remove_from_collection [all_inputs] [get_ports {clk}]]
  set_input_delay  [expr 0.2 * $CLK_PERIOD] -clock clk $inputs
  set_output_delay [expr 0.2 * $CLK_PERIOD] -clock clk [all_outputs]
  set_input_transition 0.1 $inputs
  set_load 0.005 [all_outputs]
  set_false_path -from [get_ports rst_n]
  set_fix_hold [get_clocks clk]
}

proc run_one {tag top files {params ""} {allowed {}}} {
  remove_design -all
  file mkdir ./work_$tag
  define_design_lib WORK -path ./work_$tag
  # ARM_UD_MODEL selects the real RAMSP4096X16 macro (resolved from its .db) in kse_shared_sram
  kse_analyze $files {ARM_UD_MODEL SYNTHESIS}
  kse_elab_link $top $params $allowed $tag
  constrain
  compile_ultra -no_autoungroup
  compile -incremental_mapping -only_hold_time
  redirect area_$tag.rpt      {report_area -nosplit}
  redirect area_hier_$tag.rpt {report_area -hierarchy -nosplit}
  redirect timing_$tag.rpt    {report_timing -delay_type max -max_paths 5 -nosplit}
  redirect constr_$tag.rpt    {report_constraint -all_violators -nosplit}
  redirect refs_$tag.rpt      {report_reference -nosplit}
  set slack [get_attribute [get_timing_paths -delay_type max -max_paths 1] slack]
  set ram [get_cells -hierarchical -quiet -filter "ref_name =~ RAMSP*"]
  set f [open metrics_$tag.txt w]
  puts $f "top=$top"
  puts $f "macro_count=[sizeof_collection $ram]"
  puts $f "wns_ns=$slack"
  puts $f "ff_count=[sizeof_collection [all_registers -edge_triggered]]"
  puts $f "latch_count=[sizeof_collection [all_registers -level_sensitive]]"
  close $f
  puts "SYN_ONE_DONE $tag"
}

set S $REPO/rtl/kse_soc
# kse_top is the only allowed black box (its area is reported by tools/kse/synth_kse.tcl)
run_one eng   kse_eng_icb [list $S/kse_soc_fifo.sv $S/kse_eng_icb.sv] "" {kse_top}
run_one sram kse_shared_sram [list $S/kse_sram_ctrl.sv $S/kse_shared_sram.sv]
run_one bus  kse_sys_bus [list $E/general/sirv_gnrl_dffs.v $E/general/sirv_gnrl_bufs.v \
                              $E/general/sirv_gnrl_xchecker.v $E/general/sirv_gnrl_icbs.v \
                              $S/kse_sys_bus.sv]
set PL [list $E/general/sirv_gnrl_dffs.v $E/general/sirv_gnrl_bufs.v \
            $E/perips/sirv_LevelGateway.v $E/perips/sirv_plic_man.v]
run_one plic18 kse_sirv_plic_top [concat $PL [list $S/kse_sirv_plic_top.v]]
run_one plic17 sirv_plic_top [concat $PL [list $E/perips/sirv_plic_top.v]]
puts "SYN_DONE"
exit
