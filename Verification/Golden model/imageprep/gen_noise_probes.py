#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""White and 1/f^beta (smoothed) noise probes at every depth 8..16.

Per depth, half white noise and half coloured noise: Gaussian noise shaped in
the frequency domain to a 1/f^beta spectrum, beta in [0.5, 4] (pink ~1, brown
~2, smooth gradients above). Each probe also draws a random size and a random
value window (log-uniform span, random offset), so the set spans
incompressible noise down to near-flat run-mode content. Seeded per file.

Usage: gen_noise_probes.py <Images dir> [--per-depth N] [--seed S]
"""
import argparse
from pathlib import Path

import numpy as np

DEPTHS = range(8, 17)
W_RANGE, H_RANGE = (4, 640), (1, 384)
BETA_RANGE = (0.5, 4.0)


def window(rng, b):
    """Random value window [lo, lo + span] inside the b-bit range."""
    mx = (1 << b) - 1
    span = min(mx, max(1, int(round(2 ** rng.uniform(1, b))) - 1))
    lo = int(rng.integers(0, mx - span + 1))
    return lo, span


def coloured(rng, h, w, beta):
    """Unit-range 1/f^beta noise via spectral shaping."""
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.rfftfreq(w)[None, :]
    f = np.hypot(fx, fy)
    f[0, 0] = np.inf                       # drop DC
    spec = np.fft.rfft2(rng.standard_normal((h, w))) / f ** (beta / 2)
    img = np.fft.irfft2(spec, s=(h, w))
    lo, hi = img.min(), img.max()
    return (img - lo) / (hi - lo) if hi > lo else np.zeros((h, w))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("images", type=Path)
    ap.add_argument("--per-depth", type=int, default=300)
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=0x401E)
    a = ap.parse_args()

    total_px = 0
    for b in DEPTHS:
        for i in range(a.per_depth):
            rng = np.random.default_rng([a.seed, b, i])
            w, h = int(rng.integers(*W_RANGE, endpoint=True)), int(rng.integers(*H_RANGE, endpoint=True))
            lo, span = window(rng, b)
            if i < a.per_depth // 2:
                kind = "white"
                img = rng.integers(lo, lo + span, size=(h, w), endpoint=True)
            else:
                kind = "smooth"
                img = lo + np.rint(coloured(rng, h, w, rng.uniform(*BETA_RANGE)) * span)
            out = a.images / f"noise{b}-{kind}-{i:03d}.pgm"
            with open(out, "wb") as f:
                f.write(f"P5\n{w} {h}\n{(1 << b) - 1}\n".encode())
                f.write(img.astype(">u2" if b > 8 else "u1").tobytes())
            total_px += w * h
    print(f"{len(DEPTHS) * a.per_depth} noise probes ({a.per_depth} x "
          f"{DEPTHS.start}..{DEPTHS.stop - 1} bit), {total_px / 1e6:.1f} MP total")


if __name__ == "__main__":
    main()
