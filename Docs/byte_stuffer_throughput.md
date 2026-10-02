# Byte-stuffer throughput and adversarial verification

The four-lane stuffer can backpressure even with its downstream continuously
ready. A direct RTL test reproduces this with repeated legal 64-bit regular
Golomb escape words: 4,096 input words cause 4,481 stalled input cycles with
the original 64-entry FIFO. This is a legal codeword-level sequence, not an
image proven to produce that sequence through adaptive context updates.

The new `FULL_RATE_STUFFER=1` configuration removes the stuffer's dependence
on average code length, including the previously separate image-terminal
cycle. Existing configurations default to `FULL_RATE_STUFFER=0` and retain
four-lane throughput. The option is exposed by the native core and both
Xilinx AXI wrappers.

For 16-bit camera input, use:

```vhdl
generic map (
  BITNESS          => 16,
  OUT_WIDTH        => 128,
  FULL_RATE_STUFFER => 1
)
```

The receiver must sustain the output rate. No finite buffer can guarantee
uninterrupted camera acceptance under arbitrarily long output backpressure.
The rate argument below is for the stuffer with its `iReady` continuously
high; it is not a formal proof of every other core stage or every possible
image-boundary/output-bandwidth combination.

## Deterministic service bound

JPEG-LS inserts a zero **bit**, not a whole byte, after an FF payload byte.
A byte starting with that stuffed zero cannot itself be FF. Therefore, among
`N` output bytes, at most `ceil(N/2)` are stuffed, including an incoming FF
state. Those lanes consume at least `8*N - ceil(N/2)` raw bits.

| Pixel depth | LIMIT / FIFO bits | Payload lanes | Minimum raw bits consumed with enough data | Reserved terminal lane | Stuffer output | Minimum output satisfying the framer's lane-width assertion |
|---|---:|---:|---:|---:|---:|---:|
| 8 | 32 | 5 | 37 | 1 | 48 bits | 56 bits |
| 12 | 48 | 7 | 52 | 1 | 64 bits | 72 bits |
| 16 | 64 | 9 | 67 | 1 | 80 bits | 88 bits |

128-bit external output is the tested full-rate core configuration. The last
column is an interface constraint, not a bandwidth guarantee for arbitrary
rates of tiny images and their 27-byte framing overhead.

After a ready cycle, full-rate mode retains fewer than eight raw bits. With
at most seven old bits and one FIFO word, its payload lanes either consume
all complete output bytes or leave at most a sub-byte residue. Thus the next
FIFO word can be accepted on the next cycle, regardless of the bit pattern.
Only the sub-byte residue is relevant; the implementation stores an
eight-bit residual field and zeroes the unused holding-register bits.

One additional byte lane emits terminal padding or a dangling stuffed zero
on the final payload beat. Without it, even a stuffer that sustains one FIFO
word per cycle can accumulate a cycle of backlog per frame. Consecutive EOI
beats are legal when queued short images drain; EOI qualifies each valid
beat and is not an edge-detected event.

Full-rate output formatting has an additional pipeline register. Payload,
terminal residue, and the EOI flag travel together; the following stage appends
the padding byte. This adds one cycle of latency but does not consume an extra
service cycle at EOI. The top-level framer reserves an extra input beat in its
stall margin for this additional in-flight cycle. Standalone users of the
wider stuffer must likewise allow two cycles of in-flight output after ready
is withdrawn; the four-lane interface timing remains unchanged.

The layout enumeration happens at elaboration. Runtime candidates use fixed
slices, fixed thresholds, and independent predicates, preserving the parallel
four-lane implementation strategy. There is no serial selected-byte chain.

## Reproduced tests

`Verification/OSVVM/check_byte_stuffer_throughput.sh` runs 32/48/64-bit inputs
at four lanes and at 6/8/10 lanes, with continuously ready and randomly paused
outputs. Every output byte and image boundary is checked against a serial
bit-stream model independent of the layout implementation.

For each configuration it feeds 4,096 words each of zeros, ones, legal Golomb
escape words, and random variable-length words. It then sends 1,024 consecutive
four-word frames for each of three patterns: zeros, ones, and variable-length
ones. No wait is inserted between frames; the latter also exercises two-write
flushes. All full-rate continuously-ready cases must have **zero stalls**.
Paused-output cases must retain correct bytes and image boundaries.

The original 64-bit/four-lane implementation stalls 3,980 cycles for the zero
stream, 6,127 for the all-one stream, and 4,481 for the escape stream. Even the
32-bit/four-lane stuffer stalls for arbitrary full-width all-one input because
stuffing lowers its raw-bit service rate. Such arbitrary words need not be
reachable as a sustained image encoding.

The uninterrupted-frame test exposed two additional original boundary defects:

* Final-word lengths were held in a separate queue only three entries deep.
  Several short images could overflow it while the 64-entry data FIFO still
  had room. Length metadata now travels in the same FIFO entry as its data.
* A following image could be refilled while the preceding final word still
  had eight bits left. Refill now waits until that image is finished.

