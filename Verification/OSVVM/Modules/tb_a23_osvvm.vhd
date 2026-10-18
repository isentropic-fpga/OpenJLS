-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a23_osvvm: a23_run_interruption_update against the T.87 A.23 C code
--
-- The RTL uses A += |Errval| - RItype (Mert Fig. 9). The reference keeps the
-- map-dependent C form and drives map without feeding it to the DUT, so a pass
-- also proves the equivalence for both map values.
-- Stimulus is T.87-coherent (Nn < N, RItype 1 => Errval /= 0); anything else
-- fails under ReferenceDomain.
--
-- Guidelines:
--   G4 other    N/A: Edge/Coding/Stream not in scope
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

entity tb_a23_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a23_osvvm;

architecture sim of tb_a23_osvvm is

  constant A_WIDTH     : natural := BITNESS + log2ceil(CO_RESET_STD);
  constant N_WIDTH     : natural := CO_NQ_WIDTH_STD;
  constant NN_WIDTH    : natural := CO_NNQ_WIDTH_STD;
  constant ERROR_WIDTH : natural := BITNESS + 1;
  constant RESET       : natural := CO_RESET_STD;

  constant ERR_LO : integer := -(2 ** BITNESS / 2);
  constant ERR_HI : integer := 2 ** BITNESS / 2;
  constant A_HI   : integer := (RESET - 1) * 2 ** BITNESS / 2;
  constant NN_MAX : integer := (2 ** NN_WIDTH) - 1;

  signal sErr  : signed(ERROR_WIDTH - 1 downto 0);
  signal sRi   : std_logic;
  signal sAq   : unsigned(A_WIDTH - 1 downto 0);
  signal sNq   : unsigned(N_WIDTH - 1 downto 0);
  signal sNn   : unsigned(NN_WIDTH - 1 downto 0);
  signal sAqO  : unsigned(A_WIDTH - 1 downto 0);
  signal sNqO  : unsigned(N_WIDTH - 1 downto 0);
  signal sNnO  : unsigned(NN_WIDTH - 1 downto 0);

  -- C >> 1 on a signed value (floor)
  function fdiv2 (
    x : integer
  ) return integer is
  begin

    if (x >= 0) then
      return x / 2;
    else
      return -(((-x) + 1) / 2);
    end if;

  end function fdiv2;

