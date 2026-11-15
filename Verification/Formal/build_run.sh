#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Formal suite: release property proofs and their fault-injection checks -> Results/
#
# Usage:  ./build_run.sh
set -euo pipefail
cd "$(dirname "$0")"
python3 run_suite.py
