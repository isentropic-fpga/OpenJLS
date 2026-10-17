#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# tb_openjls_top_osvvm against the funcsim netlist of its default config.
# Vivado synthesizes only. Needs vivado on PATH and XILINX_VIVADO for the
# one-time nvc --install vivado.
#
# Usage:  ./build_run_osvvm.sh          synthesize + simulate
#         ./build_run_osvvm.sh --sim    skip synthesis, reuse Output/ netlist
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OSVVM_DIR="$ROOT/Verification/OSVVM"
LIBS="$HERE/work-lib"
NETLIST="$HERE/Output/openjls_top_funcsim.vhd"

TB="tb_openjls_top_osvvm"

# Synthesis, in a space-free scratch dir (see synth_funcsim.tcl)
if [[ "${1:-}" != "--sim" ]]; then
  mkdir -p "$HERE/Output"
  SCRATCH="$(mktemp -d)"
  (cd "$SCRATCH" && vivado -mode batch -source "$HERE/synth_funcsim.tcl")
  mv "$SCRATCH/openjls_top_funcsim.vhd" "$SCRATCH/synth_util.rpt" "$HERE/Output/"
  cp "$SCRATCH/vivado.log" "$HERE/Output/" 2> /dev/null || true
  rm -rf "$SCRATCH"
fi

if [[ ! -f "$NETLIST" ]]; then
  echo "netlist missing: $NETLIST (synthesis failed? see ~/EDA/vivado.log)" >&2
  exit 1
fi

# Without lsb_release Vivado writes raw os-release lines into the netlist header
if grep -qm1 '^[A-Z_]\+=' "$NETLIST"; then
  echo "netlist header corrupt — install lsb-release on the synthesis host" >&2
  exit 1
fi

# From /tmp: the install breaks on a cwd with a space and leaves a ./work stub
if ! compgen -G "$HOME/.nvc/lib/unisim*" > /dev/null; then
  : "${XILINX_VIVADO:?set XILINX_VIVADO to the Vivado install directory for nvc --install vivado}"
  (cd /tmp && env XILINX_VIVADO="$XILINX_VIVADO" nvc --install vivado)
fi

if [[ ! -d "$OSVVM_DIR/nvc-libs/osvvm.08" ]]; then
  echo "OSVVM library missing — run Verification/OSVVM/build_osvvm.sh first" >&2
  exit 1
fi

mkdir -p "$LIBS"
NVC=(nvc --std=2008 --ieee-warnings=off -L "$LIBS" -L "$OSVVM_DIR/nvc-libs")

# The TB needs olo math and openjls_pkg; the netlist only unisim
OL_SRC="$ROOT/ThirdParty/open-logic/src/base/vhdl"
"${NVC[@]}" --work=work:"$LIBS/work.08" -a --relaxed \
  "$OL_SRC/olo_base_pkg_array.vhd" \
  "$OL_SRC/olo_base_pkg_math.vhd" \
  "$OL_SRC/olo_base_pkg_string.vhd" \
  "$OL_SRC/olo_base_pkg_logic.vhd" \
  "$OL_SRC/olo_base_pkg_attribute.vhd"
"${NVC[@]}" --work=work:"$LIBS/work.08" -a --relaxed "$ROOT/Sources/openjls_pkg.vhd"

# The netlist becomes work.openjls_top, which POST_SYNTH binds to
"${NVC[@]}" --work=work:"$LIBS/work.08" -a --relaxed "$NETLIST"

"${NVC[@]}" --work=tb_support:"$LIBS/tb_support.08" -a --relaxed \
  "$OSVVM_DIR/Support/tb_support_pkg.vhd"
"${NVC[@]}" --work=work:"$LIBS/work.08" -a --relaxed \
  "$OSVVM_DIR/Top/tb_openjls_top_osvvm.vhd"

# Run in sim-out/, which collects the OSVVM YAML
mkdir -p "$HERE/sim-out"
cd "$HERE/sim-out"
# publish_reports.sh renders this log; pipefail keeps nvc's status
PSLOG="$HERE/Output/postsynth_osvvm.log"
if "${NVC[@]}" --work=work:"$LIBS/work.08" \
    -e --jit --no-save -g POST_SYNTH=true "$TB" \
    -r --exit-severity=error "$TB" 2>&1 | tee "$PSLOG"; then ps_rc=0; else ps_rc=1; fi

# Status for publish_reports.sh
ps_aff=$(awk '/DONE/ && /Affirmations Checked:/ {
  for (i = 1; i <= NF; i++) if ($i == "Checked:") a = $(i+1) } END { print a + 0 }' "$PSLOG")
{
  echo "NAME=\"Post-synth OSVVM\""
  echo "NOTE=\"control-plane stress on funcsim netlist\""
  echo "STATUS=$([ "$ps_rc" -eq 0 ] && echo PASS || echo FAIL)"
  echo "PCT=\"$([ "$ps_rc" -eq 0 ] && echo 100% || echo 0%)\""
  echo "SUMMARY=\"Control-plane stress test &middot; $(printf "%'d" "$ps_aff") affirmations\""
  echo "DATE=\"$(date -Iseconds)\""
} > "$HERE/Output/report_status_osvvm.env"
exit "$ps_rc"
