# Architecture exploration (dev/area_perf)

Working notes after the qualification: where the area goes, where the hot paths are, and how OpenJLS compares 1:1 with Mert (2018).

## Advisor asks
1. Expand the architecture explanation and compare it with Mert's.
2. Trim OpenJLS to Mert's feature set for a close 1:1 comparison; the full core is much bigger.
3. Categorize every characterization point by where its hot path lives, to find weak points by analysis.

## Mert (2018) baseline
Y. M. Mert, *Key Architectural Optimizations for Hardware Efficient JPEG-LS Encoder*, VLSI-SoC 2018, DOI 10.1109/VLSI-SoC.2018.8644996.

| | Mert | OpenJLS |
|---|---|---|
| Pixel depth | 8 bit | 8–16 bit |
| Modes | regular + run | regular + run |
| Throughput | 1 px/clk, 7 stages | 1 px/clk, 6 stages + output |
| Device / result | XC7VX485-2: 207.8 MHz, 544 FF, 1373 LUT, 567 slices | xczu7eg-1, 8 bit: ~305 MHz, 1779 FF, 4941 LUT (synth) |
| Line buffer | 16K × 8, 2 BRAM | MAX_IMAGE_WIDTH × BITNESS FIFO |
| Context table | 366 × 33, 1 dual-port BRAM, Nn embedded | 367 × TOTAL_WIDTH SDP BRAM, Nn in the B slot |
| Input | pixel + EOL/EOF flags, no backpressure | ready/valid, dimension ports |
| Output | 32-bit bit-stuffed packets + valid | framed .jls stream (SOI/SOF55/SOS/EOI), OUT_WIDTH, keep/last, backpressure |
| Images | one at a time | back-to-back, up to 3 in flight |
| Packer + stuffer | merged in one stage (2·LIMIT−1 buffer); Mert's main area win | separate bit_packer, then byte_stuffer accumulator + FIFO |
| Context hazard | data forwarding (its critical path) | forwarding + 3-way Cq speculation |

Virtex-7 is installed in Vivado 2025.2, so the 1:1 comparison can target the same XC7VX485-2.

## Area by module
OOC synth, MAX_IMAGE_WIDTH 12288, OUT_WIDTH 64, `-flatten_hierarchy rebuilt`. Rebuilt lets logic cross module boundaries, so ctx_ram likely absorbs stage-2/3 logic. Framer and byte_stuffer only connect through ports, so their numbers are reliable. Rerun with `-flatten_hierarchy none` before quoting.

| Module | 8b LUT / FF | 12b LUT / FF | 16b LUT / FF |
|---|---|---|---|
| Total | 4941 / 1779 | 5853 / 2032 | 6909 / 2295 |
| jls_framer | 1722 / 339 | 1734 / 339 | 1516 / 339 |
| byte_stuffer | 1166 / 358 | 1574 / 471 | 2270 / 596 |
| ctx_ram (+ absorbed) | 1036 / 402 | 1243 / 406 | 1420 / 410 |
| bit_packer | 215 / 39 | 295 / 55 | 339 / 72 |
| A.10 (via A.20.2) | 138 / 0 | 250 / 0 | 347 / 0 |
| line_buffer | 225 / 123 | 230 / 139 | 251 / 155 |

### What Mert doesn't have (8 bit)
| Feature | ~LUT | ~FF |
|---|---|---|
| Framer (header, markers, 64-bit output, keep/last) | 1722 | 339 |
| Stuffer burst FIFO, almost-full stall, skid, valid queue | ~700 | ~300 |
| Separate bit_packer | 215 | 39 |
| Back-to-back images: 367 init flags + 367:1 mux, parity, in-flight cap | ~300 | ~370 |

Stripping these gives roughly 2.0–2.3k LUT / ~750 FF against Mert's 1373 / 544. The remaining gap is the 3-way speculation, the stall clock enables, the dimension clamp and LUTRAM FIFOs.

