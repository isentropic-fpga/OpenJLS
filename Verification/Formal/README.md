# Formal verification

Formal checks of the OpenJLS RTL with GHDL + Yosys + SymbiYosys. A formal tool explores every input sequence up to a
depth (BMC) or proves a property for all depths (PDR), instead of running chosen tests.

## Layout

| Folder | Content |
|---|---|
| `Common/` | `flow.py` (paths, tool env, process runner), `prep.py` (makes RTL GHDL-synthesizable, turns input-only PSL contracts into assumes), `gen_harness.py`, `replay.py` (re-runs a formal trace in NVC) |
| `Properties/` | Properties of the RTL itself: `top_ctrl.py` (top control invariants), `cushion.py` (byte_stuffer FIFO never overflows at `STALL_CUSHION_ENTRIES`), `ag.py` (proves the input assumptions that `module_eq.py` uses) |
| `Mutation/` | Mutant equivalence: `module_eq.py` (gold vs mutant per module), `top_ctx_eq.py` (2-copy top for context-RAM mutants), `exhaustive.py` (NVC exhaustive for small modules), `mutants.py` (mutant generator), `env/` (hand environments for sequential modules) |
| `Results/` | jsonl outputs (gitignored) |

## Tools

OSS CAD Suite 20261013 at `~/Tools/oss-cad-suite` (override with `OSS_CAD_SUITE`). Later nightlies break the GHDL
plugin. NVC for trace replay.

## Suite

`./build_run.sh` runs the release set (`run_suite.py`): top control invariants (BITNESS 8-16, W8 H4 and W4096 H4096),
byte_stuffer FIFO no-overflow at the `STALL_CUSHION_ENTRIES` in the RTL, and the datapath range invariants, each with a
live check. About 20 s. It writes `Results/formal_results.tsv` and `Results/report_status.env`, which
`Verification/OSVVM/publish_reports.sh` turns into the Formal row of the verification report.

Mutation equivalence is not in the suite: it measures the tests, not the RTL, and some runs take hours.

## Single checks

Each script lists its options (environment variables) in its docstring. Examples:

```sh
cd Properties && python3 top_ctrl.py                                  # control invariants, BITNESS 8
cd Properties && CUSH_FREE=1 python3 cushion.py                       # cushion 5 proves, 4 fails
cd Mutation && FEQ_BITS=8 FEQ_ONLY=266#lit191 python3 module_eq.py byte_stuffer
```

## Rules

- A PASS counts only with a live check: every flow has a known-bad case or a vacuity switch (`TC_VACUITY=1`,
  `AG_VACUITY=1`, `FEQ_CONTRACTS=0`), and it must fail.
- A formal DIFF counts only if NVC replays it on the unprepped RTL and the stop is a real difference or a bound/range
  error, not an input-contract assert.
- Assumes come only from RTL contracts (`-- psl assert` on inputs) or from properties proved here; each env assume names its source.
- Mutant IDs (`LINE#kindN`) are list indices; they shift when the source changes. List them again before `FEQ_ONLY`.
- Use the smallest legal image (width 4, height 1-2) so a bounded search reaches image boundaries.
