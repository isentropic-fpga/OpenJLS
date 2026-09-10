# OSVVM verification audit — September 2026

The audit compared all OSVVM testbenches with their underlying RTL, retained
existing random tests, and added directed checks where uniform random inputs
or broad bins could miss boundaries. No production RTL was changed.

## Coverage improvements

| Area | Gap addressed and checks added |
| --- | --- |
| Parameter widths | 23 module benches now run at 8/12/16 bits, increasing the routine regression from 60 to 106 configurations. Existing nonstandard-range A.6/A.7 and A.9 tests remain. |
| A.1, A.3, A.4 | Walking input bits; one nonzero gradient at a time; quantization coverage separated by gradient lane, with threshold sweeps in each lane. |
| A.4.1, A.4.2 | Retained exhaustive/property checks; named cross bins and all 365 mapped-context bins. |
| A.5–A.7 | Equality, full-width arithmetic, clipping boundaries, both signs, and a separate zero-error bin. Existing combined A.6/A.7 checks now have a requirement ID. |
| A.10, A.11, A.11.1 | Every representable power-of-two k transition, mapping threshold neighbors, every run index and suffix k, normal/escape boundaries. A.11.1 uses an independent run-exponent table. |
| A.12, A.13 | Rescale parity and negative rounding, every bias value, and bias-update threshold neighbors. |
| A.14–A.16 | Width variants; A.15/A.16 randomized clock-enable pauses check all held outputs, Rb, and the interruption index before decrement. Reset is tested with clock enable low. |
| A.17–A.23 | Single-bit neighbor differences, zero errors, modulo boundaries, count parity, mapping thresholds, full representable A.22 error sweep, and coherent N/Nn combinations. A.22 defensive clamping has a separate assertion group. |
| A.11.2 | Complete output-word stability under stalls, reset while stalled, raw/suffix length boundaries, exact fills, and dirty unused suffix bits. |
| Context RAM | Distinct data at all 367 addresses, independent read/write addresses, forwarding followed by idle/write-only cycles, and EOI forwarding coverage. |
| Line buffer | All widths 4–16 at minimum/maximum test height, pauses at first/last columns, and noise on inactive inputs. |
| Byte stuffer | Every input length, all-zero/all-one payloads, and invalid garbage input beats, alongside the existing independent byte scoreboard. |
| Framer | Scoreboard checks exact last-byte position as well as byte values; complete pending output beats must hold under backpressure. |
| Top level | Bounded waits must actually observe the requested image completions. Output checks include stable data/keep/last/valid, contiguous aligned keep, and partial beats only at image end. |
| AXI wrappers | Watchdogs, stream-hold checks, independent AW/W arrival, delayed B/R acceptance, response stability, height clamp and byte-strobe cases. APPLY is modeled as an explicit stream abort. |
| Shared checking | Numeric conversions reject unknown DUT outputs before conversion can turn them into a misleading zero. |

## Report attribution

Requirement checks keep their `T87.*` and `OJLS.*` IDs. Auxiliary checks have
named alert groups such as `ResetRecovery`, `FlowControl`, `StreamProtocol`,
`CoverageClosure`, and `KnownOutputs`. Coverage bins and dimensions have
explicit names, including the AXI components' internal delay distributions.
Those distributions have weight zero; their counts describe stimulus timing,
not functional coverage closure. The console suppresses empty built-in `Default` rows; the vendored HTML
renderer still includes the empty row, with zero checks.

## Defects found in the verification flow

The AXI register test assumed 50 clocks were enough for an asynchronous
half-image send. Changed VC timing exposed queued pixels crossing APPLY and
corrupting the recovery image. The test now waits for the transmitter's
transaction completion before applying reset, then checks the recovered
stream against the golden bytes.

The shell runner could return success despite simulation errors: Tcl reading
commands from stdin continued after an error, and OSVVM did not default to
raising test-case failures. The runner now enables failure reporting and wraps
the whole Tcl build in `catch`, returning status 1 on failure. A deliberate
NVC simulation failure verified that the shell now returns status 1.

## Validation and limits

Run `bash Verification/OSVVM/build_run.sh` from the repository root to regenerate
the complete routine OSVVM regression, HTML reports, and NVC statement/branch
coverage. The expanded suite passes all 106 configurations. Its statement
coverage is 823/825 (99.8%); the two uncovered statements are the A.4
nonstandard-MAXVAL clamp and the framer header-ROM default arm. This percentage
is statement coverage, not exhaustive input, state, or branch coverage.

Five isolated fault-injection probes each passed with unmodified RTL and
failed after the targeted mutation: ignored run clock enable, decremented RI
index, ignored RAM read enable, changing packer data during stall, and an
unknown mode-selection output. These probes validated the new assertions;
mutated RTL was kept outside `Sources/` and is not part of the change.

This audit reran the routine OSVVM suite, including its embedded golden
images. It did not rerun the separate all-image golden-model regression,
post-synthesis verification, or timing characterization. Seeded random checks
remain finite, and independent reference code can still contain errors.
