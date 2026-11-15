#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Prove the per-sample modules equal the T.87 reference (t87_ref_pkg.vhd) for every legal input.

Each check wires one module (or a chain the top uses as one step), leaves its inputs free inside
the legal T.87 range and asserts output = reference. Each input range names its source.
python3 t87_eq.py [check ...]; T87_LIVE=1 swaps in the reference with one wrong boundary (must fail).
"""
import json, os, re, shutil, sys, multiprocessing as mp
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Common"))
import gen_harness as gh
from prep import prep
from flow import BASE, S, RESULTS, run
from ag import a_ok

F = Path(__file__).resolve().parent
WORK = Path(os.environ.get("T87_WORK", "/tmp/feq_t87"))
REF = F / "t87_ref_pkg.vhd"

ERR_RED = "iE_i >= -(2 ** (BITNESS - 1)) and iE_i < 2 ** (BITNESS - 1)"  # A.9 / A.19 output range
CTX = ["iNq_i >= 1 and iNq_i <= RESET", a_ok("iAq_i", "iNq_i")]           # ag ctx_regular / ctx_ri


def u(n, w):
    return f"  signal {n} : unsigned({w} - 1 downto 0);"


def s(n, w):
    return f"  signal {n} : signed({w} - 1 downto 0);"


# Each check: srcs, decl, free, body, assume, check(bug) -> list of asserts; bits1 = BITNESS-independent
CHECKS = {
    "A.1 gradients": dict(
        srcs=["A1_gradient_comp"],
        decl="\n".join([u("iA_i, iB_i, iC_i, iD_i", "BITNESS"), s("oD1, oD2, oD3", "BITNESS + 1")]),
        free=["iA_i", "iB_i", "iC_i", "iD_i"],
        body="""  u : entity work.a1_gradient_comp generic map (BITNESS => BITNESS)
    port map (iA => iA_i, iB => iB_i, iC => iC_i, iD => iD_i, oD1 => oD1, oD2 => oD2, oD3 => oD3);""",
        assume=[],
        check=lambda b: ["i(oD1) = i(iD_i) - i(iB_i)", "i(oD2) = i(iB_i) - i(iC_i)",
                         f"i(oD3) = {'i(iA_i) - i(iC_i)' if b == 'true' else 'i(iC_i) - i(iA_i)'}"]),
    "A.3 mode selection": dict(
        srcs=["A3_mode_selection"],
        decl="\n".join([s("iD1_i, iD2_i, iD3_i", "BITNESS + 1"), "  signal oRun : std_logic;"]),
        free=["iD1_i", "iD2_i", "iD3_i"],
        body="""  u : entity work.a3_mode_selection generic map (BITNESS => BITNESS)
    port map (iD1 => iD1_i, iD2 => iD2_i, iD3 => iD3_i, oModeRun => oRun);""",
        # A.1 check: D is a difference of two samples
        assume=[f"iabs(i(iD{k}_i)) <= MAX_VAL" for k in (1, 2, 3)],
        check=lambda b: [f"(oRun = '1') = t87_run_mode(i(iD1_i), i(iD2_i), i(iD3_i), {b})"]),
    "A.4 gradient quantization": dict(
        srcs=["A4_quantization_gradients"],
        decl="\n".join([s("iD1_i, iD2_i, iD3_i", "BITNESS + 1"), s("oQ1, oQ2, oQ3", "4"),
                        "  constant T1 : integer := t87_threshold(1, MAX_VAL);",
                        "  constant T2 : integer := t87_threshold(2, MAX_VAL);",
                        "  constant T3 : integer := t87_threshold(3, MAX_VAL);"]),
        free=["iD1_i", "iD2_i", "iD3_i"],
        body="""  u : entity work.a4_quantization_gradients generic map (BITNESS => BITNESS, MAX_VAL => MAX_VAL)
    port map (iD1 => iD1_i, iD2 => iD2_i, iD3 => iD3_i, oQ1 => oQ1, oQ2 => oQ2, oQ3 => oQ3);""",
        assume=[f"iabs(i(iD{k}_i)) <= MAX_VAL" for k in (1, 2, 3)],
        check=lambda b: [f"i(oQ{k}) = t87_quantize(i(iD{k}_i), T1, T2, T3, {b})" for k in (1, 2, 3)]),
    "A.4.1 sign flip": dict(
        bits1=True,
        srcs=["A4_1_quant_gradient_merging"],
        decl="\n".join([s("iQ1_i, iQ2_i, iQ3_i, oQ1, oQ2, oQ3", "4"), "  signal oSign : std_logic;"]),
        free=["iQ1_i", "iQ2_i", "iQ3_i"],
        body="""  u : entity work.a4_1_quant_gradient_merging
    port map (iQ1 => iQ1_i, iQ2 => iQ2_i, iQ3 => iQ3_i, oQ1 => oQ1, oQ2 => oQ2, oQ3 => oQ3, oSign => oSign);""",
        # A.4 check
        assume=[f"iabs(i(iQ{k}_i)) <= 4" for k in (1, 2, 3)],
        check=lambda b: [f"sgn(oSign) = t87_sign(i(iQ1_i), i(iQ2_i), i(iQ3_i), {b})"]
        + [f"i(oQ{k}) = t87_sign(i(iQ1_i), i(iQ2_i), i(iQ3_i)) * i(iQ{k}_i)" for k in (1, 2, 3)]),
    "A.4.2 context mapping": dict(
        bits1=True,
        srcs=["A4_2_Q_mapping"],
        decl="\n".join([s("iP1_i, iP2_i, iP3_i, iQ1_i, iQ2_i, iQ3_i", "4"), u("oP, oQ", "9")]),
        free=["iP1_i", "iP2_i", "iP3_i", "iQ1_i", "iQ2_i", "iQ3_i"],
        body="""  u_p : entity work.a4_2_q_mapping port map (iQ1 => iP1_i, iQ2 => iP2_i, iQ3 => iP3_i, oQ => oP);
  u_q : entity work.a4_2_q_mapping port map (iQ1 => iQ1_i, iQ2 => iQ2_i, iQ3 => iQ3_i, oQ => oQ);""",
        # A.4.1 check: Q1..Q3 in [-4, 4], first non-zero element positive
        assume=[f"iabs(i(i{v}{k}_i)) <= 4" for v in "PQ" for k in (1, 2, 3)]
        + [f"i(i{v}1_i) >= 0 and (i(i{v}1_i) = 0 -> i(i{v}2_i) >= 0) and ((i(i{v}1_i) = 0 and i(i{v}2_i) = 0) -> i(i{v}3_i) >= 0)"
           for v in "PQ"],
        check=lambda b: [f"i(oP) <= {363 if b == 'true' else 364}",
                         "(iP1_i /= iQ1_i or iP2_i /= iQ2_i or iP3_i /= iQ3_i) -> oP /= oQ"]),
    "A.5 predictor": dict(
        srcs=["A5_edge_detecting_predictor"],
        decl="\n".join([u("iA_i, iB_i, iC_i, oPx", "BITNESS")]),
        free=["iA_i", "iB_i", "iC_i"],
        body="""  u : entity work.a5_edge_detecting_predictor generic map (BITNESS => BITNESS)
    port map (iA => iA_i, iB => iB_i, iC => iC_i, oPx => oPx);""",
        assume=[],
        check=lambda b: [f"i(oPx) = t87_predict(i(iA_i), i(iB_i), i(iC_i), {b})"]),
    "A.9 modulo reduction": dict(
        srcs=["A9_modulo_reduction"],
        decl="\n".join([s("iE_i, oE", "BITNESS + 1")]),
        free=["iE_i"],
        body="""  u : entity work.a9_modulo_reduction generic map (BITNESS => BITNESS, RANGE_P => RANGE_P)
    port map (iErrorVal => iE_i, oErrorVal => oE);""",
        # A.6 + A.7 check: |Ix - Px| <= MAXVAL
        assume=["iabs(i(iE_i)) <= MAX_VAL"],
        check=lambda b: [f"i(oE) = t87_modrange(i(iE_i), RANGE_P, {b})"]),
    "A.10 / A.20 Golomb k": dict(
        srcs=["A10_compute_k", "A20_2_compute_k"],
        decl="\n".join(["  signal iRi_i, iRiType_i : std_logic;", u("iAq_i", "A_WIDTH"), u("iNq_i", "N_WIDTH"),
                        u("oK", "K_WIDTH"), "  signal sTemp : integer;"]),
        free=["iRi_i", "iRiType_i", "iAq_i", "iNq_i"],
        body="""  u : entity work.a20_2_compute_k generic map (A_WIDTH => A_WIDTH, K_WIDTH => K_WIDTH, N_WIDTH => N_WIDTH)
    port map (iRunInterruption => iRi_i, iRItype => iRiType_i, iAq => iAq_i, iNq => iNq_i, oK => oK);
  -- A.20: TEMP = A[366] + (N[366] >> 1) for RItype 1, else A[Q]
  sTemp <= i(iAq_i) + i(iNq_i) / 2 when iRi_i = '1' and iRiType_i = '1' else i(iAq_i);""",
        assume=CTX,
        check=lambda b: [f"i(oK) = t87_k(i(iNq_i), sTemp, {b})", "oK <= MAX_K"]),
    "A.11 error mapping": dict(
        srcs=["A11_error_mapping"],
        decl="\n".join([u("iK_i", "K_WIDTH"), s("iBq_i", "B_WIDTH"), u("iNq_i", "N_WIDTH"), s("iE_i", "ERROR_WIDTH"),
                        u("oM", "MAPPED_ERROR_VAL_WIDTH")]),
        free=["iK_i", "iBq_i", "iNq_i", "iE_i"],
        body="""  u : entity work.a11_error_mapping
    generic map (N_WIDTH => N_WIDTH, B_WIDTH => B_WIDTH, K_WIDTH => K_WIDTH, ERROR_WIDTH => ERROR_WIDTH,
                 MAPPED_ERROR_VAL_WIDTH => MAPPED_ERROR_VAL_WIDTH)
    port map (iK => iK_i, iBq => iBq_i, iNq => iNq_i, iErrorVal => iE_i, oMappedErrorVal => oM);""",
        # A.9 check; ag ctx_regular
        assume=[ERR_RED, CTX[0], "iBq_i <= 0 and iBq_i > -signed(resize(iNq_i, B_WIDTH))"],
        check=lambda b: [f"i(oM) = t87_merrval(i(iK_i), i(iBq_i), i(iNq_i), i(iE_i), {b})", "oM < RANGE_P"]),
    "A.11.1 Golomb code": dict(
        srcs=["A11_1_golomb_encoder"],
        decl="\n".join([u("iK_i", "K_WIDTH"), u("iM_i", "MAPPED_ERROR_VAL_WIDTH"), "  signal iRi_i : std_logic;",
                        u("iRunIndex_i", "5"), u("oUnary", "UNARY_WIDTH"), u("oSufLen", "SUFFIXLEN_WIDTH"),
                        u("oSufVal", "SUFFIX_WIDTH"), "  signal sGlimit : integer;"]),
        free=["iK_i", "iM_i", "iRi_i", "iRunIndex_i"],
        body="""  u : entity work.a11_1_golomb_encoder
    generic map (K_WIDTH => K_WIDTH, QBPP => QBPP, LIMIT => LIMIT, UNARY_WIDTH => UNARY_WIDTH,
                 SUFFIX_WIDTH => SUFFIX_WIDTH, SUFFIXLEN_WIDTH => SUFFIXLEN_WIDTH,
                 MAPPED_ERROR_VAL_WIDTH => MAPPED_ERROR_VAL_WIDTH)
    port map (iK => iK_i, iMappedErrorVal => iM_i, iRiMode => iRi_i, iRunIndex => iRunIndex_i,
              oUnaryZeros => oUnary, oSuffixLen => oSufLen, oSuffixVal => oSufVal);
  -- A.22.1: glimit = LIMIT - J[RUNindex] - 1 for a run interruption sample
  sGlimit <= LIMIT - CO_J_TABLE(i(iRunIndex_i)) - 1 when iRi_i = '1' else LIMIT;""",
        # A.10 / A.20 check (k <= MAX_K); A.11 and A.21 / A.22 checks (MErrval <= RANGE)
        assume=["iK_i <= MAX_K", "iM_i <= RANGE_P"],
        check=lambda b: [f"i(oUnary) = t87_lg_zeros(i(iK_i), i(iM_i), sGlimit, QBPP, {b})",
                         f"i(oSufLen) = t87_lg_len(i(iK_i), i(iM_i), sGlimit, QBPP, {b})",
                         f"i(oSufVal) = t87_lg_val(i(iK_i), i(iM_i), sGlimit, QBPP, {b})"]),
    "A.12 / A.13 context update": dict(
        srcs=["A12_A13_update"],
        decl="\n".join([s("iE_i", "ERROR_WIDTH"), u("iAq_i, oAq", "A_WIDTH"), s("iBq_i, oBq", "B_WIDTH"),
                        s("iCq_i, oCq", "C_WIDTH"), u("iNq_i, sNqNew", "N_WIDTH"),
                        "  signal sRescale, oDec, oInc : std_logic;"]),
        free=["iE_i", "iAq_i", "iBq_i", "iCq_i", "iNq_i"],
        body="""  -- p_reg4 of openjls_top
  sRescale <= '1' when iNq_i = RESET else '0';
  sNqNew   <= to_unsigned(RESET / 2 + 1, N_WIDTH) when iNq_i = RESET else iNq_i + 1;
  u : entity work.a12_a13_update
    generic map (ERROR_WIDTH => ERROR_WIDTH, A_WIDTH => A_WIDTH, B_WIDTH => B_WIDTH, N_WIDTH => N_WIDTH,
                 C_WIDTH => C_WIDTH, MIN_C => MIN_C, MAX_C => MAX_C, RESET => RESET)
    port map (iErrorVal => iE_i, iAq => iAq_i, iBq => iBq_i, iCq => iCq_i, iNq => iNq_i, iNqNew => sNqNew,
              iRescale => sRescale, oAq => oAq, oBq => oBq, oCq => oCq, oDec => oDec, oInc => oInc);""",
        # A.9 check; ag ctx_regular
        assume=[ERR_RED] + CTX + ["iBq_i <= 0 and iBq_i > -signed(resize(iNq_i, B_WIDTH))",
                                  "iCq_i >= MIN_C and iCq_i <= MAX_C"],
        check=lambda b: ["i(sNqNew) = t87_n_new(i(iNq_i), RESET)",
                         "i(oAq) = t87_a_new(i(iAq_i), i(iE_i), i(iNq_i), RESET)",
                         f"i(oBq) = t87_b_new(i(iBq_i), i(iE_i), i(iNq_i), RESET, {b})",
                         "i(oCq) = t87_c_new(i(iBq_i), i(iCq_i), i(iE_i), i(iNq_i), RESET, MIN_C, MAX_C)"]),
    "A.17 to A.19 run interruption error": dict(
        srcs=["A17_run_interruption_index", "A18_run_interruption_prediction_error", "A19_run_interruption_error"],
        decl="\n".join([u("iRa_i, iRb_i, iIx_i", "BITNESS"), s("sE18, oE", "BITNESS + 1"),
                        "  signal oRiType, sRaGtRb, oSign : std_logic;"]),
        free=["iRa_i", "iRb_i", "iIx_i"],
        body="""  u_a17 : entity work.a17_run_interruption_index generic map (BITNESS => BITNESS)
    port map (iRa => iRa_i, iRb => iRb_i, oRItype => oRiType);
  u_a18 : entity work.a18_run_interruption_prediction_error generic map (BITNESS => BITNESS)
    port map (iRItype => oRiType, iRa => iRa_i, iRb => iRb_i, iIx => iIx_i, oErrval => sE18);
  -- p_reg2 of openjls_top: sReg2RiRaGtRb <= bool2bit(Ra > Rb)
  sRaGtRb <= '1' when iRa_i > iRb_i else '0';
  u_a19 : entity work.a19_run_interruption_error generic map (BITNESS => BITNESS, RANGE_P => RANGE_P)
    port map (iErrval => sE18, iRItype => oRiType, iRaGtRb => sRaGtRb, oErrval => oE, oSign => oSign);""",
        assume=[],
        check=lambda b: ["(oRiType = '1') = (t87_ritype(i(iRa_i), i(iRb_i)) = 1)",
                         f"sgn(oSign) = t87_ri_sign(i(iRa_i), i(iRb_i), {b})",
                         f"i(oE) = t87_ri_errval(i(iRa_i), i(iRb_i), i(iIx_i), RANGE_P, {b})"]),
    "A.20.1 run context index": dict(
        bits1=True,
        srcs=["A20_1_run_context_index"],
        decl="  signal iRiType_i : std_logic;\n" + u("oQ", "9"),
        free=["iRiType_i"],
        body="  u : entity work.a20_1_run_context_index port map (iRItype => iRiType_i, oQ => oQ);",
        assume=[],
        check=lambda b: [f"i(oQ) = {'364' if b == 'true' else '365'} + (1 - sgn(iRiType_i)) / 2"]),
    "A.21 / A.22 run interruption mapping": dict(
        srcs=["A21_compute_map", "A22_errval_mapping"],
        decl="\n".join([u("iK_i", "K_WIDTH"), s("iE_i", "ERROR_WIDTH"), u("iNn_i, iNq_i", "N_WIDTH"),
                        "  signal iRiType_i, oMap : std_logic;", u("oEm", "MAPPED_ERROR_VAL_WIDTH")]),
        free=["iK_i", "iE_i", "iNn_i", "iNq_i", "iRiType_i"],
        body="""  u_a21 : entity work.a21_compute_map generic map (K_WIDTH => K_WIDTH, N_WIDTH => N_WIDTH, ERROR_WIDTH => ERROR_WIDTH)
    port map (iK => iK_i, iErrval => iE_i, iNn => iNn_i, iNq => iNq_i, oMap => oMap);
  u_a22 : entity work.a22_errval_mapping generic map (ERROR_WIDTH => ERROR_WIDTH, MAPPED_ERRVAL_WIDTH => MAPPED_ERROR_VAL_WIDTH)
    port map (iErrval => iE_i, iRiType => iRiType_i, iMap => oMap, oEmErrVal => oEm);""",
        # A.17 to A.19 check (reduced Errval); ag ctx_ri (RItype 1 -> Errval /= 0, N range); A.23 check (Nn < N)
        assume=[ERR_RED, "iRiType_i = '1' -> iE_i /= 0", CTX[0], "iNn_i < iNq_i"],
        check=lambda b: [f"sgn(oMap) = 1 - 2 * t87_map(i(iK_i), i(iE_i), i(iNn_i), i(iNq_i), {b})",
                         "i(oEm) = t87_emerrval(i(iE_i), (1 - sgn(iRiType_i)) / 2, (1 - sgn(oMap)) / 2)",
                         "oEm <= RANGE_P"]),
    "A.23 run interruption update": dict(
        srcs=["A23_run_interruption_update"],
        decl="\n".join([s("iE_i", "ERROR_WIDTH"), "  signal iRiType_i, iMap_i : std_logic;",
                        u("sDelta", "ERROR_WIDTH - 1"), u("iAq_i, oAq", "A_WIDTH"), u("iNq_i, oNq", "N_WIDTH"),
                        u("iNn_i, oNn", "NN_WIDTH"), "  signal sEm : integer;"]),
        free=["iE_i", "iRiType_i", "iMap_i", "iAq_i", "iNq_i", "iNn_i"],
        body="""  u_delta : entity work.a23_aq_delta generic map (ERROR_WIDTH => ERROR_WIDTH)
    port map (iErrVal => iE_i, iRiType => iRiType_i, oDelta => sDelta);
  u : entity work.a23_run_interruption_update
    generic map (A_WIDTH => A_WIDTH, N_WIDTH => N_WIDTH, NN_WIDTH => NN_WIDTH, ERROR_WIDTH => ERROR_WIDTH, RESET => RESET)
    port map (iErrVal => iE_i, iAqDelta => sDelta, iAq => iAq_i, iNq => iNq_i, iNn => iNn_i,
              oAq => oAq, oNq => oNq, oNn => oNn);
  sEm <= t87_emerrval(i(iE_i), (1 - sgn(iRiType_i)) / 2, (1 - sgn(iMap_i)) / 2);""",
        # A.17 to A.19 check; ag ctx_ri; A.21 (map = 1 needs Errval /= 0); Nn < N is proved below
        assume=[ERR_RED, "iRiType_i = '1' -> iE_i /= 0", "iE_i = 0 -> iMap_i = '0'"] + CTX
        + ["resize(iNn_i, N_WIDTH) < iNq_i"],
        check=lambda b: [f"i(oAq) = t87_ri_a_new(i(iAq_i), i(iNq_i), sEm, (1 - sgn(iRiType_i)) / 2, RESET, {b})",
                         "i(oNq) = t87_n_new(i(iNq_i), RESET)",
                         "i(oNn) = t87_ri_nn_new(i(iNn_i), i(iNq_i), i(iE_i), RESET)",
                         "resize(oNn, N_WIDTH) < oNq"]),
}

# A.6 + A.7 per chain of openjls_top: CQ_OFFSET is the speculative C[Q] update (+1, -1) or none
for off in (0, 1, -1):
    CHECKS[f"A.6 / A.7 prediction error, C{off:+d}" if off else "A.6 / A.7 prediction error"] = dict(
        srcs=["A6_A7_prediction_error"],
        decl="\n".join([u("iIx_i, iPx_i", "BITNESS"), "  signal iSign_i : std_logic;", s("iCq_i", "CO_CQ_WIDTH"),
                        s("sLo, sHi", "CO_CQ_WIDTH + 1"), s("sAtLo, sAtHi, oE", "BITNESS + 1")]),
        free=["iIx_i", "iPx_i", "iSign_i", "iCq_i"],
        body=f"""  u_bounds : entity work.a6_clip_bounds generic map (BITNESS => BITNESS, MAX_VAL => MAX_VAL)
    port map (iPx => iPx_i, iSign => iSign_i, oLo => sLo, oHi => sHi);
  u_errors : entity work.a6_clip_errors generic map (BITNESS => BITNESS, MAX_VAL => MAX_VAL)
    port map (iIx => iIx_i, iSign => iSign_i, oAtLo => sAtLo, oAtHi => sAtHi);
  u : entity work.a6_a7_prediction_error generic map (BITNESS => BITNESS, MAX_VAL => MAX_VAL, CQ_OFFSET => {off})
    port map (iIx => iIx_i, iPx => iPx_i, iSign => iSign_i, iLo => sLo, iHi => sHi,
              iAtLo => sAtLo, iAtHi => sAtHi, iCq => iCq_i, oErrorVal => oE);""",
        # A.13 keeps the updated C[Q] in [MIN_C, MAX_C]
        assume=[f"i(iCq_i) + ({off}) >= MIN_C and i(iCq_i) + ({off}) <= MAX_C"],
        check=lambda b, off=off: [
            f"i(oE) = t87_errval(i(iIx_i), i(iPx_i), sgn(iSign_i), i(iCq_i) + ({off}), MAX_VAL, {b})"])


def harness(o, live):
    tgens, consts = gh.top_context()
    tg = ";\n    ".join(f"{g} : natural := {d}" for g, d in tgens.items())
    free = "\n".join(f"  attribute anyseq of {n} : signal is true;" for n in o["free"])
    psl = "\n".join(f"  -- psl assume always ({a});" for a in o["assume"])
    psl += "\n" + "\n".join(f"  -- psl assert always ({c});" for c in o["check"]("true" if live else "false"))
    return f"""library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.all;
  use work.t87_ref_pkg.all;

