# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Sourced by the post-synth flows: ties a netlist to the RTL and generics it came from.
# Needs HERE and ROOT.

sources_hash() {
  cat "$ROOT"/Sources/*.vhd | sha256sum | cut -c1-12
}

# netlist_id <bitness> <max_w> <max_h> <out_width>
netlist_id() {
  { cat "$ROOT"/Sources/*.vhd "$ROOT"/ThirdParty/open-logic/src/base/vhdl/olo_base_*.vhd "$HERE/synth_funcsim.tcl"
    echo "$*"; } | sha256sum | cut -c1-12
}

netlist_recorded() {
  cat "$1.id" 2> /dev/null || true
}
