-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- openjls_top: T.87 lossless encoder top level
--
-- Stages are combinational with their registers here; the output IPs register internally.
--   Stage 1  A.1, A.3, A.4, A.8.1, line_buffer
--   Stage 2  regular A.4.1, A.4.2, A.5 | run A.14, A.15/A.16, A.17, A.18, A.20.1; context read address
--   Stage 3  context read, into the BRAM output register | regular A.6 clip bounds and errors | RI A.19
--   Stage 4  regular speculative A.6-A.9 chains; Q4 == Q5 forwarding
--   Stage 5  A.20, A.10 via A.20.2 | regular A.12, A.13 | RI A.23; context writeback
--   Stage 6  regular A.11 | RI A.21, A.22
--   Stage 7  A.11.1
--   Output   bit_packer, byte_stuffer, jls_framer

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library work;
  use work.olo_base_pkg_math.log2ceil;

entity openjls_top is
  generic (
    BITNESS          : positive range 8 to 16    := 12;
    MAX_IMAGE_WIDTH  : positive range 4 to 65535 := 4096;
    MAX_IMAGE_HEIGHT : positive range 1 to 65535 := 4096;
    OUT_WIDTH        : positive range 48 to 1024 := CO_OUT_WIDTH_STD
  );
  port (
    iClk             : in    std_logic;
    iRst             : in    std_logic;
    iValid           : in    std_logic;
    iPixel           : in    std_logic_vector(BITNESS - 1 downto 0);
    oReady           : out   std_logic;
    -- Fixed 16 bits: Vivado's block-design port-width evaluator only takes literal
    -- arithmetic. Values above MAX_IMAGE_WIDTH/HEIGHT are clamped.
    iImageWidth      : in    std_logic_vector(15 downto 0);
    iImageHeight     : in    std_logic_vector(15 downto 0);
    oData            : out   std_logic_vector(OUT_WIDTH - 1 downto 0);
    oValid           : out   std_logic;
    oKeep            : out   std_logic_vector(OUT_WIDTH / 8 - 1 downto 0);
    oLast            : out   std_logic;
    iReady           : in    std_logic
  );
end entity openjls_top;

