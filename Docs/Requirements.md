# Requirements

Every code segment and written requirement below was taken **verbatim from ITU-T T.87 (ISO/IEC 14495-1)**. RTL files under [`Sources`](../Sources) are named after the code segment or written requirement they implement (e.g. `A4_quantization_gradients.vhd` implements Code segment A.4, `A6_A7_prediction_error.vhd` implements A.6 and A.7); the sections after the procedures are implemented by `line_buffer`, `context_ram`, `byte_stuffer` and `jls_framer`. Written requirements are labelled, in this project, as a child of the code segment that originated them (e.g. `A.4.1` under `A.4`) — an organizational choice, not part of T.87.

# Procedure

## Context determination

### Code segment A.1 – Local gradient computation for context determination

```c
D1 = Rd – Rb;
D2 = Rb – Rc;
D3 = Rc – Ra;
```

### Code segment A.2 – Mode selection procedure (LOSSY ONLY)

```c
if ((abs(D1) <= NEAR) && (abs(D2) <= NEAR) && (abs(D3) <= NEAR))
  goto RunModeProcessing
else
  goto RegularModeProcessing;
```

### Code segment A.3 – Mode selection procedure for lossless coding

```c
if (D1 == 0 && D2 == 0 && D3 == 0)
  goto RunModeProcessing;
else
  goto RegularModeProcessing;
```

### Code segment A.4 – Quantization of the gradients

```c
if (Di <= –T3) Qi = –4;
else if (Di <= –T2) Qi = –3;
else if (Di <= –T1) Qi = –2;
else if (Di < – NEAR) Qi = –1;
else if (Di <= NEAR) Qi = 0;
else if (Di < T1) Qi = 1;
else if (Di < T2) Qi = 2;
else if (Di < T3) Qi = 3;
else Qi = 4;
```

### Written requirement A.4.1 - Flip quantized vector

"If the first non-zero element of the vector (Q1, Q2, Q3) is negative, then all the signs of the vector (Q1, Q2, Q3) shall be reversed to obtain (–Q1, –Q2, –Q3).
In this case, the variable SIGN shall be set to –1, otherwise it shall be set to +1."
(T.87 1998, pg. 19)

### Written requirement A.4.2 - Merge quantized vector into Q

"After this possible "merging", the vector (Q1, Q2, Q3) is mapped, on a one-to-one basis, into an integer Q representing the context for the sample x. The function mapping the vector (Q1, Q2, Q3) to the integer Q is not specified in this Recommendation | International Standard. This Recommendation | International Standard only requires that the mapping shall be one-to-one, that it shall produce an integer in the range [0..364], and that it be defined for all possible values of the vector (Q1, Q2, Q3), including the vector (0, 0, 0).

NOTE – A total of 9 × 9 × 9 = 729 possible vectors are defined by the procedure in Code segment A.4. The vector (0, 0, 0) and its corresponding mapped value can only occur in regular mode for sample interleaved multi-component scans, as detailed in Annex B."
(T.87 1998, pg. 19)

## Prediction

### Code segment A.5 – Edge-detecting predictor

```c
if (Rc >= max(Ra, Rb))
  Px = min(Ra, Rb);
else {
  if (Rc <= min(Ra, Rb))
    Px = max(Ra, Rb);
  else
    Px = Ra + Rb – Rc;
}
```

### Code segment A.6 – Prediction correction from the bias

```c
if (SIGN == +1)
  Px = Px + C[Q];
else
  Px = Px – C[Q];
if (Px > MAXVAL)
  Px = MAXVAL;
else if (Px < 0)
  Px = 0;
```

### Code segment A.7 – Computation of prediction error

```c
Errval = Ix – Px;
if (SIGN == –1)
  Errval = – Errval;
```

### Code segment A.8 – Error quantization and computation of the reconstructed value in near-lossless coding (LOSSY ONLY)

```c
if (Errval > 0)
  Errval = (Errval + NEAR) / (2 * NEAR + 1);
else
  Errval = – (NEAR – Errval) / (2 * NEAR + 1);
Rx = Px + SIGN * Errval * (2 * NEAR + 1);
if (Rx < 0)
  Rx = 0;
else if (Rx > MAXVAL)
  Rx = MAXVAL;
```

### Written requirement A.8.1 - Reconstructed value in lossless mode (LOSSLESS ONLY)

"In lossless coding (NEAR = 0), the reconstructed value Rx shall be set to Ix."
(T.87 1998, pg. 20)

### Code segment A.9 – Modulo reduction of the error

```c
if (Errval < 0)
  Errval = Errval + RANGE;
if (Errval >= ((RANGE + 1) / 2))
  Errval = Errval – RANGE;
```

## Prediction error encoding

### Code segment A.10 – Computation of the Golomb coding variable k

```c
for(k=0; (N[Q]<<k)<A[Q]; k++);
```

### Code segment A.11 – Error mapping to non-negative values

