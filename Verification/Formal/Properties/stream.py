#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Stream properties of the clocked modules, generics and constants as openjls_top sets them.

python3 stream.py [check ...]; STREAM_LIVE=1 runs the known-bad variant (must fail).
"""
import json, os, re, shutil, sys, multiprocessing as mp
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Common"))
import gen_harness as gh
from prep import prep
from flow import BASE, S, RESULTS, run

WORK = Path(os.environ.get("STREAM_WORK", "/tmp/feq_stream"))


# T.87 F.1 marker avoidance: after each 0xFF byte the next byte starts with a stuffed '0'. One tracked
# input bit (image tI, bit tN) must leave at the same de-stuffed position with the same value; the pad
# after the image's last bit is zeros, at most one pad byte (only the stuffed byte after a final 0xFF).
def byte_stuffer(iw, **run):
    return dict(
        srcs=["byte_stuffer"],
        decl="""  constant IW  : natural := """ + iw + """;
  constant LW  : natural := log2ceil(IW + 1);
  constant CAP : natural := 511;
  constant LAT : natural := 4;
  attribute anyconst : boolean;
  signal iRst_i, iWordValid_i, iFlush_i, iReady_i : std_logic;
  signal iWord_i : std_logic_vector(IW - 1 downto 0);
  signal iLen_i  : unsigned(LW - 1 downto 0);
  signal tI : natural range 0 to 3;
  signal tN : natural range 0 to CAP;
  attribute anyconst of tI, tN : signal is true;
  signal sGap : natural range 0 to 3;
  signal sAfReg, sStallDelay, sStallLogic, sStall, af, fd, v : std_logic;
  signal w  : std_logic_vector(31 downto 0);
  signal nb : unsigned(2 downto 0);
  signal sFlight : natural range 0 to 7;
  signal sTake   : natural range 0 to 1;
  signal sFdD    : std_logic_vector(LAT - 1 downto 0);
  -- input side: images and bits accepted, the tracked bit and its image's length
  signal inImg : natural range 0 to 4;
  signal inBit : natural range 0 to CAP;
  signal tV, tVal, tEnd : std_logic;
  signal tLen  : natural range 0 to CAP;
  -- output side: images done, de-stuffed bits, last byte state
  signal outImg, nOutImg : natural range 0 to 4;
  signal outBit, nOutBit, dBefore, nDBefore : natural range 0 to CAP;
  signal oPrevFF, nPrevFF, lbStuffed, nLbStuffed, bad : std_logic;
  function sat (a, b : natural) return natural is
  begin
    if a + b > CAP then return CAP; end if;
    return a + b;
  end function;
  function tail_zero (w : std_logic_vector; n : unsigned) return boolean is
  begin
    for i in w'range loop
      if i < w'length - to_integer(n) and w(i) /= '0' then return false; end if;
    end loop;
    return true;
  end function;""",
        free=["iRst_i", "iWordValid_i", "iFlush_i", "iReady_i", "iWord_i", "iLen_i"],
        body="""  sStall <= sAfReg;
  sTake  <= 1 when iFlush_i = '1' and iWordValid_i = '1' and sStallLogic = '0' else 0;
  p_env : process (clk) is
  begin
    if rising_edge(clk) then
      if iRst_i = '1' then
        sGap <= 3; sAfReg <= '0'; sStallDelay <= '0'; sStallLogic <= '0'; sFlight <= 0; sFdD <= (others => '0');
      else
        if sStallLogic = '0' then
          if iFlush_i = '1' then sGap <= 0; elsif sGap < 3 then sGap <= sGap + 1; end if;
        end if;
        sAfReg <= af; sStallDelay <= sStall; sStallLogic <= sStallDelay and sStall;
        sFdD <= sFdD(LAT - 2 downto 0) & fd;
        if sFdD(LAT - 1) = '1' then sFlight <= sFlight + sTake - 1; else sFlight <= sFlight + sTake; end if;
      end if;
    end if;
  end process p_env;

  u : entity work.byte_stuffer(behavioral)
    generic map (IN_WIDTH => IW, OUT_BYTES_PER_CYCLE => 4, BURST_DEPTH => 8)
    port map (iClk => clk, iRst => iRst_i, iStall => sStallLogic, iWord => iWord_i, iWordValid => iWordValid_i,
              iWordValidLen => iLen_i, iFlush => iFlush_i, oWord => w, oWordValid => v, oValidBytes => nb,
              iReady => iReady_i, oAlmostFull => af, oFlushDone => fd);

  p_in : process (clk) is
    variable vLen : natural;
  begin
    if rising_edge(clk) then
      vLen := to_integer(iLen_i);
      if iRst_i = '1' then
        inImg <= 0; inBit <= 0; tV <= '0'; tVal <= '0'; tEnd <= '0'; tLen <= 0;
      elsif sStallLogic = '0' and iWordValid_i = '1' then
        if inImg = tI then
          if tN >= inBit and tN < inBit + vLen then
            tV <= '1'; tVal <= iWord_i(IW - 1 - (tN - inBit));
          end if;
          if iFlush_i = '1' then
            tEnd <= '1'; tLen <= sat(inBit, vLen);
          end if;
        end if;
        if iFlush_i = '1' then
          inBit <= 0; inImg <= inImg + 1 when inImg < 4 else 4;
        else
          inBit <= sat(inBit, vLen);
        end if;
      end if;
    end if;
  end process p_in;

  -- De-stuffer: walks the beat's bytes from the top
  p_out : process (all) is
    variable vB    : std_logic_vector(7 downto 0);
    variable vD, vDb : natural range 0 to CAP;
    variable vPrev, vLbS, vBad : std_logic;
    variable vTop  : natural;
  begin
    vD := outBit; vPrev := oPrevFF; vDb := dBefore; vLbS := lbStuffed; vBad := '0';
    if v = '1' then
      for k in 0 to 3 loop
        if k < to_integer(nb) then
          vB := w(31 - 8 * k downto 24 - 8 * k);
          vDb := vD; vLbS := vPrev;
          vTop := 7;
          if vPrev = '1' and LIVE /= 1 then
            vTop := 6;
            if vB(7) /= '0' then vBad := '1'; end if;
          end if;
          for b in 7 downto 0 loop
            if b <= vTop then
              if outImg = tI and vD = tN then
                if tEnd = '1' and tN >= tLen then
                  if vB(b) /= '0' then vBad := '1'; end if;
                elsif tV = '0' or vB(b) /= tVal then
                  vBad := '1';
                end if;
              end if;
              vD := sat(vD, 1);
            end if;
          end loop;
          vPrev := '1' when vB = x"FF" else '0';
        end if;
      end loop;
    end if;
    nOutImg <= outImg; nOutBit <= vD; nPrevFF <= vPrev; nDBefore <= vDb; nLbStuffed <= vLbS;
    if fd = '1' then
      if outImg = tI and (tEnd = '0' or (tLen < CAP - 16 and
          (vPrev = '1' or vD < tLen or (vDb >= tLen and vLbS = '0')))) then
        vBad := '1';
      end if;
      -- LIVE = 2: reach check, a second image must finish within the depth
      if LIVE = 2 and outImg = 1 then
        vBad := '1';
      end if;
      nOutImg <= outImg + 1 when outImg < 4 else 4;
      nOutBit <= 0; nPrevFF <= '0'; nDBefore <= 0; nLbStuffed <= '0';
    end if;
    bad <= vBad;
  end process p_out;

  p_out_reg : process (clk) is
  begin
    if rising_edge(clk) then
      if iRst_i = '1' then
        outImg <= 0; outBit <= 0; oPrevFF <= '0'; dBefore <= 0; lbStuffed <= '0';
      else
        outImg <= nOutImg; outBit <= nOutBit; oPrevFF <= nPrevFF; dBefore <= nDBefore; lbStuffed <= nLbStuffed;
      end if;
    end if;
  end process p_out_reg;""",
        # u_byte_stuffer env: A11_2 zeros past the length, iFlush with the last word, images >= 4 pixels;
        # cushion env: at most CO_MAX_IMAGES_IN_FLIGHT (3) images in flight (top in-flight cap)
        assume=["sInit = '1' -> iRst_i = '1'",
                "iLen_i <= IW and (iWordValid_i = '0' or (iLen_i > 0 and tail_zero(iWord_i, iLen_i)))",
                "iFlush_i = '1' -> iWordValid_i = '1'",
                "(iFlush_i = '1' and sStallLogic = '0') -> sGap = 3",
                "sFlight + sTake <= 3",
                "tN < CAP - 2 * IW"],
        check=["(sInit = '0' and iRst_i = '0') -> bad = '0'"],
        script="flatten; memory_map; opt -fast; setundef -undriven -zero; setundef -zero -init",
        bits=[8], **run)


CHECKS = {
    # T.87 A.11.1 / A.16 bit order: raw bits (A.15 '1' or A.16 break prefix), then LG code = unary zeros,
    # a '1', the suffix; each field MSB first. Built bit by bit here, not by the RTL's shift-and-or.
    "bit_packer bit order": dict(
        srcs=["A11_2_bit_packer"],
        decl="""  signal iRst_i, iStall_i, iRawV_i, iGolV_i : std_logic;
  signal iRawLen_i, iSufLen_i : unsigned(SUFFIXLEN_WIDTH - 1 downto 0);
  signal iRawVal_i, iSufVal_i : unsigned(SUFFIX_WIDTH - 1 downto 0);
  signal iUnary_i : unsigned(UNARY_WIDTH - 1 downto 0);
  signal sTotal, sRawT, sGolT : natural range 0 to 1023;
  signal oW, eW : std_logic_vector(LIMIT - 1 downto 0);
  signal oV, eV : std_logic;
  signal oLen : unsigned(log2ceil(LIMIT + 1) - 1 downto 0);
  signal eLen : natural range 0 to 1023;
  function expect (rv, gv : std_logic; rl, sl : unsigned; rval, sval : unsigned; uz : unsigned) return std_logic_vector is
    variable w     : std_logic_vector(LIMIT - 1 downto 0) := (others => '0');
    variable vRl   : natural := 0;
    variable j     : integer;
  begin
    if rv = '1' then
      vRl := to_integer(rl);
    end if;
    for i in 0 to LIMIT - 1 loop
      j := i - vRl;
      if i < vRl then
        w(LIMIT - 1 - i) := rval(vRl - 1 - i);
      elsif gv = '1' and j < to_integer(uz) then
        w(LIMIT - 1 - i) := '0';
      elsif gv = '1' and j = to_integer(uz) + LIVE then
        w(LIMIT - 1 - i) := '1';
      elsif gv = '1' and j > to_integer(uz) and j <= to_integer(uz) + to_integer(sl) then
        w(LIMIT - 1 - i) := sval(to_integer(sl) - (j - to_integer(uz)));
      end if;
    end loop;
    return w;
  end function;""",
        free=["iRst_i", "iStall_i", "iRawV_i", "iGolV_i", "iRawLen_i", "iSufLen_i", "iRawVal_i", "iSufVal_i",
              "iUnary_i"],
        body="""  sRawT  <= to_integer(iRawLen_i) when iRawV_i = '1' else 0;
  sGolT  <= to_integer(iUnary_i) + 1 + to_integer(iSufLen_i) when iGolV_i = '1' else 0;
  sTotal <= sRawT + sGolT;
  u : entity work.a11_2_bit_packer
    generic map (LIMIT => LIMIT, OUT_WIDTH => LIMIT, UNARY_WIDTH => UNARY_WIDTH, SUFFIX_WIDTH => SUFFIX_WIDTH,
                 SUFFIXLEN_WIDTH => SUFFIXLEN_WIDTH)
    port map (iClk => clk, iRst => iRst_i, iStall => iStall_i, iRawValid => iRawV_i, iRawLen => iRawLen_i,
              iRawVal => iRawVal_i, iGolombValid => iGolV_i, iUnaryZeros => iUnary_i, iSuffixLen => iSufLen_i,
              iSuffixVal => iSufVal_i, oWord => oW, oWordValid => oV, oValidLen => oLen);
  p_exp : process (clk) is
  begin
    if rising_edge(clk) then
      if iRst_i = '1' then
        eV <= '0'; eLen <= 0; eW <= (others => '0');
      elsif iStall_i = '0' then
        eV   <= iRawV_i or iGolV_i;
        eLen <= sTotal;
        eW   <= expect(iRawV_i, iGolV_i, iRawLen_i, iSufLen_i, iRawVal_i, iSufVal_i, iUnary_i);
      end if;
    end if;
  end process;""",
        # ag bit_packer: raw lengths 1 or J + 1 (A15 p_comb); suffix <= MAX_K; golomb_regular/ri: total <= LIMIT
        assume=["sInit = '1' -> iRst_i = '1'",
                "iRawV_i = '1' -> (iRawLen_i >= 1 and iRawLen_i <= J_MAX_BITS + 1)",
                "iGolV_i = '1' -> iSufLen_i <= MAX_K",
                "sTotal <= LIMIT"],
        check=["sInit = '0' -> (oV = eV and (eV = '1' -> (to_integer(oLen) = eLen and oW = eW)))"],
        depth=3),

    "byte_stuffer byte order": byte_stuffer("LIMIT", mode="bmc", depth=14, engine="smtbmc boolector"),
    "byte_stuffer byte order pdr": byte_stuffer("LIMIT", engine="abc pdr"),
}


def harness(o, live):
    tgens, consts = gh.top_context()
    tg = ";\n    ".join(f"{g} : natural := {d}" for g, d in tgens.items())
    free = "\n".join(f"  attribute anyseq of {n} : signal is true;" for n in o["free"])
    psl = "\n".join(f"  -- psl assume always ({a});" for a in o["assume"])
    psl += "\n" + "\n".join(f"  -- psl assert always ({c});" for c in o["check"])
    return f"""library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.all;

