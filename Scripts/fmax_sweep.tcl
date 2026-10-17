# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# openjls_top fmax across max image width, bit depth and implementation
# strategy, out of context on xczu7eg-fbvb900-1-e with OUT_WIDTH 64. Run via
# run_fmax_sweep.sh; FMAX_SOURCE_DIR selects a frozen RTL snapshot.
# fmax = 1000 / (period - WNS); nonnegative WNS is only a floor.
set OUTDIR [pwd]
set CLKPORT iClk
set OVERCONSTRAIN_NS 3.000 ;# keep tighter than the real fmax
# Concurrent runs, each a ~5-6 GB Vivado process: this knob sets the RAM
set MAX_PARALLEL 3
if {[info exists ::env(FMAX_MAX_PARALLEL)]} { set MAX_PARALLEL $::env(FMAX_MAX_PARALLEL) }
# general.maxThreads; synth and impl are mostly single-threaded
set THREADS_PER_RUN 3
if {[info exists ::env(FMAX_THREADS_PER_RUN)]} { set THREADS_PER_RUN $::env(FMAX_THREADS_PER_RUN) }
# Empty = Default; other directives probe netlist sensitivity
set SYNTH_DIRECTIVE ""
if {[info exists ::env(FMAX_SYNTH_DIRECTIVE)]} { set SYNTH_DIRECTIVE $::env(FMAX_SYNTH_DIRECTIVE) }

set SIZES      {4096 8192 12288 16384 32768 65535}
if {[info exists ::env(FMAX_SIZES)]} { set SIZES $::env(FMAX_SIZES) }
# Every size runs at every bit depth
set BITNESS_LIST {12}
if {[info exists ::env(FMAX_BITNESS)]} { set BITNESS_LIST $::env(FMAX_BITNESS) }
set PERF_STRATEGIES {Performance_ExplorePostRoutePhysOpt Performance_NetDelay_high Congestion_SpreadLogic_high}

# Helpers ---
proc grab {pattern text default} {
  if {[regexp $pattern $text -> m]} { return $m }
  return $default
}

# Private characterization project ---
set ROOT [file normalize [file join [file dirname [info script]] ..]]
set SRC [file join $ROOT Sources]
if {[info exists ::env(FMAX_SOURCE_DIR)]} { set SRC [file normalize $::env(FMAX_SOURCE_DIR)] }
create_project characterization [file join [pwd] project] -part xczu7eg-fbvb900-1-e
set_property target_language VHDL [current_project]
foreach f {olo_base_pkg_array olo_base_pkg_math olo_base_pkg_string olo_base_pkg_logic olo_base_pkg_attribute olo_base_ram_sdp olo_base_fifo_sync} {
    add_files -norecurse [file join $ROOT ThirdParty open-logic src base vhdl $f.vhd]
}
add_files -norecurse [lsort [glob [file join $SRC *.vhd]]]
set_property file_type {VHDL 2008} [get_files *.vhd]
set_property library xil_defaultlib [get_files *.vhd]
set FS [current_fileset]
set_property top openjls_top $FS
set_property generic {OUT_WIDTH=64} $FS ;# BITNESS is set per synth run
update_compile_order -fileset sources_1
set XDC [file join [pwd] clock.xdc]
set fp [open $XDC w]
puts $fp {create_clock -period 3.000 -name iClk [get_ports iClk]}
close $fp
add_files -fileset constrs_1 $XDC
# By name: impl_1 may have been left on another strategy
set STD_STRATEGY "Vivado Implementation Defaults"
puts "INFO: standard/baseline strategy = $STD_STRATEGY"
set STRATEGIES [concat [list $STD_STRATEGY] $PERF_STRATEGIES]

# One synth run per (size, bitness), generics in MORE_OPTIONS since the fileset
# generic is global, and one impl run per strategy under it. launch_runs starts
# each impl as its synth lands. The sw_* runs are deleted on exit.
set SYNTH_FLOW [get_property flow [get_runs synth_1]]
set IMPL_FLOW  [get_property flow [get_runs impl_1]]

# Left by an aborted sweep; impls before their parents
foreach r [get_runs -quiet sw_impl_*]  { catch {delete_runs $r} }
foreach r [get_runs -quiet sw_synth_*] { catch {delete_runs $r} }

