# OpenJLS OSVVM verification

This directory holds the OSVVM testbench suite: one TB per RTL module
(`Modules/`) plus a top-level control-plane stress TB (`Top/`). This document
records how the suite is organised and which OSVVM facilities each testbench
relies on, with pointers into the actual files.

OSVVM is a pure-VHDL verification library (no SystemVerilog; runs on NVC). The
suite uses four parts of it: **AlertLog** for assertions with pass/fail
accounting, **RandomPkg** for constrained-random stimulus, **CoveragePkg** for
functional coverage, and **ScoreboardPkg** for order-checking streamed output.
Each is described below as it is used here.

---

## Layout

```
Verification/OSVVM/
├── build_run.sh        # main: full regression + HTML reports + NVC code coverage (needs tcl)
├── build_reports.sh    # full regression + HTML reports, no coverage instrumentation (needs tcl)
├── build_osvvm.sh      # one-time: compile vendored OSVVM into ./nvc-libs (for the post-synth flow)
├── OpenJls.pro         # OSVVM build script + source-of-truth file list (library/analyze/TestSuite/RunTest)
├── Support/tb_support_pkg.vhd   # shared helpers (clk_tick, apply_reset, end_of_test)
├── Modules/tb_*_osvvm.vhd       # one TB per module
└── Top/tb_openjls_top_osvvm.vhd # top-level stress TB
```

OSVVM itself lives under `ThirdParty/osvvm/`, and the OSVVM tcl script flow
under `ThirdParty/osvvm-scripts/`, both pinned to the same release. They are
not committed — `ThirdParty/fetch_third_party.sh` materializes them (the IP
itself needs no fetch; only reproducing the verification does). The routine
flow builds its own libraries; `./build_osvvm.sh` is a one-time prerequisite
only for the post-synth gate-level flow (`Verification/Post synth/`), which
reuses `./nvc-libs`.

## Dependencies

OSVVM publishes no dependency manifest; its scripts just `package require`
what they need. `ThirdParty/fetch_third_party.sh` pins everything tcl-side
in-tree, so after running it the suite needs only two system packages:

- **nvc** — the simulator (Arch: `nvc` from the AUR)
- **tcl** ≥ 8.6 — drives the OSVVM `.pro` flow (Arch: `sudo pacman -S tcl`)

The tcllib modules the scripts require (`fileutil`, `yaml`) are fetched into
`ThirdParty/tcllib/` and picked up via `TCLLIBPATH`; OSVVM and OSVVM-Scripts
land alongside. `build_osvvm.sh` and `build_reports.sh` check for the system
tools and print these hints if one is missing.

Optional: the HTML reports mark not-applicable cells with U+2E3B (⸻); if it
renders as a missing-glyph box, install a font that covers it (Arch:
`sudo pacman -S noto-fonts`).

## Running

`build_run.sh` is the main entry point — it runs every TB through the OSVVM
tcl/`.pro` flow, renders the HTML reports, and adds NVC statement/branch code
coverage:

```bash
./build_run.sh            # full regression + HTML reports + code coverage (needs tcl + nvc)
./build_reports.sh        # same regression + reports, without coverage instrumentation
```

For byte-stuffer timing optimizations, an additional comparison checks the
current RTL against a saved baseline on every cycle:

```bash
./compare_byte_stuffer.sh /absolute/path/to/baseline/byte_stuffer.vhd
```

This standalone NVC test needs no OSVVM libraries. It runs 2,000 images for
each combination of 32/48/64-bit input and randomized/continuously-ready
flow control, including full-width zero/one streams and reset during an
unfinished image. It compares valid output bytes, bytes per cycle, output
valid, almost-full, and flush-done timing. Invalid output lanes are ignored.
The regular OSVVM scoreboard remains the independent functional oracle.
Logs are written under `build/byte_stuffer_equivalence/`.

The regular prediction/error path has two additional arithmetic checks:
`tb_a6_a7_osvvm` checks the combined A.6/A.7 datapath against a sequential
integer reference at 8/12/16 bits and an 8-bit `MAX_VAL=200` configuration.
It sweeps every context bias, both signs, clipping boundaries, and randomized
pixels. `tb_a9_osvvm` exhausts every representable error at each pixel width
from 8 through 16, plus four odd-range configurations, checking both the
binary-range wiring shortcut and the general arithmetic fallback.

