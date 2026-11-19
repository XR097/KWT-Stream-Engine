# PrimePower (pt_shell) averaged power of the synthesized KSE SoC over the 12
# scoring windows.  Libraries/corner as in syn_common.tcl (SMIC40LL RVT
# tt_typical_max 1.10 V 25 C; RAMSP* tt 1.10 V 25 C Liberty incl. power).
# Run from an output directory outside the repository:
#   KSE_NETLIST=<kse_soc_mapped.v> KSE_SDC=<kse_soc_mapped.sdc> KSE_SAIF=<12-window SAIF>
#   KSE_MAP=<kse_soc_saif_map.ptpx.tcl> [KSE_DEFAULT_TR=0.1] pt_shell -f power_soc.tcl > pt.log 2>&1
# Unannotated start points (primary inputs, cells with no annotated/propagated
# input activity) get power_default_toggle_rate (default 0.1 per clock cycle of the
# fastest clock) and static probability 0.5.  Everything else is
# SAIF-annotated or propagated through the netlist.
set STD_DB $env(SMIC40_STDCELL_DB)
set RAM4K_DB $env(SMIC40_RAM4096_DB)
set RAM1K_DB $env(SMIC40_RAM1024_DB)
set RAM128_DB $env(SMIC40_RAM128_DB)
set power_enable_analysis true
set power_analysis_mode averaged
set search_path "."
set link_path [list * $STD_DB $RAM4K_DB $RAM1K_DB $RAM128_DB]
set DTR 0.1
if {[info exists env(KSE_DEFAULT_TR)]} { set DTR $env(KSE_DEFAULT_TR) }

set_app_var report_default_significant_digits 9
read_verilog $env(KSE_NETLIST)
current_design kse_e203_soc_top
redirect -variable lk { set ok [link_design] }
puts $lk
if {!$ok || [regexp {Unable to resolve|unresolved} $lk]} { puts "POWER_FAIL: link"; exit 1 }
read_sdc $env(KSE_SDC)
# Recreate valid leaf-only groups also for older synthesis checkpoints whose
# group_path commands failed. Includes all PLIC endpoints conservatively.
set MAIN u_e203_subsys_top/u_e203_subsys_main
set accel_eps [get_cells -hier -filter "is_hierarchical==false && (full_name=~${MAIN}/u_kse_sys/* || full_name=~${MAIN}/u_e203_subsys_plic/*) && (is_sequential==true || ref_name=~RAMSP*)"]
set e203_eps [get_cells -hier -filter "is_hierarchical==false && full_name=~${MAIN}/u_e203_cpu_top/* && (is_sequential==true || ref_name=~RAMSP*)"]
group_path -name accel -to $accel_eps
group_path -name e203 -to $e203_eps
update_timing -full
catch {redirect check_timing.rpt {check_timing -verbose}}
foreach g {accel e203 core slow jtag} {
  if {[sizeof_collection [get_path_groups -quiet $g]]} {
    redirect timing_setup_$g.rpt {report_timing -delay_type max -group $g -slack_lesser_than 1000000 -max_paths 5 -nosplit}
    redirect timing_hold_$g.rpt {report_timing -delay_type min -group $g -slack_lesser_than 1000000 -max_paths 5 -nosplit}
  }
}
set tf [open timing_metrics.tsv w]
puts $tf "group\tlaunch_clock\tanalysis\tslack_ns\tstartpoint\tendpoint"
foreach g {accel e203 core slow jtag} {
  if {![sizeof_collection [get_path_groups -quiet $g]]} { continue }
  foreach_in_collection c [all_clocks] {
    foreach dt {max min} {
      set ps [get_timing_paths -group $g -from $c -delay_type $dt -max_paths 1]
      if {[sizeof_collection $ps]} {
        puts $tf "$g\t[get_object_name $c]\t$dt\t[get_attribute $ps slack]\t[get_object_name [get_attribute $ps startpoint]]\t[get_object_name [get_attribute $ps endpoint]]"
      }
    }
  }
}
# Also check paths launched inside the accelerator toward platform endpoints.
# Endpoint-only groups alone would omit these outbound interface paths.
set accel_launch_pins [filter_collection [all_registers -clock_pins] "full_name=~${MAIN}/u_kse_sys/* || full_name=~${MAIN}/u_e203_subsys_plic/*"]
foreach dt {max min} {
  set ps [get_timing_paths -from $accel_launch_pins -delay_type $dt -max_paths 1]
  if {[sizeof_collection $ps]} {
    puts $tf "accel_launch_any\tany\t$dt\t[get_attribute $ps slack]\t[get_object_name [get_attribute $ps startpoint]]\t[get_object_name [get_attribute $ps endpoint]]"
  }
  redirect timing_accel_launch_$dt.rpt {report_timing -from $accel_launch_pins -delay_type $dt -slack_lesser_than 1000000 -max_paths 5 -nosplit}
}
close $tf
catch {redirect global_timing.rpt {report_global_timing}}
catch {redirect constraints.rpt {report_constraint -all_violators -nosplit}}

