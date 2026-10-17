-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a4_1_quant_gradient_merging: T.87 A.4.1 (A.3.4 text), sign merging of (Q1, Q2, Q3)

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a4_1_quant_gradient_merging is
  port (
    iQ1   : in    signed(3 downto 0);
    iQ2   : in    signed(3 downto 0);
    iQ3   : in    signed(3 downto 0);
    oQ1   : out   signed(3 downto 0);
    oQ2   : out   signed(3 downto 0);
    oQ3   : out   signed(3 downto 0);
    oSign : out   std_logic
  );
end entity a4_1_quant_gradient_merging;

architecture behavioral of a4_1_quant_gradient_merging is

  signal sSign : std_logic;

begin

  -- Sign of the first non-zero Qi
  sSign <= CO_SIGN_NEG when iQ1 < 0 else
           CO_SIGN_NEG when (iQ1 = 0 and iQ2 < 0) else
           CO_SIGN_NEG when (iQ1 = 0 and iQ2 = 0 and iQ3 < 0) else
           CO_SIGN_POS;

  oQ1 <= - iQ1 when sSign = CO_SIGN_NEG else
         iQ1;
  oQ2 <= - iQ2 when sSign = CO_SIGN_NEG else
         iQ2;
  oQ3 <= - iQ3 when sSign = CO_SIGN_NEG else
         iQ3;

  oSign <= sSign;

  postponed assert is_x(oQ1) or (oQ1 >= 0 and oQ1 <= 4) report "a4_1: Q1 out of range" severity error;
  postponed assert is_x(oQ2) or abs(to_integer(oQ2)) <= 4 report "a4_1: Q2 out of range" severity error;
  postponed assert is_x(oQ3) or abs(to_integer(oQ3)) <= 4 report "a4_1: Q3 out of range" severity error;

end architecture behavioral;
