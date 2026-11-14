#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Step 1: the RTL's own asserts hold, per module, for all inputs that meet the contracts.

Each module runs as the top instantiates it (generics from openjls_top), inputs free. Its VHDL asserts of severity
error or failure and its PSL asserts stay as checks; PSL asserts on inputs only become assumes (contracts).
CHECKS[...]["assume"] adds contracts the top meets; each names the check that proves it.
python3 rtl_asserts.py [name ...]; env RA_LIVE=1 (known-bad: the first VHDL assert of the module inverted),
RA_BITS ("8 12 16"), RA_TIMEOUT (s, 1800), RA_WORK, RA_THREADS (20).
"""
import json, os, re, shutil, sys, subprocess as sp, multiprocessing as mp
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Common"))
import gen_harness as gh
import ag, cushion
from prep import prep, contracts, KEYWORDS
from flow import BASE, S, RESULTS, run

WORK = Path(os.environ.get("RA_WORK", "/tmp/feq_rtl_asserts"))
TIMEOUT = int(os.environ.get("RA_TIMEOUT", 1800))
BITS = [int(b) for b in os.environ.get("RA_BITS", "8 12 16").split()]

# src: module file; deps: files of sub-modules (their asserts are checked too); sub: (old, new) synth rewrites
ONES = ("    for i in lo to hi - 1 loop\n\n      if (v(v'high - i) /= '1') then",
        "    for i in 0 to v'length - 1 loop\n\n      if (i >= lo and i < hi and v(v'high - i) /= '1') then")
# Image size as in top_ctrl's W8 H4 rows; counters stay small enough for PDR
SMALL = "-gMAX_IMAGE_WIDTH=8 -gMAX_IMAGE_HEIGHT=4"

# Open top obligation: flushes are >= 4 logic cycles apart (images have >= 4 pixels, one pixel enters per logic
# cycle, fixed pipeline latency)
BS_WRAP = cushion.WRAP.replace("  signal sTake : natural range 0 to 1;", """  signal sTake : natural range 0 to 1;
  signal fGap : natural range 0 to 3 := 3;
  signal pRdy, pFd : std_logic;""").replace("  u_bs : entity", """  p_gap : process (clk) is
  begin
    if rising_edge(clk) then
      if iRst_i = '1' then fGap <= 3;
      elsif sTake = 1 then fGap <= 0;
      elsif sStallLogic = '0' and fGap < 3 then fGap <= fGap + 1;
      end if;
    end if;
  end process;

  u_bs : entity""").replace("  -- psl assume always (sFlight + sTake <= 3);",
                         "  -- psl assume always (sFlight + sTake <= 3);\n  -- psl assume always (sTake = 1 -> fGap = 3);\n"
                         "  pRdy <= iReady_i when rising_edge(clk);\n"
                         "  -- psl bs_ready : assert always (sInit = '0' -> (v = '0' or pRdy = '1'));\n"
                         "  pFd <= fd when rising_edge(clk);\n"
                         "  -- psl bs_eoi_gap : assert always ((sInit = '0' and iRst_i = '0') -> not (fd = '1' and pFd = '1'));")
assert BS_WRAP.count("fGap = 3") == 1

# Datapath modules run inside the ag.py chains: real producers plus the context ranges ag.py proves
CHECKS = {
    "A.1 gradients": dict(src="A1_gradient_comp", label="u_a1"),
    "A.5 predictor": dict(src="A5_edge_detecting_predictor", label="u_a5"),
    "A.18 RI error": dict(src="A18_run_interruption_prediction_error", label="u_a18"),
    **{f"{k} (ag.py {o})": dict(ag=o) for k, o in [
        ("A.4, A.4.1", "q_ranges"), ("A.6/A.7, A.9", "errval_regular"), ("A.12/A.13", "ctx_regular"),
        ("A.19, A.23", "ctx_ri"), ("A.10, A.20.2, A.11, A.11.1", "golomb_regular"),
        ("A.19, A.20.2, A.21, A.22, A.11.1", "golomb_ri")]},
    "A.11.2 bit_packer": dict(src="A11_2_bit_packer", label="u_bit_packer", clock="iClk", reset="iRst"),
    "A.15/A.16 run": dict(src="A15_A16_encode_run", label="u_a15_16", clock="iClk", reset="iRst"),
    # The top latches the image size only under reset (openjls_top p_input), in range
    "line_buffer": dict(src="line_buffer", label="u_line_buffer", clock="iClk", reset="iRst", gens=SMALL,
                        decl="  signal pW : unsigned(log2ceil(MAX_IMAGE_WIDTH + 1) - 1 downto 0);\n"
                             "  signal pH : unsigned(log2ceil(MAX_IMAGE_HEIGHT + 1) - 1 downto 0);\n  signal pRst : std_logic;",
                        body="  pW <= iImageWidth_i when rising_edge(clk);\n  pH <= iImageHeight_i when rising_edge(clk);\n"
                             "  pRst <= iRst_i when rising_edge(clk);",
                        assume=["sInit = '1' or pRst = '1' or (iImageWidth_i = pW and iImageHeight_i = pH)",
                                "pRst = '1' -> iValid_i = '0'",
                                "iImageWidth_i >= CO_MIN_IMAGE_WIDTH and iImageWidth_i <= MAX_IMAGE_WIDTH",
                                "iImageHeight_i >= CO_MIN_IMAGE_HEIGHT and iImageHeight_i <= MAX_IMAGE_HEIGHT"]),
    # The cushion.py environment: the top's stall loop and in-flight cap, LIMIT-bit words with zero tails
    "byte_stuffer": dict(src="byte_stuffer", wrap=BS_WRAP, sub=[ONES]),
    # Images in flight as the top counts them (p_images_in_flight). Assume: the top's cap (openjls_top check, assert
    # 1653). Assert fr_last: the framer ends only started images. Each side uses only the other's past cycles.
    "jls_framer": dict(src="jls_framer", label="u_framer", clock="iClk", reset="iRst",
                       decl="  signal fFlight, fOpen : natural range 0 to CO_MAX_IMAGES_IN_FLIGHT + 1;\n  signal fLast, pReady, pEoi : std_logic;",
                       body="  fLast <= oValid_i and iReady_i and oLast_i;\n  pReady <= oReady_i when rising_edge(clk);\n"
                            "  pEoi <= iEoi_i when rising_edge(clk);\n"
                            "  p_flight : process (clk) is\n    variable v : natural range 0 to CO_MAX_IMAGES_IN_FLIGHT + 1;\n"
                            "  begin\n    if rising_edge(clk) then\n      v := fFlight;\n"
                            "      if iStart_i = '1' then v := v + 1; end if;\n"
                            "      if fLast = '1' then v := v - 1; end if;\n"
                            "      if iRst_i = '1' then v := 0; end if;\n      fFlight <= v;\n"
                            "      v := fOpen;\n      if iStart_i = '1' then v := v + 1; end if;\n"
                            "      if iEoi_i = '1' then v := v - 1; end if;\n"
                            "      if iRst_i = '1' then v := 0; end if;\n      fOpen <= v;\n    end if;\n  end process;",
                       # byte_stuffer guarantees (byte_stuffer check): a beat only after a ready cycle, EOI on a beat,
                       # no EOI beats on consecutive cycles (bs_eoi_gap; STALL_MARGIN_BYTES holds one footer)
                       assume=["iStart_i = '1' -> (fFlight < CO_MAX_IMAGES_IN_FLIGHT or fLast = '1')",
                               "sInit = '1' or pReady = '1' or iValid_i = '0'",
                               "iEoi_i = '1' -> iValid_i = '1'",
                               "(sInit = '0' and iRst_i = '0') -> not (iEoi_i = '1' and pEoi = '1')",
                               # Open top obligation: payload beats come only between an image's start and its EOI
                               "iValid_i = '1' -> fOpen > 0"],
                       check=["(iRst_i = '0' and fLast = '1') -> fFlight > 0"]),
}
# The framer buffer depends on OUT_WIDTH: also the smallest and two wide outputs
for w in (48, 256, 1024):
    CHECKS[f"jls_framer OUT_WIDTH {w}"] = dict(CHECKS["jls_framer"], gens=f"-gOUT_WIDTH={w}")
# Top: its own asserts, plus the module contracts above as properties of the real top
RD = "sReg1V = '1' and sCE1 = '1' and (sS2TokenMode = token_regular or sS2TokenMode = token_run_interruption)"
TOP_PROPS = {
    "lb_valid": "iRst = '1' -> next (sValid = '0')",
    "lb_size": "sImageWidth >= CO_MIN_IMAGE_WIDTH and sImageWidth <= MAX_IMAGE_WIDTH and "
               "sImageHeight >= CO_MIN_IMAGE_HEIGHT and sImageHeight <= MAX_IMAGE_HEIGHT",
    "lb_stable": "pRst = '1' or (sImageWidth = pW and sImageHeight = pH)",
    "eoi_eol": "(sReg1V = '1' and sReg1Eoi = '1') -> sReg1Eol = '1'",
    "a15_cnt": "(sReg1ModeRun = '1' and sS2RunHit = '1') -> sS2RunCnt = sRunCntReg + 1",
    "rd_range": f"({RD}) -> sS2Q < RAM_DEPTH",
    "rd_regular": f"({RD} and sReg1.mode = token_regular) -> "
                  "81 * to_integer(sS2MQ1) + 9 * to_integer(sS2MQ2) + to_integer(sS2MQ3) = to_integer(sS2Q)",
    "rd_ri": f"({RD} and sReg1.mode /= token_regular) -> to_integer(sS2Q) = 365 + to_integer(unsigned'('0' & sS2RItype))",
    "wr_range": "(sCtxWrEn = '1' and sCE4 = '1') -> sReg4.Q < RAM_DEPTH",
}
# Context fields written back fit their stored widths: the ag.py ctx_regular/ctx_ri chains with ctx_init
TOP_SKIP = (843, 845, 848, 851, 853)
# Previous-cycle copies for lb_stable (GHDL analysis rejects PSL stable/prev); pRst starts '1'
PREV_DECL = ("  signal pW : unsigned(log2ceil(MAX_IMAGE_WIDTH + 1) - 1 downto 0);\n"
             "  signal pH : unsigned(log2ceil(MAX_IMAGE_HEIGHT + 1) - 1 downto 0);\n  signal pRst : std_logic := '1';")
PREV_BODY = "  pW <= sImageWidth when rising_edge(iClk);\n  pH <= sImageHeight when rising_edge(iClk);\n" \
            "  pRst <= iRst when rising_edge(iClk);\n" \
            "  -- Framer guarantee (jls_framer check, fr_last): it ends only images it started\n" \
            "  -- psl assume always ((iRst = '0' and oValid = '1' and iReady = '1' and oLast = '1') -> sImagesInFlight > 0);\n"
TOP_KEEP = ["u_line_buffer", "u_a4", "u_a4_1", "u_a4_2", "u_a14", "u_a15_16", "u_a20_1"]
RI_PSL = "sReg3.RiType = '1') -> sReg3.Errval /= 0"
CHECKS["openjls_top"] = dict(top=True, keep=TOP_KEEP, skip=TOP_SKIP + (RI_PSL,), props=TOP_PROPS)
# The RI Errval PSL alone, with the run path from line_buffer to A.18 kept
CHECKS["openjls_top RI Errval"] = dict(top=True, keep=["u_line_buffer", "u_a14", "u_a15_16", "u_a17", "u_a18", "u_a19"],
                                       only=RI_PSL, props={})
VASSERT = re.compile(r"^([ \t]*)(postponed[ \t]+)?assert\b(.*?)\breport\b((?:[^;\"]|\"[^\"]*\")*);", re.M | re.S)
FUNCS = {"is_x", "abs", "to_integer", "unsigned", "signed", "resize", "integer", "math_min", "math_max"}


def harness(c):
    src = (S / f"{c['src']}.vhd").read_text()
    ent, arch, gmap = gh.top_instance(c["label"])
    mgens, ports = gh.entity_decl(src, ent)
    full = {g: gmap.get(g, d) for g, d in mgens.items() if g in gmap or d is not None}
    tgens, consts = gh.top_context()
    clock, reset = c.get("clock"), c.get("reset")
    sig, pm = [], []
    for n, d, t in ports:
        if n == clock:
            pm.append(f"{n} => clk")
            continue
        sig.append(f"  signal {n}_i : {gh.subst(t, full)};")
        if d == "in":
            sig.append(f"  attribute anyseq of {n}_i : signal is true;")
        pm.append(f"{n} => {n}_i")
    assumes = list(c.get("assume", []))
    psl = ["  -- psl default clock is rising_edge(clk);"]
    if reset:
        sig.append("  signal sInit : std_logic := '1';")
        psl.append("  sInit <= '0' when rising_edge(clk);")
        assumes.insert(0, f"sInit = '1' -> {reset}_i = '1'")
    psl += [f"  -- psl assume always ({a});" for a in assumes]
    gate = "sInit = '0' -> " if reset else ""
    psl += [f"  -- psl fr_{i} : assert always ({gate}({a}));" for i, a in enumerate(c.get("check", []))]
    gm = ", ".join(f"{g} => {a}" for g, a in full.items())
    tg = ";\n    ".join(f"{g} : natural := {d}" for g, d in tgens.items())
    return f"""library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.all;

