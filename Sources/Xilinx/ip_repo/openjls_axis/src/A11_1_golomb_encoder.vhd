-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a11_1_golomb_encoder: T.87 A.5.3 text (no code segment), limited-length Golomb code LG(k, LIMIT)

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a11_1_golomb_encoder is
  generic (
    K_WIDTH                : natural := CO_K_WIDTH_STD;
    QBPP                   : natural := CO_QBPP_STD;
    LIMIT                  : natural := CO_LIMIT_STD;
    UNARY_WIDTH            : natural := CO_UNARY_WIDTH_STD;
    SUFFIX_WIDTH           : natural := CO_SUFFIX_WIDTH_STD;
    SUFFIXLEN_WIDTH        : natural := CO_SUFFIXLEN_WIDTH_STD;
    MAPPED_ERROR_VAL_WIDTH : natural := CO_MAPPED_ERROR_VAL_WIDTH_STD
  );
  port (
    iK                     : in    unsigned (K_WIDTH - 1 downto 0);
    iMappedErrorVal        : in    unsigned (MAPPED_ERROR_VAL_WIDTH - 1 downto 0);
    -- iRunIndex: RUNindex before the A.16 decrement, used only when iRiMode = '1'
    iRiMode                : in    std_logic;
    iRunIndex              : in    unsigned (4 downto 0);
    oUnaryZeros            : out   unsigned (UNARY_WIDTH - 1 downto 0);
    oSuffixLen             : out   unsigned (SUFFIXLEN_WIDTH - 1 downto 0);
    oSuffixVal             : out   unsigned (SUFFIX_WIDTH - 1 downto 0)
  );
end entity a11_1_golomb_encoder;

architecture behavioral of a11_1_golomb_encoder is

  constant REG_THRESHOLD : natural := LIMIT - QBPP - 1;

begin

  -- LG(k, L) with L = LIMIT (regular) or glimit = LIMIT - J[RUNindex] - 1 (RI, A.22.1)
  p_golomb_encode : process (iK, iMappedErrorVal, iRiMode, iRunIndex) is

    variable vKInt           : integer;
    variable vHighOrder      : unsigned(iMappedErrorVal'range);
    variable vLowOrder       : unsigned(iMappedErrorVal'range);
    variable vMappedErrorDec : unsigned(iMappedErrorVal'range);
    variable vUnaryZeros     : unsigned(oUnaryZeros'range);
    variable vSuffixLen      : unsigned(oSuffixLen'range);
    variable vIsEscape       : boolean;
    variable vSuffixVal      : unsigned(oSuffixVal'range);
    variable vJ              : natural;
    variable vThreshold      : natural;

  begin

    if (iRiMode = '1') then
      vJ         := CO_J_TABLE(to_integer(iRunIndex));
      vThreshold := LIMIT - vJ - QBPP - 2;
    else
      vThreshold := REG_THRESHOLD;
    end if;

    vKInt      := to_integer(iK);
    vHighOrder := shift_right(iMappedErrorVal, vKInt);
    vLowOrder  := iMappedErrorVal - shift_left(vHighOrder, vKInt);

    vIsEscape := (vHighOrder >= vThreshold);

    if (not vIsEscape) then
      vUnaryZeros := resize(vHighOrder, vUnaryZeros'length);
      vSuffixLen  := resize(iK, vSuffixLen'length);

      vSuffixVal := resize(vLowOrder, vSuffixVal'length);
    else
      assert (iMappedErrorVal /= 0)
        report "LG(k,LIMIT) escape with MErrval=0 is impossible per T.87/14495-1"
        severity failure;

      vUnaryZeros := to_unsigned(vThreshold, vUnaryZeros'length);
      vSuffixLen  := to_unsigned(QBPP, vSuffixLen'length);

      vMappedErrorDec := iMappedErrorVal - 1;

      vSuffixVal                    := (others => '0');
      vSuffixVal(QBPP - 1 downto 0) := vMappedErrorDec(QBPP - 1 downto 0);
    end if;

    oUnaryZeros <= vUnaryZeros;
    oSuffixLen  <= vSuffixLen;
    oSuffixVal  <= vSuffixVal;

  end process p_golomb_encode;

end architecture behavioral;
