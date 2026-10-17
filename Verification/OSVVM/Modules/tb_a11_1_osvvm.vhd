-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a11_1_osvvm: a11_1_golomb_encoder against the T.87 LG(k, L) written rule
--
-- Guidelines:
--   G1.Req      T87.A11.1, T87.A22.1
--   G1.Property A.11.1/A.22.1 LG(k, L) written rule
--   G2.Range    RTL A11_1_golomb_encoder.vhd (range comments + postponed asserts)
--   G2.MinMax   G2.MinMax node x value
--   G2.Clamp    N/A: no accumulator
--   G2.Checked  checked_* on all outputs
--   G3.Stim     G3.Stim node x value
--   G4.Coding   G4.Coding Golomb k, G4.Coding riMode x escape
--   G4.Run      G4.Run Run interruption J table
--   G4.Config   BITNESS 8/16 variants (OpenJls.pro)
--   G4 other    N/A: Edge/Stream not in scope
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

entity tb_a11_1_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a11_1_osvvm;

architecture sim of tb_a11_1_osvvm is

  constant K_WIDTH     : natural := log2ceil(BITNESS + log2ceil(CO_RESET_STD) + 1);
  constant QBPP        : natural := BITNESS;
  constant LIMIT       : natural := 4 * BITNESS;
  constant UNARY_W     : natural := log2ceil(3 * BITNESS);
  constant SUFFIX_W    : natural := BITNESS + log2ceil(CO_RESET_STD);
  constant SUFFIXLEN_W : natural := math_max(log2ceil(BITNESS + log2ceil(CO_RESET_STD) + 1), 5);
  constant MAPPED_W    : natural := BITNESS + 2;

  -- Valid k: 0 to SUFFIX_W
  constant K_HI        : integer := SUFFIX_W;
  constant MERR_MAX    : integer := (2 ** MAPPED_W) - 1;

  signal sK         : unsigned(K_WIDTH - 1 downto 0);
  signal sMerr      : unsigned(MAPPED_W - 1 downto 0);
  signal sRiMode    : std_logic;
  signal sRunIndex  : unsigned(4 downto 0);
  signal sUnary     : unsigned(UNARY_W - 1 downto 0);
  signal sSuffixLen : unsigned(SUFFIXLEN_W - 1 downto 0);
  signal sSuffixVal : unsigned(SUFFIX_W - 1 downto 0);

  -- Escape threshold L - qbpp - 1
  function threshold_of (
    riMode : std_logic;
    runIdx : integer
  ) return integer is
  begin

    if (riMode = '1') then
      -- L = glimit = LIMIT - J - 1
      return LIMIT - TB_J_TABLE(runIdx) - QBPP - 2;
    else
      return LIMIT - QBPP - 1;
    end if;

  end function threshold_of;

