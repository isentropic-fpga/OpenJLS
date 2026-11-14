#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""A.14-A.16 run coder vs a T.87 model (run_coder.vhd), with the top's stage-1 register, run counter and stall.

python3 run_coder.py [WIDTH ...]; env RC_MODE=prove|bmc (prove), RC_DEPTH (BMC depth, 40),
RC_LIVE=1 (model drops the A.16 EOLine '1' bit, must fail), RC_TIMEOUT (1800 s),
RC_HELP=1 (k-induction with the RTL-to-model state facts, for wide lines).
"""
import json, os, re, shutil, sys, multiprocessing as mp
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Common"))
from prep import prep
from flow import BASE, S, RESULTS, run

F = Path(__file__).resolve().parent
WORK = Path(os.environ.get("RC_WORK", "/tmp/feq_run_coder"))
MODE = os.environ.get("RC_MODE", "prove")
DEPTH = int(os.environ.get("RC_DEPTH", 40))
TIMEOUT = int(os.environ.get("RC_TIMEOUT", 1800))
HELP = os.environ.get("RC_HELP") == "1"
SRCS = ["A14_run_length_determination", "A15_A16_encode_run"]


# Scratch copy only: A.15/A.16 state on ports, for the HELP facts in run_coder.vhd
def debug_ports(t):
    if "entity a15_a16_encode_run" not in t:
        return t
    t = t.replace("    oInRunNext    : out   std_logic\n  );", "    oInRunNext    : out   std_logic;\n"
                  "    dIdx : out unsigned(4 downto 0);\n    dNB, dNBM1 : out unsigned(RUN_CNT_WIDTH downto 0);\n"
                  "    dInRun : out std_logic\n  );", 1)
    t = t.replace("end architecture behavioral;", "  dIdx <= sRunIndex; dNB <= sNextBound; dNBM1 <= sNextBoundM1; dInRun <= sInRun;\n"
                  "end architecture behavioral;", 1)
    assert t.count("dInRun") == 2
    return t


def one(job):
    width, live = job
    d = WORK / f"w{width}{'_live' if live else ''}_{MODE}{'_help' if HELP else ''}"
    shutil.rmtree(d, ignore_errors=True); (d / "lib").mkdir(parents=True)
    (d / "rtl.vhd").write_text("".join(debug_ports(prep((S / f"{s}.vhd").read_text(), s + ".vhd")) for s in SRCS))
    r = run(["ghdl", "-a", "--std=08", "-frelaxed", "-fpsl", "--workdir=lib"] + [str(f) for f in BASE]
            + ["rtl.vhd", str(F / "run_coder.vhd")], d)
    if r.returncode:
        return dict(width=width, live=live, res="ERROR", info=r.stderr[-600:])
    eng = "abc pdr" if MODE == "prove" and not HELP else "smtbmc yices"
    (d / "p.sby").write_text(f"""[options]
mode {MODE}
depth {DEPTH}
[engines]
{eng}
[script]
plugin -i ghdl
ghdl --std=08 -frelaxed -fpsl --workdir=lib -gWIDTH={width} -gLIVE={int(live)} -gHELP={int(HELP)} run_coder
prep -top run_coder
memory_map; opt -full
[files]
lib
""")
    run(["sby", "-f", "p.sby"], d, timeout=TIMEOUT)
    st = (d / "p" / "status").read_text().split()[0] if (d / "p" / "status").exists() else "TIMEOUT"
    res = {"PASS": "PROVED", "FAIL": "DISPROVED"}.get(st, st)
    if res == "PROVED":
        shutil.rmtree(d)
        return dict(width=width, live=live, res=res)
    log = (d / "p" / "logfile.txt").read_text() if (d / "p" / "logfile.txt").exists() else ""
    return dict(width=width, live=live, res=res, info="\n".join(re.findall(r".*(?:Assert failed|ERROR|error|step).*", log))[-600:])


if __name__ == "__main__":
    widths = [int(w) for w in sys.argv[1:]] or [4, 8, 37]
    jobs = [(w, bool(os.environ.get("RC_LIVE"))) for w in widths]
    with mp.Pool(len(jobs)) as p, open(RESULTS / "run_coder.jsonl", "a") as f:
        for r in p.imap_unordered(one, jobs):
            f.write(json.dumps(r) + "\n"); f.flush()
            print(r["width"], "live" if r["live"] else "", r["res"], r.get("info", "")[-400:], flush=True)
