#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""Download the curated datasets flat into <dest>, prefixed per dataset so
same-named files don't clash. normalize.py converts them afterwards.

Usage: fetch.py <dest>   (IMG_CACHE=<dir> reuses downloaded zips)
"""
import io
import os
import shutil
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path
from urllib.parse import urlparse

CATALOG = [
    ("usc-misc",      "https://sipi.usc.edu/database/misc.zip"),
    ("usc-aerials",   "https://sipi.usc.edu/database/aerials.zip"),
    ("usc-textures",  "https://sipi.usc.edu/database/textures.zip"),
    ("usc-sequences", "https://sipi.usc.edu/database/sequences.zip"),
    ("ic-gray8",      "http://imagecompression.info/test_images/gray8bit.zip"),
    ("ic-gray16",     "http://imagecompression.info/test_images/gray16bit.zip"),
]

IMG_EXT = {".tif", ".tiff", ".pgm", ".ppm", ".pnm", ".pbm",
           ".png", ".bmp", ".jpg", ".jpeg"}


def zip_path_for(url: str, cache: str | None) -> tuple[Path, bool]:
    """Return (path-to-zip, is_temp)."""
    name = Path(urlparse(url).path).name
    if cache:
        cached = Path(cache) / name
        if cached.is_file():
            print(f"    (cache hit: {cached})")
            return cached, False
    tmp = tempfile.NamedTemporaryFile(prefix="fetch_", suffix=".zip", delete=False)
    with urllib.request.urlopen(url, timeout=600) as r:
        shutil.copyfileobj(r, tmp)
    tmp.close()
    return Path(tmp.name), True


def fetch(dest: Path):
    dest.mkdir(parents=True, exist_ok=True)
    cache = os.environ.get("IMG_CACHE")
    total = 0
    for prefix, url in CATALOG:
        print(f"  {prefix}: {url}")
        zpath, is_temp = zip_path_for(url, cache)
        try:
            n = 0
            with zipfile.ZipFile(zpath) as z:
                for info in z.infolist():
                    if info.is_dir():
                        continue
                    if Path(info.filename).suffix.lower() not in IMG_EXT:
                        continue
                    out = dest / f"{prefix}_{Path(info.filename).name}"
                    with z.open(info) as src, open(out, "wb") as dst:
                        shutil.copyfileobj(src, dst)
                    n += 1
            print(f"  {prefix}: extracted {n} images")
            total += n
        finally:
            if is_temp:
                os.unlink(zpath)
    print(f"fetched: {total} source images into {dest}")


def main():
    dest = Path(sys.argv[1] if len(sys.argv) > 1 else "Images")
    fetch(dest)


if __name__ == "__main__":
    main()
