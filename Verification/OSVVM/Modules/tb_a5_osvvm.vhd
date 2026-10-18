-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a5_osvvm: a5_edge_detecting_predictor against the T.87 A.5 C code
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

entity tb_a5_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a5_osvvm;

architecture sim of tb_a5_osvvm is

  constant PX_MAX  : integer := (2 ** BITNESS) - 1;

  signal sA  : unsigned(BITNESS - 1 downto 0);
  signal sB  : unsigned(BITNESS - 1 downto 0);
  signal sC  : unsigned(BITNESS - 1 downto 0);
  signal sPx : unsigned(BITNESS - 1 downto 0);

  -- T.87 A.5
  function predict (
    a : integer;
    b : integer;
    c : integer
  ) return integer is

    variable mx : integer;
    variable mn : integer;

  begin

    mx := math_max(a, b);
    mn := math_min(a, b);

    if (c >= mx) then
      return mn;
    elsif (c <= mn) then
      return mx;
    else
      return a + b - c;
    end if;

  end function predict;

  -- Branch: 0 = C >= max, 1 = C <= min, 2 = interpolate
  function branch_of (
    a : integer;
    b : integer;
    c : integer
  ) return integer is

    variable mx : integer;
    variable mn : integer;

  begin

    mx := math_max(a, b);
    mn := math_min(a, b);

    if (c >= mx) then
      return 0;
    elsif (c <= mn) then
      return 1;
    else
      return 2;
    end if;

  end function branch_of;

begin

  dut : entity work.a5_edge_detecting_predictor(behavioral)
    generic map (
      BITNESS => BITNESS
    )
    port map (
      iA  => sA,
      iB  => sB,
      iC  => sC,
      oPx => sPx
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable mm      : CoverageIDType;
    variable st      : CoverageIDType;
    variable req     : AlertLogIDType;
    variable a       : integer;
    variable b       : integer;
    variable c       : integer;
    variable exp     : integer;
    variable br      : integer;
    constant N_RAND  : natural := 4000;

    procedure drive_check (
      av  : integer;
      bv  : integer;
      cv  : integer;
      msg : string
    ) is
    begin

      sA <= to_unsigned(av, BITNESS);
      sB <= to_unsigned(bv, BITNESS);
      sC <= to_unsigned(cv, BITNESS);
      wait for 1 ns;
      AffirmIfEqual(req, checked_integer(sPx), predict(av, bv, cv), msg &
                    " A=" & integer'image(av) &
                    " B=" & integer'image(bv) &
                    " C=" & integer'image(cv));
      ICover(cov, branch_of(av, bv, cv));
      ICover(mm, (1, predict(av, bv, cv)));
      ICover(st, (1, av));
      ICover(st, (2, bv));
      ICover(st, (3, cv));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a5_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A5", 200);

    cov := NewID("G4.Branch branch");
    SetFieldName(cov, "branch");
    AddBins(cov, "C >= max: choose min", GenBin(0));
    AddBins(cov, "C <= min: choose max", GenBin(1));
    AddBins(cov, "interpolate", GenBin(2));
    mm := NewID("G2.MinMax node x value");
    add_value_bin(mm, 1, "Px", 0);
    add_value_bin(mm, 1, "Px", PX_MAX);
    st := NewID("G3.Stim node x value");
    add_value_bin(st, 1, "Ra MSB", 2 ** (BITNESS - 1), PX_MAX);
    add_value_bin(st, 2, "Rb MSB", 2 ** (BITNESS - 1), PX_MAX);
    add_value_bin(st, 3, "Rc MSB", 2 ** (BITNESS - 1), PX_MAX);

    -- Directed corners
    drive_check(10, 5, 10, "c=max");
    drive_check(10, 5, 5, "c=min");
    drive_check(10, 5, 7, "interp");
    drive_check(0, 0, 0, "all-zero");
    drive_check(PX_MAX, PX_MAX, PX_MAX, "all-max");
    drive_check(0, PX_MAX, PX_MAX, "interp-edge");
    drive_check(PX_MAX, 0, 0, "c<=min big span");

    -- Equality and interpolation near the addition carry boundary
    for delta in -1 to 1 loop
      drive_check(PX_MAX, PX_MAX - 2, PX_MAX - 1 + delta, "upper interpolation");
      drive_check(PX_MAX - 2, PX_MAX, PX_MAX - 1 + delta, "swapped interpolation");
      drive_check(0, 2, 1 + delta, "lower interpolation");
      drive_check(2, 0, 1 + delta, "swapped lower interpolation");
    end loop;

    for i in 1 to N_RAND loop

      a := rv.RandInt(0, PX_MAX);
      b := rv.RandInt(0, PX_MAX);
      c := rv.RandInt(0, PX_MAX);
      drive_check(a, b, c, "rand");
      exit when IsCovered(cov) and i > 200;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "branch coverage closed");
    affirm_covered(mm, "Px min/max covered");
    affirm_covered(st, "input MSB covered");

    end_of_test("tb_a5_osvvm");
    wait;

  end process stim;

end architecture sim;
