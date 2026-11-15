#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Encode every image in Images/ with CharLS and OpenJLS and byte-compare, then
# stream the same-size sets in Images_stream/ through one core with no reset
# between images. Runs that passed with the same RTL, tools and image are skipped;
# RERUN=1 runs all. A row from another RTL never counts as a pass: STATUS=PARTIAL.
# Knobs: MAX_MP (default 0.5), NUMBER_OF_THREADS (default 1), NVC_HEAP,
# STREAM=0 (skip the same-size and random streams), RANDOM_RUNS (default 1500),
# ANALYZE_ONLY=1 (stop after compiling).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIBS="$HERE/work-lib"
GOLDEN="$HERE/Output/Golden"
OUTPUT="$HERE/Output/OpenJLS"
CLI="$ROOT/ThirdParty/charls/build/cli/charls-cli"

TB="tb_openjls_golden"
STREAM_TB="tb_openjls_golden_stream"

mkdir -p "$LIBS" "$GOLDEN" "$OUTPUT"

"$ROOT/ThirdParty/fetch_third_party.sh" charls

"$ROOT/Verification/T87 conformance/charls_gate.sh" "$CLI" "$GOLDEN"

# The TB holds whole images in memory. NVC fills the heap up to -H before
# collecting, so -H x NUMBER_OF_THREADS must fit in RAM; 1g covers ~39 MP.
NVC=(nvc --std=2008 --ieee-warnings=off -H "${NVC_HEAP:-1g}" -L "$LIBS")
A_FLAGS=(--relaxed --psl)

OL_SRC="$ROOT/ThirdParty/open-logic/src/base/vhdl"
OL_FILES=(
  olo_base_pkg_array.vhd
  olo_base_pkg_math.vhd
  olo_base_pkg_string.vhd
  olo_base_pkg_logic.vhd
  olo_base_pkg_attribute.vhd
  olo_base_ram_sdp.vhd
  olo_base_fifo_sync.vhd
)
"${NVC[@]}" --work=work:"$LIBS/work.08" -a "${A_FLAGS[@]}" \
  "${OL_FILES[@]/#/$OL_SRC/}"

SRC="$ROOT/Sources"
SRC_FILES=(
  openjls_pkg.vhd
  A1_gradient_comp.vhd
  A3_mode_selection.vhd
  A4_quantization_gradients.vhd
  A4_1_quant_gradient_merging.vhd
  A4_2_Q_mapping.vhd
  A5_edge_detecting_predictor.vhd
  A6_A7_prediction_error.vhd
  A8_1_reconstructed_value.vhd
  A9_modulo_reduction.vhd
  A10_compute_k.vhd
  A11_error_mapping.vhd
  A11_1_golomb_encoder.vhd
  A11_2_bit_packer.vhd
  A12_A13_update.vhd
  A14_run_length_determination.vhd
  A15_A16_encode_run.vhd
  A17_run_interruption_index.vhd
  A18_run_interruption_prediction_error.vhd
  A19_run_interruption_error.vhd
  A20_1_run_context_index.vhd
  A20_2_compute_k.vhd
  A21_compute_map.vhd
  A22_errval_mapping.vhd
  A23_run_interruption_update.vhd
  line_buffer.vhd
  context_ram.vhd
  byte_stuffer.vhd
  jls_framer.vhd
  openjls_top.vhd
)
"${NVC[@]}" --work=work:"$LIBS/work.08" -a "${A_FLAGS[@]}" \
  "${SRC_FILES[@]/#/$SRC/}"

"${NVC[@]}" --work=work:"$LIBS/work.08" -a "${A_FLAGS[@]}" "$HERE/$TB.vhd" "$HERE/$STREAM_TB.vhd"
[ "${ANALYZE_ONLY:-0}" = 1 ] && exit 0

