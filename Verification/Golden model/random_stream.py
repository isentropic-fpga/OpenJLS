#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

"""Random no-reset image streams vs CharLS: size, depth, output width, valid, ready, content.

The seed alone defines a run; --replay SEED repeats it and keeps its files. Dimensions
latch only under reset, so all images of a run share one size. A seed that passed on the
same RTL, TB and generator is skipped unless --rerun. Mid-image reset and the control plane
stay with the OSVVM top TB.
"""
import argparse
import csv
import hashlib
import os
import re
import shutil
import subprocess
import threading
import time
from collections import Counter
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = HERE / "Output" / "Random"
LIBS = HERE / "work-lib"
CLI = ROOT / "ThirdParty/charls/build/cli/charls-cli"
TB = "tb_openjls_golden_stream"
TSV = OUT / "results.tsv"
PINNED = HERE / "random_stream_seeds.txt"
COLUMNS = "Seed Bits W H Out Valid% Ready% Images Pixels Result WindowHits Seconds RTL".split()

# Biased towards what found the image-merge bug: low ready and minimum dimensions.
WIDTHS = ((4, 4, 25), (5, 16, 30), (17, 256, 35), (257, 2048, 10))
HEIGHTS = ((1, 1, 30), (2, 8, 30), (9, 64, 40))
READY = {3: 40, 10: 15, 30: 10, 60: 10, 95: 5, 100: 20}
VALID = {100: 50, 95: 15, 70: 10, 30: 15, 5: 10}
OUT_WIDTHS = {64: 50, 48: 10, 56: 10, 72: 10, 128: 10, 256: 5, 1024: 5}
KINDS = "flat noise low_noise ramp blocks extremes flat_tail".split()
MAX_PIXELS = 120_000
MAX_IMAGES = 400
MIN_RUNS_FOR_HITS = 20


def weighted(rng, table):
    keys = list(table)
    weights = np.array([table[k] for k in keys], float)
    return int(keys[rng.choice(len(keys), p=weights / weights.sum())])


def band(rng, bands):
    i = rng.choice(len(bands), p=np.array([b[2] for b in bands], float) / sum(b[2] for b in bands))
    return int(rng.integers(bands[i][0], bands[i][1], endpoint=True))


