#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""openjls_top width-constant mutants: every block that takes the changed widths, gold vs mutant constants.

Each obligation holds two copies of a block chain, one with the top constants and one with the mutant's (suffix _M),
fed the same values. Inputs are limited by the invariants Formal/Properties/ag.py proves; the check is that every
output has the same integer value. The top only stores these values in registers and the context RAM, and resizes
them between stages; in range, both are value-preserving at either width. Jobs run only at generics where a constant
differs (const_eq.py evaluator), so no proof is vacuous.
  width_eq.py ID [ID ...]   Env: WE_WORK, WE_OUT, WE_THREADS (20), WE_BITS ("8..16"), WE_MIW ("4096 7 65535"),
                            WE_TIMEOUT (3600 s per job), WE_FAULT="NAME=expr" (fault-injection check; ID is then only a label)
"""
import itertools, json, os, re, shutil, subprocess, sys, multiprocessing as mp
from pathlib import Path

F = Path(__file__).resolve().parent
sys.path[:0] = [str(F), str(F.parent), str(F.parents[1] / "Formal/Common")]
import const_eq as ce
import gen_harness as gh
import mutants as mut
from prep import prep
from flow import S, BASE, run

WORK = Path(os.environ.get("WE_WORK", "/tmp/width_eq"))
OUT = Path(os.environ.get("WE_OUT", F.parent / "Results/classify/width_eq.jsonl"))
BITS = [int(b) for b in os.environ.get("WE_BITS", " ".join(map(str, range(8, 17)))).split()]
MIW = [int(w) for w in os.environ.get("WE_MIW", "4096 7 65535").split()]

HALF = "to_unsigned(2 ** (BITNESS - 1), 16)"
A_INIT = "math_max(2, (RANGE_P + 32) / 64)"
A_OK = f"resize(iAq_i, 24) <= resize(iNq_i - 1, 8) * {HALF} + {A_INIT}"
CTX = ["iNq_i >= 1 and iNq_i <= RESET", "iBq_i <= 0 and iBq_i > -signed(resize(iNq_i, B_WIDTH))", A_OK]

# Per obligation: free inputs (gold widths), per-copy declarations and body ({s} = "" or "_M"), assumptions, and the
# outputs compared by integer value. Copy inputs are named <input>{s}, resized from <input>_i.
OBL = {
    "golomb_regular": dict(
        srcs=["A10_compute_k", "A20_2_compute_k", "A11_error_mapping", "A11_1_golomb_encoder"],
        free={"iErr_i": "signed(ERROR_WIDTH - 1 downto 0)", "iAq_i": "unsigned(A_WIDTH - 1 downto 0)",
              "iBq_i": "signed(B_WIDTH - 1 downto 0)", "iNq_i": "unsigned(N_WIDTH - 1 downto 0)"},
        copy="""  signal iErr{s} : signed(ERROR_WIDTH{s} - 1 downto 0);
  signal iAq{s} : unsigned(A_WIDTH{s} - 1 downto 0);
  signal iBq{s} : signed(B_WIDTH{s} - 1 downto 0);
  signal iNq{s} : unsigned(N_WIDTH{s} - 1 downto 0);
  signal sK{s} : unsigned(K_WIDTH{s} - 1 downto 0);
  signal sMErr{s} : unsigned(MAPPED_ERROR_VAL_WIDTH{s} - 1 downto 0);
  signal oUnary{s} : unsigned(UNARY_WIDTH{s} - 1 downto 0);
  signal oSufLen{s} : unsigned(SUFFIXLEN_WIDTH{s} - 1 downto 0);
  signal oSufVal{s} : unsigned(SUFFIX_WIDTH{s} - 1 downto 0);""",
        body="""  u_a20_2{s} : entity work.a20_2_compute_k generic map (A_WIDTH => A_WIDTH{s}, K_WIDTH => K_WIDTH{s}, N_WIDTH => N_WIDTH{s})
    port map (iRunInterruption => '0', iRItype => '0', iAq => iAq{s}, iNq => iNq{s}, oK => sK{s});
  u_a11{s} : entity work.a11_error_mapping
    generic map (N_WIDTH => N_WIDTH{s}, B_WIDTH => B_WIDTH{s}, K_WIDTH => K_WIDTH{s}, ERROR_WIDTH => ERROR_WIDTH{s},
                 MAPPED_ERROR_VAL_WIDTH => MAPPED_ERROR_VAL_WIDTH{s})
    port map (iK => sK{s}, iBq => iBq{s}, iNq => iNq{s}, iErrorVal => iErr{s}, oMappedErrorVal => sMErr{s});
  u_a11_1{s} : entity work.a11_1_golomb_encoder
    generic map (K_WIDTH => K_WIDTH{s}, QBPP => QBPP{s}, LIMIT => LIMIT{s}, UNARY_WIDTH => UNARY_WIDTH{s},
                 SUFFIX_WIDTH => SUFFIX_WIDTH{s}, SUFFIXLEN_WIDTH => SUFFIXLEN_WIDTH{s},
                 MAPPED_ERROR_VAL_WIDTH => MAPPED_ERROR_VAL_WIDTH{s})
    port map (iK => sK{s}, iMappedErrorVal => sMErr{s}, iRiMode => '0', iRunIndex => (others => '0'),
              oUnaryZeros => oUnary{s}, oSuffixLen => oSufLen{s}, oSuffixVal => oSufVal{s});""",
        assume=["iErr_i >= -(2 ** (BITNESS - 1)) and iErr_i < 2 ** (BITNESS - 1)"] + CTX,
        cmp=["sK", "sMErr", "oUnary", "oSufLen", "oSufVal"]),
    "golomb_ri": dict(
        srcs=["A10_compute_k", "A20_2_compute_k", "A19_run_interruption_error", "A21_compute_map",
              "A22_errval_mapping", "A11_1_golomb_encoder"],
        free={"iErr_i": "signed(BITNESS downto 0)", "iRiType_i": "std_logic", "iRaGtRb_i": "std_logic",
              "iAq_i": "unsigned(A_WIDTH - 1 downto 0)", "iNq_i": "unsigned(N_WIDTH - 1 downto 0)",
              "iNn_i": "unsigned(N_WIDTH - 1 downto 0)", "iRunIndex_i": "unsigned(4 downto 0)"},
        copy="""  signal iAq{s} : unsigned(A_WIDTH{s} - 1 downto 0);
  signal iNq{s}, iNn{s} : unsigned(N_WIDTH{s} - 1 downto 0);
  signal sErr19{s} : signed(BITNESS downto 0);
  signal sSign{s}, sMap{s} : std_logic;
  signal sK{s} : unsigned(K_WIDTH{s} - 1 downto 0);
  signal sEm{s} : unsigned(MAPPED_ERROR_VAL_WIDTH{s} - 1 downto 0);
  signal oUnary{s} : unsigned(UNARY_WIDTH{s} - 1 downto 0);
  signal oSufLen{s} : unsigned(SUFFIXLEN_WIDTH{s} - 1 downto 0);
  signal oSufVal{s} : unsigned(SUFFIX_WIDTH{s} - 1 downto 0);""",
        body="""  iNn{s} <= resize(iNn_i, N_WIDTH{s});
  u_a19{s} : entity work.a19_run_interruption_error generic map (BITNESS => BITNESS, RANGE_P => RANGE_P{s})
    port map (iErrval => iErr_i, iRItype => iRiType_i, iRaGtRb => iRaGtRb_i, oErrval => sErr19{s}, oSign => sSign{s});
  u_a20_2{s} : entity work.a20_2_compute_k generic map (A_WIDTH => A_WIDTH{s}, K_WIDTH => K_WIDTH{s}, N_WIDTH => N_WIDTH{s})
    port map (iRunInterruption => '1', iRItype => iRiType_i, iAq => iAq{s}, iNq => iNq{s}, oK => sK{s});
  u_a21{s} : entity work.a21_compute_map generic map (K_WIDTH => K_WIDTH{s}, N_WIDTH => N_WIDTH{s}, ERROR_WIDTH => ERROR_WIDTH{s})
    port map (iK => sK{s}, iErrval => sErr19{s}, iNn => iNn{s}, iNq => iNq{s}, oMap => sMap{s});
  u_a22{s} : entity work.a22_errval_mapping generic map (ERROR_WIDTH => ERROR_WIDTH{s}, MAPPED_ERRVAL_WIDTH => MAPPED_ERROR_VAL_WIDTH{s})
    port map (iErrval => sErr19{s}, iRiType => iRiType_i, iMap => sMap{s}, oEmErrVal => sEm{s});
  u_a11_1{s} : entity work.a11_1_golomb_encoder
    generic map (K_WIDTH => K_WIDTH{s}, QBPP => QBPP{s}, LIMIT => LIMIT{s}, UNARY_WIDTH => UNARY_WIDTH{s},
                 SUFFIX_WIDTH => SUFFIX_WIDTH{s}, SUFFIXLEN_WIDTH => SUFFIXLEN_WIDTH{s},
                 MAPPED_ERROR_VAL_WIDTH => MAPPED_ERROR_VAL_WIDTH{s})
    port map (iK => sK{s}, iMappedErrorVal => sEm{s}, iRiMode => '1', iRunIndex => iRunIndex_i,
              oUnaryZeros => oUnary{s}, oSuffixLen => oSufLen{s}, oSuffixVal => oSufVal{s});""",
        assume=["iErr_i >= -MAX_VAL and iErr_i <= MAX_VAL", "iRiType_i = '1' -> iErr_i /= 0",
                "iNq_i >= 1 and iNq_i <= RESET", "iNn_i < iNq_i", "iRunIndex_i <= 31", A_OK],
        cmp=["sK", "sMap", "sEm", "oUnary", "oSufLen", "oSufVal"]),
    "ctx_regular": dict(
        srcs=["A12_A13_update"],
        free={"iErr_i": "signed(ERROR_WIDTH - 1 downto 0)", "iAq_i": "unsigned(A_WIDTH - 1 downto 0)",
              "iBq_i": "signed(B_WIDTH - 1 downto 0)", "iCq_i": "signed(C_WIDTH - 1 downto 0)",
              "iNq_i": "unsigned(N_WIDTH - 1 downto 0)"},
        copy="""  signal iErr{s} : signed(ERROR_WIDTH{s} - 1 downto 0);
  signal iAq{s}, oAq{s} : unsigned(A_WIDTH{s} - 1 downto 0);
  signal iBq{s}, oBq{s} : signed(B_WIDTH{s} - 1 downto 0);
  signal iCq{s}, oCq{s} : signed(C_WIDTH{s} - 1 downto 0);
  signal iNq{s}, sNqNew{s} : unsigned(N_WIDTH{s} - 1 downto 0);
  signal sRescale{s}, oDec{s}, oInc{s} : std_logic;""",
        body="""  iCq{s} <= resize(iCq_i, C_WIDTH{s});
  sRescale{s} <= '1' when iNq{s} = RESET{s} else '0';
  sNqNew{s}   <= to_unsigned(RESET{s} / 2 + 1, N_WIDTH{s}) when iNq{s} = RESET{s} else iNq{s} + 1;
  u_a12_a13{s} : entity work.a12_a13_update
    generic map (ERROR_WIDTH => BITNESS + 1, A_WIDTH => A_WIDTH{s}, B_WIDTH => B_WIDTH{s}, N_WIDTH => N_WIDTH{s},
                 C_WIDTH => C_WIDTH{s}, MIN_C => MIN_C{s}, MAX_C => MAX_C{s}, RESET => RESET{s})
    port map (iErrorVal => iErr{s}, iAq => iAq{s}, iBq => iBq{s}, iCq => iCq{s}, iNq => iNq{s}, iNqNew => sNqNew{s},
              iRescale => sRescale{s}, oAq => oAq{s}, oBq => oBq{s}, oCq => oCq{s}, oDec => oDec{s}, oInc => oInc{s});""",
        assume=["iErr_i >= -(2 ** (BITNESS - 1)) and iErr_i < 2 ** (BITNESS - 1)", "iCq_i >= MIN_C and iCq_i <= MAX_C"]
        + CTX,
        cmp=["sNqNew", "oAq", "oBq", "oCq", "oDec", "oInc"]),
    "ctx_ri": dict(
        srcs=["A19_run_interruption_error", "A23_run_interruption_update"],
        free={"iErr_i": "signed(BITNESS downto 0)", "iRiType_i": "std_logic", "iRaGtRb_i": "std_logic",
              "iAq_i": "unsigned(A_WIDTH - 1 downto 0)", "iNq_i": "unsigned(N_WIDTH - 1 downto 0)",
              "iNn_i": "unsigned(NN_WIDTH - 1 downto 0)"},
        copy="""  signal sErr19{s} : signed(BITNESS downto 0);
  signal sSign{s} : std_logic;
  signal sDelta{s} : unsigned(BITNESS - 1 downto 0);
  signal iAq{s}, oAq{s} : unsigned(A_WIDTH{s} - 1 downto 0);
  signal iNq{s}, oNq{s} : unsigned(N_WIDTH{s} - 1 downto 0);
  signal iNn{s}, oNn{s} : unsigned(NN_WIDTH{s} - 1 downto 0);""",
        body="""  iNn{s} <= resize(iNn_i, NN_WIDTH{s});
  u_a19{s} : entity work.a19_run_interruption_error generic map (BITNESS => BITNESS, RANGE_P => RANGE_P{s})
    port map (iErrval => iErr_i, iRItype => iRiType_i, iRaGtRb => iRaGtRb_i, oErrval => sErr19{s}, oSign => sSign{s});
  u_a23_delta{s} : entity work.a23_aq_delta generic map (ERROR_WIDTH => BITNESS + 1)
    port map (iErrVal => sErr19{s}, iRiType => iRiType_i, oDelta => sDelta{s});
  u_a23{s} : entity work.a23_run_interruption_update
    generic map (A_WIDTH => A_WIDTH{s}, N_WIDTH => N_WIDTH{s}, NN_WIDTH => NN_WIDTH{s}, ERROR_WIDTH => ERROR_WIDTH{s},
                 RESET => RESET{s})
    port map (iErrVal => sErr19{s}, iAqDelta => sDelta{s}, iAq => iAq{s}, iNq => iNq{s}, iNn => iNn{s},
              oAq => oAq{s}, oNq => oNq{s}, oNn => oNn{s});""",
        assume=["iErr_i >= -MAX_VAL and iErr_i <= MAX_VAL", "iRiType_i = '1' -> iErr_i /= 0",
                "iNq_i >= 1 and iNq_i <= RESET", "iNn_i < iNq_i", A_OK],
        cmp=["sErr19", "sDelta", "oAq", "oNq", "oNn"]),
    # sRunCntReg as in the top; a run count before a pixel is at most its column index (runs stop at EOL)
    "run": dict(
        clocked=True,
        # Its own asserts check its state before the first reset; only the equality asserts matter here
        strip=["a15_a16_encode_run*"],
        engine="abc pdr",
        srcs=["A14_run_length_determination", "A15_A16_encode_run"],
        free={"iRst_i": "std_logic", "iCE_i": "std_logic", "iEoi_i": "std_logic", "iEol_i": "std_logic",
              "iMode_i": "std_logic",
              "iIx_i": "unsigned(BITNESS - 1 downto 0)", "iRa_i": "unsigned(BITNESS - 1 downto 0)",
              "iRb_i": "unsigned(BITNESS - 1 downto 0)"},
        copy="""  signal iRunCnt{s}, sCnt{s} : unsigned(RUN_CNT_WIDTH{s} - 1 downto 0);
  signal sHit{s}, sCont{s}, oRawV{s}, oRiV{s}, oInRun{s} : std_logic;
  signal oRawLen{s}, oRiIdx{s} : unsigned(4 downto 0);
  signal oRawVal{s} : unsigned(RUN_CNT_WIDTH{s} - 1 downto 0);
  signal oRiIx{s}, oRiRa{s}, oRiRb{s} : unsigned(BITNESS - 1 downto 0);""",
        body="""  -- p_run_cnt of openjls_top
  p_run_cnt{s} : process (clk) is
  begin
    if rising_edge(clk) then
      if iRst_i = '1' then
        iRunCnt{s} <= (others => '0');
      elsif iCE_i = '1' and iMode_i = '1' then
        if sCont{s} = '1' then
          iRunCnt{s} <= sCnt{s};
        else
          iRunCnt{s} <= (others => '0');
        end if;
      end if;
    end if;
  end process p_run_cnt{s};
  u_a14{s} : entity work.a14_run_length_determination generic map (BITNESS => BITNESS, RUN_CNT_WIDTH => RUN_CNT_WIDTH{s})
    port map (iRa => iRa_i, iIx => iIx_i, iRunCnt => iRunCnt{s}, iEol => iEol_i, oRunCnt => sCnt{s},
              oRunHit => sHit{s}, oRunContinue => sCont{s});
  u_a15{s} : entity work.a15_a16_encode_run generic map (BITNESS => BITNESS, RUN_CNT_WIDTH => RUN_CNT_WIDTH{s})
    port map (iClk => clk, iRst => iRst_i, iCE => iCE_i, iEoi => iEoi_i, iRunCnt => sCnt{s}, iRunCntPrev => iRunCnt{s},
              iRunHit => sHit{s}, iRunContinue => sCont{s}, iModeIsRun => iMode_i, iIx => iIx_i, iRa => iRa_i,
              iRb => iRb_i, oRawValid => oRawV{s}, oRawSuffixLen => oRawLen{s}, oRawSuffixVal => oRawVal{s},
              oRiValid => oRiV{s}, oRiIx => oRiIx{s}, oRiRa => oRiRa{s}, oRiRb => oRiRb{s}, oRiRunIndex => oRiIdx{s},
              oInRunNext => oInRun{s});""",
        assume=["sInit = '1' -> iRst_i = '1'", "iRunCnt < MAX_IMAGE_WIDTH",
                "iEol_i = '0' -> iRunCnt < MAX_IMAGE_WIDTH - 1"],
        # The packer reads only the low RawLen bits of RawVal (ag.py bit_packer)
        cmp=["sCnt", "sHit", "sCont", "oRawV", "oRawLen", "shift_left(resize(oRawVal{s}, 32), 32 - to_integer(oRawLen))", "oRiV", "oRiIx", "oRiRa", "oRiRb", "oRiIdx",
             "oInRun"]),
    # Assumptions as ag.py bit_packer; bits past a length are ignored (proved there), so both copies get the same bits
    "bit_packer": dict(
        clocked=True,
        srcs=["A11_2_bit_packer"],
        free={"iRst_i": "std_logic", "iStall_i": "std_logic", "iRawV_i": "std_logic", "iGolV_i": "std_logic",
              "iRawLen_i": "unsigned(SUFFIXLEN_WIDTH - 1 downto 0)", "iSufLen_i": "unsigned(SUFFIXLEN_WIDTH - 1 downto 0)",
              "iRawVal_i": "unsigned(SUFFIX_WIDTH - 1 downto 0)", "iSufVal_i": "unsigned(SUFFIX_WIDTH - 1 downto 0)",
              "iUnary_i": "unsigned(UNARY_WIDTH - 1 downto 0)"},
        decl="""  signal sTotal, sRawT, sGolT : natural range 0 to 1023;""",
        copy="""  signal iRawLen{s}, iSufLen{s} : unsigned(SUFFIXLEN_WIDTH{s} - 1 downto 0);
  signal iRawVal{s}, iSufVal{s} : unsigned(SUFFIX_WIDTH{s} - 1 downto 0);
  signal iUnary{s} : unsigned(UNARY_WIDTH{s} - 1 downto 0);
  signal oW{s} : std_logic_vector(LIMIT{s} - 1 downto 0);
  signal oV{s} : std_logic;
  signal oLen{s} : unsigned(log2ceil(LIMIT{s} + 1) - 1 downto 0);""",
        body="""  u_bp{s} : entity work.a11_2_bit_packer
    generic map (LIMIT => LIMIT{s}, OUT_WIDTH => LIMIT{s}, UNARY_WIDTH => UNARY_WIDTH{s}, SUFFIX_WIDTH => SUFFIX_WIDTH{s},
                 SUFFIXLEN_WIDTH => SUFFIXLEN_WIDTH{s})
    port map (iClk => clk, iRst => iRst_i, iStall => iStall_i, iRawValid => iRawV_i, iRawLen => iRawLen{s},
              iRawVal => iRawVal{s}, iGolombValid => iGolV_i, iUnaryZeros => iUnary{s}, iSuffixLen => iSufLen{s},
              iSuffixVal => iSufVal{s}, oWord => oW{s}, oWordValid => oV{s}, oValidLen => oLen{s});""",
        glue="""  sRawT  <= to_integer(iRawLen_i) when iRawV_i = '1' else 0;
  sGolT  <= to_integer(iUnary_i) + 1 + to_integer(iSufLen_i) when iGolV_i = '1' else 0;
  sTotal <= sRawT + sGolT;""",
        assume=["sInit = '1' -> iRst_i = '1'", "iRawV_i = '1' -> (iRawLen_i >= 1 and iRawLen_i <= J_MAX_BITS + 1)",
                "iGolV_i = '1' -> iSufLen_i <= MAX_K", "sTotal <= LIMIT"],
        cmp=["oW", "oV", "oLen"]),
}


def mutant(name):
    text = (S / "openjls_top.vhd").read_text()
    if os.environ.get("WE_FAULT"):  # fault-injection check: NAME=expr replaces the mutant, and must fail
        c, e = os.environ["WE_FAULT"].split("=", 1)
        return text, re.sub(rf"(constant\s+{c}\s*:[^;]*?:=)[^;]*;", rf"\1 {e};", text, count=1, flags=re.I), c
    m = next(x for x in mut.all_mutants(text, "openjls_top", True) if x["id"] == name)
    lines = text.splitlines(); lines[m["line"]] = m["to"]
    return text, "\n".join(lines), re.match(r"\s*constant\s+(\w+)", m["from"], re.I)[1]


def consts(text):
    """Top generics (harness generics) and the constant declarations of an openjls_top text."""
    tmp = WORK / f"src_{os.getpid()}"; tmp.mkdir(parents=True, exist_ok=True); (tmp / "openjls_top.vhd").write_text(text)
    gh.S = tmp  # top_context reads openjls_top.vhd from gh.S
    try:
        return gh.top_context()
    finally:
        gh.S = S


def suffixed(cs):
    names = [re.match(r"constant\s+(\w+)", c, re.I)[1] for c in cs]
    pat = re.compile(r"\b(" + "|".join(names) + r")\b", re.I)
    return [pat.sub(lambda x: x[1] + "_M", c) for c in cs]


def harness(o, gens, cg, cm):
    tg = ";\n    ".join(f"{g} : natural := {d}" for g, d in gens.items())
    free = "\n".join(f"  signal {n} : {t};\n  attribute anyseq of {n} : signal is true;" for n, t in o["free"].items())
    copies, bodies = [], []
    for s in ("", "_M"):
        copies.append(o["copy"].replace("{s}", s))
        body = o["body"].replace("{s}", s)
        for n in o["free"]:
            base = n[:-2]
            if re.search(rf"\b{base}{s}\b", copies[-1]) and not re.search(rf"\b{base}{s}\s*<=", body):
                body = f"  {base}{s} <= resize({n}, {base}{s}'length);\n" + body
        bodies.append(body)
    psl = "\n".join(f"  -- psl assume always ({a});" for a in o["assume"])
    guard = "sInit = '0' -> " if o.get("clocked") else ""
    eq = []
    for c in o["cmp"]:
        if "{s}" in c:
            eq.append(f"{c.replace('{s}', '')} = {c.replace('{s}', '_M')}")
            continue
        bit = re.search(rf"signal [^;]*\b{c}\b[^;]*: std_logic;", o["copy"].replace("{s}", ""))
        vec = re.search(rf"signal [^;]*\b{c}\b[^;]*: std_logic_vector", o["copy"].replace("{s}", ""))
        eq.append(f"{c} = {c}_M" if bit or vec else f"to_integer({c}) = to_integer({c}_M)")
    psl += "\n" + "\n".join(f"  -- psl assert always ({guard}{e});" for e in eq)
    return f"""library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.all;

