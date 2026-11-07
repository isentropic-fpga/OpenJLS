-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a19_run_interruption_error: T.87 A.19, run-interruption error sign and modulo reduction

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a19_run_interruption_error is
  generic (
    BITNESS : natural range 8 to 16 := CO_BITNESS_STD;
    RANGE_P : natural               := CO_RANGE_STD
  );
  port (
    iErrval : in    signed (BITNESS downto 0);
    iRItype : in    std_logic;
    -- Ra > Rb, registered with iErrval
    iRaGtRb : in    std_logic;
    oErrval : out   signed (BITNESS downto 0);
    oSign   : out   std_logic
  );
end entity a19_run_interruption_error;

architecture behavioral of a19_run_interruption_error is

  signal sFlip : boolean;
  signal sErr  : signed (BITNESS downto 0);

begin

  sFlip <= iRItype = '0' and iRaGtRb = '1';
  sErr  <= - iErrval when sFlip else
           iErrval;
  oSign <= CO_SIGN_NEG when sFlip else
           CO_SIGN_POS;

  gen_binary_range : if RANGE_P = 2 ** BITNESS generate

    -- As A.9: the low BITNESS bits read as signed are the residue
    oErrval <= resize(sErr(BITNESS - 1 downto 0), BITNESS + 1);

  end generate gen_binary_range;

  gen_general_range : if RANGE_P /= 2 ** BITNESS generate

    p_modulo : process (sErr) is

      variable vErrAdj : integer;

    begin

      vErrAdj := to_integer(sErr);

      if (vErrAdj < 0) then
        vErrAdj := vErrAdj + RANGE_P;
      end if;

      if (vErrAdj >= (RANGE_P + 1) / 2) then
        vErrAdj := vErrAdj - RANGE_P;
      end if;

      oErrval <= to_signed(vErrAdj, oErrval'length);

    end process p_modulo;

  end generate gen_general_range;

  postponed assert is_x(oErrval) or abs(to_integer(sErr)) >= RANGE_P
                   or (to_integer(oErrval) >= (RANGE_P + 1) / 2 - RANGE_P and to_integer(oErrval) < (RANGE_P + 1) / 2)
    report "a19: Errval out of range" severity error;

end architecture behavioral;
