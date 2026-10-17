#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""Convert every image in <dir> to a grayscale binary PGM in place, keeping
the bit depth (Rec.601 luma for color). P5 files are left alone; the original
is deleted once its .pgm is written.

Usage: normalize.py <dir>
"""
import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image

# The datasets trip Pillow's decompression-bomb guard
Image.MAX_IMAGE_PIXELS = None

SIXTEEN_BIT_MODES = {"I", "I;16", "I;16B", "I;16L", "I;16N"}


def is_binary_pgm(path: Path) -> bool:
    try:
        with open(path, "rb") as f:
            return f.read(2) == b"P5"
    except OSError:
        return False


def to_gray_array(im: Image.Image):
    """Return (HxW ndarray, maxval), single component, bit depth preserved."""
    single = len(im.getbands()) == 1
    sixteen = im.mode in SIXTEEN_BIT_MODES

    if single and sixteen:
        return np.asarray(im, dtype=np.uint32).astype(np.uint16), 65535
    if single:
        return np.asarray(im.convert("L"), dtype=np.uint8), 255

    # Pillow drops 16-bit color to 8-bit RGB first; none of the sets have any
    rgb = np.asarray(im.convert("RGB"), dtype=np.float64)
    luma = rgb[..., 0] * 0.299 + rgb[..., 1] * 0.587 + rgb[..., 2] * 0.114
    return np.clip(luma + 0.5, 0, 255).astype(np.uint8), 255


def write_pgm(arr: np.ndarray, maxval: int, out: Path) -> None:
    h, w = arr.shape
    dtype = ">u2" if maxval > 255 else ">u1"
    tmp = out.with_name(out.name + ".tmp")
    with open(tmp, "wb") as f:
        f.write(f"P5\n{w} {h}\n{maxval}\n".encode("ascii"))
        f.write(arr.astype(dtype).tobytes())
    os.replace(tmp, out)  # safe when out == source


def normalize_dir(root: Path):
    converted = removed = skipped = 0
    for p in sorted(root.rglob("*")):
        if not p.is_file() or p.name.endswith(".tmp"):
            continue
        if p.suffix.lower() == ".pgm" and is_binary_pgm(p):
            skipped += 1
            continue
        try:
            with Image.open(p) as im:
                im.load()
                arr, maxval = to_gray_array(im)
        except Exception:
            continue
        out = p.with_suffix(".pgm")
        write_pgm(arr, maxval, out)
        converted += 1
        if p != out:
            p.unlink()
            removed += 1
    return converted, removed, skipped


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    if not root.is_dir():
        sys.exit(f"normalize: not a directory: {root}")
    converted, removed, skipped = normalize_dir(root)
    print(f"normalized: converted={converted} removed_originals={removed} "
          f"already_pgm={skipped}")


if __name__ == "__main__":
    main()
