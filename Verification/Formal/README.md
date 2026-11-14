# Formal verification

Formal checks of the OpenJLS RTL with GHDL + Yosys + SymbiYosys. Simulation checks the inputs that a test applies.
A formal tool checks a property against all input sequences: for a fixed number of clock cycles (bounded check, BMC),
or for any number of cycles (full proof, PDR or k-induction). Formal is one of the methods in the OpenJLS
verification report (`Verification/`), next to the OSVVM test benches, the golden-model comparison, post-synthesis
simulation, T.87 conformance and hardware-in-the-loop tests.

## What is proved

Results of the release suite (`./build_run.sh`): 396 checks, all with the expected result. 340 are full proofs and
56 are known-bad checks that fail as required (see "How results are qualified").

| Area | Property | Scope | Result |
|---|---|---|---|
| RTL asserts | Each module's own `assert` lines and PSL input contracts hold, for all inputs that meet the module contracts. The top check proves every module contract on the real top | All modules, BITNESS 8, 12, 16 | Proved |
| Top control | Valid/ready, stall, bubble and end-of-image control invariants of `openjls_top` | BITNESS 8-16, images 8 x 4 and 4096 x 4096 | Proved |
| T.87 equivalence | Per-sample modules A.1-A.23 equal a reference transcribed from the ITU-T T.87 C code | 18 checks, BITNESS 8-16 | Proved |
| Run coder | A.14-A.16 equal a step-by-step T.87 model | Line widths 4, 8, 37, 4096, 65535 | Proved |
| Bit stream | `bit_packer` outputs every bit in order, with stall | BITNESS 8-16 | Proved |
| Byte stream | `byte_stuffer` outputs every byte in order, stuffing removed, with stall. Proved in 4 parts that meet at the FIFOs: stage 1 writes each bit at its stream position, the two FIFOs keep order, stage 3 outputs that word stream in order. Each part's input rules are the guarantees of the part before it | BITNESS 8, 12, 16 | Proved |
| Stall margin | The `byte_stuffer` FIFO never overflows with `STALL_CUSHION_ENTRIES` = 5. With 4 it overflows, so 5 is the minimum | FIFO depths 6, 8, 16, 64 (64 in `openjls_top`) | Proved |
| Framer margin | The `jls_framer` payload buffer never overflows under output backpressure, with the `byte_stuffer` output timing that the `byte_stuffer` check proves | BITNESS 8-16, OUT_WIDTH 48, 64, 256, 1024 | Proved |
| Context forwarding | A context read gets the newest value written to that context, through the RAM or the bypass | BITNESS 8-16 | Proved |
| Datapath ranges | Context values, quantized gradients, error values and Golomb code lengths stay in the ranges the next module needs | BITNESS 8-16 | Proved |

## How results are qualified

- **Known-bad check per property.** Each property also runs on a copy with a bug put in on purpose (an inverted
  assert, a moved boundary in the reference, removed input rules). That run must fail. A property whose known-bad
  copy passes is not counted.
- **Input rules have a source.** A check may restrict the inputs only with a contract written in the RTL (PSL
  `assert` on module inputs) or with a fact that another check proves. Each rule in the scripts names its source.
- **Failures are replayed.** A formal failure counts only when NVC replays the trace on the original RTL and shows
  the same failure.
- **Bounded is reported as bounded.** A result that holds only for a fixed number of cycles shows as BOUNDED, not
  PROVED.
- **Abstractions are sound.** Where a module is removed to make a proof small, its outputs become free inputs. The
  free outputs include all real behaviour, so a proof with the module removed also holds with the real module.

## Assumptions and limits

