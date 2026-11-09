-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a12_a13_osvvm: a12_a13_update against the T.87 A.12 then A.13 C code
--
-- Negative B halves with the C form -((1-B)>>1), not the RTL shift.
--
-- Guidelines:
--   G4 other    N/A: Edge/Run/Stream not in scope
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

entity tb_a12_a13_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a12_a13_osvvm;

architecture sim of tb_a12_a13_osvvm is

  constant ERROR_WIDTH : natural := BITNESS + 1;
  constant A_WIDTH     : natural := BITNESS + log2ceil(CO_RESET_STD);
  constant B_WIDTH     : natural := BITNESS + 1;
  constant N_WIDTH     : natural := CO_NQ_WIDTH_STD;
  constant C_WIDTH     : natural := CO_CQ_WIDTH;
  constant MIN_C       : integer := CO_MIN_CQ;
  constant MAX_C       : integer := CO_MAX_CQ;
  constant RESET       : natural := CO_RESET_STD;

  -- T.87 operating ranges, post-A.9 Errval
  constant ERR_LO : integer := -(2 ** BITNESS / 2);
  constant ERR_HI : integer := 2 ** BITNESS / 2;
  constant A_HI   : integer := (RESET - 1) * 2 ** BITNESS / 2;
  constant B_LIM  : integer := RESET - 1;

  signal sErr   : signed(ERROR_WIDTH - 1 downto 0);
  signal sAq    : unsigned(A_WIDTH - 1 downto 0);
  signal sBq    : signed(B_WIDTH - 1 downto 0);
  signal sCq    : signed(C_WIDTH - 1 downto 0);
  signal sNq    : unsigned(N_WIDTH - 1 downto 0);
  signal sNqNew : unsigned(N_WIDTH - 1 downto 0);
  signal sRsc   : std_logic;
  signal sAqO   : unsigned(A_WIDTH - 1 downto 0);
  signal sBqO   : signed(B_WIDTH - 1 downto 0);
  signal sCqO   : signed(C_WIDTH - 1 downto 0);
  signal sDec   : std_logic;
  signal sInc   : std_logic;

