#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Context read gets the newest value: context_ram plus the top's forward and straggler-drop logic, on the real top.

All instances except u_ctx_ram and u_line_buffer are cut (any datapath values). One tracked context address
(anyconst); the RAM keeps only that word, other reads return any value. A token's read must equal the last
update of the same context by an earlier token of the same image (CTX_INIT if none): from the RAM word, or
from the stage-4/5 bypass when the token just ahead has the same context.
Three jobs per BITNESS: fwd (bypass flags, PDR), word (RAM word, k-induction with helper facts), eoi (the
assumption that the EOI token always reaches stage 2).
python3 ctx_fwd.py [BITNESS ...]; env CF_LIVE=1 (known-bad, must fail: word misses the load-edge update, fwd demands
a bypass across an image boundary, eoi asserts false), CF_TIMEOUT (s, 1800), CF_WORK, CF_THREADS (20).
"""
import json, os, re, sys, multiprocessing as mp
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Common"))
from prep import prep
from flow import S, BASE, ORDER, RESULTS, run

WORK = Path(os.environ.get("CF_WORK", "/tmp/feq_ctx_fwd"))
TIMEOUT = int(os.environ.get("CF_TIMEOUT", 1800))
GEN = "MAX_IMAGE_WIDTH=8 MAX_IMAGE_HEIGHT=4".split()

# RBW RAM, read latency 1, that stores only address Trk
TRK_RAM = """library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity trk_ram is
  generic (DEPTH_G : positive; WIDTH_G : positive; ISASYNC_G : boolean; RDLATENCY_G : positive;
           RAMSTYLE_G : string; RAMBEHAVIOR_G : string; USEBYTEENABLE_G : boolean; INITSTRING_G : string;
           INITFORMAT_G : string);
  port (Trk : in std_logic_vector; Clk : in std_logic; Wr_Addr : in std_logic_vector; Wr_Ena : in std_logic;
        Wr_Be : in std_logic_vector(0 downto 0) := "1"; Wr_Data : in std_logic_vector(WIDTH_G - 1 downto 0);
        Rd_Clk : in std_logic := '0'; Rd_Addr : in std_logic_vector; Rd_Ena : in std_logic;
        Rd_Data : out std_logic_vector(WIDTH_G - 1 downto 0); dMem : out std_logic_vector(WIDTH_G - 1 downto 0));
end entity;

architecture formal of trk_ram is
  signal sMem, sAny : std_logic_vector(WIDTH_G - 1 downto 0);
  attribute anyseq : boolean;
  attribute anyseq of sAny : signal is true;
begin
  dMem <= sMem;
  process (Clk) begin
    if rising_edge(Clk) then
      if Rd_Ena = '1' then
        Rd_Data <= sMem when Rd_Addr = Trk else sAny;
      end if;
      if Wr_Ena = '1' and Wr_Addr = Trk then
        sMem <= Wr_Data;
      end if;
    end if;
  end process;
end architecture;
"""

DECL = """
  signal sFInit : std_logic := '1';
  attribute anyconst : boolean;
  signal fTrk : unsigned(8 downto 0);
  attribute anyconst of fTrk : signal is true;
  constant F_INIT : std_logic_vector(TOTAL_WIDTH - 1 downto 0) :=
    std_logic_vector(to_unsigned(math_max(2, (RANGE_P + 32) / 64), A_STORED)) &
    std_logic_vector(to_signed(0, B_STORED)) & std_logic_vector(to_signed(0, C_STORED)) &
    std_logic_vector(to_unsigned(1, N_STORED));
  -- Image tag (EOIs seen at stage 1), read flag and address per stage; fSh*: last update of the tracked context
  signal fCnt, fT2, fT3, fT4, fShT : unsigned(2 downto 0);
  signal fRd2, fRd3, fRd4, fShSet, fRdEn, fWr : std_logic;
  signal fA2, fA3, fA4 : unsigned(8 downto 0);
  signal fShV, fExp : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