entity ra is
  generic (
    {tg}
  );
  port (
    clk : in std_logic
  );
end entity ra;

architecture formal of ra is

  {chr(10).join('  ' + x for x in consts).strip()}
  attribute anyseq : boolean;
{chr(10).join(sig)}
{c.get("decl", "")}
begin
  u_dut : entity work.{ent}{f"({arch})" if arch else ""}
    {f"generic map ({gm})" if gm else ""}
    port map ({", ".join(pm)});
{c.get("body", "")}
{chr(10).join(psl)}
end architecture formal;
"""


def inputs(text):
    ent = re.search(r"\bentity\s+\w+\s+is(.*?)\bend\b", text, re.S | re.I)[1]
    ent = re.sub(r"--.*", "", ent)
    allowed = set()
    for decl in re.findall(r"([\w\s,;(]+?)\s*:\s*(?:in\b|natural|positive|integer|boolean)", ent, re.I):
        allowed |= {n.strip().lower() for n in re.split(r"[,;(]", decl) if n.strip()}
    allowed |= {n.lower() for n in re.findall(r"^\s*constant\s+(\w+)", text, re.M | re.I)}
    return allowed - {"generic", "port"}


def module_src(name, live, labels, cons=None, skip=(), only=None):
    """Checked copy: VHDL asserts labelled ra_<n>. With a cons list, concurrent ones on inputs and generics only
    leave the module and go there (the harness assumes them)."""
    orig = (S / f"{name}.vhd").read_text()
    t = contracts(prep(orig, f"{name}.vhd", keep=True), keep=True)
    allowed = inputs(orig) | FUNCS | KEYWORDS

    def lab(m):
        cond = m[3].strip()
        msg = re.search(r'"([^"]*)"', m[4])
        ol = orig.splitlines()
        line = next((i for i, l in enumerate(ol) if msg and msg[1] in l), -1)
        while line > 0 and not re.search(r"\bassert\b", ol[line]):
            line -= 1
        line += 1
        bare = re.sub(r"\bis_x\([^()]*\)\s+or\b", "", cond)
        ids = {w.lower() for w in re.findall(r"\b[A-Za-z_]\w*\b", re.sub(r"'[^']'", " ", bare))}
        n = len(labels)
        labels[f"ra_{n}"] = f"{name}.vhd:{line}"
        if cons is not None and m[2] and ids <= allowed:
            labels[f"ra_{n}"] += " (contract)"
            cons.append(bare.strip())
            return ""
        if line in skip or only:
            labels[f"ra_{n}"] += " (not checked here)"
            return ""
        bad = live and re.search(r"\b[siov][A-Z]\w*", cond) and not any(v.endswith("(known-bad)") for v in labels.values())
        if bad:
            labels[f"ra_{n}"] += " (known-bad)"
        return f"{m[1]}ra_{n} : {m[2] or ''}assert {f'not ({cond})' if bad else cond} report{m[4]};"
    t = VASSERT.sub(lab, t)
    if cons:
        clk = "" if "psl default clock" in t else "  -- psl default clock is rising_edge(iClk);\n"
        i = t.rindex("end architecture")
        t = t[:i] + clk + "".join(f"  -- psl assume always ({x});\n" for x in cons) + "\n" + t[i:]

    def psl(m):
        n = len(labels)
        if any(isinstance(x, str) and x in m[2] for x in skip) or (only and only not in m[2]):
            labels[f"ra_{n}"] = f"{name}.vhd PSL (not checked here): {m[2].strip()[:60]}"
            return ""
        labels[f"ra_{n}"] = f"{name}.vhd PSL: {m[2].strip()[:70]}"
        if live and not any(v.endswith("(known-bad)") for v in labels.values()):
            labels[f"ra_{n}"] += " (known-bad)"
            return f"{m[1]}ra_{n} : assert always false;"
        return f"{m[1]}ra_{n} : assert{m[2]}"
    return re.sub(r"^([ \t]*--[ \t]*psl[ \t]+)assert\b(.*)$", psl, t, flags=re.M)


def one(arg):
    name, bits, live = arg
    c = CHECKS[name]
    if c.get("top"):
        return top(c, bits, live)
    d = WORK / f"{re.sub(r'\W+', '_', name)}_b{bits}{'_live' if live else ''}"
    shutil.rmtree(d, ignore_errors=True); (d / "lib").mkdir(parents=True)
    labels, files, cons = {}, [], []
    if "ag" in c:
        o = ag.OBL[c["ag"]]
        for i, n in enumerate(o["srcs"]):
            (d / f"{n}.vhd").write_text(module_src(n, live and i == len(o["srcs"]) - 1, labels))
            files.append(f"{n}.vhd")
        (d / "ra.vhd").write_text(ag.harness(o).replace("entity ag is", "entity ra is")
                                  .replace("end entity ag;", "end entity ra;").replace("of ag is", "of ra is"))
    else:
        for n in c.get("deps", []) + [c["src"]]:
            t = module_src(n, live if n == c["src"] else False, labels, cons if n == c["src"] else None)
            for old, new in c.get("sub", []):
                assert old in t, old
                t = t.replace(old, new)
            (d / f"{n}.vhd").write_text(t)
            files.append(f"{n}.vhd")
        (d / "ra.vhd").write_text(c["wrap"].replace("entity cush is", "entity ra is").replace(
            "end entity cush;", "end entity ra;").replace("of cush is", "of ra is") if "wrap" in c else harness(c))
    # wrap: the top's byte_stuffer generics (BYTE_STUFFER_BURST_DEPTH 64, IN_WIDTH = LIMIT)
    gens = f"-gBURST=64 -gLIMIT={2 * (bits + max(8, bits))}" if "wrap" in c else f"-gBITNESS={bits} {c.get('gens', '')}"
    (d / "labels.json").write_text(json.dumps(labels, indent=1))
    r = run(["ghdl", "-a", "--std=08", "-frelaxed", "-fpsl", "--workdir=lib"] + [str(f) for f in BASE]
            + files + ["ra.vhd"], d)
    out = dict(name=name, bits=bits, live=live)
    if r.returncode:
        return dict(out, res="ERROR", info=r.stderr[-600:])
    (d / "p.sby").write_text(f"""[options]
