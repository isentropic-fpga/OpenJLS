-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a18_run_interruption_prediction_error: T.87 A.18, run-interruption prediction error

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a18_run_interruption_prediction_error is
  generic (
    BITNESS : natural range 8 to 16 := CO_BITNESS_STD
  );
  port (
    iRItype : in    std_logic;
    iRa     : in    unsigned (BITNESS - 1 downto 0);
    iRb     : in    unsigned (BITNESS - 1 downto 0);
    iIx     : in    unsigned (BITNESS - 1 downto 0);
    oErrval : out   signed (BITNESS downto 0)
  );
end entity a18_run_interruption_prediction_error;

architecture behavioral of a18_run_interruption_prediction_error is

  signal sPx : unsigned (BITNESS - 1 downto 0);

begin

  sPx <= iRa when iRItype = '1' else
         iRb;

  oErrval <= signed('0' & iIx) - signed('0' & sPx);

  postponed assert is_x(oErrval) or abs(to_integer(oErrval)) < 2 ** BITNESS report "a18: Errval out of range" severity error;

end architecture behavioral;
