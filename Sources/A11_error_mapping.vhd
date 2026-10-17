-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

----------------------------------------------------------------------------------
-- Engineer:    Vitor Mendes Camilo
--
-- Module Name: A11_error_mapping - Behavioral
--
-- Description:                     Code segment A.11
--                                  Error mapping to non-negative values
--
----------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a11_error_mapping is
  generic (
    N_WIDTH                : natural := CO_NQ_WIDTH_STD;
    B_WIDTH                : natural := CO_BQ_WIDTH_STD;
    K_WIDTH                : natural := CO_K_WIDTH_STD;
    ERROR_WIDTH            : natural := CO_ERROR_VALUE_WIDTH_STD;
    MAPPED_ERROR_VAL_WIDTH : natural := CO_MAPPED_ERROR_VAL_WIDTH_STD
  );
  port (
    iK                     : in    unsigned (K_WIDTH - 1 downto 0);
    iBq                    : in    signed (B_WIDTH - 1 downto 0);
    iNq                    : in    unsigned (N_WIDTH - 1 downto 0);
    iErrorVal              : in    signed (ERROR_WIDTH - 1 downto 0);
    oMappedErrorVal        : out   unsigned (MAPPED_ERROR_VAL_WIDTH - 1 downto 0)
  );
end entity a11_error_mapping;

architecture behavioral of a11_error_mapping is

  -- Control flags
  signal sSpecialMap          : std_logic;
  signal sErrEqualGreaterZero : std_logic;

  -- Width-extended compare for 2*B <= -N (avoid overflow and mismatched lengths)
  signal sBExt                : signed(B_WIDTH downto 0);
  signal sNExt                : signed(B_WIDTH downto 0);
  signal sErrorValExt         : signed((2 * MAPPED_ERROR_VAL_WIDTH) - 1 downto 0); -- so that abs(ErrorVal) fits

  -- Precomputed mapping candidates (parallel)
  signal sErrU, sErrAbsU      : unsigned (oMappedErrorVal'range);
  signal sMapErrorSpecialPos  : unsigned (oMappedErrorVal'range);
  signal sMapErrorSpecialNeg  : unsigned (oMappedErrorVal'range);
  signal sMapErrorRegPos      : unsigned (oMappedErrorVal'range);
  signal sMapErrorRegNeg      : unsigned (oMappedErrorVal'range);

begin

  sErrorValExt <= resize(iErrorVal, sErrorValExt'length);
  -- Extend and compare: 2*B <= -N with one extra bit to prevent overflow
  sBExt <= resize(iBq, sBExt'length);
  -- N reaches RESET (64), which sets the MSB of iNq: zero-extend before signed.
  sNExt <= resize(signed('0' & iNq), sBExt'length);

  sSpecialMap <= '1' when (iK = 0 and 2 * sBExt <= - sNExt) else
                 '0';

  -- Error sign flag
  sErrEqualGreaterZero <= '1' when iErrorVal >= 0 else
                          '0';

  -- Magnitudes for mapping
  sErrU    <= resize(unsigned(iErrorVal), sErrU'length); -- Only used when ErrorVal >= 0, conversion is safe
  sErrAbsU <= resize(unsigned(abs(sErrorValExt)), sErrAbsU'length);

  -- Special mapping
  sMapErrorSpecialPos <= resize((2 * sErrU) + 1, sMapErrorSpecialPos'length);
  sMapErrorSpecialNeg <= resize((2 * sErrAbsU) - 2, sMapErrorSpecialNeg'length);

  -- Regular mapping
  sMapErrorRegPos <= resize(2 * sErrU, sMapErrorRegPos'length);
  sMapErrorRegNeg <= resize((2 * sErrAbsU) - 1, sMapErrorRegNeg'length);

  -- Final selection (purely combinational)
  oMappedErrorVal <= sMapErrorSpecialPos when (sSpecialMap = '1' and sErrEqualGreaterZero = '1') else
                     sMapErrorSpecialNeg when (sSpecialMap = '1' and sErrEqualGreaterZero = '0') else
                     sMapErrorRegPos when (sSpecialMap = '0' and sErrEqualGreaterZero = '1') else
                     sMapErrorRegNeg; -- last case (Errval<0)

  -- MErrval in [0, 2^ERROR_WIDTH - 1]; unselected candidates may wrap
  postponed assert is_x(oMappedErrorVal) or oMappedErrorVal < 2 ** ERROR_WIDTH
    report "a11: MErrval out of range" severity error;

end architecture behavioral;