For the regular regression, `OpenJls.pro` drives the vendored tcl
scripts (`build` → `library`/`analyze`/`TestSuite`/`RunTest`), every TB's
`end_of_test` emits YAML via `EndOfTestReports`, and the scripts render it to
HTML. Outputs (all gitignored, in this directory):

- `index.html` — report index, linking each build's summary
- `OSVVM_OpenJls/OSVVM_OpenJls.html` — build summary with one row per test
  (suite, status, alert counts, functional coverage %, links)
- `OSVVM_OpenJls/reports/<suite>/<test>.html` — per-test detail: alert tree,
  every coverage model's bin table, scoreboard stats
- `OSVVM_OpenJls/reports/OSVVM_OpenJls_req.html` — requirements traceability
  (the `T87.*` / `OJLS.*` registry mapped to tests; `.csv` alongside)
- `NVC_CodeCoverage/html/index.html` — statement/branch coverage of `Sources/`
  (written by `build_run.sh` only — it is NVC's own report, since OSVVM has no
  NVC coverage vendor API, so its `OSVVM_OpenJls/CodeCoverage/` stays empty)
- `OSVVM_OpenJls/logs/` — per-test simulate transcripts; `VHDL_LIBS/` —
  compiled libraries (incremental between runs)

Note: tcl's `exec` treats any stderr output as a failure, hence the
`--stderr=error` global option in `OpenJls.pro`, which keeps NVC warnings on
stdout — analysis must stay warning-clean under this flow.

`RunTest Modules/tb_a5_osvvm.vhd` = analyze the file + simulate the entity
named like it + register the result under the current `TestSuite`. `OpenJls.pro`
is the single source of the analyzed-file list — to run one TB in isolation,
comment out the others' `Test` lines there (or pass generics via
`[generic NAME VALUE]`).

Configuration variants re-run a TB with non-default generics:
`Test Modules/tb_jls_framer_osvvm.vhd [generic OUT_WIDTH 40]` — reports and
`.covdb` files get a `_OUT_WIDTH_56` suffix. The framer and top TBs sweep
OUT_WIDTH around the 64-bit default (floor 48 / 56 / header-on-beat-boundary
200 / ceiling 1024) plus non-power-of-2 MAX dims this way; the byte stream
they check is configuration-invariant. The byte_stuffer TB sweeps IN_WIDTH
(= LIMIT) across the 8-/12-/16-bit configs (32 / 48 / 64).

The top TB also runs gate-level: `Verification/Post synth/build_run_osvvm.sh`
synthesizes openjls_top at the TB's default config (Vivado, from PATH) and
re-runs the full stress TB against the funcsim netlist under NVC
(`POST_SYNTH` generic). Release-gated, not part of the routine suite.

### Reading the output

A passing run ends with:

```
%%  205 ns    DONE   PASSED   tb_a5_osvvm  Passed: 209  Affirmations Checked: 209  Requirements Passed: 1 of 1
** Note: 205ns+0: tb_a5_osvvm: PASS
```

`Affirmations Checked` is the number of checks that ran; `Passed` is how many
passed. A failure looks like:

```
%%  211 ns    Alert  ERROR   <the message that was passed to the check>  Received : 20  Expected : 0
%% 2231 ns    DONE   FAILED   tb_..._osvvm  Total Error(s) = 1 ...
** Failure: 2231ns+0: tb_..._osvvm: FAIL
```

Each failing check prints an `Alert ERROR` line carrying its message, which
localises it. The run then reports `FAILED` and exits nonzero (what the
regression sweep keys on).

### Publishing reports (GitHub Pages)

`./publish_reports.sh` assembles the committed report site under
`Docs/Reports/` (served at `https://isentropic-fpga.github.io/OpenJLS/` by
`.github/workflows/pages.yml`). The OSVVM suite owns the report: the script
copies the OSVVM HTML tree (`osvvm/`) and the NVC coverage HTML (`coverage/`)
it generates, then stitches in the text-only suites — golden model and
post-synth — from the small `report_status.env` file each one drops in its
`Output/` when run. A suite that hasn't been run shows as "not run", so the
page degrades gracefully (post-synth in particular needs Vivado).