entity stream is
  generic (
    {tg};
    LIVE : natural := 0
  );
  port (clk : in std_logic);
end entity stream;

architecture formal of stream is
  {chr(10).join('  ' + c for c in consts).strip()}
  attribute anyseq : boolean;
  signal sInit : std_logic := '1';
{o["decl"]}
{free}
begin
  sInit <= '0' when rising_edge(clk);
{o["body"]}
  -- psl default clock is rising_edge(clk);
{psl}
end architecture formal;
"""


def tag(name):
    return re.sub(r"\W+", "_", name).strip("_")


def one(job):
    name, bits, live = job
    o = CHECKS[name]
    d = WORK / f"{tag(name)}_b{bits}{'_live' + str(int(live)) if live else ''}"
    shutil.rmtree(d, ignore_errors=True); (d / "lib").mkdir(parents=True)
    (d / "rtl.vhd").write_text("".join(prep((S / f"{s}.vhd").read_text(), s + ".vhd") for s in o["srcs"]))
    (d / "stream.vhd").write_text(harness(o, live))
    r = run(["ghdl", "-a", "--std=08", "-frelaxed", "-fpsl", "--workdir=lib"] + [str(f) for f in BASE]
            + ["rtl.vhd", "stream.vhd"], d)
    if r.returncode:
        return dict(name=name, bits=bits, live=live, res="ERROR", info=r.stderr[-600:])
    (d / "p.sby").write_text(f"""[options]
