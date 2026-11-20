#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Gold vs mutant k-induction with lockstep helpers found by Houdini, for module_eq.py env harnesses.

Candidates: u_gold.X = u_mut.X for every register pair of equal width. Each round proves the main
assert plus all candidates; candidates that fail (base or step) are dropped. Ends PROVED when the step
closes, DIFF when the main assert fails in the base case, UNKNOWN when only the main assert fails the step.
Kept candidates are proved with the main assert, so they add no trust.

  houdini.py NAME [NAME ...]   mutant IDs (stem:hash), same FEQ_* env as module_eq.py
HD_GUARD="ARRAY:COUNT:DEPTH[,...]": also cnt_gold > k -> gold.ARRAY(k) = mut.ARRAY(k) per slot k (both slot orders),
for queues whose dead slots may differ.
HD_AUTOGUARD=1: guarded equalities (gold.r = c or /= c, r of <= HD_GUARD_BITS bits) -> gold.X = mut.X, for reset values;
HD_AUTOINV=1 adds gold-only implications between those guards. HD_TARGET=1: those guards only on the register
that the mutant line assigns (far fewer candidates).
HD_EXTRA=FILE: one candidate per line, a Python expression over g("reg") and m("reg") (gold / mutant register),
h("reg") (harness register), int constants, ==, &, |, ~, imp(a, b), x.f(lo, w) (bit slice) and x.top(y, n) (top n bits equal); for relations that are not register equalities (e.g. a one-cycle shift).
HD_PREFIX=BUF:COUNT[,...]: g(BUF).top(m(BUF), g(COUNT)) candidates, for buffers whose bits past a fill count are stale.
Env: HD_DEPTH (k, default 4), HD_ROUNDS (40), HD_TIMEOUT (s per round, 1800), HD_THREADS (20), HD_OUT.
"""
import json, os, re, shutil, sys, multiprocessing as mp
from pathlib import Path

F = Path(__file__).resolve().parent
sys.path[:0] = [str(F), str(F.parent), str(F.parents[1] / "Formal/Common")]
import module_eq as me
from flow import RESULTS, run

DEPTH = int(os.environ.get("HD_DEPTH", "4"))
ROUNDS = int(os.environ.get("HD_ROUNDS", "40"))
TIMEOUT = int(os.environ.get("HD_TIMEOUT", "1800"))
OUT = Path(os.environ.get("HD_OUT", F.parent / "Results/classify/houdini.jsonl"))


def build(name):
    """module_eq work dir (harness, gold, mutant, analysed lib) without solving."""
    stem = name.split(":")[0]
    m = next(x for x in me.all_mutants(stem) if x[0] == name)
    label = me.HARNESS[stem][0][0]
    old = os.environ.get("FEQ_SBY_TIMEOUT")
    os.environ["FEQ_SBY_TIMEOUT"] = "1"
    try:
        r = me.one_(m + (label, me.BITS[0]))
    finally:
        os.environ.pop("FEQ_SBY_TIMEOUT") if old is None else os.environ.__setitem__("FEQ_SBY_TIMEOUT", old)
    d = me.WORK / re.sub(r"\W", "_", f"{name}_{label}_b{me.BITS[0]}_{'_'.join(me.GENERICS)}")
    return d, r


def base_il(d):
    s = (d / "p.sby").read_text()
    script = s.split("[script]\n")[1].split("[files]")[0]
    (d / "h_base.ys").write_text(script.replace("--workdir=lib", "--workdir=lib") + "write_rtlil h_base.il\n")
    r = run(["yosys", "-q", "-s", "h_base.ys"], d)
    if r.returncode:
        raise RuntimeError(r.stderr[-800:])
    return (d / "h_base.il").read_text()


def qbits(spec, widths):
    """(wire, bit) list of an RTLIL SigSpec: a wire, a slice, or a { } concat (MSB first)."""
    parts = re.findall(r"(\\\S+|\$\S+)(?: \[(\d+)(?::(\d+))?\])?", spec.strip().strip("{}"))
    out = []
    for w, hi, lo in parts:
        if hi == "":
            out += [(w, b) for b in range(widths.get(w, 1) - 1, -1, -1)]
        else:
            out += [(w, b) for b in range(int(hi), int(lo or hi) - 1, -1)]
    return out


def ff_bits(il):
    widths = {m[2]: int(m[1] or 1) for m in re.finditer(r"^\s*wire (?:width (\d+) )?(?:\w+ \d+ )*(\S+)$", il, re.M)}
    ff = set()
    for c in re.finditer(r"^\s*cell \$\w*dff\w* \S+\n(.*?)^\s*end$", il, re.M | re.S):
        q = re.search(r"connect \\Q (.+)", c[1])
        if q:
            ff |= set(qbits(q[1], widths))
    return ff, widths


def gold_regs(il):
    """Gold registers whose bits are all FFs. Includes those yosys merged with the mutant copy (same driver)."""
    ff, w = ff_bits(il)
    n = {}
    for x, b in ff:
        if x.startswith("\\u_gold."):
            n[x] = n.get(x, 0) + 1
    return [x[len("\\u_gold."):] for x, k in sorted(n.items()) if k == w[x]]


def pairs(il):
    """Per gold register: the FF bits that the mutant also has as FFs under the same name."""
    ff, widths = ff_bits(il)
    by = {}
    for w, b in ff:
        if w.startswith("\\u_gold.") and ("\\u_mut." + w[len("\\u_gold."):], b) in ff:
            by.setdefault(w, []).append(b)
    return [(w, "\\u_mut." + w[len("\\u_gold."):], sorted(bs, reverse=True)) for w, bs in sorted(by.items())]


def guard_cells(i, guard):
    if not guard:
        return ""
    c, cw, k = guard
    return f"""  wire $h_g{i}
  wire $h_z{i}
  wire $h_n{i}
  cell $gt $h_gt{i}
    parameter \\A_SIGNED 0
    parameter \\B_SIGNED 0
    parameter \\A_WIDTH {cw}
    parameter \\B_WIDTH 32
    parameter \\Y_WIDTH 1
    connect \\A {c}
    connect \\B {k}
    connect \\Y $h_g{i}
  end
  cell $logic_or $h_or{i}
    parameter \\A_SIGNED 0
    parameter \\B_SIGNED 0
    parameter \\A_WIDTH 1
    parameter \\B_WIDTH 1
    parameter \\Y_WIDTH 1
    connect \\A $h_y{i}
    connect \\B $h_n{i}
    connect \\Y $h_z{i}
  end
  cell $logic_not $h_not{i}
    parameter \\A_SIGNED 0
    parameter \\A_WIDTH 1
    parameter \\Y_WIDTH 1
    connect \\A $h_g{i}
    connect \\Y $h_n{i}
  end
