The byte-stuffer rewrite preserves its cycle-level interface while reducing
the combinational logic between holding-buffer registers. In the measured
configuration, the isolated module's routed frequency estimate increases
from 248.0 to 334.9 MHz, and the full core increases from 238.6 to 254.1 MHz.

Measurements were taken on 2026-09-08 with Vivado 2025.2, targeting
`xczu7eg-fbvb900-1-e`. The baseline is
`c65ad37370b55b6ecb26125c990c841432228cfe:Sources/byte_stuffer.vhd`.
Both versions used the same non-project, out-of-context flow:
`synth_design`, `opt_design`, `place_design`, `phys_opt_design`, and
`route_design`, with default directives and four tool threads.

| Configuration | Version | Clock constraint | Routed WNS | Estimated fmax | LUTs | Registers |
|---|---|---:|---:|---:|---:|---:|
| Byte stuffer, 48-bit input, FIFO depth 16 | Baseline | 2.000 ns | -2.033 ns | 247.95 MHz | 2,276 | 498 |
| Byte stuffer, 48-bit input, FIFO depth 16 | Optimized | 2.000 ns | -0.986 ns | 334.90 MHz | 1,707 | 464 |
| Full core, 12-bit pixels, 4096 × 4096, 64-bit output | Baseline | 3.000 ns | -1.191 ns | 238.61 MHz | 7,518 | 2,092 |
| Full core, 12-bit pixels, 4096 × 4096, 64-bit output | Optimized | 3.000 ns | -0.936 ns | 254.07 MHz | 6,786 | 2,049 |

The full core uses its existing FIFO sizing (depth 64) and 1.5 BRAM tiles
in both versions. The isolated depth-16 FIFOs map to LUTRAM in both versions.
The frequency estimate is `1000 / (clock_period_ns - routed_WNS_ns)`, using
the worst setup path. These deliberately overconstrained runs measure
internal register-to-register timing, with no external port delays. They
are representative implementation comparisons, not hardware measurements
or a guarantee across image sizes, implementation strategies, or devices.

The isolated module improves by 35.1% in estimated frequency while using
25.0% fewer LUTs. Its worst path falls from 12 to 8 logic levels. The full
core improves by 6.5% and uses 9.7% fewer LUTs. Its worst path moves from
the byte stuffer to `sReg2_reg[Q][4]` → `sReg3_reg[Errval][12]`; further
whole-core frequency work should investigate that prediction/error path.

The implementation changes are:

- Refill uses nine fixed alignments, because the existing skid-pop contract
  only permits 0–8 old bits. The final FIFO word follows the same data path;
  its real-bit count determines validity. Copying its invalid trailing bits
  is safe because emission is count-gated, refill overwrites invalid bits,
  and terminal padding explicitly writes zeros.
- Eight mutually exclusive predicates select the legal four-byte stuffing
  layouts. Each layout uses fixed slices and constant consumption thresholds.
- The remaining buffer and count are selected from fixed shifts/decrements
  for consumption counts `0, 7, 8, 15, 16, 22, 23, 24, 30, 31, 32`.
- The no-emission condition depends directly on ready, available bits, and
  the incoming FF state, bypassing the output-count decoder.

No pipeline stage was added. Output capacity remains up to four bytes per
cycle, with the same partial beats, refill schedule, input backpressure,
and image-terminal timing. The first experiment, changing only layout and
remainder selection, reached 250.2 MHz; exposing the restricted refill
alignments was the largest improvement.

Validation of the final logic:

- All 44 OSVVM regression configurations passed, with PSL assertions enabled.
  Byte-stuffer statement coverage was 181/181 (100%).
- The additional cycle-equivalence test passed 2,000 images for each of six
  combinations: 32/48/64-bit input, with randomized stalls or downstream
  continuously ready. It checked 1,241,004 cycles and 2,382,118 output bytes
  against the original RTL, including full-width zero/one streams and resets
  during unfinished images. Data, valid-byte counts, output-valid timing,
  almost-full timing, and flush-done timing matched. This is simulation
  evidence of unchanged throughput and latency, not a formal proof.
- The T.87 conformance suite passed.
- The CharLS golden-model suite passed all 203 eligible images; 84 larger
  images were skipped by the existing 0.5-megapixel default limit.
- The post-synthesis full-core OSVVM test passed 22,676 assertions and all
  five requirements using the 8-bit, 4096 × 4096, 64-bit-output netlist.

The baseline regression initially had three failures in the AXI register
test: its expected version was still 1.0.0 although the RTL reports 1.2.0.
The test expectation was updated to 1.2.0; no register behavior was changed.

To reproduce, start in the repository root and save the baseline:

```bash
mkdir -p build/byte_stuffer_perf/baseline
git show c65ad37370b55b6ecb26125c990c841432228cfe:Sources/byte_stuffer.vhd \
  > build/byte_stuffer_perf/baseline/byte_stuffer.vhd
Verification/OSVVM/compare_byte_stuffer.sh \
  "$PWD/build/byte_stuffer_perf/baseline/byte_stuffer.vhd"
```

Run the timing script from a separate output directory per version. Supply
absolute paths for the script and chosen source file:

```bash
vivado -mode batch -source /path/to/OpenJLS/Scripts/benchmark_byte_stuffer.tcl \
  -tclargs /path/to/byte_stuffer.vhd byte_stuffer 48 2.0

vivado -mode batch -source /path/to/OpenJLS/Scripts/benchmark_byte_stuffer.tcl \
  -tclargs /path/to/byte_stuffer.vhd openjls_top 48 3.0
```

Each run writes `result.txt`, synthesis and routed utilization/timing reports,
the 20 worst routed paths, and `routed.dcp`. Original experiment artifacts
remain under `build/byte_stuffer_perf/`: `baseline`, `parallel_v3`,
`top_baseline`, and `top_v3`. These generated artifacts are gitignored.
