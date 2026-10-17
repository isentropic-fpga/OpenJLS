-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a12_variables_update: T.87 A.12, update of A[Q], B[Q], N[Q]

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a12_variables_update is
  generic (
    ERROR_WIDTH : natural := CO_ERROR_VALUE_WIDTH_STD;
    A_WIDTH     : natural := CO_AQ_WIDTH_STD;
    B_WIDTH     : natural := CO_BQ_WIDTH_STD;
    N_WIDTH     : natural := CO_NQ_WIDTH_STD;
    RESET       : natural := CO_RESET_STD
  );
  port (
    iErrorVal   : in    signed (ERROR_WIDTH - 1 downto 0);
    iAq         : in    unsigned (A_WIDTH - 1 downto 0);
    iBq         : in    signed (B_WIDTH - 1 downto 0);
    iNq         : in    unsigned (N_WIDTH - 1 downto 0);

    oAq         : out   unsigned (A_WIDTH - 1 downto 0);
    oBq         : out   signed (B_WIDTH - 1 downto 0);
    oNq         : out   unsigned (N_WIDTH - 1 downto 0)
  );
end entity a12_variables_update;

architecture rtl of a12_variables_update is

  signal sDoRescale      : std_logic;
  signal sErrorAbsExtend : unsigned(A_WIDTH - 1 downto 0);
  signal sAqNew          : unsigned(A_WIDTH - 1 downto 0);
  signal sBqNew          : signed (B_WIDTH - 1 downto 0);
  signal sNqNew          : unsigned(N_WIDTH - 1 downto 0);
  signal sARescale       : unsigned(A_WIDTH - 1 downto 0);
  signal sBRescale       : signed (B_WIDTH - 1 downto 0);
  signal sNRescale       : unsigned(N_WIDTH - 1 downto 0);

begin

  sDoRescale <= '1' when (iNq = to_unsigned(RESET, iNq'length)) else
                '0';

  sErrorAbsExtend <= resize(unsigned(abs(iErrorVal)), A_WIDTH);

  sAqNew <= iAq + sErrorAbsExtend;
  sBqNew <= iBq + resize(iErrorVal, B_WIDTH);
  sNqNew <= iNq + 1;

  sARescale <= shift_right(sAqNew, 1);
  sBRescale <= shift_right(sBqNew, 1); -- arithmetic shift: floor for negatives
  sNRescale <= shift_right(iNq, 1) + 1;

  oAq <= sARescale when sDoRescale = '1' else
         sAqNew;
  oBq <= sBRescale when sDoRescale = '1' else
         sBqNew;
  oNq <= sNRescale when sDoRescale = '1' else
         sNqNew;

  postponed assert is_x(sAqNew) or sAqNew >= iAq report "a12: A wrapped" severity error;
  postponed assert is_x(oNq) or iNq > RESET or (oNq >= 1 and oNq <= RESET) report "a12: N out of range" severity error;

end architecture rtl;
