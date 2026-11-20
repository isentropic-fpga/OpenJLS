#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Gold vs mutant openjls_top, stateful instances cut, proved by Houdini k-induction (houdini.py).

Each stateful instance becomes a shell: its outputs come from a free vector that both copies share, and it exports
its inputs. The check: every shell sees the same inputs in both copies, and the top outputs are the same. Sound by
induction: while the inputs of an instance are the same in both copies, so are its outputs, whatever it contains.
The combinational instances stay real.

  top_eq.py ID [ID ...]   openjls_top mutant IDs (openjls_top:hash)
Env: TE_BITS (8), TE_GEN ("MAX_IMAGE_WIDTH=8 MAX_IMAGE_HEIGHT=4"), TE_WORK, TE_OUT, TE_THREADS (20), and HD_* of houdini.py.
TE_TOKEN=1: per-field candidates on the stage tokens sRegN (one flat register in RTLIL): field equal, and field equal
while the gold token mode is c; stage side registers sRegN* equal while the gold sRegN mode is c. For CO_TOKEN_NONE
fields, which fill the unused fields of valid tokens.
"""
import json, os, re, shutil, sys, multiprocessing as mp
from pathlib import Path

F = Path(__file__).resolve().parent
sys.path[:0] = [str(F), str(F.parent), str(F.parents[1] / "Formal/Common")]
import houdini as hd
import mutants as mut
from prep import prep
from flow import S, ENV, BASE, ORDER, run

WORK = Path(os.environ.get("TE_WORK", "/tmp/top_eq"))
BITS = os.environ.get("TE_BITS", "8")
GEN = os.environ.get("TE_GEN", "MAX_IMAGE_WIDTH=8 MAX_IMAGE_HEIGHT=4").split()
OUT = Path(os.environ.get("TE_OUT", F.parent / "Results/classify/top_eq.jsonl"))
# A15/A16 and the bit packer stay real: bubbles reach their data inputs, which they ignore
CUT = {"line_buffer": "u_line_buffer", "context_ram": "u_ctx_ram", "byte_stuffer": "u_byte_stuffer",
       "jls_framer": "u_framer"}
# Inputs observed only while their enable is set. Each entry is a proof obligation on the module: its outputs do
# not depend on the input while the enable is low (te_mask.py)
MASK = {"context_ram": {"iWrAddr": "iWrEn", "iWrData": "iWrEn", **{p: "iRdEn" for p in
                        ("iRdAddr", "iRdRegular", "iRdRiType", "iRdQ1", "iRdQ2", "iRdQ3")}},
        "line_buffer": {"iPixel": "iValid"}}
# Outputs equal in both copies only while their enable is set (te_mask.py); otherwise each copy reads its own free value
OWN = {"context_ram": {"oRdAlt": "oRdUseAlt"}}
# Combinational relations of the real module kept in the shell ({c} is the free value); each is read off the RTL:
# line_buffer comb_proc drives oValid <= iValid, and oEol/oEoi only while iValid = '1'
PASS = {"line_buffer": {"oValid": "iValid", "oEol": "{c} and iValid", "oEoi": "{c} and iValid"}}
CW = 1024
PSL_ASSERT = re.compile(r"^[ \t]*--[ \t]*psl[ \t]+assert\b.*$", re.M)


def ports(text):
    """Entity name, generic clause text and [(name, dir, type)] of the first entity in text."""
    t = re.sub(r"--.*", "", text)
    e = re.search(r"\bentity\s+(\w+)\s+is(.*?)\bend\s+entity", t, re.S | re.I)
    g = re.search(r"\bgeneric\s*\((.*?)\)\s*;\s*port\b", e[2], re.S | re.I)
    p = e[2][re.search(r"\bport\s*\(", e[2], re.I).end():]
    out = []
    for names, d, ty in re.findall(r"([\w\s,]+?)\s*:\s*(in|out)\s+([^;]+?)\s*(?:;|\)\s*;?\s*$)", p, re.I):
        out += [(n.strip(), d.lower(), ty.strip()) for n in names.split(",")]
    return e[1], (g[1] if g else ""), out


def slv(name, ty):
    return name if ty.lower() == "std_logic" or ty.lower().startswith("std_logic_vector") else f"std_logic_vector({name})"


def shell(stem):
    """Entity <name>_cut with the same generics and ports, plus iCutP (free outputs) and oObsP (its inputs)."""
    name, gen, ps = ports((S / f"{stem}.vhd").read_text())
    uses = re.findall(r"^\s*(?:library|use)\b[^;]*;", (S / f"{stem}.vhd").read_text(), re.M)
    mask, own = MASK.get(stem, {}), OWN.get(stem, {})
    ins = [("m_" + n if n in mask else slv(n, t)) for n, d, t in ps if d == "in" and n.lower() != "iclk"]
    ty = {a: c for a, b, c in ps}
    vec = {n: ty[n].lower() != "std_logic" for n in mask}
    decl = "".join(f"  signal m_{n} : " + (f"std_logic_vector({n}'range)" if vec[n] else "std_logic") + ";\n" for n in mask)
    zero = lambda n: "(others => '0')" if vec[n] else "'0'"
    body, off = [f"  m_{n} <= {slv(n, ty[n])} when {en} = '1' else {zero(n)};" for n, en in mask.items()], "0"
    for n, d, t in ps:
        if d != "out":
            continue
        if t.lower() == "std_logic":
            body.append(f"  {n} <= " + PASS.get(stem, {}).get(n, "{c}").format(c=f"iCutP({off})") + ";")
            off = f"{off} + 1"
        else:
            conv = t.split("(")[0].strip()
            v = f"{conv}(iCutP({off} + {n}'length - 1 downto {off}))"
            if n in own:
                v += f" when {own[n]} = '1' else {conv}(iOwnP({off} + {n}'length - 1 downto {off}))"
            body.append(f"  {n} <= {v};")
            off = f"{off} + {n}'length"
    pdecl = ";\n    ".join(f"{n} : {d} {t}" for n, d, t in ps)
    return "\n".join(uses) + f"""

