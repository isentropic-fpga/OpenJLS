The regular prediction/error optimization raises the measured full-core
frequency estimate from 254.1 to 282.7 MHz without adding pipeline stages.
It combines prediction correction and error computation so late context
bias data does not cross two serial full-width arithmetic operations.

The baseline is commit `82ae135512d38f91b6df717e0d7c68a7dcb2e957`, which
already includes the byte-stuffer optimization. Measurements were taken on
2026-09-08 with Vivado 2025.2 targeting `xczu7eg-fbvb900-1-e`, 12-bit pixels,
4096 × 4096 maximum dimensions, and 64-bit output. Both versions use the
same non-project, out-of-context flow and 3.000 ns clock constraint:
`synth_design`, `opt_design`, `place_design`, `phys_opt_design`, and
`route_design`, with default directives and four tool threads.

| Full-core measurement | Baseline | Optimized |
|---|---:|---:|
| Routed WNS | -0.936 ns | -0.537 ns |
| Estimated fmax | 254.07 MHz | 282.73 MHz |
| Total LUTs | 6,786 | 6,563 |
| LUTs used as logic | 6,462 | 6,503 |
| LUTs used as memory | 324 | 60 |
| Registers | 2,049 | 2,013 |
| BRAM tiles | 1.5 | 2.5 |

Frequency improves by 11.3%. Total LUTs fall by 3.3%, but this is not a
uniform area reduction: Vivado's automatic memory mapping uses one more
36-kilobit block RAM, with fewer distributed-memory LUTs and slightly more
logic LUTs. No memory depth or image capacity was changed in RTL.

The estimate is `1000 / (clock_period_ns - routed_WNS_ns)`, using the worst
setup path under deliberately tight constraints. External ports have no
input/output delay constraints. These are internal timing estimates from
one implementation flow and device configuration, not hardware clock
measurements or guarantees across configurations.

The original worst path ran from `sReg2_reg[Q][4]` through context selection,
prediction correction, error subtraction, and modulo reduction to
`sReg3_reg[Errval][12]`. The optimized worst path is
`sReg1D2_reg[3]` → `u_ctx_ram/sUseInitReg_reg`, in the context-initialization
selection logic. Prediction/error is no longer the limiting path in this run.

The arithmetic change is in `Sources/A6_A7_prediction_error.vhd`, used for
the central and clamped ±1 speculative bias candidates in `openjls_top`.
Before prediction clipping, the two signs give:

```text
positive: Ix - (Px + Cq) = (Ix - Px) - Cq
negative: (Px - Cq) - Ix = (Px - Ix) - Cq
```

The pixel-only difference can settle before the forwarded bias arrives.
Meanwhile, `Px ± Cq` is computed independently to decide whether prediction
clips to zero or MAXVAL. The clipped errors also depend only on the input
pixel, so the output selects between those boundary errors and the raw
difference-minus-bias result. An overflowing raw candidate is never selected:
if corrected prediction is inside the legal interval, the pixel difference
fits the existing signed error width.

`A9_modulo_reduction` now specializes `RANGE_P = 2**BITNESS` to a bit slice
and sign extension. The low BITNESS bits give the residue; interpreting them
as signed selects `[-RANGE/2, RANGE/2-1]`. The original arithmetic remains
for other range values. This specialization alone saved LUTs but routed at
240.73 MHz, slower than the baseline. Combining it with the parallel A.6/A.7
calculation produced the final improvement; the isolated arithmetic saving
was not sufficient to improve full-core timing.

The original A.6 and A.7 standalone modules remain available. All explicit
simulation/synthesis source lists include the new combined module. Context
forwarding, registers, clock enables, stall propagation, and output framing
retain their existing cycle boundaries. No extra latency or throughput
bubbles were introduced by this combinational replacement.

Validation:

- All 60 OSVVM regression configurations passed with PSL assertions enabled.
- The combined A.6/A.7 test passed 2,459,117 affirmations across 8/12/16-bit
  configurations and an 8-bit MAXVAL=200 configuration. Its independent
  integer reference performs correction, clipping, and error subtraction
  in the original sequential order. It checks every context bias, both
  signs, clipping boundaries, and randomized pixels; at 8 bits it also
  sweeps every uncorrected prediction for several pixel/error boundaries.