architecture rtl of openjls_top is

  constant DEBUG_MODE                       : boolean := false;

  -- Encoder parameters ---
  constant MAX_VAL                          : natural := 2 ** BITNESS - 1;
  constant RANGE_P                          : natural := MAX_VAL + 1;
  constant QBPP                             : natural := log2ceil(RANGE_P);
  constant BPP                              : natural := math_max(2, log2ceil(MAX_VAL + 1));
  constant LIMIT                            : natural := 2 * (BPP + math_max(8, BPP));

  constant ERROR_WIDTH                      : natural  := BITNESS + 1;
  constant MAPPED_ERROR_VAL_WIDTH           : natural  := BITNESS + 2;
  constant RAM_DEPTH                        : positive := 367;                                        -- 365 regular + 2 run-interruption contexts
  constant RESET                            : natural  := 64;                                         -- T.87
  constant MAX_C                            : integer  := 127;                                        -- T.87
  constant MIN_C                            : integer  := - 128;                                      -- T.87
  constant ABS_MIN_C                        : natural  := - MIN_C;
  constant ABS_MAX_C                        : natural  := MAX_C;

  -- Context-variable widths ---
  -- _STORED: packed BRAM width (Murat 2018 Table I); _WIDTH: pipeline width with A.12/A.13 headroom
  --
  --   Var    Stored                          Encoding @ BRAM           Pipeline width
  --   A      bpp - 1 + ⌈log2(RESET)⌉         zero-extend on read       _STORED + 1
  --   B      ⌈log2(RESET)⌉ (mag only)        B = -unsigned(stored)     BPP + 1 (signed)
  --   C      ⌈log2(max|MIN_C|,|MAX_C|)⌉+1    signed cast               = _STORED
  --   N      ⌈log2(RESET)⌉ (RESET↦0)         0 ⇒ RESET                 log2ceil(RESET+1)
  --   Nn     ⌈log2(RESET)⌉                   direct                    = _STORED

  constant A_STORED                         : natural := BPP - 1 + log2ceil(RESET);
  constant B_STORED                         : natural := log2ceil(RESET);
  constant C_STORED                         : natural := log2ceil(math_max(ABS_MIN_C, ABS_MAX_C)) + 1;
  constant N_STORED                         : natural := log2ceil(RESET);
  constant NN_STORED                        : natural := log2ceil(RESET);
  constant A_WIDTH                          : natural := A_STORED + 1;
  constant B_WIDTH                          : natural := BPP + 1;
  constant C_WIDTH                          : natural := C_STORED;
  constant N_WIDTH                          : natural := log2ceil(RESET + 1);
  constant NN_WIDTH                         : natural := NN_STORED;
  constant MAX_K                            : natural := A_WIDTH;                                     -- A.10 saturates k at the width of A
  constant K_WIDTH                          : natural := log2ceil(MAX_K + 1);
  constant TOTAL_WIDTH                      : natural := A_STORED + B_STORED + C_STORED + N_STORED;

  -- Golomb / raw suffix widths ---
  -- Runs do not cross EOL
  constant RUN_CNT_WIDTH                    : natural := log2ceil(MAX_IMAGE_WIDTH + 1);
  constant J_MAX_BITS                       : natural := 15;                                          -- T.87 A.2.1, J[31] = 15
  constant UNARY_WIDTH                      : natural := log2ceil(LIMIT - QBPP);                      -- max LIMIT - QBPP - 1 (escape threshold)
  constant SUFFIX_WIDTH                     : natural := math_max(MAX_K, RUN_CNT_WIDTH);              -- k or QBPP bits (<= MAX_K), or raw run bits
  constant SUFFIXLEN_WIDTH                  : natural := math_max(K_WIDTH, log2ceil(J_MAX_BITS + 2)); -- k or QBPP, or raw length up to J_MAX_BITS + 1

  -- Output stages ---
  -- byte_stuffer runs at the average rate; its FIFO absorbs bursts and stalls the pipeline near full
  constant BYTE_STUFFER_OUT_BYTES_PER_CYCLE : natural := 4;                                           -- fixed by the stuffing layout table
  constant BYTE_STUFFER_BURST_DEPTH         : natural := 64;                                          -- covers natural images with margin
  constant BYTE_STUFFER_OUT_WIDTH           : natural := BYTE_STUFFER_OUT_BYTES_PER_CYCLE * 8;
  -- Must not exceed the shallowest per-image queue: jls_framer EOI FIFO (3), start queue (4),
  -- byte_stuffer valid-bits queue (3)
  constant MAX_IMAGES_IN_FLIGHT             : natural := 3;

  -- Context RAM word: regular (A | B | C | N), run (A | Nn | 0 | N) ---
  constant CTX_A_HI                         : natural := TOTAL_WIDTH - 1;
  constant CTX_A_LO                         : natural := TOTAL_WIDTH - A_STORED;
  constant CTX_B_HI                         : natural := CTX_A_LO - 1;
  constant CTX_B_LO                         : natural := CTX_A_LO - B_STORED;
  constant CTX_C_HI                         : natural := CTX_B_LO - 1;
  constant CTX_C_LO                         : natural := CTX_B_LO - C_STORED;
  constant CTX_N_HI                         : natural := CTX_C_LO - 1;
  constant CTX_N_LO                         : natural := 0;
  constant CTX_NN_HI                        : natural := CTX_B_LO + NN_STORED - 1;
  constant CTX_NN_LO                        : natural := CTX_B_LO;

  -- Pipeline token: only fields that cross stage registers ---
  --   token_none             : bubble
  --   token_regular          : regular sample (Golomb only)
  --   token_run              : run-mode pixel, resolved by A.14-A.16 in stage 2
  --   token_run_interruption : run break (Golomb + A.16 raw prefix)
  --   token_raw              : mid-run boundary (raw only)

  type t_token_mode is (token_none, token_regular, token_run, token_run_interruption, token_raw);

  type t_pipeline_token is record
    mode       : t_token_mode;
    Ix         : unsigned(BITNESS - 1 downto 0);
    Ra         : unsigned(BITNESS - 1 downto 0);
    Rb         : unsigned(BITNESS - 1 downto 0);
    Rc         : unsigned(BITNESS - 1 downto 0);
    Q          : unsigned(8 downto 0);
    Sign       : std_logic;
    RiType     : std_logic;
    Aq         : unsigned(A_WIDTH - 1 downto 0);
    Bq         : signed(B_WIDTH - 1 downto 0);
    Cq         : signed(C_WIDTH - 1 downto 0);
    Nq         : unsigned(N_WIDTH - 1 downto 0);
    Nn         : unsigned(NN_WIDTH - 1 downto 0);
    Errval     : signed(ERROR_WIDTH - 1 downto 0);
    k          : unsigned(K_WIDTH - 1 downto 0);
    RawLen     : unsigned(SUFFIXLEN_WIDTH - 1 downto 0);
    RawVal     : unsigned(SUFFIX_WIDTH - 1 downto 0);
    RiRunIndex : unsigned(4 downto 0);
  end record t_pipeline_token;

  constant CO_TOKEN_NONE                    : t_pipeline_token :=
  (
    mode       => token_none,
    Ix         => (others => '0'),
    Ra         => (others => '0'),
    Rb         => (others => '0'),
    Rc         => (others => '0'),
    Q          => (others => '0'),
    Sign       => '0',
    RiType     => '0',
    Aq         => (others => '0'),
    Bq         => (others => '0'),
    Cq         => (others => '0'),
    Nq         => (others => '0'),
    Nn         => (others => '0'),
    Errval     => (others => '0'),
    k          => (others => '0'),
    RawLen     => (others => '0'),
    RawVal     => (others => '0'),
    RiRunIndex => (others => '0')
  );

  signal sFramerReady                       : std_logic;
  signal sBsAlmostFullReg                   : std_logic;
  signal sStall                             : std_logic;
  signal sStallDelay                        : std_logic;
  signal sStallUpstream                     : std_logic;
  signal sStallLogic                        : std_logic;
  signal sCE1                               : std_logic;
  signal sCE2                               : std_logic;
  signal sCE3                               : std_logic;
  signal sCtxAdvance                        : std_logic;
  signal sCE4                               : std_logic;
  signal sCE5                               : std_logic;
  signal sCE6,     sCE7                     : std_logic;
  signal sStallNext                         : std_logic;
  signal sReg1VNext, sReg2VNext, sReg3VNext : std_logic;
  signal sReg4VNext, sReg5VNext             : std_logic;
  signal sReg6VNext, sReg7VNext             : std_logic;

  -- Pipeline tokens + sideband
  signal sReg1                              : t_pipeline_token;
  signal sReg2                              : t_pipeline_token;
  signal sReg3                              : t_pipeline_token;
  signal sReg4                              : t_pipeline_token;
  signal sReg5                              : t_pipeline_token;
  signal sReg1V                             : std_logic;
  signal sReg2V                             : std_logic;
  signal sReg3V                             : std_logic;
  signal sReg4V                             : std_logic;
  signal sReg5V                             : std_logic;
  signal sReg1Eol                           : std_logic;
  signal sReg1Eoi                           : std_logic;
  signal sReg2Eoi                           : std_logic;
  signal sReg3Eoi                           : std_logic;
  signal sReg4Eoi                           : std_logic;
  signal sReg5Eoi                           : std_logic;

  -- Image parity, flipped at each EOI: a straggler writeback from the previous
  -- image must not corrupt the next image's contexts
  signal sGenPar                            : std_logic;
  signal sReg1Par                           : std_logic;
  signal sReg2Par                           : std_logic;
  signal sReg2RiRaGtRb                      : std_logic;
  signal sReg3Par                           : std_logic;
  signal sReg3RiSign                        : std_logic;
  signal sReg4Par                           : std_logic;
  signal sReg4Rescale                       : std_logic;
  signal sReg4NqNew                         : unsigned(N_WIDTH - 1 downto 0);
  signal sReg4RiAqDelta                     : unsigned(BITNESS - 1 downto 0);
  signal sCtxOwnerPar                       : std_logic;
  signal sCtxRdPar                          : std_logic;
  signal sReg1ModeRun                       : std_logic;
  signal sReg1Q1                            : signed(3 downto 0);                                     -- [-4, 4]
  signal sReg1Q2                            : signed(3 downto 0);                                     -- [-4, 4]
  signal sReg1Q3                            : signed(3 downto 0);                                     -- [-4, 4]

  -- Input stage
  signal sPixel                             : unsigned(BITNESS - 1 downto 0);                         -- [0, MAX_VAL]
  signal sRx                                : unsigned(BITNESS - 1 downto 0);                         -- [0, MAX_VAL]
  signal sImageWidth                        : unsigned(log2ceil(MAX_IMAGE_WIDTH + 1) - 1 downto 0);   -- [4, MAX_IMAGE_WIDTH]
  signal sImageHeight                       : unsigned(log2ceil(MAX_IMAGE_HEIGHT + 1) - 1 downto 0);  -- [1, MAX_IMAGE_HEIGHT]
  signal sValid                             : std_logic;                                              -- accepted input beat
  signal sLbRa                              : unsigned(BITNESS - 1 downto 0);                         -- [0, MAX_VAL]
  signal sLbRb                              : unsigned(BITNESS - 1 downto 0);                         -- [0, MAX_VAL]
  signal sLbRc                              : unsigned(BITNESS - 1 downto 0);                         -- [0, MAX_VAL]
  signal sLbRd                              : unsigned(BITNESS - 1 downto 0);                         -- [0, MAX_VAL]
  signal sLbValid                           : std_logic;
  signal sLbEol                             : std_logic;
  signal sLbEoi                             : std_logic;

  -- Stage 1 combinational
  signal sS1D1                              : signed(BITNESS downto 0);                               -- [-MAX_VAL, MAX_VAL]
  signal sS1D2                              : signed(BITNESS downto 0);                               -- [-MAX_VAL, MAX_VAL]
  signal sS1D3                              : signed(BITNESS downto 0);                               -- [-MAX_VAL, MAX_VAL]
  signal sS1Q1                              : signed(3 downto 0);                                     -- [-4, 4]
  signal sS1Q2                              : signed(3 downto 0);                                     -- [-4, 4]
  signal sS1Q3                              : signed(3 downto 0);                                     -- [-4, 4]
  signal sS1ModeRun                         : std_logic;
  -- A.15/A.16 next-state run flag: keeps the stage 1 pixel in run mode while its
  -- predecessor in stage 2 is still in a run; A.3 alone would break the run
  signal sS1InRunNext                       : std_logic;

  -- Stage 2 — regular
  signal sS2MQ1                             : signed(3 downto 0);                                     -- [0, 4]
  signal sS2MQ2                             : signed(3 downto 0);                                     -- [-4, 4]
  signal sS2MQ3                             : signed(3 downto 0);                                     -- [-4, 4]
  signal sS2MSign                           : std_logic;
  signal sS2QReg                            : unsigned(8 downto 0);                                   -- [0, 364]
  signal sS2RunQ                            : unsigned(8 downto 0);                                   -- [365, 366]

  -- Stage 2 — run
  signal sRunCntReg                         : unsigned(RUN_CNT_WIDTH - 1 downto 0);                   -- [0, MAX_IMAGE_WIDTH]
  signal sS2RunCnt                          : unsigned(RUN_CNT_WIDTH - 1 downto 0);                   -- [0, MAX_IMAGE_WIDTH]
  signal sS2RunHit                          : std_logic;
  signal sS2RunContinue                     : std_logic;
  signal sS2RItype                          : std_logic;
  signal sS2RawValid                        : std_logic;
  signal sS2RawLen                          : unsigned(4 downto 0);                                   -- [0, J_MAX_BITS + 1]
  signal sS2RawVal                          : unsigned(RUN_CNT_WIDTH - 1 downto 0);                   -- [0, 2^J[RUNindex] - 1]
  signal sS2RiValid                         : std_logic;
  signal sS2RiIx                            : unsigned(BITNESS - 1 downto 0);                         -- [0, MAX_VAL]
  signal sS2RiRa                            : unsigned(BITNESS - 1 downto 0);                         -- [0, MAX_VAL]
  signal sS2RiRb                            : unsigned(BITNESS - 1 downto 0);                         -- [0, MAX_VAL]
  signal sS2RiRunIndex                      : unsigned(4 downto 0);                                   -- [0, 31]
  signal sS2RiErr18                         : signed(BITNESS downto 0);                               -- [-MAX_VAL, MAX_VAL]

  -- Stage 2 — muxed
  signal sS2Q                               : unsigned(8 downto 0);                                   -- [0, 366]
  signal sS2TokenMode                       : t_token_mode;

  signal sS2Px                              : unsigned(BITNESS - 1 downto 0);                         -- [0, MAX_VAL]
  signal sS3AtLo                            : signed(BITNESS downto 0);                               -- [-MAX_VAL, MAX_VAL]
  signal sS3AtHi                            : signed(BITNESS downto 0);                               -- [-MAX_VAL, MAX_VAL]
  signal sS3ClipLo, sS3ClipHi               : signed(C_WIDTH downto 0);
  signal sReg3ClipLo, sReg3ClipHi           : signed(C_WIDTH downto 0);
  signal sReg2Px                            : unsigned(BITNESS - 1 downto 0);                         -- [0, MAX_VAL]
  signal sReg3Px                            : unsigned(BITNESS - 1 downto 0);                         -- [0, MAX_VAL]
  signal sReg3AtLo                          : signed(BITNESS downto 0);                               -- [-MAX_VAL, MAX_VAL]
  signal sReg3AtHi                          : signed(BITNESS downto 0);                               -- [-MAX_VAL, MAX_VAL]

  -- context_ram packed I/O
  signal sCtxRdData                         : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
  signal sCtxWrData                         : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
  signal sCtxWrEn                           : std_logic;

  -- Stage 4 — context read
  signal sS4Aq                              : unsigned(A_WIDTH - 1 downto 0);                         -- [0, 2^A_STORED - 1]
  signal sS4Bq                              : signed(B_WIDTH - 1 downto 0);                           -- [-(RESET - 1), 0]
  signal sS4Cq                              : signed(C_WIDTH - 1 downto 0);                           -- [MIN_C, MAX_C]
  signal sS4Nq                              : unsigned(N_WIDTH - 1 downto 0);                         -- [1, RESET]
  signal sS4Nn                              : unsigned(NN_WIDTH - 1 downto 0);                        -- [0, RESET - 1]

  -- Stage 4 — regular prediction (speculative 3-chain)
  signal sS4Px                              : unsigned(BITNESS - 1 downto 0);                         -- [0, MAX_VAL]
  signal sS4CqC                             : signed(C_WIDTH - 1 downto 0);                           -- [MIN_C, MAX_C]
  signal sS4CqP1                            : signed(C_WIDTH - 1 downto 0);                           -- [MIN_C, MAX_C]
  signal sS4CqM1                            : signed(C_WIDTH - 1 downto 0);                           -- [MIN_C, MAX_C]
  signal sS4Err7C                           : signed(BITNESS downto 0);                               -- [-MAX_VAL, MAX_VAL]
  signal sS4Err7P                           : signed(BITNESS downto 0);                               -- [-MAX_VAL, MAX_VAL]
  signal sS4Err7M                           : signed(BITNESS downto 0);                               -- [-MAX_VAL, MAX_VAL]
  signal sS4Err9C                           : signed(BITNESS downto 0);                               -- [-RANGE_P / 2, RANGE_P / 2 - 1]
  signal sS4Err9P                           : signed(BITNESS downto 0);                               -- [-RANGE_P / 2, RANGE_P / 2 - 1]
  signal sS4Err9M                           : signed(BITNESS downto 0);                               -- [-RANGE_P / 2, RANGE_P / 2 - 1]
  signal sS4Errval                          : signed(ERROR_WIDTH - 1 downto 0);

  -- Q4 == Q5 forwarding, one flag per mode (regular and RI Q ranges are disjoint)
  signal sFwdRegHit                         : std_logic;
  -- Context key: '1' & merged Qi for regular, '0' & RItype otherwise; equal keys iff equal Q
  signal sS2Key                             : std_logic_vector(12 downto 0);
  signal sReg2Key                           : std_logic_vector(12 downto 0);
  signal sReg3Key                           : std_logic_vector(12 downto 0);
  signal sFwdRiHit                          : std_logic;

  -- Speculation control (Cq only)
  signal sSpecUseM                          : std_logic;
  signal sSpecUseP                          : std_logic;

  -- Stage 3 — RI A.19, then stage 4 — RI path
  signal sS3RiSign                          : std_logic;
  signal sS3RiErr19                         : signed(BITNESS downto 0);                               -- [-RANGE_P / 2, RANGE_P / 2 - 1]
  signal sS4RiAqDelta                       : unsigned(BITNESS - 1 downto 0);                         -- [0, RANGE_P / 2]

  -- Stage 5
  signal sS5RiTemp                          : unsigned(A_WIDTH - 1 downto 0);                         -- [0, 2^A_WIDTH - 1]
  signal sS5K                               : unsigned(K_WIDTH - 1 downto 0);                         -- [0, MAX_K]
  signal sS5RiMode                          : std_logic;
  signal sS5AqNew                           : unsigned(A_WIDTH - 1 downto 0);                         -- [0, 2^A_STORED - 1]
  signal sS5NqNew                           : unsigned(N_WIDTH - 1 downto 0);                         -- [1, RESET]
  signal sS5BqNew                           : signed(B_WIDTH - 1 downto 0);                           -- [-(RESET - 1), 0]
  signal sS5CqNew                           : signed(C_WIDTH - 1 downto 0);                           -- [MIN_C, MAX_C]
  signal sS5CqDec                           : std_logic;
  signal sS5CqInc                           : std_logic;
  signal sS5RiAqNew                         : unsigned(A_WIDTH - 1 downto 0);                         -- [0, 2^A_STORED - 1]
  signal sS5RiNqNew                         : unsigned(N_WIDTH - 1 downto 0);                         -- [1, RESET]
  signal sS5RiNnNew                         : unsigned(NN_WIDTH - 1 downto 0);                        -- [0, RESET - 1]
  signal sNqEncReg                          : unsigned(N_STORED - 1 downto 0);                        -- [0, RESET - 1] (RESET stored as 0)
  signal sNqEncRi                           : unsigned(N_STORED - 1 downto 0);                        -- [0, RESET - 1] (RESET stored as 0)

  -- Stage 6
  signal sS6MErrval                         : unsigned(MAPPED_ERROR_VAL_WIDTH - 1 downto 0);          -- [0, MAX_VAL]
  signal sS6RiMap                           : std_logic;
  signal sS6RiEmErrval                      : unsigned(MAPPED_ERROR_VAL_WIDTH - 1 downto 0);          -- [0, RANGE_P]
  signal sS6GolMErr                         : unsigned(MAPPED_ERROR_VAL_WIDTH - 1 downto 0);          -- [0, RANGE_P]

  signal sS6Unary                           : unsigned(UNARY_WIDTH - 1 downto 0);                     -- [0, LIMIT - QBPP - 1]
  signal sS6SufLen                          : unsigned(SUFFIXLEN_WIDTH - 1 downto 0);                 -- [0, MAX_K]
  signal sS6SufVal                          : unsigned(SUFFIX_WIDTH - 1 downto 0);

  -- Reg6 before A.11.1, Reg7 after
  signal sReg6,    sReg7                    : t_pipeline_token;
  signal sReg6V,   sReg7V                   : std_logic;
  signal sReg6Eoi, sReg7Eoi                 : std_logic;
  signal sReg6GolMErr                       : unsigned(MAPPED_ERROR_VAL_WIDTH - 1 downto 0);          -- [0, RANGE_P]
  signal sReg7Unary                         : unsigned(UNARY_WIDTH - 1 downto 0);                     -- [0, LIMIT - QBPP - 1]
  signal sReg7SufLen                        : unsigned(SUFFIXLEN_WIDTH - 1 downto 0);                 -- [0, MAX_K]
  signal sReg7SufVal                        : unsigned(SUFFIX_WIDTH - 1 downto 0);

  -- Output
  signal sBpRawV,  sBpGolV                  : std_logic;
  signal sBpWord                            : std_logic_vector(LIMIT - 1 downto 0);
  signal sBpWordV                           : std_logic;
  signal sBpValidLen                        : unsigned(log2ceil(LIMIT + 1) - 1 downto 0);             -- [0, LIMIT]
  signal sBsWord                            : std_logic_vector(BYTE_STUFFER_OUT_WIDTH - 1 downto 0);
  signal sBsWordV                           : std_logic;
  signal sBsValidB                          : unsigned(log2ceil(BYTE_STUFFER_OUT_WIDTH / 8 + 1) - 1 downto 0);-- [0, BYTE_STUFFER_OUT_BYTES_PER_CYCLE]
  signal sFramerVBytes                      : unsigned(log2ceil(OUT_WIDTH / 8 + 1) - 1 downto 0);     -- [0, OUT_WIDTH / 8]

  -- Flush / framer control
  signal sBsFlush                           : std_logic;
  signal sBsAlmostFull                      : std_logic;
  signal sBsFlushDone                       : std_logic;
  signal sFramerEoi                         : std_logic;
  signal sFirstPixel                        : std_logic;
  signal sFramerStart                       : std_logic;
  signal sReadyOut                          : std_logic;
  signal sImagesInFlight                    : natural range 0 to MAX_IMAGES_IN_FLIGHT;
  signal sNextIsFirst                       : std_logic;
  signal sInFlightStall                     : std_logic;