### Area candidates
1. **Framer**: ~30% of the 8-bit core and flat across BITNESS. The ~25-byte buffer with variable byte insert/emit at OUT_WIDTH 64 is the cost. Options: narrower OUT_WIDTH, or mux the header to the output instead of through the buffer.
2. **Two cascaded variable shifters**: bit_packer builds a LIMIT word, then the stuffer shifts it into a 2·LIMIT accumulator. Merging them is Mert's own main optimization. Area-only claim; earlier stuffer rewrites regressed fmax.
3. **Context init flags**: 367 FF + lookup tree. Kept: a generation tag in the BRAM word aliases after 2^k untouched images, and any exact RAM clear stalls. Their area is the price of back-to-back images, a row in the ablation ladder. Taken off the critical path in aafc6a4.
4. **A.10**: comparison chain, 138 → 347 LUT. Leading-zero estimate + one ±1 correction compare.

## Hot paths per characterization point
Top-20 paths per strategy from the 2026-10-02 bitness sweep (`build/fmax_bitness_20261002_155803`), 80 per bitness, bucketed by endpoint:

| BITNESS | Endpoints |
|---|---|
| 8 | sReg3.Errval 31, framer sBuffer 21, ctx BRAM 9, line_buffer FIFO 5, byte_stuffer 4 |
| 10 | sReg3 49, ctx BRAM 15, framer 4, sUseInitReg 4, byte_stuffer 3 |
| 12 | sReg3 54, ctx BRAM 18, sUseInitReg 4, framer 3 |
| 14 | sReg3 49, ctx BRAM 14, sUseInitValue 8, sUseInitReg 4, sReg1 4 |
| 16 | sReg3 69, ctx BRAM 5, init flags 6 |

This top-20 view only sees the worst structure; the cumulative study below replaces it.

### Lagging paths
- **RI forwarding `sReg3.Errval → sReg3.Temp`** (12–16 bit top 3): A.23 update then A.20 in the same cycle. The regular path got speculation; this one didn't. There are only 2 RI contexts.
- **`sImageWidth → sReg1.Ra`** (14 bit): line_buffer compares the column counter with `iImageWidth − 1` combinationally. Register the flag a cycle ahead.
- **16 bit**: ~1.0–1.4 ns short. `dev/optimization_bitness` helps; then the init-flag lookup leads again.

### Cumulative hot-path study (2026-10-30, f2947f7)
Method:
- Non-project OOC flow: synth → opt → place → phys_opt → route, Default directives.
- Width 12288, OUT_WIDTH 64, 3.0 ns overconstraint, BITNESS 8/10/12/14/16.
- Worst path to every endpoint with slack < 0.3 ns (1.3k–2.8k paths per point), bucketed by start/end structure.
- "fmax" is the ceiling that structure sets on its own: 1000 / (3.0 − its worst slack).
- One Default run per point, so the ordering of structures within ~0.05 ns of each other is placement noise.

Walls per point, worst first, fmax in MHz (TNS share in brackets):

| Structure | 8b | 10b | 12b | 14b | 16b |
|---|---|---|---|---|---|
| ctx loop: BRAM → Errval, Errval → BRAM din, RI Errval → Temp | 287 (6%) | 285 (6%) | **280** (13%) | **263** (10%) | **218** (9%) |
| init lookup → sUseInitReg (367:1 mux) | **275** (0%) | **284** (0%) | 292 (0%) | 270 (0%) | 222 (0%) |
| init flag write decode, sReg1D2 → 367 × sUseInitValue | 301 (55%) | 299 (27%) | 315 (6%) | 272 (38%) | 231 (31%) |
| dims / line_buffer → stage 1 (sImageWidth, sRowCounter) | 293 (12%) | 285 (11%) | 289 (13%) | 278 (9%) | 235 (10%) |
| byte_stuffer | 290 (10%) | 292 (15%) | 291 (8%) | 282 (6%) | 236 (16%) |
| framer: EOI FIFO head → emit count → sBuffer shift/CE | 316 (6%) | 296 (34%) | 290 (47%) | 281 (27%) | 254 (19%) |
| run mode A.15/16 (sReg1.Ix → sNextBound) | 298 | 304 | 300 | 289 | 256 |
| stage 1 → 2 | 308 | 319 | 299 | 295 | 258 |
| bit_packer | 349 | 297 | 331 | 316 | 288 |

