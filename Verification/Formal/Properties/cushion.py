#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""byte_stuffer FIFO no-overflow under the openjls_top stall loop, per STALL_CUSHION_ENTRIES and BURST.

  cushion.py                 CUSH_LIST="5 4", BURST_LIST="6 8 16"; results in Results/cushion.jsonl
A scratch copy of byte_stuffer gets PSL asserts: no main FIFO write without In_Ready, no BV queue write when full.
CUSH_FREE=1: main FIFO only. FIFO read and image spacing are free (over-approximation, so PASS is sound); the
output side and all data drop out of the cone. Flush assumes only the RTL precondition (no flush while one is pending).
"""
import json, os, re, shutil, subprocess as sp, sys, multiprocessing as mp
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Common"))
from prep import prep
from flow import S, BASE, RESULTS, run

F = Path(__file__).resolve().parent
WORK = Path(os.environ.get("CUSH_WORK", "/tmp/feq_cush"))
OUT = RESULTS / "cushion.jsonl"
TIMEOUT = int(os.environ.get("CUSH_TIMEOUT", 10800))
LAT = int(os.environ.get("CUSH_LAT", 4))
FREE = os.environ.get("CUSH_FREE") == "1"

WRAP = """library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.all;

entity cush is
  generic (BURST : natural := 8; LIMIT : natural := 32; LAT : natural := 4);
  port (clk : in std_logic);
end entity cush;

architecture formal of cush is
  constant LW : natural := log2ceil(LIMIT + 1);
  attribute anyseq : boolean;
  signal iRst_i, iWordValid_i, iFlush_i, iReady_i : std_logic;
  signal iWord_i : std_logic_vector(LIMIT - 1 downto 0);
  signal iLen_i : unsigned(LW - 1 downto 0);
  attribute anyseq of iRst_i, iWordValid_i, iFlush_i, iReady_i, iWord_i, iLen_i : signal is true;
  signal sInit : std_logic := '1';
  signal sAfReg, sStallDelay, sStallLogic, sStall, af, fd, v : std_logic;
  signal w : std_logic_vector(31 downto 0);
  signal nb : unsigned(2 downto 0);
  signal sFlight : natural range 0 to 7 := 0;
  signal sTake : natural range 0 to 1;
  -- A slot frees when the oFlushDone beat is taken, but the next image's flush needs >= LAT cycles of pipeline after its start
  signal sFdD : std_logic_vector(LAT - 1 downto 0) := (others => '0');

  function tail_zero (w : std_logic_vector; n : unsigned) return boolean is
  begin
    for i in w'range loop
      if i < w'length - to_integer(n) and w(i) /= '0' then return false; end if;
    end loop;
    return true;
  end function;
begin
  sStall <= sAfReg;
  sTake <= 1 when iFlush_i = '1' and iWordValid_i = '1' and sStallLogic = '0' else 0;
  p_env : process (clk) is
  begin
    if rising_edge(clk) then
      sInit <= '0';
      if iRst_i = '1' then
        sAfReg <= '0'; sStallDelay <= '0'; sStallLogic <= '0'; sFlight <= 0; sFdD <= (others => '0');
      else
        sAfReg <= af; sStallDelay <= sStall; sStallLogic <= sStallDelay and sStall;
        sFdD <= sFdD(LAT - 2 downto 0) & (fd and iReady_i);
        if sFdD(LAT - 1) = '1' then sFlight <= sFlight + sTake - 1; else sFlight <= sFlight + sTake; end if;
      end if;
    end if;
  end process p_env;

  u_bs : entity work.byte_stuffer(behavioral)
    generic map (IN_WIDTH => LIMIT, OUT_BYTES_PER_CYCLE => 4, BURST_DEPTH => BURST)
    port map (iClk => clk, iRst => iRst_i, iStall => sStallLogic, iWord => iWord_i, iWordValid => iWordValid_i,
              iWordValidLen => iLen_i, iFlush => iFlush_i, oWord => w, oWordValid => v, oValidBytes => nb,
              iReady => iReady_i, oAlmostFull => af, oFlushDone => fd);

  -- psl default clock is rising_edge(clk);
  -- psl assume always (sInit = '1' -> iRst_i = '1');
  -- psl assume always (iLen_i <= LIMIT and (iWordValid_i = '0' or (iLen_i > 0 and tail_zero(iWord_i, iLen_i))));
  -- psl assume always (iFlush_i = '1' -> iWordValid_i = '1');
  -- psl assume always (sFlight + sTake <= 3);  -- @FLIGHT@
