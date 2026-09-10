-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: a6_prediction_correction (combinational).
--
-- T.87 Code segment A.6: Px += C[Q] when SIGN==+1 else Px -= C[Q]; then clamp to
-- [0, MAXVAL]. Coverage crosses the sign with the saturation region (low/in/high).
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

entity tb_a6_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a6_osvvm;

architecture sim of tb_a6_osvvm is

  constant MAX_VAL : natural := 2 ** BITNESS - 1;
  constant CQ_MIN  : integer := CO_MIN_CQ;
  constant CQ_MAX  : integer := CO_MAX_CQ;

  signal sPxIn  : unsigned(BITNESS - 1 downto 0);
  signal sSign  : std_logic;
  signal sCq    : signed(CO_CQ_WIDTH - 1 downto 0);
  signal sPxOut : unsigned(BITNESS - 1 downto 0);

  -- T.87 A.6 reference. region returned for coverage (0 low / 1 in / 2 high).
  function corrected (
    px   : integer;
    sign : std_logic;
    cq   : integer
  ) return integer is

    variable v : integer;

  begin

    if (sign = CO_SIGN_POS) then
      v := px + cq;
    else
      v := px - cq;
    end if;

    if (v > MAX_VAL) then
      return MAX_VAL;
    elsif (v < 0) then
      return 0;
    else
      return v;
    end if;

  end function corrected;

  function region_of (
    px   : integer;
    sign : std_logic;
    cq   : integer
  ) return integer is

    variable v : integer;

  begin

    if (sign = CO_SIGN_POS) then
      v := px + cq;
    else
      v := px - cq;
    end if;

    if (v < 0) then
      return 0;
    elsif (v > MAX_VAL) then
      return 2;
    else
      return 1;
    end if;

  end function region_of;

begin

  dut : entity work.a6_prediction_correction(behavioral)
    generic map (
      BITNESS => BITNESS,
      MAX_VAL => MAX_VAL
    )
    port map (
      iPx   => sPxIn,
      iSign => sSign,
      iCq   => sCq,
      oPx   => sPxOut
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable req     : AlertLogIDType;
    variable boundary : integer;
    constant N_RAND  : natural := 5000;

    procedure drive_check (
      px  : integer;
      sg  : std_logic;
      cq  : integer;
      msg : string
    ) is
    begin

      sPxIn <= to_unsigned(px, BITNESS);
      sSign <= sg;
      sCq   <= to_signed(cq, CO_CQ_WIDTH);
      wait for 1 ns;
      AffirmIfEqual(req, checked_integer(sPxOut), corrected(px, sg, cq),
                    msg & " px=" & integer'image(px) & " cq=" & integer'image(cq));
      ICover(cov, (std_to_int(sg), region_of(px, sg, cq)));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a6_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A6", 300);

    cov := NewID("sign x region");
    SetFieldName(cov, "sign", "region");
    for axis0 in 0 to 1 loop
      for axis1 in 0 to 2 loop
        AddCross(cov, "sign=" & to_string(axis0) & " / " & "region=" & to_string(axis1), GenBin(axis0), GenBin(axis1));
      end loop;
    end loop;

    -- Directed corners.
    drive_check(0, CO_SIGN_POS, CQ_MIN, "low sat pos");
    drive_check(MAX_VAL, CO_SIGN_POS, CQ_MAX, "high sat pos");
    drive_check(MAX_VAL, CO_SIGN_NEG, CQ_MIN, "high sat neg");
    drive_check(0, CO_SIGN_NEG, CQ_MAX, "low sat neg");
    drive_check(MAX_VAL / 2, CO_SIGN_POS, 0, "mid cq0");

    -- Random sweep.
    -- Every bias at both clipping thresholds, both signs, including equality.
    for cq in CQ_MIN to CQ_MAX loop
      for delta in -1 to 1 loop
        for edge in 0 to 1 loop
          boundary := edge * MAX_VAL - cq + delta;
          if boundary >= 0 and boundary <= MAX_VAL then
            drive_check(boundary, CO_SIGN_POS, cq, "clip boundary positive sign");
          end if;
          boundary := edge * MAX_VAL + cq + delta;
          if boundary >= 0 and boundary <= MAX_VAL then
            drive_check(boundary, CO_SIGN_NEG, cq, "clip boundary negative sign");
          end if;
        end loop;
      end loop;
    end loop;

    for i in 1 to N_RAND loop

      if (rv.RandInt(0, 1) = 0) then
        drive_check(rv.RandInt(0, MAX_VAL), CO_SIGN_POS, rv.RandInt(CQ_MIN, CQ_MAX), "rand");
      else
        drive_check(rv.RandInt(0, MAX_VAL), CO_SIGN_NEG, rv.RandInt(CQ_MIN, CQ_MAX), "rand");
      end if;
      exit when IsCovered(cov) and i > 300;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "sign x region coverage closed");

    end_of_test("tb_a6_osvvm");
    wait;

  end process stim;

end architecture sim;