# Generics are fixed at elaboration, so each image is its own -e --no-save -r;
# the library stays read-only and images run in parallel.
PREP="$HERE/imageprep"
IMAGES_DIR="$HERE/Images"
MAX_MP="${MAX_MP:-0.5}"
NUMBER_OF_THREADS="${NUMBER_OF_THREADS:-1}"
LOGD="$HERE/Output/logs"
mkdir -p "$LOGD"

shopt -s nullglob
PGMS=("$IMAGES_DIR"/*.pgm)
shopt -u nullglob
if [ "${#PGMS[@]}" -eq 0 ]; then
  echo "No images in $IMAGES_DIR — run ./prepare_images.sh first." >&2
  exit 1
fi
if [ "$(cat "$IMAGES_DIR/.corpus_id" 2> /dev/null)" != "$("$HERE/corpus_id.sh")" ]; then
  echo "$IMAGES_DIR was not made by the current prepare_images.sh — run it again." >&2
  exit 1
fi
SETS="$HERE/Images_stream"
if [ "${STREAM:-1}" = 1 ] && [ ! -d "$SETS/8-r3" ]; then
  echo "No stream sets in $SETS — run ./prepare_images.sh first, or STREAM=0." >&2
  exit 1
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# A PASS row is reused only while the RTL, the TB, the tools and its image match
TOOLS_HASH="$({ cat "${OL_FILES[@]/#/$OL_SRC/}" "$CLI"; nvc --version; } | sha256sum | cut -c1-12)"
RTL_HASH="$({ cat "${SRC_FILES[@]/#/$SRC/}" "$HERE/$TB.vhd"; echo "$TOOLS_HASH"; } | sha256sum | cut -c1-12)"
STREAM_HASH="$({ cat "${SRC_FILES[@]/#/$SRC/}" "$HERE/$STREAM_TB.vhd"; echo "$TOOLS_HASH"
  [ -d "$SETS" ] && find "$SETS" -name '*.pgm' -print0 | sort -z | xargs -0 cat; } | sha256sum | cut -c1-12)"
TSV="$HERE/Output/golden_image_results.tsv"

(cd "$IMAGES_DIR" && find . -maxdepth 1 -name '*.pgm' -printf '%f\0' | xargs -0 -P "$NUMBER_OF_THREADS" -n 200 sha256sum) |
  awk '{ n = $2; sub(/\.pgm$/, "", n); print n "\t" substr($1, 1, 12) }' >"$TMPD/sums"
declare -A IMG_SUM CACHED
while IFS=$'\t' read -r s v; do IMG_SUM[$s]=$v; done <"$TMPD/sums"
if [ "${RERUN:-0}" != 1 ] && [ -f "$TSV" ]; then
  while IFS=$'\t' read -r s _ _ _ _ r _ h v; do
    [ "$r" = PASS ] && [ "$h" = "$RTL_HASH" ] && CACHED[$s]=$v
  done < <(tail -n +2 "$TSV")
fi

skip=0; cached=0
ELIG=()      # "<size_bytes>\t<pgm_path>\t<bits>"
SKIPPED=()
for pgm in "${PGMS[@]}"; do
  stem="$(basename "${pgm%.pgm}")"
  if [ -n "${CACHED[$stem]:-}" ] && [ "${CACHED[$stem]}" = "${IMG_SUM[$stem]}" ]; then
    cached=$((cached + 1)); continue
  fi
  read -r W H MX BITS < <(python3 "$PREP/pgm_info.py" "$pgm")
  mp=$(awk -v w="$W" -v h="$H" 'BEGIN{printf "%.3f", w*h/1e6}')
  if awk -v mp="$mp" -v cap="$MAX_MP" 'BEGIN{exit !(mp>cap)}'; then
    echo "SKIP $stem (${W}x${H}, ${mp} MP > ${MAX_MP} cap)"
    skip=$((skip + 1))
    SKIPPED+=("$stem"$'\t'"${W}x${H}"$'\t'"$mp"$'\t'"$BITS"$'\t'"—"$'\t'SKIP)
    continue
  fi
  ELIG+=("$(stat -c%s "$pgm")"$'\t'"$pgm"$'\t'"$BITS")
done
NELIG="${#ELIG[@]}"

NT="$NUMBER_OF_THREADS"
[ "$NT" -lt 1 ] && NT=1
[ "$NELIG" -gt 0 ] && [ "$NT" -gt "$NELIG" ] && NT="$NELIG"

run_image() {
  local w="$1" pgm="$2" bits="$3" stem rc st result W H MX mp
  local ref out rsz osz diffb minsz matched bytes
  stem="$(basename "${pgm%.pgm}")"
  read -r W H MX _ < <(python3 "$PREP/pgm_info.py" "$pgm")
  mp=$(awk -v w="$W" -v h="$H" 'BEGIN{printf "%.3f", w*h/1e6}')
  if ! "$CLI" encode "$pgm" "$GOLDEN/${stem}_charls.jls" >"$LOGD/$stem.log" 2>&1; then
    rc=1; result="FAIL (charls)"
  elif "${NVC[@]}" --work=work:"$LIBS/work.08" \
      -e --jit --no-save \
      -g REPO_ROOT="$ROOT/" \
      -g PGM_PATH="Verification/Golden model/Images/${stem}.pgm" \
      -g JLS_PATH="Verification/Golden model/Output/Golden/${stem}_charls.jls" \
      -g OUT_PATH="Verification/Golden model/Output/OpenJLS/${stem}_OPENJLS.jls" \
      -g BITNESS="$bits" "$TB" \
      -r --exit-severity=error "$TB" >>"$LOGD/$stem.log" 2>&1 &&
      grep -qa "$TB RESULT: PASS" "$LOGD/$stem.log"; then rc=0; result=PASS; else rc=1; result=FAIL; fi
  st="$(grep -m1 -ao 'Pipeline stalled.*' "$LOGD/$stem.log" 2>/dev/null || true)"
  if [ -n "$st" ]; then
    echo "[t$w] STALL $stem: $st"
    printf '%s\t%s\n' "$stem" "$st" >>"$TMPD/stalls"
  fi
  # Matched bytes over the golden size; a length mismatch counts as unmatched
  ref="$GOLDEN/${stem}_charls.jls"; out="$OUTPUT/${stem}_OPENJLS.jls"
  rsz=$(stat -c%s "$ref" 2>/dev/null || echo 0)
  osz=$(stat -c%s "$out" 2>/dev/null || echo 0)
  if [ "$rsz" -gt 0 ] && [ -f "$out" ]; then
    diffb=$(cmp -l "$ref" "$out" 2>/dev/null | wc -l)
    minsz=$(( rsz < osz ? rsz : osz ))
    matched=$(( minsz - diffb )); [ "$matched" -lt 0 ] && matched=0
    bytes="$matched/$rsz"
  else
    bytes="0/$rsz"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$stem" "${W}x${H}" "$mp" "$bits" "$bytes" "$result" >>"$TMPD/results"
  if [ "$rc" -eq 0 ]; then echo "[t$w] PASS $stem"; return 0; fi
  echo "[t$w] FAIL $stem"; echo "$stem" >>"$TMPD/failures"; return 1
}

run_worker() {
  local w="$1" pgm bits
  while IFS=$'\t' read -r pgm bits; do
    [ -z "$pgm" ] && continue
    run_image "$w" "$pgm" "$bits" || true
  done < "$TMPD/w$w.list"
}

pass=0; fail=0
if [ "$NELIG" -gt 0 ]; then
  # Largest image first to the least-loaded worker
  declare -a LOAD
  for ((w = 0; w < NT; w++)); do LOAD[w]=0; : > "$TMPD/w$w.list"; done
  while IFS=$'\t' read -r sz pgm bits; do
    min=0
    for ((w = 1; w < NT; w++)); do
      [ "${LOAD[w]}" -lt "${LOAD[min]}" ] && min=$w
    done
    printf '%s\t%s\n' "$pgm" "$bits" >> "$TMPD/w$min.list"
    LOAD[min]=$((LOAD[min] + sz))
  done < <(printf '%s\n' "${ELIG[@]}" | sort -t$'\t' -k1,1nr)

  echo "Running $NELIG image(s) across $NT thread(s), balanced by size:"
  for ((w = 0; w < NT; w++)); do
    printf '  t%d: %d image(s), %s MB\n' "$w" "$(wc -l < "$TMPD/w$w.list")" \
      "$(awk -v b="${LOAD[w]}" 'BEGIN{printf "%.2f", b/1048576}')"
  done
  echo "=============================================================="

  for ((w = 0; w < NT; w++)); do run_worker "$w" & done
  wait

  # An image with no result line was lost with its worker: its row is a FAIL
  touch "$TMPD/results" "$TMPD/failures"
  for e in "${ELIG[@]}"; do
    IFS=$'\t' read -r _ pgm bits <<<"$e"; pgm="${pgm##*/}"; printf '%s\t%s\n' "${pgm%.pgm}" "$bits"
  done | awk -F'\t' -v OFS='\t' -v r="$TMPD/results" -v f="$TMPD/failures" '
      BEGIN { while ((getline l < r) > 0) { split(l, a, "\t"); seen[a[1]] = 1 } }
      !($1 in seen) { print $1, "—", "—", $2, "0/0", "FAIL (no result)" >> r; print $1 >> f }'
  pass=$(awk -F'\t' '$6 == "PASS"' "$TMPD/results" | wc -l)
  fail=$((NELIG - pass))
