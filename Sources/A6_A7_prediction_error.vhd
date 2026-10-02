-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- Combined T.87 A.6/A.7 regular-mode prediction correction and error.
-- Cq arrives late (context RAM read) while Ix, Px and Sign are early, so all
-- BITNESS-wide arithmetic uses only the early inputs and Cq meets only
-- Cq-width compares and adders: the late path does not grow with BITNESS.

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
  constant CQ_W  : natural := CO_CQ_WIDTH;
  constant LIM_W : natural := CQ_W + 1;
  constant CQ_LO : integer := -2 ** (CQ_W - 1);
  constant CQ_HI : integer := 2 ** (CQ_W - 1) - 1;

  -- Clip threshold for Cq, saturated one past the Cq range so the compare
  -- stays Cq-width: CQ_LO - 1 always clips on '>', CQ_HI + 1 always on '<'.
  function sat(v : integer) return signed is
  begin
    if v < CQ_LO - 1 then
      return to_signed(CQ_LO - 1, LIM_W);
    elsif v > CQ_HI + 1 then
      return to_signed(CQ_HI + 1, LIM_W);
    end if;
    return to_signed(v, LIM_W);
  end function;

  signal sCq                         : signed(LIM_W - 1 downto 0);
  signal sLimZero, sLimMax           : signed(LIM_W - 1 downto 0);
  signal sClipZero, sClipMax         : boolean;
  signal sDelta, sRawError           : signed(BITNESS downto 0);
  signal sHi, sHiM1, sHiP1, sHiSel   : signed(BITNESS - CQ_W downto 0);
  signal sLowDiff                    : signed(CQ_W + 1 downto 0);
  signal sAtZero, sAtMax             : signed(BITNESS downto 0);
begin
  assert MAX_VAL < 2 ** BITNESS
    report "a6_a7_prediction_error: MAX_VAL must fit BITNESS"
    severity failure;

  sCq <= resize(iCq, LIM_W);

  -- A.6 clipping. Positive sign corrects Px + Cq, negative Px - Cq:
  --   below zero:    Cq < -Px          | Cq > Px
  --   above MAX_VAL: Cq > MAX_VAL - Px | Cq < Px - MAX_VAL
  sLimZero <= sat(-to_integer(iPx)) when iSign = CO_SIGN_POS else
              sat(to_integer(iPx));
  sLimMax  <= sat(MAX_VAL - to_integer(iPx)) when iSign = CO_SIGN_POS else
              sat(to_integer(iPx) - MAX_VAL);

  sClipZero <= sCq < sLimZero when iSign = CO_SIGN_POS else sCq > sLimZero;
  sClipMax  <= sCq > sLimMax  when iSign = CO_SIGN_POS else sCq < sLimMax;

  -- A.7 before clipping: Ix - (Px + Cq) = (Ix - Px) - Cq for positive sign,
  -- (Px - Cq) - Ix = (Px - Ix) - Cq for negative.
  sDelta <= signed('0' & iIx) - signed('0' & iPx) when iSign = CO_SIGN_POS else
            signed('0' & iPx) - signed('0' & iIx);

  -- Carry-select Delta - Cq: the low byte absorbs Cq and borrows or carries
  -- at most one into the precomputed upper part.
  sHi   <= sDelta(BITNESS downto CQ_W);
  sHiM1 <= sHi - 1;
  sHiP1 <= sHi + 1;
  sLowDiff <= signed("00" & sDelta(CQ_W - 1 downto 0)) - resize(iCq, CQ_W + 2);
  with sLowDiff(CQ_W + 1 downto CQ_W) select sHiSel <=
    sHiM1 when "11",
    sHiP1 when "01",
    sHi   when others;
  sRawError <= sHiSel & sLowDiff(CQ_W - 1 downto 0);

  -- Errors for the two clipped predictions depend only on the input pixel.
  sAtZero <= signed('0' & iIx) when iSign = CO_SIGN_POS else -signed('0' & iIx);
  sAtMax <= signed('0' & iIx) - to_signed(MAX_VAL, sAtMax'length) when iSign = CO_SIGN_POS else
            to_signed(MAX_VAL, sAtMax'length) - signed('0' & iIx);

  -- sRawError wraps only when the prediction is clipped, and then a boundary
  -- error is selected instead.
  oErrorVal <= sAtZero when sClipZero else
               sAtMax when sClipMax else
               sRawError;
end architecture behavioral;
