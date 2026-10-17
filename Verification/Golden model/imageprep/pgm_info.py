#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""Print "WIDTH HEIGHT MAXVAL BITS" for a binary PGM (P5)."""
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
    with open(sys.argv[1], "rb") as f:
        magic = read_token(f)
        if magic != b"P5":
            sys.exit(f"not a binary PGM (magic={magic!r})")
        w = int(read_token(f))
        h = int(read_token(f))
        mx = int(read_token(f))
    print(w, h, mx, mx.bit_length())


if __name__ == "__main__":
    main()
