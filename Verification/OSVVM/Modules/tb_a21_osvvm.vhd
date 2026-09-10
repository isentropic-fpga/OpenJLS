-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: a21_compute_map (combinational).
--
-- T.87 Code segment A.21 map computation, transcribed verbatim. Coverage closes
-- which clause fired (the two positive paths, the k!=0 negative path, and the
-- else), biasing k, Errval sign and the 2*Nn vs Nq relation to reach all four.
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

entity tb_a21_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a21_osvvm;

architecture sim of tb_a21_osvvm is

  constant K_WIDTH     : natural := log2ceil(BITNESS + log2ceil(CO_RESET_STD) + 1);
  constant N_WIDTH     : natural := CO_NQ_WIDTH_STD;
  constant ERROR_WIDTH : natural := BITNESS + 1;
  constant K_MAX       : integer := (2 ** K_WIDTH) - 1;
  constant N_MAX       : integer := (2 ** N_WIDTH) - 1;
  constant ERR_MIN     : integer := -(2 ** (ERROR_WIDTH - 1));
  constant ERR_MAX     : integer := (2 ** (ERROR_WIDTH - 1)) - 1;

  signal sK      : unsigned(K_WIDTH - 1 downto 0);
  signal sErrval : signed(ERROR_WIDTH - 1 downto 0);
  signal sNn     : unsigned(N_WIDTH - 1 downto 0);
  signal sNq     : unsigned(N_WIDTH - 1 downto 0);
  signal sMap    : std_logic;

  -- clause: 0 = first, 1 = second, 2 = third, 3 = else (per A.21 order).
  function clause_of (
    k   : integer;
    err : integer;
    nn  : integer;
    nq  : integer
  ) return integer is
  begin

    if ((k = 0) and (err > 0) and (2 * nn < nq)) then
      return 0;
    elsif ((err < 0) and (2 * nn >= nq)) then
      return 1;
    elsif ((err < 0) and (k /= 0)) then
      return 2;
    else
      return 3;
    end if;

  end function clause_of;

  function ref_map (
    k   : integer;
    err : integer;
    nn  : integer;
    nq  : integer
  ) return std_logic is
  begin

    if (clause_of(k, err, nn, nq) = 3) then
      return '0';
    else
      return '1';
    end if;

  end function ref_map;

begin

  dut : entity work.a21_compute_map(behavioral)
    generic map (
      K_WIDTH     => K_WIDTH,
      N_WIDTH     => N_WIDTH,
      ERROR_WIDTH => ERROR_WIDTH
    )
    port map (
      iK      => sK,
      iErrval => sErrval,
      iNn     => sNn,
      iNq     => sNq,
      oMap    => sMap
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable req     : AlertLogIDType;
    variable k       : integer;
    variable err     : integer;
    variable nn      : integer;
    variable nq      : integer;
    constant N_RAND  : natural := 8000;

    procedure drive_check (
      k   : integer;
      err : integer;
      nn  : integer;
      nq  : integer;
      msg : string
    ) is
    begin

      sK      <= to_unsigned(k, K_WIDTH);
      sErrval <= to_signed(err, ERROR_WIDTH);
      sNn     <= to_unsigned(nn, N_WIDTH);
      sNq     <= to_unsigned(nq, N_WIDTH);
      wait for 1 ns;
      AffirmIfEqual(req, checked_bit(sMap), std_to_int(ref_map(k, err, nn, nq)),
                    msg & " k=" & integer'image(k) & " err=" & integer'image(err) &
                    " nn=" & integer'image(nn) & " nq=" & integer'image(nq));
      ICover(cov, clause_of(k, err, nn, nq));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a21_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A21", 400);

    cov := NewID("clause");
    SetFieldName(cov, "clause");
    AddBins(cov, "positive special", GenBin(0));
    AddBins(cov, "negative frequent", GenBin(1));
    AddBins(cov, "negative nonzero k", GenBin(2));
    AddBins(cov, "unmapped", GenBin(3));

    -- Directed: one per clause.
    drive_check(0, 5, 1, 10, "clause1");
    drive_check(2, -5, 10, 5, "clause2");
    drive_check(2, -5, 1, 10, "clause3");
    drive_check(0, 5, 10, 5, "else pos");
    drive_check(3, 0, 4, 4, "else zero");

    -- Random sweep with small-k and signed-Errval bias.
    for nq in 1 to CO_RESET_STD loop
      for nn in 0 to nq - 1 loop
        for kval in 0 to K_MAX loop
          for error in -1 to 1 loop
            drive_check(kval, error, nn, nq, "coherent count/sign/k sweep");
          end loop;
        end loop;
      end loop;
    end loop;

    for i in 1 to N_RAND loop

      if (rv.RandInt(0, 1) = 0) then
        k := rv.RandInt(0, 2);            -- bias small k
      else
        k := rv.RandInt(0, K_MAX);
      end if;
      err := rv.RandInt(ERR_MIN, ERR_MAX);
      nn  := rv.RandInt(0, N_MAX);
      nq  := rv.RandInt(0, N_MAX);
      drive_check(k, err, nn, nq, "rand");

      exit when IsCovered(cov) and i > 400;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "clause coverage closed");

    end_of_test("tb_a21_osvvm");
    wait;

  end process stim;

end architecture sim;
