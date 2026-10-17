-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: a12_variables_update (combinational).
--
-- T.87 Code segment A.12 with NEAR=0 (2*NEAR+1 = 1):
--   B += Errval; A += abs(Errval);
--   if (N == RESET) { A>>=1; B = (B>=0)? B>>1 : -((1-B)>>1); N>>=1; }
--   N += 1;
-- Reference follows that order verbatim; the negative-B halving uses the C
-- -((1-B)>>1) form (not the RTL arithmetic shift) so the two stay independent.
-- Coverage crosses the RESET rescale with the post-add sign of B.
--
-- Guidelines:
--   G1.Req      T87.A12
--   G1.Golden   A.12 C code as an integer reference
--   G2.Range    RTL A12_variables_update.vhd (range comments + postponed asserts)
--   G2.MinMax   G2.MinMax node x value
--   G2.Clamp    G2.Clamp node x value
--   G2.Checked  checked_* on all outputs
--   G3.Stim     G3.Stim node x value
--   G4.Coding   G4.Coding rescale x bSumSign
--   G4.Config   BITNESS 8/16 variants (OpenJls.pro)
--   G4 other    N/A: Edge/Run/Stream not in scope
--   G5          N/A: combinational
--   G6.Code     fully covered
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

entity tb_a12_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a12_osvvm;

architecture sim of tb_a12_osvvm is

  constant ERROR_WIDTH : natural := BITNESS + 1;
  constant A_WIDTH     : natural := BITNESS + log2ceil(CO_RESET_STD);
  constant B_WIDTH     : natural := BITNESS + 1;
  constant N_WIDTH     : natural := CO_NQ_WIDTH_STD;
  constant RESET       : natural := CO_RESET_STD;

  -- Non-overflowing operating ranges (post-A.9 error, T.87 variable bounds).
  constant ERR_LO : integer := -(2 ** BITNESS / 2);
  constant ERR_HI : integer := 2 ** BITNESS / 2;
  constant A_HI   : integer := (RESET - 1) * 2 ** BITNESS / 2;
  constant B_LIM  : integer := RESET - 1;

  signal sErr  : signed(ERROR_WIDTH - 1 downto 0);
  signal sAq   : unsigned(A_WIDTH - 1 downto 0);
  signal sBq   : signed(B_WIDTH - 1 downto 0);
  signal sNq   : unsigned(N_WIDTH - 1 downto 0);
  signal sAqO  : unsigned(A_WIDTH - 1 downto 0);
  signal sBqO  : signed(B_WIDTH - 1 downto 0);
  signal sNqO  : unsigned(N_WIDTH - 1 downto 0);