begin

  assert B_WIDTH >= BITNESS + 1
    report "A12: B_WIDTH must be >= BITNESS + 1 to avoid truncation"
    severity failure;

  assert A_WIDTH >= BITNESS + 1
    report "A12: A_WIDTH must be >= BITNESS + 1 to avoid truncation"
    severity failure;

  assert B_WIDTH >= N_WIDTH
    report "A11 & A13: B_WIDTH must be >= N_WIDTH to avoid truncation"
    severity failure;

  -- Stall, clock enable and ready ---
  p_stall_control : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sBsAlmostFullReg <= '0';
        sStallDelay      <= '0';
        sStallLogic      <= '0';
      else
        sBsAlmostFullReg <= sBsAlmostFull;
        sStallDelay      <= sStall;
        sStallLogic      <= sStallNext;
      end if;
    end if;

  end process p_stall_control;

  -- Only the byte_stuffer FIFO stalls the pipeline; framer backpressure stops at its iReady
  sStall <= sBsAlmostFullReg;
  -- sStall alone leaves a 1-cycle window with oReady = '1' while the input latch
  -- is still frozen, dropping that pixel
  sStallUpstream <= sStall or sStallLogic;

  -- A stage loads only when not stalled and it or its upstream holds a token:
  -- a bubble moves one hop, then the stage stops toggling

  sStallNext <= sStallDelay and sStall;

  sCE1 <= '1' when sStallLogic = '0' and (sReg1V = '1' or sValid = '1') else
          '0';

  -- CE2..CE7 are registered a cycle ahead from the next stall and valid bits: one local
  -- flop per stage instead of the shared stall net through a LUT. CE1 would need iValid.
  sReg1VNext <= sValid when sCE1 = '1' else sReg1V;
  sReg2VNext <= sReg1V and bool2bit(sS2TokenMode /= token_none) when sCE2 = '1' else sReg2V;
  sReg3VNext <= sReg2V when sCE3 = '1' else sReg3V;
  sReg4VNext <= sReg3V when sCE4 = '1' else sReg4V;
  sReg5VNext <= sReg4V when sCE5 = '1' else sReg5V;
  sReg6VNext <= sReg5V when sCE6 = '1' else sReg6V;
  sReg7VNext <= sReg6V when sCE7 = '1' else sReg7V;

  p_ce : process (iClk) is
  begin
    if rising_edge(iClk) then
      if (iRst = '1') then
        sCE2 <= '0';
        sCE3 <= '0';
        sCtxAdvance <= '1';
        sCE4 <= '0';
        sCE5 <= '0';
        sCE6 <= '0';
        sCE7 <= '0';
      else
        sCE2 <= not sStallNext and (sReg2VNext or sReg1VNext);
        sCE3 <= not sStallNext and (sReg3VNext or sReg2VNext);
        sCtxAdvance <= not sStallNext;
        sCE4 <= not sStallNext and (sReg4VNext or sReg3VNext);
        sCE5 <= not sStallNext and (sReg5VNext or sReg4VNext);
        sCE6 <= not sStallNext and (sReg6VNext or sReg5VNext);
        sCE7 <= not sStallNext and (sReg7VNext or sReg6VNext);
      end if;
    end if;
  end process p_ce;

  postponed assert iRst = '1' or is_x(sStallLogic) or
    (sCE2 = (not sStallLogic and (sReg2V or sReg1V)) and sCE3 = (not sStallLogic and (sReg3V or sReg2V)) and
     sCtxAdvance = not sStallLogic and sCE4 = (not sStallLogic and (sReg4V or sReg3V)) and
     sCE5 = (not sStallLogic and (sReg5V or sReg4V)) and sCE6 = (not sStallLogic and (sReg6V or sReg5V)) and
     sCE7 = (not sStallLogic and (sReg7V or sReg6V)))
    report "openjls_top: registered stage CE disagrees with the stall and valid bits" severity error;

  sReadyOut <= not iRst and not sStallUpstream and not sInFlightStall;
  oReady    <= sReadyOut;

  -- Contracts (PSL, simulation only): AXI-Stream input
  -- psl default clock is rising_edge(iClk);
  -- psl assert always (iRst = '1' -> oReady = '0') report "openjls_top: reset must hold oReady low";
  -- psl assert always ((iRst = '0' and sStallLogic = '1') -> oReady = '0') report "openjls_top: oReady must stay low while the input latch is frozen (no dropped beat)";
  -- psl assert always ((iRst = '0' and iValid = '1' and oReady = '1') -> next (sValid = '1')) report "openjls_top: an accepted pixel (iValid and oReady) must be committed next cycle";

  postponed assert is_x(sRunCntReg) or sRunCntReg <= MAX_IMAGE_WIDTH
    report "openjls_top: run count past MAX_IMAGE_WIDTH" severity error;

  -- Input register ---
  p_input_reg : process (iClk) is

    variable vImageWidthUnsi  : unsigned (iImageWidth'range);
    variable vImageHeightUnsi : unsigned (iImageHeight'range);

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sValid <= '0';
        sPixel <= (others => '0');

        vImageWidthUnsi  := unsigned(iImageWidth);
        vImageHeightUnsi := unsigned(iImageHeight);

        -- Out of range (including unwired, 0) selects MAX_IMAGE_WIDTH/HEIGHT
        if (vImageWidthUnsi < CO_MIN_IMAGE_WIDTH) then
          assert false
            report "iImageWidth smaller than the minimum allowed: " & integer'image(CO_MIN_IMAGE_WIDTH) & ", using max value instead: " & integer'image(MAX_IMAGE_WIDTH)
            severity warning;

          sImageWidth <= to_unsigned(MAX_IMAGE_WIDTH, sImageWidth'length);
        elsif (vImageWidthUnsi > MAX_IMAGE_WIDTH) then
          assert false
            report "iImageWidth larger than the maximum allowed: " & integer'image(MAX_IMAGE_WIDTH) & ", using max value instead: " & integer'image(MAX_IMAGE_WIDTH)
            severity warning;

          sImageWidth <= to_unsigned(MAX_IMAGE_WIDTH, sImageWidth'length);
        else
          sImageWidth <= resize(vImageWidthUnsi, sImageWidth'length);
        end if;

        if (vImageHeightUnsi < CO_MIN_IMAGE_HEIGHT) then
          assert false
            report "iImageHeight smaller than the minimum allowed: " & integer'image(CO_MIN_IMAGE_HEIGHT) & ", using max value instead: " & integer'image(MAX_IMAGE_HEIGHT)
            severity warning;

          sImageHeight <= to_unsigned(MAX_IMAGE_HEIGHT, sImageHeight'length);
        elsif (vImageHeightUnsi > MAX_IMAGE_HEIGHT) then
          assert false
            report "iImageHeight larger than the maximum allowed: " & integer'image(MAX_IMAGE_HEIGHT) & ", using max value instead: " & integer'image(MAX_IMAGE_HEIGHT)
            severity warning;

          sImageHeight <= to_unsigned(MAX_IMAGE_HEIGHT, sImageHeight'length);
        else
          sImageHeight <= resize(vImageHeightUnsi, sImageHeight'length);
        end if;
      else
        if (iValid = '1' and sReadyOut = '1' and sStallLogic = '0') then
          sPixel <= unsigned(iPixel);
          sValid <= '1';
        else
          sPixel <= (others => '0');
          sValid <= '0';
        end if;
      end if;
    end if;

  end process p_input_reg;

  -- Stage 1: A.8.1, line buffer, A.1, A.3, A.4 ---
  u_a8_1 : entity work.a8_1_reconstructed_value(behavioral)
    generic map (
      BITNESS => BITNESS
    )
    port map (
      iIx => sPixel,
      oRx => sRx
    );

  u_line_buffer : entity work.line_buffer(behavioral)
    generic map (
      MAX_IMAGE_WIDTH  => MAX_IMAGE_WIDTH,
      MAX_IMAGE_HEIGHT => MAX_IMAGE_HEIGHT,
      BITNESS          => BITNESS
    )
    port map (
      iClk             => iClk,
      iRst             => iRst,
      iImageWidth      => sImageWidth,
      iImageHeight     => sImageHeight,
      iValid           => sValid,
      iPixel           => sRx,
      oA               => sLbRa,
      oB               => sLbRb,
      oC               => sLbRc,
      oD               => sLbRd,
      oValid           => sLbValid,
      oEol             => sLbEol,
      oEoi             => sLbEoi
    );

  u_a1 : entity work.a1_gradient_comp(behavioral)
    generic map (
      BITNESS => BITNESS
    )
    port map (
      iA      => sLbRa,
      iB      => sLbRb,
      iC      => sLbRc,
      iD      => sLbRd,
      oD1     => sS1D1,
      oD2     => sS1D2,
      oD3     => sS1D3
    );

  u_a3 : entity work.a3_mode_selection(behavioral)
    generic map (
      BITNESS  => BITNESS
    )
    port map (
      iD1      => sS1D1,
      iD2      => sS1D2,
      iD3      => sS1D3,
      oModeRun => sS1ModeRun
    );

  u_a4 : entity work.a4_quantization_gradients(behavioral)
    generic map (
      BITNESS => BITNESS,
      MAX_VAL => MAX_VAL
    )
    port map (
      iD1     => sS1D1,
      iD2     => sS1D2,
      iD3     => sS1D3,
      oQ1     => sS1Q1,
      oQ2     => sS1Q2,
      oQ3     => sS1Q3
    );

  -- Reg1 ---
  p_reg1 : process (iClk) is

    variable v : t_pipeline_token;

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sReg1    <= CO_TOKEN_NONE;
        sReg1V   <= '0';
        sReg1Eol <= '0';
        sReg1Eoi <= '0';
        sReg1Q1  <= (others => '0');
        sReg1Q2  <= (others => '0');
        sReg1Q3  <= (others => '0');
        sGenPar  <= '0';
        sReg1Par <= '0';
      elsif (sCE1 = '1') then
        if (sLbValid = '1' and (sS1ModeRun = '1' or sS1InRunNext = '1')) then
          v.mode := token_run;
        elsif (sLbValid = '1') then
          v.mode := token_regular;
        else
          v := CO_TOKEN_NONE;
        end if;

        if (sLbValid = '1') then
          v.Ix := sPixel;
          v.Ra := sLbRa;
          v.Rb := sLbRb;
          v.Rc := sLbRc;
        end if;

        sReg1    <= v;
        sReg1V   <= sValid;
        sReg1Eol <= sLbValid and sLbEol;
        sReg1Eoi <= sLbValid and sLbEoi;
        sReg1Par <= sGenPar;
        if (sLbValid = '1' and sLbEoi = '1') then
          sGenPar <= not sGenPar;
        end if;
        sReg1Q1 <= sS1Q1;
        sReg1Q2 <= sS1Q2;
        sReg1Q3 <= sS1Q3;
      end if;
    end if;

  end process p_reg1;

  -- Stage 2, regular: A.4.1, A.4.2 ---
  u_a4_1 : entity work.a4_1_quant_gradient_merging(behavioral)
    port map (
      iQ1   => sReg1Q1,
      iQ2   => sReg1Q2,
      iQ3   => sReg1Q3,
      oQ1   => sS2MQ1,
      oQ2   => sS2MQ2,
      oQ3   => sS2MQ3,
      oSign => sS2MSign
    );

  u_a4_2 : entity work.a4_2_q_mapping(behavioral)
    port map (
      iQ1 => sS2MQ1,
      iQ2 => sS2MQ2,
      iQ3 => sS2MQ3,
      oQ  => sS2QReg
    );

  -- Stage 2, run: A.14, A.15/A.16, A.17, A.18, A.20.1 ---
  u_a14 : entity work.a14_run_length_determination(behavioral)
    generic map (
      BITNESS       => BITNESS,
      RUN_CNT_WIDTH => RUN_CNT_WIDTH
    )
    port map (
      iRa           => sReg1.Ra(BITNESS - 1 downto 0),
      iIx           => sReg1.Ix(BITNESS - 1 downto 0),
      iRunCnt       => sRunCntReg,
      iEol          => sReg1Eol,
      oRunCnt       => sS2RunCnt,
      oRunHit       => sS2RunHit,
      oRunContinue  => sS2RunContinue
    );

  sReg1ModeRun <= '1' when sReg1.mode = token_run else
                  '0';

  u_a15_16 : entity work.a15_a16_encode_run(behavioral)
    generic map (
      BITNESS       => BITNESS,
      RUN_CNT_WIDTH => RUN_CNT_WIDTH
    )
    port map (
      iClk          => iClk,
      iRst          => iRst,
      iCE           => not sStallLogic,
      iEoi          => sReg1Eoi,
      iRunCnt       => sS2RunCnt,
      iRunHit       => sS2RunHit,
      iRunContinue  => sS2RunContinue,
      iModeIsRun    => sReg1ModeRun,
      iIx           => sReg1.Ix(BITNESS - 1 downto 0),
      iRa           => sReg1.Ra(BITNESS - 1 downto 0),
      iRb           => sReg1.Rb(BITNESS - 1 downto 0),
      oRawValid     => sS2RawValid,
      oRawSuffixLen => sS2RawLen,
      oRawSuffixVal => sS2RawVal,
      oRiValid      => sS2RiValid,
      oRiIx         => sS2RiIx,
      oRiRa         => sS2RiRa,
      oRiRb         => sS2RiRb,
      oRiRunIndex   => sS2RiRunIndex,
      oInRunNext    => sS1InRunNext
    );

  u_a17 : entity work.a17_run_interruption_index(behavioral)
    generic map (
      BITNESS => BITNESS
    )
    port map (
      iRa     => sReg1.Ra(BITNESS - 1 downto 0),
      iRb     => sReg1.Rb(BITNESS - 1 downto 0),
      oRItype => sS2RItype
    );

  u_a18 : entity work.a18_run_interruption_prediction_error(behavioral)
    generic map (
      BITNESS => BITNESS
    )
    port map (
      iRItype => sS2RItype,
      iRa     => sS2RiRa,
      iRb     => sS2RiRb,
      iIx     => sS2RiIx,
      oErrval => sS2RiErr18
    );

  p_run_cnt : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sRunCntReg <= (others => '0');
      elsif (sStallLogic = '0' and sReg1.mode = token_run) then
        if (sS2RunContinue = '1') then
          sRunCntReg <= sS2RunCnt;
        else
          sRunCntReg <= (others => '0');
        end if;
      end if;
    end if;

  end process p_run_cnt;

  -- RI break (Golomb + raw) wins over raw-only
  sS2TokenMode <= token_regular when sReg1.mode = token_regular else
                  token_run_interruption when sS2RiValid = '1' else
                  token_raw when sS2RawValid = '1' else
                  token_none;

  u_a20_1 : entity work.a20_1_run_context_index(behavioral)
    port map (
      iRItype => sS2RItype,
      oQ      => sS2RunQ
    );

  sS2Q <= sS2QReg when sReg1.mode = token_regular else
          sS2RunQ;

  -- Context RAM owner: parity of the last valid read, held across bubbles
  p_ctx_owner : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sCtxOwnerPar <= '0';
      elsif (sReg2V = '1') then
        sCtxOwnerPar <= sReg2Par;
      end if;
    end if;

  end process p_ctx_owner;

  sCtxRdPar <= sReg2Par when sReg2V = '1' else
               sCtxOwnerPar;

  -- Drop straggler writebacks from a finished image. Parity from stage 2, whose word load still forwards this write
  sCtxWrEn <= sReg4V and
              bool2bit(sReg4Par = sCtxRdPar) and
              (bool2bit(sReg4.mode = token_regular) or
               bool2bit(sReg4.mode = token_run_interruption));

  -- Murat BRAM encoding: A narrowed (the halving at N = RESET caps it), N = RESET stored as 0.
  -- B keeps its low bits only: Bq is in [-(RESET - 1), 0] after A.13, so nonzero means negative
  -- and no negation sits after the A.13 select
  sCtxWrData <= std_logic_vector(resize(sS5AqNew, A_STORED)) &
                std_logic_vector(sS5BqNew(B_STORED - 1 downto 0)) &
                std_logic_vector(sS5CqNew) &
                std_logic_vector(sNqEncReg)
                when sReg4.mode = token_regular else
                std_logic_vector(resize(sS5RiAqNew, A_STORED)) &
                std_logic_vector(sS5RiNnNew) &
                std_logic_vector(to_signed(0, C_STORED)) &
                std_logic_vector(sNqEncRi);

  sNqEncReg <= (others => '0') when sS5NqNew = to_unsigned(RESET, N_WIDTH) else
               resize(sS5NqNew, N_STORED);

  sNqEncRi <= (others => '0') when sS5RiNqNew = to_unsigned(RESET, N_WIDTH) else
              resize(sS5RiNqNew, N_STORED);

  postponed assert sCtxWrEn /= '1' or sReg4.mode /= token_regular or is_x(sS5AqNew) or sS5AqNew < 2 ** A_STORED
    report "openjls_top: A does not fit A_STORED" severity error;
  postponed assert sCtxWrEn /= '1' or sReg4.mode /= token_regular or is_x(sS5BqNew) or
                   (sS5BqNew <= 0 and sS5BqNew > - 2 ** B_STORED)
    report "openjls_top: B does not fit B_STORED" severity error;
  postponed assert sCtxWrEn /= '1' or sReg4.mode /= token_regular or is_x(sS5NqNew) or
                   (sS5NqNew >= 1 and sS5NqNew <= RESET)
    report "openjls_top: N out of [1, RESET]" severity error;
  postponed assert sCtxWrEn /= '1' or sReg4.mode /= token_run_interruption or is_x(sS5RiAqNew) or sS5RiAqNew < 2 ** A_STORED
    report "openjls_top: RI A does not fit A_STORED" severity error;
  postponed assert sCtxWrEn /= '1' or sReg4.mode /= token_run_interruption or is_x(sS5RiNqNew) or
                   (sS5RiNqNew >= 1 and sS5RiNqNew <= RESET)
    report "openjls_top: RI N out of [1, RESET]" severity error;

  u_ctx_ram : entity work.context_ram(behavioral)
    generic map (
      RANGE_P     => RANGE_P,
      RAM_DEPTH   => RAM_DEPTH,
      A_WIDTH     => A_STORED,
      B_WIDTH     => B_STORED,
      C_WIDTH     => C_STORED,
      N_WIDTH     => N_STORED,
      TOTAL_WIDTH => TOTAL_WIDTH
    )
    port map (
      iClk        => iClk,
      iRst        => iRst,
      iWrAddr     => std_logic_vector(sReg4.Q),
      iWrEn       => sCtxWrEn and sCE4,
      iWrData     => sCtxWrData,
      iRdAddr     => std_logic_vector(sS2Q),
      iRdRegular  => bool2bit(sReg1.mode = token_regular),
      iRdRiType   => sS2RItype,
      iRdQ1       => sS2MQ1,
      iRdQ2       => sS2MQ2,
      iRdQ3       => sS2MQ3,
      iRdEn       => sReg1V and sCE1 and (bool2bit(sS2TokenMode = TOKEN_REGULAR) or
      bool2bit(sS2TokenMode = TOKEN_RUN_INTERRUPTION)),
      iEndOfImage => sReg1Eoi,
      iAdvance    => sCtxAdvance,
      iWordCE     => sCE3,
      oRdData     => sCtxRdData
    );

  -- Read valid at stage 4. Q4 == Q5: the BRAM read is stale, use the live stage 5 update
  sS4Aq <= sS5AqNew when sFwdRegHit = '1' else
           sS5RiAqNew when sFwdRiHit = '1' else
           resize(unsigned(sCtxRdData(CTX_A_HI downto CTX_A_LO)), A_WIDTH);

  -- RI: the B slot carries Nn
  sS4Bq <= sS5BqNew when sFwdRegHit = '1' else
           to_signed(0, B_WIDTH) when unsigned(sCtxRdData(CTX_B_HI downto CTX_B_LO)) = 0 else
           resize(signed('1' & sCtxRdData(CTX_B_HI downto CTX_B_LO)), B_WIDTH);

  -- Prediction takes Cq through the chains (sS4CqC)
  sS4Cq <= sS5CqNew when sFwdRegHit = '1' else
           signed(sCtxRdData(CTX_C_HI downto CTX_C_LO));

  sS4Nq <= sS5NqNew when sFwdRegHit = '1' else
           sS5RiNqNew when sFwdRiHit = '1' else
           to_unsigned(RESET, N_WIDTH) when unsigned(sCtxRdData(CTX_N_HI downto CTX_N_LO)) = 0 else
           resize(unsigned(sCtxRdData(CTX_N_HI downto CTX_N_LO)), N_WIDTH);

  -- Regular: the slot holds B, not Nn
  sS4Nn <= sS5RiNnNew when sFwdRiHit = '1' else
           (others => '0') when sReg3.mode = token_regular else
           unsigned(sCtxRdData(CTX_NN_HI downto CTX_NN_LO));

  -- Stage 2, regular: A.5 ---
  u_a5 : entity work.a5_edge_detecting_predictor(behavioral)
    generic map (
      BITNESS => BITNESS
    )
    port map (
      iA      => sReg1.Ra(BITNESS - 1 downto 0),
      iB      => sReg1.Rb(BITNESS - 1 downto 0),
      iC      => sReg1.Rc(BITNESS - 1 downto 0),
      oPx     => sS2Px
    );

  -- Reg2: the context read address lands with it ---
  p_reg2 : process (iClk) is

    variable v : t_pipeline_token;

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sReg2    <= CO_TOKEN_NONE;
        sReg2V   <= '0';
        sReg2Eoi <= '0';
        sReg2Px  <= (others => '0');
        sReg2Par <= '0';
        sReg2RiRaGtRb <= '0';
      elsif (sCE2 = '1') then
        -- Unused fields stay at CO_TOKEN_NONE: no stale values downstream
        v      := CO_TOKEN_NONE;
        v.mode := sS2TokenMode;
        v.Q    := sS2Q;

        case sS2TokenMode is

          when token_regular =>

            v.Ix   := sReg1.Ix;
            v.Ra   := sReg1.Ra;
            v.Rb   := sReg1.Rb;
            v.Rc   := sReg1.Rc;
            v.Sign := sS2MSign;

          when token_run_interruption =>

            v.Ix         := sS2RiIx;
            v.Ra         := sS2RiRa;
            v.Rb         := sS2RiRb;
            v.RiType     := sS2RItype;
            v.Errval     := resize(sS2RiErr18, v.Errval'length);
            v.RawLen     := resize(sS2RawLen, v.RawLen'length);
            v.RawVal     := resize(sS2RawVal, v.RawVal'length);
            v.RiRunIndex := sS2RiRunIndex;

          when token_raw =>

            v.RawLen := resize(sS2RawLen, v.RawLen'length);
            v.RawVal := resize(sS2RawVal, v.RawVal'length);

          when others =>

            v := CO_TOKEN_NONE;

        end case;

        if (sReg1V = '0' or sS2TokenMode = token_none) then
          v := CO_TOKEN_NONE;
        end if;

        sReg2    <= v;
        sReg2V   <= sReg1V and bool2bit(sS2TokenMode /= token_none);
        sReg2Eoi <= sReg1Eoi;
        sReg2Px  <= sS2Px;
        sReg2Par <= sReg1Par;
        sReg2RiRaGtRb <= bool2bit(sS2RiRa > sS2RiRb);
        sReg2Key <= sS2Key;
      end if;
    end if;

  end process p_reg2;

  -- Stage 3: A.6 clip bounds and errors, A.19; none reads a context, the BRAM output register loads with Reg3 ---

  -- Tokens other than regular carry sign '0', so the clip errors match iSign in every chain
  u_a6_bounds : entity work.a6_clip_bounds(behavioral)
    generic map (
      BITNESS => BITNESS, MAX_VAL => MAX_VAL
    )
    port map (
      iPx   => sReg2Px,
      iSign => sReg2.Sign,
      oLo   => sS3ClipLo,
      oHi   => sS3ClipHi
    );

  u_a6_errors : entity work.a6_clip_errors(behavioral)
    generic map (
      BITNESS => BITNESS, MAX_VAL => MAX_VAL
    )
    port map (
      iIx   => sReg2.Ix(BITNESS - 1 downto 0),
      iSign => sReg2.Sign,
      oAtLo => sS3AtLo,
      oAtHi => sS3AtHi
    );

  u_a19 : entity work.a19_run_interruption_error(behavioral)
    generic map (
      BITNESS => BITNESS,
      RANGE_P => RANGE_P
    )
    port map (
      iErrval => sReg2.Errval(BITNESS downto 0),
      iRItype => sReg2.RiType,
      iRaGtRb => sReg2RiRaGtRb,
      oErrval => sS3RiErr19,
      oSign   => sS3RiSign
    );

  -- Reg3 ---
  p_reg3 : process (iClk) is

    variable v : t_pipeline_token;

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sReg3    <= CO_TOKEN_NONE;
        sReg3V   <= '0';
        sReg3Eoi <= '0';
        sReg3Px  <= (others => '0');
        sReg3ClipLo <= (others => '0');
        sReg3ClipHi <= (others => '0');
        sReg3AtLo <= (others => '0');
        sReg3AtHi <= (others => '0');
        sReg3Par <= '0';
        sReg3RiSign <= '0';
      elsif (sCE3 = '1') then
        v := sReg2;
        if (sReg2.mode = token_run_interruption) then
          v.Errval := resize(sS3RiErr19, v.Errval'length);
        end if;

        sReg3    <= v;
        sReg3V   <= sReg2V;
        sReg3Eoi <= sReg2Eoi;
        sReg3Px  <= sReg2Px;
        sReg3ClipLo <= sS3ClipLo;
        sReg3ClipHi <= sS3ClipHi;
        sReg3AtLo <= sS3AtLo;
        sReg3AtHi <= sS3AtHi;
        sReg3Par <= sReg2Par;
        sReg3RiSign <= sS3RiSign;
        sReg3Key <= sReg2Key;
      end if;
    end if;

  end process p_reg3;

  -- Stage 4, regular: A.6–A.9 speculative chains ---

  sS4Px <= sReg3Px;

  sS2Key <= '1' & std_logic_vector(sS2MQ1 & sS2MQ2 & sS2MQ3) when sReg1.mode = token_regular else
            (0 => sS2RItype, others => '0');

  -- Forward on a Q match, registered a cycle early from the stage 2/3 pair the stall advances together.
  -- Same parity only, so a straggler from the previous image never forwards
  p_fwd_hit : process (iClk) is
    variable vMatch : boolean;
  begin
    if rising_edge(iClk) then
      if (iRst = '1') then
        sFwdRegHit <= '0';
        sFwdRiHit  <= '0';
      elsif (sStallLogic = '0') then
        vMatch     := sReg2V = '1' and sReg3V = '1' and sReg2Par = sReg3Par and sReg2Key = sReg3Key;
        sFwdRegHit <= bool2bit(vMatch and sReg3.mode = token_regular);
        sFwdRiHit  <= bool2bit(vMatch and sReg3.mode = token_run_interruption);
      end if;
    end if;
  end process p_fwd_hit;

  postponed assert is_x(sReg3.Q) or is_x(sReg4.Q) or is_x(sFwdRegHit) or
    sFwdRegHit = bool2bit(sReg3V = '1' and sReg4V = '1' and sReg3Par = sReg4Par
                          and sReg3.Q = sReg4.Q and sReg4.mode = token_regular)
    report "openjls_top: registered regular hit disagrees with Q3 == Q4" severity error;
  postponed assert is_x(sReg3.Q) or is_x(sReg4.Q) or is_x(sFwdRiHit) or
    sFwdRiHit = bool2bit(sReg3V = '1' and sReg4V = '1' and sReg3Par = sReg4Par
                         and sReg3.Q = sReg4.Q and sReg4.mode = token_run_interruption)
    report "openjls_top: registered RI hit disagrees with Q3 == Q4" severity error;

  -- On a hit the chains start from the pre-update Cq, with the A.13 branch picking the candidate
  sS4CqC <= sReg4.Cq when sFwdRegHit = '1' else
            signed(sCtxRdData(CTX_C_HI downto CTX_C_LO));

  sS4CqP1 <= to_signed(MAX_C, C_WIDTH) when sReg4.Cq = to_signed(MAX_C, C_WIDTH) else
             sReg4.Cq + 1;
  sS4CqM1 <= to_signed(MIN_C, C_WIDTH) when sReg4.Cq = to_signed(MIN_C, C_WIDTH) else
             sReg4.Cq - 1;

  -- A.6 and A.7 fused per chain: the forwarded Cq skips the clip-then-subtract path
  -- DeltaCq = 0
  u_a6a7_c : entity work.a6_a7_prediction_error(behavioral)
    generic map (
      BITNESS => BITNESS, MAX_VAL => MAX_VAL
    )
    port map (
      iIx       => sReg3.Ix(BITNESS - 1 downto 0),
      iPx       => sS4Px,
      iSign     => sReg3.Sign,
      iLo       => sReg3ClipLo,
      iHi       => sReg3ClipHi,
      iAtLo     => sReg3AtLo,
      iAtHi     => sReg3AtHi,
      iCq       => sS4CqC,
      oErrorVal => sS4Err7C
    );

  u_a9_c : entity work.a9_modulo_reduction(behavioral)
    generic map (
      BITNESS   => BITNESS, RANGE_P => RANGE_P
    )
    port map (
      iErrorVal => sS4Err7C,
      oErrorVal => sS4Err9C
    );

  -- DeltaCq = +1
  u_a6a7_p : entity work.a6_a7_prediction_error(behavioral)
    generic map (
      BITNESS => BITNESS, MAX_VAL => MAX_VAL
    )
    port map (
      iIx       => sReg3.Ix(BITNESS - 1 downto 0),
      iPx       => sS4Px,
      iSign     => sReg3.Sign,
      iLo       => sReg3ClipLo,
      iHi       => sReg3ClipHi,
      iAtLo     => sReg3AtLo,
      iAtHi     => sReg3AtHi,
      iCq       => sS4CqP1,
      oErrorVal => sS4Err7P
    );

  u_a9_p : entity work.a9_modulo_reduction(behavioral)
    generic map (
      BITNESS   => BITNESS, RANGE_P => RANGE_P
    )
    port map (
      iErrorVal => sS4Err7P,
      oErrorVal => sS4Err9P
    );

  -- DeltaCq = -1
  u_a6a7_m : entity work.a6_a7_prediction_error(behavioral)
    generic map (
      BITNESS => BITNESS, MAX_VAL => MAX_VAL
    )
    port map (
      iIx       => sReg3.Ix(BITNESS - 1 downto 0),
      iPx       => sS4Px,
      iSign     => sReg3.Sign,
      iLo       => sReg3ClipLo,
      iHi       => sReg3ClipHi,
      iAtLo     => sReg3AtLo,
      iAtHi     => sReg3AtHi,
      iCq       => sS4CqM1,
      oErrorVal => sS4Err7M
    );

  u_a9_m : entity work.a9_modulo_reduction(behavioral)
    generic map (
      BITNESS   => BITNESS, RANGE_P => RANGE_P
    )
    port map (
      iErrorVal => sS4Err7M,
      oErrorVal => sS4Err9M
    );

  -- The live stage 5 A.13 branch picks the chain; a clamped C lands on a saturated chain, equal to C
  sSpecUseM <= sFwdRegHit and sS5CqDec;
  sSpecUseP <= sFwdRegHit and sS5CqInc;

  sS4Errval <= (others => '0') when sReg3V = '0' else
               resize(sS4Err9M, ERROR_WIDTH) when sReg3.mode = token_regular and sSpecUseM = '1' else
               resize(sS4Err9P, ERROR_WIDTH) when sReg3.mode = token_regular and sSpecUseP = '1' else
               resize(sS4Err9C, ERROR_WIDTH) when sReg3.mode = token_regular else
               sReg3.Errval;

  -- Stage 4, RI: A.23 delta ---
  u_a23_delta : entity work.a23_aq_delta(rtl)
    generic map (
      ERROR_WIDTH => BITNESS + 1
    )
    port map (
      iErrVal => sReg3.Errval(BITNESS downto 0),
      iRiType => sReg3.RiType,
      oDelta  => sS4RiAqDelta
    );

  -- Reg4 ---
  p_reg4 : process (iClk) is

    variable v : t_pipeline_token;

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sReg4          <= CO_TOKEN_NONE;
        sReg4V         <= '0';
        sReg4Eoi       <= '0';
        sReg4Par       <= '0';
        sReg4Rescale   <= '0';
        sReg4NqNew     <= (others => '0');
        sReg4RiAqDelta <= (others => '0');
      elsif (sCE4 = '1') then
        v      := sReg3;
        v.Aq   := sS4Aq;
        v.Bq   := sS4Bq;
        v.Cq   := sS4Cq;
        v.Nq   := sS4Nq;
        v.Nn   := sS4Nn;

        case sReg3.mode is

          when token_run_interruption =>

            v.Sign   := sReg3RiSign;

          when others =>

            null;

        end case;

        if (sReg3V = '0') then
          v := CO_TOKEN_NONE;
        end if;
        v.Errval     := sS4Errval;
        sReg4          <= v;
        sReg4V         <= sReg3V;
        sReg4Eoi       <= sReg3Eoi;
        sReg4Par       <= sReg3Par;
        sReg4Rescale   <= bool2bit(v.Nq = RESET);
        if (v.Nq = RESET) then
          sReg4NqNew <= to_unsigned(RESET / 2 + 1, N_WIDTH);
        else
          sReg4NqNew <= v.Nq + 1;
        end if;
        sReg4RiAqDelta <= sS4RiAqDelta;
      end if;
    end if;

  end process p_reg4;

  -- Stage 5: A.20, A.10 shared via A.20.2, A.12, A.13, A.23 ---
  sS5RiMode <= '1' when sReg4.mode = token_run_interruption else
               '0';

  -- A.20 here, not in stage 4: TEMP only feeds k, so it stays out of the context forwarding loop
  u_a20 : entity work.a20_compute_temp(behavioral)
    generic map (
      A_WIDTH => A_WIDTH,
      N_WIDTH => N_WIDTH
    )
    port map (
      iRItype => sReg4.RiType,
      iAq     => sReg4.Aq,
      iNq     => sReg4.Nq,
      oTemp   => sS5RiTemp
    );

  u_a20_2 : entity work.a20_2_compute_k(behavioral)
    generic map (
      A_WIDTH => A_WIDTH,
      K_WIDTH => K_WIDTH,
      N_WIDTH => N_WIDTH
    )
    port map (
      iRunInterruption => sS5RiMode,
      iAq              => sReg4.Aq,
      iTemp            => sS5RiTemp,
      iNq              => sReg4.Nq,
      oK               => sS5K
    );

  sS5NqNew <= sReg4NqNew;

  u_a12_a13 : entity work.a12_a13_update(rtl)
    generic map (
      ERROR_WIDTH => BITNESS + 1,
      A_WIDTH     => A_WIDTH,
      B_WIDTH     => B_WIDTH,
      N_WIDTH     => N_WIDTH,
      C_WIDTH     => C_WIDTH,
      MIN_C       => MIN_C,
      MAX_C       => MAX_C,
      RESET       => RESET
    )
    port map (
      iErrorVal => sReg4.Errval(BITNESS downto 0),
      iAq       => sReg4.Aq,
      iBq       => sReg4.Bq,
      iCq       => sReg4.Cq,
      iNq       => sReg4.Nq,
      iNqNew    => sReg4NqNew,
      iRescale  => sReg4Rescale,
      oAq       => sS5AqNew,
      oBq       => sS5BqNew,
      oCq       => sS5CqNew,
      oDec      => sS5CqDec,
      oInc      => sS5CqInc
    );

  u_a23 : entity work.a23_run_interruption_update(behavioral)
    generic map (
      A_WIDTH     => A_WIDTH,
      N_WIDTH     => N_WIDTH,
      NN_WIDTH    => NN_WIDTH,
      ERROR_WIDTH => ERROR_WIDTH,
      RESET       => RESET
    )
    port map (
      iErrVal     => sReg4.Errval(BITNESS downto 0),
      iAqDelta    => sReg4RiAqDelta,
      iAq         => sReg4.Aq,
      iNq         => sReg4.Nq,
      iNn         => sReg4.Nn,
      oAq         => sS5RiAqNew,
      oNq         => sS5RiNqNew,
      oNn         => sS5RiNnNew
    );

  -- Reg5 ---
  p_reg5 : process (iClk) is

    variable v : t_pipeline_token;

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sReg5    <= CO_TOKEN_NONE;
        sReg5V   <= '0';
        sReg5Eoi <= '0';
      elsif (sCE5 = '1') then
        v   := sReg4;
        v.k := resize(sS5K, K_WIDTH);
        if (sReg4V = '0') then
          v := CO_TOKEN_NONE;
        end if;
        sReg5    <= v;
        sReg5V   <= sReg4V;
        sReg5Eoi <= sReg4Eoi;
      end if;
    end if;

  end process p_reg5;

  -- Stage 6: A.11, A.21, A.22 ---
  u_a11 : entity work.a11_error_mapping(behavioral)
    generic map (
      N_WIDTH                => N_WIDTH,
      B_WIDTH                => B_WIDTH,
      K_WIDTH                => K_WIDTH,
      ERROR_WIDTH            => ERROR_WIDTH,
      MAPPED_ERROR_VAL_WIDTH => MAPPED_ERROR_VAL_WIDTH
    )
    port map (
      iK                     => sReg5.k,
      iBq                    => sReg5.Bq,
      iNq                    => sReg5.Nq,
      iErrorVal              => sReg5.Errval(BITNESS downto 0),
      oMappedErrorVal        => sS6MErrval
    );

  u_a21 : entity work.a21_compute_map(behavioral)
    generic map (
      K_WIDTH     => K_WIDTH,
      N_WIDTH     => N_WIDTH,
      ERROR_WIDTH => ERROR_WIDTH
    )
    port map (
      iK          => sReg5.k,
      iErrval     => sReg5.Errval(BITNESS downto 0),
      iNn         => resize(sReg5.Nn, N_WIDTH),
      iNq         => sReg5.Nq,
      oMap        => sS6RiMap
    );

  u_a22 : entity work.a22_errval_mapping(behavioral)
    generic map (
      ERROR_WIDTH         => ERROR_WIDTH,
      MAPPED_ERRVAL_WIDTH => MAPPED_ERROR_VAL_WIDTH
    )
    port map (
      iErrval             => sReg5.Errval(BITNESS downto 0),
      iRItype             => sReg5.RiType,
      iMap                => sS6RiMap,
      oEmErrVal           => sS6RiEmErrval
    );

  sS6GolMErr <= sS6MErrval when sReg5.mode = token_regular else
                sS6RiEmErrval;

  -- Reg6, then A.11.1 ---
  p_reg6 : process (iClk) is

    variable v : t_pipeline_token;

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sReg6        <= CO_TOKEN_NONE;
        sReg6V       <= '0';
        sReg6Eoi     <= '0';
        sReg6GolMErr <= (others => '0');
      elsif (sCE6 = '1') then
        v := sReg5;
        if (sReg5V = '0') then
          v := CO_TOKEN_NONE;
        end if;
        sReg6        <= v;
        sReg6V       <= sReg5V;
        sReg6Eoi     <= sReg5Eoi;
        sReg6GolMErr <= sS6GolMErr;
      end if;
    end if;

  end process p_reg6;

  u_a11_1 : entity work.a11_1_golomb_encoder(behavioral)
    generic map (
      K_WIDTH                => K_WIDTH,
      QBPP                   => QBPP,
      LIMIT                  => LIMIT,
      UNARY_WIDTH            => UNARY_WIDTH,
      SUFFIX_WIDTH           => SUFFIX_WIDTH,
      SUFFIXLEN_WIDTH        => SUFFIXLEN_WIDTH,
      MAPPED_ERROR_VAL_WIDTH => MAPPED_ERROR_VAL_WIDTH
    )
    port map (
      iK                     => sReg6.k,
      iMappedErrorVal        => sReg6GolMErr,
      iRiMode                => bool2bit(sReg6.mode = TOKEN_RUN_INTERRUPTION),
      iRunIndex              => sReg6.RiRunIndex,
      oUnaryZeros            => sS6Unary,
      oSuffixLen             => sS6SufLen,
      oSuffixVal             => sS6SufVal
    );

  -- Reg7 ---
  p_reg7 : process (iClk) is

    variable v : t_pipeline_token;

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sReg7       <= CO_TOKEN_NONE;
        sReg7V      <= '0';
        sReg7Eoi    <= '0';
        sReg7Unary  <= (others => '0');
        sReg7SufLen <= (others => '0');
        sReg7SufVal <= (others => '0');
      elsif (sCE7 = '1') then
        v := sReg6;
        if (sReg6V = '0') then
          v := CO_TOKEN_NONE;
        end if;
        sReg7       <= v;
        sReg7V      <= sReg6V;
        sReg7Eoi    <= sReg6Eoi;
        sReg7Unary  <= sS6Unary;
        sReg7SufLen <= sS6SufLen;
        sReg7SufVal <= sS6SufVal;
      end if;
    end if;

  end process p_reg7;

  -- Output: bit packer, byte stuffer, framer ---
  sBpRawV <= '1' when sReg7V = '1' and sStallLogic = '0'
                      and (sReg7.mode = token_run_interruption or sReg7.mode = token_raw) else
             '0';
  sBpGolV <= '1' when sReg7V = '1' and sStallLogic = '0'
                      and (sReg7.mode = token_regular or sReg7.mode = token_run_interruption) else
             '0';

  u_bit_packer : entity work.a11_2_bit_packer(behavioral)
    generic map (
      LIMIT           => LIMIT,
      OUT_WIDTH       => LIMIT,
      UNARY_WIDTH     => UNARY_WIDTH,
      SUFFIX_WIDTH    => SUFFIX_WIDTH,
      SUFFIXLEN_WIDTH => SUFFIXLEN_WIDTH
    )
    port map (
      iClk            => iClk,
      iRst            => iRst,
      iStall          => sStallLogic,
      iRawValid       => sBpRawV,
      iRawLen         => sReg7.RawLen,
      iRawVal         => sReg7.RawVal,
      iGolombValid    => sBpGolV,
      iUnaryZeros     => sReg7Unary,
      iSuffixLen      => sReg7SufLen,
      iSuffixVal      => sReg7SufVal,
      oWord           => sBpWord,
      oWordValid      => sBpWordV,
      oValidLen       => sBpValidLen
    );

  u_byte_stuffer : entity work.byte_stuffer(behavioral)
    generic map (
      IN_WIDTH            => LIMIT,
      OUT_BYTES_PER_CYCLE => BYTE_STUFFER_OUT_BYTES_PER_CYCLE,
      BURST_DEPTH         => BYTE_STUFFER_BURST_DEPTH
    )
    port map (
      iClk                => iClk,
      iRst                => iRst,
      iStall              => sStallLogic,
      iWord               => sBpWord,
      iWordValid          => sBpWordV,
      iWordValidLen       => sBpValidLen,
      iFlush              => sBsFlush,
      oWord               => sBsWord,
      oWordValid          => sBsWordV,
      oValidBytes         => sBsValidB,
      iReady              => sFramerReady,
      oAlmostFull         => sBsAlmostFull,
      oFlushDone          => sBsFlushDone
    );

  u_framer : entity work.jls_framer(behavioral)
    generic map (
      BITNESS          => BITNESS,
      IN_WIDTH         => BYTE_STUFFER_OUT_WIDTH,
      OUT_WIDTH        => OUT_WIDTH,
      MAX_IMAGE_WIDTH  => MAX_IMAGE_WIDTH,
      MAX_IMAGE_HEIGHT => MAX_IMAGE_HEIGHT
    )
    port map (
      iClk             => iClk,
      iRst             => iRst,
      iStart           => sFramerStart,
      iImageWidth      => sImageWidth,
      iImageHeight     => sImageHeight,
      iEoi             => sFramerEoi,
      iWord            => sBsWord,
      iValid           => sBsWordV,
      iByteEnable      => sBsValidB,
      oReady           => sFramerReady,
      iReady           => iReady,
      oWord            => oData,
      oValid           => oValid,
      oByteEnable      => sFramerVBytes,
      oLast            => oLast
    );

  gen_keep : for i in 0 to OUT_WIDTH / 8 - 1 generate
    oKeep(OUT_WIDTH / 8 - 1 - i) <= '1' when sFramerVBytes > i else
                                    '0';
  end generate gen_keep;

  -- Flush and framer control ---
  p_flush_control : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sBsFlush <= '0';
      elsif (sStallLogic = '0') then
        sBsFlush <= sReg7Eoi;
      end if;
    end if;

  end process p_flush_control;

  sFramerEoi <= sBsFlushDone;

  -- line_buffer flags EOI on an image's last pixel, so the next accepted pixel starts a new image
  p_first_pixel : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sFirstPixel <= '1';
      elsif (sValid = '1') then
        sFirstPixel <= sLbEoi;
      end if;
    end if;

  end process p_first_pixel;

  sFramerStart <= sValid and sFirstPixel;

  -- Images from first pixel accepted to last output beat accepted; holding the next image's
  -- first pixel at the cap bounds every per-image queue downstream
  p_images_in_flight : process (iClk) is

    variable vCount : natural range 0 to MAX_IMAGES_IN_FLIGHT + 1;

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sImagesInFlight <= 0;
      else
        vCount := sImagesInFlight;
        if (sFramerStart = '1') then
          vCount := vCount + 1;
        end if;
        if (oValid = '1' and iReady = '1' and oLast = '1') then
          vCount := vCount - 1;
        end if;
        assert vCount <= MAX_IMAGES_IN_FLIGHT
          report "openjls_top: images in flight past MAX_IMAGES_IN_FLIGHT"
          severity failure;
        sImagesInFlight <= vCount;
      end if;
    end if;

  end process p_images_in_flight;

  sNextIsFirst   <= sLbEoi when sValid = '1' else
                    sFirstPixel;
  sInFlightStall <= '1' when sImagesInFlight = MAX_IMAGES_IN_FLIGHT and sNextIsFirst = '1' else
                    '0';

end architecture rtl;
