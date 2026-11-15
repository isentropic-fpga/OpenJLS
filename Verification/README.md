# Verification

One folder per method. Each suite writes its own results and a `report_status.env` summary.

| Folder | Method | What it shows |
|---|---|---|
| `OSVVM/` | Constrained-random module and top-level test benches | Each module matches an independent model of its T.87 code segment; the top handles stall, backpressure and back-to-back images. Requirements tracked in [`verification_requirements.md`](../Docs/verification_requirements.md) |
| `Golden model/` | RTL simulation of the image corpus | Output is byte-exact against CharLS, per image and on streams with no reset |
| `T87 conformance/` | RTL simulation of the official T.87 test images | Output is byte-exact against the official coded streams |
| `Post synth/` | Gate-level simulation of the Vivado netlist | Synthesis keeps the behaviour of the RTL |
| `Formal/` | Property proofs over all input sequences | Control invariants, contracts, T.87 equivalence and stream order hold for all inputs |

Hardware-in-the-loop results come from the [OpenJLS-Demos](https://github.com/isentropic-fpga/OpenJLS-Demos) repository.

- `publish_reports.sh`: builds the verification report in `Docs/Reports/` from the results of all suites. Its
  header lists the suite runs it reads.
- `matrix_html.py`: renders the requirements matrix for the report landing page.
- `report_assets/`: style and theme script of the report site.
