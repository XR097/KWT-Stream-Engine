# DC synthesis of kse_top (R=32, C=32) for SMIC40LL, RVT tt_typical_max 1.10 V 25 C,
# RAMSP1024X16 tt 1.10 V 25 C, 150 MHz.
# Run from an output directory outside the repository:
#   KSE_REPO=<repo> dc_shell -no_home_init -f <repo>/tools/kse/synth_kse.tcl > dc.log 2>&1
set REPO $env(KSE_REPO)
set RTL  $REPO/rtl/kse
set CLK_PERIOD 6.667
if {[info exists env(KSE_CLK)]} { set CLK_PERIOD $env(KSE_CLK) }

set STD_DB $env(SMIC40_STDCELL_DB)
set RAM_DB $env(SMIC40_RAM1024_DB)
set RAM128_DB $env(SMIC40_RAM128_DB)
set_app_var target_library [list $STD_DB]
set_app_var link_library   [list * $STD_DB $RAM_DB $RAM128_DB]
set_host_options -max_cores 2
set_app_var report_default_significant_digits 9
set_app_var hdlin_check_no_latch true

define_design_lib WORK -path ./work
analyze -format sverilog -define ARM_UD_MODEL [list \
  $RTL/kse_pkg.sv $RTL/kse_arith.sv $RTL/kse_exp_rom.sv $RTL/kse_gelu_rom.sv $RTL/kse_post.sv \
  $RTL/kse_softmax.sv $RTL/kse_ln.sv $RTL/kse_mac_array.sv $RTL/kse_rowstore.sv $RTL/kse_pfifo.sv $RTL/kse_loader.sv \
  $RTL/kse_mm.sv $RTL/kse_pass.sv $RTL/kse_top.sv]
elaborate kse_top
current_design kse_top
link
redirect check_design_pre.rpt {check_design}

create_clock -name clk -period $CLK_PERIOD [get_ports clk]
# Optimize with 10 ps extra margin; report/export the required 0.1 ns.
set_clock_uncertainty 0.11 [get_clocks clk]
set inputs [remove_from_collection [all_inputs] [get_ports {clk}]]
set_input_delay  [expr 0.2 * $CLK_PERIOD] -clock clk $inputs
set_output_delay [expr 0.2 * $CLK_PERIOD] -clock clk [all_outputs]
set_input_transition 0.1 $inputs
set_load 0.005 [all_outputs]
set_false_path -from [get_ports rst_n]
# RAMSP1024X16 inputs have a hold requirement; let DC insert delay where needed
set_fix_hold [get_clocks clk]

# keep the module hierarchy so that the area can be broken down per unit
compile_ultra -no_autoungroup
# compile_ultra does not insert hold buffers by itself here; fix the SRAM input
# hold requirement (0.22 ns + uncertainty) with an incremental hold-only pass
compile -incremental_mapping -only_hold_time
set_clock_uncertainty 0.1 [get_clocks clk]

redirect area.rpt            {report_area}
redirect area_hier.rpt       {report_area -hierarchy -nosplit}
redirect timing.rpt          {report_timing -delay_type max -max_paths 20 -nosplit -input_pins -nets}
redirect timing_hold.rpt     {report_timing -delay_type min -max_paths 5 -nosplit}
redirect qor.rpt             {report_qor}
redirect constraints.rpt     {report_constraint -all_violators -nosplit}
redirect check_design.rpt    {check_design}
redirect refs.rpt            {report_reference -nosplit}
redirect power.rpt           {report_power}

set paths [get_timing_paths -delay_type max -max_paths 1]
set slack [get_attribute $paths slack]
set ram_cells [get_cells -hierarchical -filter "ref_name =~ RAMSP*"]
set f [open metrics.txt w]
puts $f "clk_period_ns=$CLK_PERIOD"
puts $f "optimization_uncertainty_ns=0.11"
puts $f "reported_uncertainty_ns=0.1"
puts $f "wns_ns=$slack"
set hp [get_timing_paths -delay_type min -max_paths 1]
puts $f "hold_slack_ns=[get_attribute $hp slack]"
puts $f "total_area_um2=[get_attribute [current_design] area]"
puts $f "ram_count=[sizeof_collection $ram_cells]"
puts $f "ff_count=[sizeof_collection [all_registers -edge_triggered]]"
puts $f "latch_count=[sizeof_collection [all_registers -level_sensitive]]"
close $f
write -format ddc -hierarchy -output kse_top_mapped.ddc
write -format verilog -hierarchy -output kse_top_mapped.v
write_sdc kse_top_mapped.sdc
puts "SYN_DONE"
exit
