# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Copy RTL into a GHDL-synthesizable form: drop asserts, work around GHDL synth gaps and bugs."""
import re, sys
from pathlib import Path

ASSERT = re.compile(r"^[ \t]*(?:\w+[ \t]*:[ \t]*)?(?:postponed[ \t]+)?assert\b.*?;[ \t]*$", re.M | re.S)
SLICES = [
    (r"vPadByte(6 downto 7 - vStuffBufferBits) := sStuffBuffer(HOLD_BITS - 1 downto HOLD_BITS - vStuffBufferBits);",
     "for t in 0 to 6 loop if t < vStuffBufferBits then vPadByte(6 - t) := sStuffBuffer(HOLD_BITS - 1 - t); end if; end loop;"),
    (r"vPadByte(7 downto 8 - vStuffBufferBits) := sStuffBuffer(HOLD_BITS - 1 downto HOLD_BITS - vStuffBufferBits);",
     "for t in 0 to 7 loop if t < vStuffBufferBits then vPadByte(7 - t) := sStuffBuffer(HOLD_BITS - 1 - t); end if; end loop;"),
]

def prep(text, name, keep=False):
    """keep: leave error and failure asserts in place (they become solver checks); drop note and warning ones."""
    text = ASSERT.sub(lambda m: m[0] if keep and not re.search(r"severity\s+(note|warning)\b", m[0], re.I) else "", text)
    # GHDL synth lacks integer abs; widen first so the most negative value stays exact
    text = re.sub(r"abs\(to_integer\((\w+)\)\)", r"to_integer(abs(resize(\1, \1'length + 1)))", text)
    # GHDL synth (7.0.0-dev r535) computes integer - signed as signed - integer
    text = re.sub(r"\b(\d+) - signed\(resize\((\w+), ([^()]+)\)\)",
                  r"to_signed(\1, \3) - signed(resize(\2, \3))", text)
    if name == "byte_stuffer.vhd":
        for a, b in SLICES:
            text = text.replace(a, b)
    return text


PSL = re.compile(r"^([ \t]*--[ \t]*psl[ \t]+)assert\b(.*)$", re.M)
KEYWORDS = {"always", "never", "next", "and", "or", "not", "xor", "nand", "nor", "eventually", "until", "abort",
            "before", "true", "false", "report", "severity"}


def contracts(text, keep=False):
    """Module-level proof: PSL asserts on inputs and generics only become assumes; other PSL asserts are dropped
    (kept with keep=True)."""
    ent = re.search(r"\bentity\s+\w+\s+is(.*?)\bend\b", text, re.S | re.I)[1]
    gen = re.search(r"\bgeneric\s*\((.*?)\)\s*;\s*port\b", ent, re.S | re.I)
    allowed = set()
    for decl in re.findall(r"([\w\s,]+?)\s*:\s*in\b", ent, re.I):
        allowed |= {n.strip().lower() for n in decl.split(",")}
    if gen:
        for decl in re.findall(r"([\w\s,]+?)\s*:", re.sub(r"--.*", "", gen[1])):
            allowed |= {n.strip().lower() for n in decl.split(",")}

    def one(m):
        prop = re.split(r"\breport\b", m[2], 1)[0]
        prop = re.sub(r"\"[^\"]*\"|'[^']'", " ", prop)
        ids = {w.lower() for w in re.findall(r"\b[A-Za-z_]\w*\b", prop)} - KEYWORDS
        if ids and ids <= allowed:
            return m[1] + "assume" + re.split(r"\breport\b", m[2], 1)[0].rstrip().rstrip(";") + ";"
        return m[0] if keep else ""
    return PSL.sub(one, text)


if __name__ == "__main__":
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    dst.mkdir(parents=True, exist_ok=True)
    for f in src.glob("*.vhd"):
        (dst / f.name).write_text(prep(f.read_text(), f.name))