The existing six cycle-equivalence runs still pass against `ecdd0670666100e705a7e17b5bea8ec5dcbcefaa`
RTL in four-lane mode: 2,000 images each at 32/48/64 bits with and without
random stalls. Those serialized-image tests do not exercise the newly fixed
continuous-frame boundary cases.

## Camera-image search

28 additional 16-bit images were tested on the original four-lane path:
checkerboards, horizontal/vertical stripes, and sparse spikes at levels
16384/32768/49152; eight random seeds; and eight training/shock seeds.
Every image matched CharLS and had zero internal input stalls. No camera
image causing this bottleneck was found in this search.

The old 0/65535 patterns are weak large-error probes: modulo reduction can
turn an error of 65535 into -1. `gen_stress.py --level 32768` changes the
pattern amplitude while retaining a 65535 PGM maximum. The new `shock`
pattern trains on small values and then adds half-range jumps.

The upstream CharLS CLI could not encode the half-range checkerboard because
its estimated destination buffer was too small. The golden runner now uses
the same CharLS codec through a small PGM helper with a LIMIT-based buffer.
It still first checks byte equality against the official T16E0 reference.

Reproduce the image set with `Verification/Golden model/prepare_images.sh`.
For just these 28 images, run:

```bash
IMAGE_FILTER='stuffer-probe-*' NUMBER_OF_THREADS=4 \
  bash 'Verification/Golden model/build_run.sh'
OUT_WIDTH=128 FULL_RATE_STUFFER=1 IMAGE_FILTER='stuffer-probe-*' \
  NUMBER_OF_THREADS=4 bash 'Verification/Golden model/build_run.sh'
```

The OSVVM suite includes the wider lanes, terminal-lane coverage, reset,
random backpressure, and a full-rate 128-bit-output core configuration.
The standalone rate regression covers continuous word traffic and queued
frame boundaries beyond the original serialized-image tests.

## Implementation timing

Routed timing is measured with `Scripts/benchmark_byte_stuffer.tcl`, Vivado
2025.2, `xczu7eg-fbvb900-1-e`, and the same overconstrained out-of-context flow
used for the earlier optimization. These are implementation estimates,
not hardware measurements. Increasing lane count trades logic for guaranteed
bits per cycle; it does not by itself guarantee an unchanged maximum clock.

Final routed comparison (64-bit input, depth-16 FIFO, 2.000 ns constraint):

| Implementation | Routed WNS | Estimated fmax | LUTs | Flip-flops |
|---|---:|---:|---:|---:|
| Original four-lane RTL | -1.035 ns | 329.49 MHz | 2,174 | 586 |
| Full-rate 9 payload + 1 terminal lane, pipelined formatter | -2.330 ns | 230.95 MHz | 2,924 | 650 |

Neither isolated depth-16 implementation used BRAM. The stress tests use
64-entry FIFOs, matching the core. These measurements do not establish a
final full-core clock frequency. Full-rate mode costs about 34.5% more LUTs
and has a 29.9% lower isolated frequency estimate; it is **not** a demonstrated
zero-clock-cost upgrade. Compatibility mode remains the default. The extra
formatter register improves the full-rate implementation's clock estimate
from 204.88 MHz to 230.95 MHz while preserving one input word per cycle.

To reproduce the matched comparison, save the baseline from commit
`ecdd0670666100e705a7e17b5bea8ec5dcbcefaa`, and run Vivado from separate scratch
directories. The benchmark's sixth argument selects the lane count:

```bash
# Substitute absolute paths; run each command in its own output directory.
vivado -mode batch -source /path/to/OpenJLS/Scripts/benchmark_byte_stuffer.tcl \
  -tclargs /path/to/baseline.vhd byte_stuffer 64 2.0 /path/to/OpenJLS/Sources 4
vivado -mode batch -source /path/to/OpenJLS/Scripts/benchmark_byte_stuffer.tcl \
  -tclargs /path/to/OpenJLS/Sources/byte_stuffer.vhd byte_stuffer 64 2.0 /path/to/OpenJLS/Sources 10
```

Final validation on 2026-09-13:

* All 110 OSVVM configurations passed, including full-rate output and reset /
  backpressure cases. Terminal-lane coverage is exercised explicitly.
* All 12 standalone throughput configurations passed: 1,828,712 output bytes
  checked, including 3,072 uninterrupted short frames per configuration.
  Full-rate continuously-ready configurations had zero input stalls.
* All six serialized-image cycle-equivalence runs passed: 1,241,004 cycles
  and 2,382,118 bytes matched the original four-lane RTL.
* All 231 eligible CharLS images passed with `OUT_WIDTH=128` and
  `FULL_RATE_STUFFER=1`, including the 28 new probes. Every tested image had
  zero internal input stalls. 84 larger images were skipped by the existing
  0.5-megapixel limit.
* All three packaged IPs were regenerated, passed Vivado integrity checks,
  and their source copies match the working RTL.

The logs and routed reports from this run are under `build/stuffer_stress/`;
the standalone per-configuration logs are in `build/byte_stuffer_throughput/`.
