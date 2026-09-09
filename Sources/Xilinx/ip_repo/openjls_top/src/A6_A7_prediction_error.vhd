-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- Combined T.87 A.6/A.7 regular-mode prediction correction and error.
-- Compute the unclipped error in parallel with prediction clipping, keeping
-- the late context bias off a serial corrected-prediction/error adder chain.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a6_a7_prediction_error is
  generic (
    BITNESS : natural range 8 to 16 := CO_BITNESS_STD;
    MAX_VAL : natural := CO_MAX_VAL_STD
  );
  port (
    iIx       : in    unsigned(BITNESS - 1 downto 0);
    iPx       : in    unsigned(BITNESS - 1 downto 0);
    iSign     : in    std_logic;
    iCq       : in    signed(CO_CQ_WIDTH - 1 downto 0);
    oErrorVal : out   signed(BITNESS downto 0)
  );
end entity a6_a7_prediction_error;

architecture behavioral of a6_a7_prediction_error is
  constant EXT_WIDTH : natural := BITNESS + 2;
  constant MAX_S : signed(EXT_WIDTH - 1 downto 0) := to_signed(MAX_VAL, EXT_WIDTH);

  signal sPxPlusCq, sPxMinusCq, sCorrectedPx : signed(EXT_WIDTH - 1 downto 0);
  signal sDeltaPos, sDeltaNeg, sDelta, sRawError : signed(BITNESS downto 0);
  signal sAtZero, sAtMax : signed(BITNESS downto 0);
begin
  assert MAX_VAL < 2 ** BITNESS
    report "a6_a7_prediction_error: MAX_VAL must fit BITNESS"
    severity failure;

  -- A.6 clipping decision. Neither sum feeds the error subtraction.
  sPxPlusCq  <= resize(signed('0' & iPx), EXT_WIDTH) + resize(iCq, EXT_WIDTH);
  sPxMinusCq <= resize(signed('0' & iPx), EXT_WIDTH) - resize(iCq, EXT_WIDTH);
  sCorrectedPx <= sPxPlusCq when iSign = CO_SIGN_POS else sPxMinusCq;

  -- Before clipping:
  -- positive sign: Ix - (Px + Cq) = (Ix - Px) - Cq
  -- negative sign: (Px - Cq) - Ix = (Px - Ix) - Cq
  -- The pixel-only difference can settle before the forwarded context bias.
  sDeltaPos <= signed('0' & iIx) - signed('0' & iPx);
  sDeltaNeg <= signed('0' & iPx) - signed('0' & iIx);
  sDelta <= sDeltaPos when iSign = CO_SIGN_POS else sDeltaNeg;
  sRawError <= sDelta - resize(iCq, sRawError'length);

  -- Errors for the two clipped predictions depend only on the input pixel.
  sAtZero <= signed('0' & iIx) when iSign = CO_SIGN_POS else -signed('0' & iIx);
  sAtMax <= signed('0' & iIx) - to_signed(MAX_VAL, sAtMax'length) when iSign = CO_SIGN_POS else
            to_signed(MAX_VAL, sAtMax'length) - signed('0' & iIx);

  -- Any overflow of sRawError occurs only when the prediction is clipped,
  -- in which case the corresponding boundary error is selected instead.
  oErrorVal <= sAtZero when sCorrectedPx < 0 else
               sAtMax when sCorrectedPx > MAX_S else
               sRawError;
end architecture behavioral;
