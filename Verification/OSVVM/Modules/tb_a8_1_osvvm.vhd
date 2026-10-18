-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a8_1_osvvm: a8_1_reconstructed_value against the T.87 A.8.1 rule (Rx = Ix)
--
-- Guidelines:
--   G2.MinMax   G4.Branch Ix (0 and MAXVAL)
--   G2.Clamp    N/A: no accumulator
--   G3.Stim     N/A: exhaustive over every pixel value
--   G4 other    N/A: Edge/Run/Coding/Stream not in scope
--   G5          N/A: combinational

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.log2ceil;

library osvvm;
  context osvvm.OsvvmContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_a8_1_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a8_1_osvvm;

architecture sim of tb_a8_1_osvvm is

  constant PX_MAX : integer := (2 ** BITNESS) - 1;

  signal sIx : unsigned(BITNESS - 1 downto 0);
  signal sRx : unsigned(BITNESS - 1 downto 0);

begin

  dut : entity work.a8_1_reconstructed_value(behavioral)
    generic map (
      BITNESS => BITNESS
    )
    port map (
      iIx => sIx,
      oRx => sRx
    );

  stim : process is

    variable cov : CoverageIDType;
    variable req : AlertLogIDType;

  begin

    SetAlertLogName("tb_a8_1_osvvm");
    SetLogEnable(PASSED, FALSE);
    req := GetReqID("T87.A8.1", PX_MAX + 1);

    cov := NewID("G4.Branch Ix");
    SetFieldName(cov, "Ix");
    AddBins(cov, "zero", GenBin(0));
    AddBins(cov, "interior", GenBin(1, PX_MAX - 1, 1));
    AddBins(cov, "MAXVAL", GenBin(PX_MAX));

    for ix in 0 to PX_MAX loop

      sIx <= to_unsigned(ix, BITNESS);
      wait for 1 ns;
      AffirmIfEqual(req, checked_integer(sRx), ix, "Rx = Ix");
      ICover(cov, ix);

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "Ix coverage closed");

    end_of_test("tb_a8_1_osvvm");
    wait;

  end process stim;

end architecture sim;
