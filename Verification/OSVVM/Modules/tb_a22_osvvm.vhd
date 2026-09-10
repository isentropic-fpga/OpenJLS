-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: a22_errval_mapping (combinational).
--
-- T.87 Code segment A.22: EMErrval = 2*abs(Errval) - RItype - map. The C model
-- has no clamp; the RTL clamps at 0. That clamp is provably a no-op for any
-- T.87-coherent input, so the reference is the pure (unclamped) C formula and
-- the check covers its full valid domain.
--
-- Proof that EMErrval >= 0 for coherent inputs (so EMErrval<0 is unreachable):
--   EMErrval<0 needs |Errval|=0 AND RItype+map>=1. But
--     (1) a run-interruption sample is the breaking sample, so Ix/=Ra; with
--         RItype=1 (A.17: Ra=Rb) A.18 gives Px=Ra and Errval=Ix-Ra/=0, and A.19
--         ModRange keeps it nonzero -> RItype=1 implies |Errval|>=1; and
--     (2) A.21 forces map=0 whenever Errval=0 (every map=1 clause needs Errval/=0).
--   So |Errval|=0 with RItype+map>=1 cannot occur; EMErrval>=0 always, with =0
--   reachable only at (RItype=0, map=0, Errval=0) -- which is driven and checked.
-- Skipped (EMErrval<0) vectors are asserted to be exactly that forbidden combo.
-- Coverage crosses RItype x map and includes the EMErrval==0 boundary.
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.log2ceil;

library osvvm;
  context osvvm.OsvvmContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_a22_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a22_osvvm;

architecture sim of tb_a22_osvvm is

  constant ERROR_WIDTH : natural := BITNESS + 1;
  constant MAPPED_W    : natural := BITNESS + 2;
  constant ERR_MIN     : integer := -(2 ** (ERROR_WIDTH - 1));
  constant ERR_MAX     : integer := (2 ** (ERROR_WIDTH - 1)) - 1;

  signal sErrval : signed(ERROR_WIDTH - 1 downto 0);
  signal sRiType : std_logic;
  signal sMap    : std_logic;
  signal sEm     : unsigned(MAPPED_W - 1 downto 0);

  function ref_em (
    err : integer;
    ri  : integer;
    mp  : integer
  ) return integer is
  begin

    return 2 * abs(err) - ri - mp;

  end function ref_em;

begin

  dut : entity work.a22_errval_mapping(behavioral)
    generic map (
      ERROR_WIDTH         => ERROR_WIDTH,
      MAPPED_ERRVAL_WIDTH => MAPPED_W
    )
    port map (
      iErrval   => sErrval,
      iRiType   => sRiType,
      iMap      => sMap,
      oEmErrVal => sEm
    );

  stim : process is

    variable rv       : RandomPType;
    variable covCross : CoverageIDType;        -- RItype x map (all 4 reachable)
    variable covZero  : CoverageIDType;        -- EMErrval == 0 boundary seen
    variable req      : AlertLogIDType;
    variable err      : integer;
    variable ri       : integer;
    variable mp       : integer;
    constant N_RAND   : natural := 8000;

    procedure drive_check (
      ev  : integer;
      riv : integer;
      mpv : integer;
      msg : string
    ) is

      variable exp : integer;
      variable z   : integer;

    begin

      sErrval <= to_signed(ev, ERROR_WIDTH);
      sRiType <= bool2bit(riv = 1);
      sMap    <= bool2bit(mpv = 1);
      wait for 1 ns;

      exp := ref_em(ev, riv, mpv);

      if (exp >= 0) then
        AffirmIfEqual(req, checked_integer(sEm), exp,
                      msg & " err=" & integer'image(ev) &
                      " ri=" & integer'image(riv) & " map=" & integer'image(mpv));
        if (exp = 0) then
          z := 1;
        else
          z := 0;
        end if;
        ICover(covCross, (riv, mpv));
        ICover(covZero, z);
      else
        -- EMErrval<0 is T.87-unreachable: it requires Errval=0 with RItype or map
        -- set, but RItype=1 => Errval/=0 and Errval=0 => map=0 (see header).
        -- Guard against ever skipping a coherent vector by changing the formula.
        AffirmIfEqual(GetAlertLogID("DefensiveClamp"), checked_integer(sEm), 0, "negative transient clamps to zero");
        AffirmIf(GetAlertLogID("DataChecks"), ev = 0 and (riv = 1 or mpv = 1),
                 "EMErrval<0 only on T.87-non-coherent inputs (Errval=0 with RItype/map set)");
      end if;

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a22_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A22", 300);

    covCross := NewID("ri x map");
    SetFieldName(covCross, "ri", "map");
    for axis0 in 0 to 1 loop
      for axis1 in 0 to 1 loop
        AddCross(covCross, "ri=" & to_string(axis0) & " / " & "map=" & to_string(axis1), GenBin(axis0), GenBin(axis1));
      end loop;
    end loop;
    covZero := NewID("emZero");
    SetFieldName(covZero, "emZero");
    AddBins(covZero, "nonzero mapped error", GenBin(0));
    AddBins(covZero, "zero mapped error", GenBin(1));

    -- Directed: EMErrval==0 boundary for each ri/map needing it.
    drive_check(1, 1, 1, "err1 ri1 map1 -> 0");        -- 2-1-1 = 0
    drive_check(1, 1, 0, "err1 ri1 map0 -> 1");
    drive_check(1, 0, 1, "err1 ri0 map1 -> 1");
    drive_check(0, 0, 0, "err0 ri0 map0 -> 0");
    drive_check(ERR_MAX, 1, 1, "max err");
    drive_check(ERR_MIN, 0, 0, "min err");

    for ev in ERR_MIN to ERR_MAX loop
      for riv in 0 to 1 loop
        for mpv in 0 to 1 loop
          drive_check(ev, riv, mpv, "error mapping sweep");
        end loop;
      end loop;
    end loop;

    for i in 1 to N_RAND loop

      -- Bias |err| small so the EMErrval==0 boundary bins fill.
      if (rv.RandInt(0, 1) = 0) then
        err := rv.RandInt(-2, 2);
      else
        err := rv.RandInt(ERR_MIN, ERR_MAX);
      end if;
      ri := rv.RandInt(0, 1);
      mp := rv.RandInt(0, 1);
      drive_check(err, ri, mp, "rand");
      exit when IsCovered(covCross) and IsCovered(covZero) and i > 400;

    end loop;

    WriteBin(covCross);
    WriteBin(covZero);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covCross), "ri x map coverage closed");
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covZero), "EMErrval==0 boundary covered");

    end_of_test("tb_a22_osvvm");
    wait;

  end process stim;

end architecture sim;
