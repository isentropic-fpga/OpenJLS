# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""Shared plot style, after isentropic.com.br: Barlow, amber accent, warm
neutrals. Tokens mirror the datasheet preamble."""
import os

import matplotlib.pyplot as plt
from matplotlib import font_manager

INK, MUTED, DIVIDER = "#1c1a16", "#7e7362", "#d7cdbe"
AMBER = "#d97706"
# Series after the first are warm greys; dash and marker keep them separable.
SERIES = [AMBER, "#443e34", "#7e7362", "#b0a491"]

_FONTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Docs", "datasheet", "fonts")
for _f in ("Barlow-Regular.ttf", "Barlow-SemiBold.ttf"):
    font_manager.fontManager.addfont(os.path.join(_FONTS, _f))

plt.rcParams.update({
    "font.family": "Barlow",
    "font.size": 11,
    "text.color": INK,
    "axes.labelcolor": INK,
    "axes.edgecolor": DIVIDER,
    "axes.linewidth": 0.8,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "xtick.color": MUTED,
    "ytick.color": MUTED,
    "xtick.labelcolor": INK,
    "ytick.labelcolor": INK,
    "grid.color": DIVIDER,
    "grid.linestyle": "-",
    "grid.linewidth": 0.6,
    "grid.alpha": 1.0,
    "legend.frameon": False,
    "legend.title_fontsize": 10,
})