Small leftovers: ctx address/write side (sReg1D2 / sReg1.Ix → ctx_ram) and, at 16 bit, sStallLogic fanout and Golomb sReg5 → sReg6.

Findings:
- **No single hot path per point.** At 8–14 bit, 5–7 unrelated structures sit within ~0.2 ns (~15 MHz) of the worst. Fixing only the top wall buys 1–4%. The "8–10 bit = byte stuffer, 11+ = context loop" split doesn't hold: the stuffer is never the worst at any BITNESS.
- **WNS owner ≠ TNS owner.** The worst path (ctx loop, init lookup) is a handful of endpoints. Most failing slack comes from wide, shallow structures: the 367 init flags, the framer sBuffer, the stuffer. Those are cheap to retime and set the post-fix floor.
- **Context init is the real weak point.** It appears three times in the top four at every BITNESS: lookup mux, write decode, and the ctx address side. The write decode is fed by the unregistered stage-1 context index into 367 enables. One redesign removes it as both an area and a timing item.
- **The framer regressed with the EOI FIFO (07a8cd9).** The head offset compare picks the emit byte count, which then drives a variable shift and CE of the whole buffer in one cycle. It's the largest TNS owner at 10–12 bit. Precomputing "EOI in next beat" from the FIFO head one cycle ahead should take it off the list.
- **16 bit is still the context loop** (15 levels BRAM → Errval), with init lookup/decode 0.1–0.25 ns behind. Fixing the loop alone gives ~222 MHz; all three gives ~235 MHz, where dims/stuffer take over.
- Absolute numbers sit below the README's best-of-four strategies (one Default run, non-project). Use the table for ranking, not as headline fmax.

Data and scripts: scratchpad `hot/` (routed DCPs per point, `paths.csv`, `bucket.py`, `ladder.py`).

### After the context work (8c32762)
Same flow as the 0fb2554 baselines: non-project OOC, 4 strategies, 2 threads.

| Commit | Change |
|---|---|
| 0fb2554 | framer: EOI-in-beat flags registered |
| aafc6a4 | init lookup indexed by merged Qi; flag clear a cycle late |
| 26eee7c | chain select from the A.13 branch; A.12 rescale registered |
| e49875c | forwarding hit registered a cycle early |
| 8c32762 | one chain fed straight from the BRAM, C/P/M from registers |
| cd35082 | BRAM write registered; reads forward both in-flight writes |

Routed fmax, MHz (Default / Explore / NetDelay / SpreadLogic → best):

| BITNESS | f2947f7 | 0fb2554 | 8c32762 | cd35082 |
|---|---|---|---|---|
| 8 | 299/299/295/295 → 299 | 294/307/282/292 → 307 | 318/322/329/311 → 329 | 333/332/327/≥336 → **≥336** |
| 10 | 284/287/291/285 → 291 | 276/286/289/269 → 289 | 295/296/310/302 → 310 | 332/327/327/324 → **332** |
| 12 | 279/274/266/269 → 279 | 253/257/268/261 → 268 | 276/294/278/281 → 294 | 299/304/307/300 → **307** |
| 16 | 214/224/207/218 → 224 | 221/219/221/209 → 221 | 247/253/245/247 → 253 | 244/253/256/260 → **260** |