entity t87 is
  generic (
    {tg}
  );
  port (clk : in std_logic);
end entity t87;

architecture formal of t87 is
  {chr(10).join('  ' + c for c in consts).strip()}
  attribute anyseq : boolean;
  function i (v : unsigned) return integer is begin return to_integer(v); end function;
  function i (v : signed) return integer is begin return to_integer(v); end function;
  -- RTL sign bit to T.87 SIGN ('1' = -1)
  function iabs (v : integer) return integer is begin if v < 0 then return -v; end if; return v; end function;
  function sgn (v : std_logic) return integer is begin if v = '1' then return -1; end if; return 1; end function;
{o["decl"]}
{free}
begin
{o["body"]}
  -- psl default clock is rising_edge(clk);
{psl}
end architecture formal;
"""


def tag(name):
    return re.sub(r"\W+", "_", name.replace("+", "p").replace("-", "m")).strip("_")


def one(job):
    name, bits, live = job
    o = CHECKS[name]
    d = WORK / f"{tag(name)}_b{bits}{'_live' if live else ''}"
    shutil.rmtree(d, ignore_errors=True); (d / "lib").mkdir(parents=True)
    (d / "rtl.vhd").write_text("".join(prep((S / f"{s}.vhd").read_text(), s + ".vhd") for s in o["srcs"]))
    (d / "t87.vhd").write_text(harness(o, live))
    r = run(["ghdl", "-a", "--std=08", "-frelaxed", "-fpsl", "--workdir=lib"] + [str(f) for f in BASE]
            + ["rtl.vhd", str(REF), "t87.vhd"], d)
    if r.returncode:
        return dict(name=name, bits=bits, live=live, res="ERROR", info=r.stderr[-600:])
    (d / "p.sby").write_text(f"""[options]