- Two top-level facts are taken from the design and not proved by a check: two flushes are at least 4 cycles apart
  (an image has at least 4 pixels), and payload bytes reach the framer only between an image's start and its end
  (all payload comes from the image's pixels). The module checks that use them name them as assumptions.
- The top and framer image counts depend on each other. Each side uses only the other's past cycles, and both
  sides are proved.
- The `byte_stuffer` byte-order proof counts bit positions up to 2^30 - 1. Past 2^30 bits of coded data in one
  image (128 MB), the order of each bit stays proved, but the end-of-image position is not checked.
- The `byte_stuffer` FIFO proofs use a copy of the FIFO and RAM files with extra output ports that show the internal
  addresses and one RAM cell. The copies change no logic.
- The `byte_stuffer` last-word queue does not overflow because the top admits at most 3 images in flight. The
  `openjls_top` RTL-assert check proves that limit.
- The first cycle after power-up is not checked: the tool starts all registers at 0, real hardware does not.
- Proofs hold at the BITNESS values, image sizes and output widths listed above.

## Mutation equivalence

Mutation testing checks the test benches, not the RTL. For each mutant that no test detected, `Mutation/` builds
the original and the mutant side by side with the same inputs. A proof of equal outputs closes the mutant as
equivalent. A difference becomes a new directed test in the OSVVM test benches. All combinational survivors are
closed this way. A few sequential survivors, where a full proof did not finish, are classified by analysis with
bounded evidence. Mutation
equivalence is not in the release suite: it measures the tests, and some runs take hours.

## Layout

| Folder | Content |
|---|---|
| `Common/` | `flow.py` (paths, tool env, process runner), `prep.py` (makes RTL GHDL-synthesizable, turns input-only PSL contracts into assumes), `gen_harness.py`, `replay.py` (re-runs a formal trace in NVC) |
| `Properties/` | Properties of the RTL itself: `top_ctrl.py` (top control invariants), `cushion.py` (byte_stuffer FIFO never overflows at `STALL_CUSHION_ENTRIES`), `ag.py` (proves the input assumptions that `module_eq.py` uses), `t87_eq.py` + `t87_ref_pkg.vhd` (per-sample modules A.1-A.23 equal a T.87 reference transcribed from the C code in `Docs/Requirements.md`), `run_coder.py` + `run_coder.vhd` (A.14-A.16 run coder vs a T.87 model), `stream.py` (bit_packer and byte_stuffer keep every bit in order), `ctx_fwd.py` (a context read gets the newest value), `rtl_asserts.py` (each module's own asserts, and the module contracts on the top) |
| `Mutation/` | Mutant equivalence: `module_eq.py` (gold vs mutant per module), `top_ctx_eq.py` (2-copy top for context-RAM mutants), `exhaustive.py` (NVC exhaustive for small modules), `mutants.py` (mutant generator), `env/` (hand environments for sequential modules) |
| `Results/` | jsonl outputs (gitignored) |

## Tools

OSS CAD Suite 20261013 at the path in `OSS_CAD_SUITE`. Later nightlies break the GHDL plugin. NVC for trace
replay.

## Suite

`./build_run.sh` runs the release set (`run_suite.py`): top control invariants (BITNESS 8-16, W8 H4 and W4096 H4096),
byte_stuffer FIFO no-overflow at the `STALL_CUSHION_ENTRIES` in the RTL, the datapath range invariants, the
per-sample modules against the T.87 reference, the run coder and stream checks, context forwarding and the RTL
asserts, each with a known-bad check. It writes `Results/formal_results.tsv` and `Results/report_status.env`, which
`Verification/publish_reports.sh` turns into the Formal row of the verification report.

## Single checks

Each script lists its options (environment variables) in its docstring. Examples:

```sh
cd Properties && python3 top_ctrl.py                                  # control invariants, BITNESS 8
cd Properties && CUSH_FREE=1 python3 cushion.py                       # cushion 5 proves, 4 fails
cd Properties && python3 t87_eq.py "A.5 predictor"                    # T.87 reference, BITNESS 8-16
cd Properties && python3 ctx_fwd.py 8                                 # context forwarding, BITNESS 8
cd Properties && RA_BITS=8 python3 rtl_asserts.py openjls_top         # top asserts + module contracts
cd Mutation && FEQ_BITS=8 python3 module_eq.py byte_stuffer            # mutant equivalence, one module
```

## Rules for contributors

- Each new check needs a known-bad switch that must fail. The present switches: `TC_VACUITY=1`, `AG_VACUITY=1`,
  `FEQ_CONTRACTS=0`, `T87_LIVE=1`, `STREAM_LIVE=1`, `CF_LIVE=1`, `RA_LIVE=1`. `T87_LIVE=1` moves one boundary in
  the reference; pick a boundary that changes every output it feeds.
- A formal DIFF counts only if NVC replays it on the unprepped RTL and the stop is a real difference or a bound/range
  error, not an input-contract assert.
- Assumes come only from RTL contracts (`-- psl assert` on inputs) or from properties proved here; each assume in
  a hand environment (`Mutation/env/`) names its source.
- Use the smallest legal image (width 4, height 1-2) so a bounded search reaches image boundaries.
