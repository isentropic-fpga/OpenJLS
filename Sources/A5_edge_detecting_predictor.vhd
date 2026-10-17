-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a5_edge_detecting_predictor: T.87 A.5, edge-detecting predictor Px

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a5_edge_detecting_predictor is
  generic (
    BITNESS : natural range 8 to 16 := CO_BITNESS_STD
  );
  port (
    iA      : in    unsigned (BITNESS - 1 downto 0);
    iB      : in    unsigned (BITNESS - 1 downto 0);
    iC      : in    unsigned (BITNESS - 1 downto 0);
    oPx     : out   unsigned (BITNESS - 1 downto 0)
  );
end entity a5_edge_detecting_predictor;

architecture behavioral of a5_edge_detecting_predictor is

begin

  oPx <= math_min(iA, iB) when iC >= math_max(iA, iB) else
         math_max(iA, iB) when iC <= math_min(iA, iB) else
         iA + iB - iC;

  -- Ra + Rb - Rc may wrap mid-expression; the result does not
  postponed assert is_x(oPx) or (oPx >= math_min(iA, iB) and oPx <= math_max(iA, iB))
    report "a5: Px outside [min(Ra, Rb), max(Ra, Rb)]" severity error;

end architecture behavioral;
