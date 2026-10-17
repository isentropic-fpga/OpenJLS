#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""Requantize a binary PGM to a lower bit depth, with an optional centered crop.

Natural 9..15-bit images by right-shifting the 16-bit set; the crop keeps them
under MAX_MP.
"""
import argparse
import array
import sys


def read_token(f) -> bytes:
    tok = b""
    while True:
        c = f.read(1)
        if not c:
            break
        if c == b"#":
            f.readline()
            continue
        if c.isspace():
            if tok:
                break
            continue
        tok += c
    return tok


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", help="source PGM (P5)")
    ap.add_argument("out", help="output PGM path")
    ap.add_argument("--bits", type=int, required=True,
                    help="target sample precision (8..16)")
    ap.add_argument("--crop", type=int, nargs=2, metavar=("W", "H"),
                    help="centered crop to WxH before requantizing")
    a = ap.parse_args()

    with open(a.src, "rb") as f:
        if read_token(f) != b"P5":
            sys.exit(f"{a.src}: not a binary PGM")
        sw, sh, smx = int(read_token(f)), int(read_token(f)), int(read_token(f))
        body = f.read()

    sbits = smx.bit_length()
    if not 8 <= a.bits <= sbits:
        sys.exit(f"--bits {a.bits}: must be in 8..{sbits} (source is {sbits}-bit)")
    w, h = (a.crop if a.crop else (sw, sh))
    if w < 4 or h < 1:
        sys.exit(f"{w}x{h}: OpenJLS requires width >= 4 and height >= 1 by design")
    if w > sw or h > sh:
        sys.exit(f"--crop {w}x{h}: exceeds source {sw}x{sh}")

    src = array.array("H" if smx > 255 else "B")
    src.frombytes(body[: sw * sh * src.itemsize])
    if smx > 255 and sys.byteorder == "little":
        src.byteswap()           # PGM is big-endian

    x0, y0 = (sw - w) // 2, (sh - h) // 2
    shift = sbits - a.bits
    dst = array.array("H" if a.bits > 8 else "B",
                      (src[(y0 + y) * sw + x0 + x] >> shift
                       for y in range(h) for x in range(w)))
    if a.bits > 8 and sys.byteorder == "little":
        dst.byteswap()

    mx = (1 << a.bits) - 1
    header = f"P5\n{w} {h}\n{mx}\n".encode()
    with open(a.out, "wb") as f:
        f.write(header + dst.tobytes())
    print(f"{a.out}: {w}x{h} {a.bits}-bit from {a.src} ({sbits}-bit), "
          f"{len(header) + len(dst) * dst.itemsize} B")


if __name__ == "__main__":
    main()
