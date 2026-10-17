-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a20_1_run_context_index: T.87 A.20.1, run-interruption context Q = RItype + 365

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity a20_1_run_context_index is
  port (
    iRItype : in    std_logic;
    oQ      : out   unsigned (8 downto 0)
  );
end entity a20_1_run_context_index;

architecture behavioral of a20_1_run_context_index is

begin

  oQ <= to_unsigned(366, 9) when iRItype = '1' else
        to_unsigned(365, 9);

end architecture behavioral;
