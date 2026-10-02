#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Image ingestion + normalization for the golden-model conformance suite.
#
# Converges "Images/" to single-component grayscale binary PGMs, ready for the
# golden TB and CharLS. Two stages:
#   1. fetch     download + extract the curated public datasets (USC-SIPI +
#                imagecompression.info grayscale sets) into Images/
#   2. normalize convert every image in Images/ to grayscale PGM, in place,
#                deleting the original color / non-PGM sources
#
# Drop-in friendly: put your own images (any format, color or gray) into
# Images/ and run with --no-fetch to fold them into the suite.
#
# Usage:
#   ./prepare_images.sh             # fetch curated datasets, then normalize
#   ./prepare_images.sh --no-fetch  # normalize whatever is already in Images/
#
# Env:
#   IMG_CACHE=<dir>   reuse already-downloaded dataset zips (by basename)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGES="$HERE/Images"
PREP="$HERE/imageprep"

FETCH=1
[ "${1:-}" = "--no-fetch" ] && FETCH=0

mkdir -p "$IMAGES"

if [ "$FETCH" -eq 1 ]; then
  echo "== fetch =="
  python3 "$PREP/fetch.py" "$IMAGES"
fi

echo "== normalize =="
python3 "$PREP/normalize.py" "$IMAGES"

# 16-bit byte_stuffer stall probes: random noise (several seeds) + adversarial
# patterns (checkerboard/stripes/spikes). Built to try to overrun the byte_stuffer
# 4 B/cycle cap. No stalls were observed in the original runs; this is not
# a proof of a worst-case bound. They remain useful robustness probes. Generated after normalize
# (already in target form; must not be down-converted). See imageprep/gen_stress.py.
echo "== random 16-bit probes =="
i=1
for seed in 0x0FF5 0x1234 0xBEEF; do
  python3 "$PREP/gen_stress.py" "$IMAGES/synth-rand16_$i.pgm" --pattern random --seed "$seed"
  i=$((i + 1))
done
# Avoid the modulo-wrap weakness of 0/65535 probes. Keep precision at 16
# bits while using quarter/half-range values; train low-k contexts then shock.
echo "== stuffer rate probes =="
for pattern in checker vstripe hstripe spikes; do
  for level in 16384 32768 49152; do
    python3 "$PREP/gen_stress.py" "$IMAGES/stuffer-probe-$pattern-$level.pgm" \
      --pattern "$pattern" --level "$level"
  done
done
for seed in 0 1 2 3 4 5 6 7; do
  for pattern in random shock; do
    python3 "$PREP/gen_stress.py" "$IMAGES/stuffer-probe-$pattern-$seed.pgm" \
      --pattern "$pattern" --seed "$seed" --width 1024 --height 64
  done
done

echo "== adversarial 16-bit probes =="
for pat in checker vstripe hstripe spikes; do
  python3 "$PREP/gen_stress.py" "$IMAGES/synth-$pat-16.pgm" --pattern "$pat"
done

# Boundary-dimension probes — natural images never hit these shapes. Minimal
# legal image (width >= 4, height >= 1 is the design floor; 1x1 unsupported),
# min-width-tall (an EOL every 4 px), odd just-above-min dims, and max-width
# lines (65535 = T.87 SOF55 2-byte dimension field cap). random exercises
# regular mode; flat is all-zero => pure run mode, every run cut by EOL.
echo "== boundary-dimension probes =="
gen_bound() {
  python3 "$PREP/gen_stress.py" "$IMAGES/synth-bound-${1}x${2}-$3.pgm" \
    --width "$1" --height "$2" --pattern "$3"
}
gen_bound 4 1 random
gen_bound 4 1 flat
gen_bound 4 1024 random
gen_bound 4 1024 flat
gen_bound 5 3 random
gen_bound 7 1 random
gen_bound 65535 1 random
gen_bound 65535 2 random

# Tiny-random-image fuzz batch — small images make the last pixel's context
# first-use often, the shape that exposed the context_ram EOI bug (b513990).
echo "== tiny-image fuzz batch =="
python3 "$PREP/gen_stress.py" "$IMAGES" --fuzz-batch 16 --seed 0xB513

# Intermediate-depth probes (9-15 bits): the T.87 constants (LIMIT, k range,
# counter widths) all derive from BITNESS, but the natural sets are 8/16-bit
# only and the T.87 vector covers just 12. Random + checker per depth, plus
# natural texture requantized from the 16-bit set (cropped under the routine
# 0.5 MP cap).
echo "== intermediate-depth probes =="
for b in 9 10 11 12 13 14 15; do
  mx=$(( (1 << b) - 1 ))
  python3 "$PREP/gen_stress.py" "$IMAGES/synth-rand${b}_1.pgm" --pattern random --maxval "$mx"
  python3 "$PREP/gen_stress.py" "$IMAGES/synth-checker-$b.pgm" --pattern checker --maxval "$mx"
done
python3 "$PREP/requantize.py" "$IMAGES/ic-gray16_cathedral.pgm" "$IMAGES/requant10-cathedral.pgm" --bits 10 --crop 700 700
python3 "$PREP/requantize.py" "$IMAGES/ic-gray16_deer.pgm" "$IMAGES/requant14-deer.pgm" --bits 14 --crop 700 700

echo "Images ready: $(find "$IMAGES" -name '*.pgm' | wc -l) PGM(s) in $IMAGES"