At cd35082, 8 bit SpreadLogic meets 3.0 ns (WNS +0.027, hold met); 8 and 10 bit Default miss by ≤ 0.01 ns on 1–2 endpoints. The 3.0 ns overconstraint now caps 8–10 bit: next sweeps use 2.5 ns.

Walls per point at 8c32762, Default run, fmax in MHz:

| BITNESS | 1st | 2nd | 3rd | 4th | 5th |
|---|---|---|---|---|---|
| 8 | ctx read address 318 | ctx loop 322 | init lookup 327 | stuffer 330 | framer 330 |
| 10 | ctx loop 295 | ctx read address 311 | stuffer 312 | framer 312 | packer 316 |
| 12 | ctx read address 276 | ctx loop 280 | framer 285 (42% TNS) | init lookup 286 | stuffer 291 |
| 16 | init lookup 247 | ctx loop 248 | ctx read address 249 | stuffer 270 | stage 1 → 2 278 |

- The init flag write decode is gone everywhere.
- What remains of the ctx loop is mostly the writeback, Errval → A.12/A.13 → BRAM din.
- New co-wall: ctx read address, sReg1D2 → A.4 → A.4.1 → A.4.2 → BRAM address. At 16 bit the same cone feeds the init lookup.
- 12 bit at Default alone is flat (279 → 276); ±10 MHz per point is placement noise.

Walls per point at cd35082, Default run, fmax in MHz:

| BITNESS | 1st | 2nd | 3rd | 4th | 5th |
|---|---|---|---|---|---|
| 8 | ctx read 333 | ctx loop 334 | stuffer 335 | framer 338 | dims 342 |
| 10 | RI Aq → Temp 332 | run mode A.15/16 337 | stuffer 338 | framer 339 | ctx loop 339 |
| 12 | RI Errval → Temp 299 | writeback (Bq → write word) 300 | init lookup 302 | framer 303 (49% TNS) | dims 309 |
| 16 | ctx read address 244 | init lookup 244 | BRAM → Errval, RI Temp 248 | stuffer 254 (32% TNS) | stage 1 → 2 265 |

- 8–10 bit are flat: every structure within ~3%, capped by the 3.0 ns constraint.
- 12 bit: the RI path (A.23 then A.20 in one cycle) leads; it never got speculation.
- 16 bit: the stage-2 quantization cone (A.4 → A.4.1 → A.4.2) limits both the read address and the init lookup.

### 8–10 bit ceiling at 2.5 ns (cd35082)
Same flow, 2.5 ns constraint, 8 and 10 bit only.

| BITNESS | Default / Explore / NetDelay / SpreadLogic | best | at 3.0 ns |
|---|---|---|---|
| 8 | 335/351/362/347 | **362** | ≥336 |
| 10 | 326/336/316/328 | **336** | 332 |

- 3.0 ns hid ~8% at 8 bit; 10 bit was already at its ceiling.
- Hold is met in every run.

Walls on the best run, fmax in MHz:

| BITNESS | 1st | 2nd | 3rd | 4th | 5th |
|---|---|---|---|---|---|
| 8 (NetDelay) | stuffer 362 | ctx read address 362 | dims 363 | framer 369 (44% TNS) | writeback 370 |
| 10 (Explore) | BRAM → Errval 336 | framer 338 (47% TNS) | ctx read address 338 | stuffer 342 | stage 1 → 2 343 |