```bash
./build_run.sh                                    # OSVVM regression + coverage
( cd "../Golden model" && ./build_run.sh )        # optional: golden cross-check
( cd "../Post synth"   && ./build_run_osvvm.sh )  # optional: gate-level (needs Vivado)
./publish_reports.sh                              # regenerate Docs/Reports/
```

Refresh at milestones rather than every run — the report HTML is committed, so
each regeneration churns history. The deploy workflow only uploads the
committed `Docs/Reports/`; it never runs the suites (free on this public repo).
One-time: repo Settings → Pages → Source → "GitHub Actions".

---

## OSVVM facilities used in the suite

### AlertLog — assertions and pass/fail accounting

Checks are written as `AffirmIf(condition, "msg")` and
`AffirmIfEqual(actual, expected, "msg")` (overloaded for `integer`,
`std_logic_vector`, `unsigned`, …). A failing check raises an ERROR alert
carrying its message; `AffirmIfEqual` additionally logs `Received`/`Expected`.
Each TB names itself with `SetAlertLogName(...)` and calls
`SetLogEnable(PASSED, FALSE)` to suppress per-pass logging so only failures and
the summary print. The watchdog processes use `Alert("msg", FAILURE)` to fail on
timeout.

The PASS/FAIL decision lives in `Support/tb_support_pkg.vhd::end_of_test`:

```vhdl
errors := EndOfTestReports;   -- ReportAlerts + YAML for the script flow
if errors = 0 then
  report test_name & ": PASS";
else
  report test_name & ": FAIL" severity failure;
end if;
std.env.stop;
```

`EndOfTestReports` (ReportPkg) prints the same alert summary `ReportAlerts`
would, returns the total error count, and additionally writes the per-test
YAML (alerts, every registered coverage model, scoreboards) that
`build_reports.sh` turns into HTML. A failing `AffirmIf` raises an ERROR →
the count is nonzero → `end_of_test` reports FAIL. Reference:
`Modules/tb_a5_osvvm.vhd`.

### RandomPkg — constrained-random stimulus

Stimulus is generated from a `RandomPType` object seeded deterministically
(`rv.InitSeed(rv'instance_name)`), so every run — including a failing one — is
reproducible. The suite uses:

```vhdl
rv.RandInt(lo, hi)                  -- uniform integer in [lo, hi]
rv.RandSlv(WIDTH)                   -- random std_logic_vector
rv.RandUnsigned(WIDTH)              -- random unsigned
rv.DistValInt(((1, 20), (0, 80)))  -- weighted: 1 about 20%, 0 about 80%
```

`DistValInt` biases rare events so they occur often enough to test — e.g. the
all-zero run-mode case in `tb_a3_osvvm`, or extra backpressure in
`tb_byte_stuffer_osvvm`.

### CoveragePkg — functional coverage

Functional coverage records whether the stimulus exercised the interesting
*combinations*, not merely whether it passed. Each TB creates a coverage model
in OSVVM's global coverage store (`CoverageIDType` + `NewID` — the singleton
API), records hits during the run, and asserts the model is fully covered at
the end:

```vhdl
variable cov : CoverageIDType;
...
cov := NewID("branch");                            -- register in the singleton
AddBins(cov, GenBin(0, 2, 3));                     -- 3 bins for values 0,1,2
AddCross(cov, GenBin(0, 1, 2), GenBin(0, 2, 3));   -- 2 x 3 = 6 cross bins
...
ICover(cov, branch_value);                         -- record a hit
ICover(cov, (sign_value, region_value));           -- record a cross hit
...
exit when IsCovered(cov) and i > 200;              -- stop once every bin is hit
WriteBin(cov);                                     -- print the bin table
AffirmIf(IsCovered(cov), "coverage closed");       -- FAIL if any bin never hit
```

