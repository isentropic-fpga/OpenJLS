# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Smoke test of the packaged IP: create_ip each core from ip_repo with
# non-default generics and synthesize it OOC. Run via run_package_ip.sh --verify.

set script_dir [file dirname [file normalize [info script]]]
set repo_dir   [file normalize [file join $script_dir ..]]
set ip_repo    [file join $repo_dir Sources Xilinx ip_repo]

set part xc7z020clg400-1

create_project -force ip_smoke [file join [pwd] ip_smoke] -part $part
set_property ip_repo_paths $ip_repo [current_project]
update_ip_catalog

# Non-default on every generic, so a broken width expression or default fails
set common {
    CONFIG.BITNESS          16
    CONFIG.MAX_IMAGE_WIDTH  1920
    CONFIG.MAX_IMAGE_HEIGHT 1080
    CONFIG.OUT_WIDTH        48
}

set cores {
    openjls_top       {}
    openjls_axis      {}
    openjls_axis_regs {}
}

set ip_insts {}
foreach {name extra} $cores {
    set vlnv isentropic:openjls:${name}:*
    puts "==== create_ip $vlnv ===="
    create_ip -vlnv $vlnv -module_name smoke_$name
    # create_ip may return the .xci; CONFIG.* needs the IP object
    set inst [get_ips smoke_$name]
    set_property -dict [concat $common $extra] $inst
    if {[get_property CONFIG.OUT_WIDTH $inst] != 48} {
        error "$name: CONFIG.OUT_WIDTH did not apply"
    }
    generate_target {synthesis} $inst
    create_ip_run $inst
    lappend ip_insts $inst
}

set runs [get_runs smoke_*_synth_1]
launch_runs $runs
foreach r $runs {
    wait_on_run $r
    if {[get_property PROGRESS $r] ne "100%"} {
        error "$r failed: [get_property STATUS $r]"
    }
}

puts "IP smoke test passed: [llength $ip_insts] cores synthesized OOC"
close_project