begin

  dut : entity work.a12_a13_update(rtl)
    generic map (
      ERROR_WIDTH => ERROR_WIDTH,
      A_WIDTH     => A_WIDTH,
      B_WIDTH     => B_WIDTH,
      N_WIDTH     => N_WIDTH,
      C_WIDTH     => C_WIDTH,
      MIN_C       => MIN_C,
      MAX_C       => MAX_C,
      RESET       => RESET
    )
    port map (
      iErrorVal => sErr,
      iAq       => sAq,
      iBq       => sBq,
      iCq       => sCq,
      iNq       => sNq,
      iNqNew    => sNqNew,
      iRescale  => sRsc,
      oAq       => sAqO,
      oBq       => sBqO,
      oCq       => sCqO,
      oDec      => sDec,
      oInc      => sInc
    );

  stim : process is

    variable rv         : RandomPType;
    variable cov        : CoverageIDType;
    variable covC       : CoverageIDType;
    variable mm, st     : CoverageIDType;
    variable req        : AlertLogIDType;
    constant N_RAND     : natural := 8000;

    procedure drive_check (
      err : integer;
      a   : integer;
      b   : integer;
      n   : integer;
      c   : integer;
      msg : string
    ) is

      variable rescale : boolean;
      variable aNew    : integer;
      variable bSum    : integer;
      variable bMid    : integer;
      variable bNew    : integer;
      variable nNew    : integer;
      variable cNew    : integer;
      variable ev      : integer;
      variable cev     : integer;

    begin

      -- A.12
      rescale := (n = RESET);
      aNew    := a + abs(err);
      bSum    := b + err;
      bMid    := bSum;
      nNew    := n + 1;

      if (rescale) then
        aNew := aNew / 2;
        if (bSum >= 0) then
          bMid := bSum / 2;
        else
          bMid := -((1 - bSum) / 2);
        end if;
        nNew := (n / 2) + 1;
      end if;

      -- A.13
      bNew := bMid;
      cNew := c;
      ev   := 4;
      cev  := 0;

      if (bMid <= -nNew) then
        bNew := bMid + nNew;
        if (c > MIN_C) then
          cNew := c - 1;
          cev  := 1;
        else
          cev := 2;
        end if;
        if (bNew <= -nNew) then
          bNew := -nNew + 1;
          ev   := 1;
        else
          ev := 0;
        end if;
      elsif (bMid > 0) then
        bNew := bMid - nNew;
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

      sErr   <= to_signed(err, ERROR_WIDTH);
      sAq    <= to_unsigned(a, A_WIDTH);
      sBq    <= to_signed(b, B_WIDTH);
      sCq    <= to_signed(c, C_WIDTH);
      sNq    <= to_unsigned(n, N_WIDTH);
      sNqNew <= to_unsigned(nNew, N_WIDTH);
      sRsc   <= bool2bit(rescale);
      wait for 1 ns;

      AffirmIfEqual(req, checked_integer(sAqO), aNew, msg & " A");
      AffirmIfEqual(req, checked_integer(sBqO), bNew, msg & " B");
      AffirmIfEqual(req, checked_integer(sCqO), cNew, msg & " C");
      AffirmIfEqual(req, sDec, bool2bit(bMid <= -nNew), msg & " Dec");
      AffirmIfEqual(req, sInc, bool2bit(bMid > -nNew and bMid > 0), msg & " Inc");

      if (rescale) then
        ICover(cov, (1, ev));
      else
        ICover(cov, (0, ev));
      end if;
      ICover(covC, cev);
      ICover(mm, (1, err));
      ICover(mm, (2, a));
      ICover(mm, (3, b));
      ICover(mm, (4, n));
      ICover(mm, (5, cNew));
      ICover(st, (1, err));
      ICover(st, (2, b));
      ICover(st, (3, n));

    end procedure drive_check;

    -- Errval landing B + Errval on target, in range
    impure function err_for (b : integer; target : integer) return integer is
    begin
      return maximum(ERR_LO, minimum(ERR_HI, target - b));
    end function err_for;

    variable nNext, scale, base : integer;
    type t_int_list is array (natural range <>) of integer;
    constant B_POINTS : t_int_list := (0, -1, -B_LIM, B_LIM);
    constant C_POINTS : t_int_list := (MIN_C, MIN_C + 1, 0, MAX_C - 1, MAX_C);

  begin

    SetAlertLogName("tb_a12_a13_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name & run_seed);
    req := GetReqID("T87.A12A13", 230000);

    cov := NewID("G2.Rescale x clamp event");
    SetFieldName(cov, "rescale", "event");
    for r in 0 to 1 loop
      AddCross(cov, "rescale=" & to_string(r) & " / negative adjust", GenBin(r), GenBin(0));
      AddCross(cov, "rescale=" & to_string(r) & " / negative clamp", GenBin(r), GenBin(1));
      AddCross(cov, "rescale=" & to_string(r) & " / positive adjust", GenBin(r), GenBin(2));
      AddCross(cov, "rescale=" & to_string(r) & " / positive clamp", GenBin(r), GenBin(3));
      AddCross(cov, "rescale=" & to_string(r) & " / unchanged", GenBin(r), GenBin(4));
    end loop;

    covC := NewID("G4.Coding cUpdate");
    SetFieldName(covC, "cUpdate");
    AddBins(covC, "held",     GenBin(0, 0));
    AddBins(covC, "moved",    GenBin(1, 1));
    AddBins(covC, "clampMin", GenBin(2, 2));
    AddBins(covC, "clampMax", GenBin(3, 3));

    mm := NewID("G2.MinMax node x value");
    add_value_bin(mm, 1, "Errval", ERR_LO);
    add_value_bin(mm, 1, "Errval", ERR_HI);
    add_value_bin(mm, 2, "A", 0);
    add_value_bin(mm, 2, "A", A_HI);
    add_value_bin(mm, 3, "B", -B_LIM);
    add_value_bin(mm, 3, "B", B_LIM);
    add_value_bin(mm, 4, "N", 1);
    add_value_bin(mm, 4, "N", RESET);
    add_value_bin(mm, 5, "C out", MIN_C);
    add_value_bin(mm, 5, "C out", MAX_C);
    st := NewID("G3.Stim node x value");
    add_value_bin(st, 1, "Errval", ERR_LO);
    add_value_bin(st, 2, "B", -B_LIM);
    add_value_bin(st, 3, "N MSB", 2 ** (N_WIDTH - 1), RESET);

    drive_check(ERR_LO, 0, -B_LIM, RESET, MIN_C, "most negative sum, rescale");
    drive_check(ERR_HI, A_HI, B_LIM, RESET, MAX_C, "most positive sum, rescale");
    drive_check(ERR_LO, 0, -B_LIM, 1, MIN_C, "most negative sum");
    drive_check(ERR_HI, A_HI, B_LIM, 1, MAX_C, "most positive sum");

    -- Every branch and reclamp boundary of the post-A.12 values, +-3, unhalved or halved
    for n in 1 to RESET loop
      if (n = RESET) then
        nNext := RESET / 2 + 1;
        scale := 2;
      else
        nNext := n + 1;
        scale := 1;
      end if;
      for bi in B_POINTS'range loop
        for t in -3 to 3 loop
          for ci in C_POINTS'range loop
            for target in 0 to 3 loop
              case target is
                when 0 => base := -2 * nNext;
                when 1 => base := -nNext;
                when 2 => base := 0;
                when others => base := nNext;
              end case;
              drive_check(err_for(B_POINTS(bi), scale * base + t), rv.RandInt(0, A_HI), B_POINTS(bi), n, C_POINTS(ci),
                          "boundary");
            end loop;
          end loop;
        end loop;
      end loop;
    end loop;

    for i in 1 to N_RAND loop

      drive_check(rv.RandInt(ERR_LO, ERR_HI), rv.RandInt(0, A_HI), rv.RandInt(-B_LIM, B_LIM),
                  rv.RandInt(1, RESET), rv.RandInt(MIN_C, MAX_C), "rand");
      drive_check(rv.RandInt(-200, 200), rv.RandInt(0, A_HI), rv.RandInt(-B_LIM, B_LIM),
                  RESET, rv.RandInt(MIN_C, MAX_C), "rand rescale");

    end loop;

    WriteBin(cov);
    WriteBin(covC);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "rescale x branch/clamp coverage closed");
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covC), "C-update coverage closed");
    affirm_covered(mm, "Errval/A/B/N/C min/max covered");
    affirm_covered(st, "most negative Errval/B and N MSB covered");

    end_of_test("tb_a12_a13_osvvm");
    wait;

  end process stim;

end architecture sim;