```c
if ((NEAR == 0) && ( k == 0) && ( 2 * B[Q] <= – N[Q])) {
  if (Errval >= 0)
    MErrval = 2 * Errval + 1
  else
    MErrval = –2 * (Errval + 1);
}
else {
  if (Errval >= 0)
    MErrval = 2 * Errval;
  else
    MErrval = –2 * Errval – 1;
}
```

### Written requirement A.11.1 and A.11.2 - Golomb encoder and bit packer

"If the number formed by the high order bits of MErrval (all but the k least significant bits) is less than LIMIT – qbpp – 1, this number shall be appended to the encoded bit stream in unary representation, that is, by as many zeros as the value of this number, followed by a binary one. The k least significant bits of MErrval shall then be appended to the encoded bit stream without change, with the most significant bit first, followed by the remaining bits in decreasing order of significance."
(T.87 1998, pg. 21)

"Otherwise, LIMIT – qbpp – 1 zeros shall be appended to the encoded bit stream, followed by a binary
one. The binary representation of MErrval – 1 shall then be appended to the encoded bit stream using
qbpp bits, with the most significant bit first, followed by the remaining bits in decreasing order of
significance."
(T.87 1998, pg. 22)

## Update variables

### Code segment A.12 – Variables update

```c
B[Q] = B[Q] + Errval *(2 *NEAR + 1);
A[Q] = A[Q] + abs(Errval);
if (N[Q] == RESET) {
  A[Q] = A[Q] >> 1;
  if (B[Q] >= 0)
    B[Q] = B[Q] >> 1;
  else
    B[Q] = –((1-B[Q]) >> 1);
  N[Q] = N[Q] >> 1;
}
N[Q] = N[Q] + 1;
```

### Code segment A.13 – Update of bias-related variables B[Q] and C[Q]

```c
if (B[Q] <= –N[Q]) {
  B[Q] = B[Q] + N[Q];
  if (C[Q] > MIN_C)
    C[Q] = C[Q] – 1;
  if (B[Q] <= –N[Q])
    B[Q] = –N[Q] + 1;
}
else if (B[Q] > 0) {
  B[Q] = B[Q] – N[Q];
  if (C[Q] < MAX_C)
    C[Q] = C[Q] + 1;
  if (B[Q] > 0)
    B[Q] = 0
}
```

# Procedure: run mode

## Run scanning and run-length coding

### Code segment A.14 – Run-length determination for run mode

```c
RUNval = Ra;
RUNcnt = 0;
while (abs(Ix – RUNval) <= NEAR) {
  RUNcnt = RUNcnt + 1;
  Rx = RUNval;
  if (EOLine == 1)
    break;
  else
    GetNextSample();
}
```

### Code segment A.15 – Encoding of run segments of length rg

```c
while (RUNcnt >= (1 << J[RUNindex]) ) {
  AppendToBitStream(1,1);
  RUNcnt = RUNcnt – (1 << J[RUNindex]);
  if (RUNindex < 31)
    RUNindex = RUNindex +1;
}
```

### Code segment A.16 – Encoding of run segments of length less than rg

```c
if (abs(Ix – RUNval) > NEAR) {
  AppendToBitStream(0,1);
  AppendToBitStream(RUNcnt, J[RUNindex]);
  if (RUNindex > 0)
    RUNindex = RUNindex –1;
}
else if (RUNcnt > 0)
  AppendToBitStream(1,1);
```

## Run interruption sample encoding

### Code segment A.17 – Index computation

```c
if (abs(Ra – Rb) <= NEAR)
  RItype = 1;
else
  RItype = 0;
```

### Code segment A.18 – Prediction error for a run interruption sample

```c
if (RItype ==1)
  Px = Ra;
else
  Px = Rb
Errval = Ix – Px;
```

### Code segment A.19 – Error computation for a run interruption sample

```c
if ((RItype == 0) && (Ra > Rb)) {
  Errval = –Errval;
  SIGN = –1;
}
else
  SIGN = 1;
if (NEAR > 0) {
  Errval = Quantize(Errval);
  Rx = ComputeRx ();
}
else
  Rx = Ix;
Errval = ModRange (Errval,RANGE);
```

### Code segment A.20 – Computation of the auxiliary variable TEMP

```c
if (RItype == 0)
  TEMP = A[365];
else
  TEMP = A[366] + (N[366] >> 1);
```

### Written requirement A.20.1 – Compute Q for run mode

"Set Q = RItype + 365. " (T.87 1998, pg. 25)

### Written requirement A.20.2 – Golomb k variable

"The Golomb variable k shall be computed, following the same procedure as in the
regular mode, Code segment A.10, but using TEMP instead of A[Q]." (T.87 1998, pg. 25)

### Code segment A.21 – Computation of map for Errval mapping

```c
if ((k == 0) && (Errval > 0) && (2 * Nn[Q] < N[Q]))
  map = 1;
else if ((Errval < 0) && (2 * Nn[Q] >= N[Q]))
  map = 1;
else if ((Errval < 0) && (k != 0))
  map = 1;
else
  map = 0;
```

### Code segment A.22 – Errval mapping for run interruption sample

```c
EMErrval = 2 * abs(Errval) – RItype – map;
```

### Written requirement A.22.1 – EMErrval encoding

