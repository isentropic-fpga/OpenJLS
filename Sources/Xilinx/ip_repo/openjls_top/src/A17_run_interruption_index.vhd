-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a17_run_interruption_index: T.87 A.17, run-interruption type RItype

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a17_run_interruption_index is
  generic (
    BITNESS : natural range 8 to 16 := CO_BITNESS_STD
  );
  port (
    iRa     : in    unsigned (BITNESS - 1 downto 0);
    iRb     : in    unsigned (BITNESS - 1 downto 0);
    oRItype : out   std_logic
  );
end entity a17_run_interruption_index;

architecture behavioral of a17_run_interruption_index is

begin

  oRItype <= '1' when iRa = iRb else
             '0';

end architecture behavioral;
