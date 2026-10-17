-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a4_quantization_gradients: T.87 A.4, gradient quantization to Q1, Q2, Q3

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a4_quantization_gradients is
  generic (
    BITNESS : natural range 8 to 16 := CO_BITNESS_STD;
    MAX_VAL : natural               := CO_MAX_VAL_STD
  );
  port (
    iD1     : in    signed (BITNESS downto 0);
    iD2     : in    signed (BITNESS downto 0);
    iD3     : in    signed (BITNESS downto 0);
    oQ1     : out   signed (3 downto 0);
    oQ2     : out   signed (3 downto 0);
    oQ3     : out   signed (3 downto 0)
  );
end entity a4_quantization_gradients;

architecture behavioral of a4_quantization_gradients is

  -- T.87 CLAMP: out of range returns j, not maxvalue

  function clamp (
    i        : integer;
    j        : integer;
    maxvalue : integer
  ) return integer is
  begin

    if (i > maxvalue or i < j) then
      return j;
    else
      return i;
    end if;

  end function clamp;

  function quantizate (
    signal di   : signed (BITNESS downto 0);
    constant t1 : natural;
    constant t2 : natural;
    constant t3 : natural
  ) return signed is

    variable qi     : signed (3 downto 0);
    variable vAbsQi : natural;
    variable vSign  : std_logic;

  begin

    vAbsQi := abs(to_integer(di));
    vSign  := di(di'high);

    if (vAbsQi = 0) then
      qi := to_signed(0, qi'length);
    elsif (vAbsQi < t1) then
      qi := to_signed(1, qi'length);
    elsif (vAbsQi < t2) then
      qi := to_signed(2, qi'length);
    elsif (vAbsQi < t3) then
      qi := to_signed(3, qi'length);
    else
      qi := to_signed(4, qi'length);
    end if;

    if (vSign = '1') then
      qi := - qi;
    end if;

    return qi;

  end function quantizate;

  constant BASIC_T1 : natural := 3;
  constant BASIC_T2 : natural := 7;
  constant BASIC_T3 : natural := 21;
  constant FACTOR   : natural := (math_min(MAX_VAL, 4095) + 128) / 256;
  constant T1       : natural := clamp(FACTOR * (BASIC_T1 - 2) + 2, 1, MAX_VAL);
  constant T2       : natural := clamp(FACTOR * (BASIC_T2 - 3) + 3, T1, MAX_VAL);
  constant T3       : natural := clamp(FACTOR * (BASIC_T3 - 4) + 4, T2, MAX_VAL);

begin

  oQ1 <= quantizate(iD1, T1, T2, T3);
  oQ2 <= quantizate(iD2, T1, T2, T3);
  oQ3 <= quantizate(iD3, T1, T2, T3);

  postponed assert is_x(oQ1) or abs(to_integer(oQ1)) <= 4 report "a4: Q1 out of range" severity error;
  postponed assert is_x(oQ2) or abs(to_integer(oQ2)) <= 4 report "a4: Q2 out of range" severity error;
  postponed assert is_x(oQ3) or abs(to_integer(oQ3)) <= 4 report "a4: Q3 out of range" severity error;

end architecture behavioral;