array unset RUN_INFO
set ALL_SYNTH {}
set ALL_IMPL  {}
foreach size $SIZES {
 foreach bits $BITNESS_LIST {
  set sr "sw_synth_${size}_${bits}"
  create_run $sr -flow $SYNTH_FLOW -constrset constrs_1
  # -name/-value: the name has a space and the value starts with '-'
  set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
    -value "-mode out_of_context -generic MAX_IMAGE_WIDTH=$size -generic MAX_IMAGE_HEIGHT=$size -generic BITNESS=$bits" \
    -objects [get_runs $sr]
  if {$SYNTH_DIRECTIVE ne ""} {
    set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE $SYNTH_DIRECTIVE [get_runs $sr]
  }
  lappend ALL_SYNTH $sr
  set si 0
  foreach strat $STRATEGIES {
    set ir "sw_impl_${size}_${bits}_${si}"
    create_run $ir -parent_run $sr -flow $IMPL_FLOW -constrset constrs_1
    set_property strategy $strat [get_runs $ir]
    set RUN_INFO($ir) [list $size $bits $strat $sr]
    lappend ALL_IMPL $ir
    incr si
  }
 }
}
puts "INFO: built [llength $ALL_SYNTH] synth + [llength $ALL_IMPL] impl runs (<= $MAX_PARALLEL concurrent, $THREADS_PER_RUN threads each)"

set fp [open $XDC r]; set XDC_ORIG [read $fp]; close $fp
set fp [open $XDC w]
puts $fp "create_clock -period $OVERCONSTRAIN_NS -name $CLKPORT \[get_ports $CLKPORT\]"
close $fp
puts "INFO: clock over-constrained to ${OVERCONSTRAIN_NS} ns for the sweep"

set CSV "$OUTDIR/fmax_sweep.csv"
set ch [open $CSV w]
puts $ch "size,bitness,strategy,period_ns,wns_ns,fmax_mhz,lut,ff,bram,met,status"
close $ch

# Launch and extract, wrapped so the project is always restored ---
set FAILED_POINTS 0
set rc [catch {
  set_param general.maxThreads $THREADS_PER_RUN
  launch_runs {*}$ALL_SYNTH {*}$ALL_IMPL -jobs $MAX_PARALLEL
  foreach r [concat $ALL_SYNTH $ALL_IMPL] { catch {wait_on_run $r} } ;# throws on a failed run; PROGRESS is checked below

  # One CSV row per impl run
  foreach ir $ALL_IMPL {
    lassign $RUN_INFO($ir) size bits strat sr
    puts "---- size $size bitness $bits strategy $strat ($ir) ----"

    if {[get_property PROGRESS [get_runs $sr]] != "100%"} {
      set ch [open $CSV a]
      puts $ch "$size,$bits,$strat,$OVERCONSTRAIN_NS,NA,NA,NA,NA,NA,0,SYNTH_FAIL"
      close $ch
      incr FAILED_POINTS
      puts "WARN: synth failed for size $size bitness $bits"
      continue
    }
    if {[get_property PROGRESS [get_runs $ir]] != "100%"} {
      set ch [open $CSV a]
      puts $ch "$size,$bits,$strat,$OVERCONSTRAIN_NS,NA,NA,NA,NA,NA,0,IMPL_FAIL"
      close $ch
      incr FAILED_POINTS
      puts "WARN: impl failed for size $size / $bits b / $strat"
      continue
    }

    open_run $ir
    set wpath [lindex [get_timing_paths -delay_type max -max_paths 1 -nworst 1] 0]
    set wns   [get_property SLACK $wpath]
    set fmax  [expr {1000.0 / ($OVERCONSTRAIN_NS - $wns)}]
    set met   [expr {$wns >= 0 ? 1 : 0}]

    set tag "${size}_${bits}b_${strat}"
    report_timing -max_paths 20 -file "$OUTDIR/rpt_${tag}_paths.log"
    report_timing_summary -file "$OUTDIR/rpt_${tag}_timing.log" -quiet
    set u [report_utilization -return_string]
    report_utilization -file "$OUTDIR/rpt_${tag}_util.log" -quiet
    set lut  [grab {CLB LUTs\s*\|\s*(\d+)}        $u NA]
    set ff   [grab {CLB Registers\s*\|\s*(\d+)}   $u NA]
    set bram [grab {Block RAM Tile\s*\|\s*([\d.]+)} $u NA]

    set ch [open $CSV a]
    puts $ch "$size,$bits,$strat,$OVERCONSTRAIN_NS,$wns,[format %.2f $fmax],$lut,$ff,$bram,$met,OK"
    close $ch
    puts "RESULT size=$size bitness=$bits strat=$strat wns=$wns fmax=[format %.1f $fmax] MHz met=$met"
    if {$met} {
      puts "WARN: WNS>=0 at ${OVERCONSTRAIN_NS} ns for $size/$bits/$strat -> probe too loose; fmax is a FLOOR. Tighten OVERCONSTRAIN_NS and rerun this point."
    }
    close_design
  }
} err]

# Close ---
puts "INFO: closing characterization project"
catch {close_design}
set fp [open $XDC w]; puts -nonewline $fp $XDC_ORIG; close $fp

# Impls before their parent synths
foreach r [get_runs -quiet sw_impl_*]  { catch {delete_runs $r} }
foreach r [get_runs -quiet sw_synth_*] { catch {delete_runs $r} }

if {$rc} {
  puts "ERROR: sweep aborted: $err"
} else {
  puts "DONE: results in $CSV"
}
close_project
if {$rc || $FAILED_POINTS > 0} { exit 1 }
