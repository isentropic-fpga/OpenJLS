-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: a4_quantization_gradients (combinational).
--
-- Reference is the T.87 Code segment A.4 quantiser with NEAR = 0 (Docs/Project.md),
-- using the T.87 default threshold derivation (T1/T2/T3 from FACTOR). The RTL
-- realises this with the absolute-value optimisation; the reference stays on the
-- verbatim signed-branch form so the two are independent.
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

entity tb_a4_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a4_osvvm;

architecture sim of tb_a4_osvvm is

  constant MAX_VAL : natural := 2 ** BITNESS - 1;
  constant D_MIN   : integer := -(2 ** BITNESS);
  constant D_MAX   : integer := (2 ** BITNESS) - 1;

  -- T.87 default threshold derivation (NEAR = 0).
  function clamp (
    i   : integer;
    lo  : integer;
    hi  : integer
  ) return integer is
  begin

    if (i > hi or i < lo) then
      return lo;
    else
      return i;
    end if;

  end function clamp;

  constant FACTOR : integer := (math_min(MAX_VAL, 4095) + 128) / 256;
  constant T1     : integer := clamp(FACTOR * (3 - 2) + 2, 1, MAX_VAL);
  constant T2     : integer := clamp(FACTOR * (7 - 3) + 3, T1, MAX_VAL);
  constant T3     : integer := clamp(FACTOR * (21 - 4) + 4, T2, MAX_VAL);

  -- T.87 A.4 quantiser, verbatim signed branches with NEAR = 0.
  function quantize (
    di : integer
  ) return integer is
  begin

    if (di <= -T3) then
      return -4;
    elsif (di <= -T2) then
      return -3;
    elsif (di <= -T1) then
      return -2;
    elsif (di < 0) then
      return -1;
    elsif (di <= 0) then
      return 0;
    elsif (di < T1) then
      return 1;
    elsif (di < T2) then
      return 2;
    elsif (di < T3) then
      return 3;
    else
      return 4;
    end if;

  end function quantize;

  signal sD1 : signed(BITNESS downto 0);
  signal sD2 : signed(BITNESS downto 0);
  signal sD3 : signed(BITNESS downto 0);
  signal sQ1 : signed(3 downto 0);
  signal sQ2 : signed(3 downto 0);
  signal sQ3 : signed(3 downto 0);

begin

  dut : entity work.a4_quantization_gradients(behavioral)
    generic map (
      BITNESS => BITNESS,
      MAX_VAL => MAX_VAL
    )
    port map (
      iD1 => sD1,
      iD2 => sD2,
      iD3 => sD3,
      oQ1 => sQ1,
      oQ2 => sQ2,
      oQ3 => sQ3
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable req     : AlertLogIDType;
    constant N_RAND  : natural := 6000;

    procedure drive_check (
      d1  : integer;
      d2  : integer;
      d3  : integer;
      msg : string
    ) is
    begin

      sD1 <= to_signed(d1, BITNESS + 1);
      sD2 <= to_signed(d2, BITNESS + 1);
      sD3 <= to_signed(d3, BITNESS + 1);
      wait for 1 ns;
      AffirmIfEqual(req, checked_integer(sQ1), quantize(d1), msg & " Q1 d=" & integer'image(d1));
      AffirmIfEqual(req, checked_integer(sQ2), quantize(d2), msg & " Q2 d=" & integer'image(d2));
      AffirmIfEqual(req, checked_integer(sQ3), quantize(d3), msg & " Q3 d=" & integer'image(d3));
      ICover(cov, (1, quantize(d1)));
      ICover(cov, (2, quantize(d2)));
      ICover(cov, (3, quantize(d3)));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a4_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A4", 200);

    cov := NewID("Qi");
    SetFieldName(cov, "gradient lane", "quantized level");
    for lane in 1 to 3 loop
      for level in -4 to 4 loop
        AddCross(cov, "lane=" & to_string(lane) & " / level=" & to_string(level),
                 GenBin(lane), GenBin(level));
      end loop;
    end loop;

    -- Directed threshold boundaries (both signs).
    drive_check(0, 1, -1, "near-zero");
    drive_check(T1 - 1, T1, T2 - 1, "T1 boundary");
    drive_check(T2, T3 - 1, T3, "T2/T3 boundary");
    drive_check(-T1, -T2, -T3, "neg thresholds");
    drive_check(-(T1 - 1), -(T2 - 1), -(T3 - 1), "just inside neg");
    drive_check(D_MAX, D_MIN, 0, "extremes");

    -- Random sweep.
    -- Each lane sees every gradient; other lanes differ to detect cross-wiring.
    for d in -MAX_VAL to MAX_VAL loop
      drive_check(d, -d, 0, "gradient sweep");
      drive_check(0, d, -d, "gradient sweep rotated");
    end loop;

    for i in 1 to N_RAND loop

      drive_check(rv.RandInt(D_MIN, D_MAX), rv.RandInt(D_MIN, D_MAX), rv.RandInt(D_MIN, D_MAX), "rand");
      exit when IsCovered(cov) and i > 200;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "Qi level coverage closed");

    end_of_test("tb_a4_osvvm");
    wait;

  end process stim;

end architecture sim;