"""


def guards(il):
    """Guarded slot candidates from HD_GUARD, as (gold, mut, bits, count wire) with a slot index."""
    widths = {m[2]: int(m[1] or 1) for m in re.finditer(r"^\s*wire (?:width (\d+) )?(?:\w+ \d+ )*(\S+)$", il, re.M)}
    out = []
    for spec in filter(None, os.environ.get("HD_GUARD", "").split(",")):
        arr, cnt, depth = spec.split(":")
        depth = int(depth)
        g, m, c = "\\u_gold." + arr, "\\u_mut." + arr, "\\u_gold." + cnt
        if g not in widths or m not in widths or c not in widths or widths[g] != widths[m]:
            continue
        ew = widths[g] // depth
        for k in range(depth):
            for slot in (k, depth - 1 - k):
                bs = list(range((slot + 1) * ew - 1, slot * ew - 1, -1))
                out.append((g, m, bs, (c, widths[c], k)))
    return out


class _E:
    """1-bit or vector RTLIL signal; operators append cells to the shared context."""

    def __init__(self, sig, w, ctx):
        self.sig, self.w, self.ctx = sig, w, ctx

    def _cell(self, typ, b, yw=1):
        c = self.ctx
        c["n"] += 1
        y = f"{c['pre']}{c['n']}"
        ports = f"    parameter \\A_WIDTH {self.w}\n    connect \\A {self.sig}\n"
        if b is not None:
            ports += f"    parameter \\B_SIGNED 0\n    parameter \\B_WIDTH {b.w}\n    connect \\B {b.sig}\n"
        w = f"width {yw} " if yw > 1 else ""
        c["cells"].append(f"  wire {w}{y}\n  cell ${typ} {y}_c\n    parameter \\A_SIGNED 0\n{ports}"
                          f"    parameter \\Y_WIDTH {yw}\n    connect \\Y {y}\n  end\n")
        return _E(y, yw, c)

    def _k(self, o):
        return o if isinstance(o, _E) else _E(f"{self.w}'{o:0{self.w}b}", self.w, self.ctx)

    def __eq__(self, o):
        return self._cell("eq", self._k(o))

    def __and__(self, o):
        return self._cell("logic_and", self._k(o))

    def __or__(self, o):
        return self._cell("logic_or", self._k(o))

    def __invert__(self):
        return self._cell("logic_not", None)

    def f(self, lo, w):
        """Bits lo + w - 1 downto lo (a record field: GHDL packs the first field at bit 0)."""
        return _E(f"{self.sig} [{lo + w - 1}:{lo}]", w, self.ctx)

    def top(self, o, n):
        """1 when the top n bits (MSB first; index 0 of an ascending vector) of self and o are equal."""
        x = self._cell("xor", self._k(o), self.w)
        keep = _E(f"{self.w}'{'1' * self.w}", self.w, self.ctx)._cell("shr", n, self.w)._cell("not", None, self.w)
        return x._cell("and", keep, self.w)._cell("logic_not", None)


def expr_cells(src, widths, pre):
    """RTLIL cells for an HD_EXTRA expression; returns (text, 1-bit output wire)."""
    ctx = dict(n=0, pre=pre, cells=[])
    sig = lambda p: lambda r: _E(f"\\u_{p}.{r}", widths[f"\\u_{p}.{r}"], ctx)
    h = lambda r: _E(f"\\{r}", widths[f"\\{r}"], ctx)
    e = eval(src, {"__builtins__": {}}, dict(g=sig("gold"), m=sig("mut"), h=h, imp=lambda a, b: (~a) | b))
    return "".join(ctx["cells"]), e.sig


def il_widths(il):
    return {m[2]: int(m[1] or 1) for m in re.finditer(r"^\s*wire (?:width (\d+) )?(?:\w+ \d+ )*(\S+)$", il, re.M)}


def target(name):
    """Register that the mutant line assigns (lower case, as in RTLIL), or None."""
    stem, line = name.split(":")[0], next(x for x in me.all_mutants(name.split(":")[0]) if x[0] == name)[2]
    k = re.match(r"\s*(\w+)\s*(?:\(.*?\))?\s*<=", (me.S / f"{stem}.vhd").read_text().splitlines()[line])
    return k[1].lower() if k else None


def autoguards(il, only=None):
    """HD_AUTOGUARD=1: guard -> gold.X = mut.X for every full-width register pair X, where the guard is
    gold.r = c or gold.r /= c for every register r of at most HD_GUARD_BITS (3) bits and every value c; for
    registers that differ only while a valid bit or an FSM state says they are unused (reset values)."""
    if os.environ.get("HD_AUTOGUARD") != "1" and only is None:
        return []
    w = il_widths(il)
    full = [g[len("\\u_gold."):] for g, m, bs in pairs(il) if len(bs) == w[g]]
    small = [x for x in gold_regs(il) if w["\\u_gold." + x] <= int(os.environ.get("HD_GUARD_BITS", "3"))]
    atoms = []
    for r in small:
        n = w["\\u_gold." + r]
        atoms += [f'g("{r}") == {c}' for c in range(2 ** n)]
        atoms += [f'~(g("{r}") == {c})' for c in range(2 ** n)] if n > 1 else []
    out = [("expr", f'imp({a}, g("{x}") == m("{x}"))') for x in full for a in atoms
           if f'"{x}"' not in a and only in (None, x)]
    # Gold-only state invariants a -> b between different small registers (e.g. preload -> first row): the
    # guarded equalities need them to exclude unreachable states in the induction step
    reg = lambda a: a.split('"')[1]
    if os.environ.get("HD_AUTOINV") != "1":
        return out
    return out + [("expr", f"imp({a}, {b})") for a in atoms for b in atoms if reg(a) != reg(b)]


def extras(il):
    f = os.environ.get("HD_EXTRA")
    out = [("expr", l.strip()) for l in open(f) if l.strip() and not l.startswith("#")] if f else []
    # Registers whose width the mutant changes: equal after zero extension ($eq extends the narrower side)
    w = il_widths(il)
    out += [("expr", f'g("{x}") == m("{x}")') for x in gold_regs(il)
            if f"\\u_mut.{x}" in w and w[f"\\u_mut.{x}"] != w[f"\\u_gold.{x}"]]
    # HD_PREFIX=BUF:COUNT[,...]: gold.BUF and mut.BUF agree in their top gold.COUNT bits (bits past a fill count)
    for spec in filter(None, os.environ.get("HD_PREFIX", "").split(",")):
        b, c = spec.split(":")
        if not all(re.search(rf"^\s*wire .*\\u_(gold|mut)\.{x}$", il, re.M) for x in (b, c)):
            continue
        out.append(("expr", f'g("{b}").top(m("{b}"), g("{c}"))'))
    return out


def with_cands(il, cands):
    cells = []
    widths = il_widths(il)
    for i, cand in enumerate(cands):
        if cand[0] == "expr":
            text, y = expr_cells(cand[1], widths, f"$h_x{i}_")
            cells.append(f"""{text}  attribute \\src "houdini:{i}"
  cell $assert \\h_{i}
    connect \\A {y}
    connect \\EN 1'1
  end
