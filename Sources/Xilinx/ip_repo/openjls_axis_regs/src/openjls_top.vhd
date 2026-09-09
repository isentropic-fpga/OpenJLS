-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

-------------------------------------------------------------------------------------------------------------
-- Engineer:    Vitor Mendes Camilo
--
-- Module Name: openjls_top - rtl
-- Description: JPEG-LS T.87 lossless encoder top level.
--
--          The architecture is a 14 stage pipeline with:
--          1 input stage + 6 processing stages + 7 output stages.
--          The output stages are internally registered in the IPs, while the processing
--          stages are purely combinational and the inter-stage registers are placed in
--          this top-level wrapper
--
--------------------------------------------------------------------------------------------
-- PIPELINE
--------------------------------------------------------------------------------------------
--
--   Input Stage : Wire
--
-- RegInput -------
--
--   Stage 1     : A.1 gradients + A.3 mode select
--                 line_buffer
--
-- Reg1 -----------
--
--   Stage 2     : regular {A.4, A.4.1, A.4.2} | run {A.14, A.15/16, A.17, A.18}
--                 context_ram
--
-- Reg2 -----------
--
--   Stage 3     : regular {A.5, speculative 3×{A.6..A.9}} | RI {A.19, A.20}
--                 feed-forward logic for speculation and Q3==Q4 forwarding
--
-- Reg3 -----------
--
--   Stage 4     : shared {A.10} | regular {A.12, A.13} | RI {A.23};
--                 context writeback
--
-- Reg4 -----------
--
--   Stage 5     : regular {A.11} | RI {A.21, A.22};
--                 mux select mapped errval
--
-- Reg5 -----------
--
--   Stage 6    : A.11.1 Golomb encoder
--
-- Reg6 -----------
--
--   Output Stages (internally registered):
--
--                bit_packer
--                byte_stuffer
--                jls_framer
--
-------------------------------------------------------------------------------------------------------------

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
    -- Fixed 16-bit (not log2ceil-sized): Vivado's block-design port-width
    -- evaluator only handles literal arithmetic in port expressions. Values
    -- above MAX_IMAGE_WIDTH/HEIGHT are clamped at sample time as before.
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

  -------------------------------------------------------------------------------------------------------------
  -- ENCODER PARAMETERS
  -------------------------------------------------------------------------------------------------------------
  -- Derived constants
  constant MAX_VAL                          : natural := 2 ** BITNESS - 1;
  constant RANGE_P                          : natural := MAX_VAL + 1;
  constant QBPP                             : natural := log2ceil(RANGE_P);
  constant BPP                              : natural := math_max(2, log2ceil(MAX_VAL + 1));
  constant LIMIT                            : natural := 2 * (BPP + math_max(8, BPP));

  -- Widths computed locally from generics
  constant ERROR_WIDTH                      : natural  := BITNESS + 1;
  constant MAPPED_ERROR_VAL_WIDTH           : natural  := BITNESS + 2;
  constant RAM_DEPTH                        : positive := 367;                                        -- 365 contexts + 2 RI-specific contexts
  constant RESET                            : natural  := 64;                                         -- T.87
  constant MAX_C                            : integer  := 127;                                        -- T.87
  constant MIN_C                            : integer  := - 128;                                      -- T.87
  constant ABS_MIN_C                        : natural  := - MIN_C;
  constant ABS_MAX_C                        : natural  := MAX_C;

  --------------------------------------------------------------------------------------------
  -- Context-variable widths.
  --------------------------------------------------------------------------------------------
  -- Two tiers:
  --   _STORED : packed BRAM width (Murat 2018 Table I, "Optimal Bits to
  --             Represent"). Encoding tricks applied at the BRAM boundary.
  --   _WIDTH  : pipeline arithmetic width (mid-update headroom for A.12/A.13).
  --             Needed to compute intermediary values without overflow.
  --
  --------------------------------------------------------------------------------------------
  --   Var    Stored                          Encoding @ BRAM           Pipeline width
  --------------------------------------------------------------------------------------------
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
  constant MAX_K                            : natural := A_WIDTH;                                     -- A10 saturates Golomb k here (max k = bit-width of A)
  constant K_WIDTH                          : natural := log2ceil(MAX_K + 1);                         -- holds k in [0, MAX_K]
  constant TOTAL_WIDTH                      : natural := A_STORED + B_STORED + C_STORED + N_STORED;

  --------------------------------------------------------------------------------------------
  -- Golomb / Raw suffix output widths.
  --------------------------------------------------------------------------------------------
  --   Raw  : oRawSuffixVal up to RUN_CNT_WIDTH bits, oRawSuffixLen up to
  --          J_MAX+1 = 16 distinct values (vJ+1, vJ ∈ [0..15] from T.87 J).
  --   Gol. : regular suffix = k low bits (k <= MAX_K), escape suffix = QBPP bits;
  --          both fit in MAX_K. Unary zeros <= LIMIT - QBPP - 1 (escape
  --          threshold; regular quotient is strictly smaller).

  -- Run length bounded by image width (run cannot cross EOL).
  constant RUN_CNT_WIDTH                    : natural := log2ceil(MAX_IMAGE_WIDTH + 1);
  constant J_MAX_BITS                       : natural := 15;                                          -- T.87 A.2.1, J[31] = 15
  constant UNARY_WIDTH                      : natural := log2ceil(LIMIT - QBPP);                      -- regular quotient / escape threshold; max = LIMIT-QBPP-1
  constant SUFFIX_WIDTH                     : natural := math_max(MAX_K, RUN_CNT_WIDTH);              -- regular k bits / escape QBPP bits, both <= MAX_K
  constant SUFFIXLEN_WIDTH                  : natural := math_max(K_WIDTH, log2ceil(J_MAX_BITS + 2)); -- regular k / escape QBPP, both <= K_WIDTH

  --------------------------------------------------------------------------------------------
  -- Bit packer / byte stuffer / framer interface widths.
  -- byte_stuffer is sized for AVERAGE rate; bursts absorbed by its buffer, which
  -- asserts oAlmostFull and stalls upstream near full. OUT_BYTES_PER_CYCLE trades
  -- fmax vs throughput; BURST_DEPTH=64 covers natural images with margin.
  --------------------------------------------------------------------------------------------
  constant BYTE_STUFFER_OUT_BYTES_PER_CYCLE : natural := 4;                                           -- Hardcoded, fixed
  constant BYTE_STUFFER_BURST_DEPTH         : natural := 64;                                          -- Can be tuned
  constant BYTE_STUFFER_OUT_WIDTH           : natural := BYTE_STUFFER_OUT_BYTES_PER_CYCLE * 8;

  --------------------------------------------------------------------------------------------
  -- Packed context RAM word slicing
  --------------------------------------------------------------------------------------------
  -- Regular mode:  (A | B  | C | N)
  -- Run mode:      (A | NN | 0 | N)
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

  -------------------------------------------------------------------------------------------------------------
  -- PIPELINE TOKEN RECORD
  -------------------------------------------------------------------------------------------------------------
  -- Fields cross inter-stage register boundaries;
  -- combinational stage-local wires are NOT in the record.
  --
  -- Mode tag:
  --   TOKEN_NONE             : pipeline bubble — downstream stages NOP
  --   TOKEN_REGULAR          : regular-mode sample (Golomb only)
  --   TOKEN_RUN_INTERRUPTION : run break (Golomb + A.16 raw prefix)
  --   TOKEN_RAW              : mid-run boundary emit (raw only)

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
    Temp       : unsigned(A_WIDTH - 1 downto 0);
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
    Temp       => (others => '0'),
    Errval     => (others => '0'),
    k          => (others => '0'),
    RawLen     => (others => '0'),
    RawVal     => (others => '0'),
    RiRunIndex => (others => '0')
  );
  -------------------------------------------------------------------------------------------------------------

  -- Backpressure / clock-enable. sStall drives a single coarse pipeline freeze
  -- when the framer FIFO is approaching its nominal capacity. It also doubles
  -- as the idle-power gate together with each stage's valid bits: a register
  -- only updates when (NOT sStall) AND (current_valid OR upstream_valid), so a
  -- bubble propagates exactly once and then the register stops toggling.
  signal sFramerReady                       : std_logic;
  signal sBsAlmostFullReg                   : std_logic;
  signal sStall                             : std_logic;
  signal sStallDelay                        : std_logic;
  signal sStallUpstream                     : std_logic;
  signal sStallLogic                        : std_logic;
  signal sCE1                               : std_logic;
  signal sCE2                               : std_logic;
  signal sCE3                               : std_logic;
  signal sCE4                               : std_logic;
  signal sCE5,     sCE6                     : std_logic;

  -- Pipeline tokens + sideband
  signal sReg1                              : t_pipeline_token;
  signal sReg2                              : t_pipeline_token;
  signal sReg3                              : t_pipeline_token;
  signal sReg4                              : t_pipeline_token;
  signal sReg1V                             : std_logic;
  signal sReg2V                             : std_logic;
  signal sReg3V                             : std_logic;
  signal sReg4V                             : std_logic;
  signal sReg1Eol                           : std_logic;
  signal sReg1Eoi                           : std_logic;
  signal sReg2Eoi                           : std_logic;
  signal sReg3Eoi                           : std_logic;
  signal sReg4Eoi                           : std_logic;

  -- Per-image parity bit: 1 bit assigned at Reg1, flipped at each EOI,
  -- carried to the writeback stage. Avoid old image writing values into
  -- the context ram that belongs to the new image.
  signal sGenPar                            : std_logic;
  signal sReg1Par                           : std_logic;
  signal sReg2Par                           : std_logic;
  signal sReg3Par                           : std_logic;
  signal sCtxOwnerPar                       : std_logic;                                              -- sticky: parity owning the ctx RAM (held thru bubbles)
  signal sCtxRdPar                          : std_logic;                                              -- effective owner this cycle (combinational)
  signal sReg1ModeRun                       : std_logic;
  signal sReg1D1                            : signed(BITNESS downto 0);
  signal sReg1D2                            : signed(BITNESS downto 0);
  signal sReg1D3                            : signed(BITNESS downto 0);

  -- Input stage
  signal sPixel                             : unsigned(BITNESS - 1 downto 0);
  signal sImageWidth                        : unsigned(log2ceil(MAX_IMAGE_WIDTH + 1) - 1 downto 0);
  signal sImageHeight                       : unsigned(log2ceil(MAX_IMAGE_HEIGHT + 1) - 1 downto 0);
  signal sValid                             : std_logic;                                              -- iValid & sReady
  signal sLbRa                              : unsigned(BITNESS - 1 downto 0);
  signal sLbRb                              : unsigned(BITNESS - 1 downto 0);
  signal sLbRc                              : unsigned(BITNESS - 1 downto 0);
  signal sLbRd                              : unsigned(BITNESS - 1 downto 0);
  signal sLbValid                           : std_logic;
  signal sLbEol                             : std_logic;
  signal sLbEoi                             : std_logic;

  -- Stage 1 combinational
  signal sS1D1                              : signed(BITNESS downto 0);
  signal sS1D2                              : signed(BITNESS downto 0);
  signal sS1D3                              : signed(BITNESS downto 0);
  signal sS1ModeRun                         : std_logic;
  -- Sticky run flag: A15_16's next-state sInRun, fed back to stage 1 so the
  -- pixel currently in stage 1 inherits "still in run" from the prior pixel
  -- in stage 2. Without it, A.3's gradient-based decision can break runs.
  signal sS1InRunNext                       : std_logic;

  -- Stage 2 — regular
  signal sS2Q1                              : signed(3 downto 0);
  signal sS2Q2                              : signed(3 downto 0);
  signal sS2Q3                              : signed(3 downto 0);
  signal sS2MQ1                             : signed(3 downto 0);
  signal sS2MQ2                             : signed(3 downto 0);
  signal sS2MQ3                             : signed(3 downto 0);
  signal sS2MSign                           : std_logic;
  signal sS2QReg                            : unsigned(8 downto 0);

  -- Stage 2 — run
  signal sRunCntReg                         : unsigned(RUN_CNT_WIDTH - 1 downto 0);
  signal sS2RunCnt                          : unsigned(RUN_CNT_WIDTH - 1 downto 0);
  signal sS2RunHit                          : std_logic;
  signal sS2RunContinue                     : std_logic;
  signal sS2RItype                          : std_logic;
  signal sS2RawValid                        : std_logic;
  signal sS2RawLen                          : unsigned(4 downto 0);
  signal sS2RawVal                          : unsigned(RUN_CNT_WIDTH - 1 downto 0);
  signal sS2RiValid                         : std_logic;
  signal sS2RiIx                            : unsigned(BITNESS - 1 downto 0);
  signal sS2RiRa                            : unsigned(BITNESS - 1 downto 0);
  signal sS2RiRb                            : unsigned(BITNESS - 1 downto 0);
  signal sS2RiRunIndex                      : unsigned(4 downto 0);
  signal sS2RiErr18                         : signed(BITNESS downto 0);

  -- Stage 2 — muxed
  signal sS2Q                               : unsigned(8 downto 0);
  signal sS2TokenMode                       : t_token_mode;

  signal sS2Px                              : unsigned(BITNESS - 1 downto 0);
  signal sReg2Px                            : unsigned(BITNESS - 1 downto 0);

  -- context_ram packed I/O
  signal sCtxRdData                         : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
  signal sCtxWrData                         : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
  signal sCtxWrEn                           : std_logic;

  -- Stage 3 context (mux between BRAM regular read and RI cluster read)
  signal sS3Aq                              : unsigned(A_WIDTH - 1 downto 0);
  signal sS3Bq                              : signed(B_WIDTH - 1 downto 0);
  signal sS3Cq                              : signed(C_WIDTH - 1 downto 0);
  signal sS3Nq                              : unsigned(N_WIDTH - 1 downto 0);
  signal sS3Nn                              : unsigned(NN_WIDTH - 1 downto 0);

  -- Stage 3 — regular prediction (speculative 3-chain)
  signal sS3Px                              : unsigned(BITNESS - 1 downto 0);
  signal sS3CqBase                          : signed(C_WIDTH - 1 downto 0);
  signal sS3CqP1                            : signed(C_WIDTH - 1 downto 0);
  signal sS3CqM1                            : signed(C_WIDTH - 1 downto 0);
  signal sS3Err7C                           : signed(BITNESS downto 0);
  signal sS3Err7P                           : signed(BITNESS downto 0);
  signal sS3Err7M                           : signed(BITNESS downto 0);
  signal sS3Err9C                           : signed(BITNESS downto 0);
  signal sS3Err9P                           : signed(BITNESS downto 0);
  signal sS3Err9M                           : signed(BITNESS downto 0);
  signal sS3Err9Sel                         : signed(BITNESS downto 0);

  -- Q3==Q4 forwarding: one flag per mode. Q ranges are disjoint (regular
  -- 0..364, RI 365,366), so a Q match + the Stage-4 mode uniquely identifies
  -- which writeback path is live; Stage-2 mode is implied.
  signal sFwdRegHit                         : std_logic;
  signal sFwdRiHit                          : std_logic;

  -- Speculation control (Cq only)
  signal sDeltaCq                           : signed(C_WIDTH - 1 downto 0);
  signal sSpecUseM                          : std_logic;
  signal sSpecUseP                          : std_logic;

  -- Stage 3 — RI path
  signal sS3RiSign                          : std_logic;
  signal sS3RiErr19                         : signed(BITNESS downto 0);
  signal sS3RiTemp                          : unsigned(A_WIDTH - 1 downto 0);

  -- Stage 4
  signal sS4K                               : unsigned(K_WIDTH - 1 downto 0);
  signal sS4AqSel                           : unsigned(A_WIDTH - 1 downto 0);                         -- iAq mux for shared A.10
  signal sS4AqNew                           : unsigned(A_WIDTH - 1 downto 0);
  signal sS4BqMid                           : signed(B_WIDTH - 1 downto 0);
  signal sS4NqNew                           : unsigned(N_WIDTH - 1 downto 0);
  signal sS4BqNew                           : signed(B_WIDTH - 1 downto 0);
  signal sS4CqNew                           : signed(C_WIDTH - 1 downto 0);
  signal sS4RiAqNew                         : unsigned(A_WIDTH - 1 downto 0);
  signal sS4RiNqNew                         : unsigned(N_WIDTH - 1 downto 0);
  signal sS4RiNnNew                         : unsigned(NN_WIDTH - 1 downto 0);
  -- BRAM-side encode helpers for the N 0↔RESET trick.
  signal sNqEncReg                          : unsigned(N_STORED - 1 downto 0);
  signal sNqEncRi                           : unsigned(N_STORED - 1 downto 0);

  -- Stage 5
  signal sS5MErrval                         : unsigned(MAPPED_ERROR_VAL_WIDTH - 1 downto 0);
  signal sS5RiMap                           : std_logic;
  signal sS5RiEmErrval                      : unsigned(MAPPED_ERROR_VAL_WIDTH - 1 downto 0);
  signal sS5GolMErr                         : unsigned(MAPPED_ERROR_VAL_WIDTH - 1 downto 0);

  signal sS5Unary                           : unsigned(UNARY_WIDTH - 1 downto 0);
  signal sS5SufLen                          : unsigned(SUFFIXLEN_WIDTH - 1 downto 0);
  signal sS5SufVal                          : unsigned(SUFFIX_WIDTH - 1 downto 0);

  -- Stage 5 inter-stage registers: Reg5 in front of A.11_1, Reg6 after.
  signal sReg5,    sReg6                    : t_pipeline_token;
  signal sReg5V,   sReg6V                   : std_logic;
  signal sReg5Eoi, sReg6Eoi                 : std_logic;
  signal sReg5GolMErr                       : unsigned(MAPPED_ERROR_VAL_WIDTH - 1 downto 0);
  signal sReg6Unary                         : unsigned(UNARY_WIDTH - 1 downto 0);
  signal sReg6SufLen                        : unsigned(SUFFIXLEN_WIDTH - 1 downto 0);
  signal sReg6SufVal                        : unsigned(SUFFIX_WIDTH - 1 downto 0);

  -- Output
  signal sBpRawV,  sBpGolV                  : std_logic;
  signal sBpWord                            : std_logic_vector(LIMIT - 1 downto 0);
  signal sBpWordV                           : std_logic;
  signal sBpValidLen                        : unsigned(log2ceil(LIMIT + 1) - 1 downto 0);
  signal sBsWord                            : std_logic_vector(BYTE_STUFFER_OUT_WIDTH - 1 downto 0);
  signal sBsWordV                           : std_logic;
  signal sBsValidB                          : unsigned(log2ceil(BYTE_STUFFER_OUT_WIDTH / 8 + 1) - 1 downto 0);
  signal sFramerVBytes                      : unsigned(log2ceil(OUT_WIDTH / 8 + 1) - 1 downto 0);

  -- Flush / framer control
  signal sBsFlush                           : std_logic;
  signal sBsAlmostFull                      : std_logic;
  signal sBsFlushDone                       : std_logic;
  signal sFramerEoi                         : std_logic;
  signal sFirstPixel                        : std_logic;
  signal sFramerStart                       : std_logic;
  signal sReadyOut                          : std_logic;

