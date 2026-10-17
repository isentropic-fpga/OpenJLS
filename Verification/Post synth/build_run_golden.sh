#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# The 8-bit golden corpus (under MAX_MP) against CharLS on the funcsim netlist.
# Each shard elaborates the netlist once and loops a manifest of images.
# Needs vivado on PATH and XILINX_VIVADO for the one-time nvc --install vivado.
#
# Usage:  ./build_run_golden.sh           synthesize + run all eligible images
#         ./build_run_golden.sh --sim     reuse the existing 8-bit netlist
#         IMAGE=<stem> ./build_run_golden.sh --sim   run one image
#
# Env: NVC_HEAP (2g), MAX_MP (0.05), NUMBER_OF_THREADS (20), PER_MEM (2G per worker).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GMODEL="$ROOT/Verification/Golden model"
LIBS="$HERE/work-lib-golden"
NETLIST="$HERE/Output/openjls_top_8bit_funcsim.vhd"
CLI="$ROOT/ThirdParty/charls/build/cli/charls-cli"
IMAGES_DIR="$GMODEL/Images"
GOLDEN="$GMODEL/Output/Golden"
OUTPUT="$GMODEL/Output/OpenJLS"
LOGD="$HERE/Output/logs-golden"
PREP="$GMODEL/imageprep"
MANIFEST="$HERE/Output/manifest.txt"
TB="tb_postsynth_golden"

# Sized to the largest 8-bit image
BITNESS=8
MAX_W=7216
MAX_H=5412
OUT_WIDTH=64

NVC_HEAP="${NVC_HEAP:-2g}"
MAX_MP="${MAX_MP:-0.05}"
NT="${NUMBER_OF_THREADS:-20}"
PER_MEM="${PER_MEM:-2G}"        # ~1 GB real on <= 4 MP images

mkdir -p "$LIBS" "$GOLDEN" "$OUTPUT" "$LOGD" "$HERE/Output"

[ -x "$CLI" ] || "$ROOT/ThirdParty/fetch_third_party.sh" charls

# Synthesis, in a space-free scratch dir (see synth_funcsim.tcl)
if [[ "${1:-}" != "--sim" ]]; then
  SCRATCH="$(mktemp -d)"
  ( cd "$SCRATCH" && env \
      SYNTH_BITNESS="$BITNESS" SYNTH_MAX_WIDTH="$MAX_W" \
      SYNTH_MAX_HEIGHT="$MAX_H" SYNTH_OUT_WIDTH="$OUT_WIDTH" \
      vivado -mode batch -source "$HERE/synth_funcsim.tcl" )
  mv "$SCRATCH/openjls_top_funcsim.vhd" "$NETLIST"
  mv "$SCRATCH/synth_util.rpt" "$HERE/Output/synth_util_8bit.rpt"
  rm -rf "$SCRATCH"
fi
[ -f "$NETLIST" ] || { echo "netlist missing: $NETLIST (synthesis failed?)" >&2; exit 1; }
if grep -qm1 '^[A-Z_]\+=' "$NETLIST"; then
  echo "netlist header corrupt — install lsb-release on the synthesis host" >&2; exit 1
fi

if ! compgen -G "$HOME/.nvc/lib/unisim*" > /dev/null; then
  : "${XILINX_VIVADO:?set XILINX_VIVADO for the one-time nvc --install vivado}"
  ( cd /tmp && env XILINX_VIVADO="$XILINX_VIVADO" nvc --install vivado )
fi

