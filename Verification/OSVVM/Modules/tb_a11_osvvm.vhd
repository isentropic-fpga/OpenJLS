-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.log2ceil;

library osvvm;
  context osvvm.OsvvmContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_a11_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a11_osvvm;

architecture sim of tb_a11_osvvm is

  constant N_WIDTH       : natural := CO_NQ_WIDTH_STD;
  constant B_WIDTH       : natural := BITNESS + 1;
  constant K_WIDTH       : natural := log2ceil(BITNESS + log2ceil(CO_RESET_STD) + 1);
  constant ERROR_WIDTH   : natural := BITNESS + 1;
  constant MAPPED_W      : natural := BITNESS + 2;

  constant ERR_MIN       : integer := -(2 ** (ERROR_WIDTH - 1));
  constant ERR_MAX       : integer := (2 ** (ERROR_WIDTH - 1)) - 1;
  constant N_MAX         : integer := (2 ** N_WIDTH) - 1;
  -- B only feeds the 2*B vs -N comparison; sweep the full signed B_WIDTH range.
  constant B_MIN         : integer := -(2 ** (B_WIDTH - 1));
  constant B_MAX         : integer := (2 ** (B_WIDTH - 1)) - 1;
  constant K_MAX         : integer := (2 ** K_WIDTH) - 1;

  signal sK              : unsigned(K_WIDTH - 1 downto 0);
  signal sBq             : signed(B_WIDTH - 1 downto 0);
  signal sNq             : unsigned(N_WIDTH - 1 downto 0);
  signal sErrorVal       : signed(ERROR_WIDTH - 1 downto 0);
  signal sMappedErrorVal : unsigned(MAPPED_W - 1 downto 0);

  -- Reference model: T.87 A.11 error mapping.

  function ref_map (
    kval   : integer;
    bval   : integer;
    nval   : integer;
    errval : integer
  ) return integer is

    variable special : boolean;

  begin

    special := (kval = 0) and (2 * bval <= -nval);

    if (special) then
      if (errval >= 0) then
        return 2 * errval + 1;
      else
        return 2 * (-errval) - 2;
      end if;
    else
      if (errval >= 0) then
        return 2 * errval;
      else
        return 2 * (-errval) - 1;
      end if;
    end if;

  end function ref_map;

