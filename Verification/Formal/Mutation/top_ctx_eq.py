#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Gold vs mutant top, context-RAM loop real, everything else shared free (top 818: context write parity).

Instances outside the loop are cut at source level: their outputs come from one free vector that
both copies share. Sound up to the first difference in a valid Reg4 token: before it, every cut
instance sees the same inputs in both copies. The loop (context RAM, stage 3-5 error and update
logic, Q merging, line_buffer) stays real. Check: same Reg4 valid bit, same Reg4 token when valid.
Contexts: regular Q in {81, 162} and both RI contexts (equality-only use of the address).
Env: CE_BITS (8), CE_GEN, CE_MUT ("old|||new" on the mutant), CE_MODE (prove|bmc), CE_DEPTH, CE_TIMEOUT.
"""
import json, os, re, subprocess as sp, sys
from pathlib import Path

F = Path(__file__).resolve().parent
sys.path.insert(0, str(F.parent / "Common"))
from prep import prep
from flow import S, ENV, BASE, ORDER, run
WORK = Path(os.environ.get("CE_WORK", "/tmp/top_ctx_eq"))
BITS = os.environ.get("CE_BITS", "8")
GEN = os.environ.get("CE_GEN", "MAX_IMAGE_WIDTH=8 MAX_IMAGE_HEIGHT=4").split()
MODE = os.environ.get("CE_MODE", "prove")
MUT = os.environ.get("CE_MUT", "  sCtxRdPar <= sReg2Par when sReg2V = '1' else|||"
                               "  sCtxRdPar <= sReg2Par when sReg2V = '0' else")
KEEP = {"u_line_buffer", "u_a4_1", "u_a4_2", "u_a20_1", "u_ctx_ram", "u_a6_bounds", "u_a6_errors",
        "u_a6a7_d", "u_a9_d", "u_a6a7_c", "u_a9_c", "u_a6a7_p", "u_a9_p", "u_a6a7_m", "u_a9_m",
        "u_a23_delta", "u_a12_a13", "u_a23"}
CUT_W, OBS_W = 2048, 512
RESTRICT = "sS1Q2 = 0 and sS1Q3 = 0 and (sS1Q1 = 1 or sS1Q1 = 2)"


# Restricted contexts on a 5-entry RAM in both copies (slot 4 takes any other address)
CTX_MAP = """
  function fmap (a : std_logic_vector) return std_logic_vector is
  begin
    case to_integer(unsigned(a)) is
      when 81 => return "000";
      when 162 => return "001";
      when 365 => return "010";
      when 366 => return "011";
      when others => return "100";
    end case;
  end function;
