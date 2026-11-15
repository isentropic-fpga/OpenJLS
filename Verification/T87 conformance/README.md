# T.87 conformance

Encodes the official ITU-T T.87 test images with the RTL and compares the output byte for byte with the
official coded streams:

| Input | Reference | BITNESS |
|---|---|---|
| `TEST16.PGM` | `T16E0.JLS` | 12 |
| `TEST8R/G/B.PGM` | the three scans of `T8C0E0.JLS`, split into one stream each by `t87_split.py` | 8 |

The golden-model flow also uses these vectors to qualify CharLS: `charls_gate.sh` fails the run if CharLS
does not reproduce them.

## Running

```bash
./fetch_reference_images.sh   # one time: downloads the T.87 package into "Reference Images/"
./build_run.sh                # PASS/FAIL per vector, nonzero exit on a failure
```

The download and every CharLS gate check the files against `reference_images.sha256`. Outputs and logs go to `Output/`.