begin

  dut : entity work.a11_error_mapping(behavioral)
    generic map (
      N_WIDTH                => N_WIDTH,
      B_WIDTH                => B_WIDTH,
      K_WIDTH                => K_WIDTH,
      ERROR_WIDTH            => ERROR_WIDTH,
      MAPPED_ERROR_VAL_WIDTH => MAPPED_W
    )
    port map (
      iK                     => sK,
      iBq                    => sBq,
      iNq                    => sNq,
      iErrorVal              => sErrorVal,
      oMappedErrorVal        => sMappedErrorVal
    );

  stim : process is

    variable rv       : RandomPType;
    variable cov      : CoverageIDType;
    variable req      : AlertLogIDType;
    variable kVal     : integer;
    variable bVal     : integer;
    variable nVal     : integer;
    variable errVal   : integer;
    variable expected : integer;
    variable actual   : integer;
    variable special  : integer;
    variable signIdx  : integer;
    constant N_RAND   : natural := 8000;

  begin

    SetAlertLogName("tb_a11_osvvm");
    SetLogEnable(PASSED, FALSE);

    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A11", 500);

    -- The interesting axis is (special_map, err_sign). Special map only fires
    -- when k=0 AND 2*B <= -N, which is rare under uniform random — bias it.
    -- Axis 0 (regular=0, special=1), axis 1 (err>=0 => 0, err<0 => 1).
    cov := NewID("Special x ErrSign");
    SetFieldName(cov, "Special", "ErrSign");
    for special in 0 to 1 loop
      for negative in 0 to 1 loop
        AddCross(cov, "special=" & to_string(special) & " / negative=" & to_string(negative),
          GenBin(ATLEAST => 100, Min => special, Max => special, NumBin => 1),
          GenBin(ATLEAST => 100, Min => negative, Max => negative, NumBin => 1));
      end loop;
    end loop;

    -- Directed corners
    -- (k=0, B=0, N=0, err=0) — special path fires (2*0 <= -0), expect 2*0+1 = 1
    sK        <= to_unsigned(0, sK'length);
    sBq       <= to_signed(0, sBq'length);
    sNq       <= to_unsigned(0, sNq'length);
    sErrorVal <= to_signed(0, sErrorVal'length);
    wait for 1 ns;
    AffirmIfEqual(req, checked_integer(sMappedErrorVal), 1, "corner all-zero (special fires)");

    -- True regular path with err=0: k=1 disables special
    sK <= to_unsigned(1, sK'length);
    wait for 1 ns;
    AffirmIfEqual(req, checked_integer(sMappedErrorVal), 0, "corner k=1 err=0 regular");

    -- Special path at err=0 → expect 2*0 - 2 in unsigned wrap? No — err>=0 branch: 2*0+1 = 1
    -- 2*(-1) <= -1 → special path.
    sK        <= to_unsigned(0, sK'length);
    sBq       <= to_signed(-1, sBq'length);
    sNq       <= to_unsigned(1, sNq'length);
    sErrorVal <= to_signed(0, sErrorVal'length);
    wait for 1 ns;
    AffirmIfEqual(req, checked_integer(sMappedErrorVal), 1, "corner special err=0");

    -- Special path at err=-1 → 2*1 - 2 = 0
    sErrorVal <= to_signed(-1, sErrorVal'length);
    wait for 1 ns;
    AffirmIfEqual(req, checked_integer(sMappedErrorVal), 0, "corner special err=-1");

    -- Regular path at err=ERR_MAX (k=1 forces regular).
    sK        <= to_unsigned(1, sK'length);
    sBq       <= to_signed(0, sBq'length);
    sNq       <= to_unsigned(0, sNq'length);
    sErrorVal <= to_signed(ERR_MAX, sErrorVal'length);
    wait for 1 ns;
    AffirmIfEqual(req, checked_integer(sMappedErrorVal), 2 * ERR_MAX, "corner regular err=ERR_MAX");

    -- Regular path at err=ERR_MIN
    sErrorVal <= to_signed(ERR_MIN, sErrorVal'length);
    wait for 1 ns;
    AffirmIfEqual(req, checked_integer(sMappedErrorVal), 2 * (-ERR_MIN) - 1, "corner regular err=ERR_MIN");

    -- Random sweep, biased so special-map fires often enough to close coverage.
    for n in 1 to CO_RESET_STD loop
      for delta in -1 to 1 loop
        for kval in 0 to 1 loop
          for ev in -2 to 2 loop
            bVal := -(n + 1) / 2 + delta;
            sK <= to_unsigned(kval, K_WIDTH);
            sBq <= to_signed(bVal, B_WIDTH);
            sNq <= to_unsigned(n, N_WIDTH);
            sErrorVal <= to_signed(ev, ERROR_WIDTH);
            wait for 1 ns;
            AffirmIfEqual(req, checked_integer(sMappedErrorVal), ref_map(kval, bVal, n, ev),
                          "special mapping equality/parity boundary");
          end loop;
        end loop;
      end loop;
    end loop;

    for i in 1 to N_RAND loop

      -- Half the iterations force the special-map precondition (k=0, big -B vs N)
      if (rv.RandInt(0, 1) = 0) then
        -- bVal range guarantees 2*B <= -N.
        kVal := 0;
        nVal := rv.RandInt(1, N_MAX);
        bVal := rv.RandInt(B_MIN, -(nVal + 1) / 2);
      else
        kVal := rv.RandInt(0, K_MAX);
        bVal := rv.RandInt(B_MIN, B_MAX);
        nVal := rv.RandInt(0, N_MAX);
      end if;

      errVal := rv.RandInt(ERR_MIN, ERR_MAX);

      sK        <= to_unsigned(kVal, sK'length);
      sBq       <= to_signed(bVal, sBq'length);
      sNq       <= to_unsigned(nVal, sNq'length);
      sErrorVal <= to_signed(errVal, sErrorVal'length);
      wait for 1 ns;

      expected := ref_map(kVal, bVal, nVal, errVal);
      actual   := checked_integer(sMappedErrorVal);
      AffirmIfEqual(req, actual, expected,
                    "k=" & integer'image(kVal) &
                    " b=" & integer'image(bVal) &
                    " n=" & integer'image(nVal) &
                    " err=" & integer'image(errVal));

      if ((kVal = 0) and (2 * bVal <= -nVal)) then
        special := 1;
      else
        special := 0;
      end if;

      if (errVal >= 0) then
        signIdx := 0;
      else
        signIdx := 1;
      end if;

      ICover(cov, (special, signIdx));

      exit when IsCovered(cov) and i > 500;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "Coverage closed");

    end_of_test("tb_a11_osvvm");
    wait;

  end process stim;

end architecture sim;
