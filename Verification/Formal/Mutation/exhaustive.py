#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Exhaustive NVC equivalence, gold vs mutant, for modules with few input bits.

  exhaustive.py NAME[,NAME...] LABEL
Every input value at every BITNESS; NVC semantics (resolution, null ranges), so it decides
mutants GHDL synthesis cannot elaborate (multiple drivers, null slices).
"""
import os, re, subprocess as sp, sys, multiprocessing as mp
from pathlib import Path
import module_eq as me, gen_harness as gh

WORK = Path(os.environ.get("FEQ_WORK", "/tmp/feq_exh"))


def width(t, bits):
    if t.lower() == "std_logic":
        return 1
    hi, lo = re.search(r"\((.+?)\s+downto\s+(.+)\)", t).groups()
    env = dict(BITNESS=bits, CO_CQ_WIDTH=8)
    return eval(hi, {}, env) - eval(lo, {}, env) + 1


def check(job):
    name, label, bits = job
    stem = name.split(":")[0]
    m = next(x for x in me.all_mutants(stem) if x[0] == name)
    src = (me.S / f"{stem}.vhd").read_text()
    ls = src.splitlines(keepends=True); ls[m[2]] = m[3] + "\n"
    d = WORK / re.sub(r"\W", "_", f"{name}_{label}_b{bits}"); d.mkdir(parents=True, exist_ok=True)
    (d / "mut_raw.vhd").write_text(me.rename("".join(ls), gh.entities(src)))
    ent = gh.top_instance(label)[0]
    ins = [(n, t) for n, k, t in gh.entity_decl(src, ent)[1] if k == "in"]
    ws = [width(t, bits) for _, t in ins]
    body, pos = [], 0
    for (n, t), w in zip(ins, ws):
        sl = f"v({pos + w - 1} downto {pos})"
        body.append(f"      {n}_i <= v({pos});" if t.lower() == "std_logic" else
                    f"      {n}_i <= {t.split('(')[0].strip()}({sl});")
        pos += w
    h = gh.harness("eq_x", src, label, drive={0: {}})
    eq = re.search(r"assert (.+?) report", h)[1]
    proc = f"""  p_x : process
    variable v : unsigned({pos - 1} downto 0);
    variable bad : natural := 0;
  begin
    for i in 0 to 2 ** {pos} - 1 loop
      v := to_unsigned(i, {pos});
{chr(10).join(body)}
      wait for 1 ns;
      if not ({eq}) then bad := bad + 1; end if;
    end loop;
    report "EXH: " & integer'image(bad) & " of {2 ** pos}";
    wait;
  end process;"""
    h = re.sub(r"  p_replay : process.*?end process;", lambda _: proc, h, flags=re.S)
    (d / "x.vhd").write_text(h)
    w = ["nvc", "--std=2008", f"--work=work:{d}/work"]
    r = me.run(w + ["-a", "--relaxed"] + [str(s) for s in me.BASE] + [str(me.S / f"{stem}.vhd"), "mut_raw.vhd", "x.vhd"], d)
    if r.returncode:
        return name, label, bits, "ANALYSIS " + (r.stdout + r.stderr)[-200:]
    r = me.run(w + ["-e", "--jit", "--no-save", f"-gBITNESS={bits}", "eq_x", "-r"], d, timeout=1800)
    out = r.stdout + r.stderr
    mm = re.search(r"EXH: (\d+) of (\d+)", out)
    return name, label, bits, (("EQUIVALENT" if mm[1] == "0" else f"DIFF {mm[1]}/{mm[2]}") if mm else "RUN " + out[-300:])


if __name__ == "__main__":
    jobs = [(n, sys.argv[2], b) for n in sys.argv[1].split(",") for b in me.BITS]
    with mp.Pool(20) as p:
        for r in p.imap_unordered(check, jobs):
            print(*r, flush=True)
