#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Print the corpus recipe ID: a hash of prepare_images.sh and its generators.
# prepare_images.sh stores it in Images/.corpus_id; the Golden and HIL runs
# refuse a corpus made by another recipe.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export LC_ALL=C
cat "$HERE/prepare_images.sh" "$HERE"/imageprep/*.py "$HERE"/imageprep/*.sha256 | sha256sum | cut -c1-12