"Encode EMErrval following the same procedures as in the regular mode (see A.5.3), but using the limited
length Golomb code function LG(k, glimit), where glimit = LIMIT – J[RUNindex] – 1 and RUNindex
corresponds to the value of the variable before the decrement specified in Code segment A.16." (T.87 1998, pg. 25)

### Code segment A.23 – Update of variables for run interruption sample

```c
if (Errval < 0)
  Nn[Q] = Nn[Q] + 1;
A[Q] = A[Q] + ((EMErrval + 1 - RItype) >> 1);
if (N[Q] == RESET) {
  A[Q] = A[Q] >> 1;
  N[Q] = N[Q] >> 1;
  Nn[Q] = Nn[Q] >> 1;
}
N[Q] = N[Q] + 1;
```

# Initialisation

### Written requirement – Causal template at image borders

"When encoding the first line of a source image component, the samples at positions b, c, and d are not present, and their reconstructed values are defined to be zero. If the sample at position x is at the start or end of a line so that either a and c, or d is not present, the reconstructed value for a sample in position a or d is defined to be equal to Rb, the reconstructed value of the sample at position b, or zero for the first line in the component. The reconstructed value at a sample in position c, in turn, is copied (for lines other than the first line) from the value that was assigned to Ra when encoding the first sample in the previous line."
(T.87 1998, pg. 16)

### Written requirement – Variable initialisation

"1) Compute the parameter RANGE: For lossless coding (NEAR = 0), RANGE = MAXVAL + 1. [...]
Compute the parameters qbpp = ⌈log RANGE⌉, bpp = max(2, ⌈log(MAXVAL+1)⌉), and LIMIT = 2 * (bpp + max(8, bpp)).

1) Initialise the variables N[0..366], A[0..366], B[0..364] and C[0..364] [...]. Each one of the entries of A is initialised with the value max(2, ⌊(RANGE + 2^5) / 2^6⌋), those of N are initialised with the value 1, and those of B and C with the value 0.

2) Initialise the variables for the run mode: RUNindex=0 and J[0..31] = {0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12, 13, 14, 15}.

3) Initialise the two run interruption variables Nn[365] and Nn[366] to 0."
(T.87 1998, pg. 17)

# Default parameters

### Written requirement – Default preset coding parameters

| Parameter | Default |
|---|---|
| MAXVAL | 2^P – 1 |
| T1, T2, T3 | See below |
| RESET | 64 |

(T.87 1998, pg. 33, Table C.2)

### Written requirement – Default threshold values

BASIC_T1 = 3, BASIC_T2 = 7, BASIC_T3 = 21 (Table C.3), with Figure C.4 (MAXVAL ≥ 128; the MAXVAL < 128 case of Figure C.5 is out of scope):

```c
CLAMP(i, j) = j if i > MAXVAL or i < j, i otherwise.
FACTOR = (min(MAXVAL, 4095) + 128) / 256;
T1 = CLAMP(FACTOR * (BASIC_T1 – 2) + 2 + 3*NEAR, NEAR + 1);
T2 = CLAMP(FACTOR * (BASIC_T2 – 3) + 3 + 5*NEAR, T1);
T3 = CLAMP(FACTOR * (BASIC_T3 – 4) + 4 + 7*NEAR, T2);
```

(T.87 1998, pg. 34)

# Coded data

### Written requirement – Padding and byte stuffing

"0-bits are used, if necessary, to pad the end of the coded image data to complete the final byte of a segment. In order to provide for easy detection of marker segments, any X'FF' byte generated by the encoding process defined in this Recommendation | International Standard is followed by a "stuffed" zero bit, provided that the X'FF' byte is not part of an inserted marker segment."
(T.87 1998, pg. 31)

# Framing

### Written requirement – Image control procedure

Encode_image: append SOI marker, Encode_frame, append EOI marker. (T.87 1998, pg. 38, Figure D.1)

### Written requirement – Header layout

OpenJLS requirement: the fixed 25-byte header, per T.87 C.2.2/C.2.3 on top of T.81 B.2.2/B.2.3.

| Bytes | Value | Field |
|---|---|---|
| 0–1 | FF D8 | SOI |
| 2–5 | FF F7 00 0B | SOF55, Lf = 11 |
| 6 | BITNESS | P |
| 7–8 / 9–10 | height / width | Y / X |
| 11–14 | 01 01 11 00 | Nf = 1, C1 = 1, H1V1 = 11, Tq1 = 0 |
| 15–18 | FF DA 00 08 | SOS, Ls = 8 |
| 19–21 | 01 01 00 | Ns = 1, Cs1 = 1, Tm1 = 0 |
| 22–24 | 00 00 00 | NEAR = 0, ILV = 0, Al/Ah = 0 |

# Scope

Not part of T.87; these are project choices:

- Lossless only (NEAR = 0); the LOSSY ONLY segments above are not implemented.
- Single component, so ILV = 0; Annex B interleaving is not implemented.
- Default preset parameters only; no LSE marker segment and no restart intervals.
- BITNESS 8 to 16 bits; image width 4 to 65535 and height 1 to 65535.