# Mint the goldens and pack the images into NT shards by megapixels, so the
# ~30 s netlist load is paid once per shard
shopt -s nullglob
PGMS=("$IMAGES_DIR"/*.pgm)
shopt -u nullglob
: > "$MANIFEST"
declare -a EL_STEM EL_MP
for pgm in "${PGMS[@]}"; do
  stem="$(basename "${pgm%.pgm}")"
  [ -n "${IMAGE:-}" ] && [ "$stem" != "$IMAGE" ] && continue
  read -r W H MX BITS < <(python3 "$PREP/pgm_info.py" "$pgm")
  [ "$MX" = "255" ] || continue
  mp=$(awk -v w="$W" -v h="$H" 'BEGIN{printf "%.3f", w*h/1e6}')
  awk -v mp="$mp" -v cap="$MAX_MP" 'BEGIN{exit !(mp>cap)}' && { echo "SKIP $stem (${mp} MP)"; continue; }
  if [ ! -f "$GOLDEN/${stem}_charls.jls" ]; then
    "$CLI" encode "$pgm" "$GOLDEN/${stem}_charls.jls" >"$LOGD/$stem.charls.log" 2>&1 \
      || { echo "FAIL $stem (charls encode)" >&2; exit 1; }
  fi
  EL_STEM+=("$stem"); EL_MP+=("$mp")
  echo "$stem" >> "$MANIFEST"
done
nelig=${#EL_STEM[@]}
[ "$nelig" -gt 0 ] || { echo "no eligible 8-bit images" >&2; exit 1; }
NSH=$(( NT < nelig ? NT : nelig ))

# Stale shards from a wider run would add PASS lines to the count below
rm -f "$HERE/Output"/shard_*.txt "$LOGD"/shard_*.log

# Heaviest image first onto the least-loaded shard
ORDER=$(for i in "${!EL_STEM[@]}"; do echo "${EL_MP[$i]} $i"; done | sort -rn | awk '{print $2}')
declare -a SH_LOAD
for ((s=0; s<NSH; s++)); do SH_LOAD[$s]=0; : > "$HERE/Output/shard_$s.txt"; done
for i in $ORDER; do
  best=0
  for ((s=1; s<NSH; s++)); do
    awk -v a="${SH_LOAD[$s]}" -v b="${SH_LOAD[$best]}" 'BEGIN{exit !(a<b)}' && best=$s
  done
  echo "${EL_STEM[$i]}" >> "$HERE/Output/shard_$best.txt"
  SH_LOAD[$best]=$(awk -v a="${SH_LOAD[$best]}" -v m="${EL_MP[$i]}" 'BEGIN{printf "%.3f", a+m}')
done
# Run smallest first so progress shows before each shard's giant
for ((s=0; s<NSH; s++)); do tac "$HERE/Output/shard_$s.txt" > "$HERE/Output/shard_$s.tmp" && mv "$HERE/Output/shard_$s.tmp" "$HERE/Output/shard_$s.txt"; done
echo "8-bit images: $nelig across $NSH shard(s) (heap=$NVC_HEAP, per-worker cap=$PER_MEM)"
echo "=============================================================="

# The netlist is analyzed as work.openjls_top
NVC=(nvc --std=2008 --ieee-warnings=off -H "$NVC_HEAP" -L "$LIBS")
OL_SRC="$ROOT/ThirdParty/open-logic/src/base/vhdl"
"${NVC[@]}" --work=work:"$LIBS/work.08" -a --relaxed \
  "$OL_SRC/olo_base_pkg_array.vhd" "$OL_SRC/olo_base_pkg_math.vhd" \
  "$OL_SRC/olo_base_pkg_string.vhd" "$OL_SRC/olo_base_pkg_logic.vhd" \
  "$OL_SRC/olo_base_pkg_attribute.vhd"
"${NVC[@]}" --work=work:"$LIBS/work.08" -a --relaxed "$ROOT/Sources/openjls_pkg.vhd"
"${NVC[@]}" --work=work:"$LIBS/work.08" -a --relaxed "$NETLIST"
"${NVC[@]}" --work=work:"$LIBS/work.08" -a --relaxed "$HERE/$TB.vhd"

# Each shard in its own cgroup scope capped at PER_MEM, so one runaway can't
# take the machine
run_shard() {
  local s="$1" rel="Verification/Post synth/Output/shard_$s.txt"
  local cmd=("${NVC[@]}" --work=work:"$LIBS/work.08" -e --jit --no-save
             -g REPO_ROOT="$ROOT/" -g MANIFEST="$rel"
             -g BITNESS="$BITNESS" -g MAX_IMAGE_WIDTH="$MAX_W"
             -g MAX_IMAGE_HEIGHT="$MAX_H" -g OUT_WIDTH="$OUT_WIDTH" "$TB"
             -r --exit-severity=error "$TB")
  if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --user --scope -p MemoryMax="$PER_MEM" -p MemorySwapMax=0 \
      "${cmd[@]}" >"$LOGD/shard_$s.log" 2>&1
  else
    "${cmd[@]}" >"$LOGD/shard_$s.log" 2>&1
  fi
}

rc=0
for ((s=0; s<NSH; s++)); do run_shard "$s" & done
for ((s=0; s<NSH; s++)); do wait -n || rc=1; done

echo "=============================================================="
npass=$(grep -hc '^\*\* Note:.*: PASS ' "$LOGD"/shard_*.log 2>/dev/null | awk '{s+=$1} END{print s+0}')
echo "Per-image PASS lines: $npass of $nelig"
grep -h 'MANIFEST RESULT' "$LOGD"/shard_*.log 2>/dev/null || true

# Status for publish_reports.sh
if [ "$rc" -ne 0 ] || [ "$npass" -ne "$nelig" ]; then ps_status=FAIL; else ps_status=PASS; fi
gpct=$(awk -v p="$npass" -v t="$nelig" 'BEGIN{ if (t > 0) printf "%.0f%%", 100 * p / t }')
{
  echo "NAME=\"Post-synth Golden Model\""
  echo "NOTE=\"byte-exact vs CharLS on funcsim netlist\""
  echo "STATUS=$ps_status"
  echo "PCT=\"$gpct\""
  echo "SUMMARY=\"$npass of $nelig images byte-exact vs CharLS\""
  echo "DATE=\"$(date -Iseconds)\""
} > "$HERE/Output/report_status_golden.env"

# Per-image table. A PASS line carries the byte count; a FAIL leaves a _PS.jls
# to diff against the golden.
PREP="$GMODEL/imageprep"
PSOUT="$GMODEL/Output/OpenJLS"
declare -A PS_RES PS_BYTES
while read -r kind stem rest; do
  if [ "$kind" = PASS ]; then
    PS_RES["$stem"]=PASS; PS_BYTES["$stem"]="$(printf '%s' "$rest" | tr -dc '0-9')"
  else
    PS_RES["$stem"]=FAIL
  fi
done < <(grep -hoE 'PASS [^ ]+ \([0-9]+ B\)|FAIL [^ ]+' "$LOGD"/shard_*.log 2>/dev/null)
{
  printf 'Image\tDims\tBits\tBytes (match/total)\tResult\n'
  while IFS= read -r stem; do
    [ -z "$stem" ] && continue
    read -r W H _ _ < <(python3 "$PREP/pgm_info.py" "$IMAGES_DIR/$stem.pgm" 2>/dev/null) || true
    total=$(stat -c%s "$GOLDEN/${stem}_charls.jls" 2>/dev/null || echo 0)
    case "${PS_RES[$stem]:-}" in
      PASS) result=PASS; matched="${PS_BYTES[$stem]:-$total}" ;;
      FAIL) result=FAIL; ps="$PSOUT/${stem}_PS.jls"
            if [ -f "$ps" ]; then
              diffb=$(cmp -l "$GOLDEN/${stem}_charls.jls" "$ps" 2>/dev/null | wc -l)
              osz=$(stat -c%s "$ps"); minsz=$(( total < osz ? total : osz ))
              matched=$(( minsz - diffb )); [ "$matched" -lt 0 ] && matched=0
            else matched=0; fi ;;
      *)    result="no result"; matched=0 ;;
    esac
    printf '%s\t%sx%s\t%s\t%s\t%s\n' "$stem" "${W:-?}" "${H:-?}" "$BITNESS" "$matched/$total" "$result"
  done < "$MANIFEST" | sort
} > "$HERE/Output/ps_golden_image_results.tsv" || true

if [ "$rc" -ne 0 ] || [ "$npass" -ne "$nelig" ]; then
  echo "Post-synth golden: FAIL"
  grep -h 'FAIL ' "$LOGD"/shard_*.log 2>/dev/null || true
  exit 1
fi
echo "Post-synth golden: PASS ($nelig/$nelig byte-exact vs CharLS)"
