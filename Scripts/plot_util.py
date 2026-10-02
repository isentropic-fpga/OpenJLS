#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""Plot resource usage vs maximum image width, or vs pixel bit depth for a
single-size bit-depth sweep (default strategy only), from fmax_sweep.csv.

LUTs/FFs (counts) and Block-RAM tiles (~1-11) are on very different scales, so
LUT/FF go on the left y-axis and BRAM on a right y-axis.

Usage:
    python3 Scripts/plot_util.py [csv_path] [out_png]
Defaults: ~/EDA/Logs/fmax_sweep.csv -> ~/EDA/Logs/util_vs_size.png
"""
import csv
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker

csv_path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/EDA/Logs/fmax_sweep.csv")
out_png = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/EDA/Logs/util_vs_size.png")

# Default strategy only; utilization is set by synthesis and is ~strategy-independent.
with open(csv_path) as f:
    raw = [r for r in csv.DictReader(f) if r["status"] == "OK" and "Default" in r["strategy"]]
# Older CSVs predate the bitness column and are all 12-bit.
for r in raw:
    r.setdefault("bitness", "12")
by_bitness = len({r["size"] for r in raw}) == 1 and len({r["bitness"] for r in raw}) > 1
x_key = "bitness" if by_bitness else "size"

rows = sorted((int(r[x_key]), int(r["lut"]), int(r["ff"]), float(r["bram"])) for r in raw)
xs    = [r[0] for r in rows]
lut   = [r[1] for r in rows]
ff    = [r[2] for r in rows]
bram  = [r[3] for r in rows]

fig, ax1 = plt.subplots(figsize=(8, 5))
ax2 = ax1.twinx()

# Redundant encoding: dash pattern and marker separate the series without
# colour, so the figure survives greyscale printing and colour-vision
# deficiency. Colours are the Okabe-Ito colour-blind-safe palette.
kw = dict(lw=1.6, ms=6, mfc="white", mew=1.4)
l_lut,  = ax1.plot(xs, lut,  ls="-",  marker="o", color="#0072B2", label="LUTs", **kw)
l_ff,   = ax1.plot(xs, ff,   ls="--", marker="s", color="#D55E00", label="Flip-flops", **kw)
l_bram, = ax2.plot(xs, bram, ls="-.", marker="^", color="#009E73", label="Block RAM", **kw)

# X axis: linear spacing so the BRAM line (~proportional to width) reads straight.
ax1.set_xticks(xs)
if by_bitness:
    ax1.set_xlabel(f"Pixel bit depth  (MAX_IMAGE_WIDTH = {int(raw[0]['size']) // 1024}k)")
else:
    ax1.xaxis.set_major_formatter(mticker.FuncFormatter(lambda x, _: f"{int(round(x / 1024))}k"))
    ax1.set_xlabel("Maximum image width  (px)")
ax1.set_ylabel("LUT / FF  (count)")
ax2.set_ylabel("Block RAM (tiles)")
ax1.set_ylim(bottom=0)
ax2.set_ylim(bottom=0)

# No in-figure title: the LaTeX float caption supplies it.
ax1.grid(True, which="major", ls=":", alpha=0.5)
ax1.legend(handles=[l_lut, l_ff, l_bram], title="Resource", loc="center left",
           framealpha=0.95)

plt.tight_layout()
plt.savefig(out_png, dpi=150)
print(f"wrote {out_png}")
