#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Fetch the pinned third-party dependencies; the pins below are their provenance.
# A no-arg run fetches the verification deps (gitignored), builds CharLS and
# installs NVC (may prompt for sudo). open-logic is committed, since the RTL
# uses it, so it is fetched only when named.
#
# Usage:  ./fetch_third_party.sh                 verification deps (default)
#         ./fetch_third_party.sh open-logic      one or more named components
#         (names: open-logic osvvm osvvm-scripts osvvm-common osvvm-axi4 tcllib charls nvc)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Pins ---
OL_URL="https://github.com/open-logic/open-logic.git"
OL_TAG="4.5.0"

# The OSVVM tags move in lockstep
OSVVM_URL="https://github.com/OSVVM/OSVVM.git"
OSVVM_TAG="2026.01"

OSVVM_SCRIPTS_URL="https://github.com/OSVVM/OSVVM-Scripts.git"
OSVVM_SCRIPTS_TAG="2026.01"

OSVVM_COMMON_URL="https://github.com/OSVVM/OSVVM-Common.git"
OSVVM_COMMON_TAG="2026.01"

OSVVM_AXI4_URL="https://github.com/OSVVM/AXI4.git"
OSVVM_AXI4_TAG="2026.01"

TCLLIB_URL="https://github.com/tcltk/tcllib.git"   # fileutil + yaml for OSVVM-Scripts
TCLLIB_TAG="tcllib-2-0"

CHARLS_URL="https://github.com/team-charls/charls.git"
CHARLS_COMMIT=57ac3c337083bedbdfc93d19ec75a02101b1cd71    # cli/ is on main, not in the 2.4.x tags

NVC_URL="https://github.com/nickg/nvc"
NVC_DOCS="https://www.nickg.me.uk/nvc/"
NVC_VERSION="1.21.0"

# open-logic: base packages + the RAM/FIFO the RTL instantiates ---
fetch_open_logic() {
  local OL_DST="$HERE/open-logic"
  local OL_FILES=(
    olo_base_pkg_array.vhd
    olo_base_pkg_math.vhd
    olo_base_pkg_string.vhd
    olo_base_pkg_logic.vhd
    olo_base_pkg_attribute.vhd
    olo_base_ram_sdp.vhd
    olo_base_fifo_sync.vhd
  )

  echo "==> open-logic $OL_TAG"
  git clone --quiet --depth 1 --branch "$OL_TAG" -c advice.detachedHead=false "$OL_URL" "$TMP/ol"
  rm -rf "$OL_DST/src"
  mkdir -p "$OL_DST/src/base/vhdl"
  for f in "${OL_FILES[@]}"; do
    cp "$TMP/ol/src/base/vhdl/$f" "$OL_DST/src/base/vhdl/$f"
  done
  cp "$TMP/ol/License.txt" "$TMP/ol/LGPL2_1.txt" "$OL_DST/"
}

# OSVVM ---
# Keep in sync with FILES in Verification/OSVVM/build_osvvm.sh
fetch_osvvm() {
  local OSVVM_DST="$HERE/osvvm"
  local OSVVM_FILES=(
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
  osvvm.pro
  OsvvmVhdlSettings.pro
)

  echo "==> OSVVM $OSVVM_TAG"
  git clone --quiet --depth 1 --branch "$OSVVM_TAG" -c advice.detachedHead=false "$OSVVM_URL" "$TMP/osvvm"
  rm -rf "$OSVVM_DST"
  mkdir -p "$OSVVM_DST/deprecated"
  for f in "${OSVVM_FILES[@]}"; do
    cp "$TMP/osvvm/$f" "$OSVVM_DST/$f"
  done
  cp "$TMP/osvvm/LICENSE.md" "$OSVVM_DST/"
}

# OSVVM-Scripts: top-level files only ---
fetch_osvvm_scripts() {
  local SCRIPTS_DST="$HERE/osvvm-scripts"

  echo "==> OSVVM-Scripts $OSVVM_SCRIPTS_TAG"
  git clone --quiet --depth 1 --branch "$OSVVM_SCRIPTS_TAG" -c advice.detachedHead=false "$OSVVM_SCRIPTS_URL" "$TMP/osvvm-scripts"
  rm -rf "$SCRIPTS_DST"
  mkdir -p "$SCRIPTS_DST"
  find "$TMP/osvvm-scripts" -maxdepth 1 -type f ! -name '.*' -exec cp {} "$SCRIPTS_DST/" \;
}

# OSVVM-Common, needed by the AXI4 VCs ---
# Whole src/: the VHDL-2008 build uses the deprecated/ fallbacks
fetch_osvvm_common() {
  local DST="$HERE/osvvm-common"

  echo "==> OSVVM-Common $OSVVM_COMMON_TAG"
  git clone --quiet --depth 1 --branch "$OSVVM_COMMON_TAG" -c advice.detachedHead=false "$OSVVM_COMMON_URL" "$TMP/osvvm-common"
  rm -rf "$DST"
  mkdir -p "$DST"
  cp "$TMP/osvvm-common/build.pro" "$TMP/osvvm-common/LICENSE.md" "$DST/"
  cp -r "$TMP/osvvm-common/src" "$DST/"
}

