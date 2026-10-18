-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a4_1_osvvm: a4_1_quant_gradient_merging against the T.87 A.4.1 rule
--
-- Guidelines:
--   G2.Clamp    N/A: no accumulator
--   G4.Config   N/A: no BITNESS generic
--   G4 other    N/A: Edge/Run/Coding/Stream not in scope
--   G5          N/A: combinational

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

  -- Element that decides the sign; 3 = all zero
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
    variable mm  : CoverageIDType;
    variable st  : CoverageIDType;
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
      ICover(mm, (1, checked_integer(sQ1o)));
      ICover(mm, (2, checked_integer(sQ2o)));
      ICover(mm, (3, checked_integer(sQ3o)));
      ICover(st, (1, q1));
      ICover(st, (2, q2));
      ICover(st, (3, q3));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a4_1_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A4.1", 729);

    cov := NewID("G4.Branch decider");
    SetFieldName(cov, "decider");
    AddBins(cov, "Q1 decides", GenBin(0));
    AddBins(cov, "Q2 decides", GenBin(1));
    AddBins(cov, "Q3 decides", GenBin(2));
    AddBins(cov, "all zero", GenBin(3));
    mm := NewID("G2.MinMax node x value");
    add_value_bin(mm, 1, "Q1 out", 0);
    add_value_bin(mm, 1, "Q1 out", 4);
    for lane in 2 to 3 loop
      add_value_bin(mm, lane, "Q" & to_string(lane) & " out", -4);
      add_value_bin(mm, lane, "Q" & to_string(lane) & " out", 4);
    end loop;
    st := NewID("G3.Stim node x value");
    for lane in 1 to 3 loop
      add_value_bin(st, lane, "Q" & to_string(lane), -4);
    end loop;

    -- Each decider, both polarities
    drive_check(0, 0, 0, "all-zero");
    drive_check(-1, 4, -4, "Q1 neg decides");
    drive_check(2, -3, 1, "Q1 pos decides");
    drive_check(0, -2, 4, "Q2 neg decides");
    drive_check(0, 3, -4, "Q2 pos decides");
    drive_check(0, 0, -1, "Q3 neg decides");
    drive_check(0, 0, 4, "Q3 pos decides");

    -- Exhaustive over [-4, 4]^3
    for q1 in -4 to 4 loop

      for q2 in -4 to 4 loop

        for q3 in -4 to 4 loop

          drive_check(q1, q2, q3, "exhaustive");

        end loop;

      end loop;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "decider coverage closed");
    affirm_covered(mm, "Q1..Q3 out min/max covered");
    affirm_covered(st, "Qi most negative covered");

    end_of_test("tb_a4_1_osvvm");
    wait;

  end process stim;

end architecture sim;
