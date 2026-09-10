-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: a4_1_quant_gradient_merging (written requirement A.4.1).
--
-- T.87 A.4.1: if the first non-zero element of (Q1,Q2,Q3) is negative, reverse
-- all three signs and set SIGN = -1, else SIGN = +1. Reference encodes that rule
-- directly; coverage closes which element decided the sign.
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library osvvm;
  context osvvm.OsvvmContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_a4_1_osvvm is
end entity tb_a4_1_osvvm;

architecture sim of tb_a4_1_osvvm is

  signal sQ1i  : signed(3 downto 0);
  signal sQ2i  : signed(3 downto 0);
  signal sQ3i  : signed(3 downto 0);
  signal sQ1o  : signed(3 downto 0);
  signal sQ2o  : signed(3 downto 0);
  signal sQ3o  : signed(3 downto 0);
  signal sSign : std_logic;

  -- decider: 0 = Q1, 1 = Q2, 2 = Q3, 3 = all-zero.
  function decider_of (
    q1 : integer;
    q2 : integer;
    q3 : integer
  ) return integer is
  begin

    if (q1 /= 0) then
      return 0;
    elsif (q2 /= 0) then
      return 1;
    elsif (q3 /= 0) then
      return 2;
    else
      return 3;
    end if;

  end function decider_of;

  -- SIGN = -1 (CO_SIGN_NEG) iff the deciding element is negative.
  function neg_sign (
    q1 : integer;
    q2 : integer;
    q3 : integer
  ) return boolean is
  begin

    return (q1 < 0) or (q1 = 0 and q2 < 0) or (q1 = 0 and q2 = 0 and q3 < 0);

  end function neg_sign;

begin

  dut : entity work.a4_1_quant_gradient_merging(behavioral)
    port map (
      iQ1   => sQ1i,
      iQ2   => sQ2i,
      iQ3   => sQ3i,
      oQ1   => sQ1o,
      oQ2   => sQ2o,
      oQ3   => sQ3o,
      oSign => sSign
    );

  stim : process is

    variable rv  : RandomPType;
    variable cov : CoverageIDType;
    variable req : AlertLogIDType;

    procedure drive_check (
      q1  : integer;
      q2  : integer;
      q3  : integer;
      msg : string
    ) is

      variable flip : boolean;
      variable eS   : std_logic;

    begin

      sQ1i <= to_signed(q1, 4);
      sQ2i <= to_signed(q2, 4);
      sQ3i <= to_signed(q3, 4);
      wait for 1 ns;

      flip := neg_sign(q1, q2, q3);
      if (flip) then
        eS := CO_SIGN_NEG;
      else
        eS := CO_SIGN_POS;
      end if;

      AffirmIfEqual(req, checked_bit(sSign), std_to_int(eS), msg & " sign");
      if (flip) then
        AffirmIfEqual(req, checked_integer(sQ1o), -q1, msg & " Q1");
        AffirmIfEqual(req, checked_integer(sQ2o), -q2, msg & " Q2");
        AffirmIfEqual(req, checked_integer(sQ3o), -q3, msg & " Q3");
      else
        AffirmIfEqual(req, checked_integer(sQ1o), q1, msg & " Q1");
        AffirmIfEqual(req, checked_integer(sQ2o), q2, msg & " Q2");
        AffirmIfEqual(req, checked_integer(sQ3o), q3, msg & " Q3");
      end if;

      ICover(cov, decider_of(q1, q2, q3));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a4_1_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A4.1", 729);

    cov := NewID("decider");
    SetFieldName(cov, "decider");
    AddBins(cov, "Q1 decides", GenBin(0));
    AddBins(cov, "Q2 decides", GenBin(1));
    AddBins(cov, "Q3 decides", GenBin(2));
    AddBins(cov, "all zero", GenBin(3));

    -- Directed: each decider category, both polarities.
    drive_check(0, 0, 0, "all-zero");
    drive_check(-1, 4, -4, "Q1 neg decides");
    drive_check(2, -3, 1, "Q1 pos decides");
    drive_check(0, -2, 4, "Q2 neg decides");
    drive_check(0, 3, -4, "Q2 pos decides");
    drive_check(0, 0, -1, "Q3 neg decides");
    drive_check(0, 0, 4, "Q3 pos decides");

    -- Exhaustive over the A.4 output domain [-4,4]^3.
    for q1 in -4 to 4 loop

      for q2 in -4 to 4 loop

        for q3 in -4 to 4 loop

          drive_check(q1, q2, q3, "exhaustive");

        end loop;

      end loop;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "decider coverage closed");

    end_of_test("tb_a4_1_osvvm");
    wait;

  end process stim;

end architecture sim;
