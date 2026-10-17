# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Regenerate the openjls_top, openjls_axis and openjls_axis_regs IP cores in
# Sources/Xilinx/ip_repo, which is committed. Run via run_package_ip.sh after
# RTL or interface changes.

set script_dir [file dirname [file normalize [info script]]]
set repo_dir   [file normalize [file join $script_dir ..]]
set ip_repo    [file join $repo_dir Sources Xilinx ip_repo]
set work_root  [file join [pwd] ip_pkg]

set vendor   isentropic
set library  openjls
set version  1.3
set repo_url https://github.com/isentropic-fpga/OpenJLS

# Only a packaging vehicle; level_2 family support below opens all families
set part xc7z020clg400-1

# name -> {axi_files display_name description}
set ips {
  openjls_top {
    {}
    {OpenJLS Encoder (Native)}
    {JPEG-LS (ITU-T T.87) lossless image encoder, native interface: FIFO-style ready/valid handshakes plus sideband iImageWidth/iImageHeight ports sampled while iRst is high.}
  }
  openjls_axis {
    {openjls_axis.vhd}
    {OpenJLS Encoder (AXI4-Stream)}
    {JPEG-LS (ITU-T T.87) lossless image encoder with AXI4-Stream pixel input and encoded .jls output. Image dimensions are sideband ports (iImageWidth/iImageHeight) sampled while iRst is high.}
  }
  openjls_axis_regs {
    {openjls_axis.vhd openjls_axis_regs.vhd}
    {OpenJLS Encoder (AXI4-Stream + AXI4-Lite)}
    {JPEG-LS (ITU-T T.87) lossless image encoder with AXI4-Stream pixel input, encoded .jls output, and an AXI4-Lite register bank for dimension configuration, soft reset and status.}
  }
}

proc add_openjls_sources {repo_dir axi_files} {
    set files [glob [file join $repo_dir Sources *.vhd]]
    foreach f $axi_files {
        lappend files [file join $repo_dir Sources Xilinx $f]
    }
    add_files -fileset sources_1 $files
    set_property FILE_TYPE {VHDL 2008} [get_files $files]
    source [file join $repo_dir Scripts create_libraries_vivado.tcl]
}

proc set_range {core pname lo hi} {
    foreach p [ipx::get_user_parameters $pname -of_objects $core] {
        set_property value_validation_type          range_long $p
        set_property value_validation_range_minimum $lo        $p
        set_property value_validation_range_maximum $hi        $p
    }
}

file delete -force $ip_repo
file delete -force $work_root

