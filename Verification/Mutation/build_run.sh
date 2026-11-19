#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Mutation suite: every RTL mutant against the OSVVM, golden and formal suites -> Results/
# Needs a passing OSVVM, golden and formal run on the current RTL; unchanged rows are reused.
#
# Usage:  ./build_run.sh            (RERUN=1 ignores the cache, MUT_ONLY=stem,... runs a subset)
set -euo pipefail
cd "$(dirname "$0")"
exec python3 run.py
