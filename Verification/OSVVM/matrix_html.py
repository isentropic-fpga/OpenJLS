#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""Render the verification matrix of Docs/verification_requirements.md as HTML
for the report landing page, with repo links pointed at GitHub.

Usage: matrix_html.py <verification_requirements.md>
"""
import html
import os
import re
import sys

REPO = "https://github.com/isentropic-fpga/OpenJLS/blob/main/"


def cell(text, base):
    def link(m):
        url = m.group(2)
        if not re.match(r"[a-z]+://", url):
            url = REPO + os.path.normpath(os.path.join(base, url))
        return f'<a href="{html.escape(url)}">{m.group(1)}</a>'

    text = html.escape(text, quote=False)
    # <wbr> so long names wrap in narrow columns
    text = re.sub(r"`([^`]*)`",
                  lambda m: "<code>" + re.sub(r"([_.-]|[a-z](?=[A-Z]))", r"\1<wbr>", m.group(1)) + "</code>", text)
    text = re.sub(r"\*\*([^*]*)\*\*", r"\1", text)
    return re.sub(r"\[([^\]]*)\]\(([^)]*)\)", link, text)


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def main():
    md = sys.argv[1]
    lines = open(md, encoding="utf-8").read().splitlines()
    base = os.path.dirname(os.path.relpath(md, ROOT))
    start = next(i for i in range(lines.index("## Matrix"), len(lines)) if lines[i].startswith("|"))
    end = start
    while end < len(lines) and lines[end].startswith("|"):
        end += 1
    rows = [r.strip().strip("|").split(" | ") for r in lines[start:end]]
    head, body = [h.strip() for h in rows[0]], rows[2:]
    gcols = {i for i, h in enumerate(head) if re.fullmatch(r"G\d", h)}

    print('<div class="tbl-scroll"><table class="matrix">')
    print("  <thead><tr>" + "".join(
        f'<th{" class=\"num\"" if h == "Goal" else ""}>{h}</th>' for h in head) + "</tr></thead>")
    print("  <tbody>")
    for r in body:
        tds = []
        for i, c in enumerate(r):
            c = c.strip()
            cls = ""
            if i in gcols:
                cls = {"✓": "r-ok", "N/A": "r-na"}.get(c, "r-bad")
            elif head[i] == "Goal":
                cls = "num"
            elif head[i] == "ID":
                cls = "suite"
            attr = f' class="{cls}"' if cls else ""
            tds.append(f"<td{attr}>{cell(c, base)}</td>")
        print("    <tr>" + "".join(tds) + "</tr>")
    print("  </tbody>")
    print("</table></div>")


if __name__ == "__main__":
    main()