`IsCovered` is true once every bin has been hit (default at-least-once); the
random loops therefore run "until covered" rather than for a fixed count, and a
TB only passes if the stimulus reached every interesting case. Because the
models live in the global store (unlike the older `CovPType` protected type),
`EndOfTestReports` finds them automatically and they appear in the per-test
HTML coverage tables. Examples: `tb_a5_osvvm` (three branches), `tb_a6_osvvm`
(sign × saturation-region cross), `tb_a15_a16_osvvm` (terminal type, immediate
break, EOI, RUNindex range).

### Intelligent Coverage — coverage-driven randomization

Uniform random closes a sparse cross slowly: the last uncovered bin is hit
with probability 1/N per pass (the coupon-collector tail). Intelligent
Coverage inverts the loop — instead of randomizing stimulus and recording
what it happened to hit, ask the coverage model for a random *uncovered* bin
and drive exactly that scenario:

```vhdl
while not IsCovered(covSweep) loop
  pt := RandCovPoint(covSweep);   -- integer_vector: one value per cross axis
  -- drive the scenario encoded by pt(1), pt(2), pt(3) ...
  ICover(covSweep, pt);           -- mark it covered
end loop;
```

An N-bin cross closes in exactly N passes. The top TB's Phase A sweep uses
this over `(backpressure x input-stall x prelude)` — see
`Top/tb_openjls_top_osvvm.vhd`; its `WriteBin` table shows every bin with
`Count = 1`, the signature of coverage-driven selection.

### ScoreboardPkg_slv — order-checking for streams

Modules that emit a stream are checked with a scoreboard — a FIFO of expected
values the driver pushes and the monitor checks in order. Like coverage, the
scoreboard is registered in a global store so reports find it:

```vhdl
constant SB_ID : ScoreboardIDType := NewID("framer SB");
...
Push(SB_ID, expected_byte);          -- driver enqueues expected
Check(SB_ID, observed_byte);         -- monitor dequeues and compares
AffirmIf(IsEmpty(SB_ID), "scoreboard drained");
AffirmIfEqual(GetErrorCount(SB_ID), 0, "no mismatches");
```

A `Check` mismatch raises an alert and increments the error count; the
per-test HTML shows the scoreboard's check/error totals. Used by
`tb_jls_framer_osvvm` (expected stream = `header ++ payload ++ FF D9`) and
`tb_byte_stuffer_osvvm`.

### Requirements — spec-to-test traceability

A requirement is a named AlertLog ID with a passing goal, declared with
`GetReqID`; existing checks are attributed to it by passing the ID as the
first argument:

```vhdl
req := GetReqID("T87.A5", 200);                       -- declare, set goal
AffirmIfEqual(req, dut_out, reference(inputs), msg);  -- same check, attributed
```

A requirement fails its test if any attributed check fails **or** if it
collects fewer passing checks than its goal (`FailOnRequirementErrors`
defaults true) — so the goals double as anti-vacuity guards. Each goal here
is a guaranteed lower bound of the checks the TB performs by construction
(directed vectors plus the random loop's minimum-iteration exit guard): if a
future edit silently stops checking, the requirement — and the test — fails.

`EndOfTestReports` writes a `<tb>_req.yml` next to the other per-test YAML;
the build merges them into the **Requirements** tab of the build HTML and
into `reports/OSVVM_OpenJls_req.csv`, a requirement-by-requirement
traceability matrix (goal, passed count, errors) suitable for handing to a
customer or auditor. The registry below lists every ID. Reference:
`Modules/tb_a5_osvvm.vhd` (module pattern), `Top/tb_openjls_top_osvvm.vhd`
(monitor-based product requirements).

### tb_support_pkg — shared helpers

`Support/tb_support_pkg.vhd` provides `clk_tick(clk, n)` (wait n edges),
`apply_reset(clk, rst, n, active)` (pulse reset for n edges then release), and
`end_of_test(name)` (summary + PASS/FAIL + stop). Note: `apply_reset`'s trailing
edge re-latches whatever inputs are still driven, so the TBs idle their inputs
before it when checking a cleared output.

---

## Testbench structure

Combinational module TBs (e.g. `tb_a5_osvvm`) follow one shape: instantiate the
DUT; define a reference function transcribed from the **T.87 C model** in
`Docs/Requirements.md`; run directed corner cases, then a constrained-random sweep
checking each vector with `AffirmIfEqual(dut_output, reference(inputs))`; close
functional coverage; `end_of_test`.

Stateful module TBs (e.g. `tb_a15_a16_osvvm`, `tb_byte_stuffer_osvvm`) are
transaction-level: they drive a whole transaction (a run, an image), collect the
output, and compare it against the reference for that transaction — using a
scoreboard for streamed output and a clock plus `apply_reset`.

### Reference models come from the spec, not the RTL

Every reference is derived from the T.87 C model in `Docs/Requirements.md` (code
segments A.1–A.23), not from `Sources/*.vhd`, so an RTL bug cannot appear on both
sides and pass. Where T.87 leaves something open (e.g. the A.4.2 context map) the
TB checks the required properties (range, one-to-one, totality). Where the RTL
adds non-spec behaviour (e.g. the A.22 clamp) the TB tests only the domain T.87
reaches and asserts the skipped domain is genuinely unreachable per T.87.

### Reset coverage

Each stateful TB checks that asserting `iRst` drives the outputs/state to their
defined reset values, and that a reset injected mid-operation recovers cleanly
(the next transaction is correct from scratch). The scoreboard-based TBs use an
`sIgnore` signal so the monitor skips the aborted transaction's output (which is
never pushed to the scoreboard); the recovery transaction then runs normally. The
top-level TB injects mid-image reset end-to-end.

