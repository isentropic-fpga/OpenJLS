#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""Replace every PGM over the MP cap with full-width strips.

Top, middle and bottom strips of at most ROWS rows; the original moves to the
full-size directory. Line width stresses the RTL, extra rows only repeat it.

Usage: slice_large.py <Images dir> <full-size dir> [--max-mp 0.5]
"""
import argparse
import shutil
from pathlib import Path

STRIPS, ROWS = 3, 64


def read_pgm(path):
    data = path.read_bytes()
    _, dims, mx, raw = data.split(b"\n", 3)
    w, h = map(int, dims.split())
    return w, h, int(mx), raw[: w * h * (2 if int(mx) > 255 else 1)]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("images", type=Path)
    ap.add_argument("full", type=Path)
    ap.add_argument("--max-mp", type=float, default=0.5)
    a = ap.parse_args()
    a.full.mkdir(parents=True, exist_ok=True)

    n = 0
    for pgm in sorted(a.images.glob("*.pgm")):
        w, h, mx, raw = read_pgm(pgm)
        if w * h <= a.max_mp * 1e6:
            continue
        rows = min(ROWS, int(a.max_mp * 1e6) // w, h)
        bpl = w * (2 if mx > 255 else 1)
        for k, y0 in enumerate((0, (h - rows) // 2, h - rows)[:STRIPS]):
            out = a.images / f"{pgm.stem}-strip{k}.pgm"
            with open(out, "wb") as f:
                f.write(f"P5\n{w} {rows}\n{mx}\n".encode())
                f.write(raw[y0 * bpl:(y0 + rows) * bpl])
        shutil.move(pgm, a.full / pgm.name)
        n += 1
    print(f"sliced {n} image(s) over {a.max_mp} MP into {STRIPS} strips each")


if __name__ == "__main__":
    main()
