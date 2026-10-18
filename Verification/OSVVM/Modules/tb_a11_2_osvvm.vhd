-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a11_2_osvvm: a11_2_bit_packer against an independent MSB-first assembler
--
-- Guidelines:
--   G2.Clamp    N/A: no accumulator
--   G3.Stim     N/A: inputs are bit fields and lengths, no signed source
--   G4 other    N/A: Edge/Run/Coding/Stream not in scope

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library work;
  use work.olo_base_pkg_math.log2ceil;

library osvvm;
  context osvvm.OsvvmContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_a11_2_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a11_2_osvvm;

architecture sim of tb_a11_2_osvvm is

  constant LIMIT       : natural := 4 * BITNESS;
  constant UNARY_W     : natural := log2ceil(3 * BITNESS);
  constant SUFFIX_W    : natural := BITNESS + log2ceil(CO_RESET_STD);
  constant SUFFIXLEN_W : natural := math_max(log2ceil(BITNESS + log2ceil(CO_RESET_STD) + 1), 5);
  constant OUT_WIDTH   : natural := 4 * BITNESS;
  constant LEN_W       : natural := log2ceil(OUT_WIDTH + 1);
  constant CLK_PERIOD  : time    := CLK_PERIOD_DEFAULT;

  signal clk         : std_logic := '0';
  signal rst         : std_logic;
  signal iStall      : std_logic;
  signal iRawValid   : std_logic;
  signal iRawLen     : unsigned(SUFFIXLEN_W - 1 downto 0);
  signal iRawVal     : unsigned(SUFFIX_W - 1 downto 0);
  signal iGolombVal  : std_logic;
  signal iUnaryZeros : unsigned(UNARY_W - 1 downto 0);
  signal iSuffixLen  : unsigned(SUFFIXLEN_W - 1 downto 0);
  signal iSuffixVal  : unsigned(SUFFIX_W - 1 downto 0);
  signal oWord       : std_logic_vector(OUT_WIDTH - 1 downto 0);
  signal oWordValid  : std_logic;
  signal oValidLen   : unsigned(LEN_W - 1 downto 0);

  -- [raw][unary zeros]['1'][suffix], MSB first
  procedure assemble (
    rawValid : std_logic;
    rawLen   : natural;
    rawVal   : unsigned;
    gV       : std_logic;
    uz       : natural;
    sl       : natural;
    sv       : unsigned;
    word     : out std_logic_vector(OUT_WIDTH - 1 downto 0);
    total    : out natural
  ) is

    variable w   : std_logic_vector(OUT_WIDTH - 1 downto 0);
    variable idx : integer;
    variable n   : natural;

  begin

    w   := (others => '0');
    idx := OUT_WIDTH - 1;
    n   := 0;

    if (rawValid = '1' and rawLen > 0) then
      for i in rawLen - 1 downto 0 loop

        w(idx) := rawVal(i);
        idx    := idx - 1;

      end loop;
      n := n + rawLen;
    end if;

    if (gV = '1') then
      for i in 1 to uz loop

        w(idx) := '0';
        idx    := idx - 1;

      end loop;
      w(idx) := '1';
      idx    := idx - 1;

      for i in sl - 1 downto 0 loop

        w(idx) := sv(i);
        idx    := idx - 1;

      end loop;
      n := n + uz + 1 + sl;
    end if;

    word  := w;
    total := n;

  end procedure assemble;

