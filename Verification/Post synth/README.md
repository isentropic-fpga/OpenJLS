# Post-synthesis

Runs two RTL test benches again on the gate-level netlist. Vivado synthesizes `openjls_top` and writes a
functional-simulation netlist (`synth_funcsim.tcl`); NVC simulates it.

| Script | Test | Configuration |
|---|---|---|
| `build_run_osvvm.sh` | The OSVVM top-level control-plane stress test (`tb_openjls_top_osvvm`) | BITNESS 8, 4096 × 4096, `OUT_WIDTH` 64 |
| `build_run_golden.sh` | The 8-bit golden-model images, byte-exact against CharLS | BITNESS 8, images up to `MAX_MP` |

## Requirements

- Vivado on `PATH` and `XILINX_VIVADO` set. The first run calls `nvc --install vivado` to compile the
  Vivado simulation libraries for NVC.
- The OSVVM libraries compiled by `../OSVVM/build_osvvm.sh`.
- For the golden run: the images of `../Golden model` (run `prepare_images.sh` there). The script builds
  CharLS and encodes the reference streams itself.

## Running

```bash
./build_run_osvvm.sh                         # synthesize, then simulate
./build_run_osvvm.sh --sim                   # reuse the netlist in Output/
./build_run_golden.sh                        # synthesize, then run all eligible images
./build_run_golden.sh --sim                  # reuse the 8-bit netlist
IMAGE=<stem> ./build_run_golden.sh --sim     # one image
```

Gate-level simulation is slow, so the golden run is capped at 0.05 MP per image by default (`MAX_MP`).
Other options: `NUMBER_OF_THREADS` (20), `NVC_HEAP` (2g), `PER_MEM` (2G per worker).

Netlists, logs and the `report_status*.env` summaries for the verification report go to `Output/`.