begin

  dut : entity work.a12_variables_update(rtl)
    generic map (
      ERROR_WIDTH => ERROR_WIDTH,
      A_WIDTH     => A_WIDTH,
      B_WIDTH     => B_WIDTH,
      N_WIDTH     => N_WIDTH,
      RESET       => RESET
    )
    port map (
      iErrorVal => sErr,
      iAq       => sAq,
      iBq       => sBq,
      iNq       => sNq,
      oAq       => sAqO,
      oBq       => sBqO,
      oNq       => sNqO
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable req     : AlertLogIDType;
    constant N_RAND  : natural := 8000;
    variable mm, st, cl : CoverageIDType;

    procedure drive_check (
      err : integer;
      a   : integer;
      b   : integer;
      n   : integer;
      msg : string
    ) is

      variable rescale : boolean;
      variable aNew    : integer;
      variable bSum    : integer;
      variable bNew    : integer;
      variable nNew    : integer;
      variable rsc     : integer;
      variable bSgn    : integer;

    begin

      sErr <= to_signed(err, ERROR_WIDTH);
      sAq  <= to_unsigned(a, A_WIDTH);
      sBq  <= to_signed(b, B_WIDTH);
      sNq  <= to_unsigned(n, N_WIDTH);
      wait for 1 ns;

      rescale := (n = RESET);
      aNew    := a + abs(err);
      bSum    := b + err;

      if (rescale) then
        aNew := aNew / 2;
        if (bSum >= 0) then
          bNew := bSum / 2;
        else
          bNew := -((1 - bSum) / 2);
        end if;
        nNew := (n / 2) + 1;
      else
        bNew := bSum;
        nNew := n + 1;
      end if;

      AffirmIfEqual(req, checked_integer(sAqO), aNew, msg & " A");
      AffirmIfEqual(req, checked_integer(sBqO), bNew, msg & " B");
      AffirmIfEqual(req, checked_integer(sNqO), nNew, msg & " N");

      if (rescale) then
        rsc := 1;
      else
        rsc := 0;
      end if;
      if (bSum >= 0) then
        bSgn := 0;
      else
        bSgn := 1;
      end if;
      ICover(cov, (rsc, bSgn));
      ICover(mm, (1, err));
      ICover(mm, (2, a));
      ICover(mm, (3, b));
      ICover(mm, (4, n));
      ICover(st, (1, err));
      ICover(st, (2, b));
      ICover(st, (3, n));
      ICover(cl, (1, n));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a12_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A12", 300);

    cov := NewID("G4.Coding rescale x bSumSign");
    SetFieldName(cov, "rescale", "bSumSign");
    for axis0 in 0 to 1 loop
      for axis1 in 0 to 1 loop
        AddCross(cov, "rescale=" & to_string(axis0) & " / " & "bSumSign=" & to_string(axis1), GenBin(axis0), GenBin(axis1));
      end loop;
    end loop;

    -- Directed corners.
    mm := NewID("G2.MinMax node x value");
    add_value_bin(mm, 1, "Errval", ERR_LO);
    add_value_bin(mm, 1, "Errval", ERR_HI);
    add_value_bin(mm, 2, "A", 0);
    add_value_bin(mm, 2, "A", A_HI);
    add_value_bin(mm, 3, "B", -B_LIM);
    add_value_bin(mm, 3, "B", B_LIM);
    add_value_bin(mm, 4, "N", 1);
    add_value_bin(mm, 4, "N", RESET);
    st := NewID("G3.Stim node x value");
    add_value_bin(st, 1, "Errval", ERR_LO);
    add_value_bin(st, 2, "B", -B_LIM);
    add_value_bin(st, 3, "N MSB", 2 ** (N_WIDTH - 1), RESET);
    cl := NewID("G2.Clamp node x value");
    add_value_bin(cl, 1, "N", RESET - 1);
    add_value_bin(cl, 1, "N", RESET);
    drive_check(ERR_LO, 0, -B_LIM, RESET - 1, "min A most negative B");
    drive_check(ERR_HI, A_HI, B_LIM, RESET - 1, "max A max B no rescale");
    drive_check(0, 0, 0, 1, "min no-rescale");
    drive_check(ERR_HI, A_HI, B_LIM, RESET, "rescale pos B");
    drive_check(ERR_LO, A_HI, -B_LIM, RESET, "rescale neg B");
    drive_check(-1, 5, -1, RESET, "rescale neg even B");

    -- Random sweep (N biased to RESET for the rescale path).
    -- Negative odd sums require floor division, not integer truncation.
    for n in RESET - 1 to RESET loop
      for err in -3 to 3 loop
        for b in -3 to 3 loop
          drive_check(err, 5, b, n, "rescale parity and sign boundary");
        end loop;
      end loop;
    end loop;

    for i in 1 to N_RAND loop

      if (rv.RandInt(0, 2) = 0) then
        drive_check(rv.RandInt(ERR_LO, ERR_HI), rv.RandInt(0, A_HI),
                    rv.RandInt(-B_LIM, B_LIM), RESET, "rand rescale");
      else
        drive_check(rv.RandInt(ERR_LO, ERR_HI), rv.RandInt(0, A_HI),
                    rv.RandInt(-B_LIM, B_LIM), rv.RandInt(1, RESET), "rand");
      end if;
      exit when IsCovered(cov) and i > 300;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "rescale x bSign coverage closed");
    affirm_covered(mm, "inputs min/max covered");
    affirm_covered(st, "most negative Errval/B and N MSB covered");
    affirm_covered(cl, "N reset point and one before covered");

    end_of_test("tb_a12_osvvm");
    wait;

  end process stim;

end architecture sim;
