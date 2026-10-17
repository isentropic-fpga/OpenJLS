#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Fill Images/ with grayscale PGMs: the USC-SIPI and imagecompression.info sets
# plus generated probes. Own images (any format) dropped into Images/ are
# converted in place; --no-fetch skips the download, IMG_CACHE=<dir> reuses zips.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGES="$HERE/Images"
PREP="$HERE/imageprep"
FULL="$HERE/Images_full"

FETCH=1
[ "${1:-}" = "--no-fetch" ] && FETCH=0

mkdir -p "$IMAGES"

if [ "$FETCH" -eq 1 ]; then
  echo "== fetch =="
  python3 "$PREP/fetch.py" "$IMAGES"
fi

echo "== normalize =="
python3 "$PREP/normalize.py" "$IMAGES"

# Over 0.5 MP: three <= 64-row strips; originals move to Images_full/
echo "== slice large images =="
python3 "$PREP/slice_large.py" "$IMAGES" "$FULL"

# Attempts to overrun the byte_stuffer 4 B/cycle cap. Generated after normalize
# so they are not down-converted.
echo "== random 16-bit probes =="
i=1
for seed in 0x0FF5 0x1234 0xBEEF; do
  python3 "$PREP/gen_stress.py" "$IMAGES/synth-rand16_$i.pgm" --pattern random --seed "$seed"
  i=$((i + 1))
done
echo "== adversarial 16-bit probes =="
for pat in checker vstripe hstripe spikes; do
  python3 "$PREP/gen_stress.py" "$IMAGES/synth-$pat-16.pgm" --pattern "$pat"
done

# Dimension floor (4x1), max width (65535) and odd sizes; flat is all run mode
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

# Tiny images often hit a first-use context on the last pixel (b513990)
echo "== tiny-image fuzz batch =="
python3 "$PREP/gen_stress.py" "$IMAGES" --fuzz-batch 16 --seed 0xB513

# 9 to 15 bits; the natural sets are 8/16-bit only
echo "== intermediate-depth probes =="
for b in 9 10 11 12 13 14 15; do
  mx=$(( (1 << b) - 1 ))
  python3 "$PREP/gen_stress.py" "$IMAGES/synth-rand${b}_1.pgm" --pattern random --maxval "$mx"
  python3 "$PREP/gen_stress.py" "$IMAGES/synth-checker-$b.pgm" --pattern checker --maxval "$mx"
done
python3 "$PREP/requantize.py" "$FULL/ic-gray16_cathedral.pgm" "$IMAGES/requant10-cathedral.pgm" --bits 10 --crop 700 700
python3 "$PREP/requantize.py" "$FULL/ic-gray16_deer.pgm" "$IMAGES/requant14-deer.pgm" --bits 14 --crop 700 700

# ~300 crops of the 16-bit photos per depth, 9..16 bits
echo "== depth tiles =="
python3 "$PREP/gen_depth_tiles.py" "$FULL" "$IMAGES"

# ~300 white and 1/f noise images per depth, 8..16 bits
echo "== noise probes =="
python3 "$PREP/gen_noise_probes.py" "$IMAGES"

echo "Images ready: $(find "$IMAGES" -name '*.pgm' | wc -l) PGM(s) in $IMAGES"
