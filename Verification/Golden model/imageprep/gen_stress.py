#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""Deterministic 16-bit byte_stuffer stall probes (random + adversarial).

The compatibility byte_stuffer drains at most 4 B/cycle. LIMIT-length words
can exceed that service rate (stuffing adds bits even at 8-bit precision).
Earlier random/checker/stripe/spike tests showed no internal stalls. That is
simulation evidence for those images, not a bound on every possible image.

Full-scale 0/65535 patterns are weak error probes: modulo reduction maps a
65535 prediction error to -1. Use --level 32768 to exercise large residuals
without changing the 16-bit sample precision. --pattern shock trains small
errors before switching abruptly to half-range noise, stressing k adaptation.

Patterns (full-scale = --maxval, default 65535):
  random   uniform noise in [0, maxval] (incompressible; --seed controls it)
  checker  1px checkerboard 0/max        -- MED predictor wrong full-scale every px
  vstripe  alternating columns 0/max     -- vertical 1px stripes
  hstripe  alternating rows 0/max        -- horizontal 1px stripes
  spikes   max spikes on a flat field    -- sparse max where x%3==0 and y%3==0
  flat     all zeros                     -- pure run mode; every run ends at EOL

--maxval sets the sample precision (must be 2^N - 1, N in 8..16; the golden TB
asserts maxval = 2^BITNESS - 1). The T.87 constants (LIMIT, k range, counter
widths) all derive from BITNESS, and no natural dataset exists at 9-15 bits --
these probes are the only coverage of those derivations.

--width/--height override --size for non-square boundary images (minimal
4x1, min-width-tall, max-width single line). OpenJLS requires width >= 4 and
height >= 1 by design; 1x1 is not supported, and the generator refuses it.

--fuzz-batch N treats OUT as a directory and emits N tiny random images with
master-seeded dimensions in [4..16] x [1..8]. Small random images make the
LAST pixel's context first-use 20-60% of the time -- the shape that exposed
the context_ram EOI init-lookup bug (b513990) which 163 natural images never
reached. Tiny, so the whole batch adds negligible sim time.

Seeded => byte-reproducible across runs/hosts, so the committed generator is the
source of truth for Images/ files that are otherwise gitignored.
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
    raise ValueError(pat)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", help="output PGM path")
    ap.add_argument("--size", type=int, default=256, help="square edge length (px)")
    ap.add_argument("--width", type=int, help="image width (px); overrides --size")
    ap.add_argument("--height", type=int, help="image height (px); overrides --size")
    ap.add_argument("--pattern", default="random",
                    choices=["random", "checker", "vstripe", "hstripe", "spikes", "flat", "shock"])
    ap.add_argument("--level", type=int, help="structured-pattern high value (precision stays --maxval)")
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
    level = mx if a.level is None else a.level
    if not 0 <= level <= mx:
        ap.error("--level must be in [0, maxval]")
    fmt = ">H" if mx > 255 else "B"
    if a.pattern == "shock":
        rng = random.Random(a.seed)
        payload = bytearray()
        for y in range(h):
            for x in range(w):
                # Repeated training/shock bands; training visits many low-k
                # gradient contexts. Half-range jumps avoid modulo wrap to -1.
                v = rng.randrange(min(mx + 1, 256))
                if y % 64 >= 56:
                    v += rng.randrange(2) * ((mx + 1) // 2)
                payload += struct.pack(fmt, v)
        tag = f"shock (seed {a.seed:#06x})"
    elif a.pattern == "random":
        if mx == 65535:
            payload = random.Random(a.seed).randbytes(w * h * 2)  # big-endian-agnostic
        else:
            rng = random.Random(a.seed)
            payload = b"".join(struct.pack(fmt, rng.randint(0, mx))
                               for _ in range(w * h))
        tag = f"random (seed {a.seed:#06x})"
    else:
        payload = bytearray()
        for y in range(h):
            for x in range(w):
                payload += struct.pack(fmt, pattern_value(a.pattern, x, y, level))
        tag = a.pattern

    n = write_pgm(a.out, w, h, payload, mx)
    print(f"{a.out}: {w}x{h} {mx.bit_length()}-bit {tag}, {n} B")


if __name__ == "__main__":
    main()