entity {name}_cut is
  {"generic (" + gen + ");" if gen.strip() else ""}
  port (
    {pdecl};
    iCutP : in std_logic_vector({CW} - 1 downto 0);
    iOwnP : in std_logic_vector({CW} - 1 downto 0);
    oObsP : out std_logic_vector({CW} - 1 downto 0)
  );
end entity {name}_cut;

architecture cut of {name}_cut is
{decl}begin
  oObsP <= std_logic_vector(resize(unsigned(std_logic_vector'({' & '.join(ins)})), {CW}));
{chr(10).join(body)}
end architecture cut;
"""


def top_src(mutant=None):
    lines = (S / "openjls_top.vhd").read_text().split("\n")
    if mutant:
        assert lines[mutant["line"]] == mutant["from"]
        lines[mutant["line"]] = mutant["to"]
    t = PSL_ASSERT.sub("", prep("\n".join(lines), "openjls_top.vhd"))
    ent = "openjls_top_mut" if mutant else "openjls_top"
    t = re.sub(r"\bopenjls_top\b", ent, t)
    k = 0
    for stem, label in CUT.items():
        ename = ports((S / f"{stem}.vhd").read_text())[0]
        m = re.search(rf"^  {label}\s*:\s*entity\s+work\.{ename}\s*\(\w+\)(.*?)\);[ \t]*$", t, re.S | re.M | re.I)
        assert m, label
        inst = re.sub(rf"entity\s+work\.{ename}\s*\(\w+\)", f"entity work.{ename}_cut(cut)", m[0], count=1, flags=re.I)
        inst = inst[:-2] + (f",\n      iCutP => iCut({(k + 1) * CW - 1} downto {k * CW}),"
                            f"\n      iOwnP => iOwn({(k + 1) * CW - 1} downto {k * CW}),"
                            f"\n      oObsP => oObs({(k + 1) * CW - 1} downto {k * CW}));")
        t = t.replace(m[0], inst)
        k += 1
    t = re.sub(r"(\n\s*iReady\s*:\s*in\s+std_logic)", r"\1;\n    iCut, iOwn : in std_logic_vector(%d downto 0);"
               r"\n    oObs : out std_logic_vector(%d downto 0)" % (k * CW - 1, k * CW - 1), t, count=1)
    return t


HARNESS = """library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity eq is
  port (
    clk : in std_logic
  );
end entity eq;

architecture formal of eq is
  attribute anyseq : boolean;
  signal iRst, iValid, iReady : std_logic;
  signal iPixel : std_logic_vector({B} - 1 downto 0);
  signal iW, iH : std_logic_vector(15 downto 0);
  signal iCut, gOwn, mOwn : std_logic_vector({N} - 1 downto 0);
  attribute anyseq of iRst, iValid, iReady, iPixel, iW, iH, iCut, gOwn, mOwn : signal is true;
  signal sInit : std_logic := '1';
  signal gObs, mObs : std_logic_vector({N} - 1 downto 0);
  signal gRdy, mRdy, gV, mV, gL, mL : std_logic;
  signal gD, mD : std_logic_vector({OW} - 1 downto 0);
  signal gK, mK : std_logic_vector({OW} / 8 - 1 downto 0);
begin
  sInit <= '0' when rising_edge(clk);
  u_gold : entity work.openjls_top
    generic map ({G})
    port map (iClk => clk, iRst => iRst, iValid => iValid, iPixel => iPixel, oReady => gRdy,
              iImageWidth => iW, iImageHeight => iH, oData => gD, oValid => gV, oKeep => gK,
              oLast => gL, iReady => iReady, iCut => iCut, iOwn => gOwn, oObs => gObs);
  u_mut : entity work.openjls_top_mut
    generic map ({G})
    port map (iClk => clk, iRst => iRst, iValid => iValid, iPixel => iPixel, oReady => mRdy,
              iImageWidth => iW, iImageHeight => iH, oData => mD, oValid => mV, oKeep => mK,
              oLast => mL, iReady => iReady, iCut => iCut, iOwn => mOwn, oObs => mObs);
  -- psl default clock is rising_edge(clk);
  -- psl assume always (sInit = '1' -> iRst = '1');
  -- psl assert always (sInit = '0' -> (gObs = mObs and gRdy = mRdy and gV = mV and gL = mL and gD = mD and gK = mK));
end architecture formal;
"""


def token_layout():
    """{field: (lsb, width)} of t_pipeline_token at TE_BITS and TE_GEN."""
    import const_eq as ce
    t = ce.code((S / "openjls_top.vhd").read_text())
    gens = {k.lower(): int(v) for k, v in (g.split("=") for g in GEN)}
    env = ce.evaluate(ce.top_decls(), {**ce.evaluate(ce.decls((S / "openjls_pkg.vhd").read_text()), {}),
                                       "bitness": int(BITS), "out_width": 64, **gens})
    modes = len(re.search(r"type t_token_mode is \((.*?)\)", t)[1].split(","))
    lay, lo = {}, 0
    for n, ty in re.findall(r"(\w+)\s*:\s*([^;]+);", t[t.index("type t_pipeline_token is record"):
                                                       t.index("end record t_pipeline_token")]):
        ty = ty.strip()
        if ty == "t_token_mode":
            w = max(1, (modes - 1).bit_length())
        elif ty == "std_logic":
            w = 1
        else:
            a, b = re.search(r"\((.*)\s+downto\s+(.*)\)", ty).groups()
            w = eval(ce.pyexpr(a), {"__builtins__": {}}, {**ce.FUN, **env}) - int(b) + 1
        lay[n], lo = (lo, w), lo + w
    return lay, lo, modes


def token_cands(il):
    if os.environ.get("TE_TOKEN") != "1":
        return []
    lay, total, modes = token_layout()
    w = hd.il_widths(il)
    regs = [k[len("\\u_gold."):] for k, v in w.items() if re.fullmatch(r"\\u_gold\.sreg\d", k) and v == total
            and w.get("\\u_mut." + k[len("\\u_gold."):]) == total]
    ml, mw = lay["mode"]
    out = []
    for r in regs:
        mode = f'g("{r}").f({ml}, {mw})'
        out.append(("expr", f'{mode} == m("{r}").f({ml}, {mw})'))
        for fld, (lo, fw) in lay.items():
            if fld == "mode":
                continue
            eq = f'g("{r}").f({lo}, {fw}) == m("{r}").f({lo}, {fw})'
            out += [("expr", eq)] + [("expr", f"imp({mode} == {c}, {eq})") for c in range(modes)]
        side = [k[len("\\u_gold."):] for k in w if k.startswith(f"\\u_gold.{r}") and k != f"\\u_gold.{r}"
                and f"\\u_mut.{k[len(chr(92) + 'u_gold.'):]}" in w]
        out += [("expr", f'imp({mode} == {c}, g("{x}") == m("{x}"))') for x in side for c in range(modes)]
    return out


def build(name):
    stem, h = name.split(":")
    m = next(x for x in mut.all_mutants((S / "openjls_top.vhd").read_text(), stem) if x["id"] == name)
    d = WORK / re.sub(r"\W", "_", f"{name}_b{BITS}_{'_'.join(GEN)}")
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    files = [str(f) for f in BASE]
    for n in ORDER:
        if n == "openjls_top":
            for x, mm in (("openjls_top.vhd", None), ("openjls_top_mut.vhd", m)):
                (d / x).write_text(top_src(mm))
                files.append(x)
        elif n in CUT:
            (d / f"{n}_cut.vhd").write_text(shell(n))
            files.append(f"{n}_cut.vhd")
        else:
            (d / f"{n}.vhd").write_text(PSL_ASSERT.sub("", prep((S / f"{n}.vhd").read_text(), f"{n}.vhd")))
            files.append(f"{n}.vhd")
    gens = dict(g.split("=") for g in GEN)
    ow = int(gens.get("OUT_WIDTH", 64))
    (d / "eq.vhd").write_text(HARNESS.format(B=BITS, N=len(CUT) * CW, OW=ow,
                                             G=", ".join([f"BITNESS => {BITS}"] + [g.replace("=", " => ") for g in GEN])))
    files.append("eq.vhd")
    (d / "lib").mkdir()
    r = run(["ghdl", "-a", "--std=08", "-frelaxed", "-fpsl", "--workdir=lib"] + files, d)
    if r.returncode:
        raise RuntimeError("ghdl -a: " + (r.stdout + r.stderr)[-1500:])
    (d / "p.sby").write_text("""[options]
mode prove
[engines]
smtbmc yices
[script]
plugin -i ghdl
ghdl --std=08 -frelaxed -fpsl --workdir=lib eq
prep -top eq
flatten; memory_map; opt -fast; setundef -undriven -zero; setundef -zero -init
[files]
lib
""")
    return d


def one(name):
    try:
        d = build(name)
        il = hd.base_il(d)
    except Exception as e:  # noqa: BLE001
        return dict(name=name, res="ERROR", info=str(e)[-800:])
    cands = hd.pairs(il) + hd.autoguards(il) + hd.extras(il) + token_cands(il)
    n0 = len(cands)
    for rnd in range(hd.ROUNDS):
        st, failed, where = hd.solve(d, hd.with_cands(il, cands), rnd)
        if st == "PASS":
            shutil.rmtree(d, ignore_errors=True)
            return dict(name=name, res="PROVED", depth=hd.DEPTH, kept=len(cands), cands=n0, rounds=rnd + 1)
        if st == "TIMEOUT":
            return dict(name=name, res="TIMEOUT", kept=len(cands), cands=n0, rounds=rnd + 1)
        if st not in ("FAIL", "UNKNOWN"):
            return dict(name=name, res="ERROR", info=st)
        idx = {int(f[2:]) for f in failed if re.fullmatch(r"h_\d+", f)}
        if not idx:
            return dict(name=name, res="DIFF_BASE" if where == "base" else "UNKNOWN", kept=len(cands), cands=n0,
                        rounds=rnd + 1, failed=sorted(failed))
        cands = [c for i, c in enumerate(cands) if i not in idx]
    return dict(name=name, res="ROUNDS", kept=len(cands), cands=n0)


if __name__ == "__main__":
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with mp.get_context("fork").Pool(min(len(sys.argv) - 1, int(os.environ.get("TE_THREADS", "20")))) as p, \
            open(OUT, "a") as f:
        for r in p.imap_unordered(one, sys.argv[1:]):
            r.update(bits=BITS, gen=" ".join(GEN))
            f.write(json.dumps(r) + "\n"); f.flush()
            print(json.dumps(r), flush=True)