mode prove
depth 1
[engines]
smtbmc yices
[script]
plugin -i ghdl
ghdl --std=08 -frelaxed -fpsl --workdir=lib -gBITNESS={bits} t87
prep -top t87
memory_map; opt -full
[files]
lib
""")
    run(["sby", "-f", "p.sby"], d, timeout=1800)
    st = (d / "p" / "status").read_text().split()[0] if (d / "p" / "status").exists() else "ERROR"
    res = {"PASS": "PROVED", "FAIL": "DISPROVED"}.get(st, st)
    if res == "PROVED":
        shutil.rmtree(d)
        return dict(name=name, bits=bits, live=live, res=res)
    log = (d / "p" / "logfile.txt").read_text() if (d / "p" / "logfile.txt").exists() else ""
    return dict(name=name, bits=bits, live=live, res=res,
                info="\n".join(re.findall(r".*(?:Assert failed|ERROR|error).*", log))[-600:])


def jobs(names=None, live=False):
    names = names or list(CHECKS)
    if live:
        return [(n, 8, True) for n in names]
    return [(n, b, False) for n in names for b in ([8] if CHECKS[n].get("bits1") else range(8, 17))]


if __name__ == "__main__":
    js = jobs(sys.argv[1:], bool(os.environ.get("T87_LIVE")))
    with mp.Pool(int(os.environ.get("T87_THREADS", 20))) as p, open(RESULTS / "t87_eq.jsonl", "a") as f:
        for r in p.imap_unordered(one, js):
            f.write(json.dumps(r) + "\n"); f.flush()
            print(r["name"], r["bits"], "live" if r["live"] else "", r["res"], r.get("info", "")[-400:], flush=True)
