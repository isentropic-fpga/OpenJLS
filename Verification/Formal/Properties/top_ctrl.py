#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Control invariants of openjls_top on the real RTL, datapath cut.

Every instance except the line_buffer becomes a free cut point (sound over-approximation): the
valid bits, CEs, stall loop and token modes must hold for any datapath, byte_stuffer and framer
output. The RTL PSL of the kept instances (line_buffer input contract) becomes a proof obligation.
Env: TC_BITS (8), TC_GEN ("MAX_IMAGE_WIDTH=8 MAX_IMAGE_HEIGHT=4"), TC_TIMEOUT (s, 1800), TC_VACUITY=1.
"""
import json, os, re, subprocess as sp, sys, zlib
from pathlib import Path

F = Path(__file__).resolve().parent
sys.path.insert(0, str(F.parent / "Common"))
from prep import prep
from flow import S, ENV, BASE, ORDER, run
WORK = Path(os.environ.get("TC_WORK", "/tmp/top_ctrl"))
BITS = os.environ.get("TC_BITS", "8").split()
GEN = os.environ.get("TC_GEN", "MAX_IMAGE_WIDTH=8 MAX_IMAGE_HEIGHT=4").split()
VAC = os.environ.get("TC_VACUITY") == "1"
# Non-vacuity: "old|||new" text substitution in the top (a known bad change must fail a property)
SUB = os.environ.get("TC_SUB", "")
KEEP = ["u_line_buffer"]

ce = " and ".join(f"sCE{k} = (not sStallLogic and (sReg{k}V or sReg{k - 1}V))" for k in range(2, 8))
PROPS = {
    "reset_ready": "iRst = '1' -> oReady = '0'",
    "stall_ready": "(iRst = '0' and sStallLogic = '1') -> oReady = '0'",
    "accept_commit": "(iRst = '0' and iValid = '1' and oReady = '1') -> next (sValid = '1')",
    "stall_empty": "(iRst = '0' and sStallLogic = '1') -> (sReg1V = '0' and sValid = '0')",
    "ce_registered": f"iRst = '0' -> ({ce} and sCtxAdvance = not sStallLogic)",
    **{f"bubble_mode{k}": f"sReg{k}V = '0' -> sReg{k}.mode = token_none" for k in range(1, 8)},
    "bubble_eoi1": "sReg1Eoi = '1' -> sReg1V = '1'",
    "fwd_valid": "(sFwdRegHit = '1' or sFwdRiHit = '1') -> (sReg3V = '1' and sReg4V = '1')",
}
# Extra one-off properties: TC_EXTRA="name|||expr" (replaces PROPS)
if os.environ.get("TC_EXTRA"):
    PROPS = dict([os.environ["TC_EXTRA"].split("|||")])


def top_src():
    t = prep((S / "openjls_top.vhd").read_text(), "openjls_top.vhd")
    t = re.sub(r"^[ \t]*--[ \t]*psl[ \t]+assert\b.*$", "", t, flags=re.M)
    if SUB:
        a, b = SUB.split("|||")
        assert t.count(a) == 1, a
        t = t.replace(a, b)
    sig = "  signal sFInit : std_logic := '1';\n"
    psl = ["  sFInit <= '0' when rising_edge(iClk);",
           "  -- psl assume always (sFInit = '1' -> iRst = '1');"]
    for n, p in PROPS.items():
        p = "false" if VAC else p
        psl.append(f"  -- psl {n} : assert always (sFInit = '0' -> ({p}));")
    t = t.replace("\nbegin\n", "\n" + sig + "\nbegin\n", 1)
    return t.replace("end architecture rtl;", "\n".join(psl) + "\n\nend architecture rtl;")


def check(bits):
    d = WORK / f"b{bits}{'_vac' if VAC else ''}{'_x' + list(PROPS)[0] if os.environ.get('TC_EXTRA') else ''}{'_sub%08x' % zlib.crc32(SUB.encode()) if SUB else ''}"
    d.mkdir(parents=True, exist_ok=True)
    files = [str(f) for f in BASE]
    for n in ORDER:
        p = d / f"{n}.vhd"
        p.write_text(top_src() if n == "openjls_top" else prep((S / f"{n}.vhd").read_text(), f"{n}.vhd"))
        files.append(p.name)
    (d / "lib").mkdir(exist_ok=True)
    r = sp.run(["ghdl", "-a", "--std=08", "-frelaxed", "-fpsl", "--workdir=lib"] + files, cwd=d, env=ENV,
               capture_output=True, text=True)
    if r.returncode:
        return dict(bits=bits, res="ERROR", info=r.stderr[-600:])
    keep = " ".join(f"openjls_top/{k}" for k in KEEP)
    (d / "p.sby").write_text(f"""[options]
mode prove
[engines]
abc pdr
[script]
plugin -i ghdl
ghdl --std=08 -frelaxed -fpsl --workdir=lib -gBITNESS={bits} {" ".join("-g" + g for g in GEN)} openjls_top
hierarchy -top openjls_top
cutpoint openjls_top/c:u_* {keep} %d
prep -top openjls_top
flatten; memory_map; opt -fast; setundef -undriven -zero; setundef -zero -init
[files]
lib
""")
    try:
        p = run(["sby", "-f", "p.sby"], d, timeout=int(os.environ.get("TC_TIMEOUT", 1800)))
    except sp.TimeoutExpired:
        return dict(bits=bits, res="TIMEOUT")
    st = (d / "p" / "status").read_text().split()[0] if (d / "p" / "status").exists() else "ERROR"
    failed = re.findall(r"Assert failed in \S+: (\S+)", p.stdout)
    return dict(bits=bits, res=st, vacuity=VAC, failed=sorted(set(failed)), gen=" ".join(GEN))


if __name__ == "__main__":
    for b in BITS:
        print(json.dumps(check(b)), flush=True)