set power_default_toggle_rate $DTR
set power_default_toggle_rate_reference_clock fastest
set power_default_static_probability 0.5
source $env(KSE_MAP)
redirect saif_read.log { read_saif -strip_path tb_kse_soc/u_soc $env(KSE_SAIF) }
redirect switching_summary.rpt { report_switching_activity }
redirect switching_default.rpt { report_switching_activity -list_by_source default -show_pin }
update_power
redirect switching_after_update.rpt { report_switching_activity }
redirect power.rpt        { report_power -nosplit }
redirect power_hier.rpt   { report_power -hierarchy -levels 4 -nosplit }
catch {redirect power_macros.rpt { report_power -cell_power -nosplit [get_cells -hierarchical -filter "ref_name =~ RAMSP*"] }}
puts "POWER_MAIN total=[get_attribute [current_design] total_power]"
# Each sensitivity point MUST use a fresh pt_shell: propagated activity can be
# cached across update_power calls. run_power.sh runs 0.1, 0, 0.2 serially.
set f [open power_components.tsv w]
puts $f "component\tinternal_W\tswitching_W\tleakage_W\ttotal_W"
proc power_row {f name obj} {
  set vals [list $name]
  foreach a {internal_power switching_power leakage_power total_power} {
    lappend vals [get_attribute $obj $a]
  }
  puts $f [join $vals "\t"]
}
power_row $f soc [current_design]
set MAIN u_e203_subsys_top/u_e203_subsys_main
foreach {name path} [list cpu $MAIN/u_e203_cpu_top engine $MAIN/u_kse_sys/u_eng/u_kse wrapper_and_engine $MAIN/u_kse_sys/u_eng shared $MAIN/u_kse_sys/u_shram] {
  power_row $f $name [get_cells $path]
}
set macros [get_cells -hierarchical -filter "ref_name =~ RAMSP*"]
foreach_in_collection c $macros { power_row $f [get_object_name $c] $c }
close $f
# Additional read-only breakdown for fair-baseline attribution.
set ef [open power_engine_hierarchy.tsv w]
puts $ef "component\tinternal_W\tswitching_W\tleakage_W\ttotal_W"
set ENG $MAIN/u_kse_sys/u_eng/u_kse
foreach_in_collection c [get_cells -hierarchical -filter "is_hierarchical==true && full_name=~${ENG}/*"] {
  power_row $ef [get_object_name $c] $c
}
close $ef
# Exact pin-level provenance, including memory input pins (the overview's
# Memory row counts only nets driven by memory outputs).
set f [open macro_activity.tsv w]
puts $f "pin\tdirection\ttoggle_per_ns\tsource"
foreach_in_collection p [get_pins -of_objects $macros] {
  set a [get_switching_activity -toggle_rate $p]
  puts $f "[get_object_name $p]\t[get_attribute $p direction]\t[lindex [lindex $a 0] 1]\t[lindex [lindex $a 0] 2]"
}
close $f
# Attribute the full power of cells touching default-source nets. This is
# an explicitly defined cell subtotal, not causal attribution downstream.
set default_cells [get_cells -quiet __no_such_cell__]
foreach a [get_switching_activity -toggle_rate -include_only default [get_nets -hierarchical *]] {
  set ns [get_nets -quiet [list [lindex $a 0]]]
  if {[sizeof_collection $ns]} {
    set ps [get_pins -quiet -of_objects $ns]
    if {[sizeof_collection $ps]} {
      set cs [filter_collection [get_cells -quiet -of_objects $ps] "is_hierarchical==false"]
      set default_cells [add_to_collection -unique $default_cells $cs]
    }
  }
}
set f [open default_cells.tsv w]
puts $f "cell\tinternal_W\tswitching_W\tleakage_W\ttotal_W"
foreach_in_collection c $default_cells { power_row $f [get_object_name $c] $c }
close $f
puts "POWER_DONE default_toggle_rate=$DTR default_touch_cells=[sizeof_collection $default_cells]"
exit