entity we is
  generic (
    {tg}
  );
  port (clk : in std_logic);
end entity we;

architecture formal of we is
{chr(10).join('  ' + c for c in cg)}
{chr(10).join('  ' + c for c in cm)}
  attribute anyseq : boolean;
  signal sInit : std_logic := '1';
{free}
{o.get("decl", "")}
{chr(10).join(copies)}
begin
  sInit <= '0' when rising_edge(clk);
{o.get("glue", "")}
{chr(10).join(bodies)}
  -- psl default clock is rising_edge(clk);
{psl}
end architecture formal;
"""


def points(name):
    """Generic sets (BITNESS, MAX_IMAGE_WIDTH) where some top constant differs, with the differing constants."""
    gold, mtext, _ = mutant(name)
    pkg = ce.evaluate(ce.decls((S / "openjls_pkg.vhd").read_text()), {})
    pts, seen = [], set()
    for b, w in itertools.product(BITS, MIW):
        g = {**{k: r.start for k, r in ce.TOP_GENERICS.items()}, "bitness": b, "max_image_width": w}
        a, m = ce.env_for("openjls_top", gold, g, pkg), ce.env_for("openjls_top", mtext, g, pkg)
        d = {k: [a[k], m.get(k)] for k in a if k not in g and a[k] != m.get(k)}
        key = (b, json.dumps(d, sort_keys=True))
        if d and key not in seen:
            seen.add(key); pts.append((b, w, d))
    return pts


def one(job):
    name, obl, b, w, d = job
    o = OBL[obl]
    gold, mtext, _ = mutant(name)
    gens, cg = consts(gold)
    _, cm = consts(mtext)
    wd = WORK / f"{name.split(':')[1]}_{obl}_b{b}_w{w}"
    shutil.rmtree(wd, ignore_errors=True); (wd / "lib").mkdir(parents=True)
    (wd / "rtl.vhd").write_text("".join(prep((S / f"{s}.vhd").read_text(), s + ".vhd") for s in o["srcs"]))
    (wd / "we.vhd").write_text(harness(o, gens, cg, suffixed(cm)))
    r = run(["ghdl", "-a", "--std=08", "-frelaxed", "-fpsl", "--workdir=lib"] + [str(f) for f in BASE]
            + ["rtl.vhd", "we.vhd"], wd)
    res = dict(name=name, obl=obl, bits=b, miw=w, diff=d)
    if r.returncode:
        return {**res, "res": "ERROR", "info": r.stderr[-400:]}
    (wd / "p.sby").write_text(f"""[options]
