#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Assume-guarantee obligations: prove on each producer the input assumptions module_eq.py uses.

Each obligation is a combinational chain wired as in openjls_top, free inputs limited only by
their types or by an invariant this script proves elsewhere, PSL asserts on the outputs.
Context invariant (regular and RI): 1 <= N <= RESET, A <= (N - 1) * 2^(b-1) + A_INIT, and
-N < B <= 0, MIN_C <= C <= MAX_C (regular). It implies module_eq's CTX (A < 2^A_STORED).
"""
import json, os, re, shutil, sys, multiprocessing as mp
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Common"))
import gen_harness as gh
from prep import prep
from flow import BASE, S, RESULTS, run

F = Path(__file__).resolve().parent
WORK = Path(os.environ.get("AG_WORK", "/tmp/feq_ag"))
OUT = RESULTS / ("ag_vacuity.jsonl" if os.environ.get("AG_VACUITY") else "ag.jsonl")

HALF = "to_unsigned(2 ** (BITNESS - 1), 16)"
A_INIT = "math_max(2, (RANGE_P + 32) / 64)"


def a_ok(a, n):
    return f"resize({a}, 24) <= resize(({n}) - 1, 8) * {HALF} + {A_INIT}"


OBL = {
    # A4 -> Reg1 -> A4_1: what A4_2 and context_ram assume
    "q_ranges": dict(
        srcs=["A4_quantization_gradients", "A4_1_quant_gradient_merging"],
        decl="""  signal iD1_i, iD2_i, iD3_i : signed(BITNESS downto 0);
  signal sQ1, sQ2, sQ3, oQ1, oQ2, oQ3 : signed(3 downto 0);
  signal oSign : std_logic;""",
        free=["iD1_i", "iD2_i", "iD3_i"],
        body="""  u_a4 : entity work.a4_quantization_gradients generic map (BITNESS => BITNESS, MAX_VAL => MAX_VAL)
    port map (iD1 => iD1_i, iD2 => iD2_i, iD3 => iD3_i, oQ1 => sQ1, oQ2 => sQ2, oQ3 => sQ3);
  u_a4_1 : entity work.a4_1_quant_gradient_merging
    port map (iQ1 => sQ1, iQ2 => sQ2, iQ3 => sQ3, oQ1 => oQ1, oQ2 => oQ2, oQ3 => oQ3, oSign => oSign);""",
        assume=[],
        check=["oQ1 >= 0 and oQ1 <= 4 and oQ2 >= -4 and oQ2 <= 4 and oQ3 >= -4 and oQ3 <= 4",
               "81 * to_integer(oQ1) + 9 * to_integer(oQ2) + to_integer(oQ3) >= 0"]),
    # A6 bounds/errors -> A6_A7 -> A9: the regular Errval A12_A13 assumes
    "errval_regular": dict(
        srcs=["A6_A7_prediction_error", "A9_modulo_reduction"],
        decl="""  signal iIx_i, iPx_i : unsigned(BITNESS - 1 downto 0);
  signal iSign_i : std_logic;
  signal iCq_i : signed(CO_CQ_WIDTH - 1 downto 0);
  signal sLo, sHi : signed(CO_CQ_WIDTH downto 0);
  signal sAtLo, sAtHi, sErr7, oErr9 : signed(BITNESS downto 0);""",
        free=["iIx_i", "iPx_i", "iSign_i", "iCq_i"],
        body="""  u_bounds : entity work.a6_clip_bounds generic map (BITNESS => BITNESS, MAX_VAL => MAX_VAL)
    port map (iPx => iPx_i, iSign => iSign_i, oLo => sLo, oHi => sHi);
  u_errors : entity work.a6_clip_errors generic map (BITNESS => BITNESS, MAX_VAL => MAX_VAL)
    port map (iIx => iIx_i, iSign => iSign_i, oAtLo => sAtLo, oAtHi => sAtHi);
  u_a6a7 : entity work.a6_a7_prediction_error generic map (BITNESS => BITNESS, MAX_VAL => MAX_VAL)
    port map (iIx => iIx_i, iPx => iPx_i, iSign => iSign_i, iLo => sLo, iHi => sHi,
              iAtLo => sAtLo, iAtHi => sAtHi, iCq => iCq_i, oErrorVal => sErr7);
  u_a9 : entity work.a9_modulo_reduction generic map (BITNESS => BITNESS, RANGE_P => RANGE_P)
    port map (iErrorVal => sErr7, oErrorVal => oErr9);""",
        assume=[],
        check=["sErr7 >= -MAX_VAL and sErr7 <= MAX_VAL",
               "oErr9 >= -(2 ** (BITNESS - 1)) and oErr9 < 2 ** (BITNESS - 1)"]),
    # A12_A13 with the p_reg4 N update keeps the regular context invariant
    "ctx_regular": dict(
        srcs=["A12_A13_update"],
        decl="""  signal iErr_i : signed(ERROR_WIDTH - 1 downto 0);
  signal iAq_i : unsigned(A_WIDTH - 1 downto 0);
  signal iBq_i : signed(B_WIDTH - 1 downto 0);
  signal iCq_i : signed(C_WIDTH - 1 downto 0);
  signal iNq_i, sNqNew : unsigned(N_WIDTH - 1 downto 0);
  signal sRescale, oDec, oInc : std_logic;
  signal oAq : unsigned(A_WIDTH - 1 downto 0);
  signal oBq : signed(B_WIDTH - 1 downto 0);
  signal oCq : signed(C_WIDTH - 1 downto 0);""",
        free=["iErr_i", "iAq_i", "iBq_i", "iCq_i", "iNq_i"],
        body="""  -- p_reg4
  sRescale <= '1' when iNq_i = RESET else '0';
  sNqNew   <= to_unsigned(RESET / 2 + 1, N_WIDTH) when iNq_i = RESET else iNq_i + 1;
  u_a12_a13 : entity work.a12_a13_update
    generic map (ERROR_WIDTH => BITNESS + 1, A_WIDTH => A_WIDTH, B_WIDTH => B_WIDTH, N_WIDTH => N_WIDTH,
                 C_WIDTH => C_WIDTH, MIN_C => MIN_C, MAX_C => MAX_C, RESET => RESET)
    port map (iErrorVal => iErr_i, iAq => iAq_i, iBq => iBq_i, iCq => iCq_i, iNq => iNq_i, iNqNew => sNqNew,
              iRescale => sRescale, oAq => oAq, oBq => oBq, oCq => oCq, oDec => oDec, oInc => oInc);""",
        assume=["iErr_i >= -(2 ** (BITNESS - 1)) and iErr_i < 2 ** (BITNESS - 1)",
                "iNq_i >= 1 and iNq_i <= RESET",
                "iBq_i <= 0 and iBq_i > -signed(resize(iNq_i, B_WIDTH))",
                "iCq_i >= MIN_C and iCq_i <= MAX_C",
                a_ok("iAq_i", "iNq_i")],
        check=["sNqNew >= 1 and sNqNew <= RESET",
               "oBq <= 0 and oBq > -signed(resize(sNqNew, B_WIDTH))",
               "oCq >= MIN_C and oCq <= MAX_C",
               a_ok("oAq", "sNqNew"),
               "oAq < 2 ** A_STORED"]),
    # A18 difference -> A19 -> A23 delta -> A23 keeps the RI context invariant (A20_2 assumes it)
    # Nn < N (reset values 0 < 1) keeps Nn inside NN_WIDTH
    "ctx_ri": dict(
        srcs=["A19_run_interruption_error", "A23_run_interruption_update"],
        decl="""  signal iErr_i, sErr19 : signed(BITNESS downto 0);
  signal iRiType_i, iRaGtRb_i, sSign : std_logic;
  signal sDelta : unsigned(BITNESS - 1 downto 0);
  signal iAq_i, oAq : unsigned(A_WIDTH - 1 downto 0);
  signal iNq_i, oNq : unsigned(N_WIDTH - 1 downto 0);
  signal iNn_i, oNn : unsigned(NN_WIDTH - 1 downto 0);""",
        free=["iErr_i", "iRiType_i", "iRaGtRb_i", "iAq_i", "iNq_i", "iNn_i"],
        body="""  u_a19 : entity work.a19_run_interruption_error generic map (BITNESS => BITNESS, RANGE_P => RANGE_P)
    port map (iErrval => iErr_i, iRItype => iRiType_i, iRaGtRb => iRaGtRb_i, oErrval => sErr19, oSign => sSign);
  u_a23_delta : entity work.a23_aq_delta generic map (ERROR_WIDTH => BITNESS + 1)
    port map (iErrVal => sErr19, iRiType => iRiType_i, oDelta => sDelta);
  u_a23 : entity work.a23_run_interruption_update
    generic map (A_WIDTH => A_WIDTH, N_WIDTH => N_WIDTH, NN_WIDTH => NN_WIDTH, ERROR_WIDTH => ERROR_WIDTH, RESET => RESET)
    port map (iErrVal => sErr19, iAqDelta => sDelta, iAq => iAq_i, iNq => iNq_i, iNn => iNn_i,
              oAq => oAq, oNq => oNq, oNn => oNn);""",
        # A.18: Ix - Ra or Ix - Rb of BITNESS-bit pixels; RItype = 1 means Ra = Rb = RUNval and the
        # run broke on Ix /= RUNval (A.16, NEAR = 0), so Errval /= 0
        assume=["iErr_i >= -MAX_VAL and iErr_i <= MAX_VAL",
                "iRiType_i = '1' -> iErr_i /= 0",
                "iNq_i >= 1 and iNq_i <= RESET",
                "iNn_i < iNq_i",
                a_ok("iAq_i", "iNq_i")],
        check=["sDelta <= 2 ** (BITNESS - 1)",
               "oNq >= 1 and oNq <= RESET",
               "oNn < oNq",
               a_ok("oAq", "oNq"),
               "oAq < 2 ** A_STORED"]),
    # A20_2 -> A11 -> A11_1, regular: LG(k, LIMIT) never exceeds LIMIT bits (bit_packer OUT_WIDTH)
    "golomb_regular": dict(
        srcs=["A10_compute_k", "A20_2_compute_k", "A11_error_mapping", "A11_1_golomb_encoder"],
        decl="""  signal iErr_i : signed(ERROR_WIDTH - 1 downto 0);
  signal iAq_i : unsigned(A_WIDTH - 1 downto 0);
  signal iBq_i : signed(B_WIDTH - 1 downto 0);
  signal iNq_i : unsigned(N_WIDTH - 1 downto 0);
  signal sK : unsigned(K_WIDTH - 1 downto 0);
  signal sMErr : unsigned(MAPPED_ERROR_VAL_WIDTH - 1 downto 0);
  signal oUnary : unsigned(UNARY_WIDTH - 1 downto 0);
  signal oSufLen : unsigned(SUFFIXLEN_WIDTH - 1 downto 0);
  signal oSufVal : unsigned(SUFFIX_WIDTH - 1 downto 0);""",
        free=["iErr_i", "iAq_i", "iBq_i", "iNq_i"],
        body="""  u_a20_2 : entity work.a20_2_compute_k generic map (A_WIDTH => A_WIDTH, K_WIDTH => K_WIDTH, N_WIDTH => N_WIDTH)
    port map (iRunInterruption => '0', iRItype => '0', iAq => iAq_i, iNq => iNq_i, oK => sK);
  u_a11 : entity work.a11_error_mapping
    generic map (N_WIDTH => N_WIDTH, B_WIDTH => B_WIDTH, K_WIDTH => K_WIDTH, ERROR_WIDTH => ERROR_WIDTH,
                 MAPPED_ERROR_VAL_WIDTH => MAPPED_ERROR_VAL_WIDTH)
    port map (iK => sK, iBq => iBq_i, iNq => iNq_i, iErrorVal => iErr_i, oMappedErrorVal => sMErr);
  u_a11_1 : entity work.a11_1_golomb_encoder
    generic map (K_WIDTH => K_WIDTH, QBPP => QBPP, LIMIT => LIMIT, UNARY_WIDTH => UNARY_WIDTH,
                 SUFFIX_WIDTH => SUFFIX_WIDTH, SUFFIXLEN_WIDTH => SUFFIXLEN_WIDTH,
                 MAPPED_ERROR_VAL_WIDTH => MAPPED_ERROR_VAL_WIDTH)
    port map (iK => sK, iMappedErrorVal => sMErr, iRiMode => '0', iRunIndex => (others => '0'),
              oUnaryZeros => oUnary, oSuffixLen => oSufLen, oSuffixVal => oSufVal);""",
        assume=["iErr_i >= -(2 ** (BITNESS - 1)) and iErr_i < 2 ** (BITNESS - 1)",
                "iNq_i >= 1 and iNq_i <= RESET",
                "iBq_i <= 0 and iBq_i > -signed(resize(iNq_i, B_WIDTH))",
                a_ok("iAq_i", "iNq_i")],
        check=["to_integer(oUnary) + 1 + to_integer(oSufLen) <= LIMIT"]),
    # A19 -> A20_2/A21/A22 -> A11_1, RI: LG(k, glimit) fits beside the J + 1 run bits in LIMIT
    "golomb_ri": dict(
        srcs=["A10_compute_k", "A20_2_compute_k", "A19_run_interruption_error", "A21_compute_map",
              "A22_errval_mapping", "A11_1_golomb_encoder"],
        decl="""  signal iErr_i, sErr19 : signed(BITNESS downto 0);
  signal iRiType_i, iRaGtRb_i, sSign, sMap : std_logic;
  signal iAq_i : unsigned(A_WIDTH - 1 downto 0);
  signal iNq_i, iNn_i : unsigned(N_WIDTH - 1 downto 0);
  signal iRunIndex_i : unsigned(4 downto 0);
  signal sK : unsigned(K_WIDTH - 1 downto 0);
  signal sEm : unsigned(MAPPED_ERROR_VAL_WIDTH - 1 downto 0);
  signal oUnary : unsigned(UNARY_WIDTH - 1 downto 0);
  signal oSufLen : unsigned(SUFFIXLEN_WIDTH - 1 downto 0);
  signal oSufVal : unsigned(SUFFIX_WIDTH - 1 downto 0);""",
        free=["iErr_i", "iRiType_i", "iRaGtRb_i", "iAq_i", "iNq_i", "iNn_i", "iRunIndex_i"],
        body="""  u_a19 : entity work.a19_run_interruption_error generic map (BITNESS => BITNESS, RANGE_P => RANGE_P)
    port map (iErrval => iErr_i, iRItype => iRiType_i, iRaGtRb => iRaGtRb_i, oErrval => sErr19, oSign => sSign);
  u_a20_2 : entity work.a20_2_compute_k generic map (A_WIDTH => A_WIDTH, K_WIDTH => K_WIDTH, N_WIDTH => N_WIDTH)
    port map (iRunInterruption => '1', iRItype => iRiType_i, iAq => iAq_i, iNq => iNq_i, oK => sK);
  u_a21 : entity work.a21_compute_map generic map (K_WIDTH => K_WIDTH, N_WIDTH => N_WIDTH, ERROR_WIDTH => ERROR_WIDTH)
    port map (iK => sK, iErrval => sErr19, iNn => iNn_i, iNq => iNq_i, oMap => sMap);
  u_a22 : entity work.a22_errval_mapping generic map (ERROR_WIDTH => ERROR_WIDTH, MAPPED_ERRVAL_WIDTH => MAPPED_ERROR_VAL_WIDTH)
    port map (iErrval => sErr19, iRiType => iRiType_i, iMap => sMap, oEmErrVal => sEm);
  u_a11_1 : entity work.a11_1_golomb_encoder
    generic map (K_WIDTH => K_WIDTH, QBPP => QBPP, LIMIT => LIMIT, UNARY_WIDTH => UNARY_WIDTH,
                 SUFFIX_WIDTH => SUFFIX_WIDTH, SUFFIXLEN_WIDTH => SUFFIXLEN_WIDTH,
                 MAPPED_ERROR_VAL_WIDTH => MAPPED_ERROR_VAL_WIDTH)
    port map (iK => sK, iMappedErrorVal => sEm, iRiMode => '1', iRunIndex => iRunIndex_i,
              oUnaryZeros => oUnary, oSuffixLen => oSufLen, oSuffixVal => oSufVal);""",
        # Nn is free: no invariant is assumed for it
        assume=["iErr_i >= -MAX_VAL and iErr_i <= MAX_VAL",
                "iRiType_i = '1' -> iErr_i /= 0",
                "iNq_i >= 1 and iNq_i <= RESET",
                a_ok("iAq_i", "iNq_i")],
        check=["to_integer(oUnary) + 1 + to_integer(oSufLen) + CO_J_TABLE(to_integer(iRunIndex_i)) + 1 <= LIMIT"]),
    # bit_packer as the top drives it: RawVal/SuffixVal bits past their lengths never reach the
    # output (A15 env compares low(RawVal, RawLen)), and a valid word meets the byte_stuffer env
    # contract. Raw lengths are 1 or J + 1 (A15 p_comb); totals are golomb_regular/golomb_ri.
    "bit_packer": dict(
        clocked=True,
        srcs=["A11_2_bit_packer"],
        decl="""  signal iRst_i, iStall_i, iRawV_i, iGolV_i : std_logic;
  signal iRawLen_i, iSufLen_i : unsigned(SUFFIXLEN_WIDTH - 1 downto 0);
  signal iRawVal_i, iRawValB_i, iSufVal_i, iSufValB_i : unsigned(SUFFIX_WIDTH - 1 downto 0);
  signal iUnary_i : unsigned(UNARY_WIDTH - 1 downto 0);
  signal sLowRaw, sLowSuf : unsigned(SUFFIX_WIDTH - 1 downto 0);
  signal sTotal, sRawT, sGolT : natural range 0 to 1023;
  signal sInit : std_logic := '1';
  signal oW, oWB : std_logic_vector(LIMIT - 1 downto 0);
  signal oV, oVB : std_logic;
  signal oLen, oLenB : unsigned(log2ceil(LIMIT + 1) - 1 downto 0);
  function tail_zero (w : std_logic_vector; n : unsigned) return boolean is
  begin
    for i in w'range loop
      if i < w'length - to_integer(n) and w(i) /= '0' then return false; end if;
    end loop;
    return true;
  end function;""",
        free=["iRst_i", "iStall_i", "iRawV_i", "iGolV_i", "iRawLen_i", "iSufLen_i", "iRawVal_i", "iRawValB_i",
              "iSufVal_i", "iSufValB_i", "iUnary_i"],
        body="""  sInit   <= '0' when rising_edge(clk);
  sLowRaw <= not shift_left(not to_unsigned(0, SUFFIX_WIDTH), to_integer(iRawLen_i));
  sLowSuf <= not shift_left(not to_unsigned(0, SUFFIX_WIDTH), to_integer(iSufLen_i));
  sRawT   <= to_integer(iRawLen_i) when iRawV_i = '1' else 0;
  sGolT   <= to_integer(iUnary_i) + 1 + to_integer(iSufLen_i) when iGolV_i = '1' else 0;
  sTotal  <= sRawT + sGolT;
  u_a : entity work.a11_2_bit_packer
    generic map (LIMIT => LIMIT, OUT_WIDTH => LIMIT, UNARY_WIDTH => UNARY_WIDTH, SUFFIX_WIDTH => SUFFIX_WIDTH,
                 SUFFIXLEN_WIDTH => SUFFIXLEN_WIDTH)
    port map (iClk => clk, iRst => iRst_i, iStall => iStall_i, iRawValid => iRawV_i, iRawLen => iRawLen_i,
              iRawVal => iRawVal_i, iGolombValid => iGolV_i, iUnaryZeros => iUnary_i, iSuffixLen => iSufLen_i,
              iSuffixVal => iSufVal_i, oWord => oW, oWordValid => oV, oValidLen => oLen);
  u_b : entity work.a11_2_bit_packer
    generic map (LIMIT => LIMIT, OUT_WIDTH => LIMIT, UNARY_WIDTH => UNARY_WIDTH, SUFFIX_WIDTH => SUFFIX_WIDTH,
                 SUFFIXLEN_WIDTH => SUFFIXLEN_WIDTH)
    port map (iClk => clk, iRst => iRst_i, iStall => iStall_i, iRawValid => iRawV_i, iRawLen => iRawLen_i,
              iRawVal => iRawValB_i, iGolombValid => iGolV_i, iUnaryZeros => iUnary_i, iSuffixLen => iSufLen_i,
              iSuffixVal => iSufValB_i, oWord => oWB, oWordValid => oVB, oValidLen => oLenB);""",
        assume=["sInit = '1' -> iRst_i = '1'",
                "((iRawVal_i xor iRawValB_i) and sLowRaw) = 0 and ((iSufVal_i xor iSufValB_i) and sLowSuf) = 0",
                "iRawV_i = '1' -> (iRawLen_i >= 1 and iRawLen_i <= J_MAX_BITS + 1)",
                "iGolV_i = '1' -> iSufLen_i <= MAX_K",
                "sTotal <= LIMIT"],
        check=["sInit = '0' -> (oW = oWB and oV = oVB and oLen = oLenB)",
               "(sInit = '0' and oV = '1') -> (oLen >= 1 and oLen <= LIMIT and tail_zero(oW, oLen))"]),
    # CTX_INIT of context_ram satisfies both invariants
    "ctx_init": dict(
        srcs=[], decl="", free=[], body="", assume=[],
        check=[f"{A_INIT} < 2 ** (BITNESS - 1)", f"{A_INIT} < 2 ** A_STORED"]),
}


def harness(o):
    tgens, consts = gh.top_context()
    tg = ";\n    ".join(f"{g} : natural := {d}" for g, d in tgens.items())
    free = "\n".join(f"  attribute anyseq of {n} : signal is true;" for n in o["free"])
    psl = "\n".join(f"  -- psl assume always ({a});" for a in o["assume"])
    # AG_VACUITY=1: the asserts must then fail, else the assumptions are contradictory
    checks = [("sInit = '1'" if o.get("clocked") else "false")] if os.environ.get("AG_VACUITY") else o["check"]
    psl += "\n" + "\n".join(f"  -- psl assert always ({c});" for c in checks)
    return f"""library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.all;

