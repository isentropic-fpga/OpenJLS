-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- Check the combined datapath against sequential integer A.6 then A.7.
-- Sweep every bias and both signs around both clipping thresholds, and
-- exhaust every uncorrected 8-bit prediction. Larger widths add random cases.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library osvvm;
  context osvvm.OsvvmContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_a6_a7_osvvm is
  generic (
    BITNESS : natural range 8 to 16 := CO_BITNESS_STD;
    MAX_VAL : natural := 2 ** BITNESS - 1
  );
end entity tb_a6_a7_osvvm;

architecture sim of tb_a6_a7_osvvm is
  constant PIXEL_MAX : natural := 2 ** BITNESS - 1;
  signal sIx, sPx : unsigned(BITNESS - 1 downto 0);
  signal sSign : std_logic;
  signal sCq : signed(CO_CQ_WIDTH - 1 downto 0);
  signal sError : signed(BITNESS downto 0);
begin
  dut : entity work.a6_a7_prediction_error(behavioral)
    generic map (BITNESS => BITNESS, MAX_VAL => MAX_VAL)
    port map (iIx => sIx, iPx => sPx, iSign => sSign, iCq => sCq, oErrorVal => sError);

  stimulus : process is
    variable rv : RandomPType;
    variable cov : CoverageIDType;
    variable sign_value : std_logic;
    variable lower_edge, upper_edge : integer;

    procedure check(ix, px, cq : integer; sign_bit : std_logic) is
      variable corrected, expected, region, sign_index : integer;
    begin
      if px < 0 or px > PIXEL_MAX or ix < 0 or ix > PIXEL_MAX then
        return;
      end if;
      -- Reference follows the original algorithm's order, not the fused
      -- difference-minus-bias expression used by the new hardware.
      if sign_bit = CO_SIGN_POS then
        corrected := px + cq;
        sign_index := 0;
      else
        corrected := px - cq;
        sign_index := 1;
      end if;
      region := 1;
      if corrected < 0 then
        corrected := 0;
        region := 0;
      elsif corrected > MAX_VAL then
        corrected := MAX_VAL;
        region := 2;
      end if;
      expected := ix - corrected;
      if sign_bit /= CO_SIGN_POS then
        expected := -expected;
      end if;
      sIx <= to_unsigned(ix, sIx'length);
      sPx <= to_unsigned(px, sPx'length);
      sCq <= to_signed(cq, sCq'length);
      sSign <= sign_bit;
      wait for 1 ns;
      AffirmIfEqual(to_integer(sError), expected, "A.6/A.7 sequential reference");
      assert to_integer(sError) = expected
        report "Ix=" & integer'image(ix) & " Px=" & integer'image(px) &
               " Cq=" & integer'image(cq) & " sign=" & std_logic'image(sign_bit)
        severity failure;
      ICover(cov, (sign_index, region));
    end procedure;

    procedure check_prediction(px, cq : integer; sign_bit : std_logic) is
      variable corrected : integer;
    begin
      if px < 0 or px > PIXEL_MAX then
        return;
      end if;
      if sign_bit = CO_SIGN_POS then
        corrected := px + cq;
      else
        corrected := px - cq;
      end if;
      corrected := math_max(0, math_min(MAX_VAL, corrected));
      check(0, px, cq, sign_bit);
      check(1, px, cq, sign_bit);
      check(PIXEL_MAX / 2, px, cq, sign_bit);
      check(PIXEL_MAX - 1, px, cq, sign_bit);
      check(PIXEL_MAX, px, cq, sign_bit);
      check(px, px, cq, sign_bit);
      check(corrected - 1, px, cq, sign_bit);
      check(corrected, px, cq, sign_bit);
      check(corrected + 1, px, cq, sign_bit);
    end procedure;
  begin
    SetAlertLogName("tb_a6_a7_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    cov := NewID("sign x clipping region");
    AddCross(cov, "sign x clipping region", GenBin(0, 1, 2), GenBin(0, 2, 3));

    for cq in CO_MIN_CQ to CO_MAX_CQ loop
      for sign_index in 0 to 1 loop
        if sign_index = 0 then
          sign_value := CO_SIGN_POS;
          lower_edge := -cq;
          upper_edge := MAX_VAL - cq;
        else
          sign_value := CO_SIGN_NEG;
          lower_edge := cq;
          upper_edge := MAX_VAL + cq;
        end if;
        if BITNESS = 8 then
          for px in 0 to PIXEL_MAX loop
            check_prediction(px, cq, sign_value);
          end loop;
        else
          for delta in -1 to 1 loop
            check_prediction(lower_edge + delta, cq, sign_value);
            check_prediction(upper_edge + delta, cq, sign_value);
          end loop;
          check_prediction(0, cq, sign_value);
          check_prediction(1, cq, sign_value);
          check_prediction(PIXEL_MAX / 2, cq, sign_value);
          check_prediction(PIXEL_MAX - 1, cq, sign_value);
          check_prediction(PIXEL_MAX, cq, sign_value);
        end if;
      end loop;
    end loop;

    for trial in 1 to 20000 loop
      if rv.RandInt(0, 1) = 0 then
        sign_value := CO_SIGN_POS;
      else
        sign_value := CO_SIGN_NEG;
      end if;
      check(rv.RandInt(0, PIXEL_MAX), rv.RandInt(0, PIXEL_MAX),
            rv.RandInt(CO_MIN_CQ, CO_MAX_CQ), sign_value);
    end loop;
    WriteBin(cov);
    AffirmIf(IsCovered(cov), "both signs and all clipping regions covered");
    end_of_test("tb_a6_a7_osvvm");
    wait;
  end process;
end architecture sim;