---

## Assertion conventions

The RTL under `Sources/` carries three kinds of assertions, each chosen by
what it checks — the mix is a policy, not an accident:

| What it checks | Mechanism | Why |
|---|---|---|
| Static parameter contract (generics) | VHDL `assert` at elaboration | Evaluated once, before time zero; stops bad instantiations in any tool |
| Invariant on a process variable | VHDL `assert` inside the process | PSL sees only signals; the in-place assert checks the variable at its point of truth |
| Temporal contract between signals | PSL (`-- psl …` comment form) | Evaluated every clock cycle in **every** simulation — module TBs, top TB, golden suite, conformance — regardless of stimulus |

The PSL contracts live next to the entity's output wiring (e.g.
`jls_framer`: AXIS `oValid` held until accepted, `oLast` only on a valid
beat; `byte_stuffer`: `oFlushDone` only on a valid beat and strictly one
cycle; `a15_a16`: run state clears one cycle after `iEoi`). They are written
as comments so synthesis sees nothing; NVC activates them with `--psl` and
`--exit-severity=error` makes a violation fatal (without it the violation
prints but the sim still exits 0). All four build flows set both flags.

NVC notes: the properties are kept to plain boolean expressions under
`always`/`never`/`next` (the portable PSL subset — the original GHDL flow
could not codegen `prev()`/`stable()` either, and staying inside it keeps
the contracts simulator-agnostic). With `--psl` active, any comment whose
first word is `psl` is *parsed as PSL*, so prose comments must not start
with that word.

---

## Requirements registry

Two ID families. `T87.*` is conformance: the RTL matches the reference derived
from the T.87 spec (clause numbers follow the project's module decomposition,
e.g. `A4.1`/`A11.2` are sub-blocks of clauses A.4/A.11). `OJLS.*` are product
requirements on top of the standard. Goals are the guaranteed minimum check
counts described above.

