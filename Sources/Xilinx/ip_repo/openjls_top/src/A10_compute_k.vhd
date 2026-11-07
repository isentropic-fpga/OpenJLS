-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a10_compute_k: T.87 A.10, Golomb parameter k
--
-- iAddHalfN compares against A + N/2 (A.20 TEMP) as one 3-input sum, keeping the adder off the
-- compare chain.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a10_compute_k is
  generic (
    A_WIDTH : natural := CO_AQ_WIDTH_STD;
    K_WIDTH : natural := CO_K_WIDTH_STD;
    N_WIDTH : natural := CO_NQ_WIDTH_STD
  );
  port (
    iNq       : in    unsigned (N_WIDTH - 1 downto 0);
    iAq       : in    unsigned (A_WIDTH - 1 downto 0);
    iAddHalfN : in    std_logic := '0';
    oK        : out   unsigned (K_WIDTH - 1 downto 0)
  );
end entity a10_compute_k;

architecture behavioral of a10_compute_k is

  -- Worst case Nq = 1, Aq = 2^A_WIDTH - 1
  constant MAX_K : natural := A_WIDTH;
  constant W     : natural := A_WIDTH + 1;

begin

  -- Parallel compares + priority encode instead of T.87's serial loop
  p_compute_k : process (iNq, iAq, iAddHalfN) is

    variable vAq    : unsigned(W - 1 downto 0);
    variable vNq    : unsigned(W - 1 downto 0);
    variable vT     : unsigned(W - 1 downto 0);
    variable vDiff  : unsigned(W downto 0);  -- N * 2^k - A - T; MSB set when negative
    variable vMatch : std_logic_vector(MAX_K downto 0);
    variable vK     : unsigned(oK'range);

  begin

    vAq := resize(iAq, W);
    vNq := resize(iNq, W);

    if (iAddHalfN = '1') then
      vT := shift_right(vNq, 1);
    else
      vT := (others => '0');
    end if;

    -- A + T < 2^(W-1), so the W + 1 bit difference cannot wrap
    for k in 0 to MAX_K loop

      vDiff     := resize(shift_left(vNq, k), W + 1) - resize(vAq, W + 1) - resize(vT, W + 1);
      vMatch(k) := not vDiff(W);

    end loop;

    -- Lowest matching k wins
    vK := to_unsigned(MAX_K + 1, vK'length);

    for k in MAX_K downto 0 loop

      if (vMatch(k) = '1') then
        vK := to_unsigned(k, vK'length);
      end if;

    end loop;

    oK <= vK;

  end process p_compute_k;

  -- Nq = 0 (reset value) yields MAX_K + 1
  postponed assert is_x(iNq) or is_x(iAq) or iNq = 0 or oK <= MAX_K report "a10: k above MAX_K" severity error;

end architecture behavioral;