foreach {name meta} $ips {
    lassign $meta axi_files display desc
    puts "==== Packaging $name ===="

    create_project -force pkg_$name [file join $work_root $name] -part $part
    add_openjls_sources $repo_dir $axi_files
    set_property top $name [current_fileset]
    update_compile_order -fileset sources_1

    ipx::package_project -root_dir [file join $ip_repo $name] \
        -vendor $vendor -library $library -taxonomy /Video_and_Image_Processing \
        -import_files -force
    set core [ipx::current_core]

    set_property name         $name     $core
    set_property version      $version  $core
    # yymmddHH, so block designs see a repackage as newer; fits a signed int32
    set_property core_revision [clock format [clock seconds] -format %y%m%d%H] $core
    set_property display_name $display  $core
    set_property description  $desc     $core
    set_property company_url  $repo_url $core
    set_property vendor_display_name "Isentropic" $core
    set_property auto_family_support_level level_2 $core

    # Parameters, ranges as in the VHDL ---
    set_range $core BITNESS          8  16
    set_range $core MAX_IMAGE_WIDTH  4  65535
    set_range $core MAX_IMAGE_HEIGHT 1  65535
    set_range $core OUT_WIDTH        48 1024

    # The packager can carry CO_OUT_WIDTH_STD through unresolved
    foreach p [ipx::get_user_parameters OUT_WIDTH -of_objects $core] {
        set_property value 64 $p
    }
    foreach p [ipx::get_hdl_parameters OUT_WIDTH -of_objects $core] {
        set_property value 64 $p
    }
    # Every default must be a literal integer; Component_Name is Vivado's
    foreach p [ipx::get_user_parameters -of_objects $core] {
        if {[get_property name $p] eq "Component_Name"} { continue }
        set v [get_property value $p]
        if {![string is integer -strict $v]} {
            error "$name: parameter [get_property name $p] default '$v' is not a literal integer"
        }
    }

    # Bus interfaces ---
    if {$name eq "openjls_top"} {
        # Only clock and reset; drop whatever was inferred and re-add them
        foreach bif [ipx::get_bus_interfaces -of_objects $core] {
            ipx::remove_bus_interface [get_property NAME $bif] $core
        }
        ipx::infer_bus_interface iClk xilinx.com:signal:clock_rtl:1.0 $core
        ipx::infer_bus_interface iRst xilinx.com:signal:reset_rtl:1.0 $core
        set rstif [ipx::get_bus_interfaces iRst -of_objects $core]
        if {[ipx::get_bus_parameters POLARITY -of_objects $rstif] eq ""} {
            ipx::add_bus_parameter POLARITY $rstif
        }
        set_property value ACTIVE_HIGH \
            [ipx::get_bus_parameters POLARITY -of_objects $rstif]
        ipx::associate_bus_interfaces -clock iClk -reset iRst $core
    } else {
        # Inferred from the x_interface_* attributes; verify only
        foreach bif {s_axis_pixel m_axis_jls} {
            if {[ipx::get_bus_interfaces $bif -of_objects $core] eq ""} {
                error "$name: bus interface $bif was not inferred"
            }
        }
        if {$name eq "openjls_axis"} {
            set clk iClk
        } else {
            set clk aclk
        }
        ipx::associate_bus_interfaces -busif s_axis_pixel -clock $clk $core
        ipx::associate_bus_interfaces -busif m_axis_jls   -clock $clk $core
    }

    if {$name eq "openjls_axis_regs"} {
        set bif [ipx::get_bus_interfaces s_axi_ctrl -of_objects $core]
        if {$bif eq ""} {
            error "$name: bus interface s_axi_ctrl was not inferred"
        }
        set rstif [ipx::get_bus_interfaces aresetn -of_objects $core]
        if {$rstif ne ""} {
            set pol [ipx::get_bus_parameters POLARITY -of_objects $rstif]
            if {$pol ne "" && [get_property value $pol] ne "ACTIVE_LOW"} {
                error "$name: aresetn polarity is not ACTIVE_LOW"
            }
        }
        # 256 B block over the 8-bit address space
        if {[ipx::get_memory_maps s_axi_ctrl -of_objects $core] eq ""} {
            set mmap [ipx::add_memory_map s_axi_ctrl $core]
            set_property slave_memory_map_ref s_axi_ctrl $bif
            set ablk [ipx::add_address_block reg0 $mmap]
            set_property range 256      $ablk
            set_property width 32       $ablk
            set_property usage register $ablk
        }
        ipx::associate_bus_interfaces -busif s_axi_ctrl -clock aclk $core
    }

    # Logo ---
    # Copied into the core so the reference stays relative; 64x64 as stock IP
    set logo_src [file join $repo_dir Docs Images isentropic-icon-64.png]
    set logo_rel [file join misc isentropic-icon-64.png]
    file mkdir [file join $ip_repo $name misc]
    file copy -force $logo_src [file join $ip_repo $name $logo_rel]
    ipx::add_file_group -type utility {} $core
    set logo_grp  [ipx::get_file_groups xilinx_utilityxitfiles -of_objects $core]
    set logo_file [ipx::add_file $logo_rel $logo_grp]
    set_property type image $logo_file
    set_property type LOGO  $logo_file

    # Finalize ---
    ipx::create_xgui_files $core
    ipx::update_checksums  $core
    if {[catch {ipx::check_integrity $core} err]} {
        error "$name: check_integrity failed: $err"
    }
    ipx::save_core $core
    close_project

    puts "==== Packaged $name -> [file join $ip_repo $name] ===="
}

puts "All cores packaged into $ip_repo"
