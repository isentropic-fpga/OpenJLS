-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a4_2_q_mapping: T.87 A.4.2, (Q1, Q2, Q3) to the context index Q

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity a4_2_q_mapping is
  port (
    iQ1 : in    signed(3 downto 0);  -- [0, 4]
    iQ2 : in    signed(3 downto 0);  -- [-4, 4]
    iQ3 : in    signed(3 downto 0);  -- [-4, 4]
    oQ  : out   unsigned(8 downto 0) -- [0..364]
  );
end entity a4_2_q_mapping;

architecture behavioral of a4_2_q_mapping is

  -- Q = 81*Q1 + 9*Q2 + Q3  (Mert, 2018)
  signal sQ1 : unsigned(2 downto 0);
  signal s81 : unsigned(8 downto 0); -- 81*Q1,  [0..324]
  signal s9  : signed(7 downto 0);   -- 9*Q2,  [-72..72]

begin

  sQ1 <= unsigned(iQ1(2 downto 0)); -- Q1 >= 0

  s81 <= shift_left(resize(sQ1, 9), 6)
         or shift_left(resize(sQ1, 9), 4)
         or resize(sQ1, 9);

  s9 <= shift_left(resize(iQ2, 8), 3)
        + resize(iQ2, 8);

  oQ <= resize(unsigned(signed('0' & s81) + s9 + iQ3), 9);

end architecture behavioral;
