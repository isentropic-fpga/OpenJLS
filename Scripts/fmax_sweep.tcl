# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# Characterize openjls_top across maximum image dimensions and implementation
# strategies. Creates an isolated project in the output directory, compiles
# current Sources/*.vhd and open-logic dependencies, and uses xczu7eg-fbvb900-1-e,
# 12-bit pixels, 64-bit output, and out-of-context synthesis.
#
# Run Scripts/run_fmax_sweep.sh with a fresh FMAX_OUTDIR. No private board
# project or packaged-IP copy is used. FMAX_SOURCE_DIR optionally selects a
# frozen RTL snapshot. Other overrides are documented below.
#
# Outputs: fmax_sweep.csv and per-point timing, path, and utilization reports.
# Frequency is estimated as 1000/(period-WNS); nonnegative WNS gives only a
# lower bound. Ports have no external delays; this measures internal timing.
#
set OUTDIR [pwd]
set CLKPORT iClk
set OVERCONSTRAIN_NS 3.000 ;# aggressive probe period; keep tighter than real fmax
# Max runs (synth OR impl) to execute CONCURRENTLY. The sweep launches all synth
# + impl runs as one dependency DAG (each impl waits on its size's synth) and
# Vivado's run scheduler keeps this many jobs busy, pulling the next ready run as
# each finishes — no synth/impl barrier idle. CAUTION: THIS is the knob that
# drives RAM — each concurrent run is a full separate Vivado process (~5-6 GB on
# this device, independent of the per-run thread count), so 4 ~= 24 GB. Needs a
# box with that headroom free; drop it if other apps are using the RAM.
# Override with FMAX_MAX_PARALLEL.
set MAX_PARALLEL 3
if {[info exists ::env(FMAX_MAX_PARALLEL)]} { set MAX_PARALLEL $::env(FMAX_MAX_PARALLEL) }
# Threads each run may use internally (general.maxThreads), global and shared
# since synth and impl overlap. Both are mostly single-threaded here, so a few is
# plenty; CPU is not the binding limit (RAM via MAX_PARALLEL is). Peak threads =
# MAX_PARALLEL x THREADS_PER_RUN (3 x 3 = 9 by default). Override FMAX_THREADS_PER_RUN.
set THREADS_PER_RUN 3
if {[info exists ::env(FMAX_THREADS_PER_RUN)]} { set THREADS_PER_RUN $::env(FMAX_THREADS_PER_RUN) }
# Optional synthesis directive applied to every synth run (e.g. AlternateRoutability,
# PerformanceOptimized, RuntimeOptimized). Empty = the flow default (Default). All
# directives produce functionally identical hardware; a non-default one just yields
# a different netlist, used to probe how netlist changes move fmax. Override with
# FMAX_SYNTH_DIRECTIVE.
set SYNTH_DIRECTIVE ""
if {[info exists ::env(FMAX_SYNTH_DIRECTIVE)]} { set SYNTH_DIRECTIVE $::env(FMAX_SYNTH_DIRECTIVE) }

set SIZES      {4096 8192 12288 16384 32768 65535}
if {[info exists ::env(FMAX_SIZES)]} { set SIZES $::env(FMAX_SIZES) } ;# e.g. FMAX_SIZES="4096 8192" for a quick smoke test
# Compare the default flow with three complementary implementation strategies.
set PERF_STRATEGIES {Performance_ExplorePostRoutePhysOpt Performance_NetDelay_high Congestion_SpreadLogic_high}

# ---- Helpers ----------------------------------------------------------------
proc grab {pattern text default} {
  if {[regexp $pattern $text -> m]} { return $m }
  return $default
}

# ---- Create an isolated characterization project -----------------------------
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
set_property generic {BITNESS=12 OUT_WIDTH=64} $FS
update_compile_order -fileset sources_1
set XDC [file join [pwd] clock.xdc]
set fp [open $XDC w]
puts $fp {create_clock -period 3.000 -name iClk [get_ports iClk]}
close $fp
add_files -fileset constrs_1 $XDC
# Pin the baseline to the real Vivado default BY NAME. Do NOT read it from the
# project: a prior manual session may have left impl_1 on another strategy
# (e.g. Performance_Explore), which would silently replace the "standard" line.
set STD_STRATEGY "Vivado Implementation Defaults"
puts "INFO: standard/baseline strategy = $STD_STRATEGY"
set STRATEGIES [concat [list $STD_STRATEGY] $PERF_STRATEGIES]

# Build the run DAG: one synth run per size (each carrying its own generic via
# STEPS.SYNTH_DESIGN.ARGS.MORE_OPTIONS, since the fileset generic is global and
# can't differ per run) + one impl run per (size, strategy) parented to its
# size's synth. launch_runs then schedules the whole graph as a pool: synths
# first, each size's impls the moment its synth lands. All runs are sweep-private
# (sw_*) and deleted on exit, so the project's own synth_1/impl_1 are untouched.
set SYNTH_FLOW [get_property flow [get_runs synth_1]]
set IMPL_FLOW  [get_property flow [get_runs impl_1]]

# Clear sw_* runs left by an aborted previous sweep (impls before their parents).
foreach r [get_runs -quiet sw_impl_*]  { catch {delete_runs $r} }
foreach r [get_runs -quiet sw_synth_*] { catch {delete_runs $r} }

