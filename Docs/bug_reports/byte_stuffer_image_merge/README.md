# byte_stuffer merges back-to-back images

**Status:** open. **Affects:** v1.3.2 (`f2947f7`) and `dev/area_perf`, which match each other on every output cycle. **Severity:** silent output corruption or a hang, with back-to-back images and no misuse.

## Symptom

When images are streamed back-to-back, part of image N+1's payload can be emitted inside image N's frame:

- **Silent:** bytes move across the boundary between two frames. `oLast` still fires once per image, so the sink sees well-formed frames whose payloads are wrong. Example: 16-bit 4×4 at full throughput, where image 2 is 88 B instead of 80 B and image 3 is 48 B instead of 56 B. Another: 12-bit 256×64, where image 1 is 13164 B instead of 13158 B.
- **Hang:** one EOI is lost. The framer then waits forever for the last image's footer and never asserts its `oLast`. Example: 16-bit 4×4 with 95 % valid and 30 % ready.

## Root cause

In `Sources/byte_stuffer.vhd`, `sSkidTaken` refills the stuff buffer from the skid whenever there is room:

```vhdl
sSkidTaken <= '1' when sSkidValid = '1'
                       and sStuffBufferBits <= to_unsigned(HOLD_BITS - FIFO_BITS, sStuffBufferBits'length)
                       and iReady = '1'
                       and sLastPending = '0' else
```

After image N's last word is refilled, `sStuffBufferLast = '1'`. If the bits still left in the buffer are at least 8, stage 3 doesn't set `sLastPending`. The refill condition can still hold, though, so image N+1's first word, already waiting in the skid, is appended to image N's tail. The final beat (`sLastPending`) only fires once fewer than 8 bits remain, which now happens inside image N+1. Two images share one `oFlushDone`, which means one framer EOI is lost. FF stuffing makes it likelier, since stuffed lanes carry 7 bits, so the residue drains slower.

## Reach

Measured with the repro below: 600 random cases, BITNESS 8–16, sizes from 4×1 to 256×64, three valid/ready loads, 4 seeds.

- 42 cases hit the merge, 3 of which hang.
- BITNESS 10, 12, 14 and 16. None at 8 in this sweep.
- Sizes from 4×2 to 256×64.
- Every load, including 100 % valid and 100 % ready.

Why the suites miss it: the golden flow resets between images, so it never streams back-to-back. `tb_openjls_top_osvvm` does stream back-to-back and byte-compares every frame, but only at BITNESS 8 with fixed images: the H.3 image, a 48×48 noise image and 4×1. None of those reach the trigger.

## Candidate fix

Hold the skid until the buffer's last word has left as the final beat:

```vhdl
                       and sLastPending = '0'
                       and sStuffBufferLast = '0' else
```

Checked only in a scratch copy:

- **CharLS:** all 600 cases byte-exact.
- **Timing:** cycle timing differs from the unfixed core in exactly the 42 merging cases and is identical in the other 558. The cost is a stall at an affected image boundary only.
- **Not yet done:** the full suites and synthesis/fmax on the fix.

## Repro

```bash
./run.sh                           # 16-bit 4x4, 100/100 valid/ready: silent corruption
./run.sh 16 4 4 20 95 30 2         # hang: oLast 19 of 20
./run.sh 12 256 64 3 100 100 4     # realistic size, silent corruption
```

Arguments are `BITNESS W H NIMG VALID_PCT READY_PCT SEED`. `tb_image_merge.vhd` streams NIMG images into `openjls_top`, dumps pixels and output bytes, and reports `MERGE` when the trigger fires. `check_dump.py` then splits the output at `oLast`, encodes each image with CharLS (`CHARLS_CLI` overrides the CLI path) and byte-compares per image.

## For the fix

- Add a regression that streams back-to-back images and byte-compares every frame against CharLS, across bitness, small sizes and backpressure. This TB is a starting point.
- Re-run the OSVVM, golden, post-synth and fmax flows; `sSkidTaken` feeds the FIFO read path.