def settings(rng):
    w, h = band(rng, WIDTHS), band(rng, HEIGHTS)
    n = min(int(rng.integers(8, MAX_IMAGES, endpoint=True)), max(2, MAX_PIXELS // (w * h)))
    return {"bits": int(rng.integers(8, 16, endpoint=True)), "w": w, "h": h, "n": n,
            "out": weighted(rng, OUT_WIDTHS), "valid": weighted(rng, VALID), "ready": weighted(rng, READY)}


def image(rng, kind, w, h, bits):
    mx = (1 << bits) - 1
    if kind == "flat":
        return np.full((h, w), rng.integers(0, mx, endpoint=True))
    if kind == "noise":
        return rng.integers(0, mx, (h, w), endpoint=True)
    if kind == "low_noise":
        base = rng.integers(0, mx, endpoint=True)
        return np.clip(base + rng.integers(-3, 3, (h, w), endpoint=True), 0, mx)
    if kind == "ramp":
        return (np.add.outer(np.arange(h), np.arange(w)) * rng.integers(1, 8, endpoint=True)) & mx
    if kind == "extremes":
        return rng.integers(0, 1, (h, w), endpoint=True) * mx
    if kind == "flat_tail":
        px = rng.integers(0, mx, (h, w), endpoint=True)
        cut = rng.integers(0, h * w)
        px.flat[cut:] = px.flat[cut]
        return px
    lengths = rng.integers(1, max(2, w), 2 * w * h + 1)  # blocks: runs and interruptions
    values = rng.integers(0, mx, lengths.size, endpoint=True)
    return np.repeat(values, lengths)[:w * h].reshape(h, w)


def generate(seed, p, d):
    """Write the concatenated pixels, CharLS streams and lengths for one run."""
    rng = np.random.default_rng(seed)
    settings(rng)
    d.mkdir(parents=True, exist_ok=True)
    dtype = "u1" if p["bits"] == 8 else ">u2"
    header = f"P5\n{p['w']} {p['h']}\n{(1 << p['bits']) - 1}\n".encode()
    pgm, jls = d / "i.pgm", d / "i.jls"
    with open(d / "x.pix", "wb") as pix, open(d / "x.jls", "wb") as ref, open(d / "x.len", "w") as lens:
        for _ in range(p["n"]):
            raw = image(rng, KINDS[rng.integers(len(KINDS))], p["w"], p["h"], p["bits"]).astype(dtype).tobytes()
            pix.write(raw)
            pgm.write_bytes(header + raw)
            subprocess.run([CLI, "encode", pgm, jls], check=True, capture_output=True)
            data = jls.read_bytes()
            ref.write(data)
            lens.write(f"{len(data)}\n")


def simulate(seed, p, d, timeout, heap):
    rel = d.relative_to(ROOT)
    work = f"work:{LIBS}/work.08"
    cmd = ["nvc", "--std=2008", "--ieee-warnings=off", "-H", heap, "-L", LIBS, f"--work={work}",
           "-e", "--jit", "--no-save", f"-gREPO_ROOT={ROOT}/", f"-gPIX_PATH={rel}/x.pix",
           f"-gJLS_PATH={rel}/x.jls", f"-gLEN_PATH={rel}/x.len", f"-gRES_PATH={rel}/x.res",
           f"-gBITNESS={p['bits']}", f"-gW={p['w']}", f"-gH={p['h']}", f"-gN_IMAGES={p['n']}",
           f"-gOUT_WIDTH={p['out']}", f"-gVALID_PCT={p['valid']}", f"-gREADY_PCT={p['ready']}",
           f"-gSEED={seed}", TB, "-r", "--exit-severity=error", TB]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=timeout)
    except subprocess.TimeoutExpired:
        return "TIMEOUT", 0
    (d / "sim.log").write_text(r.stdout + r.stderr)
    m = re.search(r"window_hits=(\d+)", r.stdout + r.stderr)
    return ("PASS" if r.returncode == 0 else "FAIL"), int(m.group(1)) if m else 0


def rtl_hash():
    h = hashlib.sha256()
    for f in sorted((ROOT / "Sources").glob("*.vhd")) + [HERE / f"{TB}.vhd", Path(__file__).resolve()]:
        h.update(f.read_bytes())
    return h.hexdigest()[:12]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--seed", type=int, help="first run seed (default: from the clock)")
    ap.add_argument("--rtl-seed", action="store_true", help="first seed from the RTL hash; also run the pinned seeds")
    ap.add_argument("--runs", type=int, help="stop after this many runs")
    ap.add_argument("--minutes", type=float, help="start no new run after this time")
    ap.add_argument("--replay", type=int, metavar="SEED", help="repeat one run and keep its files")
    ap.add_argument("--threads", type=int, default=20)
    ap.add_argument("--timeout", type=int, default=1800, help="seconds per simulation")
    ap.add_argument("--heap", default="512m", help="NVC heap per simulation")
    ap.add_argument("--rerun", action="store_true", help="ignore earlier passes")
    ap.add_argument("--no-analyze", action="store_true", help="work-lib is already current")
    a = ap.parse_args()
    if a.replay is None and not (a.runs or a.minutes):
        ap.error("give --runs, --minutes or --replay")

    if not a.no_analyze:
        subprocess.run([HERE / "build_run.sh"], check=True, stdout=subprocess.DEVNULL, env={**os.environ, "ANALYZE_ONLY": "1"})
    OUT.mkdir(parents=True, exist_ok=True)
    if not TSV.exists():
        TSV.write_text("\t".join(COLUMNS) + "\n")
    rtl = rtl_hash()
    cached = {}
    if not a.rerun and a.replay is None:
        with open(TSV) as f:
            last = {int(r["Seed"]): r for r in csv.DictReader(f, delimiter="\t")}
        cached = {s: r for s, r in last.items() if r["Result"] == "PASS" and r["RTL"] == rtl}

    if a.replay is not None:
        first = a.replay
    elif a.rtl_seed:
        first = int(rtl, 16) % (1 << 30) + 1
    else:
        first = a.seed if a.seed is not None else int(time.time()) % (1 << 30)
    pinned = []
    if a.rtl_seed:
        pinned = [int(c) for c in (l.split("#")[0].strip() for l in PINNED.read_text().splitlines()) if c]
    limit = 1 if a.replay is not None else a.runs
    deadline = time.monotonic() + a.minutes * 60 if a.minutes else None
    print(f"first seed {first}, {len(pinned)} pinned, RTL {rtl}, {a.threads} threads")

    lock = threading.Lock()
    started = 0
    done, hits, failed = Counter(), Counter(), []
    reused = 0

    def worker():
        nonlocal started, reused
        while True:
            with lock:
                if (limit and started >= limit + len(pinned)) or (deadline and time.monotonic() > deadline):
                    return
                seed = pinned[started] if started < len(pinned) else first + started - len(pinned)
                started += 1
                if seed in cached:
                    done[int(cached[seed]["Bits"])] += 1
                    hits[int(cached[seed]["Bits"])] += int(cached[seed]["WindowHits"])
                    reused += 1
                    continue
            t0 = time.monotonic()
            p = settings(np.random.default_rng(seed))
            d = OUT / f"s{seed}"
            try:
                generate(seed, p, d)
                result, h = simulate(seed, p, d, a.timeout, a.heap)
            except (subprocess.CalledProcessError, OSError) as e:
                (d / "error.txt").write_text(str(e))
                result, h = "ERROR", 0
            row = [seed, p["bits"], p["w"], p["h"], p["out"], p["valid"], p["ready"], p["n"],
                   p["n"] * p["w"] * p["h"], result, h, round(time.monotonic() - t0), rtl]
            with lock:
                with open(TSV, "a") as f:
                    f.write("\t".join(map(str, row)) + "\n")
                done[p["bits"]] += 1
                hits[p["bits"]] += h
                if result != "PASS":
                    failed.append(seed)
                print(" ".join(f"{c}={v}" for c, v in zip(COLUMNS, row)), flush=True)
            if result == "PASS" and a.replay is None:
                shutil.rmtree(d)

    threads = [threading.Thread(target=worker) for _ in range(a.threads)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    print("Bits  Runs  WindowHits")
    for b in sorted(done):
        print(f"{b:4}  {done[b]:4}  {hits[b]:10}")
    print(f"Runs {sum(done.values())} ({reused} cached), failed {len(failed)}, window hits {sum(hits.values())}")
    if failed:
        print("Failing seeds (files under Output/Random/s<seed>):", *sorted(failed))
        raise SystemExit(1)
    vacuous = [b for b in sorted(done) if done[b] >= MIN_RUNS_FOR_HITS and hits[b] == 0]
    if vacuous:
        raise SystemExit(f"FAIL: no run reached the merge window at BITNESS {vacuous}")


if __name__ == "__main__":
    main()
