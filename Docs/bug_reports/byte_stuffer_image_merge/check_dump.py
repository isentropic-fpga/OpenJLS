# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
# Split the dumped output at oLast, encode the dumped pixels with CharLS, byte-compare per image
import sys, subprocess, os, struct
pre, W, H, B, CLI = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
pix = [int(x) for x in open(pre + "_pix.txt").read().split()]
imgs = [pix[i:i + W * H] for i in range(0, len(pix), W * H)]
streams, cur = [], bytearray()
for line in open(pre + "_out.txt"):
    tok = line.split()
    for t in tok:
        if t == "L":
            streams.append(bytes(cur)); cur = bytearray()
        else:
            cur.append(int(t))
if cur: streams.append(bytes(cur) + b"<no oLast>")
d = pre + "_chk"; os.makedirs(d, exist_ok=True)
refs = []
for k, im in enumerate(imgs):
    maxv = 2 ** B - 1
    hdr = f"P5\n{W} {H}\n{maxv}\n".encode()
    body = bytes(im) if B <= 8 else b"".join(struct.pack(">H", v) for v in im)
    open(f"{d}/{k}.pgm", "wb").write(hdr + body)
    subprocess.run([CLI, "encode", f"{d}/{k}.pgm", f"{d}/{k}.jls"], check=True, capture_output=True)
    refs.append(open(f"{d}/{k}.jls", "rb").read())
print(f"{pre}: images={len(imgs)} streams={len(streams)}")
for k in range(max(len(imgs), len(streams))):
    r = refs[k] if k < len(refs) else b""
    s = streams[k] if k < len(streams) else b""
    ok = r == s
    if not ok:
        print(f"  img {k}: ref {len(r)} B, got {len(s)} B -> MISMATCH")
print("  all byte-exact" if len(imgs) == len(streams) and all(refs[k] == streams[k] for k in range(len(imgs))) else "  FAIL")