Weak points, by how many points they limit:
1. **Ctx read address** (sReg1D2 → A.4 → A.4.1 → A.4.2 → BRAM address, 9–10 levels). It's a top-3 wall at 8, 10 and 16 bit, and also drives `sFwdOld` and the init lookup. Candidate: move the per-gradient quantization (A.4) into stage 1 so stage 2 only merges and indexes.
2. **BRAM → Errval** (5–6 levels, but it starts from the BRAM clock-to-out). The direct chain spends the unregistered BRAM output in the same cycle as A.6/A.7/A.9. A registered output would add a cycle to the context loop, so this is the structural floor of a 1-cycle read.
3. **Writeback** (Errval/Bq → A.12/A.13 → `sWrPendData`/`sFwdNewData`, 12–13 levels). It's now the deepest cone; the write register moved it but didn't shorten it.
4. **Framer** (`sFifoByteCount` → `sBuffer` CE, 8–9 levels). It owns 44–61% of TNS on every run: one count drives the CE of the whole buffer. Candidate: register a per-lane CE decode one cycle ahead.
5. **Stuffer** (`sStuffBufferBits` → buffer, 10 levels). This is the known carry-chain wall; representation rewrites regressed before.
6. **Dims → stage 1** (`sImageWidth` compare → `sReg1.mode`, 10 levels). Candidate: precompute end-of-line flags from the column counter.

None of these is bitness-specific except the widths. 1, 4 and 6 are cheap RTL changes; 2 is a latency trade; 3 needs the writeback split.

### Weak points 1 and 6
- A.4 moved into stage 1: stage 1 registers Q1–Q3 (4 bits) instead of D1–D3.
- That made stage 1 the 16 bit wall (−1.40 post-synth) through the line buffer's `col = width − 1` compare. The first/last column and first row flags are now next-state registers; the width only loads in reset.

Routed best-of-4 at 2.5 ns, MHz:

| BITNESS | cd35082 | + A.4 in stage 1, registered flags |
|---|---|---|
| 8 | 362 | 352 |
| 10 | 336 | 343 |
| 12 | 309 | 310 |
| 16 | 256 | 271 |

- Post-synth, the lookup/read address cone goes from −1.17 to +0.34 ns at 16 bit; it's off the wall list at every point.
- 8 bit: dims (363 → 378) and read address (362 → 365) both moved; BRAM → Errval (5 levels) now leads at 352, from 370. Placement of the BRAM path, not new logic.
- 12 bit is still the RI Temp path.
- Next: weak point 2 (BRAM output register, +1 cycle in the loop).

### Context loop arithmetic (weak points 1–2)
The BRAM output register would gain ~6 MHz at 16 bit: the register-sourced paths into Errval sat right behind the BRAM path. The depth on both sides of `sReg3.Errval` was the limit, so the arithmetic was flattened instead. No added latency.
- **A.6 clip as narrow compares.** `a6_clip_bounds` gives the Cq range where Px doesn't clip, from Px and Sign; `a6_clip_errors` gives the clipped Errval, from Ix and Sign. The late Cq sees one 8-bit compare and one subtract, not Px ± Cq followed by a wide compare. Bounds are computed in stage 3 from registers (constant compares and 8-bit subtracts, settled before the BRAM word); clip errors are registered in stage 2, which also stops Vivado sharing the error adder behind the compare. Bounds registered in stage 2 made A.5 → bounds the wall (−1.15 post-synth at 12 bit).
- **A.20 in stage 4.** TEMP only feeds k, so it left the forwarding loop (Errval → A.12 → forward → A.20 → `sReg3.Temp`).
- **A.13 tests as sums against 0**, with two guard bits so they never wrap.
- **B stored as its low bits.** Bq is in [−(RESET − 1), 0], so nonzero means negative; the negations after the A.13 select (write) and on the read go away, same BRAM width.
- Tried, no gain: A.12 `A + |E|` as one add/subtract (reverted).

Routed best-of-4 at 2.5 ns, MHz:

| BITNESS | Default / Explore / NetDelay / SpreadLogic | best | before (7b5bc09) |
|---|---|---|---|
| 8 | 369/359/342/337 | **369** | 352 |
| 10 | 348/332/357/345 | **357** | 343 |
| 12 | 268/264/332/344 | **344** | 310 |
| 16 | 301/300/295/307 | **307** | 271 |

