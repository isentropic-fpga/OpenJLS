-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a6_a7_prediction_error: T.87 A.6 + A.7 fused, prediction correction and error
--
-- a6_clip_bounds gives the C[Q] range where A.6 doesn't clip and a6_clip_errors the error when it does.
-- Both are off the C[Q] path, which leaves the late C[Q] one narrow compare and one subtract.
-- a6_clip_sat decides a stage ahead whether a bound leaves that compare's range.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a6_clip_bounds is
  generic (
    BITNESS : natural range 8 to 16 := CO_BITNESS_STD;
    MAX_VAL : natural := CO_MAX_VAL_STD
  );
  port (
    iPx   : in    unsigned(BITNESS - 1 downto 0);
    iSign : in    std_logic;
    -- a6_clip_sat of iPx, iSign, a stage ahead
    iLoSat : in    std_logic;
    iHiSat : in    std_logic;
    -- A.6 clips when Cq < oLo or Cq > oHi; oLo <= 0 <= oHi
    oLo   : out   signed(CO_CQ_WIDTH downto 0);
    oHi   : out   signed(CO_CQ_WIDTH downto 0)
  );
end entity a6_clip_bounds;

architecture behavioral of a6_clip_bounds is
  -- Unsaturated bounds fit one bit past the Cq range, so the subtracts are that wide (mod 2 ** (CO_CQ_WIDTH + 1))
  constant MAX_LO : unsigned(CO_CQ_WIDTH downto 0) := to_unsigned(MAX_VAL mod 2 ** (CO_CQ_WIDTH + 1), CO_CQ_WIDTH + 1);

  signal sPx            : unsigned(CO_CQ_WIDTH downto 0);
  signal sLoVal, sHiVal : unsigned(CO_CQ_WIDTH downto 0);
begin
  sPx <= resize(iPx, CO_CQ_WIDTH + 1);

  -- Positive sign: lo = -Px, hi = MAX_VAL - Px. Negative: lo = Px - MAX_VAL, hi = Px.
  sLoVal <= 0 - sPx when iSign = CO_SIGN_POS else
            sPx - MAX_LO;
  sHiVal <= MAX_LO - sPx when iSign = CO_SIGN_POS else
            sPx;
  oLo <= to_signed(- 2 ** CO_CQ_WIDTH, oLo'length) when iLoSat = '1' else
         signed(sLoVal);
  oHi <= to_signed(2 ** CO_CQ_WIDTH - 1, oHi'length) when iHiSat = '1' else
         signed(sHiVal);
end architecture behavioral;

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a6_clip_sat is
  generic (
    BITNESS : natural range 8 to 16 := CO_BITNESS_STD;
    MAX_VAL : natural := CO_MAX_VAL_STD
  );
  port (
    iPx    : in    unsigned(BITNESS - 1 downto 0);
    iSign  : in    std_logic;
    -- The a6_clip_bounds bound saturates to the C[Q] range
    oLoSat : out   std_logic;
    oHiSat : out   std_logic
  );
end entity a6_clip_sat;

architecture behavioral of a6_clip_sat is
  -- A bound beyond +-2 ** CO_CQ_WIDTH can't clip Cq, so saturating there is safe
  signal sPxBig, sCompBig : std_logic;
begin
  gen_narrow : if BITNESS <= CO_CQ_WIDTH generate
    sPxBig <= '0';
  end generate gen_narrow;

  gen_wide : if BITNESS > CO_CQ_WIDTH generate
    sPxBig <= or iPx(BITNESS - 1 downto CO_CQ_WIDTH);
  end generate gen_wide;

  -- MAX_VAL - Px is the complement of Px in the binary range: top bits alone decide, no carry chain
  gen_binary : if BITNESS > CO_CQ_WIDTH and MAX_VAL = 2 ** BITNESS - 1 generate
    sCompBig <= not (and iPx(BITNESS - 1 downto CO_CQ_WIDTH));
  end generate gen_binary;

  gen_general : if BITNESS <= CO_CQ_WIDTH or MAX_VAL /= 2 ** BITNESS - 1 generate
    sCompBig <= '1' when to_integer(iPx) + 2 ** CO_CQ_WIDTH <= MAX_VAL else
                '0';
  end generate gen_general;

  oLoSat <= sPxBig when iSign = CO_SIGN_POS else
            sCompBig;
  oHiSat <= sCompBig when iSign = CO_SIGN_POS else
            sPxBig;
end architecture behavioral;

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a6_clip_errors is
  generic (
    BITNESS : natural range 8 to 16 := CO_BITNESS_STD;
    MAX_VAL : natural := CO_MAX_VAL_STD
  );
  port (
    iIx    : in    unsigned(BITNESS - 1 downto 0);
    iSign  : in    std_logic;
    -- Errval for Cq below / above the a6_clip_bounds range
    oAtLo  : out   signed(BITNESS downto 0);
    oAtHi  : out   signed(BITNESS downto 0)
  );
end entity a6_clip_errors;

architecture behavioral of a6_clip_errors is
begin
  -- Below the range, Px clips to 0 (positive sign) or MAX_VAL; above it the other way
  oAtLo <= signed('0' & iIx) when iSign = CO_SIGN_POS else
           to_signed(MAX_VAL, oAtLo'length) - signed('0' & iIx);
  oAtHi <= signed('0' & iIx) - to_signed(MAX_VAL, oAtHi'length) when iSign = CO_SIGN_POS else
           - signed('0' & iIx);
end architecture behavioral;

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
    -- a6_clip_bounds of iPx, iSign and a6_clip_errors of iIx, iSign
    iLo       : in    signed(CO_CQ_WIDTH downto 0);
    iHi       : in    signed(CO_CQ_WIDTH downto 0);
    iAtLo     : in    signed(BITNESS downto 0);
    iAtHi     : in    signed(BITNESS downto 0);
    iCq       : in    signed(CO_CQ_WIDTH - 1 downto 0);
    oErrorVal : out   signed(BITNESS downto 0)
  );
end entity a6_a7_prediction_error;

architecture behavioral of a6_a7_prediction_error is
  signal sDelta, sRawError : signed(BITNESS downto 0);
begin
  assert MAX_VAL < 2 ** BITNESS
    report "a6_a7_prediction_error: MAX_VAL must fit BITNESS"
    severity failure;

  -- Error as (Ix - Px) - Cq so the pixel difference settles before the forwarded Cq
  sDelta <= signed('0' & iIx) - signed('0' & iPx) when iSign = CO_SIGN_POS else
            signed('0' & iPx) - signed('0' & iIx);
  sRawError <= sDelta - resize(iCq, sRawError'length);

  -- sRawError can only wrap when clipped, where a boundary error is selected
  oErrorVal <= iAtLo when iCq < iLo else
               iAtHi when iCq > iHi else
               sRawError;

  postponed assert is_x(oErrorVal) or iIx > MAX_VAL or iPx > MAX_VAL or abs(to_integer(oErrorVal)) <= MAX_VAL
    report "a6_a7: Errval out of range" severity error;
end architecture behavioral;
