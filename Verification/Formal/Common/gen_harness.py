#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Generate a gold-vs-mutant harness for one module instance of openjls_top.

Generics, constants and the generic map come verbatim from openjls_top.vhd, so the module
is checked exactly as the top instantiates it. Inputs are free (anyseq); `assumes` are PSL
lines over the input signal names (port name + "_i").
"""
import re
from flow import S


def entities(src):
    return re.findall(r"^entity\s+(\w+)\s+is", src, re.M | re.I)


def _block(text, start):
    """Text inside the parenthesis that opens at or after start."""
    i = text.index("(", start); depth = 0
    for j in range(i, len(text)):
        depth += text[j] == "("; depth -= text[j] == ")"
        if depth == 0:
            return text[i + 1:j]
    raise ValueError("unbalanced")


def _strip_comments(t):
    return re.sub(r"--[^\n]*", "", t)


def entity_decl(src, ent):
    """(generics {name: default}, ports [(name, dir, type)])."""
    m = re.search(rf"^entity\s+{ent}\s+is(.*?)^end\s+entity", src, re.M | re.S | re.I)
    body = _strip_comments(m[1])
    gens, ports = {}, []
    g = re.search(r"\bgeneric\s*\(", body, re.I)
    if g:
        for d in _block(body, g.start()).split(";"):
            mm = re.match(r"\s*([\w\s,]+?)\s*:\s*[^:=]+?(?::=\s*(.+))?$", d.strip(), re.S)
            if mm:
                for n in mm[1].split(","):
                    gens[n.strip()] = " ".join(mm[2].split()) if mm[2] else None
    p = re.search(r"\bport\s*\(", body, re.I)
    for d in _block(body, p.start()).split(";"):
        mm = re.match(r"\s*([\w\s,]+?)\s*:\s*(in|out)\s+(.+)$", d.strip(), re.S | re.I)
        if mm:
            for n in mm[1].split(","):
                ports.append((n.strip(), mm[2].lower(), " ".join(mm[3].split())))
    return gens, ports


def top_instance(label):
    """(entity, arch, generic map {formal: actual}) of instance `label` in openjls_top."""
    top = _strip_comments((S / "openjls_top.vhd").read_text())
    m = re.search(rf"\b{label}\s*:\s*entity\s+work\.(\w+)\s*(?:\((\w+)\))?", top)
    gmap = {}
    g = re.search(r"generic\s+map\s*\(", top[m.end():m.end() + 400])
    if g:
        for a in _block(top, m.end() + g.start()).split(","):
            f, act = a.split("=>")
            gmap[f.strip()] = act.strip()
    return m[1], m[2], gmap


def top_context():
    """Top generics (as harness generics) and its constant declarations."""
    top = (S / "openjls_top.vhd").read_text()
    gens, _ = entity_decl(top, "openjls_top")
    arch = re.search(r"^architecture\s+\w+\s+of\s+openjls_top\s+is(.*?)^\s*type\s", top, re.M | re.S)[1]
    consts = [" ".join(c.split()) + ";" for c in re.findall(r"^\s*(constant\s[^;]+);", _strip_comments(arch), re.M)]
    return gens, consts


def replay_process(drive, types, eq):
    """Apply each trace step, let it settle, then compare (no delta-cycle glitches)."""
    lines = []
    names = {n.lower(): n for n in types}
    for t in sorted(drive):
        lines.append(f"    wait for {t} ns - now;" if t else "")
        step = dict(drive[t])
        # The edge samples the previous step's inputs; no edge at t = 0 (clk starts high)
        ck = next((k for k in step if k.lower() == "clk"), None)
        if ck is not None:
            if step.pop(ck)[-1] == "1":
                if t:
                    lines.append("    clk <= '1';\n    wait for 1 ps;")
            else:
                lines.append("    clk <= '0';")
        for v, bits in step.items():
            n = names.get(v.lower())
            if n is None or n == "clk":
                continue
            if types[n].lower() == "std_logic":
                lines.append(f"    {n} <= '{bits[-1]}';")
            else:
                e = f"resize(unsigned'(\"{bits}\"), {n}'length)"
                kind = types[n].split("(")[0].strip().lower()
                lines.append(f"    {n} <= {kind}({e});" if kind != "unsigned" else f"    {n} <= {e};")
        lines.append(f"    wait for 1 ps;\n    assert {eq} report \"REPLAY: DIFF\" severity error;")
    body = "\n".join(l for l in lines if l)
    return f"""  p_replay : process
  begin
{body}
    report "REPLAY: END";
    wait;
  end process;"""


def subst(typ, gmap):
    for f, a in gmap.items():
        typ = re.sub(rf"\b{f}\b", f"({a})", typ)
    return typ


def harness(name, src, label, assumes=(), clock=None, drive=None, bind=None, reset=None):
    """VHDL text of entity `name`: module instance `label`, gold vs <ent>_mut.

    drive = {time_ns: {signal: bits}} gives the NVC replay form: inputs from a trace, plain assert.
    bind = (decls, stmts, {port: signal}): gold producers drive those ports instead of free inputs.
    clock, reset: port names; reset is held in the first cycle and outputs compare from the second.
    """
    bdecl, bstmt, bports = bind or ("", "", {})
    ent, arch, gmap = top_instance(label)
    mgens, ports = entity_decl(src, ent)
    full = {g: gmap.get(g, d) for g, d in mgens.items() if g in gmap or d is not None}
    tgens, consts = top_context()
    tg = ";\n    ".join(f"{g} : natural := {d}" for g, d in tgens.items())
    ins = [p for p in ports if p[1] == "in"]
    outs = [p for p in ports if p[1] == "out"]
    sig = []
    for n, _, t in ins:
        if n == clock or n in bports:
            continue
        sig.append(f"  signal {n}_i : {subst(t, full)};")
        if drive is None:
            sig.append(f"  attribute anyseq of {n}_i : signal is true;")
    for n, _, t in outs:
        sig.append(f"  signal g_{n}, m_{n} : {subst(t, full)};")
    gm = ", ".join(f"{g} => {a}" for g, a in full.items())
    a_ = f"({arch})" if arch else ""
    port_txt = ";\n  port (\n    clk : in std_logic\n  )" if drive is None else ""
    if drive is not None:
        sig.append("  signal clk : std_logic := '1';")

    def inst(lbl, e, pre):
        pm = [f"{n} => {'clk' if n == clock else bports.get(n, n + '_i')}" for n, _, _ in ins]
        pm += [f"{n} => {pre}_{n}" for n, _, _ in outs]
        gmap_txt = f"    generic map ({gm})\n" if gm else ""
        return (f"  {lbl} : entity work.{e}{a_}\n{gmap_txt}"
                f"    port map ({', '.join(pm)});")
    eq = " and ".join(f"g_{n} = m_{n}" for n, _, _ in outs)
    if reset:
        assumes = [f"sInit = '1' -> {reset}_i = '1'"] + list(assumes)
        sig.append("  signal sInit : std_logic := '1';")
    psl = "\n".join(f"  -- psl assume always ({a});" for a in assumes)
    gate = "sInit = '0' -> " if reset else ""
    check = f"  -- psl default clock is rising_edge(clk);\n{psl}\n  -- psl assert always ({gate}({eq}));"
    if drive is not None:
        types = {n + "_i": t for n, _, t in ins if n not in bports and n != clock}
        if clock:
            types["clk"] = "std_logic"
        check = replay_process(drive, types, f"sInit = '1' or ({eq})" if reset else eq)
    if reset:
        check = "  sInit <= '0' when rising_edge(clk);\n" + check
    return f"""-- Generated by gen_harness.py: {ent} as {label} in openjls_top, gold vs mutant
library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.all;

entity {name} is
  generic (
    {tg}
  ){port_txt};
end entity {name};

architecture formal of {name} is

  {chr(10).join('  ' + c for c in consts).strip()}
  attribute anyseq : boolean;
{chr(10).join(sig)}
{bdecl}

begin
{bstmt}

{inst('u_gold', ent, 'g')}

{inst('u_mut', ent + '_mut', 'm')}

{check}

end architecture formal;
"""


if __name__ == "__main__":
    import sys
    print(harness("eq_" + sys.argv[2], (S / f"{sys.argv[1]}.vhd").read_text(), sys.argv[2]))
