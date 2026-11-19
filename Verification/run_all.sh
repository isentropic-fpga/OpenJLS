#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Every verification suite in order, then the report; stops at the first failing suite.
# Mutation runs last: it needs the other suites to pass on the current RTL.
#
# Usage:  ./run_all.sh [log dir]     (default build/verify_<date>; NUMBER_OF_THREADS, default 20)
set -uo pipefail
V="$(cd "$(dirname "$0")" && pwd)"
L="${1:-$V/../build/verify_$(date +%Y%m%d_%H%M)}"
mkdir -p "$L"
export NUMBER_OF_THREADS="${NUMBER_OF_THREADS:-20}"
export FORMAL_THREADS="$NUMBER_OF_THREADS" MUT_THREADS="$NUMBER_OF_THREADS"

step() {  # name timeout dir status-env|- cmd...
  local name=$1 to=$2 dir=$3 envf=$4; shift 4
  echo "$name: start $(date +%T)"
  ( cd "$dir" && timeout "$to" "$@" ) > "$L/$name.log" 2>&1
  local rc=$? st=""
  [ "$envf" != - ] && st=$(grep -m1 '^STATUS=' "$envf" 2>/dev/null | cut -d= -f2)
  if [ $rc -ne 0 ] || { [ "$envf" != - ] && [ "$st" != PASS ]; }; then
    echo "$name: FAIL (exit $rc${st:+, STATUS=$st}), log $L/$name.log"; exit 1
  fi
  echo "$name: pass $(date +%T)"
}

step osvvm     1h "$V/OSVVM"           -                                               ./build_run.sh
step golden    3h "$V/Golden model"    "$V/Golden model/Output/report_status.env"      ./build_run.sh
step t87       1h "$V/T87 conformance" -                                               ./build_run.sh
step ps_osvvm  3h "$V/Post synth"      "$V/Post synth/Output/report_status_osvvm.env"  ./build_run_osvvm.sh
step ps_golden 5h "$V/Post synth"      "$V/Post synth/Output/report_status_golden.env" ./build_run_golden.sh
step formal    6h "$V/Formal"          "$V/Formal/Results/report_status.env"           ./build_run.sh
step mutation 24h "$V/Mutation"        "$V/Mutation/Results/report_status.env"         ./build_run.sh
step publish  10m "$V"                 -                                               ./publish_reports.sh
echo "all suites pass, logs in $L"
