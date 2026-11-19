#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Module-level formal equivalence of mutants, each module as openjls_top instantiates it.

  module_eq.py STEM [STEM ...]   every std and lit mutant of STEM, BITNESS 8..16
A formal DIFF counts only if NVC replays it on the unprepped RTL (GHDL synth bugs, see prep.py).
Env: FEQ_GOLD_INV=1 (gold's proved asserts become assumes), FEQ_WORK (scratch), FEQ_BITS, FEQ_ONLY (mutant ID hashes), FEQ_DEPTH (default 1), FEQ_THREADS (20), FEQ_OUT.
"""
import json, os, re, shutil, subprocess as sp, sys, multiprocessing as mp
from pathlib import Path

F = Path(__file__).resolve().parent
sys.path[:0] = [str(F), str(F.parent), str(F.parents[1] / "Formal/Common")]
from flow import R, S, OSS, ENV, BASE, RESULTS, run, tree  # noqa: F401 (re-exported)
from prep import prep, contracts
import gen_harness as gh
import mutants as mut, replay

WORK = Path(os.environ.get("FEQ_WORK", "/tmp/feq_mod"))
BITS = [int(b) for b in os.environ.get("FEQ_BITS", "8 9 10 11 12 13 14 15 16").split()]
DEPTH = int(os.environ.get("FEQ_DEPTH", "1"))
# Extra harness generics, e.g. "MAX_IMAGE_WIDTH=15" (sequential envs proved at small sizes)
GENERICS = os.environ.get("FEQ_GENERICS", "").split()
SEQ_DEPTH = int(os.environ.get("FEQ_SEQ_DEPTH", "20"))
# bmc: bounded check only, for clocked modules where PDR does not converge
BMC = os.environ.get("FEQ_MODE", "prove") == "bmc"
# RTL PSL asserts on module inputs become assumes (assume-guarantee); 0 = ignore them (non-vacuity check)
CONTRACTS = os.environ.get("FEQ_CONTRACTS", "1") == "1"
OUT = Path(os.environ.get("FEQ_OUT", F.parent / "Results/classify/module_eq.jsonl"))
# Gold keeps its own asserts as assumes (skip 1). Sound only where rtl_asserts.py proves them under a weaker env
GOLD_INV = os.environ.get("FEQ_GOLD_INV") == "1"

# T.87 context invariants, as the top keeps them: -N < B <= 0, 1 <= N <= RESET, A below 2^A_STORED
CTX = ["iNq_i >= 1 and iNq_i <= RESET",
       "iBq_i <= 0 and iBq_i > -signed(resize(iNq_i, B_WIDTH))",
       "iAq_i < 2 ** A_STORED"]
# Regular-mode Errval is the A.9 residue
ERRVAL = "iErrorVal_i >= -(2 ** (BITNESS - 1)) and iErrorVal_i < 2 ** (BITNESS - 1)"

# A.6 clip bounds and errors as the top computes them (Reg3 registers Stage 3 of the same Px, Ix, Sign)
A6_BIND = ("""  signal sLo, sHi : signed(CO_CQ_WIDTH downto 0);
  signal sAtLo, sAtHi : signed(BITNESS downto 0);""",
"""  u_bounds : entity work.a6_clip_bounds generic map (BITNESS => BITNESS, MAX_VAL => MAX_VAL)
    port map (iPx => iPx_i, iSign => iSign_i, oLo => sLo, oHi => sHi);
  u_errors : entity work.a6_clip_errors generic map (BITNESS => BITNESS, MAX_VAL => MAX_VAL)
    port map (iIx => iIx_i, iSign => iSign_i, oAtLo => sAtLo, oAtHi => sAtHi);""",
           {"iLo": "sLo", "iHi": "sHi", "iAtLo": "sAtLo", "iAtHi": "sAtHi"})
PX = ["iPx_i <= MAX_VAL", "iIx_i <= MAX_VAL"]
# label -> extra gold sources for an env/<label>.vhd harness (hand-written top loop, both copies)
ENV_SRC = {"u_a15_16": ["A14_run_length_determination"], "u_line_buffer": [], "u_ctx_ram": [], "u_byte_stuffer": [], "u_framer": []}
# label -> (clock port, reset port) for sequential modules
CLOCKED = {l: ("iClk", "iRst") for l in ("u_a15_16", "u_line_buffer", "u_ctx_ram", "u_bit_packer",
                                                  "u_byte_stuffer", "u_framer")}  # env harnesses are clocked too
BIND = {l: A6_BIND for l in ("u_a6a7_d", "u_a6a7_c", "u_a6a7_p", "u_a6a7_m")}

# stem -> [(instance label in openjls_top, PSL assumptions)]; PARENTS: stems instantiated through a parent
PARENTS = {"A10_compute_k": ["A20_2_compute_k"]}
HARNESS = {
    "A6_A7_prediction_error": [("u_a6_bounds", ["iPx_i <= MAX_VAL"]), ("u_a6_errors", ["iIx_i <= MAX_VAL"])]
                              + [(l, PX) for l in ("u_a6a7_d", "u_a6a7_c", "u_a6a7_p", "u_a6a7_m")],
    "A23_run_interruption_update": [("u_a23_delta", []), ("u_a23", [])],
    "A4_quantization_gradients": [("u_a4", [])],
    "A9_modulo_reduction": [("u_a9_d", [])],
    "A10_compute_k": [("u_a20_2", [CTX[0], CTX[2]])],
    "A4_2_Q_mapping": [("u_a4_2", ["iQ1_i >= 0 and iQ1_i <= 4", "iQ2_i >= -4 and iQ2_i <= 4",
                                   "iQ3_i >= -4 and iQ3_i <= 4"])],
    "A19_run_interruption_error": [("u_a19", [])],
    "A5_edge_detecting_predictor": [("u_a5", [])],
    "A22_errval_mapping": [("u_a22", [])],
    "A15_A16_encode_run": [("u_a15_16", [])],
    "line_buffer": [("u_line_buffer", [])],
    "context_ram": [("u_ctx_ram", [])],
    "A11_2_bit_packer": [("u_bit_packer", [])],
    "byte_stuffer": [("u_byte_stuffer", [])],
    "jls_framer": [("u_framer", [])],
    "A12_A13_update": [("u_a12_a13", CTX + [ERRVAL,
        "(iRescale_i = '1') = (iNq_i = RESET)",                      # p_reg4
        "(iNq_i = RESET and iNqNew_i = RESET / 2 + 1) or (iNq_i /= RESET and iNqNew_i = iNq_i + 1)"])],
}


def ctr(text):
    return contracts(text) if CONTRACTS else re.sub(r"^[ \t]*--[ \t]*psl[ \t]+assert\b.*$", "", text, flags=re.M)


def all_mutants(stem):
    return [(m["id"], stem, m["line"], m["to"]) for m in mut.all_mutants((S / f"{stem}.vhd").read_text(), stem)]


def rename(text, ents):
    for e in ents:
        text = re.sub(rf"\b{e}\b", e + "_mut", text)
    return text


def replay_nvc(d, src, label, assumes, bits, mut_raw):
    tr = next(iter(sorted((d / "p").glob("engine_*/trace.vcd"))), None)
    if tr is None:
        return "NO_TRACE"
    _, ports = gh.entity_decl(src, gh.top_instance(label)[0])
    seq = replay.vcd_inputs(tr, [n + "_i" for n, k, _ in ports if k == "in"] + ["clk"])
    if not seq:
        return "NO_TRACE"
    if label in ENV_SRC:
        seq = replay.vcd_inputs(tr, list(re.findall(r"\b(i\w+_i)\b", env_harness(label, "x"))) + ["clk"])
        (d / "replay.vhd").write_text(env_harness(label, "eq_replay", drive=seq))
    else:
        (d / "replay.vhd").write_text(gh.harness("eq_replay", src, label, assumes, drive=seq, bind=BIND.get(label), **clk_args(label)))
    nv = d / "nvc"; nv.mkdir(exist_ok=True)
    w = ["nvc", "--std=2008", f"--work=work:{nv}/work"]
    st = stem_of(label)
    r = run(w + ["-a", "--relaxed"] + [str(s) for s in BASE + [d / "gold_raw.vhd"] + [S / f"{p}.vhd" for p in PARENTS.get(st, []) + ENV_SRC.get(label, [])]]
            + [str(mut_raw), "replay.vhd"], d)
    if r.returncode:
        return "REPLAY_ERROR " + (r.stdout + r.stderr)[-300:]
    r = run(w + ["-e", "--jit", "--no-save", f"-gBITNESS={bits}"] + ["-g" + g for g in GENERICS] + ["eq_replay", "-r"], d, timeout=300)
    out = r.stdout + r.stderr
    if "REPLAY: DIFF" in out:
        return "CONFIRMED"
    if "REPLAY: END" in out:
        return "NOT_CONFIRMED"
    # NVC stops on the mutant itself (bound or range check): simulation detects it
    # Bound/range stop only: an RTL assert there may be an input contract that gold breaks too
    if "mut_raw.vhd" in out and ("outside of" in out or "out of bounds" in out):
        return "CONFIRMED"
    return "REPLAY_ERROR " + out[-300:]


def cut_ram(src):
    """context_ram with olo_base_ram_sdp replaced by port iFormalRamRd (read data)."""
    src, n = re.subn(r"\n\s*olo_base_ram_sdp_inst\s*:\s*entity.*?\);\n", "\n  sBramRdData <= iFormalRamRd;\n", src,
                     count=1, flags=re.S)
    assert n == 1
    return re.sub(r"(\n\s*oRdData\s*:)", "\n    iFormalRamRd    : in    std_logic_vector(TOTAL_WIDTH - 1 downto 0);\\1", src, count=1)


# stem -> source transform applied to gold and mutant alike (formal and replay)
CUT = {"context_ram": cut_ram}


def env_harness(label, name, drive=None):
    """env/<label>.vhd; with drive, the NVC replay form (free signals driven from the trace)."""
    t = (F / "env" / f"{label}.vhd").read_text().replace("@NAME@", name)
    gens, consts = gh.top_context()
    t = t.replace("@CONSTS@", "\n  ".join(consts))
    t = t.replace("@TOPGENS@", ";\n    ".join(f"{g} : natural := {v}" for g, v in gens.items()))
    if drive is None:
        return t.replace("@PORT@", ";\n  port (\n    clk : in std_logic\n  )")
    t = t.replace("@PORT@", "")
    free = re.search(r"-- free\n(.*?)  -- end free", t, re.S)
    types = {}
    for names, typ in re.findall(r"signal\s+([\w\s,]+?)\s*:\s*([^;]+);", free[1]):
        for n in names.split(","):
            types[n.strip()] = typ.strip()
    types["clk"] = "std_logic"
    decl = re.sub(r"\s*attribute anyseq of[^;]*;", "", free[1]) + "  signal clk : std_logic := '1';\n"
    t = t[:free.start(1)] + decl + t[free.end(1):]
    eq = re.search(r"psl assert always \(sInit = '0' -> \((.*)\)\);", t)[1]
    proc = gh.replay_process(drive, types, f"sInit = '1' or ({eq})")
    return re.sub(r"  -- @CHECK@.*?-- @END@", lambda _: proc, t, flags=re.S)


def clk_args(label):
    c = CLOCKED.get(label)
    return dict(clock=c[0], reset=c[1]) if c else {}


def stem_of(label):
    return next(s for s, v in HARNESS.items() if any(l == label for l, _ in v))


def one(job):
    r = one_(job)
    if GENERICS:
        r["gen"] = " ".join(GENERICS)
    return r


def one_(job):
    name, stem, line, to, label, bits = job
    assumes = dict(HARNESS[stem])[label]
    d = WORK / re.sub(r"\W", "_", f"{name}_{label}_b{bits}_{'_'.join(GENERICS)}")
    shutil.rmtree(d, ignore_errors=True); (d / "lib").mkdir(parents=True)
    src = (S / f"{stem}.vhd").read_text()
    par = [(S / f"{p}.vhd").read_text() for p in PARENTS.get(stem, [])]
    ents = gh.entities(src) + [e for p in par for e in gh.entities(p)]
    ls = src.splitlines(keepends=True); ls[line] = to + "\n"; msrc = "".join(ls)
    cut = CUT.get(stem, lambda s: s)
    src, msrc = cut(src), cut(msrc)
    if src == msrc:
        return dict(name=name, label=label, bits=bits, res="IN_CUT")
    (d / "gold_raw.vhd").write_text(src)
    gsrc = contracts(prep(src, stem + ".vhd", keep=True), keep=True) if GOLD_INV else ctr(prep(src, stem + ".vhd"))
    (d / "gold.vhd").write_text(gsrc + "".join(ctr(prep(p, "")) for p in par))
    (d / "mut.vhd").write_text(rename(ctr(prep(msrc, stem + ".vhd")) + "".join(ctr(prep(p, "")) for p in par), ents))
    (d / "mut_raw.vhd").write_text(rename(msrc + "".join(par), ents))
    hsrc = par[-1] if par else src
    if label in ENV_SRC:
        (d / "eq.vhd").write_text(env_harness(label, "eq"))
    else:
        (d / "eq.vhd").write_text(gh.harness("eq", hsrc, label, assumes, bind=BIND.get(label), **clk_args(label)))
    extra = [str(S / f"{e}.vhd") for e in ENV_SRC.get(label, [])]
    r = run(["ghdl", "-a", "--std=08", "-frelaxed", "-fpsl", "--workdir=lib"] + [str(f) for f in BASE] + extra + ["gold.vhd"], d)
    if r.returncode:
        return dict(name=name, label=label, bits=bits, res="ERROR", info=r.stderr[-400:])
    r = run(["ghdl", "-a", "--std=08", "-frelaxed", "-fpsl", "--workdir=lib", "mut.vhd"], d)
    if r.returncode:
        return dict(name=name, label=label, bits=bits, res="INVALID")
    r = run(["ghdl", "-a", "--std=08", "-frelaxed", "-fpsl", "--workdir=lib", "eq.vhd"], d)
    if r.returncode:
        return dict(name=name, label=label, bits=bits, res="ERROR", info=r.stderr[-400:])
    (d / "p.sby").write_text(f"""[options]
mode {"bmc" if BMC else "prove"}
depth {SEQ_DEPTH if label in CLOCKED else DEPTH}
[engines]
{"abc pdr" + chr(10) + "smtbmc yices" if label in CLOCKED and not BMC else os.environ.get("FEQ_BMC_ENGINE", "smtbmc yices")}
[script]
plugin -i ghdl
ghdl --std=08 -frelaxed -fpsl --workdir=lib -gBITNESS={bits} {" ".join("-g" + g for g in GENERICS)} eq
prep -top eq
{f"chformal -assert -skip 1 {stem.lower()}*" + chr(10) + f"chformal -assert2assume {stem.lower()}*" if GOLD_INV else ""}
{"flatten; memory_map; opt -fast; setundef -undriven -zero; setundef -zero -init" if label in CLOCKED else ""}
[files]
lib
""")
    try:
        r = run(["sby", "-f", "p.sby"], d, timeout=int(os.environ.get("FEQ_SBY_TIMEOUT", 1800)))
    except sp.TimeoutExpired:
        lg = d / "p" / "logfile.txt"
        steps = re.findall(r"Checking assertions in step (\d+)", lg.read_text()) if lg.exists() else []
        return dict(name=name, label=label, bits=bits, res="TIMEOUT", info=f"bmc step {steps[-1]}" if BMC and steps else "")
    st = (d / "p" / "status").read_text().split()[0] if (d / "p" / "status").exists() else "ERROR"
    if st == "PASS":
        shutil.rmtree(d)
        return dict(name=name, label=label, bits=bits, res=f"BMC_PASS_{SEQ_DEPTH}" if BMC else "PROVED")
    if st != "FAIL" and "vhdl import failed" in "".join(p.read_text() for p in (d / "p" / "model").glob("*.log")):
        return dict(name=name, label=label, bits=bits, res="INVALID_ELAB")
    pdr = "".join(f.read_text() for f in (d / "p").glob("engine_*/logfile*.txt"))
    fr = re.search(r"was asserted in frame (\d+)", pdr)
    if st != "FAIL" and fr:
        # sby can fail converting the PDR witness; BMC to that depth gives the trace
        (d / "b.sby").write_text((d / "p.sby").read_text().replace("mode prove", "mode bmc")
                                 .replace(re.search(r"depth \d+", (d / "p.sby").read_text())[0], f"depth {int(fr[1]) + 2}")
                                 .replace("abc pdr\n", ""))
        try:
            run(["sby", "-f", "b.sby"], d, timeout=1800)
        except sp.TimeoutExpired:
            pass
        if (d / "b" / "status").exists() and (d / "b" / "status").read_text().startswith("FAIL"):
            shutil.rmtree(d / "p", ignore_errors=True); shutil.copytree(d / "b", d / "p")
            st = "FAIL"
    if st != "FAIL":
        log = (d / "p" / "logfile.txt").read_text()[-600:] if (d / "p" / "logfile.txt").exists() else r.stdout[-600:]
        return dict(name=name, label=label, bits=bits, res="ERROR", info=log)
    rp = replay_nvc(d, hsrc, label, assumes, bits, d / "mut_raw.vhd")
    return dict(name=name, label=label, bits=bits, res="DIFF" if rp == "CONFIRMED" else "DIFF_" + rp.split()[0],
                info=rp[:300])


def main(stems):
    done = set()
    if OUT.exists():
        done = {(r["name"], r["label"], r["bits"]) for r in map(json.loads, open(OUT))
                if r.get("gen", "") == " ".join(GENERICS)}
    only = set(filter(None, os.environ.get("FEQ_ONLY", "").split(",")))
    jobs = [m + (l, b) for s in stems for m in all_mutants(s) for l, _ in HARNESS[s] for b in BITS
            if (m[0], l, b) not in done and (not only or m[0].split(":")[1] in only)]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with mp.Pool(int(os.environ.get("FEQ_THREADS", "20"))) as p, open(OUT, "a") as f:
        for r in p.imap_unordered(one, jobs):
            f.write(json.dumps(r) + "\n"); f.flush()
    print("done", len(jobs))


if __name__ == "__main__":
    main(sys.argv[1:])
