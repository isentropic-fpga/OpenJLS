#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""One check of the formal suite (index into run_suite.CHECKS) on FORMAL_SOURCES, verdict as JSON.

  formal_check.py I               {"res": ..., "sec": ...}
  formal_check.py --hash I [I..]  {I: hash of the files the check writes and the sources they name}, no tool runs
A check whose written files hash the same for gold and mutant cannot see the mutant.
"""
import hashlib, json, re, shutil, subprocess as sp, sys
from pathlib import Path

F = Path(__file__).resolve().parents[1] / "Formal"
sys.path[:0] = [str(F / "Common"), str(F / "Properties"), str(F)]
import flow

if sys.argv[1] == "--hash":
    # The property scripts write their sources before the first tool call
    flow.run = lambda cmd, cwd, timeout=None: sp.CompletedProcess(cmd, 0, "", "")
    import run_suite
    out = {}
    for i in map(int, sys.argv[2:]):
        d = run_suite.WORK / f"j{i:03d}"
        shutil.rmtree(d, ignore_errors=True)
        try:
            run_suite.do(i)
        except BaseException:
            pass
        h, refs = hashlib.sha1(), set()
        for f in sorted(p for p in d.rglob("*") if p.is_file()) if d.exists() else []:
            data = f.read_bytes()
            refs |= set(re.findall(re.escape(str(flow.S)).encode() + rb"/([\w.]+\.vhd)", data))
            h.update(str(f.relative_to(d)).encode())
            h.update(data.replace(str(flow.S).encode(), b"@S@").replace(str(d).encode(), b"@D@"))
        # Sources the tools read by path count by content
        for r in sorted(refs):
            h.update(r + (flow.S / r.decode()).read_bytes())
        out[i] = h.hexdigest()[:16]
        shutil.rmtree(d, ignore_errors=True)
    print(json.dumps(out))
else:
    import run_suite
    _, r, sec = run_suite.do(int(sys.argv[1]))
    print(json.dumps(dict(res=r, sec=sec)))
