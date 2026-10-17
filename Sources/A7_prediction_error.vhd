-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

----------------------------------------------------------------------------------
-- Engineer:    Vitor Mendes Camilo
--
-- Module Name: prediction_error - Behavioral
--
-- Description:                     Code segment A.7
--                                  Computation of prediction error
--
----------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a7_prediction_error is
  generic (
    BITNESS   : natural range 8 to 16 := CO_BITNESS_STD
  );
  port (
    iIx       : in    unsigned (BITNESS - 1 downto 0);
    iPx       : in    unsigned (BITNESS - 1 downto 0);
    iSign     : in    std_logic;
    oErrorVal : out   signed (BITNESS downto 0)
  );
end entity a7_prediction_error;

architecture behavioral of a7_prediction_error is

begin

  oErrorVal <= signed('0' & iIx) - signed('0' & iPx) when iSign = CO_SIGN_POS else
               signed('0' & iPx) - signed('0' & iIx);

  -- Errval in [-(2^B - 1), 2^B - 1]
  postponed assert is_x(oErrorVal) or abs(to_integer(oErrorVal)) < 2 ** BITNESS
    report "a7: Errval out of range" severity error;

end architecture behavioral;
