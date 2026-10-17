#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Compile OSVVM into ./nvc-libs for the post-synth flow
set -euo pipefail

command -v nvc >/dev/null || {
  echo "nvc not found — install it (Arch: nvc from the AUR)" >&2
  exit 1
}

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$ROOT/ThirdParty/osvvm"
LIBS="$HERE/nvc-libs"

mkdir -p "$LIBS"

# Order from osvvm.pro; deprecated/*_c.vhd are the VHDL-2008 fallbacks
FILES=(
  IfElsePkg.vhd
  OsvvmTypesPkg.vhd
  OsvvmScriptSettingsPkg.vhd
  OsvvmScriptSettingsPkg_default.vhd
  OsvvmSettingsPkg.vhd
  OsvvmSettingsPkg_default.vhd
  TextUtilPkg.vhd
  FileUtilPkg.vhd
  ResolutionPkg.vhd
  NamePkg.vhd
  OsvvmGlobalPkg.vhd
  CoverageVendorApiPkg_default.vhd
  TranscriptPkg.vhd
  deprecated/LanguageSupport2019Pkg_c.vhd
  deprecated/FileLinePathPkg_c.vhd
  deprecated/AssertApiPkg_c.vhd
  AlertLogPkg.vhd
  TbUtilPkg.vhd
  NameStorePkg.vhd
  MessageListPkg.vhd
  SortListPkg_int.vhd
  RandomBasePkg.vhd
  RandomPkg.vhd
  RandomProcedurePkg.vhd
  CoveragePkg.vhd
  DelayCoveragePkg.vhd
  ClockResetPkg.vhd
  ResizePkg.vhd
  ScoreboardGenericPkg.vhd
  ScoreboardPkg_slv.vhd
  ScoreboardPkg_int.vhd
  ScoreboardPkg_signed.vhd
  ScoreboardPkg_unsigned.vhd
  ScoreboardPkg_IntV.vhd
  MemorySupportPkg.vhd
  MemoryGenericPkg.vhd
  MemoryPkg.vhd
  ReportPkg.vhd
  deprecated/RandomPkg2019_c.vhd
  OsvvmContext.vhd
)

nvc --std=2008 --work=osvvm:"$LIBS/osvvm.08" -a --relaxed "${FILES[@]/#/$SRC/}"

echo "OSVVM compiled into $LIBS/osvvm.08"