- Hold met in every run (worst +0.016 ns). Area flat post-synth: 8 bit 5990 → 5979 LUT, 1853 FF; 16 bit 8396 → 8343 LUT, 2327 → 2401 FF (the registered clip errors).
- Walls on the best run: 8 bit, Cq → Errval, stuffer and stage 1 → 2 all within 3 MHz. 10 bit, framer CE then stuffer. 12 bit, Ra/Errval → Errval/Bq (10 levels), stuffer, framer. 16 bit, Errval → writeback / Errval / Aq, dims → stage 1 and stuffer within 8 MHz.
- 12 bit is strategy-sensitive (268–344): Default and Explore land 75 MHz below SpreadLogic.
- The context loop no longer stands alone at any point; the output side (stuffer, framer) is now co-limiting everywhere.
- Verified: OSVVM 115/115, golden sample 906/906 (MAX_MP=0.01). A first registered-bounds version tripped the A.6/A.7 range assert on unused chains: non-regular tokens register Sign = '0', so the stage-2 sign must match (`sS2Sign`).

### Context RAM output register (d5abf30, 2026-11-04)

Own enabled register on the BRAM output in a new stage 3; everything after it moves down one, for seven stages. Clock-to-out 0.90 → 0.23 ns, read forwards from a third in-flight write. `olo_base_ram_sdp` RDLATENCY > 1 ignores `Rd_Ena`, so its pipe breaks under stall. Write-gate parity must come from stage 2, or a new image in stage 1 drops a write the old image's last token still forwards.

Routed means, 4 strategies, 2.5 ns unless noted, size 12288, noise about ±7.5 MHz:

| Step | 8 bit MHz | 12 bit MHz | 8 bit LUT / FF | 12 bit LUT / FF |
|---|---|---|---|---|
| 4cb0d3c | 378.4 | 359.1 | | |
| RAM output register | 391.2 | 382.5 | 5430 / 2103 | 6299 / 2385 |
| + A.6 clip errors, sat and A.19 in stage 3 | 384.9 | 383.8 | 5429 / 2093 | 6326 / 2374 |
| + A.6 clip bounds in stage 3, sat merged (d5abf30) | 387.8 | 383.9 | 5436 / 2100 | 6242 / 2383 |
| d5abf30 at 2.2 ns | 381.2 | 381.3 | 5568 / 2130 | 6453 / 2406 |

- The moves into stage 3 simplify the architecture and don't change fmax.
- A false-path "ceiling" on RAM paths (384.5/374.7) had predicted less than this: it bounds only the excluded paths, while the new stage also registered the hit and forward compares.
- 2.2 ns doesn't help, LUT +2–3%. The target isn't what bunches the paths; keep 2.5 ns.
- No single wall left. Worst path moves with placement:

| Worst path in | a6/a19 step | d5abf30 | d5abf30, 2.2 ns |
|---|---|---|---|
| Framer | 1 | 4 | 6 |
| Stuffer | 4 | 1 | 0 |
| `sReg4` → `sReg5` | 3 | 0 | 2 |
| Other | 0 | 3 | 0 |

Mean per-run floor at 2.2 ns: framer 383.3, pipeline 385.4, stuffer 385.5, `sNextBound` 390.9, context RAM 394.5, line buffer 404.2.

Timing-report bound with blocks excluded, 8/12 bit MHz:

| Excluded | 2.5 ns | 2.2 ns |
|---|---|---|
| Nothing | 387.8 / 383.9 | 381.2 / 381.3 |
| Stuffer | 388.7 / 383.9 | 381.2 / 381.3 |
| Framer | 388.5 / 384.7 | 384.7 / 382.5 |
| Framer, stuffer | 391.4 / 385.0 | 386.9 / 382.7 |
| + pipeline | 393.0 / 386.9 | 388.5 / 390.8 |
| + `sNextBound` | 397.0 / 389.1 | 392.5 / 393.4 |

