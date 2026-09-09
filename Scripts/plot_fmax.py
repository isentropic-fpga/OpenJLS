#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""Plot fmax vs maximum image width (one line per strategy) from fmax_sweep.csv.

Usage:
    python3 Scripts/plot_fmax.py [csv_path] [out_png]
Defaults: ~/EDA/Logs/fmax_sweep.csv -> ~/EDA/Logs/fmax_vs_size.png
"""
import csv
import os
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker

csv_path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/EDA/Logs/fmax_sweep.csv")
out_png = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/EDA/Logs/fmax_vs_size.png")

# strategy -> list of (size, fmax, met)
series = defaultdict(list)
with open(csv_path) as f:
    for row in csv.DictReader(f):
        if row["status"] != "OK":
            continue
        series[row["strategy"]].append(
            (int(row["size"]), float(row["fmax_mhz"]), row["met"] == "1")
        )

fig = plt.figure(figsize=(8, 5))
def pretty(strat):
    # The project default strategy is named "Vivado Implementation Defaults".
    if "Default" in strat:
        return "Standard (default)"
    return strat.replace("_", " ")

# Redundant encoding: every series is separable by dash pattern and marker
# alone, so the figure survives greyscale printing and colour-vision
# deficiency. Colours are the Okabe-Ito colour-blind-safe palette.
STYLES = [
    ("-",  "o", "#0072B2"),
    ("--", "s", "#D55E00"),
    ("-.", "^", "#009E73"),
    (":",  "D", "#CC79A7"),
]

# Fixed order so the styles stay bound to the same strategy across re-runs.
for idx, strat in enumerate(sorted(series, key=lambda k: ("Default" not in k, k))):
    pts = series[strat]
    pts.sort()
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    label = pretty(strat)
    ls, mk, col = STYLES[idx % len(STYLES)]
    line, = plt.plot(xs, ys, ls=ls, marker=mk, color=col, label=label,
                     lw=1.6, ms=6, mfc="white", mew=1.4)
    # flag points where the probe was too loose (fmax is only a floor)
    floor_x = [p[0] for p in pts if p[2]]
    floor_y = [p[1] for p in pts if p[2]]
    if floor_x:
        plt.scatter(floor_x, floor_y, marker="v", s=90, zorder=5,
                    facecolors="none", edgecolors=line.get_color(),
                    label=f"{label} (floor only — re-probe)")

all_sizes = sorted({p[0] for pts in series.values() for p in pts})
ax = plt.gca()
ax.set_xticks(all_sizes)
# Label ticks as 4k, 8k, 12k, ... instead of raw pixel counts
ax.xaxis.set_major_formatter(mticker.FuncFormatter(lambda x, _: f"{int(round(x / 1024))}k"))
plt.xlabel("Maximum image width  (px)")
plt.ylabel("Max. frequency  (MHz)")
# No in-figure title: the LaTeX float caption supplies it.
plt.grid(True, which="major", ls=":", alpha=0.5)
plt.legend(title="Implementation strategy", framealpha=0.95)
plt.tight_layout()
plt.savefig(out_png, dpi=150)
print(f"wrote {out_png}")
