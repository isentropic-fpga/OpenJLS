#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Constant-declaration mutants: evaluate every constant of the file for gold and mutant over the legal top
generics. If the mutated constant never changes value, no constant does, the elaborated design is the same, and the
mutant is equivalent.

Module generics come from the openjls_top instance generic map. Each top generic the file depends on is swept
over its whole legal range; when the product is too large, MAX_IMAGE_WIDTH/HEIGHT use boundary and power-of-two
points instead (result marked "sampled").
  const_eq.py ID [ID ...]   prints one JSON line per mutant: SAME (exact or sampled), DIFF (first generic set
                            where a constant differs), or SKIP (line is not a constant this evaluator handles)
"""
import functools, itertools, json, math, re, sys
from pathlib import Path

F = Path(__file__).resolve().parent
sys.path[:0] = [str(F.parent)]
import mutants as mut

S = F.parents[2] / "Sources"
TOP_GENERICS = {"bitness": range(8, 17), "out_width": range(48, 1025, 8),
                "max_image_width": range(4, 65536), "max_image_height": range(1, 65536)}
LIMIT = 2_000_000
FUN = {"log2ceil": lambda x: max(0, math.ceil(math.log2(x))) if x > 0 else 0,
       "log2": lambda x: int(math.log2(x)), "math_max": max, "math_min": min, "maximum": max, "minimum": min,
       "math_ceil_div": lambda a, b: -(-a // b)}


def code(text):
    return "\n".join(l.split("--", 1)[0] for l in text.splitlines()).lower()


def decls(text):
    """[(name, expr)] of the constant declarations, in order."""
    return [(m[1], " ".join(m[2].split())) for m in
            re.finditer(r"\bconstant\s+(\w+)\s*:\s*[^;]*?:=\s*(.*?);", code(text), re.S)]


def pyexpr(e):
    e = re.sub(r"\bmod\b", "%", e)
    e = re.sub(r"(?<![/*])/(?!=)", "//", e)
    return e


@functools.cache
def comp(e):
    try:
        return compile(pyexpr(e), "<c>", "eval")
    except SyntaxError:
        return None


@functools.cache
def top_decls():
    return tuple(decls((S / "openjls_top.vhd").read_text()))


def evaluate(pairs, env):
    env = dict(env)
    for n, e in pairs:
        try:
            v = eval(comp(e), {"__builtins__": {}}, {**FUN, **env})
            env[n] = v if isinstance(v, int) else None
        except Exception:  # noqa: BLE001 (records, strings, tables: not evaluated)
            env[n] = None
    return env


@functools.cache
def instance_map(stem):
    """{module generic: top expression} from the openjls_top instantiation of stem."""
    t = code((S / "openjls_top.vhd").read_text())
    m = re.search(rf"entity\s+work\.{stem.lower()}\b.*?generic\s+map\s*\((.*?)\)\s*port\s+map", t, re.S)
    return dict((a, " ".join(b.split())) for a, b in re.findall(r"(\w+)\s*=>\s*([^,]+)", m[1])) if m else {}


def module_generics(text):
    e = re.search(r"\bentity\s+\w+\s+is\s+generic\s*\((.*?)\)\s*;\s*port", code(text), re.S)
    return re.findall(r"(\w+)\s*:\s*[^;:]*?(?::=\s*([^;]*))?(?:;|$)", e[1]) if e else []


def env_for(stem, text, g, pkg):
    if stem == "openjls_top":
        return evaluate(decls(text), {**pkg, **g})
    return evaluate(decls(text), {**pkg, **module_env(stem, text, tuple(sorted(g.items())), pkg)})


_MG = {}


def module_env(stem, text, gk, pkg):
    """Module generic values at top generics gk (memoised per top point)."""
    if (stem, gk) not in _MG:
        top, imap, env = evaluate(top_decls(), {**pkg, **dict(gk)}), instance_map(stem), {}
        for n, d in module_generics(text):
            env[n] = evaluate([(n, imap[n])], top)[n] if n in imap else evaluate([(n, d)], pkg)[n] if d else None
        _MG[(stem, gk)] = env
    return _MG[(stem, gk)]


def deps(stem, text, target):
    """Top generics that constant target reaches. Only target can change first: if its value is the same, so is
    every constant computed from it."""
    own = dict(decls(text))
    names, todo0, done = "", {target}, set()
    while todo0:
        n = todo0.pop()
        if n in own and n not in done:
            done.add(n)
            names += f" {n} {own[n]}"
            todo0 |= set(re.findall(r"\w+", own[n]))
    names += " " + " ".join(v for k, v in instance_map(stem).items() if re.search(rf"\b{k}\b", names))
    top = dict(top_decls())
    seen, todo = set(), set(re.findall(r"\w+", names))
    while todo:
        n = todo.pop()
        if n in seen:
            continue
        seen.add(n)
        todo |= set(re.findall(r"\w+", top.get(n, ""))) if stem != "openjls_top" or n in top else set()
    return [g for g in TOP_GENERICS if g in seen]


def critical(r):
    pts = {r.start, r.stop - 1} | {x for k in range(17) for x in range(2 ** k - 2, 2 ** k + 3)}
    return sorted(x for x in pts if r.start <= x < r.stop)


def one(name):
    stem = name.split(":")[0]
    f = next(S.rglob(f"{stem}.vhd"))
    text = f.read_text()
    m = next(x for x in mut.all_mutants(text, stem, True) if x["id"] == name)
    if not re.match(r"\s*constant\s", m["from"], re.I):
        return dict(name=name, res="SKIP", info="not a constant declaration")
    lines = text.splitlines(); lines[m["line"]] = m["to"]; mtext = "\n".join(lines)
    pkg = evaluate(decls((S / "openjls_pkg.vhd").read_text()), {})
    target = re.match(r"\s*constant\s+(\w+)", m["from"], re.I)[1].lower()
    dep = deps(stem, text, target)
    axes = {g: TOP_GENERICS[g] for g in dep}
    sampled = math.prod(len(r) for r in axes.values()) > LIMIT
    if sampled:
        axes = {g: (critical(r) if g.startswith("max_image") else r) for g, r in axes.items()}
    n, done = 0, set()
    for vals in itertools.product(*axes.values()):
        g = {**{k: r.start for k, r in TOP_GENERICS.items()}, **dict(zip(axes, vals))}
        if stem != "openjls_top":
            key = tuple(sorted(module_env(stem, text, tuple(sorted(g.items())), pkg).items()))
            _MG.clear()
            if key in done:
                continue
            done.add(key)
        a, b = env_for(stem, text, g, pkg), env_for(stem, mtext, g, pkg)
        if a.get(target) is None:
            return dict(name=name, res="SKIP", info=f"{target} not evaluated")
        diff = [target] if a[target] != b.get(target) else []
        if diff:
            return dict(name=name, res="DIFF", at=g, consts={target: [a[target], b.get(target)]})
        n += 1
    return dict(name=name, res="SAME", mode="sampled" if sampled else "exact", generics=dep, points=n)


if __name__ == "__main__":
    for x in sys.argv[1:]:
        print(json.dumps(one(x)), flush=True)
