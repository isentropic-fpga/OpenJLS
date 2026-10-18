# Verification requirements

Requirement registry and traceability for the OSVVM suite in [`Verification/OSVVM`](../Verification/OSVVM).
Rules G1–G6 are defined in [`verification_guidelines.md`](verification_guidelines.md); coverage IDs carry the rule tag, and N/A reasons and other exceptions are in each TB's `Guidelines:` header.

## ID families
- `T87.*`: conformance. The RTL matches a reference derived from [T.87](Requirements.md). Clause numbers follow the module decomposition (`A4.1`, `A11.2` are sub-blocks of A.4, A.11).
- `OJLS.*`: OpenJLS product requirements on top of the standard.

Goal = guaranteed minimum check count per run (a TB that silently stops checking fails its requirement).
Each build writes the measured counts to `reports/OSVVM_OpenJls_req.csv`.

## Matrix
Status: ✓ met, N/A not applicable (reason in the TB header), **gap** open (see below). A column is ✓ when every sub-rule is met or N/A.

| ID | Requirement | Source | RTL | TB | Goal | G1 | G2 | G3 | G4 | G5 | G6 |
|---|---|---|---|---|---:|:-:|:-:|:-:|:-:|:-:|:-:|
| `T87.A1` | Local gradient computation | T.87 A.1 | [`A1_gradient_comp`](../Sources/A1_gradient_comp.vhd) | [`tb_a1_osvvm`](../Verification/OSVVM/Modules/tb_a1_osvvm.vhd) | 200 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A3` | Run/regular mode selection | T.87 A.3 | [`A3_mode_selection`](../Sources/A3_mode_selection.vhd) | [`tb_a3_osvvm`](../Verification/OSVVM/Modules/tb_a3_osvvm.vhd) | 100 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A4` | Gradient quantization | T.87 A.4 | [`A4_quantization_gradients`](../Sources/A4_quantization_gradients.vhd) | [`tb_a4_osvvm`](../Verification/OSVVM/Modules/tb_a4_osvvm.vhd) | 200 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A4.1` | Quantized-gradient sign merging | T.87 A.4.1 | [`A4_1_quant_gradient_merging`](../Sources/A4_1_quant_gradient_merging.vhd) | [`tb_a4_1_osvvm`](../Verification/OSVVM/Modules/tb_a4_1_osvvm.vhd) | 729 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A4.2` | Context mapping Q (total, one-to-one, in range) | T.87 A.4.2 | [`A4_2_Q_mapping`](../Sources/A4_2_Q_mapping.vhd) | [`tb_a4_2_osvvm`](../Verification/OSVVM/Modules/tb_a4_2_osvvm.vhd) | 365 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A5` | Edge-detecting (MED) predictor | T.87 A.5 | [`A5_edge_detecting_predictor`](../Sources/A5_edge_detecting_predictor.vhd) | [`tb_a5_osvvm`](../Verification/OSVVM/Modules/tb_a5_osvvm.vhd) | 200 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A6-A7` | Combined correction/error path | T.87 A.6-A.7 | [`A6_A7_prediction_error`](../Sources/A6_A7_prediction_error.vhd) | [`tb_a6_a7_osvvm`](../Verification/OSVVM/Modules/tb_a6_a7_osvvm.vhd) | 20000 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A6` | Prediction correction | T.87 A.6 | [`A6_prediction_correction`](../Sources/A6_prediction_correction.vhd) | [`tb_a6_osvvm`](../Verification/OSVVM/Modules/tb_a6_osvvm.vhd) | 300 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A7` | Prediction error | T.87 A.7 | [`A7_prediction_error`](../Sources/A7_prediction_error.vhd) | [`tb_a7_osvvm`](../Verification/OSVVM/Modules/tb_a7_osvvm.vhd) | 200 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A8.1` | Lossless reconstruction (Rx = Ix) | T.87 A.8.1 | [`A8_1_reconstructed_value`](../Sources/A8_1_reconstructed_value.vhd) | [`tb_a8_1_osvvm`](../Verification/OSVVM/Modules/tb_a8_1_osvvm.vhd) | 2^BITNESS | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A9` | Modulo reduction | T.87 A.9 | [`A9_modulo_reduction`](../Sources/A9_modulo_reduction.vhd) | [`tb_a9_osvvm`](../Verification/OSVVM/Modules/tb_a9_osvvm.vhd) | 200 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A10` | Golomb parameter k | T.87 A.10 | [`A10_compute_k`](../Sources/A10_compute_k.vhd) | [`tb_a10_osvvm`](../Verification/OSVVM/Modules/tb_a10_osvvm.vhd) | 400 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A11` | Error mapping (incl. special case) | T.87 A.11 | [`A11_error_mapping`](../Sources/A11_error_mapping.vhd) | [`tb_a11_osvvm`](../Verification/OSVVM/Modules/tb_a11_osvvm.vhd) | 500 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A11.1` | Golomb encoding, regular mode (incl. escape) | T.87 A.11.1 | [`A11_1_golomb_encoder`](../Sources/A11_1_golomb_encoder.vhd) | [`tb_a11_1_osvvm`](../Verification/OSVVM/Modules/tb_a11_1_osvvm.vhd) | 400 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A11.2` | Bit packing | T.87 A.11.2 | [`A11_2_bit_packer`](../Sources/A11_2_bit_packer.vhd) | [`tb_a11_2_osvvm`](../Verification/OSVVM/Modules/tb_a11_2_osvvm.vhd) | 100 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `T87.A12` | Context variables update (A, B, N) | T.87 A.12 | [`A12_variables_update`](../Sources/A12_variables_update.vhd) | [`tb_a12_osvvm`](../Verification/OSVVM/Modules/tb_a12_osvvm.vhd) | 300 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A13` | Bias update (B, C) | T.87 A.13 | [`A13_update_bias`](../Sources/A13_update_bias.vhd) | [`tb_a13_osvvm`](../Verification/OSVVM/Modules/tb_a13_osvvm.vhd) | 300 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A14` | Run-length determination | T.87 A.14 | [`A14_run_length_determination`](../Sources/A14_run_length_determination.vhd) | [`tb_a14_osvvm`](../Verification/OSVVM/Modules/tb_a14_osvvm.vhd) | 100 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A15-A16` | Run encoding | T.87 A.15-A.16 | [`A15_A16_encode_run`](../Sources/A15_A16_encode_run.vhd) | [`tb_a15_a16_osvvm`](../Verification/OSVVM/Modules/tb_a15_a16_osvvm.vhd) | 100 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `T87.A17` | Run interruption type | T.87 A.17 | [`A17_run_interruption_index`](../Sources/A17_run_interruption_index.vhd) | [`tb_a17_osvvm`](../Verification/OSVVM/Modules/tb_a17_osvvm.vhd) | 100 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A18` | Run interruption prediction error | T.87 A.18 | [`A18_run_interruption_prediction_error`](../Sources/A18_run_interruption_prediction_error.vhd) | [`tb_a18_osvvm`](../Verification/OSVVM/Modules/tb_a18_osvvm.vhd) | 200 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A19` | Run interruption error computation | T.87 A.19 | [`A19_run_interruption_error`](../Sources/A19_run_interruption_error.vhd) | [`tb_a19_osvvm`](../Verification/OSVVM/Modules/tb_a19_osvvm.vhd) | 300 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A20` | Temp computation | T.87 A.20 | [`A20_compute_temp`](../Sources/A20_compute_temp.vhd) | [`tb_a20_osvvm`](../Verification/OSVVM/Modules/tb_a20_osvvm.vhd) | 50 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A20.1` | Run interruption context (Q = RItype + 365) | T.87 A.20.1 | [`A20_1_run_context_index`](../Sources/A20_1_run_context_index.vhd) | [`tb_a20_1_osvvm`](../Verification/OSVVM/Modules/tb_a20_1_osvvm.vhd) | 4 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A20.2` | Golomb k from TEMP (shared A.10) | T.87 A.20.2 | [`A20_2_compute_k`](../Sources/A20_2_compute_k.vhd) | [`tb_a20_2_osvvm`](../Verification/OSVVM/Modules/tb_a20_2_osvvm.vhd) | 400 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A21` | Map computation | T.87 A.21 | [`A21_compute_map`](../Sources/A21_compute_map.vhd) | [`tb_a21_osvvm`](../Verification/OSVVM/Modules/tb_a21_osvvm.vhd) | 400 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A22` | RI errval mapping | T.87 A.22 | [`A22_errval_mapping`](../Sources/A22_errval_mapping.vhd) | [`tb_a22_osvvm`](../Verification/OSVVM/Modules/tb_a22_osvvm.vhd) | 300 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A22.1` | RI Golomb encoding, glimit = LIMIT − J[RUNindex] − 1 | T.87 A.22.1 | [`A11_1_golomb_encoder`](../Sources/A11_1_golomb_encoder.vhd) | [`tb_a11_1_osvvm`](../Verification/OSVVM/Modules/tb_a11_1_osvvm.vhd) | 192 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.A23` | Run interruption update | T.87 A.23 | [`A23_run_interruption_update`](../Sources/A23_run_interruption_update.vhd) | [`tb_a23_osvvm`](../Verification/OSVVM/Modules/tb_a23_osvvm.vhd) | 600 | ✓ | ✓ | ✓ | ✓ | N/A | ✓ |
| `T87.H3` | Output byte-identical to the Annex H.3 golden stream under every Phase A stress | T.87 H.3 | [`openjls_top`](../Sources/openjls_top.vhd) | [`tb_openjls_top_osvvm`](../Verification/OSVVM/Top/tb_openjls_top_osvvm.vhd) | 57 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `OJLS.BackToBack` | Next image accepted while the previous one is still draining — no inter-image gap required | OpenJLS | [`openjls_top`](../Sources/openjls_top.vhd) | [`tb_openjls_top_osvvm`](../Verification/OSVVM/Top/tb_openjls_top_osvvm.vhd) | 3 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `OJLS.RIForward` | Run-interruption context forwarding (two RI updates to the same context one stage apart) emits the CharLS golden byte-for-byte | OpenJLS | [`openjls_top`](../Sources/openjls_top.vhd) | [`tb_openjls_top_osvvm`](../Verification/OSVVM/Top/tb_openjls_top_osvvm.vhd) | 40 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `OJLS.NoStallCompress` | With downstream ready, `oReady` never drops during a feed: the byte_stuffer buffer must not fill while compressing | OpenJLS | [`openjls_top`](../Sources/openjls_top.vhd) | [`tb_openjls_top_osvvm`](../Verification/OSVVM/Top/tb_openjls_top_osvvm.vhd) | 5000 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `OJLS.NoStallEOL` | …including across every line and image boundary | OpenJLS | [`openjls_top`](../Sources/openjls_top.vhd) | [`tb_openjls_top_osvvm`](../Verification/OSVVM/Top/tb_openjls_top_osvvm.vhd) | 100 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `OJLS.AxiStreamTransparent` | AXI4-Stream wrapper output is byte-identical to the golden (H.3 at BITNESS 8, CharLS-minted at BITNESS 12 and 16, garbage on the unused TDATA bits at 12) under clean, backpressured, input-stalled and mid-image-TLAST handshakes, and after a mid-operation core reset | OpenJLS | [`openjls_axis`](../Sources/Xilinx/openjls_axis.vhd) | [`tb_openjls_axis_osvvm`](../Verification/OSVVM/Modules/tb_openjls_axis_osvvm.vhd) | 456 | ✓ | N/A | N/A | ✓ | ✓ | ✓ |
| `OJLS.AxiLiteRegMap` | AXI4-Lite register file: RO identity/config read exact, WIDTH/HEIGHT reset defaults + read-write + clamp, partial-WSTRB merge, RO-write dropped, WO/unmapped read zero, STATUS TREADY mirror | OpenJLS | [`openjls_axis_regs`](../Sources/Xilinx/openjls_axis_regs.vhd) | [`tb_openjls_axis_regs_osvvm`](../Verification/OSVVM/Modules/tb_openjls_axis_regs_osvvm.vhd) | 16 | ✓ | N/A | N/A | ✓ | ✓ | ✓ |
| `OJLS.AxiApplyReconfig` | Register-programmed dimensions + CTRL.APPLY reconfigure the core and encode the H.3 golden byte-exact | OpenJLS | [`openjls_axis_regs`](../Sources/Xilinx/openjls_axis_regs.vhd) | [`tb_openjls_axis_regs_osvvm`](../Verification/OSVVM/Modules/tb_openjls_axis_regs_osvvm.vhd) | 57 | ✓ | N/A | N/A | ✓ | ✓ | ✓ |
| `OJLS.AxiAbortReencode` | CTRL.APPLY mid-image aborts the in-flight encode (whole-beat residue only) and the next image comes out byte-exact | OpenJLS | [`openjls_axis_regs`](../Sources/Xilinx/openjls_axis_regs.vhd) | [`tb_openjls_axis_regs_osvvm`](../Verification/OSVVM/Modules/tb_openjls_axis_regs_osvvm.vhd) | 57 | ✓ | N/A | N/A | ✓ | ✓ | ✓ |
| `OJLS.LineBuffer` | Neighbour window a/b/c/d with T.87 border rules (first line, first/last column, 1-line images, width 4), across stalls and mid-image reset | OpenJLS | [`line_buffer`](../Sources/line_buffer.vhd) | [`tb_line_buffer_osvvm`](../Verification/OSVVM/Modules/tb_line_buffer_osvvm.vhd) | 9668 | ✓ | ✓ | N/A | ✓ | ✓ | ✓ |
| `OJLS.CtxRam` | Context RAM read: init value on first use per image (EOI/reset re-arm), stored value, same-cycle write forwarding | OpenJLS | [`context_ram`](../Sources/context_ram.vhd) | [`tb_context_ram_osvvm`](../Verification/OSVVM/Modules/tb_context_ram_osvvm.vhd) | 1322 | ✓ | ✓ | N/A | ✓ | ✓ | ✓ |
| `OJLS.ByteStuffer` | Bit packing to bytes with 0xFF → 0x00 stuffing and end-of-image flush, byte-exact against the model | OpenJLS | [`byte_stuffer`](../Sources/byte_stuffer.vhd) | [`tb_byte_stuffer_osvvm`](../Verification/OSVVM/Modules/tb_byte_stuffer_osvvm.vhd) | 2900 | ✓ | ✓ | N/A | ✓ | ✓ | ✓ |
| `OJLS.Framer` | JPEG-LS header, payload bytes and EOI marker framed into output beats, byte- and TLAST-exact | OpenJLS | [`jls_framer`](../Sources/jls_framer.vhd) | [`tb_jls_framer_osvvm`](../Verification/OSVVM/Modules/tb_jls_framer_osvvm.vhd) | 1600 | ✓ | ✓ | N/A | ✓ | ✓ | ✓ |

## Open gaps
None.

## Not tracked
- A.2, A.8 (and every NEAR > 0 path): lossy only, not implemented.
- Frame sizes above 65535 (T.87 LSE ID = 4): deferred to v1.1.
