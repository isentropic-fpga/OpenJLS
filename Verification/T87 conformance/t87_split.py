#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#
"""Split T8C0E0.JLS into one single-component .JLS per scan.

Contexts restart per scan, so each scan is the encode of TEST8R, G or B alone.
The scan bytes are official. SOF and SOS are rebuilt for one component with id 1.
usage: t87_split.py <reference dir> <output dir>
"""
import sys
from pathlib import Path


def main(ref, out):
    d = (ref / "T8C0E0.JLS").read_bytes()
    assert d[:2] == b"\xff\xd8", "no SOI"
    i, sof, scans = 2, None, []
    while d[i:i + 2] != b"\xff\xd9":
        assert d[i] == 0xFF, f"no marker at {i}"
        marker, length = d[i + 1], int.from_bytes(d[i + 2:i + 4], "big")
        body = d[i + 4:i + 2 + length]
        i += 2 + length
        if marker == 0xF7:
            sof = body
        elif marker == 0xDA:
            j = i
            # Inside a scan, FF is followed by a byte with MSB 0
            while not (d[j] == 0xFF and d[j + 1] & 0x80):
                j += 1
            scans.append(d[i:j])
            i = j
    assert sof is not None and sof[5] == 3 and len(scans) == 3, "not a 3-scan frame"
    for c, scan in zip("RGB", scans):
        s = b"\xff\xd8\xff\xf7\x00\x0b" + sof[:5] + b"\x01\x01\x11\x00"
        s += b"\xff\xda\x00\x08\x01\x01\x00\x00\x00\x00" + scan + b"\xff\xd9"
        (out / f"T8C0E0_{c}.JLS").write_bytes(s)


main(Path(sys.argv[1]), Path(sys.argv[2]))
