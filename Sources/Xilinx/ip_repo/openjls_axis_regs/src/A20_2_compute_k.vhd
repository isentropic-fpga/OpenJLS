-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a20_2_compute_k: T.87 A.20.2, A.10 shared by both modes, from A[Q] or TEMP

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a20_2_compute_k is
  generic (
    A_WIDTH : natural := CO_AQ_WIDTH_STD;
    K_WIDTH : natural := CO_K_WIDTH_STD;
    N_WIDTH : natural := CO_NQ_WIDTH_STD
  );
  port (
    iRunInterruption : in    std_logic;
    iAq              : in    unsigned (A_WIDTH - 1 downto 0);
    iTemp            : in    unsigned (A_WIDTH - 1 downto 0);
    iNq              : in    unsigned (N_WIDTH - 1 downto 0);
    oK               : out   unsigned (K_WIDTH - 1 downto 0)
  );
end entity a20_2_compute_k;

architecture behavioral of a20_2_compute_k is

  signal sAqSel : unsigned(A_WIDTH - 1 downto 0);

begin

  sAqSel <= iTemp when iRunInterruption = '1' else
            iAq;

  u_a10 : entity work.a10_compute_k(behavioral)
    generic map (
      A_WIDTH => A_WIDTH,
      K_WIDTH => K_WIDTH,
      N_WIDTH => N_WIDTH
    )
    port map (
      iNq => iNq,
      iAq => sAqSel,
      oK  => oK
    );

end architecture behavioral;
