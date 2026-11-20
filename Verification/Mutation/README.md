# Mutation

Checks the verification, not the RTL. Each mutant changes one line of `Sources/`: an operator (std) or a literal,
slice or width (lit). The suite passes when the verification catches every mutant, or when `equivalent.tsv` lists
it with the reason no output can change.

`mutants.py` does not generate mutants that cannot reach an output, whatever the tests do:

- package constants that the design uses only as generic defaults, which every instantiation overrides;
- constants fixed by the pipeline structure (context count, images in flight, stall cushion) and the burst depth;
- functions that only simulation asserts call;
- the range bounds of generics, which only accept or reject a configuration at elaboration;
- a shift by one of a declared range: the width stays the same, so the object is either used whole (no change) or
  sliced at absolute bits (any simulation fails).

## Run

`./build_run.sh` (or `../run_all.sh`, which runs it after the other suites). It needs a passing OSVVM, golden and
formal run on the current RTL, because it reuses their libraries, image list and check timings.

Each mutant goes through these stages, cheapest first, and stops at the first one that catches it:

1. OSVVM: the test benches of the mutated module, then the top and AXI test benches.
2. Golden: a sample of the corpus vs CharLS (small images at every depth, boundary images, no-reset streams and
   random streams).
3. Formal: every release check whose generated files the mutant changes. A check catches the mutant if it is
   disproved.

A mutant that does not compile is not counted. A test that times out counts as a catch. The results go to
`Results/mutation_results.tsv` and `Results/report_status.env`, which `../publish_reports.sh` turns into the
Mutation row of the verification report.

The cache ignores comments and layout. A caught mutant, or a survivor that `equivalent.tsv` lists, keeps its result
while its own file is unchanged; any other survivor reruns on any change to the RTL or the verification. A test
bench edit therefore does not recheck the mutants it caught before: run with `RERUN=1` after such an edit, and
before a release.
Options: `RERUN=1` (ignore the cache), `MUT_ONLY=stem,...` (only these files), `MUT_THREADS` (20), `MUT_WORK`.

## Survivors

A mutant ID (`stem:hash`) stays the same when other lines of the file change. For a survivor:

- If a stimulus can show the change, add a directed test to the suite that should have caught it.
- If no output can change, add the mutant to `equivalent.tsv` with the evidence (`id`, `file`, `line`, `mutant`,
  `reason`). Prefer a proof from `classify/`.

| File | Content |
|---|---|
| `mutants.py` | Mutant generator and stable IDs |
| `run.py` | The suite |
| `formal_check.py` | One formal release check on a mutated source tree; the change filter |
| `equivalent.tsv` | Survivors that cannot change an output, with the reason |
| `classify/module_eq.py` | Formal equivalence of gold and mutant, per module as the top instantiates it |
| `classify/houdini.py` | Lockstep helper invariants for k-induction of sequential mutants |
| `classify/top_ctx_eq.py` | Two-copy top for context RAM mutants |
| `classify/exhaustive.py` | Exhaustive NVC simulation of small modules |
| `classify/miter.py`, `classify/tb_miter.vhd` | Gold and mutant tops side by side on random segments (evidence, not proof) |
| `classify/env/`, `classify/hd/` | Hand environments for sequential modules; extra relation candidates for `houdini.py` |
| `postsynth_faults.py` | Faults in the post-synth golden flow, which must fail on each |
