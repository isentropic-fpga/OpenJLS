-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a6_prediction_correction: T.87 A.6, prediction correction by C[Q]

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a6_prediction_correction is
  generic (
    BITNESS : natural := CO_BITNESS_STD;
    MAX_VAL : natural := CO_MAX_VAL_STD
  );
  port (
    iPx     : in    unsigned (BITNESS - 1 downto 0);
    iSign   : in    std_logic;
    iCq     : in    signed (CO_CQ_WIDTH - 1 downto 0);
    oPx     : out   unsigned (BITNESS - 1 downto 0)
  );
end entity a6_prediction_correction;

architecture behavioral of a6_prediction_correction is

  constant EXT_WIDTH : natural                        := BITNESS + 2;
  constant ZERO_S    : signed(EXT_WIDTH - 1 downto 0) := (others => '0');
  constant MAX_S     : signed(EXT_WIDTH - 1 downto 0) := to_signed(MAX_VAL, EXT_WIDTH);

  signal sPxPlusCq   : signed (EXT_WIDTH - 1 downto 0);
  signal sPxMinusCq  : signed (EXT_WIDTH - 1 downto 0);

  signal sAddSat     : unsigned (BITNESS - 1 downto 0);
  signal sSubSat     : unsigned (BITNESS - 1 downto 0);

begin

  sPxPlusCq  <= resize(signed('0' & iPx), EXT_WIDTH) + resize(iCq, EXT_WIDTH);
  sPxMinusCq <= resize(signed('0' & iPx), EXT_WIDTH) - resize(iCq, EXT_WIDTH);

  sAddSat <= (others => '0') when (sPxPlusCq < ZERO_S) else
             TO_UNSIGNED(MAX_VAL, BITNESS) when (sPxPlusCq > MAX_S) else
             unsigned(sPxPlusCq(BITNESS - 1 downto 0));
  sSubSat <= (others => '0') when (sPxMinusCq < ZERO_S) else
             TO_UNSIGNED(MAX_VAL, BITNESS) when (sPxMinusCq > MAX_S) else
             unsigned(sPxMinusCq(BITNESS - 1 downto 0));

  oPx <= sAddSat when iSign = CO_SIGN_POS else
         sSubSat;

  postponed assert is_x(oPx) or oPx <= MAX_VAL report "a6: Px above MAX_VAL" severity error;

end architecture behavioral;