entity ag is
  generic (
    {tg}
  );
  port (clk : in std_logic);
end entity ag;

architecture formal of ag is
  {chr(10).join('  ' + c for c in consts).strip()}
  attribute anyseq : boolean;
{o["decl"]}
{free}
begin
{o["body"]}
  -- psl default clock is rising_edge(clk);
{psl}
end architecture formal;
"""


def one(job):
    name, bits = job
    o = OBL[name]
    d = WORK / f"{name}_b{bits}"
    shutil.rmtree(d, ignore_errors=True); (d / "lib").mkdir(parents=True)
    rtl = ["rtl.vhd"] if o["srcs"] else []
    if rtl:
        (d / "rtl.vhd").write_text("".join(prep((S / f"{s}.vhd").read_text(), s + ".vhd") for s in o["srcs"]))
    (d / "ag.vhd").write_text(harness(o))
    r = run(["ghdl", "-a", "--std=08", "-frelaxed", "-fpsl", "--workdir=lib"] + [str(f) for f in BASE]
            + rtl + ["ag.vhd"], d)
    if r.returncode:
        return dict(name=name, bits=bits, res="ERROR", info=r.stderr[-400:])
    (d / "p.sby").write_text(f"""[options]
mode prove
depth {3 if o.get("clocked") else 1}
[engines]
smtbmc yices
[script]
plugin -i ghdl
ghdl --std=08 -frelaxed -fpsl --workdir=lib -gBITNESS={bits} ag
prep -top ag
memory_map; opt -full
[files]
lib
""")
    run(["sby", "-f", "p.sby"], d, timeout=1800)
    st = (d / "p" / "status").read_text().split()[0] if (d / "p" / "status").exists() else "ERROR"
    if st == "PASS":
        shutil.rmtree(d)
        return dict(name=name, bits=bits, res="PROVED")
    log = (d / "p" / "logfile.txt").read_text() if (d / "p" / "logfile.txt").exists() else ""
    return dict(name=name, bits=bits, res=st, info="\n".join(re.findall(r".*(?:Assert failed|ERROR|error).*", log))[-600:])


if __name__ == "__main__":
    names = sys.argv[1:] or list(OBL)
    jobs = [(n, b) for n in names for b in range(8, 17)]
    with mp.Pool(int(os.environ.get("AG_THREADS", 10))) as p, open(OUT, "a") as f:
        for r in p.imap_unordered(one, jobs):
            f.write(json.dumps(r) + "\n"); f.flush()
            print(r["name"], r["bits"], r["res"], r.get("info", "")[-300:], flush=True)
