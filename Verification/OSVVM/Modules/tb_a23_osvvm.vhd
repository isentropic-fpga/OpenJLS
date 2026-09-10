-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: a23_run_interruption_update (combinational).
--
-- T.87 Code segment A.23 (standard form), transcribed verbatim:
--   if (Errval < 0) Nn += 1;
--   A += (EMErrval + 1 - RItype) >> 1;          -- floor shift
--   if (N == RESET) { A>>=1; N>>=1; Nn>>=1; }
--   N += 1;
-- where EMErrval = 2*abs(Errval) - RItype - map (A.22). The RTL drops map via the
-- Mert Fig.9 equivalence (A += abs(Errval) - RItype). The reference deliberately
-- keeps the *standard* map-dependent form and drives map as a free random input
-- not fed to the DUT, so a passing check also proves the equivalence holds for
-- both map values.
--
-- Every result is representable for T.87-coherent inputs:
--   A_new = A + |Errval| - RItype >= 0: RItype=0 => A+|Errval|>=0; RItype=1 =>
--     |Errval|>=1 (a run-interruption sample has Ix/=Ra, see tb_a22) => A_new>=A>=0.
--   Nn_new <= RESET-1: the invariant N-Nn>=1 holds from init (N=1,Nn=0) and is
--     preserved by the update (N+1, Nn+<=1) and the rescale (floor halving), so
--     input Nn<=N-1 and Nn_new = Nn+1 <= N <= RESET-1 (N=RESET takes the halving).
--   N_new <= RESET+1 < 2^N_WIDTH.
-- Directed and random stimulus obey these invariants. Invalid inputs or
-- unrepresentable reference results fail under the ReferenceDomain alert ID.
-- Coverage crosses RESET x Errval-sign x RItype.
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

  -- Floor division by 2 (arithmetic >>1), matching the C semantics.
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

    -- Reject invalid stimulus instead of silently skipping a comparison.
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
      -- Compute the standard reference first.
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

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a23_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A23", 600);

    cov := NewID("rescale x errNeg x RItype");
    SetFieldName(cov, "rescale", "errNeg", "RItype");
    for axis0 in 0 to 1 loop
      for axis1 in 0 to 1 loop
        for axis2 in 0 to 1 loop
          AddCross(cov, "rescale=" & to_string(axis0) & " / " & "errNeg=" & to_string(axis1) & " / " & "RItype=" & to_string(axis2), GenBin(axis0), GenBin(axis1), GenBin(axis2));
        end loop;
      end loop;
    end loop;

    -- Directed corners (both map values on the same vector to exercise equivalence).
    drive_check(-5, 0, 100, RESET, 10, 0, "rescale errneg ri0 m0");
    drive_check(-5, 0, 100, RESET, 10, 1, "rescale errneg ri0 m1");
    drive_check(5, 1, 100, 10, 4, 0, "errpos ri1 m0");
    drive_check(5, 1, 100, 10, 4, 1, "errpos ri1 m1");
    drive_check(0, 0, 50, 5, 0, 0, "err0 ri0");

    -- Nn increments before halving; cover every coherent count and parity.
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
        n := RESET;                                  -- bias the rescale path
      else
        n := rv.RandInt(1, RESET);
      end if;
      nn := rv.RandInt(0, n - 1);
      drive_check(err, ri, a, n, nn, mp, "rand coherent");
      exit when IsCovered(cov) and i > 600;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "rescale x errNeg x RItype coverage closed");

    end_of_test("tb_a23_osvvm");
    wait;

  end process stim;

end architecture sim;
