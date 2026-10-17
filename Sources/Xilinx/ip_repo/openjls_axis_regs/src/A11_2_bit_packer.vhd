-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a11_2_bit_packer: one cycle's raw and Golomb fields packed into one MSB-aligned word
--
-- Layout: [raw][unary zeros]['1'][suffix]; oValidLen counts the top bits in use.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library work;
  use work.olo_base_pkg_math.log2ceil;

entity a11_2_bit_packer is
  generic (
    LIMIT           : natural := CO_LIMIT_STD;
    UNARY_WIDTH     : natural := CO_UNARY_WIDTH_STD;
    SUFFIX_WIDTH    : natural := CO_SUFFIX_WIDTH_STD;
    SUFFIXLEN_WIDTH : natural := CO_SUFFIXLEN_WIDTH_STD;
    OUT_WIDTH       : natural := CO_LIMIT_STD
  );
  port (
    iClk            : in    std_logic;
    iRst            : in    std_logic;
    iStall          : in    std_logic;
    -- Raw bits: A.15 boundary bits, A.16 break residual
    iRawValid       : in    std_logic;
    iRawLen         : in    unsigned(SUFFIXLEN_WIDTH - 1 downto 0);
    iRawVal         : in    unsigned(SUFFIX_WIDTH - 1 downto 0);
    -- Golomb code: regular and RI
    iGolombValid    : in    std_logic;
    iUnaryZeros     : in    unsigned(UNARY_WIDTH - 1 downto 0);
    iSuffixLen      : in    unsigned(SUFFIXLEN_WIDTH - 1 downto 0);
    iSuffixVal      : in    unsigned(SUFFIX_WIDTH - 1 downto 0);
    -- MSB-aligned
    oWord           : out   std_logic_vector(OUT_WIDTH - 1 downto 0);
    oWordValid      : out   std_logic;
    oValidLen       : out   unsigned(log2ceil(OUT_WIDTH + 1) - 1 downto 0)
  );
end entity a11_2_bit_packer;

architecture behavioral of a11_2_bit_packer is

  signal sCombWord  : std_logic_vector(OUT_WIDTH - 1 downto 0);
  signal sCombValid : std_logic;
  signal sCombLen   : unsigned(log2ceil(OUT_WIDTH + 1) - 1 downto 0);

begin

  assert OUT_WIDTH >= LIMIT
    report "A11_2_bit_packer: OUT_WIDTH must be >= LIMIT (per-cycle worst case)"
    severity failure;

  -- Contracts (PSL, simulation only)
  -- psl default clock is rising_edge(iClk);
  -- psl assert always (iRst = '1' -> next (oWordValid = '0')) report "a11_2: reset must clear oWordValid";
  -- psl assert always ((iRst = '0' and iStall = '1' and oWordValid = '1') -> next (oWordValid = '1')) report "a11_2: stall must hold oWordValid asserted";
  -- psl assert always ((iRst = '0' and iStall = '1' and oWordValid = '0') -> next (oWordValid = '0')) report "a11_2: stall must hold oWordValid deasserted";

  comb_proc : process (iRawValid, iRawLen, iRawVal, iGolombValid, iUnaryZeros, iSuffixLen, iSuffixVal) is

    constant GOLOMB_WIDTH : natural := LIMIT;
    variable vWord        : unsigned(OUT_WIDTH - 1 downto 0);
    variable vMarker      : unsigned(GOLOMB_WIDTH - 1 downto 0);
    variable vGolombWord  : unsigned(GOLOMB_WIDTH - 1 downto 0);
    variable vGolombShift : unsigned(OUT_WIDTH - 1 downto 0);
    variable vRawShift    : unsigned(OUT_WIDTH - 1 downto 0);
    variable vRawLen      : natural;
    variable vSufLen      : natural;
    variable vGolombLen   : natural;
    variable vTotal       : natural;

  begin

    vWord   := (others => '0');
    vRawLen := to_integer(iRawLen);
    vSufLen := to_integer(iSuffixLen);
    vTotal  := 0;

    if (iRawValid = '1' and vRawLen > 0) then
      vRawShift := shift_left(resize(iRawVal, OUT_WIDTH), OUT_WIDTH - vRawLen);
      vWord     := vRawShift;
      vTotal    := vRawLen;
    end if;

    if (iGolombValid = '1') then
      vMarker     := shift_left(to_unsigned(1, GOLOMB_WIDTH), vSufLen);
      vGolombWord := vMarker or (resize(iSuffixVal, GOLOMB_WIDTH) and (vMarker - 1));

      vGolombLen   := to_integer(iUnaryZeros) + 1 + vSufLen;
      vGolombShift := shift_left(resize(vGolombWord, OUT_WIDTH), OUT_WIDTH - vTotal - vGolombLen);

      vWord  := vWord or vGolombShift;
      vTotal := vTotal + vGolombLen;
    end if;

    sCombWord  <= std_logic_vector(vWord);
    sCombLen   <= to_unsigned(vTotal, sCombLen'length);
    sCombValid <= iRawValid or iGolombValid;

  end process comb_proc;

  sync_proc : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        oWord      <= (others => '0');
        oWordValid <= '0';
        oValidLen  <= (others => '0');
      elsif (iStall = '0') then
        oWord      <= sCombWord;
        oWordValid <= sCombValid;
        oValidLen  <= sCombLen;
      end if;
    end if;

  end process sync_proc;

end architecture behavioral;
