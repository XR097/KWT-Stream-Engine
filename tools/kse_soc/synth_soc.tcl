# Full KSE SoC synthesis (E203 + interconnect + PLIC + single-port shared SRAM
# + engine wrapper/DMA + kse_top), SMIC40LL RVT tt_typical_max 1.10 V 25 C, 150 MHz,
# SRAM macros from the PDK memory .db (tt 1.10 V 25 C).  No black box is allowed.
# Run from an output directory outside the repository:
#   KSE_REPO=<repo> KSE_SYN_FILES=<file list> [KSE_SAIF=<rtl saif>] \
#     dc_shell -no_home_init -f <repo>/tools/kse_soc/synth_soc.tcl > dc.log 2>&1
set REPO $env(KSE_REPO)
set E $REPO/third-party/e203/rtl/e203
set_app_var search_path [concat [get_app_var search_path] [list $E/core $E/perips $E/perips/apb_i2c]]
source $REPO/tools/kse_soc/syn_common.tcl
set_host_options -max_cores 2
set_app_var report_default_significant_digits 9
file mkdir ./work
define_design_lib WORK -path ./work

set fh [open $env(KSE_SYN_FILES) r]; set files [split [string trim [read $fh]] "\n"]; close $fh
set defs {SYNTHESIS DISABLE_SV_ASSERTION ARM_UD_MODEL}
if {[info exists env(KSE_LANES8)]} { lappend defs KSE_LANES8 }
if {[info exists env(KSE_LANES16)]} { lappend defs KSE_LANES16 }
if {[info exists env(KSE_ARRAY_R16)]} { lappend defs KSE_ARRAY_R16 }
kse_analyze $files $defs
kse_elab_link kse_e203_soc_top "" {} soc
saif_map -start

source $REPO/tools/kse_soc/kse_soc.sdc
# Reserve 10 ps during optimization; final reports use the required 0.1 ns.
set_clock_uncertainty 0.11 [all_clocks]
set_fix_hold [all_clocks]
# Leaf cells only: is_sequential is also true on some hierarchical E203
# wrappers. Such cells invalidate the entire group_path command (UID-12).
set MAIN u_e203_subsys_top/u_e203_subsys_main
set SYS $MAIN/u_kse_sys
set CPU $MAIN/u_e203_cpu_top
set accel_eps [get_cells -hier -filter "is_hierarchical==false && (full_name=~${SYS}/* || full_name=~${MAIN}/u_e203_subsys_plic/*) && (is_sequential==true || ref_name=~RAMSP*)"]
set e203_eps [get_cells -hier -filter "is_hierarchical==false && full_name=~${CPU}/* && (is_sequential==true || ref_name=~RAMSP*)"]
if {![sizeof_collection $accel_eps] || ![sizeof_collection $e203_eps]} { kse_fail "empty endpoints" }
if {![group_path -name accel -to $accel_eps -critical_range 1.0 -weight 5]} { kse_fail "group accel" }
if {![group_path -name e203 -to $e203_eps -critical_range 1.0]} { kse_fail "group e203" }
puts "PATH_GROUPS accel_endpoints=[sizeof_collection $accel_eps] e203_endpoints=[sizeof_collection $e203_eps]"
redirect path_groups.rpt {report_path_group}
redirect check_timing_pre.rpt {check_timing}

compile_ultra -no_autoungroup
compile -incremental_mapping -only_hold_time
set_clock_uncertainty 0.1 [all_clocks]

redirect check_design.rpt   {check_design}
redirect check_timing.rpt   {check_timing}
redirect area.rpt           {report_area -nosplit}
redirect area_hier.rpt      {report_area -hierarchy -nosplit}
redirect qor.rpt            {report_qor}
redirect clocks.rpt         {report_clock -nosplit}
redirect constraints.rpt    {report_constraint -all_violators -nosplit}
foreach g {accel e203 core slow jtag} {
  redirect timing_setup_$g.rpt {report_timing -delay_type max -group $g -max_paths 10 -nosplit}
  redirect timing_hold_$g.rpt  {report_timing -delay_type min -group $g -max_paths 10 -nosplit}
}
redirect timing_setup_all.rpt {report_timing -delay_type max -max_paths 20 -nosplit}
redirect timing_hold_all.rpt  {report_timing -delay_type min -max_paths 20 -nosplit}
redirect refs.rpt           {report_reference -hierarchy -nosplit}
redirect latches.rpt        {report_cell -nosplit [all_registers -level_sensitive]}

set f [open metrics.txt w]
puts $f "optimization_uncertainty_ns=0.11"
puts $f "reported_uncertainty_ns=0.1"
foreach g {accel e203 core slow jtag} {
  foreach dt {max min} {
    set p [get_timing_paths -delay_type $dt -group $g -max_paths 1]
    if {[sizeof_collection $p]} {
      puts $f "${g}_${dt}_slack_ns=[get_attribute $p slack]"
    } else { puts $f "${g}_${dt}_slack_ns=NA" }
  }
}
puts $f "total_area_um2=[get_attribute [current_design] area]"
puts $f "macros=[sizeof_collection [get_cells -hierarchical -filter {ref_name =~ RAMSP*}]]"
puts $f "flip_flops=[sizeof_collection [all_registers -edge_triggered]]"
puts $f "latches=[sizeof_collection [all_registers -level_sensitive]]"
close $f

write -format ddc -hierarchy -output kse_soc_mapped.ddc
write -format verilog -hierarchy -output kse_soc_mapped.v
write_sdc kse_soc_mapped.sdc
if {[info exists env(KSE_SAIF)]} {
  saif_map -create_map -input $env(KSE_SAIF) -source_instance tb_kse_soc/u_soc
  saif_map -write_map kse_soc_saif_map.ptpx.tcl -type ptpx
  saif_map -write_map kse_soc_saif_map.dc.tcl
}
puts "SYN_DONE"
exit
