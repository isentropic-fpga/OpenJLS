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

Routed fmax, MHz (Default / Explore / NetDelay / SpreadLogic → best):

| BITNESS | f2947f7 | 0fb2554 | 8c32762 |
|---|---|---|---|
| 8 | 299/299/295/295 → 299 | 294/307/282/292 → 307 | 318/322/329/311 → **329** |
| 10 | 284/287/291/285 → 291 | 276/286/289/269 → 289 | 295/296/310/302 → **310** |
| 12 | 279/274/266/269 → 279 | 253/257/268/261 → 268 | 276/294/278/281 → **294** |
| 16 | 214/224/207/218 → 224 | 221/219/221/209 → 221 | 247/253/245/247 → **253** |

Walls per point, Default run, fmax in MHz:

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

## Open decisions
1. Trimmed core: a separate top (`openjls_core`, Mert's interface, same stage entities) vs. feature generics on the current top. Leaning separate top: generics multiply the verified configurations.
2. Packer + stuffer merge: trimmed core only, or a main candidate.
3. Present the comparison as an ablation ladder on XC7VX485-2: Mert-equivalent, then + backpressure, + multi-image, + framer, + speculation, + BITNESS, with ΔLUT / ΔFF / Δfmax per step.
