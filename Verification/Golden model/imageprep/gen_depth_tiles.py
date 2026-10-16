#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""Natural-texture tiles at every depth 9..16 from the 16-bit photo set.

Each tile is a crop of random size and position from one of the full-range
16-bit sources, right-shifted to the target depth. Sources rotate so every
depth sees every photo. Small tiles keep the whole batch under the routine
MAX_MP cap. Seeded, so the committed script is the source of truth for the
gitignored Images/ files.

Usage: gen_depth_tiles.py <full-size dir> <Images dir> [--per-depth N] [--seed S]
"""
import argparse
import random
from pathlib import Path

import numpy as np

DEPTHS = range(9, 17)
W_RANGE, H_RANGE = (4, 640), (1, 384)


def read_pgm16(path):
    data = path.read_bytes()
    _, dims, mx, raw = data.split(b"\n", 3)
    w, h = map(int, dims.split())
    assert int(mx) == 65535, f"{path}: not 16-bit"
    return np.frombuffer(raw[: w * h * 2], dtype=">u2").reshape(h, w)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("full", type=Path)
    ap.add_argument("images", type=Path)
    ap.add_argument("--per-depth", type=int, default=300)
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=0xD3D7)
    a = ap.parse_args()

    srcs = sorted(a.full.glob("ic-gray16_*.pgm"))
    if not srcs:
        raise SystemExit(f"no ic-gray16_*.pgm in {a.full}")
    imgs = {p.stem.removeprefix("ic-gray16_"): read_pgm16(p) for p in srcs}
    names = sorted(imgs)

    rng = random.Random(a.seed)
    total_px = 0
    for b in DEPTHS:
        for i in range(a.per_depth):
            name = names[i % len(names)]
            src = imgs[name]
            sh, sw = src.shape
            w = rng.randint(*W_RANGE)
            h = rng.randint(*H_RANGE)
            x0, y0 = rng.randint(0, sw - w), rng.randint(0, sh - h)
            tile = src[y0:y0 + h, x0:x0 + w] >> (16 - b)
            out = a.images / f"tile{b}-{name}-{i:03d}.pgm"
            with open(out, "wb") as f:
                f.write(f"P5\n{w} {h}\n{(1 << b) - 1}\n".encode())
                f.write(tile.astype(">u2").tobytes())
            total_px += w * h
    n = len(DEPTHS) * a.per_depth
    print(f"{n} depth tiles ({a.per_depth} x {DEPTHS.start}..{DEPTHS.stop - 1} bit), "
          f"{total_px / 1e6:.1f} MP total")


if __name__ == "__main__":
    main()