| ID | Requirement | Covered by | Goal |
|---|---|---|---:|
| `T87.A1` | Local gradient computation | `tb_a1_osvvm` | 200 |
| `T87.A3` | Run/regular mode selection | `tb_a3_osvvm` | 100 |
| `T87.A4` | Gradient quantization | `tb_a4_osvvm` | 200 |
| `T87.A4.1` | Quantized-gradient sign merging | `tb_a4_1_osvvm` | 729 |
| `T87.A4.2` | Context mapping Q (total, one-to-one, in range) | `tb_a4_2_osvvm` | 365 |
| `T87.A5` | Edge-detecting (MED) predictor | `tb_a5_osvvm` | 200 |
| `T87.A6` | Prediction correction | `tb_a6_osvvm` | 300 |
| `T87.A7` | Prediction error | `tb_a7_osvvm` | 200 |
| `T87.A9` | Modulo reduction | `tb_a9_osvvm` | 200 |
| `T87.A10` | Golomb parameter k | `tb_a10_osvvm` | 400 |
| `T87.A11` | Error mapping (incl. special case) | `tb_a11_osvvm` | 500 |
| `T87.A11.1` | Golomb encoding (incl. escape) | `tb_a11_1_osvvm` | 400 |
| `T87.A11.2` | Bit packing | `tb_a11_2_osvvm` | 100 |
| `T87.A12` | Context variables update (A, B, N) | `tb_a12_osvvm` | 300 |
| `T87.A13` | Bias update (B, C) | `tb_a13_osvvm` | 300 |
| `T87.A14` | Run-length determination | `tb_a14_osvvm` | 100 |
| `T87.A15-A16` | Run encoding | `tb_a15_a16_osvvm` | 100 |
| `T87.A17` | Run interruption type | `tb_a17_osvvm` | 100 |
| `T87.A18` | Run interruption prediction error | `tb_a18_osvvm` | 200 |
| `T87.A19` | Run interruption error computation | `tb_a19_osvvm` | 300 |
| `T87.A20` | Temp computation | `tb_a20_osvvm` | 50 |
| `T87.A21` | Map computation | `tb_a21_osvvm` | 400 |
| `T87.A22` | RI errval mapping | `tb_a22_osvvm` | 300 |
| `T87.A23` | Run interruption update | `tb_a23_osvvm` | 600 |
| `T87.H3` | Output byte-identical to the Annex H.3 golden stream under every Phase A stress | `tb_openjls_top_osvvm` | 57 |
| `OJLS.BackToBack` | Next image accepted while the previous one is still draining — no inter-image gap required | `tb_openjls_top_osvvm` | 3 |
| `OJLS.RIForward` | Run-interruption context forwarding (two RI updates to the same context one stage apart) emits the CharLS golden byte-for-byte | `tb_openjls_top_osvvm` | 40 |
| `OJLS.NoStallCompress` | With downstream ready, `oReady` never drops during a feed: the byte_stuffer buffer must not fill while compressing | `tb_openjls_top_osvvm` | 5000 |
| `OJLS.NoStallEOL` | …including across every line and image boundary | `tb_openjls_top_osvvm` | 100 |
| `OJLS.AxiStreamTransparent` | AXI4-Stream wrapper output is byte-identical to the golden (H.3 at BITNESS 8, CharLS-minted at BITNESS 12 with garbage on the unused TDATA bits) under clean, backpressured, input-stalled and mid-image-TLAST handshakes | `tb_openjls_axis_osvvm` | 285 |
| `OJLS.AxiLiteRegMap` | AXI4-Lite register file: RO identity/config read exact, WIDTH/HEIGHT reset defaults + read-write + clamp, partial-WSTRB merge, RO-write dropped, WO/unmapped read zero, STATUS TREADY mirror | `tb_openjls_axis_regs_osvvm` | 16 |
| `OJLS.AxiApplyReconfig` | Register-programmed dimensions + CTRL.APPLY reconfigure the core and encode the H.3 golden byte-exact | `tb_openjls_axis_regs_osvvm` | 57 |
| `OJLS.AxiAbortReencode` | CTRL.APPLY mid-image aborts the in-flight encode (whole-beat residue only) and the next image comes out byte-exact | `tb_openjls_axis_regs_osvvm` | 57 |

The infrastructure TBs (`tb_jls_framer`, `tb_byte_stuffer`, `tb_context_ram`,
`tb_line_buffer`) carry no requirement IDs: they verify implementation detail,
and their standard-facing behaviour is covered end-to-end by the golden suite
and `T87.H3`.

---

## References

- OSVVM documentation: <https://github.com/OSVVM/Documentation> (per-package user
  guides for AlertLogPkg, RandomPkg, CoveragePkg, ScoreboardPkg).
- Smallest worked examples in this suite: `Modules/tb_a5_osvvm.vhd`
  (combinational + coverage), `Modules/tb_a11_2_osvvm.vhd` (clocked + reset +
  stall), and `Modules/tb_jls_framer_osvvm.vhd` (driver/monitor/scoreboard).
