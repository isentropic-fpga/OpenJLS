#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Simulation miter for survivors: gold and mutant tops side by side on random segments (tb_miter.vhd).

  miter.py ID [ID ...]   mutant IDs (stem:hash) of Sources/*.vhd
SAME on every configuration is evidence for equivalence, not proof; DIFF names a stimulus the suites miss.
Env: MITER_WORK (/tmp/openjls_miter), MITER_THREADS (20).
"""
import json, os, re, shutil, subprocess as sp, sys, multiprocessing as mp
from pathlib import Path

F = Path(__file__).resolve().parent
sys.path.insert(0, str(F.parent))
import mutants

R = F.parents[2]
S = R / "Sources"
O = R / "Verification/OSVVM"
J = Path(os.environ.get("MITER_WORK", "/tmp/openjls_miter"))
ALL = [(O / x).resolve() for x in re.findall(r"^analyze (\S*(?:Sources|open-logic)/\S+\.vhd)$", (O / "OpenJls.pro").read_text(), re.M)
       if "Xilinx" not in x]
CFG = [(8, 64, 1), (12, 48, 2), (16, 200, 3), (9, 64, 4)]


def nv(d, lib, args, timeout=900):
    return sp.run(["nvc", "--std=2008", "--ieee-warnings=off", "-H", "1g", "-L", str(J / "base"), "-L", str(d), f"--work={lib}"] + args,
                  cwd=d, capture_output=True, text=True, errors="replace", timeout=timeout)


def init(q):
    global W
    W = J / f"w{q.get():02d}"
    shutil.rmtree(W, ignore_errors=True); W.mkdir()


def one(job):
    mid, stem, line, to = job
    for x in W.glob("MUTLIB*"):
        shutil.rmtree(x)
    src = (S / f"{stem}.vhd").read_text().splitlines(keepends=True); src[line] = to + "\n"
    f = W / "m.vhd"; f.write_text("".join(src))
    orig = (S / f"{stem}.vhd").resolve()
    r = nv(W, f"mutlib:{W}/MUTLIB.08", ["-a", "--relaxed", "--psl"] + [str(f) if a == orig else str(a) for a in ALL] + [str(F / "tb_miter.vhd")])
    if r.returncode:
        return dict(id=mid, res="INVALID")
    cycles = 0
    for b, o, s in CFG:
        try:
            r = nv(W, f"mutlib:{W}/MUTLIB.08", ["-e", "--jit", "--no-save", f"-gBITNESS={b}", f"-gOUT_WIDTH={o}", f"-gSEED={s}",
                                                "tb_miter", "-r", "--ieee-warnings=off", "tb_miter"])
        except sp.TimeoutExpired:
            return dict(id=mid, res="TIMEOUT", cfg=[b, o])
        t = r.stdout + r.stderr
        k = re.search(r"MITER: SAME (\d+)", t)
        if not k:
            d = re.search(r"MITER: DIFF.*|Fatal.*|Failure.*|Error.*", t)
            return dict(id=mid, res="DIFF", cfg=[b, o], why=d[0] if d else t[-200:])
        cycles += int(k[1])
    return dict(id=mid, res="SAME", cycles=cycles)


def jobs(ids):
    out = []
    for stem in sorted({i.split(":")[0] for i in ids}):
        ms = {m["id"]: m for m in mutants.all_mutants((S / f"{stem}.vhd").read_text(), stem)}
        out += [(i, stem, ms[i]["line"], ms[i]["to"]) for i in ids if i.split(":")[0] == stem]
    return out


if __name__ == "__main__":
    J.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(J / "base", ignore_errors=True); (J / "base").mkdir()
    r = sp.run(["nvc", "--std=2008", "--ieee-warnings=off", "-L", str(J / "base"), f"--work=openjls:{J}/base/OPENJLS.08",
                "-a", "--relaxed", "--psl"] + [str(a) for a in ALL], capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout + r.stderr)
    n = int(os.environ.get("MITER_THREADS", "20"))
    q = mp.get_context("fork").Queue()
    for i in range(n):
        q.put(i)
    with mp.get_context("fork").Pool(n, init, (q,)) as p:
        for r in p.imap_unordered(one, jobs(sys.argv[1:])):
            print(json.dumps(r), flush=True)
