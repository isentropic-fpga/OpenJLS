#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Release set of property proofs; writes Results/formal_results.tsv and Results/report_status.env.

Each check has an expected verdict: PROVED for a property, DISPROVED for its live check (a known-bad case).
Env: FORMAL_WORK (scratch, /tmp/openjls_formal), FORMAL_THREADS (20).
"""
import os, re, subprocess as sp, sys, time, multiprocessing as mp
from datetime import datetime
from pathlib import Path

F = Path(__file__).resolve().parent
sys.path[:0] = [str(F / "Common"), str(F / "Properties")]
from flow import S, RESULTS
import top_ctrl, cushion, ag

WORK = Path(os.environ.get("FORMAL_WORK", "/tmp/openjls_formal"))
CUSH = int(re.search(r"STALL_CUSHION_ENTRIES\s*:\s*natural\s*:=\s*(\d+)", (S / "byte_stuffer.vhd").read_text())[1])
SIZES = {"W8 H4": "MAX_IMAGE_WIDTH=8 MAX_IMAGE_HEIGHT=4", "W4096 H4096": "MAX_IMAGE_WIDTH=4096 MAX_IMAGE_HEIGHT=4096"}

CHECKS = ([("top control invariants", f"BITNESS {b}, {s}", "PROVED", ("tc", b, g, False))
           for s, g in SIZES.items() for b in range(8, 17)]
          + [("top control invariants (live)", "assert false, BITNESS 8, W8 H4", "DISPROVED", ("tc", 8, SIZES["W8 H4"], True))]
          + [("byte_stuffer FIFO no overflow", f"cushion {CUSH}, BURST {b}", "PROVED", ("cu", CUSH, b))
             for b in (6, 8, 16, 64)]
          + [("byte_stuffer FIFO no overflow (live)", f"cushion {CUSH - 1}, BURST 6", "DISPROVED", ("cu", CUSH - 1, 6))]
          + [(f"datapath invariant {n}", f"BITNESS {b}", "PROVED", ("ag", n, b, False))
             for n in ag.OBL for b in range(8, 17)]
          + [(f"datapath invariant {n} (live)", "assert false, BITNESS 8", "DISPROVED", ("ag", n, 8, True)) for n in ag.OBL])


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
    with mp.Pool(int(os.environ.get("FORMAL_THREADS", 20))) as p:
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
    # Same formula as publish_reports.sh (shell glob order)
    h = sp.run(["bash", "-c", 'cat "$0"/*.vhd | sha256sum | cut -c1-12', str(S)], capture_output=True, text=True).stdout.strip()
    (RESULTS / "report_status.env").write_text(
        'NAME="Formal"\n'
        f'STATUS={"PASS" if ok == n else "FAIL"}\n'
        f'PCT="{100 * ok // n}%"\n'
        f'SUMMARY="{ok} of {n} checks as expected: {n - live} proofs, {live} live checks"\n'
        f'DATE="{datetime.now().astimezone().isoformat(timespec="seconds")}"\n'
        f"SOURCES_HASH={h}\n")
    print(f"{ok} of {n} as expected", flush=True)
    return ok != n


if __name__ == "__main__":
    sys.exit(main())
