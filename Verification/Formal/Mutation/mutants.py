# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Line-level VHDL mutant generators (std operators, or literals with MUT_OPS=lit). IDs are list indices."""
import os, re

SKIP = re.compile(r"^\s*(signal|constant|variable|type|subtype|function|procedure|attribute|alias|file|use|library|entity|end|architecture|generic|port|component|report|severity)\b", re.I)
# MUT_OPS=lit: literal, slice and width operators. Result files get a _lit suffix.
OPS = os.environ.get("MUT_OPS", "")
SUF = "_lit" if OPS == "lit" else ""
SKIP_LIT = re.compile(r"^\s*(signal|variable|type|subtype|function|procedure|attribute|alias|file|use|library|entity|end|architecture|generic|port|component|report|severity)\b", re.I)

def mutants(src):
    return mutants_lit(src) if OPS == "lit" else mutants_std(src)

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

