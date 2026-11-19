#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Mutation suite: each mutant of the RTL against the verification; writes Results/.

Stages, cheapest first, stop at the first kill: OSVVM module tests, OSVVM top and AXI tests, a golden sample,
then the formal checks whose generated files the mutant changes. A survivor passes only if equivalent.tsv lists it.
Cache (hashes ignore comments and layout): a caught mutant is reused while its file is unchanged; a survivor
reruns on any RTL or verification change. RERUN=1 reruns all, which also rechecks caught mutants after a test bench
edit. STATUS=PASS needs a row for every mutant and no open survivor.
Env: RERUN=1, MUT_THREADS (20), MUT_ONLY (comma list of stems), MUT_WORK (scratch, /tmp/openjls_mutation).
"""
import hashlib, json, os, random, re, shutil, signal, subprocess as sp, sys, time, multiprocessing as mp
from datetime import datetime
from pathlib import Path

M = Path(__file__).resolve().parent
R = M.parents[1]
S = R / "Sources"
O = R / "Verification/OSVVM"
GM = R / "Verification/Golden model"
FO = R / "Verification/Formal"
RES = M / "Results"
WORK = Path(os.environ.get("MUT_WORK", "/tmp/openjls_mutation"))
NT = int(os.environ.get("MUT_THREADS", 20))
sys.path[:0] = [str(M), str(GM)]
import mutants

# Fork: workers inherit the globals main sets (3.14 defaults to forkserver)
MP = mp.get_context("fork")

FILES = sorted(S.glob("*.vhd")) + sorted((S / "Xilinx").glob("openjls_axis*.vhd"))
STEM = {f.stem: f for f in FILES}
XILINX = {s for s, f in STEM.items() if f.parent.name == "Xilinx"}
# stem -> module test benches; the package goes to all of them, top and Xilinx stems to none
MOD_TB = {
    "A1_gradient_comp": ["a1"], "A3_mode_selection": ["a3"], "A4_quantization_gradients": ["a4"],
    "A4_1_quant_gradient_merging": ["a4_1"], "A4_2_Q_mapping": ["a4_2"], "A5_edge_detecting_predictor": ["a5"],
    "A6_A7_prediction_error": ["a6_a7"], "A8_1_reconstructed_value": ["a8_1"], "A9_modulo_reduction": ["a9"],
    "A10_compute_k": ["a10", "a20_2"], "A11_error_mapping": ["a11"], "A11_1_golomb_encoder": ["a11_1"],
    "A11_2_bit_packer": ["a11_2"], "A12_A13_update": ["a12_a13"], "A14_run_length_determination": ["a14"],
    "A15_A16_encode_run": ["a15_a16"], "A17_run_interruption_index": ["a17"],
    "A18_run_interruption_prediction_error": ["a18"], "A19_run_interruption_error": ["a19"],
    "A20_1_run_context_index": ["a20_1"], "A20_2_compute_k": ["a20_2"], "A21_compute_map": ["a21"],
    "A22_errval_mapping": ["a22"], "A23_run_interruption_update": ["a23"], "line_buffer": ["line_buffer"],
    "context_ram": ["context_ram"], "byte_stuffer": ["byte_stuffer"], "jls_framer": ["jls_framer"]}


def sha(*parts):
    h = hashlib.sha1()
    for p in parts:
        h.update(p if isinstance(p, bytes) else str(p).encode())
    return h.hexdigest()[:12]


def norm(p):
    """File content without comments, docstrings and layout, so cosmetic edits keep the cache."""
    t = p.read_text(errors="replace")
    if p.suffix == ".py":
        import ast
        tree = ast.parse(t)
        for n in ast.walk(tree):
            b = getattr(n, "body", None)
            if isinstance(b, list) and b and isinstance(b[0], ast.Expr) and isinstance(getattr(b[0], "value", None), ast.Constant) \
                    and isinstance(b[0].value.value, str):
                n.body = b[1:] or [ast.Pass()]
        return ast.unparse(tree)
    if p.suffix == ".vhd":
        # Comments go, except PSL, which is code; strings are kept whole
        t = re.sub(r'("[^"\n]*")|--(?!\s*psl\b).*', lambda m: m[1] or "", t)
    else:
        t = re.sub(r"^\s*#.*$", "", t, flags=re.M)
    return " ".join(t.split())


def files_hash(paths):
    return sha(*[p.relative_to(R).as_posix() + "\0" + norm(p) for p in sorted(paths)])


INFRA = re.compile(r"No space left|Disk quota|Cannot allocate memory|Out of memory|Read-only file system", re.I)


class InfraError(Exception):
    """The machine failed, not the mutant: the run stops instead of recording a verdict."""


def checked(r):
    if INFRA.search((r.stdout or "") + (r.stderr or "")):
        raise InfraError(((r.stdout or "") + (r.stderr or ""))[-500:])
    return r


def tool(cmd):
    return sp.run(cmd, capture_output=True, text=True).stdout.strip()


# ---------------------------------------------------------------- OSVVM

def pro_tests():
    """[(dir, tb, {generic: value})] of the Test lines in OpenJls.pro, foreach loops expanded."""
    def expand(text):
        m = re.search(r"^\s*foreach (\w+) \{([^}]*)\} \{\n", text, re.M)
        if not m:
            return text
        depth, k = 1, m.end()
        while depth:
            depth += {"{": 1, "}": -1}.get(text[k], 0); k += 1
        body = text[m.end():k - 1]
        rep = "".join(re.sub(r"\$\{?" + m[1] + r"\b\}?", v, body) + "\n" for v in m[2].split())
        return expand(text[:m.start()] + rep + text[k:])
    lines = [l for l in (O / "OpenJls.pro").read_text().splitlines() if not l.strip().startswith(("#", "proc"))]
    txt = expand("\n".join(lines[lines.index("TestSuite Modules"):]))
    return [(m[1], m[2], dict(re.findall(r"\[generic (\w+) (-?\w+)\]", m[3])))
            for m in re.finditer(r"^\s*Test (Modules|Top)/(tb_\w+)\.vhd(.*)$", txt, re.M)]


TESTS = pro_tests()
RTL_OS = [(O / x).resolve() for x in re.findall(r"^analyze (\S*Sources/\S+\.vhd)$", (O / "OpenJls.pro").read_text(), re.M)
          if "open-logic" not in x]
SYS_TESTS = [(d, t, g) for d, t, g in TESTS if d == "Top" or "openjls_axis" in t]


def nvc_os(lib, args, cwd, timeout=None):
    return checked(sp.run(["nvc", "--std=2008", "--ieee-warnings=off", "-L", str(lib), f"--work=openjls:{lib}/OPENJLS.08"] + args,
                          cwd=cwd, capture_output=True, text=True, errors="replace", timeout=timeout))


def run_tb(lib, cwd, tb, g, timeout):
    args = ["-e", "--jit", "--no-save"] + [f"-g{k}={v}" for k, v in g.items()] + [tb, "-r", "--exit-severity=error", tb]
    t0 = time.time()
    try:
        r = nvc_os(lib, args, cwd, timeout)
    except sp.TimeoutExpired:
        return "TIMEOUT", timeout
    return ("PASS" if r.returncode == 0 and f"{tb}: PASS" in r.stdout + r.stderr else "FAIL"), time.time() - t0


def osvvm_base():
    """Libraries of the last OSVVM regression with the current RTL and test benches analyzed."""
    libs = sorted((O / "VHDL_LIBS").glob("NVC-*"), key=lambda p: [int(x) for x in re.findall(r"\d+", p.name)])
    base = WORK / "base_osvvm"
    shutil.rmtree(base, ignore_errors=True)
    shutil.copytree(libs[-1], base)
    tbs = sorted({str(O / d / f"{t}.vhd") for d, t, _ in TESTS})
    r = nvc_os(base, ["-a", "--relaxed", "--psl"] + [str(x) for x in RTL_OS] + tbs, O)
    if r.returncode:
        sys.exit("OSVVM base analysis failed:\n" + (r.stdout + r.stderr)[-2000:])
    return base


# ---------------------------------------------------------------- Golden

CLI = R / "ThirdParty/charls/build/cli/charls-cli"
OLO = R / "ThirdParty/open-logic/src/base/vhdl"
OLO_F = "pkg_array pkg_math pkg_string pkg_logic pkg_attribute ram_sdp fifo_sync".split()
RTL_GM = [l.strip() for l in (GM / "build_run.sh").read_text().split("SRC_FILES=(")[1].split(")")[0].splitlines() if l.strip()]
GM_TBS = [GM / "tb_openjls_golden.vhd", GM / "tb_openjls_golden_stream.vhd"]
STIM = WORK / "stim"


def nvc_gm(lib, args, cwd=None, timeout=None):
    return checked(sp.run(["nvc", "--std=2008", "--ieee-warnings=off", "-H", "1g", "-L", str(lib), f"--work=work:{lib}/work.08"] + args,
                          cwd=cwd, capture_output=True, text=True, errors="replace", timeout=timeout))


def gm_analyze(lib, sub=None):
    files = [str(sub[1]) if sub and f == sub[0] else str(S / f) for f in RTL_GM] + [str(t) for t in GM_TBS]
    return nvc_gm(lib, ["-a", "--relaxed", "--psl"] + files)


def golden_plan():
    """Golden sample: small images per depth, boundary and context-limit probes, same-size and random streams."""
    import numpy as np, random_stream as rs
    shutil.rmtree(STIM, ignore_errors=True); STIM.mkdir(parents=True)
    rows = [l.split("\t") for l in (GM / "Output/golden_image_results.tsv").read_text().splitlines()[1:]]
    rows = [r for r in rows if not r[0].startswith("stream")]
    rng = random.Random(0x60D)
    pick = [r for r in rows if r[0].startswith("synth-bound") and float(r[2]) < 0.01]
    for b in range(8, 17):
        c = [x for x in rows if x[3] == str(b) and 0.0005 < float(x[2]) < 0.06]
        pick += rng.sample(c, min(9, len(c)))
    imgs = []
    for r in sorted({r[0]: r for r in pick}.values(), key=lambda x: float(x[2])):
        p, j = GM / "Images" / f"{r[0]}.pgm", STIM / f"{r[0]}.jls"
        sp.run([CLI, "encode", p, j], check=True, capture_output=True)
        imgs.append((str(p), str(j), int(r[3])))
    for p in sorted((GM / "Images").glob("synth-bound-*-longrun-*.pgm")) + sorted((GM / "Images").glob("synth-bound-*-maxctx*.pgm")):
        j = STIM / (p.stem + ".jls")
        mx = int(p.read_bytes().split(b"\n", 3)[2])
        sp.run([CLI, "encode", p, j], check=True, capture_output=True)
        imgs.append((str(p), str(j), mx.bit_length()))
    streams = []
    for run, b, pct in (("8-r3", 8, 3), ("12-r100", 12, 100), ("16-r3", 16, 3)):
        d = STIM / run; d.mkdir()
        with open(d / "x.pix", "wb") as px, open(d / "x.jls", "wb") as js, open(d / "x.len", "w") as ln:
            for f in sorted((GM / "Images_stream" / run).glob("*.pgm"))[:80]:
                px.write(f.read_bytes().split(b"\n", 3)[3])
                sp.run([CLI, "encode", f, d / "t.jls"], check=True, capture_output=True)
                data = (d / "t.jls").read_bytes(); js.write(data); ln.write(f"{len(data)}\n")
        streams.append(dict(BITNESS=b, READY_PCT=pct, N_IMAGES=80, W=256, H=64,
                            PIX_PATH=f"{d}/x.pix", JLS_PATH=f"{d}/x.jls", LEN_PATH=f"{d}/x.len"))
    for seed in range(424200, 424216):
        p = rs.settings(np.random.default_rng(seed)); d = STIM / f"s{seed}"
        if p["n"] * p["w"] * p["h"] > 40000:
            p["n"] = max(2, 40000 // (p["w"] * p["h"]))
        rs.generate(seed, p, d)
        streams.append(dict(BITNESS=p["bits"], READY_PCT=p["ready"], VALID_PCT=p["valid"], OUT_WIDTH=p["out"], N_IMAGES=p["n"],
                            W=p["w"], H=p["h"], SEED=seed, MAX_W=p["max_w"], MAX_H=p["max_h"],
                            PIX_PATH=f"{d}/x.pix", JLS_PATH=f"{d}/x.jls", LEN_PATH=f"{d}/x.len"))
    plan = dict(imgs=imgs, streams=streams)
    (STIM / "plan.json").write_text(json.dumps(plan))
    return plan


def golden_base():
    base = WORK / "base_golden"
    shutil.rmtree(base, ignore_errors=True); base.mkdir(parents=True)
    r = nvc_gm(base, ["-a", "--relaxed", "--psl"] + [str(OLO / f"olo_base_{f}.vhd") for f in OLO_F])
    r = r if r.returncode else gm_analyze(base)
    if r.returncode:
        sys.exit("Golden base analysis failed:\n" + (r.stdout + r.stderr)[-2000:])
    return base


def gm_sim(lib, cwd, tb, gen, timeout):
    args = ["-e", "--jit", "--no-save"] + [f"-g{k}={v}" for k, v in gen.items()] + [tb, "-r", "--exit-severity=error", tb]
    try:
        r = nvc_gm(lib, args, cwd, timeout)
    except sp.TimeoutExpired:
        return "TIMEOUT"
    return "PASS" if r.returncode == 0 else "FAIL"


def golden_run(lib, w):
    """(verdict, what) at the first failure."""
    for p, j, b in PLAN["imgs"]:
        t = gm_sim(lib, w, "tb_openjls_golden", dict(PGM_PATH=p, JLS_PATH=j, OUT_PATH=f"{w}/o.jls", BITNESS=b), 120)
        if t != "PASS":
            return t, f"image {Path(p).stem}"
    for s in PLAN["streams"]:
        t = gm_sim(lib, w, "tb_openjls_golden_stream", dict(s, RES_PATH=f"{w}/x.res"), 400)
        if t != "PASS":
            return t, f"stream {Path(s['PIX_PATH']).parent.name}"
    return "PASS", None


# ---------------------------------------------------------------- Formal

sys.path[:0] = [str(FO), str(FO / "Common"), str(FO / "Properties")]


def formal_checks():
    """[(index, baseline seconds)] of the release checks that must prove; fault-injection checks excluded."""
    import run_suite
    rows = (FO / "Results/formal_results.tsv").read_text().splitlines()[1:]
    sec = [int(r.split("\t")[5]) for r in rows]
    return [(i, sec[i]) for i, c in enumerate(run_suite.CHECKS) if c[2] != "DISPROVED"]


def formal_hash(src, work, idx):
    r = sp.run([sys.executable, str(M / "formal_check.py"), "--hash"] + [str(i) for i in idx], capture_output=True, text=True,
               env=dict(os.environ, FORMAL_SOURCES=str(src), FORMAL_WORK=str(work)), timeout=3600)
    return {int(k): v for k, v in json.loads(r.stdout.strip().splitlines()[-1]).items()}


def formal_one(src, work, i, timeout):
    p = sp.Popen([sys.executable, str(M / "formal_check.py"), str(i)], stdout=sp.PIPE, stderr=sp.PIPE, text=True,
                 env=dict(os.environ, FORMAL_SOURCES=str(src), FORMAL_WORK=str(work)), start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
    except sp.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL); p.communicate()
        return "TIMEOUT"
    checked(sp.CompletedProcess(p.args, p.returncode, out, err))
    try:
        return json.loads(out.strip().splitlines()[-1])["res"]
    except (ValueError, IndexError):
        return "ERROR"


# ---------------------------------------------------------------- Worker

def init(q):
    global W, LIB_OS, LIB_GM, SRC, GOLD_HASH, PLAN
    W = WORK / f"w{q.get():02d}"
    shutil.rmtree(W, ignore_errors=True)
    (W / "os/OsvvmTemp_NVC").mkdir(parents=True); (W / "os/reports").mkdir(); (W / "gm").mkdir()
    (W / "os/run_seed.txt").write_text(SEED + "\n")
    LIB_OS, LIB_GM, SRC = W / "lib_os", W / "lib_gm", W / "src"
    shutil.copytree(WORK / "base_osvvm", LIB_OS)
    shutil.copytree(WORK / "base_golden", LIB_GM)
    shutil.copytree(S, SRC, ignore=shutil.ignore_patterns("Xilinx"))
    GOLD_HASH = None
    PLAN = json.loads((STIM / "plan.json").read_text())


def baseline_os(t):
    d, tb, g = t
    st, sec = run_tb(LIB_OS, W / "os", tb, g, 3600)
    return t, st, sec


def baseline_gm(_):
    return golden_run(LIB_GM, W / "gm")


def stage_osvvm(stem, mfile, cfgs):
    tbs = sorted({str(O / d / f"{t}.vhd") for d, t, _ in cfgs})
    orig = STEM[stem].resolve()
    r = nvc_os(LIB_OS, ["-a", "--relaxed", "--psl"] + [str(mfile) if x == orig else str(x) for x in RTL_OS] + tbs, O)
    if r.returncode:
        return "INVALID", None
    for d, t, g in cfgs:
        st, _ = run_tb(LIB_OS, W / "os", t, g, max(120, 6 * BASE_SEC[(t, json.dumps(g, sort_keys=True))]))
        if st != "PASS":
            return "KILLED", f"OSVVM {t} {' '.join(f'{k}={v}' for k, v in g.items())}".strip() + (" (timeout)" if st == "TIMEOUT" else "")
    return "SURVIVED", None


def stage_golden(stem, mfile):
    if gm_analyze(LIB_GM, (STEM[stem].name, mfile)).returncode:
        return "INVALID", None
    st, what = golden_run(LIB_GM, W / "gm")
    return ("SURVIVED", None) if st == "PASS" else ("KILLED", f"golden {what}" + (" (timeout)" if st == "TIMEOUT" else ""))


def stage_formal(stem, text):
    global GOLD_HASH
    idx = [i for i, _ in FCHECKS]
    if GOLD_HASH is None:
        GOLD_HASH = formal_hash(SRC, W / "fh", idx)
    f = SRC / f"{stem}.vhd"; orig = f.read_text()
    f.write_text(text)
    try:
        mh = formal_hash(SRC, W / "fh", idx)
        hit = sorted((sec, i) for i, sec in FCHECKS if mh.get(i) != GOLD_HASH.get(i))
        for sec, i in hit:
            r = formal_one(SRC, W / "fw", i, max(300, 4 * sec))
            # Up to ~40 MB per check; keep only the one in flight
            shutil.rmtree(W / "fw" / f"j{i:03d}", ignore_errors=True)
            if r == "DISPROVED":
                return "KILLED", f"formal {FNAME[i]}"
        return "SURVIVED", f"{len(hit)} formal checks proved"
    finally:
        f.write_text(orig)


def one(m):
    try:
        return one_(m)
    except InfraError as e:
        return dict(m, result="ERROR", detail=str(e))


def one_(m):
    t0 = time.time()
    stem = m["stem"]
    lines = STEM[stem].read_text().splitlines(keepends=True)
    lines[m["line"]] = m["to"] + "\n"
    text = "".join(lines)
    mfile = W / "m.vhd"; mfile.write_text(text)
    tbs = [x for t in (sorted({t for s in MOD_TB.values() for t in s}) if stem == "openjls_pkg" else MOD_TB.get(stem, []))
           for x in TESTS if x[1] == f"tb_{t}_osvvm"]
    res, detail = stage_osvvm(stem, mfile, tbs + SYS_TESTS)
    if res == "SURVIVED" and stem not in XILINX:
        res, detail = stage_golden(stem, mfile)
    if res == "SURVIVED" and stem not in XILINX:
        res, detail = stage_formal(stem, text)
    return dict(m, line=m["line"] + 1, result=res, detail=detail or "", seconds=int(time.time() - t0))


# ---------------------------------------------------------------- Main

COLS = ["id", "file", "line", "kind", "from", "to", "result", "detail", "seconds", "file_hash", "ver_hash", "rtl_hash", "date"]


def read_tsv(p):
    if not p.exists():
        return {}
    ls = p.read_text().splitlines()
    return {r["id"]: r for r in (dict(zip(ls[0].split("\t"), l.split("\t"))) for l in ls[1:])}


def main():
    WORK.mkdir(parents=True, exist_ok=True); RES.mkdir(exist_ok=True)
    nvc_v = tool(["nvc", "--version"]).splitlines()[0]
    ver_files = ([p for d in ("Modules", "Top", "Support") for p in (O / d).glob("*.vhd")] + [O / "OpenJls.pro"]
                 + GM_TBS + [GM / "random_stream.py", GM / "build_run.sh"]
                 + [p for d in ("Common", "Properties") for p in (FO / d).glob("*")] + [FO / "run_suite.py"]
                 + [M / "run.py", M / "mutants.py", M / "formal_check.py"])
    ver_hash = sha(files_hash([p for p in ver_files if p.is_file()]), nvc_v)
    rtl_hash = files_hash(FILES)
    only = set(filter(None, os.environ.get("MUT_ONLY", "").split(",")))
    muts = []
    for s_, f in STEM.items():
        fh = files_hash([f])
        muts += [dict(m, stem=s_, file_hash=fh) for m in mutants.all_mutants(f.read_text(), s_)]
    old = {} if os.environ.get("RERUN") == "1" else read_tsv(RES / "mutation_results.tsv")
    part = RES / "partial.jsonl"
    if part.exists():
        for l in part.read_text().splitlines():
            try:
                r = json.loads(l)
            except ValueError:  # torn last line of a killed run
                continue
            old[r["id"]] = r
    # A caught mutant stays caught while its own file is unchanged; RERUN=1 rechecks it after a test bench edit.
    # A survivor reruns on any change to the RTL or the verification.
    def reuse(m, r):
        if r["file_hash"] != m["file_hash"]:
            return False
        return r["result"] in ("KILLED", "INVALID") or (r["ver_hash"] == ver_hash and r["rtl_hash"] == rtl_hash)
    keep = {m["id"]: old[m["id"]] for m in muts if m["id"] in old and reuse(m, old[m["id"]])}
    # MUT_ONLY runs a subset; other rows keep whatever they had
    keep.update({m["id"]: old[m["id"]] for m in muts if only and m["stem"] not in only and m["id"] in old and m["id"] not in keep})
    todo = [m for m in muts if m["id"] not in keep and (not only or m["stem"] in only)]
    print(f"mutants {len(muts)}, cached {len(keep)}, to run {len(todo)}", flush=True)

    rows = dict(keep)
    if todo:
        global PLAN, BASE_SEC, FCHECKS, FNAME, SEED
        # The seed OpenJls.pro derives from the gold RTL; mutants keep it
        SEED = sp.run(["bash", "-c", 'cat "$0"/*.vhd "$0"/Xilinx/*.vhd | sha256sum | cut -d" " -f1', str(S)],
                      capture_output=True, text=True).stdout.strip()
        osvvm_base(); golden_base()
        PLAN = golden_plan()
        import run_suite
        FCHECKS = formal_checks()
        FNAME = {i: f"{c[0]} | {c[1]}" for i, c in enumerate(run_suite.CHECKS)}
        fenv = (FO / "Results/report_status.env").read_text()
        if "STATUS=PASS" not in fenv:
            sys.exit("Formal suite is not PASS: run Verification/Formal/build_run.sh first")
        q = MP.Queue()
        for i in range(NT):
            q.put(i)
        with MP.Pool(NT, init, (q,)) as p:
            base = p.map(baseline_os, TESTS, chunksize=1)
            bad = [(t, st) for t, st, _ in base if st != "PASS"]
            gm = p.apply(baseline_gm, (0,))
            if bad or gm[0] != "PASS":
                sys.exit(f"Baseline not clean: OSVVM {bad}, golden {gm}")
            BASE_SEC = {(t[1], json.dumps(t[2], sort_keys=True)): sec for t, _, sec in base}
        q = MP.Queue()
        for i in range(NT):
            q.put(i)
        t0 = time.time()
        with MP.Pool(NT, init, (q,)) as p, open(part, "a") as f:
            for n, r in enumerate(p.imap_unordered(one, sorted(todo, key=lambda m: m["stem"] != "openjls_top"), chunksize=1), 1):
                if r["result"] == "ERROR":
                    p.terminate()
                    sys.exit(f"Stopped, machine error on {r['id']} (no verdict recorded):\n{r['detail']}")
                r.update(file=STEM[r["stem"]].relative_to(R).as_posix(), ver_hash=ver_hash, rtl_hash=rtl_hash,
                         date=datetime.now().astimezone().isoformat(timespec="seconds"))
                f.write(json.dumps({k: r.get(k) for k in COLS}) + "\n"); f.flush()
                rows[r["id"]] = r
                if r["result"] == "SURVIVED" or n % 50 == 0 or n == len(todo):
                    print(f"{n}/{len(todo)} {int(time.time() - t0)} s" + (f" SURVIVED {r['id']}: {r['to'].strip()}" if r["result"] == "SURVIVED" else ""), flush=True)

    fail = report(rows, rtl_hash, ver_hash, len(muts))
    with open(RES / "mutation_results.tsv", "w") as f:
        f.write("\t".join(COLS) + "\n")
        for k in sorted(rows):
            f.write("\t".join(str(rows[k].get(c, "")).replace("\t", " ").replace("\n", " ") for c in COLS) + "\n")
    part.unlink(missing_ok=True)
    return fail


def report(rows, rtl_hash, ver_hash, total):
    """Writes report_status.env; marks registered survivors EQUIVALENT. True on FAIL."""
    reg = M / "equivalent.tsv"
    eq = {l.split("\t")[0] for l in (reg.read_text().splitlines()[1:] if reg.exists() else []) if l.strip()}
    for r in rows.values():
        if r["result"] in ("SURVIVED", "EQUIVALENT"):
            r["result"] = "EQUIVALENT" if r["id"] in eq else "SURVIVED"
    rs = list(rows.values())
    valid = [r for r in rs if r["result"] != "INVALID"]
    ok = sum(r["result"] in ("KILLED", "EQUIVALENT") for r in valid)
    open_ = [r for r in valid if r["result"] == "SURVIVED"]
    n_eq = sum(r["result"] == "EQUIVALENT" for r in valid)
    stale = sorted(eq - set(rows))
    current = len(rs) == total
    st = "FAIL" if open_ else ("PASS" if current else "PARTIAL")
    h = sp.run(["bash", "-c", 'cat "$0"/*.vhd | sha256sum | cut -c1-12', str(S)], capture_output=True, text=True).stdout.strip()
    (RES / "report_status.env").write_text(
        'NAME="Mutation"\n'
        f"STATUS={st}\n"
        f'PCT="{100 * ok // max(1, len(valid))}%"\n'
        f'SUMMARY="{ok} of {len(valid)} mutants caught or equivalent"\n'
        f'DETAIL="{n_eq} equivalent, listed with the reason in equivalent.tsv; {len(rs) - len(valid)} mutants that do not'
        ' compile are not counted."\n'
        f'DATE="{datetime.now().astimezone().isoformat(timespec="seconds")}"\n'
        f"SOURCES_HASH={h}\n")
    for r in open_:
        print(f"OPEN {r['id']} {r['file']}:{r['line']}: {r['to'].strip()}")
    for s_ in stale:
        print(f"STALE equivalent.tsv entry {s_}: no such mutant")
    print(f"Mutation: {st}, {ok} of {len(valid)} caught or equivalent, {len(open_)} open, {len(stale)} stale registry entries")
    return st == "FAIL"


if __name__ == "__main__":
    sys.exit(main())
