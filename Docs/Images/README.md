# Images

Brand assets (`openjls-wordmark*`, `isentropic-*`) are generated from code, not
hand-drawn, and the generator does not live here. It is `gen_logo.py` in the
Isentropic repo, which emits the OpenJLS and Isentropic marks in one pass so the
two share cap height, baseline and padding — they appear side by side on the
datasheet cover, and generating them from separate scripts let the geometry
drift. Regenerate there, then copy the `openjls-*` and `isentropic-*` files from
that repo's `out/` into this directory. Do not edit them by hand.

The marks are not covered by the GPL grant on the sources; see the licensing
section of the top-level README.

`fmax_vs_size.png`, `util_vs_size.png`, `fmax_vs_bitness.png` and
`util_vs_bitness.png` come from the sweep tooling in `Scripts/`. `OpenJLS_arch.png` is authored by hand.