"""


def ctx_src():
    t = prep((S / "context_ram.vhd").read_text(), "context_ram.vhd")
    for a, b in (("DEPTH_G         => RAM_DEPTH", "DEPTH_G         => 5"),
                 ("Wr_Addr         => sWrPendAddr", "Wr_Addr         => fmap(sWrPendAddr)"),
                 ("Rd_Addr         => iRdAddr", "Rd_Addr         => fmap(iRdAddr)")):
        assert t.count(a) == 1, a
        t = t.replace(a, b)
    return re.sub(r"(architecture \w+ of context_ram is\n)", lambda m: m[1] + CTX_MAP, t, count=1)


def entity_outs():
    outs = {}
    for f in S.glob("*.vhd"):
        t = re.sub(r"--.*", "", f.read_text())
        for m in re.finditer(r"\bentity\s+(\w+)\s+is(.*?)\bend\s+entity", t, re.S | re.I):
            outs[m[1].lower()] = {n.strip().lower() for d in re.findall(r"([\w\s,]+?)\s*:\s*out\b", m[2])
                                  for n in d.split(",")}
    return outs


def cut_top(t):
    outs, acts = entity_outs(), []
    inst = re.compile(r"^  (u_\w+)\s*:\s*entity\s+work\.(\w+)\s*\(\w+\).*?\);[ \t]*$", re.S | re.M)
    def one(m):
        if m[1] in KEEP:
            return m[0]
        pm = m[0][re.search(r"port\s+map\s*\(", m[0]).end():]
        for fm, act in re.findall(r"(\w+)\s*=>\s*(\w+)", re.sub(r"--.*", "", pm)):
            if fm.lower() in outs[m[2].lower()] and act.lower() != "open":
                acts.append(act)
        return f"  -- {m[1]} cut"
    t = inst.sub(one, t)
    types = {}
    decl = re.findall(r"^\s*signal\s+([\w\s,]+?)\s*:\s*([^;:]+?)\s*(?::=[^;]*)?;", t, re.M)
    decl += re.findall(r"^\s*(\w+)\s*:\s*out\s+([^;]+?)\s*;?\s*$", t, re.M)
    for names, ty in decl:
        for n in names.split(","):
            types[n.strip()] = ty.strip()
    lines, off = [], "0"
    for a in acts:
        ty = types.get(a, "std_logic")  # top output ports (oValid, oLast)
        if ty == "std_logic":
            lines.append(f"  {a} <= iCut({off});")
            off = f"{off} + 1"
        else:
            conv = ty.split("(")[0].strip()
            conv = "" if conv == "std_logic_vector" else conv
            lines.append(f"  {a} <= {conv}(iCut({off} + {a}'length - 1 downto {off}));")
            off = f"{off} + {a}'length"
    lines.append(f"  assert {off} <= CUT_W report \"CUT_W too small\" severity failure;")
    return t, lines


def top_src(mutant):
    t = prep((S / "openjls_top.vhd").read_text(), "openjls_top.vhd")
    t = re.sub(r"^[ \t]*--[ \t]*psl[ \t]+assert\b.*$", "", t, flags=re.M)
    if mutant:
        a, b = MUT.split("|||")
        assert t.count(a) == 1, a
        t = t.replace(a, b).replace("openjls_top", "openjls_top_mut")
    t, cut = cut_top(t)
    ent = "openjls_top_mut" if mutant else "openjls_top"
    t = re.sub(r"(entity " + ent + r" is\s*generic\s*\()", r"\1\n    CUT_W : natural := %d;" % CUT_W, t, count=1)
    t = re.sub(r"(\n\s*iReady\s*:\s*in\s+std_logic)", r"\1;\n    iCut : in std_logic_vector(CUT_W - 1 downto 0);"
               r"\n    oObsV : out std_logic;\n    oObs : out std_logic_vector(%d downto 0)" % (OBS_W - 1), t, count=1)
    fields = re.search(r"type t_pipeline_token is record(.*?)end record", t, re.S)[1]
    # Context fields count only for the modes that read them: raw tokens carry RAM junk there
    ctx_ri, ctx_reg = {"Aq", "Nq", "Nn"}, {"Bq", "Cq"}
    obs, ri, reg = [], [], []
    for n, ty in re.findall(r"^\s*(\w+)\s*:\s*([^;]+);", fields, re.M):
        e = ("std_logic_vector(to_unsigned(t_token_mode'pos(sReg4.mode), 3))" if n == "mode" else
             f"sReg4.{n}" if ty.strip() == "std_logic" else f"std_logic_vector(sReg4.{n})")
        (ri if n in ctx_ri else reg if n in ctx_reg else obs).append(e)
    obs += ["sReg4Eoi", "sReg4Par", "std_logic_vector(sReg4RiAqDelta)"]
    ri += ["sReg4Rescale", "std_logic_vector(sReg4NqNew)"]
    pack = lambda xs: f"std_logic_vector(resize(unsigned(std_logic_vector'({' & '.join(xs)})), {OBS_W // 2}))"
    obs_stmt = (f"  oObs({OBS_W - 1} downto {OBS_W // 2}) <= {pack(obs)};\n"
                f"  oObs({OBS_W // 2 - 1} downto 0) <= {pack(ri + reg)} when sReg4.mode = token_regular else\n"
                f"    {pack(ri)} when sReg4.mode = token_run_interruption else (others => '0');")
    body = cut + [
        "  oObsV <= sReg4V;",
        obs_stmt,
        f"  -- psl assume always ({RESTRICT});",
    ]
    return t.replace("end architecture rtl;", "\n".join(body) + "\n\nend architecture rtl;")


HARNESS = """library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity eq is
  port (
    clk : in std_logic
  );