begin

  -------------------------------------------------------------------------------------------------------------
  -- ASSERTIONS
  -------------------------------------------------------------------------------------------------------------

  assert B_WIDTH >= BITNESS + 1 -- for a single sum
    report "A12: B_WIDTH must be >= BITNESS + 1 to avoid truncation"
    severity failure;

  assert A_WIDTH >= BITNESS + 1 -- for a single sum
    report "A12: A_WIDTH must be >= BITNESS + 1 to avoid truncation"
    severity failure;

  assert B_WIDTH >= N_WIDTH
    report "A11 & A13: B_WIDTH must be >= N_WIDTH to avoid truncation"
    severity failure;

  -------------------------------------------------------------------------------------------------------------
  -- STALL, CLOCK-ENABLE, AND READY LOGIC
  -------------------------------------------------------------------------------------------------------------
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
        if (sStallDelay = '1' and sStall = '1') then
          sStallLogic <= '1';
        else
          sStallLogic <= '0';
        end if;
      end if;
    end if;

  end process p_stall_control;

  -- Pipeline stall is sourced only from byte_stuffer's FIFO (the main design
  -- buffer). Framer back-pressure is absorbed by the byte_stuffer FIFO via a
  -- local ready/valid handshake (sFramerReady -> byte_stuffer.iReady).
  sStall <= sBsAlmostFullReg;
  -- Gating oReady on sStall alone leaves a one-cycle window where oReady='1'
  -- but the latch is still frozen, which silently drops the pixel handshaken
  -- in that cycle. OR-ing both keeps oReady low until acceptance is truly
  -- re-enabled.
  sStallUpstream <= sStall or sStallLogic;

  -- Per-stage clock-enable: update register only when not stalled AND there
  -- is a real token to load OR a real token to retire (transition to bubble).
  -- Once the register is sitting on a bubble with no upstream valid, CE=0
  -- holds it frozen so its combinational fan-out stops toggling.

  sCE1 <= '1' when sStallLogic = '0' and (sReg1V = '1' or sValid = '1') else
          '0';
  sCE2 <= '1' when sStallLogic = '0' and (sReg2V = '1' or sReg1V = '1') else
          '0';
  sCE3 <= '1' when sStallLogic = '0' and (sReg3V = '1' or sReg2V = '1') else
          '0';
  sCE4 <= '1' when sStallLogic = '0' and (sReg4V = '1' or sReg3V = '1') else
          '0';
  sCE5 <= '1' when sStallLogic = '0' and (sReg5V = '1' or sReg4V = '1') else
          '0';
  sCE6 <= '1' when sStallLogic = '0' and (sReg6V = '1' or sReg5V = '1') else
          '0';

  sReadyOut <= not iRst and not sStallUpstream; -- Stalls upstream
  oReady    <= sReadyOut;

  -- Input-port AXI4-Stream slave contract (iValid/iPixel/oReady).
  -- psl default clock is rising_edge(iClk);
  -- psl assert always (iRst = '1' -> oReady = '0') report "openjls_top: reset must hold oReady low";
  -- psl assert always ((iRst = '0' and sStallLogic = '1') -> oReady = '0') report "openjls_top: oReady must stay low while the input latch is frozen (no dropped beat)";
  -- psl assert always ((iRst = '0' and iValid = '1' and oReady = '1') -> next (sValid = '1')) report "openjls_top: an accepted pixel (iValid and oReady) must be committed next cycle";

  -------------------------------------------------------------------------------------------------------------
  -- Input Stage — Input register
  -------------------------------------------------------------------------------------------------------------
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

        -- Image resolution set to max value if invalid input
        -- if the user wants MAX_IMAGE_WIDTH/HEIGHT he can leave the inputs unwired (set to 0)
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
        if (iValid = '1' and sReadyOut = '1' and sStallLogic = '0') then -- handshake
          sPixel <= unsigned(iPixel);
          sValid <= '1';
        else
          sPixel <= (others => '0');
          sValid <= '0';
        end if;
      end if;
    end if;

  end process p_input_reg;

  -------------------------------------------------------------------------------------------------------------
  -- Stage 1 — Line buffer + A.1 gradients + A.3 mode selection
  -------------------------------------------------------------------------------------------------------------
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
      iPixel           => sPixel,
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

  -------------------------------------------------------------------------------------------------------------
  -- Register 1 (Stage 1 → Stage 2)
  -------------------------------------------------------------------------------------------------------------
  p_reg1 : process (iClk) is

    variable v : t_pipeline_token;

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sReg1    <= CO_TOKEN_NONE;
        sReg1V   <= '0';
        sReg1Eol <= '0';
        sReg1Eoi <= '0';
        sReg1D1  <= (others => '0');
        sReg1D2  <= (others => '0');
        sReg1D3  <= (others => '0');
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
        -- Tag this token with the current parity; flip after an EOI so the next
        -- image's first token (and onward) carries the opposite parity.
        sReg1Par <= sGenPar;
        if (sLbValid = '1' and sLbEoi = '1') then
          sGenPar <= not sGenPar;
        end if;
        sReg1D1 <= sS1D1;
        sReg1D2 <= sS1D2;
        sReg1D3 <= sS1D3;
      end if;
    end if;

  end process p_reg1;

  -------------------------------------------------------------------------------------------------------------
  -- Stage 2 — Regular: A.4 → A.4.1 → A.4.2
  -------------------------------------------------------------------------------------------------------------
  u_a4 : entity work.a4_quantization_gradients(behavioral)
    generic map (
      BITNESS => BITNESS,
      MAX_VAL => MAX_VAL
    )
    port map (
      iD1     => sReg1D1,
      iD2     => sReg1D2,
      iD3     => sReg1D3,
      oQ1     => sS2Q1,
      oQ2     => sS2Q2,
      oQ3     => sS2Q3
    );

  u_a4_1 : entity work.a4_1_quant_gradient_merging(behavioral)
    port map (
      iQ1   => sS2Q1,
      iQ2   => sS2Q2,
      iQ3   => sS2Q3,
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

  -------------------------------------------------------------------------------------------------------------
  -- Stage 2 — Run: A.14, A.15/A.16 (FSM), A.17
  -------------------------------------------------------------------------------------------------------------
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

  -- Stage 2 mode selection. Precedence: RI break (Golomb+raw) > raw-only.
  sS2TokenMode <= token_regular when sReg1.mode = token_regular else
                  token_run_interruption when sS2RiValid = '1' else
                  token_raw when sS2RawValid = '1' else
                  token_none;

  -- A.20.1 inline: regular Q from A.4.2; run Q = 366 if RItype else 365
  sS2Q <= sS2QReg when sReg1.mode = token_regular else
          to_unsigned(366, 9) when sS2RItype = '1' else
          to_unsigned(365, 9);

  -- Sticky context-RAM owner: parity of the last valid token that issued a read,
  -- held across read bubbles. Effective owner = live Reg1 parity, else held.
  p_ctx_owner : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sCtxOwnerPar <= '0';
      elsif (sReg1V = '1') then
        sCtxOwnerPar <= sReg1Par;
      end if;
    end if;

  end process p_ctx_owner;

  sCtxRdPar <= sReg1Par when sReg1V = '1' else
               sCtxOwnerPar;

  -- Refuse a writeback whose parity no longer owns the context RAM: it is a
  -- straggler from a finished image and would corrupt the next image's contexts.
  sCtxWrEn <= sReg3V and
              bool2bit(sReg3Par = sCtxRdPar) and
              (bool2bit(sReg3.mode = token_regular) or
               bool2bit(sReg3.mode = token_run_interruption));

  -- Pack writeback word by mode (Murat BRAM encoding):
  --   A : A_WIDTH → A_STORED (A.12 output fits; the iNq=RESET-1→RESET halving caps it).
  --   B : magnitude only (Bq ≤ 0 after A.13 clamp).   N : 0 ⇔ RESET.
  sCtxWrData <= std_logic_vector(resize(sS4AqNew, A_STORED)) &
                std_logic_vector(resize(unsigned(-sS4BqNew), B_STORED)) &
                std_logic_vector(sS4CqNew) &
                std_logic_vector(sNqEncReg)
                when sReg3.mode = token_regular else
                std_logic_vector(resize(sS4RiAqNew, A_STORED)) &
                std_logic_vector(sS4RiNnNew) &
                std_logic_vector(to_signed(0, C_STORED)) &
                std_logic_vector(sNqEncRi);

  sNqEncReg <= (others => '0') when sS4NqNew = to_unsigned(RESET, N_WIDTH) else
               resize(sS4NqNew, N_STORED);

  sNqEncRi <= (others => '0') when sS4RiNqNew = to_unsigned(RESET, N_WIDTH) else
              resize(sS4RiNqNew, N_STORED);

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
      iWrAddr     => std_logic_vector(sReg3.Q),
      iWrEn       => sCtxWrEn and sCE3,
      iWrData     => sCtxWrData,
      iRdAddr     => std_logic_vector(sS2Q),
      iRdEn       => sReg1V and sCE1 and (bool2bit(sS2TokenMode = TOKEN_REGULAR) or
      bool2bit(sS2TokenMode = TOKEN_RUN_INTERRUPTION)),
      iEndOfImage => sReg1Eoi,
      oRdData     => sCtxRdData
    );

  -- Unpack read port (RdLatency=1 → valid at Stage 3). Q3==Q4 forwarding: when
  -- Stage 4 writes back the Q Stage 3 is reading, use the live update outputs
  -- (BRAM read is stale). Decode mirrors encode: A zero-extend, B = -stored, N 0 ⇒ RESET.
  sS3Aq <= sS4AqNew when sFwdRegHit = '1' else
           sS4RiAqNew when sFwdRiHit = '1' else
           resize(unsigned(sCtxRdData(CTX_A_HI downto CTX_A_LO)), A_WIDTH);

  -- Bq is regular-only (the B slot carries Nn for RI, handled below).
  sS3Bq <= sS4BqNew when sFwdRegHit = '1' else
           - signed(resize(unsigned(sCtxRdData(CTX_B_HI downto CTX_B_LO)), B_WIDTH));

  -- Cq forwarding is handled by the speculative 3-chain via sS3CqBase.
  sS3Cq <= sS4CqNew when sFwdRegHit = '1' else
           signed(sCtxRdData(CTX_C_HI downto CTX_C_LO));

  sS3Nq <= sS4NqNew when sFwdRegHit = '1' else
           sS4RiNqNew when sFwdRiHit = '1' else
           to_unsigned(RESET, N_WIDTH) when unsigned(sCtxRdData(CTX_N_HI downto CTX_N_LO)) = 0 else
           resize(unsigned(sCtxRdData(CTX_N_HI downto CTX_N_LO)), N_WIDTH);

  -- Nn is only meaningful for RI; mask to zero for regular so downstream
  -- doesn't see Bq LSBs misinterpreted as Nn.
  sS3Nn <= sS4RiNnNew when sFwdRiHit = '1' else
           (others => '0') when sReg2.mode = token_regular else
           unsigned(sCtxRdData(CTX_NN_HI downto CTX_NN_LO));

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

  -------------------------------------------------------------------------------------------------------------
  -- Register 2 (Stage 2 → Stage 3)
  -------------------------------------------------------------------------------------------------------------
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
      elsif (sCE2 = '1') then
        -- Build Reg2 per mode; unused fields stay at CO_TOKEN_NONE defaults so
        -- downstream never sees stale values.
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
      end if;
    end if;

  end process p_reg2;

  -------------------------------------------------------------------------------------------------------------
  -- Stage 3 — Regular: A.5 + speculative 3-chain A.6..A.9
  -------------------------------------------------------------------------------------------------------------

  sS3Px <= sReg2Px;

  -- Forwarding hits: Stage 2 read Q matches Stage 4 writeback Q.
  -- Stage-4 mode selects which update output to forward; Stage-2 mode is
  -- implied by the Q match (regular Q < 365, RI Q ∈ {365,366}).
  -- Same-parity guard: never forward an update across an image boundary (the
  -- two tokens can alias on the same Q — e.g. the run contexts — when one is a
  -- straggler from the previous image).
  sFwdRegHit <= '1' when sReg2V = '1' and sReg3V = '1'
                         and sReg2Par = sReg3Par
                         and sReg2.Q = sReg3.Q
                         and sReg3.mode = token_regular else
                '0';

  sFwdRiHit <= '1' when sReg2V = '1' and sReg3V = '1'
                        and sReg2Par = sReg3Par
                        and sReg2.Q = sReg3.Q
                        and sReg3.mode = token_run_interruption else
               '0';

  -- Speculative-chain Cq base: on a hit use the pre-update sReg3.Cq (DeltaCq picks
  -- the ±1/0 candidate matching sS4CqNew); on a miss the BRAM read is already correct.
  sS3CqBase <= sReg3.Cq when sFwdRegHit = '1' else
               sS3Cq;

  -- Clamped ±1 variants
  sS3CqP1 <= to_signed(MAX_C, C_WIDTH) when sS3CqBase = to_signed(MAX_C, C_WIDTH) else
             sS3CqBase + 1;
  sS3CqM1 <= to_signed(MIN_C, C_WIDTH) when sS3CqBase = to_signed(MIN_C, C_WIDTH) else
             sS3CqBase - 1;

  -- A.6 clipping and A.7 error arithmetic run in parallel inside each
  -- candidate. The forwarded Cq no longer crosses a corrected-Px adder,
  -- saturation mux, and then a second full-width error subtractor.
  -- Central chain (DeltaCq = 0)
  u_a6a7_c : entity work.a6_a7_prediction_error(behavioral)
    generic map (
      BITNESS => BITNESS, MAX_VAL => MAX_VAL
    )
    port map (
      iIx       => sReg2.Ix(BITNESS - 1 downto 0),
      iPx       => sS3Px,
      iSign     => sReg2.Sign,
      iCq       => sS3CqBase,
      oErrorVal => sS3Err7C
    );

  u_a9_c : entity work.a9_modulo_reduction(behavioral)
    generic map (
      BITNESS   => BITNESS, RANGE_P => RANGE_P
    )
    port map (
      iErrorVal => sS3Err7C,
      oErrorVal => sS3Err9C
    );

  -- +1 chain (DeltaCq = +1)
  u_a6a7_p : entity work.a6_a7_prediction_error(behavioral)
    generic map (
      BITNESS => BITNESS, MAX_VAL => MAX_VAL
    )
    port map (
      iIx       => sReg2.Ix(BITNESS - 1 downto 0),
      iPx       => sS3Px,
      iSign     => sReg2.Sign,
      iCq       => sS3CqP1,
      oErrorVal => sS3Err7P
    );

  u_a9_p : entity work.a9_modulo_reduction(behavioral)
    generic map (
      BITNESS   => BITNESS, RANGE_P => RANGE_P
    )
    port map (
      iErrorVal => sS3Err7P,
      oErrorVal => sS3Err9P
    );

  -- −1 chain (DeltaCq = −1)
  u_a6a7_m : entity work.a6_a7_prediction_error(behavioral)
    generic map (
      BITNESS => BITNESS, MAX_VAL => MAX_VAL
    )
    port map (
      iIx       => sReg2.Ix(BITNESS - 1 downto 0),
      iPx       => sS3Px,
      iSign     => sReg2.Sign,
      iCq       => sS3CqM1,
      oErrorVal => sS3Err7M
    );

  u_a9_m : entity work.a9_modulo_reduction(behavioral)
    generic map (
      BITNESS   => BITNESS, RANGE_P => RANGE_P
    )
    port map (
      iErrorVal => sS3Err7M,
      oErrorVal => sS3Err9M
    );

  -- DeltaCq from live Stage-4 A.13. On miss, sDeltaCq is irrelevant (sFwdRegHit=0).
  sDeltaCq <= sS4CqNew - sReg3.Cq;

  sSpecUseM <= '1' when sFwdRegHit = '1' and sDeltaCq < 0 else
               '0';
  sSpecUseP <= '1' when sFwdRegHit = '1' and sDeltaCq > 0 else
               '0';

  sS3Err9Sel <= sS3Err9M when sSpecUseM = '1' else
                sS3Err9P when sSpecUseP = '1' else
                sS3Err9C;

  -------------------------------------------------------------------------------------------------------------
  -- Stage 3 — RI: A.19, A.20
  -------------------------------------------------------------------------------------------------------------
  u_a19 : entity work.a19_run_interruption_error(behavioral)
    generic map (
      BITNESS => BITNESS,
      RANGE_P => RANGE_P
    )
    port map (
      iErrval => sReg2.Errval(BITNESS downto 0),
      iRItype => sReg2.RiType,
      iRa     => sReg2.Ra(BITNESS - 1 downto 0),
      iRb     => sReg2.Rb(BITNESS - 1 downto 0),
      oErrval => sS3RiErr19,
      oSign   => sS3RiSign
    );

  -- A.20: single context read returns (Aq, Nq) for Q ∈ {365, 366}.
  u_a20 : entity work.a20_compute_temp(behavioral)
    generic map (
      A_WIDTH => A_WIDTH,
      N_WIDTH => N_WIDTH
    )
    port map (
      iRItype => sReg2.RiType,
      iAq     => sS3Aq,
      iNq     => sS3Nq,
      oTemp   => sS3RiTemp
    );

  -------------------------------------------------------------------------------------------------------------
  -- Register 3 (Stage 3 → Stage 4) — carry per-mode Errval / Temp / Sign
  -------------------------------------------------------------------------------------------------------------
  p_reg3 : process (iClk) is

    variable v : t_pipeline_token;

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sReg3    <= CO_TOKEN_NONE;
        sReg3V   <= '0';
        sReg3Eoi <= '0';
        sReg3Par <= '0';
      elsif (sCE3 = '1') then
        v      := sReg2;
        v.Aq   := sS3Aq;
        v.Bq   := sS3Bq;
        v.Cq   := sS3Cq;
        v.Nq   := sS3Nq;
        v.Nn   := sS3Nn;
        v.Temp := (others => '0');

        case sReg2.mode is

          when token_regular =>

            v.Errval := resize(sS3Err9Sel, v.Errval'length);

          when token_run_interruption =>

            v.Errval := resize(sS3RiErr19, v.Errval'length);
            v.Sign   := sS3RiSign;
            v.Temp   := sS3RiTemp;

          when others =>

            null;

        end case;

        if (sReg2V = '0') then
          v := CO_TOKEN_NONE;
        end if;
        sReg3    <= v;
        sReg3V   <= sReg2V;
        sReg3Eoi <= sReg2Eoi;
        sReg3Par <= sReg2Par;
      end if;
    end if;

  end process p_reg3;

  -------------------------------------------------------------------------------------------------------------
  -- Stage 4 — Shared A.10; regular A.12 + A.13; RI A.23
  --           A.10's iAq is muxed: regular → Aq, RI → Temp.
  -------------------------------------------------------------------------------------------------------------
  sS4AqSel <= sReg3.Temp when sReg3.mode = token_run_interruption else
              sReg3.Aq;

  u_a10 : entity work.a10_compute_k(behavioral)
    generic map (
      A_WIDTH => A_WIDTH,
      K_WIDTH => K_WIDTH,
      N_WIDTH => N_WIDTH
    )
    port map (
      iNq     => sReg3.Nq,
      iAq     => sS4AqSel,
      oK      => sS4K
    );

  u_a12 : entity work.a12_variables_update(rtl)
    generic map (
      ERROR_WIDTH => ERROR_WIDTH,
      A_WIDTH     => A_WIDTH,
      B_WIDTH     => B_WIDTH,
      N_WIDTH     => N_WIDTH,
      RESET       => RESET
    )
    port map (
      iErrorVal   => sReg3.Errval(BITNESS downto 0),
      iAq         => sReg3.Aq,
      iBq         => sReg3.Bq,
      iNq         => sReg3.Nq,
      oAq         => sS4AqNew,
      oBq         => sS4BqMid,
      oNq         => sS4NqNew
    );

  u_a13 : entity work.a13_update_bias(rtl)
    generic map (
      B_WIDTH => B_WIDTH,
      N_WIDTH => N_WIDTH,
      C_WIDTH => C_WIDTH,
      MIN_C   => MIN_C,
      MAX_C   => MAX_C
    )
    port map (
      iBq     => sS4BqMid,
      iNq     => sS4NqNew,
      iCq     => sReg3.Cq,
      oBq     => sS4BqNew,
      oCq     => sS4CqNew
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
      iErrVal     => sReg3.Errval(BITNESS downto 0),
      iRItype     => sReg3.RiType,
      iAq         => sReg3.Aq,
      iNq         => sReg3.Nq,
      iNn         => sReg3.Nn,
      oAq         => sS4RiAqNew,
      oNq         => sS4RiNqNew,
      oNn         => sS4RiNnNew
    );

  -------------------------------------------------------------------------------------------------------------
  -- Register 4 (Stage 4 → Stage 5)
  -------------------------------------------------------------------------------------------------------------
  p_reg4 : process (iClk) is

    variable v : t_pipeline_token;

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sReg4    <= CO_TOKEN_NONE;
        sReg4V   <= '0';
        sReg4Eoi <= '0';
      elsif (sCE4 = '1') then
        v   := sReg3;
        v.k := resize(sS4K, K_WIDTH);
        if (sReg3V = '0') then
          v := CO_TOKEN_NONE;
        end if;
        sReg4    <= v;
        sReg4V   <= sReg3V;
        sReg4Eoi <= sReg3Eoi;
      end if;
    end if;

  end process p_reg4;

  -------------------------------------------------------------------------------------------------------------
  -- Stage 5 — Regular: A.11; RI: A.21 + A.22;
  -------------------------------------------------------------------------------------------------------------
  u_a11 : entity work.a11_error_mapping(behavioral)
    generic map (
      N_WIDTH                => N_WIDTH,
      B_WIDTH                => B_WIDTH,
      K_WIDTH                => K_WIDTH,
      ERROR_WIDTH            => ERROR_WIDTH,
      MAPPED_ERROR_VAL_WIDTH => MAPPED_ERROR_VAL_WIDTH
    )
    port map (
      iK                     => sReg4.k,
      iBq                    => sReg4.Bq,
      iNq                    => sReg4.Nq,
      iErrorVal              => sReg4.Errval(BITNESS downto 0),
      oMappedErrorVal        => sS5MErrval
    );

  u_a21 : entity work.a21_compute_map(behavioral)
    generic map (
      K_WIDTH     => K_WIDTH,
      N_WIDTH     => N_WIDTH,
      ERROR_WIDTH => ERROR_WIDTH
    )
    port map (
      iK          => sReg4.k,
      iErrval     => sReg4.Errval(BITNESS downto 0),
      iNn         => resize(sReg4.Nn, N_WIDTH),
      iNq         => sReg4.Nq,
      oMap        => sS5RiMap
    );

  u_a22 : entity work.a22_errval_mapping(behavioral)
    generic map (
      ERROR_WIDTH         => ERROR_WIDTH,
      MAPPED_ERRVAL_WIDTH => MAPPED_ERROR_VAL_WIDTH
    )
    port map (
      iErrval             => sReg4.Errval(BITNESS downto 0),
      iRItype             => sReg4.RiType,
      iMap                => sS5RiMap,
      oEmErrVal           => sS5RiEmErrval
    );

  sS5GolMErr <= sS5MErrval when sReg4.mode = token_regular else
                sS5RiEmErrval;

  -------------------------------------------------------------------------------------------------------------
  -- Register 5 (Stage 5 mapping → A.11_1 golomb encoder)
  -------------------------------------------------------------------------------------------------------------
  p_reg5 : process (iClk) is

    variable v : t_pipeline_token;

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sReg5        <= CO_TOKEN_NONE;
        sReg5V       <= '0';
        sReg5Eoi     <= '0';
        sReg5GolMErr <= (others => '0');
      elsif (sCE5 = '1') then
        v := sReg4;
        if (sReg4V = '0') then
          v := CO_TOKEN_NONE;
        end if;
        sReg5        <= v;
        sReg5V       <= sReg4V;
        sReg5Eoi     <= sReg4Eoi;
        sReg5GolMErr <= sS5GolMErr;
      end if;
    end if;

  end process p_reg5;

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
      iK                     => sReg5.k,
      iMappedErrorVal        => sReg5GolMErr,
      iRiMode                => bool2bit(sReg5.mode = TOKEN_RUN_INTERRUPTION),
      iRunIndex              => sReg5.RiRunIndex,
      oUnaryZeros            => sS5Unary,
      oSuffixLen             => sS5SufLen,
      oSuffixVal             => sS5SufVal
    );

  -------------------------------------------------------------------------------------------------------------
  -- Register 6 (golomb encoder → bit packer)
  -------------------------------------------------------------------------------------------------------------
  p_reg6 : process (iClk) is

    variable v : t_pipeline_token;

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sReg6       <= CO_TOKEN_NONE;
        sReg6V      <= '0';
        sReg6Eoi    <= '0';
        sReg6Unary  <= (others => '0');
        sReg6SufLen <= (others => '0');
        sReg6SufVal <= (others => '0');
      elsif (sCE6 = '1') then
        v := sReg5;
        if (sReg5V = '0') then
          v := CO_TOKEN_NONE;
        end if;
        sReg6       <= v;
        sReg6V      <= sReg5V;
        sReg6Eoi    <= sReg5Eoi;
        sReg6Unary  <= sS5Unary;
        sReg6SufLen <= sS5SufLen;
        sReg6SufVal <= sS5SufVal;
      end if;
    end if;

  end process p_reg6;

  -------------------------------------------------------------------------------------------------------------
  -- Output — bit packer → byte stuffer → framer
  --          internally registered in the IPs
  -------------------------------------------------------------------------------------------------------------
  sBpRawV <= '1' when sReg6V = '1' and sStallLogic = '0'
                      and (sReg6.mode = token_run_interruption or sReg6.mode = token_raw) else
             '0';
  sBpGolV <= '1' when sReg6V = '1' and sStallLogic = '0'
                      and (sReg6.mode = token_regular or sReg6.mode = token_run_interruption) else
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
      iRawLen         => sReg6.RawLen,
      iRawVal         => sReg6.RawVal,
      iGolombValid    => sBpGolV,
      iUnaryZeros     => sReg6Unary,
      iSuffixLen      => sReg6SufLen,
      iSuffixVal      => sReg6SufVal,
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

  -- AXI-Stream tkeep: one bit per byte

  gen_keep : for i in 0 to OUT_WIDTH / 8 - 1 generate
    oKeep(OUT_WIDTH / 8 - 1 - i) <= '1' when sFramerVBytes > i else
                                    '0';
  end generate gen_keep;

  -------------------------------------------------------------------------------------------------------------
  -- Flush / framer control
  -------------------------------------------------------------------------------------------------------------

  -- Pass the flush control from the EOI pipeline to the output stages
  p_flush_control : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sBsFlush <= '0';
      elsif (sStallLogic = '0') then
        sBsFlush <= sReg6Eoi;
      end if;
    end if;

  end process p_flush_control;

  sFramerEoi <= sBsFlushDone;

  -- First-pixel tracker. line_buffer flags EOI combinationally on the image's
  -- last accepted pixel, so the next accepted pixel starts the following image
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

end architecture rtl;
