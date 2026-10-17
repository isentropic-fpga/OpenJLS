# OpenJLS OSVVM suite

Rules: [`verification_guidelines.md`](../../Docs/verification_guidelines.md).
Requirements + status: [`verification_requirements.md`](../../Docs/verification_requirements.md).

## Layout
- `OpenJls.pro`: the only file list. Libraries, analyze order, every `Test` line and generic variant.
- `Modules/`, `Top/`: one TB per RTL module, plus the top control-plane stress TB.
- `Support/tb_support_pkg.vhd`: shared helpers (`checked_*`, `apply_reset`, `affirm_covered`, `add_value_bin`, H.3/B12/B16 vectors).
- `build_run.sh`: full regression + HTML reports + NVC code coverage. `build_reports.sh`: same, no coverage.
- `build_osvvm.sh`: one-time compile of OSVVM into `./nvc-libs`, needed only by `Verification/Post synth`.
- `cover_summary.py` / `cover_prune.py`: code-coverage misses and waivers.
- `compare_byte_stuffer.sh <abs baseline.vhd>`: cycle-exact byte_stuffer equivalence vs a saved baseline (no OSVVM).
- `publish_reports.sh`: rebuilds `Docs/Reports/` (OSVVM + coverage + golden/post-synth status). Run at milestones only, since the output is committed.

## Setup
`ThirdParty/fetch_third_party.sh` fetches OSVVM, OSVVM-Scripts and tcllib. System packages: `nvc` and `tcl` ≥ 8.6.

## Running
```bash
./build_run.sh          # all tests, sequential (OSVVM script flow)
```
- Outputs (gitignored): `OSVVM_OpenJls/OSVVM_OpenJls.html` (summary), `reports/<suite>/<test>.html`, `reports/OSVVM_OpenJls_req.{html,csv}`, `NVC_CodeCoverage/html/`, `logs/`.
- One TB: comment out the other `Test` lines in `OpenJls.pro`. A variant is added as `Test Modules/tb_x.vhd [generic NAME VALUE]`; its reports get a `_NAME_VALUE` suffix.
- Fail: an `Alert ERROR <msg>` line, then `DONE FAILED`, nonzero exit.

## Gotchas
- tcl `exec` treats any stderr output as a failure, so `OpenJls.pro` sets `--stderr=error` and analysis must stay warning-clean.
- PSL: every flow runs NVC with `--psl --exit-severity=error`. Stay in the `always`/`never`/`next` boolean subset. A prose comment whose first word is `psl` is parsed as PSL.
- Requirement goal = guaranteed minimum number of checks, so a TB that silently stops checking fails its requirement.
