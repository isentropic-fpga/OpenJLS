#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/build/byte_stuffer_throughput"
mkdir -p "$OUT"
NVC=(nvc --std=2008 --work=work:"$OUT/work")
OL="$ROOT/ThirdParty/open-logic/src/base/vhdl"
"${NVC[@]}" -a --relaxed --psl \
  "$OL/olo_base_pkg_array.vhd" "$OL/olo_base_pkg_math.vhd" \
  "$OL/olo_base_pkg_string.vhd" "$OL/olo_base_pkg_logic.vhd" \
  "$OL/olo_base_pkg_attribute.vhd" "$OL/olo_base_ram_sdp.vhd" \
  "$OL/olo_base_fifo_sync.vhd" "$ROOT/Sources/openjls_pkg.vhd" \
  "${STUFFER_SOURCE:-$ROOT/Sources/byte_stuffer.vhd}" "$HERE/tb_byte_stuffer_throughput.vhd"
for width in 32 48 64; do
  for lanes in ${LANE_COUNTS:-4 $((width / 8 + 2))}; do
    for ready in false true; do
      log="$OUT/${width}_${lanes}_${ready}.log"
      "${NVC[@]}" -e --jit --no-save -g IN_WIDTH="$width" -g LANES="$lanes" \
        -g RANDOM_READY="$ready" tb_byte_stuffer_throughput \
        -r --ieee-warnings=off --exit-severity=error > "$log" 2>&1 || { cat "$log"; exit 1; }
      rg 'pattern=|PASS:' "$log"
    done
  done
done
