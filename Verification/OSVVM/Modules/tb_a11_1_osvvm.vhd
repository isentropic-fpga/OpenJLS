-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: a11_1_golomb_encoder (combinational).
--
-- Limited-length Golomb LG(k, L) per T.87 A.5.3 (regular) and A.22.1 (run
-- interruption, glimit = LIMIT - J[RUNindex] - 1). The module emits the code as
-- (unaryZeros, suffixLen, suffixVal) for the bit packer rather than a bit string.
-- Reference is the T.87 written rule (Docs/Project.md A.11.1/A.11.2):
--   high = MErrval >> k
--   non-escape (high < L-qbpp-1): unary=high, len=k,    val = low k bits
--   escape:                       unary=L-qbpp-1, len=qbpp, val = (MErrval-1) low qbpp bits
-- with L = LIMIT (regular) or glimit (RI). Coverage crosses RI-mode x escape.
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

  -- Valid k domain (encoder assumptions: k <= SUFFIX_W and k <= MAPPED_W).
  constant K_HI        : integer := SUFFIX_W;
  constant MERR_MAX    : integer := (2 ** MAPPED_W) - 1;

  signal sK         : unsigned(K_WIDTH - 1 downto 0);
  signal sMerr      : unsigned(MAPPED_W - 1 downto 0);
  signal sRiMode    : std_logic;
  signal sRunIndex  : unsigned(4 downto 0);
  signal sUnary     : unsigned(UNARY_W - 1 downto 0);
  signal sSuffixLen : unsigned(SUFFIXLEN_W - 1 downto 0);
  signal sSuffixVal : unsigned(SUFFIX_W - 1 downto 0);

  -- L - qbpp - 1 escape threshold for the active mode.
  function threshold_of (
    riMode : std_logic;
    runIdx : integer
  ) return integer is
  begin

    if (riMode = '1') then
      -- glimit = LIMIT - J - 1; threshold = glimit - qbpp - 1.
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
    variable covK, covJ : CoverageIDType;
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

      AffirmIfEqual(req, checked_integer(sUnary), expUn, msg & " unary");
      AffirmIfEqual(req, checked_integer(sSuffixLen), expLen, msg & " sufLen");
      AffirmIfEqual(req, checked_integer(sSuffixVal), expVal, msg & " sufVal");

      ICover(cov, (std_to_int(ri), escape));
      ICover(covK, kv);
      if ri = '1' then ICover(covJ, rix); end if;

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a11_1_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A11.1", 400);

    covK := NewID("Golomb k");
    SetFieldName(covK, "k");
    for kval in 0 to K_HI loop
      AddBins(covK, "k=" & to_string(kval), GenBin(kval));
    end loop;
    covJ := NewID("Run interruption J table");
    SetFieldName(covJ, "RUNindex");
    for index in 0 to 31 loop
      AddBins(covJ, "RUNindex=" & to_string(index) & " J=" & to_string(TB_J_TABLE(index)), GenBin(index));
    end loop;
    cov := NewID("riMode x escape");
    SetFieldName(cov, "riMode", "escape");
    for axis0 in 0 to 1 loop
      for axis1 in 0 to 1 loop
        AddCross(cov, "riMode=" & to_string(axis0) & " / " & "escape=" & to_string(axis1), GenBin(axis0), GenBin(axis1));
      end loop;
    end loop;

    -- Directed corners.
    drive_check(0, 0, '0', 0, "reg merr0 k0");           -- non-escape, all minimal
    drive_check(0, MERR_MAX, '0', 0, "reg escape k0");   -- big merr -> escape
    drive_check(K_HI, 1, '0', 0, "reg big-k small");
    drive_check(0, MERR_MAX, '1', 0, "RI escape J=0");
    drive_check(0, MERR_MAX, '1', 31, "RI escape J=max");
    drive_check(2, 5, '1', 10, "RI non-escape");

    -- Random sweep.
    -- Every J entry, both modes, and every supported k at the escape threshold.
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
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covJ), "every J table entry covered");
    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "riMode x escape coverage closed");

    end_of_test("tb_a11_1_osvvm");
    wait;

  end process stim;

end architecture sim;
