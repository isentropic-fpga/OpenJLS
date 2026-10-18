-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a4_2_osvvm: a4_2_q_mapping against the T.87 A.4.2 properties
--
-- T.87 only requires a one-to-one map onto 0 to 364. The TB checks that over all
-- 365 merged vectors, plus the design's Q = 81*Q1 + 9*Q2 + Q3.
--
-- Guidelines:
--   G2.MinMax   G1.Property a4_2_Q_codes (all 365 codes)
--   G2.Clamp    N/A: no accumulator
--   G3.Stim     N/A: exhaustive over the 365-vector domain
--   G4.Config   N/A: no BITNESS generic
--   G4 other    N/A: Edge/Run/Coding/Stream not in scope
--   G5          N/A: combinational

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library osvvm;
  context osvvm.OsvvmContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_a4_2_osvvm is
end entity tb_a4_2_osvvm;

architecture sim of tb_a4_2_osvvm is

  signal sQ1 : signed(3 downto 0);
  signal sQ2 : signed(3 downto 0);
  signal sQ3 : signed(3 downto 0);
  signal sQ  : unsigned(8 downto 0);

begin

  dut : entity work.a4_2_q_mapping(behavioral)
    port map (
      iQ1 => sQ1,
      iQ2 => sQ2,
      iQ3 => sQ3,
      oQ  => sQ
    );

  stim : process is

    variable seen   : integer_vector(0 to 364) := (others => -1);
    variable nSeen  : natural := 0;
    variable q      : integer;
    variable expQ   : integer;
    variable req    : AlertLogIDType;
    variable cov    : CoverageIDType;

    procedure drive_check (
      q1 : integer;
      q2 : integer;
      q3 : integer
    ) is

      variable e : integer;

    begin

      sQ1 <= to_signed(q1, 4);
      sQ2 <= to_signed(q2, 4);
      sQ3 <= to_signed(q3, 4);
      wait for 1 ns;

      e := 81 * q1 + 9 * q2 + q3;
      AffirmIfEqual(req, checked_integer(sQ), e,
                    "map Q1=" & integer'image(q1) &
                    " Q2=" & integer'image(q2) &
                    " Q3=" & integer'image(q3));

      AffirmIf(req, e >= 0 and e <= 364, "Q in range for vector");

      if (e >= 0 and e <= 364) then
        ICover(cov, e);
        AffirmIf(req, seen(e) = -1,
                 "Q=" & integer'image(e) & " collides with vector index " &
                 integer'image(seen(e)));
        if (seen(e) = -1) then
          seen(e) := q1 * 100 + q2 * 10 + q3;
          nSeen   := nSeen + 1;
        end if;
      end if;

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a4_2_osvvm");
    SetLogEnable(PASSED, FALSE);
    req := GetReqID("T87.A4.2", 365);

    cov := NewID("G1.Property a4_2_Q_codes");
    SetFieldName(cov, "a4_2_Q_codes");
    for code in 0 to 364 loop
      AddBins(cov, "context_" & to_string(code), GenBin(code));
    end loop;

    -- Every merged vector (leading nonzero element positive)
    for q1 in 0 to 4 loop

      for q2 in -4 to 4 loop

        for q3 in -4 to 4 loop

          -- Merging folds a negative leading element away
          if (q1 = 0 and q2 < 0) then
            next;
          end if;
          if (q1 = 0 and q2 = 0 and q3 < 0) then
            next;
          end if;
          drive_check(q1, q2, q3);

        end loop;

      end loop;

    end loop;

    AffirmIfEqual(req, nSeen, 365, "all 365 contexts mapped (total + complete)");
    AffirmIf(req, IsCovered(cov), "functional coverage closed (all 365 Q codes)");

    end_of_test("tb_a4_2_osvvm");
    wait;

  end process stim;

end architecture sim;
