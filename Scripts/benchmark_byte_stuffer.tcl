# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Out-of-context timing of a byte_stuffer variant, alone or inside openjls_top
# (12-bit, 4096 x 4096). Run each experiment from its own output directory:
#   vivado -mode batch -source Scripts/benchmark_byte_stuffer.tcl \
#     -tclargs <byte_stuffer.vhd> byte_stuffer|openjls_top <width> <period_ns> [sources_dir]
# Overconstrain: nonnegative WNS is only a floor.

set ROOT [file normalize [file join [file dirname [info script]] ..]]
set STUFFER [file normalize [lindex $argv 0]]
set TOP [lindex $argv 1]
set WIDTH [lindex $argv 2]
set PERIOD [lindex $argv 3]
set SRC [file join $ROOT Sources]
if {[llength $argv] > 4} {
    set SRC [file normalize [lindex $argv 4]]
}
if {$TOP ni {byte_stuffer openjls_top} || ![file exists $STUFFER] ||
    ![string is integer -strict $WIDTH] || ![string is double -strict $PERIOD]} {
    error "Arguments: byte_stuffer.vhd {byte_stuffer|openjls_top} input_width period_ns"
}
set_param general.maxThreads 4
foreach f {
    olo_base_pkg_array olo_base_pkg_math olo_base_pkg_string
    olo_base_pkg_logic olo_base_pkg_attribute olo_base_ram_sdp olo_base_fifo_sync
} {
    read_vhdl -vhdl2008 [file join $ROOT ThirdParty open-logic src base vhdl $f.vhd]
}
read_vhdl -vhdl2008 [file join $SRC openjls_pkg.vhd]
if {$TOP eq "openjls_top"} {
    foreach f [lsort [glob [file join $SRC *.vhd]]] {
        if {[file tail $f] ni {openjls_pkg.vhd byte_stuffer.vhd}} {
            read_vhdl -vhdl2008 $f
        }
    }
}
read_vhdl -vhdl2008 $STUFFER
set fp [open clock.xdc w]
puts $fp "create_clock -period $PERIOD -name iClk \[get_ports iClk\]"
close $fp
read_xdc clock.xdc
set generics [list IN_WIDTH=$WIDTH]
if {$TOP eq "openjls_top"} {
    set generics {BITNESS=12 MAX_IMAGE_WIDTH=4096 MAX_IMAGE_HEIGHT=4096 OUT_WIDTH=64}
}
synth_design -top $TOP -part xczu7eg-fbvb900-1-e -mode out_of_context -generic $generics
report_utilization -file synth_util.rpt
report_timing_summary -file synth_timing.rpt
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -file routed_timing.rpt
report_timing -max_paths 20 -input_pins -file routed_paths.rpt
report_utilization -file routed_util.rpt
write_checkpoint -force routed.dcp
set worst [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
set slack [get_property SLACK $worst]
set fp [open result.txt w]
puts $fp "top=$TOP width=$WIDTH period_ns=$PERIOD wns_ns=$slack estimated_fmax_mhz=[expr {1000.0 / ($PERIOD - $slack)}]"
puts $fp "startpoint=[get_property STARTPOINT_PIN $worst] endpoint=[get_property ENDPOINT_PIN $worst]"
close $fp