begin

  dut : entity work.a23_run_interruption_update(behavioral)
    generic map (
      A_WIDTH     => A_WIDTH,
      N_WIDTH     => N_WIDTH,
      NN_WIDTH    => NN_WIDTH,
      ERROR_WIDTH => ERROR_WIDTH,
      RESET       => RESET
    )
    port map (
      iErrVal => sErr,
      iRiType => sRi,
      iAq     => sAq,
      iNq     => sNq,
      iNn     => sNn,
      oAq     => sAqO,
      oNq     => sNqO,
      oNn     => sNnO
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable req     : AlertLogIDType;
    variable err     : integer;
    variable a       : integer;
    variable n       : integer;
    variable nn      : integer;
    variable ri      : integer;
    variable mp      : integer;
    constant N_RAND  : natural := 12000;
    variable mm, st, cl : CoverageIDType;

    procedure drive_check (
      errv : integer;
      riv  : integer;
      av   : integer;
      nv   : integer;
      nnv  : integer;
      mapv : integer;
      msg  : string
    ) is

      variable rescale : boolean;
      variable emv     : integer;
      variable aAdd    : integer;
      variable aNew    : integer;
      variable nNew    : integer;
      variable nnNew   : integer;
      variable rsc     : integer;
      variable eNeg    : integer;

    begin

      AffirmIf(GetAlertLogID("ReferenceDomain"),
        (riv = 0 or errv /= 0) and nv >= 1 and nv <= RESET and nnv >= 0 and nnv < nv,
        msg & " coherent T.87 input");
      nnNew := nnv;
      if (errv < 0) then
        nnNew := nnNew + 1;
      end if;
      emv  := 2 * abs(errv) - riv - mapv;
      aAdd := fdiv2(emv + 1 - riv);
      aNew := av + aAdd;

      rescale := (nv = RESET);
      if (rescale) then
        aNew  := aNew / 2;
        nNew  := (nv / 2) + 1;
        nnNew := nnNew / 2;
      else
        nNew := nv + 1;
      end if;

      if aNew < 0 or aNew >= 2 ** A_WIDTH or nnNew > NN_MAX or
         nNew > (2 ** N_WIDTH) - 1 then
        Alert(GetAlertLogID("ReferenceDomain"), msg & " reference result out of range", ERROR);
        return;
      end if;

      sErr <= to_signed(errv, ERROR_WIDTH);
      sRi  <= bool2bit(riv = 1);
      sAq  <= to_unsigned(av, A_WIDTH);
      sNq  <= to_unsigned(nv, N_WIDTH);
      sNn  <= to_unsigned(nnv, NN_WIDTH);
      wait for 1 ns;

      AffirmIfEqual(req, checked_integer(sAqO), aNew, msg & " A");
      AffirmIfEqual(req, checked_integer(sNqO), nNew, msg & " N");
      AffirmIfEqual(req, checked_integer(sNnO), nnNew, msg & " Nn");

      if (rescale) then
        rsc := 1;
      else
        rsc := 0;
      end if;
      if (errv < 0) then
        eNeg := 1;
      else
        eNeg := 0;
      end if;
      ICover(cov, (rsc, eNeg, riv));
      ICover(mm, (1, errv));
      ICover(mm, (2, av));
      ICover(mm, (3, nv));
      ICover(mm, (4, nnv));
      ICover(st, (1, errv));
      ICover(st, (2, nv));
      ICover(cl, (1, nv));
      if rescale then
        ICover(cl, (2, nnv));
      end if;

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a23_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A23", 600);

    cov := NewID("G4.Run rescale x errNeg x RItype");
    SetFieldName(cov, "rescale", "errNeg", "RItype");
    for axis0 in 0 to 1 loop
      for axis1 in 0 to 1 loop
        for axis2 in 0 to 1 loop
          AddCross(cov, "rescale=" & to_string(axis0) & " / " & "errNeg=" & to_string(axis1) & " / " & "RItype=" & to_string(axis2), GenBin(axis0), GenBin(axis1), GenBin(axis2));
        end loop;
      end loop;
    end loop;

    mm := NewID("G2.MinMax node x value");
    add_value_bin(mm, 1, "Errval", ERR_LO);
    add_value_bin(mm, 1, "Errval", ERR_HI);
    add_value_bin(mm, 2, "A", 0);
    add_value_bin(mm, 2, "A", A_HI);
    add_value_bin(mm, 3, "N", 1);
    add_value_bin(mm, 3, "N", RESET);
    add_value_bin(mm, 4, "Nn", 0);
    add_value_bin(mm, 4, "Nn", RESET - 1);
    st := NewID("G3.Stim node x value");
    add_value_bin(st, 1, "Errval", ERR_LO);
    add_value_bin(st, 2, "N MSB", 2 ** (N_WIDTH - 1), RESET);
    cl := NewID("G2.Clamp node x value");
    add_value_bin(cl, 1, "N", RESET - 1);
    add_value_bin(cl, 1, "N", RESET);
    add_value_bin(cl, 2, "Nn at N=RESET", RESET - 1);
    drive_check(ERR_LO, 0, A_HI, RESET, RESET - 1, 0, "most negative err, max A/N/Nn");
    drive_check(ERR_HI, 1, 0, 1, 0, 0, "max err, min A/N/Nn");
    -- Both map values on the same vector
    drive_check(-5, 0, 100, RESET, 10, 0, "rescale errneg ri0 m0");
    drive_check(-5, 0, 100, RESET, 10, 1, "rescale errneg ri0 m1");
    drive_check(5, 1, 100, 10, 4, 0, "errpos ri1 m0");
    drive_check(5, 1, 100, 10, 4, 1, "errpos ri1 m1");
    drive_check(0, 0, 50, 5, 0, 0, "err0 ri0");

    -- Nn increments before halving; every coherent count and parity
    for nv in 1 to RESET loop
      for nnv in 0 to nv - 1 loop
        for riv in 0 to 1 loop
          for ev in -2 to 2 loop
            if riv = 0 or ev /= 0 then
              drive_check(ev, riv, 7, nv, nnv, 0, "coherent rescale/parity");
              drive_check(ev, riv, 7, nv, nnv, 1, "mapping cancellation");
            end if;
          end loop;
        end loop;
      end loop;
    end loop;

    for i in 1 to N_RAND loop

      err := rv.RandInt(ERR_LO, ERR_HI);
      ri  := rv.RandInt(0, 1);
      a   := rv.RandInt(0, A_HI);
      if ri = 1 and err = 0 then
        err := 1;
      end if;
      mp  := rv.RandInt(0, 1);
      if (rv.RandInt(0, 2) = 0) then
        n := RESET;
      else
        n := rv.RandInt(1, RESET);
      end if;
      nn := rv.RandInt(0, n - 1);
      drive_check(err, ri, a, n, nn, mp, "rand coherent");
      exit when IsCovered(cov) and i > 600;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "rescale x errNeg x RItype coverage closed");
    affirm_covered(mm, "Errval/A/N/Nn min/max covered");
    affirm_covered(st, "most negative Errval and N MSB covered");
    affirm_covered(cl, "N/Nn reset point and one before covered");

    end_of_test("tb_a23_osvvm");
    wait;

  end process stim;

end architecture sim;