""")
            continue
        g, m, bs = cand[:3]
        guard = cand[3] if len(cand) > 3 else None
        w = len(bs)
        cat = lambda n: "{ " + " ".join(f"{n} [{b}]" for b in bs) + " }"
        g, m = cat(g), cat(m)
        cells.append(f"""  wire $h_y{i}
  cell $eq $h_eq{i}
    parameter \\A_SIGNED 0
    parameter \\B_SIGNED 0
    parameter \\A_WIDTH {w}
    parameter \\B_WIDTH {w}
    parameter \\Y_WIDTH 1
    connect \\A {g}
    connect \\B {m}
    connect \\Y $h_y{i}
  end
{guard_cells(i, guard)}  attribute \\src "houdini:{i}"
  cell $assert \\h_{i}
    connect \\A {"$h_z" + str(i) if guard else "$h_y" + str(i)}
    connect \\EN 1'1
  end
""")
    i = il.index("module \\eq")
    j = il.index("\nend\n", i)
    return il[:j + 1] + "".join(cells) + il[j + 1:]


def solve(d, il, rnd):
    (d / "h.il").write_text(il)
    (d / "h.sby").write_text(f"""[options]
mode prove
depth {DEPTH}
[engines]
smtbmc yices
[script]
read_rtlil h.il
[files]
h.il
""")
    shutil.rmtree(d / "h", ignore_errors=True)
    try:
        p = run(["sby", "-f", "h.sby"], d, timeout=TIMEOUT)
    except Exception:
        return "TIMEOUT", set(), ""
    st = (d / "h" / "status").read_text().split()[0] if (d / "h" / "status").exists() else "ERROR"
    log = p.stdout
    base_fail = "basecase" in log and re.search(r"basecase: .*Assert failed", log) is not None
    failed = set(re.findall(r"Assert failed in \S+: (?:\S*?)(h_\d+|\S+)", log))
    return st, failed, "base" if base_fail else "step"


def houdini(name):
    d, r = build(name)
    if r["res"] not in ("TIMEOUT",):
        return dict(name=name, res="SKIP", info=r["res"])
    il = base_il(d)
    tgt = target(name) if os.environ.get("HD_TARGET") == "1" else None
    cands = pairs(il) + guards(il) + (autoguards(il, tgt) if tgt else autoguards(il)) + extras(il)
    n0 = len(cands)
    for rnd in range(ROUNDS):
        st, failed, where = solve(d, with_cands(il, cands), rnd)
        if st == "PASS":
            shutil.rmtree(d, ignore_errors=True)
            return dict(name=name, res="PROVED", depth=DEPTH, kept=len(cands), cands=n0, rounds=rnd + 1,
                        kept_names=[c[1] if c[0] == "expr" else
                                    c[0][len("\\u_gold."):] + ("[guarded %d]" % c[3][2] if len(c) > 3 else "") for c in cands])
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
    with mp.get_context("fork").Pool(min(len(sys.argv) - 1, int(os.environ.get("HD_THREADS", "20")))) as p, \
            open(OUT, "a") as f:
        for r in p.imap_unordered(houdini, sys.argv[1:]):
            r["gen"] = " ".join(me.GENERICS)
            f.write(json.dumps(r) + "\n"); f.flush()
            print(json.dumps(r), flush=True)
