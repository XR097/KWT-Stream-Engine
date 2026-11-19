# Detailed positive-slack paths as well as violations, on the final SoC.
# KSE_NETLIST=<mapped.v> KSE_SDC=<mapped.sdc> pt_shell -f timing_soc.tcl > pt.log 2>&1
set link_path [list * $env(SMIC40_STDCELL_DB) $env(SMIC40_RAM4096_DB) $env(SMIC40_RAM1024_DB) $env(SMIC40_RAM128_DB)]
set_app_var report_default_significant_digits 9
read_verilog $env(KSE_NETLIST)
current_design kse_e203_soc_top
if {![link_design]} { puts "AUDIT_FAIL link"; exit 1 }
read_sdc $env(KSE_SDC)
set MAIN u_e203_subsys_top/u_e203_subsys_main
set accel_eps [get_cells -hier -filter "is_hierarchical==false && (full_name=~${MAIN}/u_kse_sys/* || full_name=~${MAIN}/u_e203_subsys_plic/*) && (is_sequential==true || ref_name=~RAMSP*)"]
set e203_eps [get_cells -hier -filter "is_hierarchical==false && full_name=~${MAIN}/u_e203_cpu_top/* && (is_sequential==true || ref_name=~RAMSP*)"]
group_path -name accel -to $accel_eps
group_path -name e203 -to $e203_eps
update_timing -full
redirect disabled_timing.rpt {report_disable_timing}
redirect check_timing.rpt {check_timing -verbose}
set f [open timing_metrics.tsv w]
puts $f "group\tanalysis\tslack_ns\tstartpoint\tendpoint"
foreach g {accel e203 core slow jtag} {
  foreach dt {max min} {
    set ps [get_timing_paths -group $g -delay_type $dt -max_paths 1]
    if {[sizeof_collection $ps]} {
      puts $f "$g\t$dt\t[get_attribute $ps slack]\t[get_object_name [get_attribute $ps startpoint]]\t[get_object_name [get_attribute $ps endpoint]]"
    }
    redirect timing_${g}_${dt}.rpt {report_timing -group $g -delay_type $dt -slack_lesser_than 1000000 -max_paths 3 -significant_digits 9 -nosplit -input_pins}
  }
}
set aq [filter_collection [all_registers -clock_pins] "full_name=~${MAIN}/u_kse_sys/* || full_name=~${MAIN}/u_e203_subsys_plic/*"]
foreach dt {max min} {
  set ps [get_timing_paths -from $aq -delay_type $dt -max_paths 1]
  puts $f "accel_launch_any\t$dt\t[get_attribute $ps slack]\t[get_object_name [get_attribute $ps startpoint]]\t[get_object_name [get_attribute $ps endpoint]]"
  redirect timing_accel_launch_$dt.rpt {report_timing -from $aq -delay_type $dt -slack_lesser_than 1000000 -max_paths 3 -significant_digits 9 -nosplit}
}
close $f
puts "TIMING_AUDIT_DONE"
exit