mode {o.get("mode", "prove")}
depth {o.get("depth", 2)}
[engines]
{o.get("engine", "smtbmc yices")}
[script]
plugin -i ghdl
ghdl --std=08 -frelaxed -fpsl --workdir=lib -gBITNESS={bits} -gLIVE={int(live)} stream
prep -top stream
{o.get("script", "memory_map; opt -full")}
[files]
lib
""")
    run(["sby", "-f", "p.sby"], d, timeout=int(os.environ.get("STREAM_TIMEOUT", 1800)))
    st = (d / "p" / "status").read_text().split()[0] if (d / "p" / "status").exists() else "TIMEOUT"
    res = {"PASS": "PROVED", "FAIL": "DISPROVED"}.get(st, st)
    if res == "PROVED":
        shutil.rmtree(d)
        return dict(name=name, bits=bits, live=live, res=res)
    log = (d / "p" / "logfile.txt").read_text() if (d / "p" / "logfile.txt").exists() else ""
    return dict(name=name, bits=bits, live=live, res=res,
                info="\n".join(re.findall(r".*(?:Assert failed|ERROR|error).*", log))[-600:])


def jobs(names=None, live=False):
    names = names or list(CHECKS)
    return [(n, 8, True) for n in names] if live else [(n, b, False) for n in names
                                                        for b in CHECKS[n].get("bits", range(8, 17))]


if __name__ == "__main__":
    js = jobs(sys.argv[1:], bool(os.environ.get("STREAM_LIVE")))
    with mp.Pool(int(os.environ.get("STREAM_THREADS", 20))) as p, open(RESULTS / "stream.jsonl", "a") as f:
        for r in p.imap_unordered(one, js):
            f.write(json.dumps(r) + "\n"); f.flush()
            print(r["name"], r["bits"], "live" if r["live"] else "", r["res"], r.get("info", "")[-400:], flush=True)
