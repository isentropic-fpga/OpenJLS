#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""Same-size image sets for the no-reset stream sweep, one directory per depth
and ready level. No image repeats within a depth.

Mostly natural crops, plus noise, ramps and flats so that images ending in long
runs meet images that start emitting at once. File order is the stream order.
3% ready gets more images, since hits per image are few, and 8-bit the most: its
merge window is about 10x rarer.

Noise comes from SHAKE-256, so it doesn't depend on numpy or Python versions, and
is checked against stream_noise.sha256.

Usage: gen_stream_set.py <full-size dir> <out dir>
"""
import argparse
import hashlib
import random
from pathlib import Path

import numpy as np

from gen_depth_tiles import read_pgm16

DEPTHS = range(8, 17)
KINDS = ["natural"] * 7 + ["noise", "ramp", "flat"]
READY_PCTS = (100, 3)
WIDTH, HEIGHT = 256, 64
COUNT, COUNT_3, COUNT_8_3 = 200, 400, 1000
SEED = 0x57E3
NOISE_HASHES = Path(__file__).with_name("stream_noise.sha256")


def noise(b, index):
    raw = hashlib.shake_256(f"openjls-stream-{SEED}-{b}-{index}".encode()).digest(2 * WIDTH * HEIGHT)
    return (np.frombuffer(raw, dtype=">u2") & ((1 << b) - 1)).reshape(HEIGHT, WIDTH)


def make(kind, rng, imgs, names, b, noise_index):
    mx = (1 << b) - 1
    if kind == "natural":
        src = imgs[rng.choice(names)]
        y0, x0 = rng.randint(0, src.shape[0] - HEIGHT), rng.randint(0, src.shape[1] - WIDTH)
        return src[y0:y0 + HEIGHT, x0:x0 + WIDTH] >> (16 - b)
    if kind == "noise":
        return noise(b, noise_index)
    if kind == "ramp":
        return (np.add.outer(np.arange(HEIGHT), np.arange(WIDTH)) * rng.randint(1, 8)) & mx
    return np.full((HEIGHT, WIDTH), rng.randint(0, mx))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("full", type=Path)
    ap.add_argument("out", type=Path)
    a = ap.parse_args()

    srcs = sorted(a.full.glob("ic-gray16_*.pgm"))
    if not srcs:
        raise SystemExit(f"no ic-gray16_*.pgm in {a.full}")
    imgs = {p.stem: read_pgm16(p) for p in srcs}
    names = sorted(imgs)

    hashes = {}
    for b in DEPTHS:
        rng = random.Random(SEED + b)
        seen = set()
        noise_index = 0
        for pct in READY_PCTS:
            name = f"{b}-r{pct}"
            d = a.out / name
            d.mkdir(parents=True, exist_ok=True)
            noise_hash = hashlib.sha256()
            n = COUNT if pct != 3 else COUNT_8_3 if b == 8 else COUNT_3
            for i in range(n):
                while True:
                    kind = rng.choice(KINDS)
                    px = make(kind, rng, imgs, names, b, noise_index)
                    raw = px.astype("u1" if b == 8 else ">u2").tobytes()
                    digest = hashlib.sha256(raw).digest()
                    if digest not in seen:
                        break
                seen.add(digest)
                if kind == "noise":
                    noise_hash.update(raw)
                    noise_index += 1
                with open(d / f"{i:04d}-{kind}.pgm", "wb") as f:
                    f.write(f"P5\n{WIDTH} {HEIGHT}\n{(1 << b) - 1}\n".encode())
                    f.write(raw)
            hashes[name] = noise_hash.hexdigest()

    expected = dict(line.split() for line in NOISE_HASHES.read_text().splitlines())
    if hashes != expected:
        got = "\n".join(f"{k} {v}" for k, v in hashes.items())
        raise SystemExit(f"noise images differ from {NOISE_HASHES.name}; generated:\n{got}")
    print(f"{COUNT} {WIDTH}x{HEIGHT} images per depth at 100% ready; {COUNT_3} at 3%, {COUNT_8_3} at 8-bit; noise hashes match")


if __name__ == "__main__":
    main()
