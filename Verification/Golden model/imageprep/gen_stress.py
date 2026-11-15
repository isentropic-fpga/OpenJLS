#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""Seeded stress and boundary PGMs.

Patterns (full-scale = --maxval, default 65535):
  random   uniform noise (--seed)
  checker  1px checkerboard 0/max
  vstripe  alternating columns 0/max
  hstripe  alternating rows 0/max
  spikes   max where x%3==0 and y%3==0, else 0
  flat     all zeros, pure run mode
  longrun  zeros, with a 1 at x = 40000 in odd rows; RUNindex reaches 31 and interrupts there
  maxctx-neg, maxctx-pos  every sample of one context gets the largest Errval of that sign

--maxval must be 2^N - 1, N in 8..16. --width/--height override --size;
width >= 4. --fuzz-batch N writes N images of [4..16] x [1..8] into OUT.
"""
import argparse
import os
import random
import struct


def write_pgm(path, w, h, payload, maxval=65535):
    header = f"P5\n{w} {h}\n{maxval}\n".encode()
    with open(path, "wb") as f:
        f.write(header + payload)
    return len(header) + len(payload)


def pattern_value(pat, x, y, mx):
    if pat == "checker":
        return mx if (x + y) & 1 else 0
    if pat == "vstripe":
        return mx if x & 1 else 0
    if pat == "hstripe":
        return mx if y & 1 else 0
    if pat == "spikes":
        return mx if (x % 3 == 0 and y % 3 == 0) else 0
    if pat == "flat":
        return 0
    if pat == "longrun":
        return int(y % 2 == 1 and x == 40000)
    raise ValueError(pat)


def maxctx(w, h, mx, neg):
    """Largest A (neg) and C saturation for context (4, 0, 4). Rows: 0 flat, then odd = setup, even = target."""
    rng, half = mx + 1, (mx + 1) // 2
    f = (min(mx, 4095) + 128) // 256
    t1, t2, t3 = f + 2, 4 * f + 3, 17 * f + 4
    def q(g):
        m = abs(g)
        v = 0 if m == 0 else 1 if m < t1 else 2 if m < t2 else 3 if m < t3 else 4
        return v if g >= 0 else -v
    v0, gap, a0 = int(rng * 0.85), int(rng * 0.1), int(rng * 0.45)
    a1 = a0 + gap
    img = [[0] * w for _ in range(h)]
    aq, bq, cq, nq = max(2, (rng + 32) // 64), 0, 0, 1
    peak_a, cmin, cmax, hits = 0, 0, 0, 0
    for y in range(1, h):
        for x in range(w):
            c4 = x % 4
            if y % 2:
                img[y][x] = (v0, v0 + gap, v0 + gap // 2, v0)[c4]
                continue
            img[y][x] = a1 if c4 == 2 else a0
            if c4 or not x:
                continue
            ra = img[y][x - 1]
            px = max(0, min(mx, ra + cq))
            ix = px + (half if neg else half - 1)
            if ix > mx:
                ix -= rng
            img[y][x] = ix
            e = ix - px
            e = e + rng if e < 0 else e
            e = e - rng if e >= (rng + 1) // 2 else e
            hits += 1
            aq += abs(e)
            peak_a = max(peak_a, aq)
            bq += e
            if nq == 64:
                aq >>= 1
                bq = bq >> 1 if bq >= 0 else -((1 - bq) >> 1)
                nq >>= 1
            nq += 1
            if bq <= -nq:
                bq += nq
                cq = max(-128, cq - 1)
                bq = max(bq, -nq + 1)
            elif bq > 0:
                bq -= nq
                cq = min(127, cq + 1)
                bq = min(bq, 0)
            cmin, cmax = min(cmin, cq), max(cmax, cq)
    seen = 0
    for y in range(1, h):
        for x in range(w):
            ra = img[y][x - 1] if x else img[y - 1][0]
            rb, rc = img[y - 1][x], img[y - 1][x - 1] if x else (img[y - 2][0] if y > 1 else 0)
            rd = img[y - 1][x + 1] if x + 1 < w else rb
            t = (q(rd - rb), q(rb - rc), q(rc - ra))
            seen += t in ((4, 0, 4), (-4, 0, -4))
    if seen != hits:
        raise SystemExit(f"maxctx: context hit by {seen - hits} other samples")
    print(f"maxctx: {hits} samples, peak A {peak_a}, C {cmin}..{cmax}")
    return img


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", help="output PGM path")
    ap.add_argument("--size", type=int, default=256, help="square edge length (px)")
    ap.add_argument("--width", type=int, help="image width (px); overrides --size")
    ap.add_argument("--height", type=int, help="image height (px); overrides --size")
    ap.add_argument("--pattern", default="random",
                    choices=["random", "checker", "vstripe", "hstripe", "spikes", "flat", "longrun",
                             "maxctx-neg", "maxctx-pos"])
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=0x0FF5,
                    help="PRNG seed for --pattern random; accepts 0x.. hex")
    ap.add_argument("--maxval", type=lambda s: int(s, 0), default=65535,
                    help="sample precision as 2^N - 1, N in 8..16 (default 65535)")
    ap.add_argument("--fuzz-batch", type=int, metavar="N",
                    help="treat OUT as a directory; emit N tiny random images "
                         "(dims master-seeded from --seed)")
    a = ap.parse_args()

    if a.fuzz_batch is not None:
        if a.fuzz_batch < 1:
            ap.error("--fuzz-batch: N must be >= 1")
        os.makedirs(a.out, exist_ok=True)
        rng = random.Random(a.seed)
        for i in range(1, a.fuzz_batch + 1):
            w, h = rng.randint(4, 16), rng.randint(1, 8)
            path = os.path.join(a.out, f"synth-fuzz-{w}x{h}-{i:02d}.pgm")
            n = write_pgm(path, w, h, rng.randbytes(w * h * 2))
            print(f"{path}: {w}x{h} 16-bit random, {n} B")
        return

    w = a.width if a.width is not None else a.size
    h = a.height if a.height is not None else a.size
    if w < 4 or h < 1:
        ap.error(f"{w}x{h}: OpenJLS requires width >= 4 and height >= 1 by design")
    mx = a.maxval
    if mx < 255 or mx > 65535 or (mx & (mx + 1)) != 0:
        ap.error(f"--maxval {mx}: must be 2^N - 1 with N in 8..16")
    fmt = ">H" if mx > 255 else "B"
    if a.pattern == "random":
        if mx == 65535:
            payload = random.Random(a.seed).randbytes(w * h * 2)
        else:
            rng = random.Random(a.seed)
            payload = b"".join(struct.pack(fmt, rng.randint(0, mx))
                               for _ in range(w * h))
        tag = f"random (seed {a.seed:#06x})"
    elif a.pattern.startswith("maxctx"):
        img = maxctx(w, h, mx, a.pattern.endswith("neg"))
        payload = b"".join(struct.pack(fmt, v) for row in img for v in row)
        tag = a.pattern
    else:
        payload = bytearray()
        for y in range(h):
            for x in range(w):
                payload += struct.pack(fmt, pattern_value(a.pattern, x, y, mx))
        tag = a.pattern

    n = write_pgm(a.out, w, h, payload, mx)
    print(f"{a.out}: {w}x{h} {mx.bit_length()}-bit {tag}, {n} B")


if __name__ == "__main__":
    main()
