-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a3_osvvm: a3_mode_selection against D1 = D2 = D3 = 0
--
-- Guidelines:
--   G2.Clamp    N/A: no accumulator
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

entity tb_a3_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a3_osvvm;

architecture sim of tb_a3_osvvm is

  constant D_MIN   : integer := -(2 ** BITNESS);
  constant D_MAX   : integer := (2 ** BITNESS) - 1;

  signal sD1      : signed(BITNESS downto 0);
  signal sD2      : signed(BITNESS downto 0);
  signal sD3      : signed(BITNESS downto 0);
  signal sModeRun : std_logic;

begin

  dut : entity work.a3_mode_selection(behavioral)
    generic map (
      BITNESS => BITNESS
    )
    port map (
      iD1      => sD1,
      iD2      => sD2,
      iD3      => sD3,
      oModeRun => sModeRun
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable req     : AlertLogIDType;
    variable d1      : integer;
    variable d2      : integer;
    variable d3      : integer;
    variable expRun  : integer;
    constant N_RAND  : natural := 3000;
    variable mm, st  : CoverageIDType;

    procedure drive_check (
      a   : integer;
      b   : integer;
      c   : integer;
      msg : string
    ) is

      variable run : integer;

    begin

      sD1 <= to_signed(a, BITNESS + 1);
      sD2 <= to_signed(b, BITNESS + 1);
      sD3 <= to_signed(c, BITNESS + 1);
      wait for 1 ns;

      if (a = 0 and b = 0 and c = 0) then
        run := 1;
      else
        run := 0;
      end if;
      AffirmIfEqual(req, checked_bit(sModeRun), run, msg);
      ICover(cov, run);
      ICover(mm, (1, a));
      ICover(mm, (2, b));
      ICover(mm, (3, c));
      ICover(st, (1, a));
      ICover(st, (2, b));
      ICover(st, (3, c));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a3_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A3", 100);

    cov := NewID("G4.Branch modeRun");
    SetFieldName(cov, "modeRun");
    AddBins(cov, "regular", GenBin(0));
    AddBins(cov, "run", GenBin(1));

    mm := NewID("G2.MinMax node x value");
    for node in 1 to 3 loop
      add_value_bin(mm, node, "D" & to_string(node), D_MIN);
      add_value_bin(mm, node, "D" & to_string(node), D_MAX);
    end loop;
    st := NewID("G3.Stim node x value");
    for node in 1 to 3 loop
      add_value_bin(st, node, "D" & to_string(node), D_MIN);
    end loop;
    drive_check(D_MAX, D_MIN, D_MAX, "regular opposite extremes");
    drive_check(0, 0, 0, "run all-zero");
    drive_check(1, 0, 0, "regular d1");
    drive_check(0, 1, 0, "regular d2");
    drive_check(0, 0, -1, "regular d3");
    drive_check(D_MIN, D_MAX, D_MIN, "regular extremes");

    -- A lone bit in any gradient, sign bit included, must prevent run mode
    for bit_index in 0 to BITNESS loop
      if bit_index = BITNESS then
        d1 := D_MIN;
      else
        d1 := 2 ** bit_index;
      end if;
      drive_check(d1, 0, 0, "walking D1");
      drive_check(0, d1, 0, "walking D2");
      drive_check(0, 0, d1, "walking D3");
    end loop;

    for i in 1 to N_RAND loop

      if (rv.DistValInt(((1, 1), (0, 6))) = 1) then
        d1 := 0;
        d2 := 0;
        d3 := 0;
      else
        d1 := rv.RandInt(D_MIN, D_MAX);
        d2 := rv.RandInt(D_MIN, D_MAX);
        d3 := rv.RandInt(D_MIN, D_MAX);
      end if;
      drive_check(d1, d2, d3, "rand");
      exit when IsCovered(cov) and i > 100;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "modeRun coverage closed");
    affirm_covered(mm, "D1..D3 min/max covered");
    affirm_covered(st, "most negative D1..D3 covered");

    end_of_test("tb_a3_osvvm");
    wait;

  end process stim;

end architecture sim;
