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

## Open decisions
1. Trimmed core: a separate top (`openjls_core`, Mert's interface, same stage entities) vs. feature generics on the current top. Leaning separate top: generics multiply the verified configurations.
2. Packer + stuffer merge: trimmed core only, or a main candidate.
3. Present the comparison as an ablation ladder on XC7VX485-2: Mert-equivalent, then + backpressure, + multi-image, + framer, + speculation, + BITNESS, with ΔLUT / ΔFF / Δfmax per step.
