-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a10_compute_k: T.87 A.10, Golomb parameter k

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
    iNq     : in    unsigned (N_WIDTH - 1 downto 0);
    iAq     : in    unsigned (A_WIDTH - 1 downto 0);
    oK      : out   unsigned (K_WIDTH - 1 downto 0)
  );
end entity a10_compute_k;

architecture behavioral of a10_compute_k is

  -- Worst case Nq = 1, Aq = 2^A_WIDTH - 1
  constant MAX_K : natural := A_WIDTH;
  constant W     : natural := A_WIDTH + 1;

begin

  -- Parallel compares + priority encode instead of T.87's serial loop
  p_compute_k : process (iNq, iAq) is

    variable vAq    : unsigned(W - 1 downto 0);
    variable vNq    : unsigned(W - 1 downto 0);
    variable vMatch : std_logic_vector(MAX_K downto 0);
    variable vK     : unsigned(oK'range);

  begin

    vAq := resize(iAq, W);
    vNq := resize(iNq, W);

    for k in 0 to MAX_K loop

      if (shift_left(vNq, k) >= vAq) then
        vMatch(k) := '1';
      else
        vMatch(k) := '0';
      end if;

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
