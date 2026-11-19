# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Shared paths, tool environment and process runner for the formal scripts."""
import os, subprocess as sp
from pathlib import Path

FORMAL = Path(__file__).resolve().parents[1]
R = FORMAL.parents[1]
# FORMAL_SOURCES: a mutated copy of Sources/ (Verification/Mutation)
S = Path(os.environ.get("FORMAL_SOURCES", R / "Sources"))
RESULTS = FORMAL / "Results"
OSS = Path(os.environ.get("OSS_CAD_SUITE", Path.home() / "Tools/oss-cad-suite"))
ENV = dict(os.environ, PATH=f"{OSS}/bin:{OSS}/py3bin:" + os.environ["PATH"])
OLO = R / "ThirdParty/open-logic/src/base/vhdl"
BASE = [OLO / f"olo_base_{n}.vhd" for n in ("pkg_array", "pkg_math", "pkg_string", "pkg_logic", "pkg_attribute",
                                            "ram_sdp", "fifo_sync")] + [S / "openjls_pkg.vhd"]
# Analysis order of the codec sources after openjls_pkg
ORDER = ["openjls_pkg", "A1_gradient_comp", "A3_mode_selection", "A4_quantization_gradients",
         "A4_1_quant_gradient_merging", "A4_2_Q_mapping", "A5_edge_detecting_predictor", "A6_A7_prediction_error",
         "A8_1_reconstructed_value", "A9_modulo_reduction", "A10_compute_k", "A11_error_mapping",
         "A11_1_golomb_encoder", "A11_2_bit_packer", "A12_A13_update", "A14_run_length_determination",
         "A15_A16_encode_run", "A17_run_interruption_index", "A18_run_interruption_prediction_error",
         "A19_run_interruption_error", "A20_1_run_context_index", "A20_2_compute_k", "A21_compute_map",
         "A22_errval_mapping", "A23_run_interruption_update", "line_buffer", "context_ram", "byte_stuffer",
         "jls_framer", "openjls_top"]


def tree(pid):
    kids = sp.run(["ps", "-o", "pid=", "--ppid", str(pid)], capture_output=True, text=True).stdout.split()
    return [pid] + [q for k in kids for q in tree(int(k))]


def run(cmd, cwd, timeout=None):
    """Killed with all descendants on timeout: sby solvers run in their own process groups."""
    p = sp.Popen(cmd, cwd=cwd, env=ENV, stdout=sp.PIPE, stderr=sp.PIPE, text=True, errors="replace",
                 start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
    except sp.TimeoutExpired:
        for q in tree(p.pid):
            try:
                os.kill(q, 9)
            except ProcessLookupError:
                pass
        p.communicate()
        raise
    return sp.CompletedProcess(cmd, p.returncode, out, err)