begin

  clk_proc : process is
  begin

    clk <= '1';
    wait for CLK_PERIOD / 2;
    clk <= '0';
    wait for CLK_PERIOD / 2;

  end process clk_proc;

  dut : entity work.a11_2_bit_packer(behavioral)
    generic map (
      LIMIT           => LIMIT,
      UNARY_WIDTH     => UNARY_W,
      SUFFIX_WIDTH    => SUFFIX_W,
      SUFFIXLEN_WIDTH => SUFFIXLEN_W,
      OUT_WIDTH       => OUT_WIDTH
    )
    port map (
      iClk         => clk,
      iRst         => rst,
      iStall       => iStall,
      iRawValid    => iRawValid,
      iRawLen      => iRawLen,
      iRawVal      => iRawVal,
      iGolombValid => iGolombVal,
      iUnaryZeros  => iUnaryZeros,
      iSuffixLen   => iSuffixLen,
      iSuffixVal   => iSuffixVal,
      oWord        => oWord,
      oWordValid   => oWordValid,
      oValidLen    => oValidLen
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable req     : AlertLogIDType;
    variable rawLen  : integer;
    variable uz      : integer;
    variable sl      : integer;
    variable rawVal  : unsigned(SUFFIX_W - 1 downto 0);
    variable sufVal  : unsigned(SUFFIX_W - 1 downto 0);
    variable rValid  : std_logic;
    variable gValid  : std_logic;
    constant N_RAND  : natural := 4000;
    variable mm      : CoverageIDType;
    variable rs      : CoverageIDType;

    procedure beat (
      rValid : std_logic;
      rLen   : natural;
      rVal   : unsigned;
      gValid : std_logic;
      uzv    : natural;
      slv    : natural;
      sVal   : unsigned;
      msg    : string
    ) is

      variable expWord : std_logic_vector(OUT_WIDTH - 1 downto 0);
      variable expLen  : natural;
      variable caseT   : integer;

    begin

      iStall      <= '0';
      iRawValid   <= rValid;
      iRawLen     <= to_unsigned(rLen, SUFFIXLEN_W);
      iRawVal     <= rVal;
      iGolombVal  <= gValid;
      iUnaryZeros <= to_unsigned(uzv, UNARY_W);
      iSuffixLen  <= to_unsigned(slv, SUFFIXLEN_W);
      iSuffixVal  <= sVal;

      wait until rising_edge(clk);
      wait for 1 ns;

      assemble(rValid, rLen, rVal, gValid, uzv, slv, sVal, expWord, expLen);
      AffirmIfEqual(req, oWord, expWord, msg & " word");
      AffirmIfEqual(req, checked_integer(oValidLen), expLen, msg & " len");
      AffirmIfEqual(req, checked_bit(oWordValid), std_to_int(rValid or gValid), msg & " valid");

      if (rValid = '1' and gValid = '1') then
        caseT := 3;
      elsif (gValid = '1') then
        caseT := 2;
      elsif (rValid = '1') then
        caseT := 1;
      else
        caseT := 0;
      end if;
      ICover(cov, caseT);
      ICover(mm, (1, expLen));
      if gValid = '1' then
        ICover(mm, (2, uzv));
        ICover(mm, (3, slv));
      end if;
      if rValid = '1' then
        ICover(mm, (4, rLen));
      end if;

    end procedure beat;

    procedure reset_mid (stall : std_logic) is
    begin

      beat('1', 9, to_unsigned(16#1AA#, SUFFIX_W), '1', 4, 6, to_unsigned(16#33#, SUFFIX_W), "pre-reset beat");
      iRawValid  <= '0';
      iGolombVal <= '0';
      iStall     <= stall;  -- reset overrides the stall hold
      ICover(rs, std_to_int(stall));
      apply_reset(clk, rst, 3, '1');
      wait for 1 ns;
      AffirmIf(GetAlertLogID("ResetRecovery"), oWordValid = '0', "mid-op reset: oWordValid cleared");
      AffirmIfEqual(GetAlertLogID("ResetRecovery"), checked_integer(oValidLen), 0, "mid-op reset: oValidLen cleared");
      AffirmIf(GetAlertLogID("ResetRecovery"), oWord = std_logic_vector'(oWord'range => '0'), "mid-op reset: oWord cleared");
      beat('1', 7, to_unsigned(16#5C#, SUFFIX_W), '0', 0, 0, to_unsigned(0, SUFFIX_W), "post-reset recovery");

    end procedure reset_mid;

  begin

    iStall      <= '0';
    iRawValid   <= '0';
    iRawLen     <= (others => '0');
    iRawVal     <= (others => '0');
    iGolombVal  <= '0';
    iUnaryZeros <= (others => '0');
    iSuffixLen  <= (others => '0');
    iSuffixVal  <= (others => '0');

    SetAlertLogName("tb_a11_2_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A11.2", 100);
    cov := NewID("G4.Branch case");
    SetFieldName(cov, "case");
    AddBins(cov, "idle", GenBin(0));
    AddBins(cov, "raw only", GenBin(1));
    AddBins(cov, "Golomb only", GenBin(2));
    AddBins(cov, "raw and Golomb", GenBin(3));

    mm := NewID("G2.MinMax node x value");
    add_value_bin(mm, 1, "ValidLen", 0);
    add_value_bin(mm, 1, "ValidLen", LIMIT);
    add_value_bin(mm, 2, "Unary", 0);
    add_value_bin(mm, 2, "Unary", LIMIT - 1);
    add_value_bin(mm, 3, "SuffixLen", 0);
    add_value_bin(mm, 3, "SuffixLen", SUFFIX_W);
    add_value_bin(mm, 4, "RawLen", 0);
    add_value_bin(mm, 4, "RawLen", math_min(16, SUFFIX_W));
    rs := NewID("G5.States resetPhase");
    AddBins(rs, "output held (stall)", GenBin(1));
    AddBins(rs, "output running", GenBin(0));
    apply_reset(clk, rst, 4, '1');

    wait for 1 ns;
    AffirmIf(GetAlertLogID("ResetRecovery"), oWordValid = '0', "reset: oWordValid cleared");
    AffirmIfEqual(GetAlertLogID("ResetRecovery"), checked_integer(oValidLen), 0, "reset: oValidLen cleared");
    AffirmIf(GetAlertLogID("ResetRecovery"), oWord = std_logic_vector'(oWord'range => '0'), "reset: oWord cleared");

    beat('0', 0, to_unsigned(0, SUFFIX_W), '0', 0, 0, to_unsigned(0, SUFFIX_W), "neither");
    beat('1', 8, to_unsigned(16#A5#, SUFFIX_W), '0', 0, 0, to_unsigned(0, SUFFIX_W), "rawOnly");
    beat('0', 0, to_unsigned(0, SUFFIX_W), '1', 5, 4, to_unsigned(16#B#, SUFFIX_W), "golombOnly");
    beat('1', 6, to_unsigned(16#2D#, SUFFIX_W), '1', 3, 5, to_unsigned(16#15#, SUFFIX_W), "both (RI)");
    -- Escape-shaped: longest unary + qbpp suffix
    beat('0', 0, to_unsigned(0, SUFFIX_W), '1', LIMIT - BITNESS - 1, BITNESS,
         to_unsigned(16#FFF#, SUFFIX_W), "golomb max");

    -- Stall hold ---
    iStall      <= '0';
    iRawValid   <= '1';
    iRawLen     <= to_unsigned(7, SUFFIXLEN_W);
    iRawVal     <= to_unsigned(16#5B#, SUFFIX_W);
    iGolombVal  <= '0';
    wait until rising_edge(clk);
    wait for 1 ns;

    iStall      <= '1';
    iRawValid   <= '1';
    iRawLen     <= to_unsigned(3, SUFFIXLEN_W);
    iRawVal     <= to_unsigned(16#7#, SUFFIX_W);

    for n in 1 to 5 loop

      wait until rising_edge(clk);
      wait for 1 ns;
      AffirmIfEqual(GetAlertLogID("FlowControl"), checked_integer(oValidLen), 7, "stall holds len");
      AffirmIf(GetAlertLogID("FlowControl"), oWordValid = '1', "stall holds valid");
      AffirmIfEqual(GetAlertLogID("FlowControl"), oWord, std_logic_vector(shift_left(to_unsigned(16#5B#, OUT_WIDTH), OUT_WIDTH - 7)),
                    "stall holds complete data word");

    end loop;

    iStall <= '0';
    wait until rising_edge(clk);
    wait for 1 ns;
    AffirmIfEqual(GetAlertLogID("FlowControl"), checked_integer(oValidLen), 3, "post-stall latch len");
    AffirmIfEqual(GetAlertLogID("FlowControl"), oWord, std_logic_vector(shift_left(to_unsigned(7, OUT_WIDTH), OUT_WIDTH - 3)),
                  "post-stall latch data");

    -- Mid-op reset ---
    reset_mid('1');
    reset_mid('0');

    -- Field lengths ---
    -- Every length, exact fill and dirty unused suffix bits
    for rl in 0 to math_min(16, SUFFIX_W) loop
      for suffix in 0 to SUFFIX_W loop
        if rl + 1 + suffix <= LIMIT then
          beat('1', rl, (SUFFIX_W - 1 downto 0 => '1'), '1',
               LIMIT - rl - 1 - suffix, suffix, (SUFFIX_W - 1 downto 0 => '1'), "exact fill");
          beat('1', rl, (SUFFIX_W - 1 downto 0 => '0'), '1',
               0, suffix, (SUFFIX_W - 1 downto 0 => '1'), "short code with dirty suffix");
        end if;
      end loop;
    end loop;

    for i in 1 to N_RAND loop

      rValid := bool2bit(rv.RandInt(0, 1) = 1);
      gValid := bool2bit(rv.RandInt(0, 1) = 1);
      rawLen := rv.RandInt(0, math_min(12, BITNESS));
      uz     := rv.RandInt(0, LIMIT - rawLen - BITNESS - 1);
      sl     := rv.RandInt(0, BITNESS);
      rawVal := rv.RandUnsigned(SUFFIX_W);
      sufVal := rv.RandUnsigned(SUFFIX_W);
      beat(rValid, rawLen, rawVal, gValid, uz, sl, sufVal, "rand");
      exit when IsCovered(cov) and i > 200;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "case coverage closed");
    affirm_covered(mm, "length/unary min/max covered");
    affirm_covered(rs, "reset phase coverage closed");

    end_of_test("tb_a11_2_osvvm");
    wait;

  end process stim;

end architecture sim;
