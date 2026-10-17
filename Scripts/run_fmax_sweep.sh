#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Run fmax_sweep.tcl in Vivado batch mode; needs vivado on PATH.
# Usage: ./Scripts/run_fmax_sweep.sh
#        FMAX_SIZES=12288 FMAX_BITNESS="8 10 12 14 16" ./Scripts/run_fmax_sweep.sh
# Output in $FMAX_OUTDIR (default build/fmax_sweep_<timestamp>).
# RAM is the limit at ~6 GB per concurrent run (FMAX_MAX_PARALLEL, default 3).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${FMAX_OUTDIR:-$HERE/../build/fmax_sweep_$(date +%Y%m%d_%H%M%S)}"

mkdir -p "$WORKDIR"
(cd "$WORKDIR" && vivado -mode batch -source "$HERE/fmax_sweep.tcl")

echo "Sweep finished. CSV: $WORKDIR/fmax_sweep.csv"
