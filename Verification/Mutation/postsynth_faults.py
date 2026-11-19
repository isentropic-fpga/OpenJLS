#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""Faults injected into a copy of the post-synth golden flow; that flow must fail on each one except "none".

  postsynth_faults.py [fault ...]   default: every fault in FAULTS
Wraps the 8-bit funcsim netlist (output-handshake faults) or flips one LUT INIT bit (lutN).
Env: PF_WORK (/tmp/openjls_postsynth_faults), PF_TIMEOUT (1800 s), PF_IMAGES (noise8-smooth-230).
"""
import os, re, shutil, subprocess, sys, time, multiprocessing as mp
from pathlib import Path
R = Path(__file__).resolve().parents[2]; PS = R / "Verification/Post synth"; GM = R / "Verification/Golden model"
NET = PS / "Output/openjls_top_8bit_funcsim.vhd"
TIMEOUT = int(os.environ.get("PF_TIMEOUT", 1800))
W_ROOT = Path(os.environ.get("PF_WORK", "/tmp/openjls_postsynth_faults"))
IMAGES = os.environ.get("PF_IMAGES", "noise8-smooth-230").split(",")

W = """
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity openjls_top is port (
  iClk, iRst, iValid : in std_logic; iPixel : in std_logic_vector(7 downto 0); oReady : out std_logic;
  iImageWidth, iImageHeight : in std_logic_vector(15 downto 0);
  oData : out std_logic_vector(63 downto 0); oValid : out std_logic; oKeep : out std_logic_vector(7 downto 0);
  oLast : out std_logic; iReady : in std_logic);
end entity;
architecture STRUCTURE of openjls_top is
  signal cD : std_logic_vector(63 downto 0); signal cK : std_logic_vector(7 downto 0);
  signal cV, cL, cR : std_logic; signal seen, tail : std_logic := '0'; signal acc : natural := 0;
begin
  c : entity work.openjls_top_core port map (iClk=>iClk, iRst=>iRst, iValid=>iValid, iPixel=>iPixel, oReady=>cR,
    iImageWidth=>iImageWidth, iImageHeight=>iImageHeight, oData=>cD, oValid=>cV, oKeep=>cK, oLast=>cL, iReady=>iReady);
  process (iClk) begin if rising_edge(iClk) then
    if iRst = '1' then seen <= '0'; tail <= '0'; acc <= 0;
    else
      if cV = '1' then seen <= '1'; end if;
      tail <= cV and cL;
      if iValid = '1' and cR = '1' then acc <= acc + 1; end if;
    end if; end if; end process;
  %s
end architecture;
"""
PASS = "oReady <= cR; oData <= cD; oKeep <= cK; "
FAULTS = {
 "none":    PASS + "oValid <= cV; oLast <= cL;",
 "nolast":  PASS + "oValid <= cV; oLast <= '0';",
 "early":   PASS + "oValid <= cV; oLast <= cV and not seen;",
 "double":  PASS + "oValid <= cV or tail; oLast <= cL or tail;",
 "extra":   "oReady <= cR; oData <= cD; oKeep <= x\"80\" when tail = '1' else cK; oValid <= cV or tail; oLast <= cL;",
 "hang":    "oData <= cD; oKeep <= cK; oValid <= cV; oLast <= cL; oReady <= '0' when acc > 20 else cR;",
 "silent":  "oReady <= cR; oData <= cD; oKeep <= cK; oLast <= cL; oValid <= cV and not seen;",
 "xvalid":  PASS + "oLast <= cL; oValid <= 'X' when seen = '1' and cV = '0' else cV;",
 "xlast":   PASS + "oValid <= cV; oLast <= 'X' when cV = '1' and cL = '0' else cL;",
 "xdata":   "oReady <= cR; oValid <= cV; oLast <= cL; oKeep <= cK; oData <= (63 => 'X', others => '0') when cV = '1' and seen = '0' else cD;",
}
# lutN: flip one truth-table bit of the Nth LUT4 INIT in the netlist
for n in (100, 900, 2500, 4000, 6000, 8000): FAULTS[f"lut{n}"] = PASS + "oValid <= cV; oLast <= cL;"

def run(f):
    t = W_ROOT / f; shutil.rmtree(t, ignore_errors=True)
    p = t / "Verification/Post synth"; (p / "Output").mkdir(parents=True)
    for a in ("Sources", "ThirdParty"): (t / a).symlink_to(R / a)
    for s in ("build_run_golden.sh", "tb_postsynth_golden.vhd", "synth_funcsim.tcl", "netlist_id.sh"): shutil.copy(PS / s, p / s)
    g = t / "Verification/Golden model"; (g / "Images").mkdir(parents=True); (g / "imageprep").symlink_to(GM / "imageprep")
    # the CharLS gate reads the T.87 reference vectors
    (t / "Verification/T87 conformance").symlink_to(R / "Verification/T87 conformance")
    for i in IMAGES: (g / "Images" / f"{i}.pgm").symlink_to(GM / "Images" / f"{i}.pgm")
    src = NET.read_text(errors="replace")
    if f.startswith("lut"):
        hits = list(re.finditer(r'INIT => X"([0-9A-F]{4})"', src)); h = hits[int(f[3:]) % len(hits)]
        new = "%04X" % (int(h[1], 16) ^ 0x10)
        src = src[:h.start(1)] + new + src[h.end(1):]
    i = src.rfind("entity openjls_top is")
    head, top = src[:i], src[i:]
    top = re.sub(r"\bopenjls_top\b", "openjls_top_core", top)
    (p / "Output/openjls_top_8bit_funcsim.vhd").write_text(head + top + (W % FAULTS[f]))
    env = dict(os.environ, NUMBER_OF_THREADS="1", PER_MEM="3G")
    t0 = time.time()
    try:
        r = subprocess.run(["bash", str(p / "build_run_golden.sh"), "--sim"], cwd=p, env=env, capture_output=True, text=True, errors="replace", timeout=TIMEOUT)
        rc, out = r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired as e:
        rc, out = "TIMEOUT", ""
    st = p / "Output/report_status_golden.env"
    status = re.search(r"STATUS=(\w+)", st.read_text())[1] if st.exists() else "-"
    tsv = p / "Output/ps_golden_image_results.tsv"
    rows = [l.split("\t")[-1] for l in tsv.read_text().splitlines()[1:]] if tsv.exists() else []
    ps = len(list((g / "Output/OpenJLS").glob("*_PS.jls"))) if (g / "Output/OpenJLS").exists() else 0
    return f, rc, status, rows, ps, int(time.time() - t0), out[-300:] if rc not in (0, 1, "TIMEOUT") else ""

if __name__ == "__main__":
    W_ROOT.mkdir(parents=True, exist_ok=True)
    fs = sys.argv[1:] or list(FAULTS)
    with mp.Pool(min(20, len(fs))) as p:
        for x in p.imap_unordered(run, fs): print(*x, flush=True)
