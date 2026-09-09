# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

#-----------------------------------------------------------------------------
# synth_funcsim.tcl - Synthesize openjls_top and export a VHDL funcsim netlist
# for gate-level simulation under NVC (driven by build_run_osvvm.sh and
# build_run_golden.sh).
#
# Non-project batch mode. The generics MUST mirror tb_openjls_top_osvvm's
# defaults (BITNESS is an architecture constant there): the netlist bakes its
# configuration at synthesis, and the TB's POST_SYNTH component declares the
# matching fixed port widths.
#
# Run standalone:
#   vivado -mode batch -source synth_funcsim.tcl
#-----------------------------------------------------------------------------

set HERE [file dirname [file normalize [info script]]]
set ROOT [file normalize [file join $HERE .. ..]]
# Outputs go to the cwd: Vivado mishandles space-containing paths (this
# script's directory has one) in shell-outs during synthesis, dropping a
# stray prefix-truncated file. The build_run_*.sh drivers run this from a
# space-free scratch dir and collect the artifacts into Output/.
set OUT [pwd]

# Same device as the fmax characterization project.
set PART xczu7eg-fbvb900-1-e

set OL_SRC [file join $ROOT ThirdParty open-logic src base vhdl]
foreach f {
  olo_base_pkg_array.vhd
  olo_base_pkg_math.vhd
  olo_base_pkg_string.vhd
  olo_base_pkg_logic.vhd
  olo_base_pkg_attribute.vhd
  olo_base_ram_sdp.vhd
  olo_base_fifo_sync.vhd
} {
  read_vhdl -vhdl2008 [file join $OL_SRC $f]
}

set SRC [file join $ROOT Sources]
foreach f {
  openjls_pkg.vhd
  A1_gradient_comp.vhd
  A3_mode_selection.vhd
  A4_quantization_gradients.vhd
  A4_1_quant_gradient_merging.vhd
  A4_2_Q_mapping.vhd
  A5_edge_detecting_predictor.vhd
  A6_prediction_correction.vhd
  A7_prediction_error.vhd
  A6_A7_prediction_error.vhd
  A9_modulo_reduction.vhd
  A10_compute_k.vhd
  A11_error_mapping.vhd
  A11_1_golomb_encoder.vhd
  A11_2_bit_packer.vhd
  A12_variables_update.vhd
  A13_update_bias.vhd
  A14_run_length_determination.vhd
  A15_A16_encode_run.vhd
  A17_run_interruption_index.vhd
  A18_run_interruption_prediction_error.vhd
  A19_run_interruption_error.vhd
  A20_compute_temp.vhd
  A21_compute_map.vhd
  A22_errval_mapping.vhd
  A23_run_interruption_update.vhd
  line_buffer.vhd
  context_ram.vhd
  byte_stuffer.vhd
  jls_framer.vhd
  openjls_top.vhd
} {
  read_vhdl -vhdl2008 [file join $SRC $f]
}

# Config bakes into the netlist at synthesis. Defaults mirror the OSVVM top
# TB; the golden post-synth flow overrides via env to size an 8-bit netlist
# that fits the largest real image (e.g. MAX_IMAGE_WIDTH/HEIGHT for the 8-bit
# corpus). The consuming TB declares matching fixed port widths.
set BITNESS          [expr {[info exists ::env(SYNTH_BITNESS)]     ? $::env(SYNTH_BITNESS)     : 8}]
set MAX_IMAGE_WIDTH  [expr {[info exists ::env(SYNTH_MAX_WIDTH)]   ? $::env(SYNTH_MAX_WIDTH)   : 4096}]
set MAX_IMAGE_HEIGHT [expr {[info exists ::env(SYNTH_MAX_HEIGHT)]  ? $::env(SYNTH_MAX_HEIGHT)  : 4096}]
set OUT_WIDTH        [expr {[info exists ::env(SYNTH_OUT_WIDTH)]   ? $::env(SYNTH_OUT_WIDTH)   : 64}]
puts "Synthesizing openjls_top: BITNESS=$BITNESS MAX=${MAX_IMAGE_WIDTH}x${MAX_IMAGE_HEIGHT} OUT_WIDTH=$OUT_WIDTH"

# out_of_context: no IO buffer insertion, so the netlist ports stay
# bit-for-bit those of the RTL entity.
synth_design -top openjls_top -part $PART -mode out_of_context \
  -generic BITNESS=$BITNESS \
  -generic MAX_IMAGE_WIDTH=$MAX_IMAGE_WIDTH \
  -generic MAX_IMAGE_HEIGHT=$MAX_IMAGE_HEIGHT \
  -generic OUT_WIDTH=$OUT_WIDTH

write_vhdl -mode funcsim -force [file join $OUT openjls_top_funcsim.vhd]
report_utilization -file [file join $OUT synth_util.rpt]
puts "DONE: netlist at [file join $OUT openjls_top_funcsim.vhd]"
