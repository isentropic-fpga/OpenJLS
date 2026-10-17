#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Main OSVVM entry point: build_reports.sh plus merged NVC statement and branch
# coverage of Sources/ in NVC_CodeCoverage/html/
#
# Usage:  ./build_run.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

COV="NVC_CodeCoverage"
rm -rf "$COV"
CODE_COVERAGE=1 ./build_reports.sh

echo "== merge + report =="
# Keep nvc's ./work stub out of the tree
nvc --work=work:"$COV/work" --cover-merge -o "$COV/merged.covdb" "$COV"/tb_*.covdb
nvc --work=work:"$COV/work" --cover-report --per-file -o "$COV/html" "$COV/merged.covdb"
# Drop the uninstrumented TB and primitive rows
python3 cover_prune.py "$COV/html"
echo "== Sources/ statement coverage (union over all tests) =="
python3 cover_summary.py "$COV" ../../Sources

echo "== reports =="
echo "NVC code coverage     : $HERE/$COV/html/index.html"
echo "OSVVM report index    : $HERE/index.html"
echo "OSVVM build summary   : $HERE/OSVVM_OpenJls/OSVVM_OpenJls.html"
echo "OSVVM requirements    : $HERE/OSVVM_OpenJls/reports/OSVVM_OpenJls_req.html"
