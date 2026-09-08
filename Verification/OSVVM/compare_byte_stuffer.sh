#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# Compare current RTL to a saved baseline, cycle for cycle, at 32/48/64 bits.
# Requires nvc and python3; no OSVVM libraries are needed for this extra check.
# Usage: ./compare_byte_stuffer.sh /absolute/path/to/baseline/byte_stuffer.vhd
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BASELINE="$(realpath "${1:?provide the baseline byte_stuffer.vhd}")"
OUT="$ROOT/build/byte_stuffer_equivalence"
mkdir -p "$OUT"
python3 - "$BASELINE" "$OUT/byte_stuffer_baseline.vhd" <<'PY'
import pathlib
import re
import sys
source = pathlib.Path(sys.argv[1]).read_text()
pathlib.Path(sys.argv[2]).write_text(re.sub(r'\bbyte_stuffer\b', 'byte_stuffer_baseline', source))
PY
cd "$OUT"
NVC=(nvc --std=2008 --work=work:"$OUT/work")
OL="$ROOT/ThirdParty/open-logic/src/base/vhdl"
"${NVC[@]}" -a --relaxed --psl \
  "$OL/olo_base_pkg_array.vhd" "$OL/olo_base_pkg_math.vhd" \
  "$OL/olo_base_pkg_string.vhd" "$OL/olo_base_pkg_logic.vhd" \
  "$OL/olo_base_pkg_attribute.vhd" "$OL/olo_base_ram_sdp.vhd" \
  "$OL/olo_base_fifo_sync.vhd" "$ROOT/Sources/openjls_pkg.vhd" \
  "$ROOT/Sources/byte_stuffer.vhd" "$OUT/byte_stuffer_baseline.vhd" \
  "$HERE/tb_byte_stuffer_equivalence.vhd"
for width in 32 48 64; do
  for stalls in false true; do
    "${NVC[@]}" -e --jit --no-save -g IN_WIDTH="$width" -g RANDOM_STALLS="$stalls" \
      tb_byte_stuffer_equivalence -r --ieee-warnings=off --exit-severity=error \
      > "$OUT/${width}_${stalls}.log" 2>&1
    tail -n 3 "$OUT/${width}_${stalls}.log"
  done
done
echo "All six cycle-equivalence comparisons passed. Logs: $OUT"
