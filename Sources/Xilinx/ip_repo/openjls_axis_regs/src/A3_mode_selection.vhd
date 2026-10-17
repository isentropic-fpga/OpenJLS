-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a3_mode_selection: T.87 A.3, run mode when D1 = D2 = D3 = 0

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.std_logic_misc.all;
  use work.openjls_pkg.all;

entity a3_mode_selection is
  generic (
    BITNESS  : natural range 8 to 16 := CO_BITNESS_STD
  );
  port (
    iD1      : in    signed(BITNESS downto 0);
    iD2      : in    signed(BITNESS downto 0);
    iD3      : in    signed(BITNESS downto 0);
    oModeRun : out   std_logic
  );
end entity a3_mode_selection;

architecture behavioral of a3_mode_selection is

begin

  oModeRun <= '1' when or_reduce(std_logic_vector(iD1 or iD2 or iD3)) = '0' else
              '0';

end architecture behavioral;