fi

echo "=============================================================="
echo "Golden-model suite: PASS=$pass FAIL=$fail SKIP=$skip CACHED=$cached (cap ${MAX_MP} MP, ${NT} thread(s), RTL $RTL_HASH)"

# Merge into the previous table: new rows replace, skipped images keep their
# last result, images gone from Images/ drop out
today="$(date +%F)"
{
  printf 'Image\tDims\tMP\tBits\tBytes (match/total)\tResult\tRun\tRTL\tImage hash\n'
  {
    [ -f "$TSV" ] && tail -n +2 "$TSV" | awk -F'\t' -v OFS='\t' '{ for (i = NF + 1; i <= 9; i++) $i = "—"; print "old", $0 }'
    [ -f "$TMPD/results" ] && awk -F'\t' -v d="$today" -v h="$RTL_HASH" 'FNR == NR { v[$1] = $2; next } { print "new\t" $0 "\t" d "\t" h "\t" v[$1] }' "$TMPD/sums" "$TMPD/results"
    [ "${#SKIPPED[@]}" -gt 0 ] && printf 'skip\t%s\t—\t—\t—\n' "${SKIPPED[@]}"
    :   # empty SKIPPED would otherwise fail the pipe
  } | awk -F'\t' -v OFS='\t' -v imgs="$IMAGES_DIR" '
      BEGIN { while (("ls \"" imgs "\"" | getline f) > 0) if (f ~ /\.pgm$/) live[substr(f, 1, length(f) - 4)] = 1 }
      { k = $2; src = $1; sub(/^[^\t]*\t/, "")
        if (!(k in live) && k !~ /^stream[0-9]+-r[0-9]+-/) next
        if (src == "new" || !(k in row)) row[k] = $0 }
      END { for (k in row) print row[k] }' | sort
} > "$TSV.tmp"
mv "$TSV.tmp" "$TSV"