"""

BODY = """
  sFInit <= '0' when rising_edge(iClk);
  fRdEn <= sReg1V and sCE1 and (bool2bit(sS2TokenMode = token_regular) or bool2bit(sS2TokenMode = token_run_interruption));
  -- Every reading token updates its context at stage 4; the RTL may drop it, the reference does not
  fWr <= sCE4 and fRd4 and bool2bit(fA4 = fTrk);

  p_ref : process (iClk) is
  begin
    if rising_edge(iClk) then
      if iRst = '1' then
        fCnt <= (others => '0'); fRd2 <= '0'; fRd3 <= '0'; fRd4 <= '0'; fShSet <= '0';
      else
        if sCE2 = '1' then
          fRd2 <= fRdEn; fA2 <= sS2Q; fT2 <= fCnt;
          if sReg1V = '1' and sReg1Eoi = '1' then
            fCnt <= fCnt + 1;
          end if;
        end if;
        -- Word load: the update issued on this edge counts, later ones are the bypass's job
        if sCE3 = '1' then
          fRd3 <= fRd2; fA3 <= fA2; fT3 <= fT2;
          if fWr = '1' and fT4 = fT2 then
            fExp <= sCtxWrData;
          elsif fShSet = '1' and fShT = fT2 then
            fExp <= fShV;
          else
            fExp <= F_INIT;
          end if;
        end if;
        if sCE4 = '1' then
          fRd4 <= fRd3; fA4 <= fA3; fT4 <= fT3;
        end if;
        -- No reader is 4 images behind: retire the update before the tag wraps
        if fShSet = '1' and fCnt - fShT = 4 then
          fShSet <= '0';
        end if;
        if fWr = '1' then
          fShSet <= '1'; fShV <= sCtxWrData; fShT <= fT4;
        end if;
      end if;
    end if;
  end process p_ref;

  -- psl assume always (sFInit = '1' -> iRst = '1');
  -- psl assume always (fTrk < RAM_DEPTH);
  -- context_ram read contract (its own asserts, stripped here): merged Qi agree with the address
  -- psl assume always ((sReg1V = '1' and sReg1.mode = token_regular) ->
  --   (sS2MQ1 >= 0 and sS2MQ1 <= 4 and sS2MQ2 >= -4 and sS2MQ2 <= 4 and sS2MQ3 >= -4 and sS2MQ3 <= 4 and
  --    81 * to_integer(sS2MQ1) + 9 * to_integer(sS2MQ2) + to_integer(sS2MQ3) = to_integer(sS2Q)));
  -- psl assume always ((sReg1V = '1' and sS2TokenMode = token_run_interruption) ->
  --   to_integer(sS2Q) = 365 + to_integer(unsigned'('0' & sS2RItype)));
  -- Out of reset, the EOI token always reaches stage 2: proved by the eoi job
  -- psl assume always ((iRst = '0' and sReg1V = '1' and sReg1Eoi = '1') -> sS2TokenMode /= token_none);
@ASSERTS@
"""

ASSERTS = {
    "ctx_word": """  -- psl ctx_word : assert always ((sFInit = '0' and iRst = '0' and fRd3 = '1' and fA3 = fTrk and
  --   sFwdRegHit = '0' and sFwdRiHit = '0') -> sCtxRdData = fExp);""",
    "fwd_needed": """  -- psl fwd_needed : assert always ((sFInit = '0' and iRst = '0' and fRd3 = '1' and fRd4 = '1' and fA3 = fA4 and
  --   fT3 = fT4) -> (sFwdRegHit = '1' or sFwdRiHit = '1'));""",
    # A hit behind a run token is harmless: the flags only pick stage-4 context values, which it ignores
    "fwd_right": """  -- psl fwd_right : assert always ((sFInit = '0' and iRst = '0' and fRd3 = '1' and (sFwdRegHit = '1' or sFwdRiHit = '1')) ->
  --   (fRd4 = '1' and fA3 = fA4 and fT3 = fT4 and (sFwdRegHit = '1') = (fA3 < 365)));""",
}
PROPS_FWD = ("fwd_needed", "fwd_right")
# Reads of other contexts limited to one free address (TWO=1): smaller search, weaker check
TWO = """  signal fOther : unsigned(8 downto 0);
  attribute anyconst of fOther : signal is true;
"""
TWO_ASSUME = "  -- psl assume always (sReg1V = '1' -> (sS2Q = fTrk or sS2Q = fOther));\n"


# HELP=1: context_ram state on debug ports (scratch copy), for the helper facts in HELPERS
DBG = [("dFlag", "std_logic", "sUseInitValue(to_integer(unsigned(iTrk)))"),
       ("dClrPend", "std_logic", "sClrPend"), ("dClrAddr", "std_logic_vector(8 downto 0)", "sClrAddr"),
       ("dInitReg", "std_logic", "sUseInitReg"), ("dInitWord", "std_logic", "sUseInitWord"),
       ("dP1En", "std_logic", "sWrPendEn"), ("dP1Addr", "std_logic_vector(8 downto 0)", "sWrPendAddr"),
       ("dP1Data", "std_logic_vector(TOTAL_WIDTH - 1 downto 0)", "sWrPendData"),
       ("dP2En", "std_logic", "sWrPend2En"), ("dP2Addr", "std_logic_vector(8 downto 0)", "sWrPend2Addr"),
       ("dP2Data", "std_logic_vector(TOTAL_WIDTH - 1 downto 0)", "sWrPend2Data"),
       ("dRdData", "std_logic_vector(TOTAL_WIDTH - 1 downto 0)", "sBramRdData"),
       ("dMemTrk", "std_logic_vector(TOTAL_WIDTH - 1 downto 0)", "sMemTrk")]
HELP_DECL = """  signal hE2, hV2, hLV : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
  signal hR2, hR3, hR4, hCur, hAny, hDone : std_logic;
"""
# Proved like the main asserts, so they add no trust; they only make the induction step close
HELPERS = """  hE2 <= fShV when fShSet = '1' and fShT = fT2 else F_INIT;
  -- The word a stage-2 reader will load, without the update issued on the load edge
  hV2 <= F_INIT when dInitReg = '1' else
         dP1Data when dP1En = '1' and unsigned(dP1Addr) = fTrk else
         dP2Data when dP2En = '1' and unsigned(dP2Addr) = fTrk else
         dRdData;
  -- psl h_valid : assert always (sFInit = '0' -> ((fRd2 = '0' or sReg2V = '1') and (fRd3 = '0' or sReg3V = '1') and
  --   (fRd4 = '0' or sReg4V = '1')));
  -- psl h_mode : assert always ((sFInit = '0' and iRst = '0') -> (
  --   (fRd2 = '0' or sReg2.mode = token_regular or sReg2.mode = token_run_interruption) and
  --   (fRd3 = '0' or sReg3.mode = token_regular or sReg3.mode = token_run_interruption) and
  --   (fRd4 = '0' or sReg4.mode = token_regular or sReg4.mode = token_run_interruption)));
  -- psl h_mode2 : assert always ((sFInit = '0' and iRst = '0') -> (
  --   (sReg2V = '0' or not (sReg2.mode = token_regular or sReg2.mode = token_run_interruption) or fRd2 = '1') and
  --   (sReg3V = '0' or not (sReg3.mode = token_regular or sReg3.mode = token_run_interruption) or fRd3 = '1') and
  --   (sReg4V = '0' or not (sReg4.mode = token_regular or sReg4.mode = token_run_interruption) or fRd4 = '1')));
  -- Owner parity (used when stage 2 is empty): the youngest valid token past stage 2
  -- Every image leaves a valid token past stage 2, so neighbouring valid tokens are at most one image apart
  -- psl h_adj : assert always ((sFInit = '0' and iRst = '0') -> ((sReg2V = '0' or sReg3V = '0' or fT2 - fT3 <= 1) and
  --   (sReg3V = '0' or sReg4V = '0' or fT3 - fT4 <= 1)));
  -- psl h_owner : assert always ((sFInit = '0' and iRst = '0' and sReg2V = '0') ->
  --   ((sReg3V = '0' or sCtxOwnerPar = sReg3Par) and (sReg3V = '1' or sReg4V = '0' or sCtxOwnerPar = sReg4Par)));
  -- Tags and parities hold for every valid token, reader or not
  -- psl h_tag : assert always ((sFInit = '0' and iRst = '0') -> ((sReg2V = '0' or fCnt - fT2 <= 1) and (sReg3V = '0' or fCnt - fT3 <= 2) and
  --   (sReg4V = '0' or fCnt - fT4 <= 3) and (fShSet = '0' or fCnt - fShT <= 4)));
  -- psl h_par : assert always ((sFInit = '0' and iRst = '0') -> ((sReg1V = '0' or sReg1Par = fCnt(0)) and
  --   sGenPar = (fCnt(0) xor (sReg1V and sReg1Eoi)) and
  --   (sReg2V = '0' or sReg2Par = fT2(0)) and (sReg3V = '0' or sReg3Par = fT3(0)) and (sReg4V = '0' or sReg4Par = fT4(0))));
  -- psl h_addr : assert always ((sFInit = '0' and iRst = '0') -> ((fRd2 = '0' or (sReg2.Q = fA2 and unsigned(dClrAddr) = fA2)) and
  --   (fRd3 = '0' or sReg3.Q = fA3) and (fRd4 = '0' or sReg4.Q = fA4)));
  -- In-flight reader of the tracked context from the current image; hCur: the current image updated it
  hR2 <= fRd2 and bool2bit(fA2 = fTrk and fT2 = fCnt);
  hR3 <= fRd3 and bool2bit(fA3 = fTrk and fT3 = fCnt);
  hR4 <= fRd4 and bool2bit(fA4 = fTrk and fT4 = fCnt);
  hCur <= fShSet and bool2bit(fShT = fCnt);
  hAny <= hCur or hR2 or hR3 or hR4;
  hDone <= hCur or hR3 or hR4;
  hLV <= dP1Data when dP1En = '1' and unsigned(dP1Addr) = fTrk else dMemTrk;
  -- psl h_flag0 : assert always ((sFInit = '0' and iRst = '0' and dFlag = '0') -> hAny = '1');
  -- psl h_flag1 : assert always ((sFInit = '0' and iRst = '0') -> ((hDone = '0' or dFlag = '0') and
  --   (hR2 = '0' or dFlag = '0' or (dClrPend = '1' and unsigned(dClrAddr) = fTrk))));
  -- Tags never decrease down the pipe, and every in-flight reader is behind the last update (3-bit wrap)
  -- psl h_order : assert always ((sFInit = '0' and iRst = '0') -> (
  --   (sReg2V = '0' or sReg3V = '0' or fT2 - fT3 <= 3) and (sReg3V = '0' or sReg4V = '0' or fT3 - fT4 <= 3) and
  --   (sReg2V = '0' or sReg4V = '0' or fT2 - fT4 <= 3) and (fShSet = '0' or
  --   ((fRd2 = '0' or fT2 - fShT <= 3) and (fRd3 = '0' or fT3 - fShT <= 3) and (fRd4 = '0' or fT4 - fShT <= 3)))));
  -- A stage-2 reader of the tracked context saw the init flag exactly when it is the first one of its image
  -- psl h_first : assert always ((sFInit = '0' and iRst = '0' and fRd2 = '1' and fA2 = fTrk) ->
  --   ((dInitReg = '1') = not ((fRd3 = '1' and fA3 = fTrk and fT3 = fT2) or (fRd4 = '1' and fA4 = fTrk and fT4 = fT2) or
  --   (fShSet = '1' and fShT = fT2))));
  -- psl h_mem : assert always ((sFInit = '0' and iRst = '0' and hCur = '1' and hR3 = '0' and hR4 = '0') -> hLV = fShV);
@CTRL@
  -- Same context in stage 3 or 4: the stage-4 bypass or the load-edge update supplies the value
  -- psl h_r2 : assert always ((sFInit = '0' and iRst = '0' and fRd2 = '1' and fA2 = fTrk and
  --   not (fRd3 = '1' and fA3 = fTrk and fT3 = fT2) and not (fRd4 = '1' and fA4 = fTrk and fT4 = fT2)) -> hV2 = hE2);
"""


# Facts proved elsewhere become assumes: top_ctrl.PROPS (same top, all cut except line_buffer, a superset of
# this model's behaviors) and the fwd_* asserts (proved here by PDR without helpers, PROPS_FWD)
def ctrl():
    import top_ctrl
    out = [f"  -- psl assume always ((sFInit = '0') -> ({p}));" for p in top_ctrl.PROPS.values()]
    out += [re.sub(r"psl \w+ : assert", "psl assume", ASSERTS[k]) for k in PROPS_FWD]
    return "\n".join(out)


def debug(t):
    a = "    oRdUseAlt       : out   std_logic\n  );"
    assert t.count(a) == 1
    t = t.replace(a, "    oRdUseAlt       : out   std_logic;\n" + ";\n".join(f"    {n} : out {ty}" for n, ty, _ in DBG) + "\n  );")
    t = t.replace("  signal sWrPendEn ", "  signal sMemTrk : std_logic_vector(TOTAL_WIDTH - 1 downto 0);\n  signal sWrPendEn ", 1)
    t = t.replace("      Rd_Data         => sBramRdData\n", "      Rd_Data         => sBramRdData,\n      dMem            => sMemTrk\n", 1)
    assert "dMem            => sMemTrk" in t
    return t.replace("end architecture behavioral;", "".join(f"  {n} <= {e};\n" for n, _, e in DBG) + "end architecture behavioral;")


def sources(live, props=tuple(ASSERTS), two=False, help=False):
    out = {}
    for n in ORDER:
        t = prep((S / f"{n}.vhd").read_text(), f"{n}.vhd")
        if n == "context_ram":
            a = "    iClk            : in    std_logic;\n"
            assert t.count(a) == 1
            t = t.replace(a, a + "    iTrk            : in    std_logic_vector(log2ceil(RAM_DEPTH) - 1 downto 0);\n")
            a = "entity work.olo_base_ram_sdp(rtl)"
            assert t.count(a) == 1
            t = t.replace(a, "entity work.trk_ram(formal)").replace("      Clk             => iClk,",
                                                                      "      Trk             => iTrk,\n      Clk             => iClk,", 1)
            if help:
                t = debug(t)
        if n == "openjls_top":
            t = re.sub(r"^[ \t]*--[ \t]*psl[ \t]+assert\b.*$", "", t, flags=re.M)
            t = re.sub(r"(u_ctx_ram : entity work\.context_ram\(behavioral\).*?iClk        => iClk,)",
                       r"\1\n      iTrk        => std_logic_vector(fTrk),", t, count=1, flags=re.S)
            assert "iTrk" in t
            if help:
                t = t.replace("      oRdUseAlt   => sCtxRdUseAlt\n", "      oRdUseAlt   => sCtxRdUseAlt,\n"
                              + ",\n".join(f"      {n} => {n}" for n, _, _ in DBG) + "\n", 1)
                assert "dMemTrk => dMemTrk" in t
            body = BODY.replace("fWr = '1' and fT4 = fT2", "false") if live else BODY
            props_txt = "\n".join(ASSERTS[k] for k in props)
            if live:
                props_txt = props_txt.replace("fA3 = fA4 and\n  --   fT3 = fT4) ->", "fA3 = fA4) ->")
            body = body.replace("@ASSERTS@", (TWO_ASSUME if two else "") + props_txt
                                + ("\n" + HELPERS.replace("@CTRL@", ctrl()) if help else ""))
            sigs = "".join(f"  signal {n} : {ty};\n" for n, ty, _ in DBG) + HELP_DECL if help else ""
            t = t.replace("\nbegin\n", "\n" + DECL + sigs + (TWO if two else "") + "\nbegin\n", 1).replace("end architecture rtl;", body + "\nend architecture rtl;")
        out[n] = t
    return out


def one(job, props=tuple(ASSERTS), two=False, engine="abc pdr", depth=20, tag="", help=False):
    bits, live = job
    d = WORK / f"b{bits}{'_live' if live else ''}{tag}"
    (d / "lib").mkdir(parents=True, exist_ok=True)
    files = [str(f) for f in BASE]
    (d / "trk_ram.vhd").write_text(TRK_RAM)
    files.append("trk_ram.vhd")
    for n, t in sources(live, props, two, help).items():
        (d / f"{n}.vhd").write_text(t)
        files.append(f"{n}.vhd")
    r = run(["ghdl", "-a", "--std=08", "-frelaxed", "-fpsl", "--workdir=lib"] + files, d)
    if r.returncode:
        return dict(bits=bits, live=live, res="ERROR", info=r.stderr[-800:])
    (d / "p.sby").write_text(f"""[options]
mode prove
depth {depth}
[engines]
{engine}
[script]
plugin -i ghdl
ghdl --std=08 -frelaxed -fpsl --workdir=lib -gBITNESS={bits} {" ".join("-g" + g for g in GEN)} openjls_top
hierarchy -top openjls_top
cutpoint openjls_top/c:u_* openjls_top/u_line_buffer %d openjls_top/u_ctx_ram %d
prep -top openjls_top
flatten; memory_map; opt -fast; setundef -undriven -zero; setundef -zero -init
[files]
lib
""")
    try:
        p = run(["sby", "-f", "p.sby"], d, timeout=TIMEOUT)
        out = p.stdout
    except Exception:
        out = ""
    st = (d / "p" / "status").read_text().split()[0] if (d / "p" / "status").exists() else "TIMEOUT"
    res = {"PASS": "PROVED", "FAIL": "DISPROVED"}.get(st, st)
    return dict(bits=bits, live=live, res=res, failed=sorted(set(re.findall(r"Assert failed in \S+: (\S+)", out))))


def eoi(bits, live):
    """Obligation behind the EOI assume: the EOI token always leaves stage 1 as a token (top_ctrl model, A.14-A.16 kept)."""
    import top_ctrl
    # Pool workers are reused: restore top_ctrl's globals for later jobs
    old = top_ctrl.WORK, top_ctrl.VAC, top_ctrl.KEEP, top_ctrl.PROPS, top_ctrl.TOP_HOOK
    top_ctrl.WORK, top_ctrl.VAC = WORK / f"eoi_b{bits}", live
    top_ctrl.KEEP = ["u_line_buffer", "u_a14", "u_a15_16"]
    top_ctrl.PROPS = {"eoi_token": "(iRst = '0' and sReg1V = '1' and sReg1Eoi = '1') -> sS2TokenMode /= token_none"}
    # Facts proved by rtl_asserts.py (openjls_top check: eoi_eol and assert 494) make this a one-step check
    top_ctrl.TOP_HOOK = lambda t: re.sub(r"^[ \t]*--[ \t]*psl[ \t]+assert\b.*$", "", prep(t, "openjls_top.vhd"), flags=re.M).replace(
        "end architecture rtl;", "  -- psl assume always ((sReg1V = '1' and sReg1Eoi = '1') -> sReg1Eol = '1');\n"
        "  -- psl assume always (sRunCntReg <= MAX_IMAGE_WIDTH);\nend architecture rtl;")
    try:
        r = top_ctrl.check(str(bits))
    finally:
        top_ctrl.WORK, top_ctrl.VAC, top_ctrl.KEEP, top_ctrl.PROPS, top_ctrl.TOP_HOOK = old
    return dict(bits=bits, live=live, res={"PASS": "PROVED", "FAIL": "DISPROVED"}.get(r["res"], r["res"]), failed=r.get("failed", []))


# fwd: bypass flags, PDR. word: RAM word, k-induction with HELPERS. eoi: the EOI assume
def job(j):
    kind, bits, live = j
    if kind == "fwd":
        r = one((bits, live), props=PROPS_FWD, tag="_fwd")
    elif kind == "word":
        r = one((bits, live), props=("ctx_word",), help=True, engine="smtbmc yices", depth=8, tag="_word")
    else:
        r = eoi(bits, live)
    return dict(kind=kind, **r)


def jobs(bits=range(8, 17), live=False):
    return [(k, b, live) for k in ("fwd", "word", "eoi") for b in bits]


if __name__ == "__main__":
    js = jobs([int(b) for b in sys.argv[1:]] or range(8, 17), bool(os.environ.get("CF_LIVE")))
    with mp.get_context("fork").Pool(min(len(js), int(os.environ.get("CF_THREADS", 20)))) as p, \
            open(RESULTS / "ctx_fwd.jsonl", "a") as f:
        for r in p.imap_unordered(job, js):
            f.write(json.dumps(r) + "\n"); f.flush()
            print(json.dumps(r), flush=True)
