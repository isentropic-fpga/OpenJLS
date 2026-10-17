-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a20_1_osvvm: a20_1_run_context_index against the T.87 A.20.1 rule
--
-- Guidelines:
--   G1.Req      T87.A20.1
--   G1.Property A.20.1 Q = RItype + 365
--   G2.Range    RTL A20_1_run_context_index.vhd (range comments + postponed asserts)
--   G2.MinMax   N/A: 1-bit input, both values in G4.Run RItype
--   G2.Clamp    N/A: no accumulator
--   G2.Checked  checked_* on all outputs
--   G3.Stim     N/A: 1-bit input
--   G4.Run      G4.Run RItype
--   G4.Config   N/A: no BITNESS generic
--   G4 other    N/A: Edge/Coding/Stream not in scope
--   G5          N/A: combinational
--   G6.Code     fully covered

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.log2ceil;

library osvvm;
  context osvvm.OsvvmContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_a20_1_osvvm is
end entity tb_a20_1_osvvm;

architecture sim of tb_a20_1_osvvm is

  signal sRItype : std_logic;
  signal sQ      : unsigned(8 downto 0);

begin

  dut : entity work.a20_1_run_context_index(behavioral)
    port map (
      iRItype => sRItype,
      oQ      => sQ
    );

  stim : process is

    variable cov : CoverageIDType;
    variable req : AlertLogIDType;

  begin

    SetAlertLogName("tb_a20_1_osvvm");
    SetLogEnable(PASSED, FALSE);
    req := GetReqID("T87.A20.1", 4);

    cov := NewID("G4.Run RItype");
    SetFieldName(cov, "RItype");
    AddBins(cov, "Q=365", GenBin(0));
    AddBins(cov, "Q=366", GenBin(1));

    for ri in 0 to 1 loop

      sRItype <= bool2bit(ri = 1);
      wait for 1 ns;
      AffirmIfEqual(req, checked_integer(sQ), ri + 365, "Q = RItype + 365");
      AffirmIf(req, checked_integer(sQ) >= 365, "run Q outside the regular 0..364 range");
      ICover(cov, ri);

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "RItype coverage closed");

    end_of_test("tb_a20_1_osvvm");
    wait;

  end process stim;

end architecture sim;
