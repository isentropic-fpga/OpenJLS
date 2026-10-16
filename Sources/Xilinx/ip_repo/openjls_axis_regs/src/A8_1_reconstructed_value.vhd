-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

----------------------------------------------------------------------------------
-- Engineer:    Vitor Mendes Camilo
--
-- Module Name: A8_1_reconstructed_value - Behavioral
--
-- Description:                         Written requirement A.8.1
--                                      Lossless reconstruction: Rx = Ix
--
----------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a8_1_reconstructed_value is
  generic (
    BITNESS : natural range 8 to 16 := CO_BITNESS_STD
  );
  port (
    iIx : in    unsigned (BITNESS - 1 downto 0);
    oRx : out   unsigned (BITNESS - 1 downto 0)
  );
end entity a8_1_reconstructed_value;

architecture behavioral of a8_1_reconstructed_value is

begin

  oRx <= iIx;

end architecture behavioral;
