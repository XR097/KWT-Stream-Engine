# Shared DC setup and strict design checks for the KSE SoC synthesis scripts.
# Library / corner (recorded in the reports):
#   std cells: SMIC40LL sc9mc base RVT, tt_typical_max 1.10 V 25 C
#   macros   : RAMSP4096X16 / RAMSP1024X16 / RAMSP128X16 tt 1.10 V 25 C (.db from the PDK memory dirs)
set STD_DB $env(SMIC40_STDCELL_DB)
set RAM4K_DB $env(SMIC40_RAM4096_DB)
set RAM1K_DB $env(SMIC40_RAM1024_DB)
set RAM128_DB $env(SMIC40_RAM128_DB)
set_app_var target_library [list $STD_DB]
set_app_var link_library   [list * $STD_DB $RAM4K_DB $RAM1K_DB $RAM128_DB]
set_app_var hdlin_check_no_latch true

proc kse_fail {msg} {
  puts "SYN_FAIL: $msg"
  exit 1
}

# analyze a list of files (format chosen by extension), failing on any error
proc kse_analyze {files defines} {
  foreach f $files {
    set fmt [expr {[string match *.sv $f] ? "sverilog" : "verilog"}]
    if {![analyze -format $fmt -library WORK -define $defines $f]} { kse_fail "analyze $f" }
  }
}

# elaborate + link; fail on unresolved references other than the allowed
# black boxes, and on check_design reporting unresolved/black-box cells
proc kse_elab_link {top params allowed tag} {
  if {$params ne ""} {
    if {![elaborate $top -library WORK -parameters $params]} { kse_fail "elaborate $top" }
    rename_design [get_designs ${top}_*] $top
  } else {
    if {![elaborate $top -library WORK]} { kse_fail "elaborate $top" }
  }
  current_design $top
  redirect -variable link_log { set ok [link] }
  puts $link_log
  set bad {}
  set unresolved {}
  foreach line [split $link_log "\n"] {
    if {[regexp {Unable to resolve reference '([^']+)'} $line -> ref]} {
      lappend unresolved $ref
      if {[lsearch -exact $allowed $ref] < 0 && [lsearch -exact $bad $ref] < 0} { lappend bad $ref }
    }
  }
  # link returns 0 when anything is unresolved; accept that only if every
  # unresolved reference is explicitly allowed
  if {!$ok && [llength $unresolved] == 0} { kse_fail "link $top" }
  redirect check_design_pre_$tag.rpt {check_design -summary}
  redirect -append check_design_pre_$tag.rpt {check_design}
  # every unresolved reference must be explicitly allowed
  set fh [open check_design_pre_$tag.rpt r]; set cd [read $fh]; close $fh
  foreach line [split $cd "\n"] {
    if {[regexp {reference '([^']+)'.*unresolved|unresolved.*'([^']+)'} $line -> r1 r2]} {
      set ref [expr {$r1 ne "" ? $r1 : $r2}]
      if {$ref ne "" && [lsearch -exact $allowed $ref] < 0 && [lsearch -exact $bad $ref] < 0} { lappend bad $ref }
    }
  }
  if {[llength $bad] > 0} { kse_fail "$tag: unresolved/black-box references not allowed: $bad" }
  puts "LINK_CHECK_OK $tag allowed_black_boxes=\{$allowed\}"
}
