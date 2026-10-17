-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a11_error_mapping: T.87 A.11, Errval to the non-negative MErrval

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

  signal sSpecialMap          : std_logic;
  signal sErrEqualGreaterZero : std_logic;

  -- One extra bit so 2*B <= -N cannot overflow
  signal sBExt                : signed(B_WIDTH downto 0);
  signal sNExt                : signed(B_WIDTH downto 0);
  signal sErrorValExt         : signed((2 * MAPPED_ERROR_VAL_WIDTH) - 1 downto 0);

  signal sErrU, sErrAbsU      : unsigned (oMappedErrorVal'range);
  signal sMapErrorSpecialPos  : unsigned (oMappedErrorVal'range);
  signal sMapErrorSpecialNeg  : unsigned (oMappedErrorVal'range);
  signal sMapErrorRegPos      : unsigned (oMappedErrorVal'range);
  signal sMapErrorRegNeg      : unsigned (oMappedErrorVal'range);

begin

  sErrorValExt <= resize(iErrorVal, sErrorValExt'length);
  sBExt <= resize(iBq, sBExt'length);
  -- N = RESET sets the MSB of iNq: zero-extend
  sNExt <= resize(signed('0' & iNq), sBExt'length);

  sSpecialMap <= '1' when (iK = 0 and 2 * sBExt <= - sNExt) else
                 '0';

  sErrEqualGreaterZero <= '1' when iErrorVal >= 0 else
                          '0';

  sErrU    <= resize(unsigned(iErrorVal), sErrU'length); -- only used when ErrorVal >= 0
  sErrAbsU <= resize(unsigned(abs(sErrorValExt)), sErrAbsU'length);

  sMapErrorSpecialPos <= resize((2 * sErrU) + 1, sMapErrorSpecialPos'length);
  sMapErrorSpecialNeg <= resize((2 * sErrAbsU) - 2, sMapErrorSpecialNeg'length);

  sMapErrorRegPos <= resize(2 * sErrU, sMapErrorRegPos'length);
  sMapErrorRegNeg <= resize((2 * sErrAbsU) - 1, sMapErrorRegNeg'length);

  oMappedErrorVal <= sMapErrorSpecialPos when (sSpecialMap = '1' and sErrEqualGreaterZero = '1') else
                     sMapErrorSpecialNeg when (sSpecialMap = '1' and sErrEqualGreaterZero = '0') else
                     sMapErrorRegPos when (sSpecialMap = '0' and sErrEqualGreaterZero = '1') else
                     sMapErrorRegNeg;

  postponed assert is_x(oMappedErrorVal) or oMappedErrorVal < 2 ** ERROR_WIDTH
    report "a11: MErrval out of range" severity error;

end architecture behavioral;