# OSVVM-AXI4: common, AxiStream and Axi4Lite only ---
fetch_osvvm_axi4() {
  local DST="$HERE/osvvm-axi4"

  echo "==> OSVVM-AXI4 $OSVVM_AXI4_TAG"
  git clone --quiet --depth 1 --branch "$OSVVM_AXI4_TAG" -c advice.detachedHead=false "$OSVVM_AXI4_URL" "$TMP/osvvm-axi4"
  rm -rf "$DST"
  mkdir -p "$DST"
  cp "$TMP/osvvm-axi4/LICENSE.md" "$DST/"
  for sub in common AxiStream Axi4Lite; do
    mkdir -p "$DST/$sub"
    cp "$TMP/osvvm-axi4/$sub/build.pro" "$DST/$sub/"
    cp -r "$TMP/osvvm-axi4/$sub/src" "$DST/$sub/"
  done
}

# tcllib, not packaged on Arch ---
# fileutil needs cmdline; yaml bundles huddle
fetch_tcllib() {
  local TCLLIB_DST="$HERE/tcllib"
  local TCLLIB_MODULES=(fileutil cmdline yaml)

  echo "==> tcllib $TCLLIB_TAG"
  git clone --quiet --depth 1 --branch "$TCLLIB_TAG" -c advice.detachedHead=false "$TCLLIB_URL" "$TMP/tcllib"
  rm -rf "$TCLLIB_DST"
  mkdir -p "$TCLLIB_DST"
  for m in "${TCLLIB_MODULES[@]}"; do
    mkdir -p "$TCLLIB_DST/$m"
    find "$TMP/tcllib/modules/$m" -maxdepth 1 -name '*.tcl' -exec cp {} "$TCLLIB_DST/$m/" \;
  done
  cp "$TMP/tcllib/license.terms" "$TCLLIB_DST/"
}

# CharLS, built from the pinned commit ---
fetch_charls() {
  local SRC="$HERE/charls"
  local CLI="$SRC/build/cli/charls-cli"

  if [ -x "$CLI" ]; then
    echo "==> charls already built: $CLI"
    return 0
  fi

  echo "==> charls ${CHARLS_COMMIT:0:12}"
  if [ ! -e "$SRC/CMakeLists.txt" ]; then
    mkdir -p "$SRC"
    git -C "$SRC" init -q
    git -C "$SRC" remote add origin "$CHARLS_URL" 2>/dev/null || true
    git -C "$SRC" fetch -q --depth 1 origin "$CHARLS_COMMIT"
    git -C "$SRC" checkout -q FETCH_HEAD
  fi
  # CLI is off by default
  cmake -S "$SRC" -B "$SRC/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCHARLS_BUILD_CLI=ON
  cmake --build "$SRC/build"
  echo "Built: $CLI"
}

# NVC, a system package: Ubuntu .deb or AUR, else manual ---
fetch_nvc() {
  if command -v nvc > /dev/null 2>&1; then
    echo "==> nvc already installed: $(nvc --version | head -n1)"
    return 0
  fi

  local id ver arch
  id="$( [ -r /etc/os-release ] && . /etc/os-release && printf '%s' "${ID:-}" )"
  ver="$( [ -r /etc/os-release ] && . /etc/os-release && printf '%s' "${VERSION_ID:-}" )"
  arch="$(uname -m)"

  manual_nvc() {
    echo "Due to your system OS or version we can't automatically install NVC." >&2
    echo "Install it manually — releases: $NVC_URL/releases  docs: $NVC_DOCS" >&2
    return 1
  }

  case "$id" in
    ubuntu)
      # The .deb is amd64-only, one per Ubuntu LTS
      [ "$arch" = "x86_64" ] || { manual_nvc; return 1; }
      case "$ver" in
        22.04 | 24.04)
          local deb="nvc_${NVC_VERSION}-1_amd64_ubuntu-${ver}.deb"
          echo "==> nvc $NVC_VERSION (Ubuntu $ver)"
          curl -fLo "$TMP/$deb" "$NVC_URL/releases/download/r${NVC_VERSION}/$deb"
          sudo apt install -y "$TMP/$deb"
          ;;
        *) manual_nvc; return 1 ;;
      esac
      ;;
    arch | manjaro | endeavouros)
      echo "==> nvc (Arch, via yay)"
      command -v yay > /dev/null 2>&1 \
        || { echo "yay not found — install an AUR helper, or build from source: $NVC_URL" >&2; return 1; }
      yay -S --needed nvc
      ;;
    *) manual_nvc; return 1 ;;
  esac
}

# Dispatch ---
components=("$@")
[ ${#components[@]} -eq 0 ] && components=(osvvm osvvm-scripts osvvm-common osvvm-axi4 tcllib charls nvc)
for c in "${components[@]}"; do
  case "$c" in
    open-logic)    fetch_open_logic ;;
    osvvm)         fetch_osvvm ;;
    osvvm-scripts) fetch_osvvm_scripts ;;
    osvvm-common)  fetch_osvvm_common ;;
    osvvm-axi4)    fetch_osvvm_axi4 ;;
    tcllib)        fetch_tcllib ;;
    charls)        fetch_charls ;;
    nvc)           fetch_nvc ;;
    *) echo "unknown component: $c (open-logic osvvm osvvm-scripts osvvm-common osvvm-axi4 tcllib charls nvc)" >&2; exit 1 ;;
  esac
done

echo "Done. Review with: git status ThirdParty"
