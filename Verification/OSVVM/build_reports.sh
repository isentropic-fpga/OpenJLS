#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Full OSVVM regression with HTML reports, via OpenJls.pro. Outputs are gitignored.
# CODE_COVERAGE=1 adds code coverage (see build_run.sh).
#
# Usage:  ./build_reports.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

command -v nvc >/dev/null || {
  echo "nvc not found — install it (Arch: nvc from the AUR)" >&2
  exit 1
}
command -v tclsh >/dev/null || {
  echo "tclsh not found — install tcl (Arch: sudo pacman -S tcl)" >&2
  exit 1
}

# Vendored tcllib subset (fileutil, yaml)
export TCLLIBPATH="$HERE/../../ThirdParty/tcllib"

tclsh <<'EOF'
# Tcl reading stdin can print errors and still exit 0
if {[catch {
source ../../ThirdParty/osvvm-scripts/StartNVC.tcl
# The 2019 support files and the NVC coverage API aren't vendored
SetVHDLVersion 2008
set ::osvvm::FunctionalCoverageIntegratedInSimulator "default"
set ::osvvm::FailOnTestCaseErrors true
set ::osvvm::FailOnReportErrors true
build ../../ThirdParty/osvvm/osvvm.pro
# AXI4 VCs for the Xilinx wrapper TBs
build ../../ThirdParty/osvvm-common/build.pro
build ../../ThirdParty/osvvm-axi4/common/build.pro
build ../../ThirdParty/osvvm-axi4/Axi4Lite/build.pro
build ../../ThirdParty/osvvm-axi4/AxiStream/build.pro
build OpenJls.pro
} message options]} {
  puts stderr [dict get $options -errorinfo]
  exit 1
}
EOF
