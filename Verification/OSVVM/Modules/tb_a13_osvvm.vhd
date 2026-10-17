-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a13_osvvm: a13_update_bias against the T.87 A.13 C code
--
-- Guidelines:
--   G1.Req      T87.A13
--   G1.Golden   A.13 C code as an integer reference
--   G2.Range    RTL A13_update_bias.vhd (range comments + postponed asserts)
--   G2.MinMax   G2.MinMax node x value
--   G2.Clamp    G2.Clamp event
--   G2.Checked  checked_* on all outputs
--   G3.Stim     G3.Stim node x value
--   G4.Coding   G4.Coding cUpdate
--   G4.Config   BITNESS 8/16 variants (OpenJls.pro)
--   G4 other    N/A: Edge/Run/Stream not in scope
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

entity tb_a13_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a13_osvvm;

architecture sim of tb_a13_osvvm is

  constant B_WIDTH : natural := BITNESS + 1;
  constant N_WIDTH : natural := CO_NQ_WIDTH_STD;
  constant C_WIDTH : natural := CO_CQ_WIDTH;
  constant MIN_C   : integer := CO_MIN_CQ;
  constant MAX_C   : integer := CO_MAX_CQ;
  constant RESET   : natural := CO_RESET_STD;

  signal sBq  : signed(B_WIDTH - 1 downto 0);
  signal sNq  : unsigned(N_WIDTH - 1 downto 0);
  signal sCq  : signed(C_WIDTH - 1 downto 0);
  signal sBqO : signed(B_WIDTH - 1 downto 0);
  signal sCqO : signed(C_WIDTH - 1 downto 0);

begin

  dut : entity work.a13_update_bias(rtl)
    generic map (
      B_WIDTH => B_WIDTH,
      N_WIDTH => N_WIDTH,
      C_WIDTH => C_WIDTH,
      MIN_C   => MIN_C,
      MAX_C   => MAX_C
    )
    port map (
      iBq => sBq,
      iNq => sNq,
      iCq => sCq,
      oBq => sBqO,
      oCq => sCqO
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable covC    : CoverageIDType;
    variable req     : AlertLogIDType;
    constant N_RAND  : natural := 8000;
    constant B_TMIN  : integer := -(2 ** (B_WIDTH - 1));
    constant B_TMAX  : integer := 2 ** (B_WIDTH - 1) - 1;
    variable mm, st  : CoverageIDType;

    procedure drive_check (
      b   : integer;
      n   : integer;
      c   : integer;
      msg : string
    ) is

      variable bNew : integer;
      variable cNew : integer;
      variable ev   : integer;
      variable cev  : integer;

    begin

      sBq <= to_signed(b, B_WIDTH);
      sNq <= to_unsigned(n, N_WIDTH);
      sCq <= to_signed(c, C_WIDTH);
      wait for 1 ns;

      bNew := b;
      cNew := c;
      ev   := 4;
      cev  := 0;

      if (b <= -n) then
        bNew := b + n;
        if (c > MIN_C) then
          cNew := c - 1;
          cev  := 1;
        else
          cev := 2;
        end if;
        if (bNew <= -n) then
          bNew := -n + 1;
          ev   := 1;
        else
          ev := 0;
        end if;
      elsif (b > 0) then
        bNew := b - n;
        if (c < MAX_C) then
          cNew := c + 1;
          cev  := 1;
        else
          cev := 3;
        end if;
        if (bNew > 0) then
          bNew := 0;
          ev   := 3;
        else
          ev := 2;
        end if;
      end if;

      AffirmIfEqual(req, checked_integer(sBqO), bNew, msg & " B");
      AffirmIfEqual(req, checked_integer(sCqO), cNew, msg & " C");
      ICover(cov, ev);
      ICover(covC, cev);
      ICover(mm, (1, b));
      ICover(mm, (2, n));
      ICover(mm, (3, cNew));
      ICover(st, (1, b));
      ICover(st, (2, c));
      ICover(st, (3, n));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a13_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A13", 300);

    cov := NewID("G2.Clamp event");
    SetFieldName(cov, "event");
    AddBins(cov, "negative adjust", GenBin(0));
    AddBins(cov, "negative clamp", GenBin(1));
    AddBins(cov, "positive adjust", GenBin(2));
    AddBins(cov, "positive clamp", GenBin(3));
    AddBins(cov, "unchanged", GenBin(4));

    covC := NewID("G4.Coding cUpdate");
    SetFieldName(covC, "cUpdate");
    AddBins(covC, "held",     GenBin(0, 0));
    AddBins(covC, "moved",    GenBin(1, 1));
    AddBins(covC, "clampMin", GenBin(2, 2));
    AddBins(covC, "clampMax", GenBin(3, 3));

    mm := NewID("G2.MinMax node x value");
    add_value_bin(mm, 1, "B", B_TMIN);
    add_value_bin(mm, 1, "B", B_TMAX);
    add_value_bin(mm, 2, "N", 1);
    add_value_bin(mm, 2, "N", RESET);
    add_value_bin(mm, 3, "C out", MIN_C);
    add_value_bin(mm, 3, "C out", MAX_C);
    st := NewID("G3.Stim node x value");
    add_value_bin(st, 1, "B", B_TMIN);
    add_value_bin(st, 2, "C", MIN_C);
    add_value_bin(st, 3, "N MSB", 2 ** (N_WIDTH - 1), RESET);
    drive_check(B_TMIN, RESET, MIN_C, "most negative B, C at MIN");
    drive_check(B_TMAX, RESET, MAX_C, "max B, C at MAX");
    drive_check(-100, 10, 0, "neg branch, big B (clamp)");
    drive_check(-12, 10, 0, "neg branch no clamp");
    drive_check(50, 10, 0, "pos branch clamp");
    drive_check(5, 10, 0, "pos branch no clamp");
    drive_check(0, 10, 0, "none branch");
    drive_check(-100, 10, MIN_C, "neg branch C at MIN");
    drive_check(50, 10, MAX_C, "pos branch C at MAX");

    -- Branch and reclamp boundaries, +-1
    for n in 1 to RESET loop
      for delta in -1 to 1 loop
        for c in MIN_C to MAX_C loop
          drive_check(-2 * n + delta, n, c, "negative reclamp boundary");
          drive_check(-n + delta, n, c, "negative branch boundary");
          drive_check(delta, n, c, "positive branch boundary");
          drive_check(n + delta, n, c, "positive reclamp boundary");
        end loop;
      end loop;
    end loop;

    for i in 1 to N_RAND loop

      if (rv.RandInt(0, 1) = 0) then
        drive_check(rv.RandInt(-(2 * RESET), 2 * RESET), rv.RandInt(1, RESET),
                    rv.RandInt(MIN_C, MAX_C), "rand small");
      else
        drive_check(rv.RandInt(-(2 ** (B_WIDTH - 1)), 2 ** (B_WIDTH - 1) - 1), rv.RandInt(1, RESET),
                    rv.RandInt(MIN_C, MAX_C), "rand wide");
      end if;
      exit when IsCovered(cov) and IsCovered(covC) and i > 300;

    end loop;

    WriteBin(cov);
    WriteBin(covC);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "branch/clamp coverage closed");
    affirm_covered(mm, "B/N/C min/max covered");
    affirm_covered(st, "most negative B/C and N MSB covered");
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covC), "C-update coverage closed");

    end_of_test("tb_a13_osvvm");
    wait;

  end process stim;

end architecture sim;