# Ready at 3% keeps the FIFO backed up: without a backlog the next image's word
# rarely reaches the byte_stuffer skid before the last word has drained.
# Each image is a row of the image table, named stream<bits>-r<ready>-<image>;
# STREAM_TSV holds what only a whole run has: its cache key and window hits.
STREAM_OUT="$HERE/Output/Stream"
STREAM_TSV="$STREAM_OUT/runs.tsv"
STREAM_LOGD="$STREAM_OUT/logs"

# Raw pixels, one .jls and one length line per image, in file order
concat_set() {
  local run="$1" pgm stem
  mkdir -p "$STREAM_OUT/Golden/$run"
  python3 - "$SETS/$run" "$STREAM_OUT/$run.pix" <<'PY'
import sys
from pathlib import Path
with open(sys.argv[2], "wb") as out:
    for p in sorted(Path(sys.argv[1]).glob("*.pgm")):
        out.write(p.read_bytes().split(b"\n", 3)[3])
PY
  : >"$STREAM_OUT/$run.jls"; : >"$STREAM_OUT/$run.len"
  for pgm in "$SETS/$run"/*.pgm; do
    stem="$(basename "${pgm%.pgm}")"
    "$CLI" encode "$pgm" "$STREAM_OUT/Golden/$run/$stem.jls" >/dev/null
    cat "$STREAM_OUT/Golden/$run/$stem.jls" >>"$STREAM_OUT/$run.jls"
    stat -c%s "$STREAM_OUT/Golden/$run/$stem.jls" >>"$STREAM_OUT/$run.len"
  done
}

run_stream() {
  local b="$1" pct="$2" run="$1-r$2" n w h rel log res
  log="$STREAM_LOGD/$run.log"
  : >"$STREAM_OUT/$run.res"
  n=$(wc -l <"$STREAM_OUT/$run.len")
  : >"$log"
  read -r w h < <(sed -n 2p "$(ls "$SETS/$run"/*.pgm | head -1)")
  rel="Verification/Golden model/Output/Stream/$run"
  # A short .len means CharLS lost an image of the set
  if [ "$n" -eq "$(ls "$SETS/$run" | wc -l)" ] && "${NVC[@]}" --work=work:"$LIBS/work.08" -e --jit --no-save \
      -g REPO_ROOT="$ROOT/" -g PIX_PATH="$rel.pix" -g JLS_PATH="$rel.jls" -g LEN_PATH="$rel.len" -g RES_PATH="$rel.res" \
      -g BITNESS="$b" -g W="$w" -g H="$h" -g N_IMAGES="$n" -g READY_PCT="$pct" "$STREAM_TB" \
      -r --exit-severity=error "$STREAM_TB" >"$log" 2>&1 && grep -qa "$STREAM_TB RESULT: PASS" "$log"; then res=PASS; else res=FAIL; fi
  echo "[stream] $res BITNESS=$b READY=$pct"
  # An image with no result line never closed: its row is a FAIL
  ls "$SETS/$run" | sed 's/\.pgm$//' | paste - "$STREAM_OUT/$run.len" |
    awk -F'\t' -v OFS='\t' -v r="$STREAM_OUT/$run.res" -v b="$b" -v p="$pct" -v w="$w" -v h="$h" -v d="$(date +%F)" -v v="$STREAM_HASH" '
      BEGIN { while ((getline l < r) > 0) { split(l, a, " "); m[a[1]] = a[2]; ok[a[1]] = a[3] } }
      { i = FNR - 1
        print "stream" b "-r" p "-" $1, w "x" h, sprintf("%.3f", w * h / 1e6), b, (m[i] + 0) "/" ($2 + 0), (ok[i] == "true" ? "PASS" : "FAIL"), d, v, "—" }' \
    >"$TMPD/image_rows_$run"
  printf '%s\t%s\t%s\t%s\t%s\n' "$b" "$pct" "$res" "$(grep -ao 'stream: .*' "$log" || echo 'no summary')" "$STREAM_HASH" >>"$TMPD/stream_rows"
}

if [ "${STREAM:-1}" = 1 ]; then
  mkdir -p "$STREAM_LOGD"
  declare -A STREAM_CACHED
  if [ "${RERUN:-0}" != 1 ] && [ -f "$STREAM_TSV" ]; then
    while IFS=$'\t' read -r b pct r _ h; do
      [ "$r" = PASS ] && [ "$h" = "$STREAM_HASH" ] && STREAM_CACHED["$b $pct"]=1
    done < <(tail -n +2 "$STREAM_TSV")
  fi

  : >"$TMPD/stream_rows"; : >"$TMPD/stream_jobs"
  for d in "$SETS"/*/; do
    run="$(basename "$d")"; b="${run%-r*}"; pct="${run#*-r}"
    if [ -n "${STREAM_CACHED["$b $pct"]:-}" ]; then
      grep -P "^$b\t$pct\t" "$STREAM_TSV" >>"$TMPD/stream_rows"
    else
      echo "$b $pct" >>"$TMPD/stream_jobs"
      while [ "$(jobs -rp | wc -l)" -ge "$NUMBER_OF_THREADS" ]; do wait -n || true; done
      concat_set "$run" &
    fi
  done
  wait

  echo "Streaming $(wc -l <"$TMPD/stream_jobs") no-reset run(s), $(wc -l <"$TMPD/stream_rows") cached"
  while read -r b pct; do
    while [ "$(jobs -rp | wc -l)" -ge "$NUMBER_OF_THREADS" ]; do wait -n || true; done
    run_stream "$b" "$pct" &
  done <"$TMPD/stream_jobs"
  wait

  {
    printf 'Bits\tReady%%\tResult\tSummary\tRTL\n'
    sort -t$'\t' -k1,1n -k2,2nr "$TMPD/stream_rows"
  } >"$STREAM_TSV"

  # Rerun streams replace their rows; only cached runs keep theirs
  cached_runs="$(for k in "${!STREAM_CACHED[@]}"; do set -- $k; echo "stream$1-r$2-"; done)"
  {
    head -1 "$TSV"
    {
      tail -n +2 "$TSV" | awk -F'\t' -v runs="$cached_runs" '
        BEGIN { n = split(runs, a, "\n"); for (i = 1; i <= n; i++) c[a[i]] = 1 }
        { if (match($1, /^stream[0-9]+-r[0-9]+-/) && !(substr($1, 1, RLENGTH) in c)) next; print }'
      find "$TMPD" -name 'image_rows_*' -exec cat {} +
    } | sort
  } >"$TSV.tmp" && mv "$TSV.tmp" "$TSV"
  awk -F'\t' 'NR > 1 { split($4, a, "window_hits="); print "  BITNESS=" $1, "READY=" $2, $3, "window_hits=" a[2] }' "$STREAM_TSV"
fi

# Each RTL version gets its own seeds, so a release run explores new stimuli
RANDOM_RUNS="${RANDOM_RUNS:-1500}"
rfail=0
if [ "${STREAM:-1}" = 1 ] && [ "$RANDOM_RUNS" -gt 0 ]; then
  rflags=()
  [ "${RERUN:-0}" = 1 ] && rflags=(--rerun)
  python3 "$HERE/random_stream.py" --no-analyze --rtl-seed --runs "$RANDOM_RUNS" \
    --threads "$NUMBER_OF_THREADS" "${rflags[@]}" || rfail=1
else
  RANDOM_RUNS=0
fi

# A depth that never reaches the merge window proves nothing about image boundaries
sfail=0; vacuous=""
if [ -f "$STREAM_TSV" ]; then
  sfail=$(awk -F'\t' -v v="$STREAM_HASH" 'NR > 1 && $5 == v && $3 != "PASS"' "$STREAM_TSV" | wc -l)
  vacuous="$(awk -F'\t' -v v="$STREAM_HASH" 'NR > 1 && $5 == v { split($4, a, "window_hits="); h[$1] += a[2] } END { for (b in h) if (h[b] == 0) print b }' "$STREAM_TSV" | sort -n | xargs)"
  [ -z "$vacuous" ] || echo "No merge-window hits at BITNESS: $vacuous"
fi

# Status for publish_reports.sh, over the merged table: a row counts only if it
# ran on this RTL and tools, so a capped run on the same RTL keeps its full sweep
read -r tpass tfail tstale tskip < <(awk -F'\t' -v rtl="$RTL_HASH" -v st="$STREAM_HASH" '
  FNR == NR { v[$1] = $2; next }
  FNR > 1 { cur = ($1 ~ /^stream[0-9]+-r[0-9]+-/) ? $8 == st : ($8 == rtl && $9 == v[$1])
            if ($6 == "SKIP") k++; else if (!cur) o++; else if ($6 == "PASS") p++; else f++ }
  END { print p + 0, f + 0, o + 0, k + 0 }' "$TMPD/sums" "$TSV")
gpct=$(awk -v p="$tpass" -v t="$((tpass + tfail))" 'BEGIN{ if (t > 0) printf "%.0f%%", 100 * p / t }')
if [ "$tfail" -ne 0 ] || [ "$sfail" -ne 0 ] || [ "$rfail" -ne 0 ] || [ -n "$vacuous" ]; then status=FAIL
elif [ "$tstale" -ne 0 ] || [ "$RANDOM_RUNS" -eq 0 ]; then status=PARTIAL
else status=PASS; fi
{
  echo "NAME=\"Golden model\""
  echo "NOTE=\"CharLS byte-exact cross-check\""
  echo "STATUS=$status"
  echo "PCT=\"$gpct\""
  echo "SUMMARY=\"$tpass of $((tpass + tfail)) images byte-exact vs CharLS$([ "$RANDOM_RUNS" -eq 0 ] && echo ", random streams not run")$([ "$rfail" -ne 0 ] && echo ", random streams FAILED")$([ "$tstale" -eq 0 ] || echo " ($tstale not run on this RTL)")$([ "$tskip" -gt 0 ] && echo " ($tskip never run)")$([ -z "$vacuous" ] || echo ", no merge-window hits at BITNESS $vacuous")\""
  [ "$RANDOM_RUNS" -gt 0 ] && [ "$rfail" -eq 0 ] && echo "DETAIL=\"$RANDOM_RUNS random streams passed.\""
  echo "DATE=\"$(date -Iseconds)\""
  echo "SOURCES_HASH=$(cat "$ROOT"/Sources/*.vhd | sha256sum | cut -c1-12)"
} > "$HERE/Output/report_status.env"
[ "$status" != PARTIAL ] || echo "STATUS=PARTIAL: $tstale row(s) not run on this RTL, random streams: $RANDOM_RUNS run"
if [ -f "$TMPD/stalls" ]; then
  echo "Internal stalls (pipeline back-pressured with no downstream stall):"
  while IFS=$'\t' read -r s msg; do echo "  -- $s: $msg"; done < "$TMPD/stalls"
fi
if [ "$sfail" -ne 0 ] || [ -n "$vacuous" ]; then
  echo "No-reset streams failed (logs under $STREAM_LOGD):"
  awk -F'\t' 'NR > 1 && $3 != "PASS" { print "  -- BITNESS=" $1 " READY=" $2 ": " $4 }' "$STREAM_TSV"
fi
if [ "$fail" -ne 0 ] || [ "$tfail" -ne 0 ] || [ "$sfail" -ne 0 ] || [ "$rfail" -ne 0 ] || [ -n "$vacuous" ]; then
  if [ -f "$TMPD/failures" ]; then
    echo "Failing images (logs under $LOGD):"
    while IFS= read -r s; do
      echo "  -- $s"; grep -iE "RESULT|mismatch|error" "$LOGD/$s.log" 2>/dev/null | head -4 | sed 's/^/     /' || true
    done < "$TMPD/failures"
  fi
  echo "Golden-model suite: FAIL"
  exit 1
fi
echo "Golden-model suite: PASS"