- A.9 passed 279,131 affirmations across all nine supported pixel widths
  and four odd-range configurations. Every representable signed input is
  checked against the original integer algorithm for each configuration.
- Both changed arithmetic modules reached 100% statement coverage.
- T.87 conformance passed.
- The CharLS golden suite passed 203 images; 84 larger images were skipped
  by the existing 0.5-megapixel default cap.
- The full-core post-synthesis OSVVM test passed 22,676 checks and all five
  requirements on the 8-bit, 4096 × 4096, 64-bit-output netlist.

The timing helper now accepts an optional fifth argument selecting a frozen
Sources directory. Run it from a separate output directory for each version:

```bash
vivado -mode batch -source /path/to/OpenJLS/Scripts/benchmark_byte_stuffer.tcl \
  -tclargs /path/to/snapshot/Sources/byte_stuffer.vhd openjls_top 48 3.0 \
  /path/to/snapshot/Sources
```

The source snapshot must contain all top-level `Sources/*.vhd` files, including
the common package. The helper uses the repository's unchanged open-logic
dependencies. To reproduce functional verification:

```bash
Verification/OSVVM/build_run.sh
"Verification/T87 conformance/build_run.sh"
NUMBER_OF_THREADS=4 "Verification/Golden model/build_run.sh"
"Verification/Post synth/build_run_osvvm.sh"
```

Original source snapshots, routed checkpoints, and reports are under
`build/prediction_perf/{baseline,modulo,fused}/`; verification logs and the
post-synthesis netlist are alongside them. Generated artifacts are gitignored.

## Forced context-memory mapping experiment

On 2026-09-08, two frozen copies of the optimized RTL were implemented with
only `RAMSTYLE_G` in `context_ram.vhd` changed from `"auto"` to respectively
`"distributed"` and `"block"`. Device, generics, 3 ns constraint, and flow were
identical to the preceding measurements. Final synthesis mapping reports
confirmed that the requested implementations were honored.

| Full-core routed measurement | Forced LUTRAM | Forced BRAM |
|---|---:|---:|
| WNS | -0.724 ns | -0.537 ns |
| Estimated fmax | 268.53 MHz | 282.73 MHz |
| Total LUTs | 6,946 | 6,563 |
| Logic LUTs | 6,622 | 6,503 |
| Memory LUTs | 324 | 60 |
| Registers | 2,052 | 2,013 |
| BRAM tiles | 1.5 | 2.5 |

BRAM improves the frequency estimate by 5.3% relative to forced LUTRAM and
saves 383 LUTs (264 memory LUTs plus 119 logic LUTs) and 39 registers, at the
cost of one RAMB36E2. Its 367 by 37-bit context table contains 13,579 bits,
36.8% of the block's 36,864-bit capacity. The forced-BRAM timing and resource
counts exactly reproduce the earlier automatic-mapping result.

The LUTRAM run's worst path is `sReg2_reg[Q][2]` to
`sReg3_reg[Errval][4]`; its second path is error to run-interruption `Temp`,
at -0.705 ns slack. Mapping changes affect placement and surrounding logic,
so the 187 ps slack difference is a full-implementation comparison, not a
measurement of intrinsic memory access delay alone. These are single runs
per forced style, not a placement-seed sweep.

The optimized LUTRAM run still exceeds the earlier baseline's 254.07 MHz
estimate by 5.7%, although that baseline used automatic mapping. This shows
that the arithmetic optimization retains a benefit without the extra BRAM;
it does not fully isolate arithmetic and mapping interactions.

Production `Sources/context_ram.vhd` remains set to `"auto"`. No functional
RTL change was applied to production sources and no additional simulation
suite was run for these implementation-only experiments. Frozen sources,
logs, routed reports, and checkpoints are retained under
`build/context_ram_perf/{distributed,block}/`. Reproduce each with the timing
helper command above using that experiment's Sources directory and a
separate output directory.
