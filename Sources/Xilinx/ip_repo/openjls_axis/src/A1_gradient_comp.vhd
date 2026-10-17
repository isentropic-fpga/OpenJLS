-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a1_gradient_comp: T.87 A.1, local gradients D1, D2, D3

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a1_gradient_comp is
  generic (
    BITNESS : natural range 8 to 16 := CO_BITNESS_STD
  );
  port (
    iA      : in    unsigned (BITNESS - 1 downto 0);
    iB      : in    unsigned (BITNESS - 1 downto 0);
    iC      : in    unsigned (BITNESS - 1 downto 0);
    iD      : in    unsigned (BITNESS - 1 downto 0);
    oD1     : out   signed (BITNESS downto 0);
    oD2     : out   signed (BITNESS downto 0);
    oD3     : out   signed (BITNESS downto 0)
  );
end entity a1_gradient_comp;

architecture behavioral of a1_gradient_comp is

begin

  oD1 <= signed('0' & iD) - signed('0' & iB);
  oD2 <= signed('0' & iB) - signed('0' & iC);
  oD3 <= signed('0' & iC) - signed('0' & iA);

  postponed assert is_x(oD1) or abs(to_integer(oD1)) < 2 ** BITNESS report "a1: D1 out of range" severity error;
  postponed assert is_x(oD2) or abs(to_integer(oD2)) < 2 ** BITNESS report "a1: D2 out of range" severity error;
  postponed assert is_x(oD3) or abs(to_integer(oD3)) < 2 ** BITNESS report "a1: D3 out of range" severity error;

end architecture behavioral;