array unset RUN_INFO
set ALL_SYNTH {}
set ALL_IMPL  {}
foreach size $SIZES {
  set sr "sw_synth_$size"
  create_run $sr -flow $SYNTH_FLOW -constrset constrs_1
  # -name/-value form: the property name contains a space, and the value starts
  # with '-' (which the positional set_property would misread as an option).
  set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
    -value "-mode out_of_context -generic MAX_IMAGE_WIDTH=$size -generic MAX_IMAGE_HEIGHT=$size" \
    -objects [get_runs $sr]
  if {$SYNTH_DIRECTIVE ne ""} {
    set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE $SYNTH_DIRECTIVE [get_runs $sr]
  }
  lappend ALL_SYNTH $sr
  set si 0
  foreach strat $STRATEGIES {
    set ir "sw_impl_${size}_${si}"
    create_run $ir -parent_run $sr -flow $IMPL_FLOW -constrset constrs_1
    set_property strategy $strat [get_runs $ir]
    set RUN_INFO($ir) [list $size $strat $sr]
    lappend ALL_IMPL $ir
    incr si
  }
}
puts "INFO: built [llength $ALL_SYNTH] synth + [llength $ALL_IMPL] impl runs (<= $MAX_PARALLEL concurrent, $THREADS_PER_RUN threads each)"

# Apply the sweep clock to the private project.
set fp [open $XDC r]; set XDC_ORIG [read $fp]; close $fp
set fp [open $XDC w]
puts $fp "create_clock -period $OVERCONSTRAIN_NS -name $CLKPORT \[get_ports $CLKPORT\]"
close $fp
puts "INFO: clock over-constrained to ${OVERCONSTRAIN_NS} ns for the sweep"

# CSV header
set CSV "$OUTDIR/fmax_sweep.csv"
set ch [open $CSV w]
puts $ch "size,strategy,period_ns,wns_ns,fmax_mhz,lut,ff,bram,met,status"
close $ch

# ---- Launch the whole DAG, then extract (wrapped so we always restore state) -
set FAILED_POINTS 0
set rc [catch {
  set_param general.maxThreads $THREADS_PER_RUN
  # One launch over every run: Vivado runs the synths, then each impl as its
  # parent synth completes, keeping MAX_PARALLEL jobs busy from the ready queue.
  launch_runs {*}$ALL_SYNTH {*}$ALL_IMPL -jobs $MAX_PARALLEL
  foreach r [concat $ALL_SYNTH $ALL_IMPL] { catch {wait_on_run $r} } ;# THROWS on a failed run; swallow and inspect PROGRESS below

  # ---- One CSV row per impl run --------------------------------------------
  foreach ir $ALL_IMPL {
    lassign $RUN_INFO($ir) size strat sr
    puts "---- size $size strategy $strat ($ir) ----"

    if {[get_property PROGRESS [get_runs $sr]] != "100%"} {
      set ch [open $CSV a]
      puts $ch "$size,$strat,$OVERCONSTRAIN_NS,NA,NA,NA,NA,NA,0,SYNTH_FAIL"
      close $ch
      incr FAILED_POINTS
      puts "WARN: synth failed for size $size"
      continue
    }
    if {[get_property PROGRESS [get_runs $ir]] != "100%"} {
      set ch [open $CSV a]
      puts $ch "$size,$strat,$OVERCONSTRAIN_NS,NA,NA,NA,NA,NA,0,IMPL_FAIL"
      close $ch
      incr FAILED_POINTS
      puts "WARN: impl failed for size $size / $strat"
      continue
    }

    open_run $ir
    set wpath [lindex [get_timing_paths -delay_type max -max_paths 1 -nworst 1] 0]
    set wns   [get_property SLACK $wpath]
    set fmax  [expr {1000.0 / ($OVERCONSTRAIN_NS - $wns)}]
    set met   [expr {$wns >= 0 ? 1 : 0}]

    set tag "${size}_${strat}"
    report_timing -max_paths 20 -file "$OUTDIR/rpt_${tag}_paths.log"
    report_timing_summary -file "$OUTDIR/rpt_${tag}_timing.log" -quiet
    set u [report_utilization -return_string]
    report_utilization -file "$OUTDIR/rpt_${tag}_util.log" -quiet
    set lut  [grab {CLB LUTs\s*\|\s*(\d+)}        $u NA]
    set ff   [grab {CLB Registers\s*\|\s*(\d+)}   $u NA]
    set bram [grab {Block RAM Tile\s*\|\s*([\d.]+)} $u NA]

    set ch [open $CSV a]
    puts $ch "$size,$strat,$OVERCONSTRAIN_NS,$wns,[format %.2f $fmax],$lut,$ff,$bram,$met,OK"
    close $ch
    puts "RESULT size=$size strat=$strat wns=$wns fmax=[format %.1f $fmax] MHz met=$met"
    if {$met} {
      puts "WARN: WNS>=0 at ${OVERCONSTRAIN_NS} ns for $size/$strat -> probe too loose; fmax is a FLOOR. Tighten OVERCONSTRAIN_NS and rerun this point."
    }
    close_design
  }
} err]

# ---- Close the private project ----------------------------------------------
puts "INFO: closing characterization project"
catch {close_design}
set fp [open $XDC w]; puts -nonewline $fp $XDC_ORIG; close $fp

# Drop the sweep-private runs (impls before their parent synths); the project's
# own synth_1/impl_1 were never touched.
foreach r [get_runs -quiet sw_impl_*]  { catch {delete_runs $r} }
foreach r [get_runs -quiet sw_synth_*] { catch {delete_runs $r} }

if {$rc} {
  puts "ERROR: sweep aborted: $err"
} else {
  puts "DONE: results in $CSV"
}
close_project
if {$rc || $FAILED_POINTS > 0} { exit 1 }
