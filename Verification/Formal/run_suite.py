#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Release set of property proofs; writes Results/formal_results.tsv and Results/report_status.env.

Each check has an expected verdict: PROVED for a property, BOUNDED for a property checked to a fixed depth only,
DISPROVED for its live check (a known-bad case).
Env: FORMAL_WORK (scratch, /tmp/openjls_formal), FORMAL_THREADS (20).
"""
import os, re, subprocess as sp, sys, time, multiprocessing as mp
from datetime import datetime
from pathlib import Path

F = Path(__file__).resolve().parent
sys.path[:0] = [str(F / "Common"), str(F / "Properties")]
from flow import S, RESULTS
import top_ctrl, cushion, ag, t87_eq, run_coder, stream, ctx_fwd, rtl_asserts, bs_split

WORK = Path(os.environ.get("FORMAL_WORK", "/tmp/openjls_formal"))
CUSH = int(re.search(r"STALL_CUSHION_ENTRIES\s*:\s*natural\s*:=\s*(\d+)", (S / "byte_stuffer.vhd").read_text())[1])
RC_WIDTHS = (4, 8, 37, 4096, 65535)
# bs_split proves the byte_stuffer byte order; the whole-module stream.py entries are research tries
STREAM = [n for n in stream.CHECKS if not n.startswith("byte_stuffer")]
BS = {"wr": "stage 1 writes each bit at its stream position", "fifo": "main FIFO keeps order",
      "fifo_bv": "last-word queue keeps order", "rd": "stage 3 outputs the word stream in order"}
CF = {"fwd": "bypass flags", "word": "RAM word", "eoi": "EOI token reaches stage 2"}
CF_BAD = {"fwd": "bypass demanded across images", "word": "reference misses load-edge write", "eoi": "assert false"}
SIZES = {"W8 H4": "MAX_IMAGE_WIDTH=8 MAX_IMAGE_HEIGHT=4", "W4096 H4096": "MAX_IMAGE_WIDTH=4096 MAX_IMAGE_HEIGHT=4096"}

CHECKS = ([("top control invariants", f"BITNESS {b}, {s}", "PROVED", ("tc", b, g, False))
           for s, g in SIZES.items() for b in range(8, 17)]
          + [("top control invariants (live)", "assert false, BITNESS 8, W8 H4", "DISPROVED", ("tc", 8, SIZES["W8 H4"], True))]
          + [("byte_stuffer FIFO no overflow", f"cushion {CUSH}, BURST {b}", "PROVED", ("cu", CUSH, b))
             for b in (6, 8, 16, 64)]
          + [("byte_stuffer FIFO no overflow (live)", f"cushion {CUSH - 1}, BURST 6", "DISPROVED", ("cu", CUSH - 1, 6))]
          + [(f"datapath invariant {n}", f"BITNESS {b}", "PROVED", ("ag", n, b, False))
             for n in ag.OBL for b in range(8, 17)]
          + [(f"datapath invariant {n} (live)", "assert false, BITNESS 8", "DISPROVED", ("ag", n, 8, True)) for n in ag.OBL]
          + [(f"T.87 {n}", f"BITNESS {b}", "PROVED", ("t87", n, b, False)) for n, b, _ in t87_eq.jobs()]
          + [(f"T.87 {n} (live)", "wrong reference, BITNESS 8", "DISPROVED", ("t87", n, 8, True)) for n in t87_eq.CHECKS]
          + [("run coder A.14-A.16 vs T.87 model", f"line width {w}", "PROVED", ("rc", w, False)) for w in RC_WIDTHS]
          + [("run coder A.14-A.16 vs T.87 model (live)", "model drops EOLine bit, line width 4", "DISPROVED", ("rc", 4, True))]
          + [(n, f"BITNESS {b}" + (f", {stream.CHECKS[n]['depth']} steps" if stream.CHECKS[n].get("mode") == "bmc" else ""),
              "BOUNDED" if stream.CHECKS[n].get("mode") == "bmc" else "PROVED", ("st", n, b, False))
             for n, b, _ in stream.jobs(STREAM)]
          + [(f"{n} (live)", "broken harness, BITNESS 8", "DISPROVED", ("st", n, 8, True)) for n in STREAM]
          + [(f"byte_stuffer byte order: {BS[p]}", f"BITNESS {b}", "PROVED", ("bs", p, b, False))
             for p in bs_split.PARTS for b in ([8] if p == "fifo_bv" else (8, 12, 16))]
          + [(f"byte_stuffer byte order: {BS[p]} (live)", "broken copy, BITNESS 8", "DISPROVED", ("bs", p, 8, True))
             for p in bs_split.PARTS]
          + [(f"context read gets newest value: {CF[k]}", f"BITNESS {b}", "PROVED", ("cf", k, b, False))
             for k, b, _ in ctx_fwd.jobs()]
          + [(f"context read gets newest value: {CF[k]} (live)", f"{CF_BAD[k]}, BITNESS 8", "DISPROVED", ("cf", k, 8, True))
             for k in CF]
          + [(f"RTL asserts: {n}", f"BITNESS {b}", "PROVED", ("ra", n, b, False)) for n, b, _ in rtl_asserts.jobs()]
          + [(f"RTL asserts: {n} (live)", "first assert inverted, BITNESS 8", "DISPROVED", ("ra", n, 8, True))
             for n in rtl_asserts.RELEASE])


def do(i):
    name, cfg, exp, job = CHECKS[i]
    d = WORK / f"j{i:03d}"
    t0 = time.time()
    if job[0] == "tc":
        top_ctrl.WORK, top_ctrl.GEN, top_ctrl.VAC = d, job[2].split(), job[3]
        r = top_ctrl.check(str(job[1]))["res"]
    elif job[0] == "cu":
        cushion.WORK, cushion.FREE, cushion.TIMEOUT = d, True, 1800
        r = cushion.job((job[1], job[2], 32))["res"]
    elif job[0] == "rc":
        run_coder.WORK, run_coder.HELP, run_coder.MODE, run_coder.TIMEOUT = d, True, "prove", 3600
        run_coder.DEPTH = 12 if job[2] else 6
        r = run_coder.one(job[1:])["res"]
    elif job[0] == "st":
        stream.WORK = d
        r = stream.one(job[1:])["res"]
        # A clean bounded run: no failure within the depth, not a proof
        if r == "PROVED" and stream.CHECKS[job[1]].get("mode") == "bmc" and not job[3]:
            r = "BOUNDED"
    elif job[0] == "ra":
        rtl_asserts.WORK = d
        r = rtl_asserts.one(job[1:])["res"]
    elif job[0] == "bs":
        bs_split.WORK = d
        r = bs_split.job(job[1:])["res"]
    elif job[0] == "cf":
        ctx_fwd.WORK = d
        r = ctx_fwd.job(job[1:])["res"]
    elif job[0] == "t87":
        t87_eq.WORK = d
        r = t87_eq.one(job[1:])["res"]
    else:
        ag.WORK = d
        os.environ.pop("AG_VACUITY", None)
        if job[3]:
            os.environ["AG_VACUITY"] = "1"
        r = ag.one((job[1], job[2]))["res"]
    r = {"PASS": "PROVED", "FAIL": "DISPROVED"}.get(r, r)
    return i, r, int(time.time() - t0)


def main():
    RESULTS.mkdir(exist_ok=True)
    res = {}
    # One process per job: the modules keep settings in globals and os.environ
    with mp.Pool(int(os.environ.get("FORMAL_THREADS", 20)), maxtasksperchild=1) as p:
        for i, r, sec in p.imap_unordered(do, range(len(CHECKS))):
            res[i] = (r, sec)
            print(f"{CHECKS[i][0]} | {CHECKS[i][1]}: {r} ({sec} s)", flush=True)
    ok = 0
    with open(RESULTS / "formal_results.tsv", "w") as f:
        f.write("Check\tConfiguration\tExpected\tResult\tStatus\tSeconds\n")
        for i, (name, cfg, exp, _) in enumerate(CHECKS):
            r, sec = res[i]
            st = "PASS" if r == exp else f"FAIL ({r})"
            ok += st == "PASS"
            f.write(f"{name}\t{cfg}\t{exp}\t{r}\t{st}\t{sec}\n")
    n, live = len(CHECKS), sum(c[2] == "DISPROVED" for c in CHECKS)
    bounded = sum(c[2] == "BOUNDED" for c in CHECKS)
    # Same formula as publish_reports.sh (shell glob order)
    h = sp.run(["bash", "-c", 'cat "$0"/*.vhd | sha256sum | cut -c1-12', str(S)], capture_output=True, text=True).stdout.strip()
    (RESULTS / "report_status.env").write_text(
        'NAME="Formal"\n'
        f'STATUS={"PASS" if ok == n else "FAIL"}\n'
        f'PCT="{100 * ok // n}%"\n'
        f'SUMMARY="{ok} of {n} checks as expected: {n - live - bounded} proofs, {bounded} bounded, {live} live checks"\n'
        f'DATE="{datetime.now().astimezone().isoformat(timespec="seconds")}"\n'
        f"SOURCES_HASH={h}\n")
    print(f"{ok} of {n} as expected", flush=True)
    return ok != n


if __name__ == "__main__":
    sys.exit(main())
