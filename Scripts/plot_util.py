#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""Plot LUT/FF (left axis) and BRAM (right axis) vs maximum image width, or vs
bit depth for a single-size sweep, from fmax_sweep.csv.

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

from plot_style import SERIES

csv_path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/EDA/Logs/fmax_sweep.csv")
out_png = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/EDA/Logs/util_vs_size.png")

# Default strategy only: utilization is ~strategy-independent
with open(csv_path) as f:
    raw = [r for r in csv.DictReader(f) if r["status"] == "OK" and "Default" in r["strategy"]]
# Older CSVs have no bitness column and are all 12-bit
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

# Dash and marker keep the series apart in greyscale
kw = dict(lw=1.6, ms=6, mfc="white", mew=1.4)
l_lut,  = ax1.plot(xs, lut,  ls="-",  marker="o", color=SERIES[0], label="LUTs", **kw)
l_ff,   = ax1.plot(xs, ff,   ls="--", marker="s", color=SERIES[1], label="Flip-flops", **kw)
l_bram, = ax2.plot(xs, bram, ls="-.", marker="^", color=SERIES[2], label="Block RAM", **kw)

# Linear x so the BRAM line (~proportional to width) reads straight
ax1.set_xticks(xs)
if by_bitness:
    ax1.set_xlabel("Pixel bit depth  (bits)")
else:
    ax1.xaxis.set_major_formatter(mticker.FuncFormatter(lambda x, _: f"{int(round(x / 1024))}k"))
    ax1.set_xlabel("Maximum image width  (px)")
ax1.set_ylabel("LUT / FF  (count)")
ax2.set_ylabel("Block RAM (tiles)")
ax1.set_ylim(bottom=0)
ax2.set_ylim(bottom=0)

# No title: the LaTeX caption supplies it
ax1.grid(True, which="major", axis="y")
ax2.spines["right"].set_visible(True)
# Center left would cover the low BRAM points of the bit-depth sweep
ax1.legend(handles=[l_lut, l_ff, l_bram], title="Resource",
           loc="upper left" if by_bitness else "center left", alignment="left")

plt.tight_layout()
plt.savefig(out_png, dpi=150)
print(f"wrote {out_png}")
