-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a17_osvvm: a17_run_interruption_index against the T.87 A.17 C code
--
-- Guidelines:
--   G1.Req      T87.A17
--   G1.Golden   A.17 C code as an integer reference
--   G2.Range    RTL A17_run_interruption_index.vhd (range comments + postponed asserts)
--   G2.MinMax   G2.MinMax node x value
--   G2.Clamp    N/A: no accumulator
--   G2.Checked  checked_* on all outputs
--   G3.Stim     G3.Stim node x value
--   G4.Run      G4.Run RItype
--   G4.Config   BITNESS 8/16 variants (OpenJls.pro)
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

entity tb_a17_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a17_osvvm;

architecture sim of tb_a17_osvvm is

  constant PX_MAX  : integer := (2 ** BITNESS) - 1;

  signal sRaPix     : unsigned(BITNESS - 1 downto 0);
  signal sRbPix     : unsigned(BITNESS - 1 downto 0);
  signal sRItype : std_logic;

begin

  dut : entity work.a17_run_interruption_index(behavioral)
    generic map (
      BITNESS => BITNESS
    )
    port map (
      iRa     => sRaPix,
      iRb     => sRbPix,
      oRItype => sRItype
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable req     : AlertLogIDType;
    variable ra      : integer;
    variable rb      : integer;
    constant N_RAND  : natural := 3000;
    variable mm, st  : CoverageIDType;

    procedure drive_check (
      rav : integer;
      rbv : integer;
      msg : string
    ) is

      variable e : integer;

    begin

      sRaPix <= to_unsigned(rav, BITNESS);
      sRbPix <= to_unsigned(rbv, BITNESS);
      wait for 1 ns;

      if (rav = rbv) then
        e := 1;
      else
        e := 0;
      end if;
      AffirmIfEqual(req, checked_bit(sRItype), e, msg);
      ICover(cov, e);
      ICover(mm, (1, rav));
      ICover(mm, (2, rbv));
      ICover(st, (1, rav));
      ICover(st, (2, rbv));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a17_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A17", 100);
    cov := NewID("G4.Run RItype");
    SetFieldName(cov, "RItype");
    AddBins(cov, "unequal neighbours", GenBin(0));
    AddBins(cov, "equal neighbours", GenBin(1));

    mm := NewID("G2.MinMax node x value");
    add_value_bin(mm, 1, "Ra", 0);
    add_value_bin(mm, 1, "Ra", PX_MAX);
    add_value_bin(mm, 2, "Rb", 0);
    add_value_bin(mm, 2, "Rb", PX_MAX);
    st := NewID("G3.Stim node x value");
    add_value_bin(st, 1, "Ra MSB", 2 ** (BITNESS - 1), PX_MAX);
    add_value_bin(st, 2, "Rb MSB", 2 ** (BITNESS - 1), PX_MAX);
    drive_check(0, 0, "equal zero");
    drive_check(PX_MAX, PX_MAX, "equal max");
    drive_check(0, PX_MAX, "unequal");

    for bit_index in 0 to BITNESS - 1 loop
      drive_check(0, 2 ** bit_index, "single unequal bit in Rb");
      drive_check(2 ** bit_index, 0, "single unequal bit in Ra");
    end loop;

    for i in 1 to N_RAND loop

      ra := rv.RandInt(0, PX_MAX);
      if (rv.RandInt(0, 1) = 0) then
        rb := ra;
      else
        rb := rv.RandInt(0, PX_MAX);
      end if;
      drive_check(ra, rb, "rand");
      exit when IsCovered(cov) and i > 100;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "RItype coverage closed");
    affirm_covered(mm, "Ra/Rb min/max covered");
    affirm_covered(st, "Ra/Rb MSB covered");

    end_of_test("tb_a17_osvvm");
    wait;

  end process stim;

end architecture sim;
