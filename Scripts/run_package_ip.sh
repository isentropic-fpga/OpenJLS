#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Regenerate the IP cores in Sources/Xilinx/ip_repo; needs vivado on PATH.
# Usage: ./Scripts/run_package_ip.sh [--verify]
#   --verify also runs the verify_ip.tcl smoke test.
# Vivado scratch goes to $OPENJLS_IP_OUTDIR (default ~/EDA/Logs).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OPENJLS_IP_OUTDIR:-$HOME/EDA/Logs}"

mkdir -p "$WORKDIR"
(cd "$WORKDIR" && vivado -mode batch -source "$HERE/package_ip.tcl")

if [[ "${1:-}" == "--verify" ]]; then
  (cd "$WORKDIR" && vivado -mode batch -source "$HERE/verify_ip.tcl")
fi

echo "IP repo: $(cd "$HERE/.." && pwd)/Sources/Xilinx/ip_repo"
