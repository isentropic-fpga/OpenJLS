#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Generate-branch mutants: GHDL rejects both branches driving one signal, so the gold copy keeps the
selected branch and the mutant copy selects the other one; equal outputs mean the mutant is equivalent."""
import json, os, sys, multiprocessing as mp
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import module_eq as me
CASES = [  # name, stem, {0-based line: text}, bits
    ("A9_branch", "A9_modulo_reduction", {28: "  gen_binary_mod : if false generate", 36: "  gen_general_mod : if true generate"}, range(8, 17)),
    ("A19_branch", "A19_run_interruption_error", {41: "  gen_binary_range : if false generate", 48: "  gen_general_range : if true generate"}, range(8, 17)),
    ("A6_comp_branch", "A6_A7_prediction_error", {58: "  gen_binary : if false generate", 62: "  gen_general : if true generate"}, range(9, 17)),
    ("A6_comp_branch_b8", "A6_A7_prediction_error", {58: "  gen_binary : if true generate", 62: "  gen_general : if false generate"}, [8]),
    ("A6_px_branch_b8", "A6_A7_prediction_error", {49: "  gen_narrow : if false generate", 53: "  gen_wide : if true generate"}, [8]),
]
def job(j):
    name, stem, edits, label, bits = j
    os.environ["FEQ_MUT_EDIT"] = json.dumps({str(k): v for k, v in list(edits.items())[1:]})
    k, v = next(iter(edits.items()))
    return me.one_((name, stem, k, v, label, bits))
if __name__ == "__main__":
    src = lambda st: open(me.S / f"{st}.vhd").read().splitlines()
    for n, st, e, _ in CASES:
        for k in e: print(n, k + 1, src(st)[k].strip(), "->", e[k].strip())
    jobs = [(n, st, e, lab, b) for n, st, e, bs in CASES for lab, _ in me.HARNESS[st] for b in bs]
    with mp.Pool(int(os.environ.get("FEQ_THREADS", "6"))) as p:
        for r in p.imap_unordered(job, jobs):
            print(json.dumps(r), flush=True)