mode prove
[engines]
abc pdr
[script]
plugin -i ghdl
ghdl --std=08 -frelaxed -fpsl --workdir=lib {gens} ra
prep -top ra
chformal -assert -skip 1
flatten; memory_map; opt -fast; setundef -undriven -zero; setundef -zero -init
[files]
lib
""")
    try:
        p = run(["sby", "-f", "p.sby"], d, timeout=TIMEOUT)
    except sp.TimeoutExpired:
        return dict(out, res="TIMEOUT")
    st = (d / "p" / "status").read_text().split()[0] if (d / "p" / "status").exists() else "ERROR"
    res = {"PASS": "PROVED", "FAIL": "DISPROVED"}.get(st, st)
    failed = sorted(set(re.findall(r"Assert failed in \S+: \S*?(ra_\d+)", p.stdout)))
    info = "; ".join(labels.get(f, f) for f in failed) or "; ".join(set(re.findall(r"Assert failed in \S+: (.*)", p.stdout)))
    if st == "ERROR":
        info = (p.stdout + p.stderr)[-600:]
    return dict(out, res=res, info=info)


def top(c, bits, live):
    import top_ctrl
    old = top_ctrl.WORK, top_ctrl.VAC, top_ctrl.KEEP, top_ctrl.PROPS, top_ctrl.TOP_HOOK
    labels = {}
    tag = "ri" if c.get("only") else "top"
    top_ctrl.WORK, top_ctrl.VAC, top_ctrl.KEEP = WORK / f"{tag}_b{bits}{'_live' if live else ''}", False, c["keep"]
    top_ctrl.PROPS = c["props"]
    top_ctrl.TOP_HOOK = lambda _: module_src("openjls_top", live, labels, skip=c.get("skip", ()), only=c.get("only")).replace(
        "\nbegin\n", "\n" + PREV_DECL + "\nbegin\n", 1).replace("end architecture rtl;", PREV_BODY + "\nend architecture rtl;")
    try:
        r = top_ctrl.check(str(bits))
    finally:
        top_ctrl.WORK, top_ctrl.VAC, top_ctrl.KEEP, top_ctrl.PROPS, top_ctrl.TOP_HOOK = old
    fails = set(r.get("failed", [])) | set(re.findall(r"ra_\d+", " ".join(r.get("failed", []))))
    info = "; ".join(sorted({labels.get(re.search(r"ra_\d+", f)[0], f) if re.search(r"ra_\d+", f) else f for f in fails}))
    return dict(name="openjls_top" + (" RI Errval" if c.get("only") else ""), bits=bits, live=live,
                res={"PASS": "PROVED", "FAIL": "DISPROVED"}.get(r["res"], r["res"]), info=info or r.get("info", ""))


RELEASE = list(CHECKS)


def jobs(names=None, live=False):
    return [(n, b, live) for n in (names or RELEASE) for b in BITS]


if __name__ == "__main__":
    js = jobs(sys.argv[1:], bool(os.environ.get("RA_LIVE")))
    with mp.get_context("fork").Pool(min(len(js), int(os.environ.get("RA_THREADS", 20)))) as p, \
            open(RESULTS / "rtl_asserts.jsonl", "a") as f:
        for r in p.imap_unordered(one, js):
            f.write(json.dumps(r) + "\n"); f.flush()
            print(json.dumps(r), flush=True)
