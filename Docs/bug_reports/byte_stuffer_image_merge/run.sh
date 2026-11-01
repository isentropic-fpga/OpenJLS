#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
# Repro: ./run.sh BITNESS W H NIMG VALID_PCT READY_PCT SEED   (defaults: the silent-corruption case)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
B=${1:-16} W=${2:-4} H=${3:-4} N=${4:-20} V=${5:-100} R=${6:-100} SEED=${7:-2}
OUT="$HERE/out"; LIB="$OUT/lib"; mkdir -p "$LIB"
OLO="$ROOT/ThirdParty/open-logic/src/base/vhdl"
SRC=$(sed -n 's#^analyze \.\./\.\./\(Sources/[^/]*\.vhd\)$#\1#p' "$ROOT/Verification/OSVVM/OpenJls.pro")
NVC="nvc --std=2008 --ieee-warnings=off -L $LIB --work=work:$LIB/work"
$NVC -a --relaxed $OLO/olo_base_pkg_{array,math,string,logic,attribute}.vhd $OLO/olo_base_ram_sdp.vhd $OLO/olo_base_fifo_sync.vhd \
  $(for f in $SRC; do echo "$ROOT/$f"; done) "$HERE/tb_image_merge.vhd"
TAG="$OUT/b${B}_${W}x${H}_v${V}_r${R}_s${SEED}"
$NVC -e --jit --no-save -gBITNESS=$B -gW=$W -gH=$H -gNIMG=$N -gVALID_PCT=$V -gREADY_PCT=$R -gSEED=$SEED -gDUMP="$TAG" \
  tb_image_merge -r tb_image_merge 2>&1 | grep -E "MERGE|RESULT" | sed 's/^\*\* [A-Za-z]*: [0-9]*ns+[0-9]*: //'
CLI=${CHARLS_CLI:-$ROOT/ThirdParty/charls/build/cli/charls-cli}
[ -x "$CLI" ] || "$ROOT/ThirdParty/fetch_third_party.sh" charls
python3 -I "$HERE/check_dump.py" "$TAG" $W $H $B "$CLI"
