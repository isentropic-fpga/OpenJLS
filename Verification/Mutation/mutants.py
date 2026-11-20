# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Line-level VHDL mutant generators: std (operators) and lit (literals, slices, widths).

A mutant ID is stem:hash of (kind, original line, mutated line, occurrence), so edits elsewhere in the file keep it.
"""
import hashlib, os, re
from pathlib import Path

SKIP = re.compile(r"^\s*(signal|constant|variable|type|subtype|function|procedure|attribute|alias|file|use|library|entity|end|architecture|generic|port|component|report|severity)\b", re.I)
# MUT_OPS=lit: literal, slice and width operators. Result files get a _lit suffix.
OPS = os.environ.get("MUT_OPS", "")
SUF = "_lit" if OPS == "lit" else ""
SKIP_LIT = re.compile(r"^\s*(signal|variable|type|subtype|function|procedure|attribute|alias|file|use|library|entity|end|architecture|generic|port|component|report|severity)\b", re.I)

def mutants(src):
    return mutants_lit(src) if OPS == "lit" else mutants_std(src)


def all_mutants(src, stem, everything=False):
    """[{id, kind, line, from, to}] for both kinds; line is 0-based. IDs come from the full list, so the
    filter (no_effect) does not change them; everything=True keeps the filtered mutants."""
    out, seen = [], {}
    for kind, fn in (("std", mutants_std), ("lit", mutants_lit)):
        for m in fn(src):
            key = f"{kind}|{m['from'].strip()}|{m['to'].strip()}"
            k = seen[key] = seen.get(key, -1) + 1
            h = hashlib.sha1(f"{key}|{k}".encode()).hexdigest()[:8]
            out.append(dict(m, id=f"{stem}:{h}", kind=kind))
    if everything:
        return out
    ctx = Context(src)
    return [m for m in out if not no_effect(m, ctx)]


# ---------------------------------------------------------------- Filter
# Mutant classes that cannot reach an output of the encoder, whatever the test: they only cost run time.

SOURCES = Path(__file__).resolve().parents[2] / "Sources"
# Fixed by the pipeline or chosen freely: a small change has no meaning (BURST_DEPTH) or only moves timing
FIXED = re.compile(r"^\s*constant\s+(BYTE_STUFFER_BURST_DEPTH|CO_MAX_IMAGES_IN_FLIGHT|STALL_CUSHION_ENTRIES|RAM_DEPTH)\b", re.I)
DECL = re.compile(r"^\s*(constant\s+)?\w+(\s*,\s*\w+)*\s*:\s*(in|out|inout|buffer)?\s*[\w.]+\s*\(", re.I)


def statements(src, start):
    """Line numbers of the statements that start with regex start and end at the first ';'."""
    out, cur = set(), None
    for n, line in enumerate(src.splitlines()):
        code = line.split("--", 1)[0]
        if cur is None and re.match(start, code.strip(), re.I):
            cur = n
        if cur is not None:
            out.add(n)
            if ";" in code:
                cur = None
    return out


def paren(s, i):
    """Index after the ')' that closes the '(' at s[i]."""
    d = 0
    for j in range(i, len(s)):
        d += {"(": 1, ")": -1}.get(s[j], 0)
        if d == 0:
            return j + 1
    return len(s)


def default_only_constants():
    """Package constants that reach the design only as a generic default that every instantiation overrides."""
    files = sorted(SOURCES.glob("*.vhd")) + sorted((SOURCES / "Xilinx").glob("openjls_axis*.vhd"))
    code = {f.name: "\n".join(l.split("--", 1)[0] for l in f.read_text().splitlines()) for f in files}
    pkg = code["openjls_pkg.vhd"]
    defs = dict(re.findall(r"^\s*constant\s+(\w+)\s*:[^;]*?:=([^;]*);", pkg, re.M | re.I))
    mapped, inst = {}, set()
    for txt in code.values():
        for m in re.finditer(r"\bentity\s+work\.(\w+)\s*(\(\w+\))?\s*(generic\s+map\s*\()?", txt, re.I):
            e = m[1].lower(); inst.add(e)
            names = set(x.lower() for x in re.findall(r"(\w+)\s*=>", txt[m.end():paren(txt, m.end() - 1)])) if m[3] else set()
            mapped[e] = names if e not in mapped else mapped[e] & names
    live_txt = []
    for txt in code.values():
        rest = txt
        for m in re.finditer(r"\bentity\s+(\w+)\s+is\s+generic\s*\(", txt, re.I):
            e, g = m[1].lower(), txt[m.end():paren(txt, m.end() - 1) - 1]
            rest = rest.replace(g, "")
            for d in re.split(r";", g):
                k = re.match(r"\s*(\w+)\s*:", d)
                if k and (e not in inst or k[1].lower() not in mapped.get(e, set())):
                    live_txt.append(d)
        if txt is pkg:
            rest = re.sub(r"^\s*constant\s+\w+\s*:[^;]*;", "", rest, flags=re.M | re.I)
        live_txt.append(rest)
    body = "\n".join(live_txt)
    live = {c for c in defs if re.search(rf"\b{c}\b", body, re.I)}
    grew = True
    while grew:
        new = {c for c, rhs in defs.items() if c not in live and any(re.search(rf"\b{c}\b", defs[u], re.I) for u in live)}
        grew = bool(new); live |= new
    return set(defs) - live


class Context:
    def __init__(self, src):
        lines = src.splitlines()
        self.header = set()
        inside = False
        for n, l in enumerate(lines):
            c = l.split("--", 1)[0]
            if re.match(r"\s*entity\s+\w+\s+is\b", c, re.I): inside = True
            if inside: self.header.add(n)
            if re.match(r"\s*end\s+entity\b", c, re.I): inside = False
        # bodies of functions that only simulation asserts call
        asserts = statements(src, r"(postponed\s+)?assert\b")
        self.sim_only = set()
        for m in re.finditer(r"^\s*function\s+(\w+)", src, re.M | re.I):
            a = src[:m.start()].count("\n")
            b = next(n for n in range(a, len(lines)) if re.match(rf"\s*end\s+function\s+{m[1]}\b", lines[n], re.I))
            refs = [n for n, l in enumerate(lines) if re.search(rf"\b{m[1]}\b", l.split("--", 1)[0]) and not a <= n <= b]
            if refs and all(n in asserts for n in refs):
                self.sim_only |= set(range(a, b + 1))
        self.dead = set()
        if re.search(r"^\s*package\s+openjls_pkg\b", src, re.M | re.I):
            dead = default_only_constants()
            self.dead = {n for n, l in enumerate(lines) if (k := re.match(r"\s*constant\s+(\w+)", l, re.I)) and k[1] in dead}


def change(m):
    """(start, old text, new text) of the changed span of the line."""
    a, b = m["from"], m["to"]
    i = 0
    while i < min(len(a), len(b)) and a[i] == b[i]: i += 1
    j = 0
    while j < min(len(a), len(b)) - i and a[-1 - j] == b[-1 - j]: j += 1
    return i, a[i:len(a) - j], b[i:len(b) - j]


def no_effect(m, ctx):
    n, code = m["line"], m["from"].split("--", 1)[0]
    if n in ctx.sim_only or n in ctx.dead or FIXED.match(code):
        return True
    i, old, new = change(m)
    # Range bound of a generic: it only rejects or admits a configuration at elaboration
    r = re.search(r"\brange\s+[^:]*?\bto\b[^:;]*?(?=:=|;|$)", code, re.I)
    if n in ctx.header and r and r.start() <= i < r.end():
        return True
    # Slice shift of a declared range: same width, so the object either is used whole (no change) or is
    # sliced at absolute bits (any simulation fails); the mutant says nothing about the tests
    d = DECL.match(code)
    if m["kind"] == "lit" and d and d.end() - 1 <= i < paren(code, d.end() - 1):
        to = m["to"][d.end() - 1:paren(m["to"], d.end() - 1)]
        if re.fullmatch(r"\(.* ([+-]) 1 downto .* \1 1\)", to):
            return True
    return False


def mutants_lit(src):
    """'0'<->'1', integer +-1, bit-string LSB flip, slice shift by one, resize width +-1."""
    out = []; arch = False; inassert = False; seen = set()
    for n, line in enumerate(src.splitlines()):
        code = line.split("--", 1)[0]
        if re.match(r"\s*(architecture|package)\b", code, re.I): arch = True
        if not arch or not code.strip(): continue
        s = code.strip()
        if inassert or re.match(r"(postponed\s+)?assert\b", s, re.I):
            inassert = ";" not in s; continue
        if SKIP_LIT.match(code) or "rising_edge" in code or re.search(r"\bgenerate\s*$", s, re.I) and "if" not in s: continue
        tail = ("--" + line.split("--", 1)[1]) if "--" in line else ""
        def emit(a, b, what):
            to = code[:a] + what + code[b:] + tail
            if (n, to) not in seen and to != line:
                seen.add((n, to)); out.append({"line": n, "from": line, "to": to})
        for k in re.finditer(r"'([01])'", code):
            emit(k.start(), k.end(), "'%d'" % (1 - int(k[1])))
        for k in re.finditer(r"\bx\"([0-9a-fA-F]+)\"", code):
            d = k[1][:-1] + "%x" % (int(k[1][-1], 16) ^ 1)
            emit(k.start(), k.end(), 'x"%s"' % d)
        for k in re.finditer(r'(?<![a-zA-Z0-9_])"([01]+)"', code):
            emit(k.start(), k.end(), '"%s%d"' % (k[1][:-1], 1 - int(k[1][-1])))
        for k in re.finditer(r"(?<![\w.'\"#])(\d+)(?![\w.#\"])", code):
            v = int(k[1])
            # not inside a slice, the slice operator covers those
            prev = code[:k.start()].rfind("("); nxt = code.find(")", k.end())
            if prev >= 0 and nxt >= 0 and "downto" in code[prev:nxt]: continue
            emit(k.start(), k.end(), str(v + 1))
            if v > 0: emit(k.start(), k.end(), str(v - 1))
        for k in re.finditer(r"\(([^()]*?)\s+downto\s+([^()]*?)\)", code):
            for d in ("+ 1", "- 1"):
                emit(k.start(), k.end(), "(%s %s downto %s %s)" % (k[1], d, k[2], d))
        for k in re.finditer(r"\bresize\s*\((.*),\s*([^,()]+(?:\([^()]*\))?[^,()]*)\)", code, re.I):
            for d in ("+ 1", "- 1"):
                emit(k.start(2), k.end(2), "%s %s" % (k[2], d))
    return out

def mutants_std(src):
    out = []; arch = False; inassert = False
    for n, line in enumerate(src.splitlines()):
        code = line.split("--", 1)[0]
        if re.match(r"\s*architecture\b", code, re.I): arch = True
        if not arch or not code.strip(): continue
        s = code.strip()
        if inassert or re.match(r"(postponed\s+)?assert\b", s, re.I):
            inassert = ";" not in s; continue
        if SKIP.match(code) or "rising_edge" in code or re.match(r"\s*when\b.*=>\s*$", code): continue
        def emit(a, b, what):
            out.append({"line": n, "from": line, "to": code[:a] + what + code[b:] + (("--" + line.split("--", 1)[1]) if "--" in line else "")})
        m = re.search(r"\b(if|elsif|when)\b(.*?)(\bthen\b|\belse\b|;|$)", code, re.I)
        if m:
            a0, b0 = m.start(2), m.end(2)
            for rx, rep in ((r" /= ", " = "), (r" (?<![/<>])= ", " /= "), (r" < ", " <= "), (r" <= ", " < "), (r" > ", " >= "), (r" >= ", " > "), (r" and ", " or "), (r" or ", " and "), (r"\bnot ", "")):
                for k in re.finditer(rx, code[a0:b0]):
                    emit(a0 + k.start(), a0 + k.end(), rep)
        if "downto" not in code and " to " not in code:
            for rx, rep in ((r" \+ 1\b", " + 2"), (r" - 1\b", " - 2"), (r" \+ (?!1\b)", " - "), (r" - (?!1\b)", " + "), (r"shift_left", "shift_right"), (r"shift_right", "shift_left")):
                for k in re.finditer(rx, code): emit(k.start(), k.end(), rep)
    return out

