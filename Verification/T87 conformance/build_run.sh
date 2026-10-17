#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# T.87 conformance: TEST16.PGM against the official T16E0.JLS under NVC
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIBS="$HERE/work-lib"

TB="tb_openjls_t87_conformance"

mkdir -p "$LIBS" "$HERE/Output"

NVC=(nvc --std=2008 --ieee-warnings=off -L "$LIBS")
A_FLAGS=(--relaxed --psl)

OL_SRC="$ROOT/ThirdParty/open-logic/src/base/vhdl"
OL_FILES=(
  olo_base_pkg_array.vhd
  olo_base_pkg_math.vhd
  olo_base_pkg_string.vhd
  olo_base_pkg_logic.vhd
  olo_base_pkg_attribute.vhd
  olo_base_ram_sdp.vhd
  olo_base_fifo_sync.vhd
)
"${NVC[@]}" --work=work:"$LIBS/work.08" -a "${A_FLAGS[@]}" \
  "${OL_FILES[@]/#/$OL_SRC/}"

SRC="$ROOT/Sources"
SRC_FILES=(
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
  A8_1_reconstructed_value.vhd
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
  A20_1_run_context_index.vhd
  A20_2_compute_k.vhd
  A21_compute_map.vhd
  A22_errval_mapping.vhd
  A23_run_interruption_update.vhd
  line_buffer.vhd
  context_ram.vhd
  byte_stuffer.vhd
  jls_framer.vhd
  openjls_top.vhd
)
"${NVC[@]}" --work=work:"$LIBS/work.08" -a "${A_FLAGS[@]}" \
  "${SRC_FILES[@]/#/$SRC/}"

"${NVC[@]}" --work=work:"$LIBS/work.08" -a "${A_FLAGS[@]}" "$HERE/tb_openjls_conformance.vhd"

# Without --exit-severity=error a failed PSL contract still exits 0
"${NVC[@]}" --work=work:"$LIBS/work.08" \
  -e --jit --no-save -g REPO_ROOT="$ROOT/" "$TB" \
  -r --exit-severity=error "$TB"
