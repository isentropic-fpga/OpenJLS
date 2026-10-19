# Verification guidelines

Rules for every OSVVM TB in [`Verification/OSVVM`](../Verification/OSVVM).
Each rule has a tag (`G<n>.<Name>`). TBs use it in their coverage IDs and header, so any report line traces back to a rule.
A rule that doesn't apply is marked N/A in the TB header, with a reason.

## Naming
- Requirement IDs: `T87.<segment>` for T.87 code segments and written requirements (`T87.A12`, `T87.A11.1`), or a range for a combined module (`T87.A15-A16`); `OJLS.<Name>` for OpenJLS-only behaviour (`OJLS.BackToBack`).
- Coverage models: `NewID("<tags> <axes>")`, e.g. `NewID("G4.Coding rescale x bSumSign")`. A model that serves several rules lists every tag it serves: `NewID("G4.Branch G2.MinMax Qi")`.
- Bins: `axis=value` joined by ` / `; named corners use the rule's wording (`N=RESET`, `k=0`, `Ra=Rb`).
- TB header: license, a one-line description, a note only where the TB is non-obvious, then a `Guidelines:` block listing only the rules that don't apply, one line per rule: `N/A: <reason>`. A group line (`G4 other  N/A: ...`) or a partial one (`G4.Config  BITNESS N/A: ...`) is fine; code left uncovered is `G6.Code  N/A: <reason>`.
- A rule not listed is met by a model with its tag. G1 is met by the requirement IDs the TB registers, G2.Range and G2.Assert in the RTL, G2.Checked in the TB code, G4.Config generic variants in the `.pro`.

## G1. Requirements and golden model
- **G1.Req** Every requirement in [`Requirements.md`](Requirements.md) implemented in `Sources/` has a `T87.*` requirement with a goal in an OSVVM TB. LOSSY ONLY segments (A.2, A.8) are excluded. Registry and status: [`verification_requirements.md`](verification_requirements.md).
- **G1.Golden** Golden = sequential VHDL transcription of the T.87 C code with NEAR = 0: integers, same statements, order and names, no RTL packages.
- **G1.Property** Written requirements without C code (A.4.1, A.4.2, A.8.1, A.11.1/2, A.20.1/2, A.22.1): check properties (range, one-to-one, totality).
- **G1.Ojls** Non-spec RTL behaviour (clamps, saturation, AXI, stall/flow control) gets its own `OJLS.*` ID, never counted as T.87.

## G2. Overflow / underflow
- **G2.Range** Every arithmetic signal/variable: legal range commented at its declaration, for worst-case generics (BITNESS = 16).
- **G2.Assert** RTL asserts that range (`assert` for variables, PSL `never` for clocked signals); none where the legal range is the full type range.
- **G2.Postponed** Combinational signals and outputs: `postponed assert is_x(x) or (<range>)`. Checked once per time step after deltas settle, so no glitch false alarms; synthesis ignores it.
- **G2.MinMax** TB drives each node to its min and max, as named coverage bins.
- **G2.Clamp** Accumulators (A, B, C, N, Nn, RUNindex) driven to their clamp/reset point and one step past.
- **G2.Checked** Read outputs with `checked_integer` / `checked_bit` (X/U never passes).

## G3. Type conversions
- **G3.Signed** unsigned → signed: `signed('0' & x)`, never `signed(x)`.
- **G3.Resize** Widen with `resize`; narrow only with a proven range and an assert.
- **G3.Stim** Stimulus includes source MSB set and most negative value, as coverage bins.

## G4. Corner cases
Each one is a named coverage bin; TBs close on `IsCovered`.
- **G4.Edge** First line (Rb = Rc = Rd = 0), first column (Ra = Rb), last column (Rd = Rb), 1-line image, width = 4.
- **G4.Run** Run ending at end of line, RUNindex 0 and 31, both RItype values.
- **G4.Coding** k = 0 and max, escape code, A.11 special case, N = RESET, C at MIN_C/MAX_C.
- **G4.Config** BITNESS 8 and 16; image width and height at 4/1 and at `MAX_IMAGE_WIDTH`/`MAX_IMAGE_HEIGHT`, with those generics set small in the TB.
- **G4.Branch** Every branch of the C code segment is a bin (sign, region, clause), when no corner above names it.
- **G4.Stream** Back-to-back images, output backpressure, input stall, context RAM forwarding hit/miss, read on the EOI cycle.

## G5. Reset recovery (stateful modules)
- **G5.Init** Reset from any state returns the module to its initial condition: outputs, counters, FSMs, context memories.
- **G5.States** Reset is asserted in every FSM state / pipeline phase, as coverage bins.
- **G5.Replay** After reset, the next transaction matches a golden run from power-up.
- **G5.Discard** Output of the aborted transaction is ignored, never pushed to the scoreboard.

## G6. Done
- **G6.Clean** Zero errors, all requirement goals met, all coverage `IsCovered`.
- **G6.Header** Every rule has a model with its tag or an N/A line in the header, and the requirement's row in [`verification_requirements.md`](verification_requirements.md) shows no gap.
- **G6.Code** Code coverage reviewed; uncovered lines covered, or justified on the TB's G6.Code line.
