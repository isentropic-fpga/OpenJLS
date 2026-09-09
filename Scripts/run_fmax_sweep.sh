#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Launch the fmax sweep in Vivado batch mode. `vivado` must be on PATH (if
# Vivado lives in a container on your machine, point a local shim at it).
# Usage: ./Scripts/run_fmax_sweep.sh
# Output: $FMAX_OUTDIR (default build/fmax_sweep_<timestamp>): fmax_sweep.csv + per-point
#         rpt_*.log, vivado.log
#
# 6 sizes x 4 strategies = 24 impl + 6 synth, launched as one dependency DAG and
# scheduled by Vivado (default 3 concurrent runs; see MAX_PARALLEL / THREADS_PER_RUN
# in the tcl). Each concurrent run is a full ~5-6 GB Vivado process, so RAM — not
# CPU — is the limit: 3-way ~= 18 GB. Drop FMAX_MAX_PARALLEL if other apps need
# the RAM (we OOM'd a 30 GB box running it alongside other heavy apps).
# Watch progress with:  tail -f "$FMAX_OUTDIR"/vivado.log
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${FMAX_OUTDIR:-$HERE/../build/fmax_sweep_$(date +%Y%m%d_%H%M%S)}"

mkdir -p "$WORKDIR"
(cd "$WORKDIR" && vivado -mode batch -source "$HERE/fmax_sweep.tcl")

echo "Sweep finished. CSV: $WORKDIR/fmax_sweep.csv"
