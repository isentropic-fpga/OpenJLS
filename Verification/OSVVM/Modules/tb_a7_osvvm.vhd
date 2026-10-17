-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a7_osvvm: a7_prediction_error against the T.87 A.7 C code
--
-- Guidelines:
--   G1.Req      T87.A7
--   G1.Golden   A.7 C code as an integer reference
--   G2.Range    RTL A7_prediction_error.vhd (range comments + postponed asserts)
--   G2.MinMax   G2.MinMax node x value
--   G2.Clamp    N/A: no accumulator
--   G2.Checked  checked_* on all outputs
--   G3.Stim     G3.Stim node x value
--   G4.Branch   G4.Branch signIn x signErr
--   G4.Config   BITNESS 8/16 variants (OpenJls.pro)
--   G4 other    N/A: Edge/Run/Coding/Stream not in scope
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

entity tb_a7_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a7_osvvm;

architecture sim of tb_a7_osvvm is

  constant PX_MAX  : integer := (2 ** BITNESS) - 1;

  signal sIx        : unsigned(BITNESS - 1 downto 0);
  signal sPx        : unsigned(BITNESS - 1 downto 0);
  signal sSign      : std_logic;
  signal sErrorVal  : signed(BITNESS downto 0);

  function ref_err (
    ix   : integer;
    px   : integer;
    sign : std_logic
  ) return integer is
  begin

    if (sign = CO_SIGN_POS) then
      return ix - px;
    else
      return px - ix;
    end if;

  end function ref_err;

  function sgn (
    v : integer
  ) return integer is
  begin

    if v < 0 then
      return 1;
    elsif v = 0 then
      return 2;
    else
      return 0;
    end if;

  end function sgn;

begin

  dut : entity work.a7_prediction_error(behavioral)
    generic map (
      BITNESS => BITNESS
    )
    port map (
      iIx       => sIx,
      iPx       => sPx,
      iSign     => sSign,
      oErrorVal => sErrorVal
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable mm      : CoverageIDType;
    variable st      : CoverageIDType;
    variable req     : AlertLogIDType;
    variable ix      : integer;
    variable px      : integer;
    variable sgnIn   : integer;
    variable exp     : integer;
    constant N_RAND  : natural := 4000;

    procedure drive_check (
      ixv  : integer;
      pxv  : integer;
      sgv  : std_logic;
      msg  : string
    ) is

      variable e : integer;

    begin

      sIx   <= to_unsigned(ixv, BITNESS);
      sPx   <= to_unsigned(pxv, BITNESS);
      sSign <= sgv;
      wait for 1 ns;
      e := ref_err(ixv, pxv, sgv);
      AffirmIfEqual(req, checked_integer(sErrorVal), e, msg);
      ICover(cov, (std_to_int(sgv), sgn(e)));
      ICover(mm, (1, e));
      ICover(st, (1, ixv));
      ICover(st, (2, pxv));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a7_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A7", 200);

    cov := NewID("G4.Branch signIn x signErr");
    SetFieldName(cov, "signIn", "signErr");
    for axis0 in 0 to 1 loop
      for axis1 in 0 to 2 loop
        AddCross(cov, "signIn=" & to_string(axis0) & " / " & "signErr=" & to_string(axis1), GenBin(axis0), GenBin(axis1));
      end loop;
    end loop;

    mm := NewID("G2.MinMax node x value");
    add_value_bin(mm, 1, "Errval", -PX_MAX);
    add_value_bin(mm, 1, "Errval", PX_MAX);
    st := NewID("G3.Stim node x value");
    add_value_bin(st, 1, "Ix MSB", 2 ** (BITNESS - 1), PX_MAX);
    add_value_bin(st, 2, "Px MSB", 2 ** (BITNESS - 1), PX_MAX);

    -- Directed corners
    drive_check(0, 0, CO_SIGN_POS, "zero pos");
    drive_check(PX_MAX, 0, CO_SIGN_POS, "max pos");
    drive_check(0, PX_MAX, CO_SIGN_POS, "min pos");
    drive_check(PX_MAX, 0, CO_SIGN_NEG, "max neg");
    drive_check(0, PX_MAX, CO_SIGN_NEG, "min neg");

    for pixel in 0 to PX_MAX loop
      drive_check(pixel, pixel, CO_SIGN_POS, "zero positive sign");
      drive_check(pixel, pixel, CO_SIGN_NEG, "zero negative sign");
    end loop;

    for i in 1 to N_RAND loop

      ix    := rv.RandInt(0, PX_MAX);
      px    := rv.RandInt(0, PX_MAX);
      if (rv.RandInt(0, 1) = 0) then
        drive_check(ix, px, CO_SIGN_POS, "rand");
      else
        drive_check(ix, px, CO_SIGN_NEG, "rand");
      end if;
      exit when IsCovered(cov) and i > 200;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "sign cross coverage closed");
    affirm_covered(mm, "Errval min/max covered");
    affirm_covered(st, "input MSB covered");

    end_of_test("tb_a7_osvvm");
    wait;

  end process stim;

end architecture sim;
