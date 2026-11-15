#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# CharLS is only trusted if it reproduces the official T.87 vectors at 12 and 8 bits.
# Usage: charls_gate.sh <charls-cli> <scratch dir>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REF="$HERE/Reference Images"
CLI="$1"
WORK="$2/charls_gate"
mkdir -p "$WORK"

( cd "$REF" && sha256sum -c --quiet "$HERE/reference_images.sha256" ) \
  || { echo "FATAL: T.87 reference vectors differ from the pinned hashes." >&2; exit 1; }
"$HERE/t87_split.py" "$REF" "$WORK"

gate() {
  "$CLI" encode "$REF/$1" "$WORK/gate.jls" > /dev/null
  cmp -s "$WORK/gate.jls" "$2" \
    || { echo "FATAL: CharLS does not reproduce $(basename "$2") byte-exact." >&2; exit 1; }
}

gate TEST16.PGM "$REF/T16E0.JLS"
for c in R G B; do gate "TEST8$c.PGM" "$WORK/T8C0E0_$c.JLS"; done
echo "CharLS gate: reproduces the official T16E0 and T8C0E0 vectors byte-exact OK"
