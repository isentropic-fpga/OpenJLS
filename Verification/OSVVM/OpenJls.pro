# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# OpenJLS OSVVM regression, the single source of the file list. Run via
# ./build_reports.sh or ./build_run.sh.

# --relaxed: unprotected shared variables in open-logic and the TBs.
# --stderr=error: tcl exec fails on any stderr, so analysis must be warning-clean.
# --psl needs --exit-severity=error, or a violated contract still exits 0.
set ::osvvm::ExtendedGlobalOptions {--stderr=error}
SetExtendedAnalyzeOptions {--relaxed --psl}
SetExtendedRunOptions     {--ieee-warnings=off --exit-severity=error}

# CODE_COVERAGE=1 (build_run.sh): one --cover-file per test, set by Test below
set ::OpenJlsCodeCoverage [info exists ::env(CODE_COVERAGE)]
if {$::OpenJlsCodeCoverage} {
  SetCoverageSimulateEnable true
  file mkdir NVC_CodeCoverage
  # Instrument only the Sources/ entities
  set specfd [open NVC_CodeCoverage/dut_only.spec w]
  puts $specfd "-hierarchy *"
  foreach src [concat [lsort [glob ../../Sources/*.vhd]] [lsort [glob ../../Sources/Xilinx/*.vhd]]] {
    set ent [file rootname [file tail $src]]
    if {$ent ne "openjls_pkg"} { puts $specfd "+block $ent" }
    # A generate is its own scope and +block takes no globs, so list every
    # generate label or its statements go uninstrumented
    set fd [open $src r]
    set body [read $fd]
    close $fd
    foreach {full lbl} [regexp -all -inline -line {^\s*(\w+)\s*:\s*(?:for|if)\y.*\ygenerate\y} $body] {
      puts $specfd "+block $lbl"
    }
  }
  close $specfd
}
proc Test {TestFile args} {
  if {$::OpenJlsCodeCoverage} {
    # Keeps [generic ...] variants from sharing a .covdb
    set tn [file rootname [file tail $TestFile]]$::osvvm::GenericNames
    SetCoverageSimulateOptions [list --cover=statement,branch --cover-spec=NVC_CodeCoverage/dut_only.spec --cover-file=NVC_CodeCoverage/$tn.covdb]
  }
  RunTest $TestFile {*}$args
}

# open-logic, in the openjls library since the RTL uses work.olo_*
library openjls
analyze ../../ThirdParty/open-logic/src/base/vhdl/olo_base_pkg_array.vhd
analyze ../../ThirdParty/open-logic/src/base/vhdl/olo_base_pkg_math.vhd
analyze ../../ThirdParty/open-logic/src/base/vhdl/olo_base_pkg_string.vhd
analyze ../../ThirdParty/open-logic/src/base/vhdl/olo_base_pkg_logic.vhd
analyze ../../ThirdParty/open-logic/src/base/vhdl/olo_base_pkg_attribute.vhd
analyze ../../ThirdParty/open-logic/src/base/vhdl/olo_base_ram_sdp.vhd
analyze ../../ThirdParty/open-logic/src/base/vhdl/olo_base_fifo_sync.vhd

# Salt for TB random seeds, see run_seed in tb_support_pkg
set rtlDir [file normalize [file join [file dirname [info script]] ../../Sources]]
set seedFile [open run_seed.txt w]
puts $seedFile [lindex [exec sh -c "cat $rtlDir/*.vhd $rtlDir/Xilinx/*.vhd | sha256sum"] 0]
close $seedFile

library tb_support
analyze Support/tb_support_pkg.vhd

library openjls
analyze ../../Sources/openjls_pkg.vhd
analyze ../../Sources/A1_gradient_comp.vhd
analyze ../../Sources/A3_mode_selection.vhd
analyze ../../Sources/A4_quantization_gradients.vhd
analyze ../../Sources/A4_1_quant_gradient_merging.vhd
analyze ../../Sources/A4_2_Q_mapping.vhd
analyze ../../Sources/A5_edge_detecting_predictor.vhd
analyze ../../Sources/A6_A7_prediction_error.vhd
analyze ../../Sources/A8_1_reconstructed_value.vhd
analyze ../../Sources/A9_modulo_reduction.vhd
analyze ../../Sources/A10_compute_k.vhd
analyze ../../Sources/A11_error_mapping.vhd
analyze ../../Sources/A11_1_golomb_encoder.vhd
analyze ../../Sources/A11_2_bit_packer.vhd
analyze ../../Sources/A12_A13_update.vhd
analyze ../../Sources/A14_run_length_determination.vhd
analyze ../../Sources/A15_A16_encode_run.vhd
analyze ../../Sources/A17_run_interruption_index.vhd
analyze ../../Sources/A18_run_interruption_prediction_error.vhd
analyze ../../Sources/A19_run_interruption_error.vhd
analyze ../../Sources/A20_1_run_context_index.vhd
analyze ../../Sources/A20_2_compute_k.vhd
analyze ../../Sources/A21_compute_map.vhd
analyze ../../Sources/A22_errval_mapping.vhd
analyze ../../Sources/A23_run_interruption_update.vhd
analyze ../../Sources/line_buffer.vhd
analyze ../../Sources/context_ram.vhd
analyze ../../Sources/byte_stuffer.vhd
analyze ../../Sources/jls_framer.vhd
analyze ../../Sources/openjls_top.vhd
analyze ../../Sources/Xilinx/openjls_axis.vhd
analyze ../../Sources/Xilinx/openjls_axis_regs.vhd

TestSuite Modules
Test Modules/tb_a1_osvvm.vhd
Test Modules/tb_a3_osvvm.vhd
Test Modules/tb_a4_osvvm.vhd
# Only MAXVAL below about 21 reaches the threshold CLAMP
Test Modules/tb_a4_osvvm.vhd [generic BITNESS 8] [generic MAX_VAL 2]
Test Modules/tb_a4_osvvm.vhd [generic BITNESS 8] [generic MAX_VAL 3]
Test Modules/tb_a4_osvvm.vhd [generic BITNESS 8] [generic MAX_VAL 6]
Test Modules/tb_a4_osvvm.vhd [generic BITNESS 8] [generic MAX_VAL 20]
Test Modules/tb_a4_1_osvvm.vhd
Test Modules/tb_a4_2_osvvm.vhd
Test Modules/tb_a5_osvvm.vhd
Test Modules/tb_a6_a7_osvvm.vhd
Test Modules/tb_a6_a7_osvvm.vhd [generic BITNESS 8] [generic MAX_VAL 200]
# Non-binary MAXVAL above the Cq width takes the general compare; 4094 is one short of binary
Test Modules/tb_a6_a7_osvvm.vhd [generic BITNESS 12] [generic MAX_VAL 3000]
Test Modules/tb_a6_a7_osvvm.vhd [generic BITNESS 12] [generic MAX_VAL 4094]
Test Modules/tb_a6_a7_osvvm.vhd [generic BITNESS 16] [generic MAX_VAL 40000]
Test Modules/tb_a6_a7_osvvm.vhd [generic BITNESS 8] [generic CQ_OFFSET 1]
Test Modules/tb_a6_a7_osvvm.vhd [generic BITNESS 12] [generic CQ_OFFSET -1]
Test Modules/tb_a8_1_osvvm.vhd
Test Modules/tb_a9_osvvm.vhd
# Binary-range shortcut at every width
foreach bitness {8 9 10 11 13 14 15 16} {
  Test Modules/tb_a9_osvvm.vhd [generic BITNESS $bitness]
}
# Ranges either side of a power of two take the arithmetic fallback
Test Modules/tb_a9_osvvm.vhd [generic BITNESS 8] [generic RANGE_P 255]
Test Modules/tb_a9_osvvm.vhd [generic BITNESS 8] [generic RANGE_P 257]
Test Modules/tb_a9_osvvm.vhd [generic BITNESS 12] [generic RANGE_P 4095]
Test Modules/tb_a9_osvvm.vhd [generic BITNESS 12] [generic RANGE_P 4097]
# Even ranges split (RANGE + 1) / 2 from (RANGE + 2) / 2
Test Modules/tb_a9_osvvm.vhd [generic BITNESS 8] [generic RANGE_P 254]
Test Modules/tb_a9_osvvm.vhd [generic BITNESS 12] [generic RANGE_P 4094]
Test Modules/tb_a10_osvvm.vhd
Test Modules/tb_a11_osvvm.vhd
Test Modules/tb_a11_1_osvvm.vhd
Test Modules/tb_a11_2_osvvm.vhd
Test Modules/tb_a12_a13_osvvm.vhd
Test Modules/tb_a14_osvvm.vhd
Test Modules/tb_a15_a16_osvvm.vhd
# RUN_CNT_WIDTH the top derives from MAX_W 4096 and 128
Test Modules/tb_a15_a16_osvvm.vhd [generic RC_W 13]
Test Modules/tb_a15_a16_osvvm.vhd [generic RC_W 8]
Test Modules/tb_a17_osvvm.vhd
Test Modules/tb_a18_osvvm.vhd
Test Modules/tb_a19_osvvm.vhd
Test Modules/tb_a19_osvvm.vhd [generic BITNESS 8] [generic RANGE_P 254]
Test Modules/tb_a19_osvvm.vhd [generic BITNESS 8] [generic RANGE_P 255]
Test Modules/tb_a19_osvvm.vhd [generic BITNESS 12] [generic RANGE_P 4097]
Test Modules/tb_a20_1_osvvm.vhd
Test Modules/tb_a20_2_osvvm.vhd
Test Modules/tb_a21_osvvm.vhd
Test Modules/tb_a22_osvvm.vhd
Test Modules/tb_a23_osvvm.vhd
Test Modules/tb_line_buffer_osvvm.vhd
Test Modules/tb_context_ram_osvvm.vhd
Test Modules/tb_byte_stuffer_osvvm.vhd
# IN_WIDTH = LIMIT at BITNESS 8 and 16
Test Modules/tb_byte_stuffer_osvvm.vhd [generic IN_WIDTH 32]
Test Modules/tb_byte_stuffer_osvvm.vhd [generic IN_WIDTH 64]
# The other LIMIT values the top builds: IN_WIDTH /= FIFO_BITS for some
foreach in_width {36 40 44 52 56 60} {
  Test Modules/tb_byte_stuffer_osvvm.vhd [generic IN_WIDTH $in_width]
}
# The top's FIFO depth, and the almost-full cushion at its designed stall latency
Test Modules/tb_byte_stuffer_osvvm.vhd [generic BURST_DEPTH 64]
Test Modules/tb_byte_stuffer_osvvm.vhd [generic STALL_LAT 4]
Test Modules/tb_byte_stuffer_osvvm.vhd [generic IN_WIDTH 64] [generic STALL_LAT 4]
Test Modules/tb_jls_framer_osvvm.vhd
# 48 floor, 56 another header split, 200 header ends on a beat, 1024 ceiling
Test Modules/tb_jls_framer_osvvm.vhd [generic OUT_WIDTH 48]
Test Modules/tb_jls_framer_osvvm.vhd [generic OUT_WIDTH 56]
Test Modules/tb_jls_framer_osvvm.vhd [generic OUT_WIDTH 200]
Test Modules/tb_jls_framer_osvvm.vhd [generic OUT_WIDTH 1024]
# Ring exactly full (31 + 1 byte of margin): a stray write past the last byte hits the head
Test Modules/tb_jls_framer_osvvm.vhd [generic OUT_WIDTH 56] [generic STALL_MARGIN 11]
Test Modules/tb_jls_framer_osvvm.vhd [generic BITNESS 8]
Test Modules/tb_jls_framer_osvvm.vhd [generic BITNESS 16]

# BITNESS endpoints; the runs above are 12-bit
foreach bitness {8 9 10 11 13 14 15 16} {
  foreach module {a1 a3 a4 a5 a6_a7 a8_1 a10 a11 a11_1 a11_2 a12_a13 a14 a15_a16 a17 a18 a19 a20_2 a21 a22 a23 line_buffer context_ram} {
    Test Modules/tb_${module}_osvvm.vhd [generic BITNESS $bitness]
  }
}

TestSuite Top
Test Top/tb_openjls_top_osvvm.vhd
Test Top/tb_openjls_top_osvvm.vhd [generic MAX_W 320] [generic MAX_H 200]
Test Top/tb_openjls_top_osvvm.vhd [generic MAX_W 48] [generic MAX_H 48]
Test Top/tb_openjls_top_osvvm.vhd [generic OUT_WIDTH 48]
Test Top/tb_openjls_top_osvvm.vhd [generic OUT_WIDTH 1024]
Test Top/tb_openjls_top_stream_osvvm.vhd [generic BITNESS 8] [generic W 128] [generic H 16] [generic SEED 2] [generic VALID_PCT 100] [generic READY_PCT 100]
Test Top/tb_openjls_top_stream_osvvm.vhd [generic BITNESS 8] [generic W 128] [generic H 16] [generic SEED 2] [generic VALID_PCT 95] [generic READY_PCT 30]
Test Top/tb_openjls_top_stream_osvvm.vhd [generic BITNESS 10] [generic W 16] [generic H 16] [generic SEED 1] [generic VALID_PCT 100] [generic READY_PCT 100]
Test Top/tb_openjls_top_stream_osvvm.vhd [generic BITNESS 12] [generic W 256] [generic H 64] [generic SEED 4] [generic VALID_PCT 100] [generic READY_PCT 100]
Test Top/tb_openjls_top_stream_osvvm.vhd [generic BITNESS 16] [generic W 4] [generic H 4] [generic SEED 2] [generic VALID_PCT 100] [generic READY_PCT 100]
Test Top/tb_openjls_top_stream_osvvm.vhd [generic BITNESS 16] [generic W 4] [generic H 4] [generic SEED 2] [generic VALID_PCT 95] [generic READY_PCT 30]
Test Top/tb_openjls_top_stream_osvvm.vhd [generic BITNESS 9] [generic W 64] [generic H 32] [generic SEED 3] [generic VALID_PCT 100] [generic READY_PCT 10]
Test Top/tb_openjls_top_stream_osvvm.vhd [generic BITNESS 11] [generic W 16] [generic H 16] [generic SEED 4] [generic VALID_PCT 100] [generic READY_PCT 10]
Test Top/tb_openjls_top_stream_osvvm.vhd [generic BITNESS 13] [generic W 8] [generic H 8] [generic SEED 3] [generic VALID_PCT 100] [generic READY_PCT 10]
Test Top/tb_openjls_top_stream_osvvm.vhd [generic BITNESS 14] [generic W 32] [generic H 8] [generic SEED 3] [generic VALID_PCT 100] [generic READY_PCT 100]
Test Top/tb_openjls_top_stream_osvvm.vhd [generic BITNESS 15] [generic W 4] [generic H 1] [generic SEED 2] [generic VALID_PCT 95] [generic READY_PCT 30]

Test Top/tb_openjls_top_boundary_osvvm.vhd [generic BITNESS 8]
Test Top/tb_openjls_top_boundary_osvvm.vhd [generic BITNESS 12]
Test Top/tb_openjls_top_boundary_osvvm.vhd [generic BITNESS 16]
Test Top/tb_openjls_top_boundary_osvvm.vhd [generic BITNESS 8] [generic OUT_WIDTH 48]
Test Top/tb_openjls_top_boundary_osvvm.vhd [generic BITNESS 12] [generic OUT_WIDTH 1024]

TestSuite Xilinx
Test Modules/tb_openjls_axis_osvvm.vhd
Test Modules/tb_openjls_axis_osvvm.vhd [generic OUT_WIDTH 48]
Test Modules/tb_openjls_axis_osvvm.vhd [generic BITNESS 12]
Test Modules/tb_openjls_axis_osvvm.vhd [generic BITNESS 16]
Test Modules/tb_openjls_axis_regs_osvvm.vhd
Test Modules/tb_openjls_axis_regs_osvvm.vhd [generic OUT_WIDTH 48]
Test Modules/tb_openjls_axis_regs_osvvm.vhd [generic MAX_W 1024] [generic MAX_H 768]
