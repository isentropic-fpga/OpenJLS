-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

----------------------------------------------------------------------------------
-- Engineer:    Vitor Mendes Camilo
--
-- Module Name: A9_modulo_reduction - Behavioral
--
-- Description:                         Code segment A.9
--                                      Modulo reduction of the error
--
----------------------------------------------------------------------------------

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

    -- The low BITNESS bits give the residue modulo 2**BITNESS. Interpreting
    -- them as signed chooses [-RANGE/2, RANGE/2-1], including the negative
    -- result at exactly RANGE/2. Sign extension restores the interface width.
    -- Slice first: resizing the original signed error down would retain its
    -- old sign bit, rather than the residue's sign bit.
    oErrorVal <= resize(iErrorVal(BITNESS - 1 downto 0), BITNESS + 1);

  end generate gen_binary_range;

  gen_general_range : if RANGE_P /= 2 ** BITNESS generate

    -- Retain the A.9 arithmetic for configurations without a full binary
    -- sample range. The extra bit lets RANGE_P fit without sign-bit roll.
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

end architecture behavioral;