end architecture formal;
"""


def job(arg):
    cush, burst, limit = arg
    d = WORK / f"c{cush}_b{burst}_l{limit}"
    shutil.rmtree(d, ignore_errors=True); (d / "lib").mkdir(parents=True)
    s = (S / "byte_stuffer.vhd").read_text()
    s, n = re.subn(r"(STALL_CUSHION_ENTRIES\s*:\s*natural\s*:=\s*)\d+", rf"\g<1>{cush}", s); assert n == 1
    s = s.replace("  signal sBvQueueInValid", "  signal sBvInReadyF : std_logic;\n  signal sBvQueueInValid", 1)
    s, n = re.subn(r"(byte_valid_fifo_inst.*?In_Ready\s*=>\s*)open", r"\g<1>sBvInReadyF", s, count=1, flags=re.S)
    assert n == 1
    s = s.replace("  -- psl default clock is rising_edge(iClk);",
                  "  -- psl default clock is rising_edge(iClk);\n"
                  "  -- psl assert always (iRst = '0' -> not (sFifoInValid = '1' and sFifoInReady = '0'));\n"
                  "  -- psl assert always (iRst = '0' -> not (sBvQueueInValid = '1' and sBvInReadyF = '0'));", 1)
    wrap = WRAP
    if FREE:
        s = s.replace("  signal sBvQueueInValid", "  attribute anyseq : boolean;\n  signal sFreeRd : std_logic;\n"
                      "  attribute anyseq of sFreeRd : signal is true;\n  signal sBvQueueInValid", 1)
        s, n = re.subn(r"(fifo_inst\s*:.*?Out_Ready\s*=>\s*)sFifoOutReady", r"\g<1>sFreeRd", s, count=1, flags=re.S)
        assert n == 1
        s = s.replace("  -- psl assert always (iRst = '0' -> not (sBvQueueInValid = '1' and sBvInReadyF = '0'));",
                      "  -- psl assume always ((sFlush = '1' and iStall = '0') -> sFlushPending = '0');", 1)
        wrap = wrap.replace("  -- psl assume always (sFlight + sTake <= 3);  -- @FLIGHT@\n", "")
    (d / "bs.vhd").write_text(prep(s, "byte_stuffer.vhd"))
    (d / "cush.vhd").write_text(wrap)
    r = run(["ghdl", "-a", "--std=08", "-frelaxed", "-fpsl", "--workdir=lib"] + [str(f) for f in BASE]
               + ["bs.vhd", "cush.vhd"], d)
    if r.returncode:
        return dict(cush=cush, burst=burst, limit=limit, lat=LAT, free=FREE, res="ERROR", info=r.stderr[-400:])
    (d / "p.sby").write_text(f"""[options]
mode prove
depth 40
[engines]
abc pdr
smtbmc yices
[script]
plugin -i ghdl
ghdl --std=08 -frelaxed -fpsl --workdir=lib -gBURST={burst} -gLIMIT={limit} -gLAT={LAT} cush
prep -top cush
flatten; memory_map; opt -fast; setundef -undriven -zero; setundef -zero -init
[files]
lib
""")
    try:
        run(["sby", "-f", "p.sby"], d, timeout=TIMEOUT)
    except sp.TimeoutExpired:
        return dict(cush=cush, burst=burst, limit=limit, lat=LAT, free=FREE, res="TIMEOUT")
    st = (d / "p" / "status").read_text().split()[0] if (d / "p" / "status").exists() else "ERROR"
    info = ""
    if st != "PASS":
        lg = (d / "p" / "logfile.txt").read_text() if (d / "p" / "logfile.txt").exists() else ""
        info = "; ".join(re.findall(r"(Assert failed.*|failed in step \d+|was asserted in frame \d+)", lg))[:300] or lg[-300:]
    return dict(cush=cush, burst=burst, limit=limit, lat=LAT, free=FREE, res={"PASS": "PROVED"}.get(st, st), info=info)


if __name__ == "__main__":
    jobs = [(int(c), int(b), int(os.environ.get("CUSH_LIMIT", 32)))
            for c in os.environ.get("CUSH_LIST", "5 4").split() for b in os.environ.get("BURST_LIST", "6 8 16").split()]
    with mp.Pool(int(os.environ.get("CUSH_THREADS", 6))) as p, open(OUT, "a") as f:
        for r in p.imap_unordered(job, jobs):
            print(r, flush=True); f.write(json.dumps(r) + "\n"); f.flush()