mode prove
depth {6 if o.get("clocked") else 1}
[engines]
{o.get("engine", "smtbmc yices")}
[script]
plugin -i ghdl
ghdl --std=08 -frelaxed -fpsl --workdir=lib -gBITNESS={b} -gMAX_IMAGE_WIDTH={w} we
{"".join(f"chformal -assert -remove {m}{chr(10)}" for m in o.get("strip", []))}prep -top we
memory_map; opt -full
[files]
lib
""")
    try:
        run(["sby", "-f", "p.sby"], wd, timeout=int(os.environ.get("WE_TIMEOUT", "3600")))
    except subprocess.TimeoutExpired:
        return {**res, "res": "TIMEOUT"}
    st = (wd / "p" / "status").read_text().split()[0] if (wd / "p" / "status").exists() else "ERROR"
    if st == "PASS":
        shutil.rmtree(wd)
        return {**res, "res": "PROVED"}
    log = (wd / "p" / "logfile.txt").read_text() if (wd / "p" / "logfile.txt").exists() else ""
    return {**res, "res": st, "info": "\n".join(re.findall(r".*(?:Assert failed|ERROR|error).*", log))[-600:]}


if __name__ == "__main__":
    # Only obligations whose blocks take a changed constant
    jobs = [(n, o, b, w, d) for n in sys.argv[1:] for b, w, d in points(n) for o in OBL
            if any(re.search(rf"\b{k}{{s}}", OBL[o]["copy"] + OBL[o]["body"], re.I) for k in d)]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with mp.Pool(int(os.environ.get("WE_THREADS", "20"))) as p, open(OUT, "a") as f:
        for r in p.imap_unordered(one, jobs):
            f.write(json.dumps(r) + "\n"); f.flush()
            print(r["name"], r["obl"], r["bits"], r["miw"], r["res"], r.get("info", "")[-300:], flush=True)
