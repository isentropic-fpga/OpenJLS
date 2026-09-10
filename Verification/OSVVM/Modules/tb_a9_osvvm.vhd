-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: a9_modulo_reduction (combinational).
--
-- Reduces valid errors into [-floor(RANGE/2), ceil(RANGE/2)-1]: add RANGE if negative,
-- then subtract RANGE once the adjusted value reaches ceil(RANGE/2). Coverage
-- crosses the negative-wrap path with the upper-half subtract.
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library osvvm;
  context osvvm.OsvvmContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_a9_osvvm is
  generic (
    BITNESS : natural range 8 to 16 := CO_BITNESS_STD;
    RANGE_P : natural := 2 ** BITNESS
  );
end entity tb_a9_osvvm;

architecture sim of tb_a9_osvvm is

  constant ERR_MIN : integer := -(2 ** BITNESS);
  constant ERR_MAX : integer := (2 ** BITNESS) - 1;

  signal sErrIn  : signed(BITNESS downto 0);
  signal sErrOut : signed(BITNESS downto 0);

  -- T.87 A.9 reference value.
  function ref_mod (
    err : integer
  ) return integer is

    variable adj : integer;

  begin

    if (err < 0) then
      adj := err + RANGE_P;
    else
      adj := err;
    end if;

    if (adj >= (RANGE_P + 1) / 2) then
      return adj - RANGE_P;
    else
      return adj;
    end if;

  end function ref_mod;

  -- adjusted (post negative-wrap) value, for the upper-half coverage axis.
  function adj_of (
    err : integer
  ) return integer is
  begin

    if (err < 0) then
      return err + RANGE_P;
    else
      return err;
    end if;

  end function adj_of;

begin

  dut : entity work.a9_modulo_reduction(behavioral)
    generic map (
      BITNESS => BITNESS,
      RANGE_P => RANGE_P
    )
    port map (
      iErrorVal => sErrIn,
      oErrorVal => sErrOut
    );

  stim : process is

    variable cov     : CoverageIDType;
    variable req     : AlertLogIDType;

    procedure drive_check (
      ev  : integer;
      msg : string
    ) is

      variable w : integer;
      variable g : integer;

    begin

      sErrIn <= to_signed(ev, BITNESS + 1);
      wait for 1 ns;
      AffirmIfEqual(req, checked_integer(sErrOut), ref_mod(ev), msg & " err=" & integer'image(ev));

      if (ev < 0) then
        w := 1;
      else
        w := 0;
      end if;
      if (adj_of(ev) >= (RANGE_P + 1) / 2) then
        g := 1;
      else
        g := 0;
      end if;
      ICover(cov, (w, g));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a9_osvvm");
    SetLogEnable(PASSED, FALSE);
    req := GetReqID("T87.A9", 200);

    cov := NewID("wrapNeg x geHalf");
    SetFieldName(cov, "wrapNeg", "geHalf");
    for axis0 in 0 to 1 loop
      for axis1 in 0 to 1 loop
        AddCross(cov, "wrapNeg=" & to_string(axis0) & " / " & "geHalf=" & to_string(axis1), GenBin(axis0), GenBin(axis1));
      end loop;
    end loop;

    -- Directed corners.
    drive_check(0, "zero");
    drive_check(ERR_MAX, "max");
    drive_check(ERR_MIN, "min");
    drive_check((RANGE_P + 1) / 2, "exact half");
    drive_check((RANGE_P + 1) / 2 - 1, "just below half");
    drive_check(-1, "neg one");

    -- Exhaust every representable input, including the unused-most-negative
    -- code. This checks all wrap thresholds for both generated implementations.
    for err in ERR_MIN to ERR_MAX loop

      drive_check(err, "exhaustive");

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "wrap/half cross coverage closed");

    end_of_test("tb_a9_osvvm");
    wait;

  end process stim;

end architecture sim;
