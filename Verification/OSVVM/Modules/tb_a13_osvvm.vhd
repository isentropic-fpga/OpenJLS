-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: a13_update_bias (combinational).
--
-- T.87 Code segment A.13, transcribed verbatim (note the inner re-test of B
-- against -N after the adjust):
--   if (B <= -N) { B += N; if (C>MIN_C) C--; if (B <= -N) B = -N+1; }
--   else if (B > 0) { B -= N; if (C<MAX_C) C++; if (B > 0) B = 0; }
-- Coverage closes the three branches and both inner-clamp outcomes.
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
    variable covC    : CoverageIDType;   -- C-register update: held / moved / clamp-min / clamp-max
    variable req     : AlertLogIDType;
    constant N_RAND  : natural := 8000;

    -- event: 0 neg-noclamp, 1 neg-clamp, 2 pos-noclamp, 3 pos-clamp, 4 none.
    procedure drive_check (
      b   : integer;
      n   : integer;
      c   : integer;
      msg : string
    ) is

      variable bNew : integer;
      variable cNew : integer;
      variable ev   : integer;
      variable cev  : integer;   -- 0 held (none), 1 moved, 2 clamp@MIN, 3 clamp@MAX

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
          cev := 2;          -- C already at MIN_C: decrement clamped
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
          cev := 3;          -- C already at MAX_C: increment clamped
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

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a13_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A13", 300);

    cov := NewID("event");
    SetFieldName(cov, "event");
    AddBins(cov, "negative adjust", GenBin(0));
    AddBins(cov, "negative clamp", GenBin(1));
    AddBins(cov, "positive adjust", GenBin(2));
    AddBins(cov, "positive clamp", GenBin(3));
    AddBins(cov, "unchanged", GenBin(4));

    -- C-register saturation: the event bins above don't distinguish a clamped
    -- C from a moved C, so bin the C update separately (held in the none branch,
    -- moved within range, or clamped at MIN_C/MAX_C).
    covC := NewID("cUpdate");
    SetFieldName(covC, "cUpdate");
    AddBins(covC, "held",     GenBin(0, 0));
    AddBins(covC, "moved",    GenBin(1, 1));
    AddBins(covC, "clampMin", GenBin(2, 2));
    AddBins(covC, "clampMax", GenBin(3, 3));

    -- Directed: one per event.
    drive_check(-100, 10, 0, "neg branch, big B (clamp)");   -- B=-100<=-10; B+N=-90<=-10 -> clamp
    drive_check(-12, 10, 0, "neg branch no clamp");          -- B=-12<=-10; B+N=-2 >-10 -> no clamp
    drive_check(50, 10, 0, "pos branch clamp");              -- B=50>0; B-N=40>0 -> clamp 0
    drive_check(5, 10, 0, "pos branch no clamp");            -- B=5>0; B-N=-5 <=0 -> no clamp
    drive_check(0, 10, 0, "none branch");                    -- B=0, not <=-10, not >0
    drive_check(-100, 10, MIN_C, "neg branch C at MIN");     -- C not decremented
    drive_check(50, 10, MAX_C, "pos branch C at MAX");       -- C not incremented

    -- Random sweep (N in [1,RESET]; B biased to the two active branches).
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
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covC), "C-update coverage closed");

    end_of_test("tb_a13_osvvm");
    wait;

  end process stim;

end architecture sim;
