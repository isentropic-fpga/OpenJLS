#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""Drop the all-N.A. rows (uninstrumented TBs and primitives) and their pages
from an NVC --per-file coverage report.

Usage: cover_prune.py <report-html-dir>
"""
import os
import re
import sys


def main():
    html_dir = sys.argv[1]
    index = os.path.join(html_dir, "index.html")
    text = open(index).read()

    pruned = []

    def keep(row):
        m = re.search(r'hier/([^"]+\.vhd\.html)', row)
        if not m:
            return True
        # N.A. cells are class="percentna"
        if re.search(r'class="percent\d', row):
            return True
        pruned.append(m.group(1))
        return False

    parts = re.split(r"(<tr>.*?</tr>)", text, flags=re.S)
    out = "".join(p for p in parts if not p.startswith("<tr>") or keep(p))
    open(index, "w").write(out)

    for page in pruned:
        for sub in ("hier", "source"):
            p = os.path.join(html_dir, sub, page)
            if os.path.exists(p):
                os.remove(p)

    print(f"cover_prune: removed {len(pruned)} non-DUT rows from {index}")


if __name__ == "__main__":
    main()
