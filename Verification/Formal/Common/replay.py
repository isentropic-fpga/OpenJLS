#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Replay a formal counterexample (SBY trace.vcd) on the same harness in NVC.

A DIFF counts only if NVC, on the unprepped mutant, also fails the PSL assert:
this keeps GHDL synth bugs (see prep.py) out of the verdict.
"""
import re, subprocess as sp
from pathlib import Path


def ports(harness):
    """[(name, dir, type)] of the harness entity."""
    t = Path(harness).read_text()
    body = re.search(r"port\s*\((.*?)\);\s*end\s+entity", t, re.S | re.I)[1]
    out = []
    for decl in body.split(";"):
        m = re.match(r"\s*([\w\s,]+?)\s*:\s*(in|out)\s+(.+)", decl.strip(), re.S | re.I)
        if m:
            for n in m[1].split(","):
                out.append((n.strip(), m[2].lower(), " ".join(m[3].split())))
    return out


def vcd_inputs(vcd, names):
    """{time: {port: bits}} for top-scope ports in names."""
    want = {n.lower(): n for n in names}
    ids, depth, t, seq = {}, 0, 0, {}
    for line in open(vcd):
        tok = line.split()
        if not tok:
            continue
        if tok[0] == "$scope":
            depth += 1
        elif tok[0] == "$upscope":
            depth -= 1
        elif tok[0] == "$var" and depth == 1 and tok[4].lower() in want:
            ids[tok[3]] = want[tok[4].lower()]
        elif tok[0].startswith("#"):
            t = int(tok[0][1:])
        elif tok[0][0] == "b" and len(tok) == 2 and tok[1] in ids:
            seq.setdefault(t, {})[ids[tok[1]]] = tok[0][1:]
        elif tok[0][0] in "01xz" and tok[0][1:] in ids:
            seq.setdefault(t, {})[ids[tok[0][1:]]] = tok[0][0]
    return seq


def tb_text(harness, vcd, generics):
    ps = ports(harness)
    ent = Path(harness).stem
    ins = [p for p in ps if p[1] == "in"]
    seq = vcd_inputs(vcd, [p[0] for p in ins])
    gen = "; ".join(f"{k} : integer := {v}" for k, v in generics.items())
    gmap = ", ".join(f"{k} => {k}" for k in generics)
    decl = "\n".join(f"  signal {n} : {typ};" for n, _, typ in ps)
    pmap = ", ".join(f"{n} => {n}" for n, _, _ in ps)
    steps = []
    prev = 0
    for t in sorted(seq):
        if t > prev:
            steps.append(f"    wait for {t - prev} ns;")
            prev = t
        for n, bits in seq[t].items():
            typ = next(p[2] for p in ins if p[0] == n)
            steps.append(f"    {n} <= {lit_expr(n, typ, bits)};")
    body = "\n".join(steps)
    clk = next((p[0] for p in ins if p[0].lower() == "clk"), None)
    final = (f"    wait for 1 ns; {clk} <= '0'; wait for 1 ns; {clk} <= '1'; wait for 1 ns;"
             if clk else "    wait for 1 ns;")
    return f"""library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity tb_replay is generic ({gen}); end;
architecture a of tb_replay is
{decl}
begin
  dut : entity work.{ent} generic map ({gmap}) port map ({pmap});
  process begin
{body}
{final}
    report "REPLAY: END"; wait;
  end process;
end;
"""


def lit_expr(name, typ, bits):
    tl = typ.lower()
    if tl == "std_logic":
        return f"'{bits[-1]}'"
    # VCD drops leading zeros; resize from an unsigned/signed literal of the VCD width
    base = "signed" if tl.startswith("signed") else "unsigned"
    conv = "" if tl.startswith(("signed", "unsigned")) else "std_logic_vector"
    e = f"resize(unsigned'(\"{bits}\"), {name}'length)"
    if base == "signed":
        e = f"signed({e})"
    return f"{conv}({e})" if conv else e


def replay(d, harness, generics, sources):
    """'CONFIRMED' if NVC fails the assert on the trace, else 'NOT_CONFIRMED'."""
    vcd = d / "p" / "engine_0" / "trace.vcd"
    if not vcd.exists():
        return "NO_TRACE"
    (d / "tb_replay.vhd").write_text(tb_text(harness, vcd, generics))
    nv = d / "nvc"; nv.mkdir(exist_ok=True)
    r = sp.run(["nvc", "--std=2008", f"--work=work:{nv}/work", "-a", "--relaxed", "--psl"]
               + [str(s) for s in sources] + [str(harness), str(d / "tb_replay.vhd")],
               cwd=d, capture_output=True, text=True, errors="replace")
    if r.returncode:
        return "REPLAY_ERROR " + (r.stdout + r.stderr)[-300:]
    r = sp.run(["nvc", "--std=2008", f"--work=work:{nv}/work", "-e", "--jit", "--no-save"]
               + [f"-g{k}={v}" for k, v in generics.items()] + ["tb_replay", "-r"],
               cwd=d, capture_output=True, text=True, errors="replace", timeout=300)
    out = r.stdout + r.stderr
    if "REPLAY: END" not in out and "Assertion" not in out:
        return "REPLAY_ERROR " + out[-300:]
    return "CONFIRMED" if re.search(r"(Error|Failure).*(Assertion|assert)|Assertion.*violated|PSL", out) else "NOT_CONFIRMED"
