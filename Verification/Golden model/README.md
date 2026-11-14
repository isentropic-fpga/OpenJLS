# Golden model

Encodes every corpus image with [CharLS](https://github.com/team-charls/charls) and with the RTL under NVC,
and compares the two streams byte for byte. CharLS is used only after it reproduces the official T.87 vectors
(`../T87 conformance/charls_gate.sh`). The corpus is described in the Verification section of the top-level
README.

The flow has three phases:
- **Per image:** each image in `Images/` is encoded from reset (`tb_openjls_golden.vhd`).
- **Same-size streams:** each set in `Images_stream/` goes through one core with no reset between images
  (`tb_openjls_golden_stream.vhd`).
- **Random streams:** 1500 streams with random image size, BITNESS, `OUT_WIDTH`, input valid and output
  ready (`random_stream.py`). The seeds come from a hash of the RTL, so each RTL version gets new streams.
  `random_stream_seeds.txt` lists seeds that always run.

## Running

```bash
./prepare_images.sh           # one time: downloads the public sets and generates the probes
NUMBER_OF_THREADS=20 ./build_run.sh
```

Options (environment variables, see the header of `build_run.sh`):

| Variable | Default | Effect |
|---|---|---|
| `NUMBER_OF_THREADS` | 1 | Parallel simulations |
| `MAX_MP` | 0.5 | Skip images larger than this, in megapixels |
| `STREAM` | 1 | `0` skips the same-size and random streams |
| `RANDOM_RUNS` | 1500 | Number of random streams |
| `RERUN` | 0 | `1` runs all images again; otherwise images that passed with the same RTL and tools are skipped |
| `NVC_HEAP` | | NVC heap size; heap × threads must fit in RAM |

`prepare_images.sh --no-fetch` uses the images already in `Images/`. Images of your own, in any format, can
go into `Images/`; the script converts them to grayscale PGM.

## Results

- `Output/golden_image_results.tsv`: one row per image and stream.
- `Output/report_status.env`: the summary for the verification report. A result from an older RTL never
  counts as a pass, so a partial rerun shows `STATUS=PARTIAL`.
- `Output/logs/`: one log per simulation.