Framer is the most persistent limit, yet alone gains under 4 MHz. Untested options: on the short end-of-image beat, take one more cycle so the normal path only picks shift by `BYTES_OUT` or hold; or a ring buffer with no shift, a rewrite that moves the mux to the output. `sDataEmit` → `sBuffer` is 73% routing, fanout 102 after replication. Recommendation: stop here, since several blocks would have to change together for about 3%. Not yet decided.

Verified on d5abf30: OSVVM 129/129, T.87, golden sample 2,683 (MAX_MP=0.05), streams 18/18. Not yet run: post-synth, full golden, 40-run characterization. Latency 15 is derived, not measured.

### Chain D folded into chain C (05d3762, reverted)

Chain C takes `oRdData` on a miss, which removes one A.6/A.7 + A.9 chain and the 2:1 select before Reg4.

Post-synth, Default, 2.5 ns, size 12288:

| BITNESS | LUT | `sReg4.Errval` slack, ns |
|---|---|---|
| 8 | 5009 → 4964 | −0.330 → −0.101 |
| 10 | 5574 → 5553 | −0.367 → −0.138 |
| 12 | 5845 → 5792 | −0.339 → −0.056 |
| 16 | 6879 → 6811 | −0.300 → −0.251 |

Routed, 4 strategies, size 12288, mean / best MHz:

| Target | BITNESS | d5abf30 | Chain D folded |
|---|---|---|---|
| 2.5 ns | 8 | 387.8 / 402.6 | 372.3 / 380.1 |
| 2.5 ns | 12 | 383.9 / 397.5 | 364.4 / 384.6 |
| 2.45 ns | 8 | 381.3 / 394.3 | 382.2 / 400.3 |
| 2.45 ns | 12 | 390.2 / 398.9 | 385.4 / 397.0 |
| 2.4 ns | 8 | 388.1 / 397.1 | 382.9 / 387.9 |
| 2.4 ns | 12 | 391.4 / 399.0 | 384.9 / 386.6 |

- Mean change over the three targets: 8 bit −6.6, 12 bit −10.3 MHz; lower in five of six rows, so a small real loss is likely.
- The −15 to −20 MHz at 2.5 ns doesn't repeat; the same folded RTL gains 21 MHz at 12 bit from 2.5 → 2.45 ns alone. ±7.5 MHz understates the noise of a netlist or target change.
- At 2.5 ns, untouched blocks fell with the context path (stuffer 388.4 → 366.0 at 12 bit). Same logic depth, more routing.
- Reverted: the simpler architecture isn't worth 5–8 MHz.

Verified: OSVVM 129/129, golden sample 906/906 (MAX_MP=0.01), streams.

### Framer ring buffer

The framer's 30-byte shift FIFO became a 32-byte ring: writes decode from the write pointer only, reads rotate 8 bytes from the read pointer.

Routed, 2.5 ns, 4 strategies, size 12288, mean / best MHz:

| BITNESS | LUT | Chain D restored | Ring |
|---|---|---|---|
| 8 | 5441 → 5057 | 387.8 / 402.6 | 379.4 / 397.0 |
| 12 | 6267 → 5895 | 383.9 / 397.5 | 363.1 / 389.6 |

- The framer drops out of the top-20 paths (92 → 3 of 160). The stuffer, A.15/16 and compute-k were right behind it.
- The 12 bit mean carries one 310 MHz outlier on the untouched compute-k path; within the noise above.
- Kept for −7% LUT and one wall fewer.

Verified: OSVVM 129/129, golden sample 906/906 (MAX_MP=0.01), streams.

## Open decisions
1. Trimmed core: a separate top (`openjls_core`, Mert's interface, same stage entities) vs. feature generics on the current top. Leaning separate top: generics multiply the verified configurations.
2. Packer + stuffer merge: trimmed core only, or a main candidate.
3. Present the comparison as an ablation ladder on XC7VX485-2: Mert-equivalent, then + backpressure, + multi-image, + framer, + speculation, + BITNESS, with ΔLUT / ΔFF / Δfmax per step.
