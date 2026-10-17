-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a9_modulo_reduction: T.87 A.9, modulo reduction of Errval

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a9_modulo_reduction is
  generic (
    BITNESS   : natural range 8 to 16 := CO_BITNESS_STD;
    RANGE_P   : natural               := CO_RANGE_STD
  );
  port (
    iErrorVal : in    signed (BITNESS downto 0);
    oErrorVal : out   signed (BITNESS downto 0)
  );
end entity a9_modulo_reduction;

architecture behavioral of a9_modulo_reduction is

begin

  gen_binary_range : if RANGE_P = 2 ** BITNESS generate

    -- Low BITNESS bits read as signed are the residue in [-RANGE/2, RANGE/2 - 1].
    -- Slice before resize, or the input's sign bit is kept instead of the residue's.
    oErrorVal <= resize(iErrorVal(BITNESS - 1 downto 0), BITNESS + 1);

  end generate gen_binary_range;

  gen_general_range : if RANGE_P /= 2 ** BITNESS generate

    -- RANGE not a power of two: plain A.9 arithmetic
    constant RANGE_S : signed(BITNESS + 1 downto 0) := to_signed(RANGE_P, BITNESS + 2);

    signal sExt    : signed(BITNESS + 1 downto 0);
    signal sErrAdj : signed(BITNESS + 1 downto 0);

  begin

    sExt <= resize(iErrorVal, BITNESS + 2);

    sErrAdj <= sExt + RANGE_S when iErrorVal < 0 else
               sExt;

    oErrorVal <= resize(sErrAdj - RANGE_S, BITNESS + 1) when sErrAdj >= (RANGE_P + 1) / 2 else
                 resize(sErrAdj, BITNESS + 1);

  end generate gen_general_range;

  postponed assert is_x(oErrorVal) or abs(to_integer(iErrorVal)) >= RANGE_P
                   or (to_integer(oErrorVal) >= (RANGE_P + 1) / 2 - RANGE_P and to_integer(oErrorVal) < (RANGE_P + 1) / 2)
    report "a9: Errval out of range" severity error;

end architecture behavioral;