end entity eq;

architecture formal of eq is
  attribute anyseq : boolean;
  signal iRst, iValid, iReady : std_logic;
  signal iPixel : std_logic_vector({B} - 1 downto 0);
  signal iW, iH : std_logic_vector(15 downto 0);
  signal iCut : std_logic_vector({CW} - 1 downto 0);
  attribute anyseq of iRst, iValid, iReady, iPixel, iW, iH, iCut : signal is true;
  signal sInit : std_logic := '1';
  signal gV, mV : std_logic;
  signal gO, mO : std_logic_vector({OW} - 1 downto 0);
begin
  sInit <= '0' when rising_edge(clk);
  u_g : entity work.openjls_top
    generic map ({G})
    port map (iClk => clk, iRst => iRst, iValid => iValid, iPixel => iPixel, oReady => open,
              iImageWidth => iW, iImageHeight => iH, oData => open, oValid => open, oKeep => open,
              oLast => open, iReady => iReady, iCut => iCut, oObsV => gV, oObs => gO);
  u_m : entity work.openjls_top_mut
    generic map ({G})
    port map (iClk => clk, iRst => iRst, iValid => iValid, iPixel => iPixel, oReady => open,
              iImageWidth => iW, iImageHeight => iH, oData => open, oValid => open, oKeep => open,
              oLast => open, iReady => iReady, iCut => iCut, oObsV => mV, oObs => mO);
  -- psl default clock is rising_edge(clk);
  -- psl assume always (sInit = '1' -> iRst = '1');
  -- psl assert always (sInit = '0' -> (gV = mV and (gV = '1' -> gO = mO)));
end architecture formal;
"""


def check():
    d = WORK / f"b{BITS}_{MODE}"
    d.mkdir(parents=True, exist_ok=True)
    files = [str(f) for f in BASE]
    for n in ORDER:
        if n == "openjls_top":
            for mut in (False, True):
                p = d / f"openjls_top{'_mut' if mut else ''}.vhd"
                p.write_text(top_src(mut))
                files.append(p.name)
        else:
            p = d / f"{n}.vhd"
            p.write_text(ctx_src() if n == "context_ram" else prep((S / f"{n}.vhd").read_text(), f"{n}.vhd"))
            files.append(p.name)
    gens = ", ".join([f"BITNESS => {BITS}"] + [g.replace("=", " => ") for g in GEN])
    (d / "eq.vhd").write_text(HARNESS.format(B=BITS, CW=CUT_W, OW=OBS_W, G=gens))
    files.append("eq.vhd")
    (d / "lib").mkdir(exist_ok=True)
    r = sp.run(["ghdl", "-a", "--std=08", "-frelaxed", "-fpsl", "--workdir=lib"] + files, cwd=d, env=ENV,
               capture_output=True, text=True)
    if r.returncode:
        return dict(res="ERROR", info=r.stderr[-1500:])
    eng = "abc pdr" if MODE == "prove" else "smtbmc yices"
    (d / "p.sby").write_text(f"""[options]
mode {MODE}
depth {os.environ.get("CE_DEPTH", "30")}
[engines]
{eng}
[script]
plugin -i ghdl
ghdl --std=08 -frelaxed -fpsl --workdir=lib eq
prep -top eq
flatten; memory_map; opt -fast; setundef -undriven -zero; setundef -zero -init
[files]
lib
""")
    try:
        run(["sby", "-f", "p.sby"], d, timeout=int(os.environ.get("CE_TIMEOUT", 1800)))
    except sp.TimeoutExpired:
        return dict(res="TIMEOUT", mode=MODE)
    st = (d / "p" / "status").read_text().split()[0] if (d / "p" / "status").exists() else "ERROR"
    return dict(res=st, mode=MODE, bits=BITS, mut=MUT.split("|||")[1].strip(), gen=" ".join(GEN))


if __name__ == "__main__":
    print(json.dumps(check()), flush=True)
