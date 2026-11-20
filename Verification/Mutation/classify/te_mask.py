#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Lemmas for top_eq.py MASK and OWN, one per cut module: its outputs do not depend on a MASK input while the
input's enable is low, except an OWN output while that output's enable is low.

Two gold copies in the module_eq env harness (same env assumptions); the second gets a free value on each MASK input
in cycles where its enable is low. Asserts every output equal in every cycle after reset. PDR proof per BITNESS.
  te_mask.py [STEM ...]   (default: every stem in MASK); env TM_BITS ("8 12 16"), TM_WORK, TM_TIMEOUT,
                          TM_FAULT=1 (fault-injection check: the masked inputs are free in every cycle; must fail)
"""
import os, re, shutil, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import module_eq as me
import top_eq as te

WORK = Path(os.environ.get("TM_WORK", "/tmp/te_mask"))


def port_map(t, label):
    """{port: actual} of instance label."""
    i = t.index(f"{label} :")
    pm = t[t.index("port map (", i) + len("port map ("):t.index(");", i)]
    return dict((a.strip(), b.strip()) for a, b in re.findall(r"(\w+)\s*=>\s*([^,]+?)\s*(?=,|$)", pm, re.S))


def harness(stem):
    t = me.env_harness(te.CUT[stem], "eq").replace(f"entity work.{stem}_mut(", f"entity work.{stem}(")
    ps = te.ports((me.S / f"{stem}.vhd").read_text())[2]
    gm, mm = port_map(t, "u_gold"), port_map(t, "u_mut")
    decl, body = [], []
    u = t.index("u_mut :")
    head, tail = t[:u], t[u:]
    for p, en in te.MASK[stem].items():
        decl.append(f"  signal tm_{p}, tf_{p} : {dict((n, ty) for n, _, ty in ps)[p]};\n"
                    f"  attribute anyseq of tf_{p} : signal is true;\n")
        cond = "false" if os.environ.get("TM_FAULT") == "1" else f"{mm[en]} = '1'"
        body.append(f"  tm_{p} <= {mm[p]} when {cond} else tf_{p};\n")
        tail = re.sub(rf"\b{p}\s*=>\s*{re.escape(mm[p])}(?=\s*[,)])", f"{p} => tm_{p}", tail, count=1)
    own = te.OWN.get(stem, {})
    eqs = [f"({gm[own[o]]} = '0' or {gm[o]} = {mm[o]})" if o in own else f"{gm[o]} = {mm[o]}"
           for o, d, _ in ps if d == "out"]
    t = head + tail
    a = t.index("\nbegin\n", t.index("architecture"))
    t = t[:a] + "\n" + "".join(decl) + "\nbegin\n" + "".join(body) + t[a + 7:]
    t = re.sub(r"--\s*psl assert always \(sInit = '0' -> .*\);",
               lambda _: f"-- psl assert always (sInit = '0' -> ({' and '.join(eqs)}));", t)
    assert all(f"=> tm_{p}" in t for p in te.MASK[stem]), stem
    return t


def one(job):
    stem, bits = job
    d = WORK / f"{stem}_b{bits}"
    shutil.rmtree(d, ignore_errors=True); (d / "lib").mkdir(parents=True)
    src = me.CUT.get(stem, lambda s: s)((me.S / f"{stem}.vhd").read_text())
    (d / "gold.vhd").write_text(me.ctr(me.prep(src, f"{stem}.vhd")))
    (d / "eq.vhd").write_text(harness(stem))
    for f in [*map(str, me.BASE), "gold.vhd", "eq.vhd"]:
        r = me.run(["ghdl", "-a", "--std=08", "-frelaxed", "-fpsl", "--workdir=lib", f], d)
        if r.returncode:
            return f"{stem} b{bits} ERROR {r.stderr[-300:]}"
    (d / "p.sby").write_text(f"""[options]
mode prove
[engines]
abc pdr
[script]
plugin -i ghdl
ghdl --std=08 -frelaxed -fpsl --workdir=lib -gBITNESS={bits} eq
prep -top eq
flatten; memory_map; opt -fast; setundef -undriven -zero; setundef -zero -init
[files]
lib
""")
    try:
        me.run(["sby", "-f", "p.sby"], d, timeout=int(os.environ.get("TM_TIMEOUT", "3600")))
    except Exception:
        return f"{stem} b{bits} TIMEOUT"
    st = (d / "p" / "status").read_text().split()[0] if (d / "p" / "status").exists() else "ERROR"
    return f"{stem} b{bits} {'PROVED' if st == 'PASS' else st}"


if __name__ == "__main__":
    import multiprocessing as mp
    jobs = [(s, int(b)) for s in (sys.argv[1:] or te.MASK) for b in os.environ.get("TM_BITS", "8 12 16").split()]
    with mp.Pool(len(jobs)) as p:
        for r in p.imap_unordered(one, jobs):
            print(r, flush=True)