begin

  dut : entity work.a11_1_golomb_encoder(behavioral)
    generic map (
      K_WIDTH                => K_WIDTH,
      QBPP                   => QBPP,
      LIMIT                  => LIMIT,
      UNARY_WIDTH            => UNARY_W,
      SUFFIX_WIDTH           => SUFFIX_W,
      SUFFIXLEN_WIDTH        => SUFFIXLEN_W,
      MAPPED_ERROR_VAL_WIDTH => MAPPED_W
    )
    port map (
      iK              => sK,
      iMappedErrorVal => sMerr,
      iRiMode         => sRiMode,
      iRunIndex       => sRunIndex,
      oUnaryZeros     => sUnary,
      oSuffixLen      => sSuffixLen,
      oSuffixVal      => sSuffixVal
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable req     : AlertLogIDType;
    variable reqRi   : AlertLogIDType;
    variable reqSel  : AlertLogIDType;
    variable covK, covJ : CoverageIDType;
    variable mm, st  : CoverageIDType;
    variable k       : integer;
    variable merr    : integer;
    variable ridx    : integer;
    constant N_RAND  : natural := 12000;

    procedure drive_check (
      kv   : integer;
      mv   : integer;
      ri   : std_logic;
      rix  : integer;
      msg  : string
    ) is

      variable thr     : integer;
      variable high    : integer;
      variable low     : integer;
      variable expUn   : integer;
      variable expLen  : integer;
      variable expVal  : integer;
      variable escape  : integer;

    begin

      sK        <= to_unsigned(kv, K_WIDTH);
      sMerr     <= to_unsigned(mv, MAPPED_W);
      sRiMode   <= ri;
      sRunIndex <= to_unsigned(rix, 5);
      wait for 1 ns;

      thr  := threshold_of(ri, rix);
      high := mv / (2 ** kv);
      low  := mv mod (2 ** kv);

      if (high < thr) then
        expUn  := high;
        expLen := kv;
        expVal := low;
        escape := 0;
      else
        expUn  := thr;
        expLen := QBPP;
        expVal := (mv - 1) mod (2 ** QBPP);
        escape := 1;
      end if;

      if ri = '1' then
        reqSel := reqRi;
      else
        reqSel := req;
      end if;
      AffirmIfEqual(reqSel, checked_integer(sUnary), expUn, msg & " unary");
      AffirmIfEqual(reqSel, checked_integer(sSuffixLen), expLen, msg & " sufLen");
      AffirmIfEqual(reqSel, checked_integer(sSuffixVal), expVal, msg & " sufVal");

      ICover(cov, (std_to_int(ri), escape));
      ICover(covK, kv);
      ICover(mm, (1, mv));
      ICover(mm, (2, expUn));
      ICover(mm, (3, expLen));
      ICover(st, (1, mv));
      ICover(st, (2, rix));
      if ri = '1' then ICover(covJ, rix); end if;

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a11_1_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req   := GetReqID("T87.A11.1", 400);
    -- 32 RUNindex x 2 suffix cases x 3 fields
    reqRi := GetReqID("T87.A22.1", 192);

    covK := NewID("G4.Coding Golomb k");
    SetFieldName(covK, "k");
    for kval in 0 to K_HI loop
      AddBins(covK, "k=" & to_string(kval), GenBin(kval));
    end loop;
    covJ := NewID("G4.Run Run interruption J table");
    SetFieldName(covJ, "RUNindex");
    for index in 0 to 31 loop
      AddBins(covJ, "RUNindex=" & to_string(index) & " J=" & to_string(TB_J_TABLE(index)), GenBin(index));
    end loop;
    cov := NewID("G4.Coding riMode x escape");
    SetFieldName(cov, "riMode", "escape");
    for axis0 in 0 to 1 loop
      for axis1 in 0 to 1 loop
        AddCross(cov, "riMode=" & to_string(axis0) & " / " & "escape=" & to_string(axis1), GenBin(axis0), GenBin(axis1));
      end loop;
    end loop;

    mm := NewID("G2.MinMax node x value");
    add_value_bin(mm, 1, "MErrval", 0);
    add_value_bin(mm, 1, "MErrval", MERR_MAX);
    add_value_bin(mm, 2, "Unary", 0);
    add_value_bin(mm, 2, "Unary", LIMIT - QBPP - 1);
    add_value_bin(mm, 3, "SuffixLen", 0);
    add_value_bin(mm, 3, "SuffixLen", K_HI);
    st := NewID("G3.Stim node x value");
    add_value_bin(st, 1, "MErrval MSB", 2 ** (MAPPED_W - 1), MERR_MAX);
    add_value_bin(st, 2, "RUNindex MSB", 16, 31);
    drive_check(0, 0, '0', 0, "reg merr0 k0");
    drive_check(0, MERR_MAX, '0', 0, "reg escape k0");
    drive_check(K_HI, 1, '0', 0, "reg big-k small");
    drive_check(0, MERR_MAX, '1', 0, "RI escape J=0");
    drive_check(0, MERR_MAX, '1', 31, "RI escape J=max");
    drive_check(2, 5, '1', 10, "RI non-escape");

    -- Every J entry, both modes, every k at the escape threshold +-1
    for ri in 0 to 1 loop
      for rix in 0 to 31 loop
        for kv in 0 to SUFFIX_W loop
          drive_check(kv, 0, bool2bit(ri = 1), rix, "zero suffix");
          drive_check(kv, MERR_MAX, bool2bit(ri = 1), rix, "maximum suffix");
          for delta in -1 to 1 loop
            merr := threshold_of(bool2bit(ri = 1), rix) * (2 ** kv) + delta;
            if merr >= 0 and merr <= MERR_MAX then
              drive_check(kv, merr, bool2bit(ri = 1), rix, "escape threshold");
            end if;
          end loop;
        end loop;
      end loop;
    end loop;

    for i in 1 to N_RAND loop

      k    := rv.RandInt(0, K_HI);
      merr := rv.RandInt(0, MERR_MAX);
      ridx := rv.RandInt(0, 31);
      if (rv.RandInt(0, 1) = 0) then
        drive_check(k, merr, '0', ridx, "rand reg");
      else
        drive_check(k, merr, '1', ridx, "rand RI");
      end if;
      exit when IsCovered(cov) and i > 400;

    end loop;

    WriteBin(covK);
    WriteBin(covJ);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covK), "every supported k covered");
    affirm_covered(mm, "MErrval/unary/suffix length min/max covered");
    affirm_covered(st, "MErrval/RUNindex MSB covered");
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covJ), "every J table entry covered");
    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "riMode x escape coverage closed");

    end_of_test("tb_a11_1_osvvm");
    wait;

  end process stim;

end architecture sim;
