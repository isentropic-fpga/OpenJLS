-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: a18_run_interruption_prediction_error (combinational).
--
-- T.87 Code segment A.18: Px = (RItype==1)? Ra : Rb; Errval = Ix - Px.
-- Coverage crosses RItype with the sign of the resulting error.
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

entity tb_a18_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a18_osvvm;

architecture sim of tb_a18_osvvm is

  constant PX_MAX  : integer := (2 ** BITNESS) - 1;

  signal sRItype : std_logic;
  signal sRaPix     : unsigned(BITNESS - 1 downto 0);
  signal sRbPix     : unsigned(BITNESS - 1 downto 0);
  signal sIx     : unsigned(BITNESS - 1 downto 0);
  signal sErrval : signed(BITNESS downto 0);

  function sgn (
    v : integer
  ) return integer is
  begin

    if v < 0 then
      return 1;
    elsif v = 0 then
      return 2;
    else
      return 0;
    end if;

  end function sgn;

begin

  dut : entity work.a18_run_interruption_prediction_error(behavioral)
    generic map (
      BITNESS => BITNESS
    )
    port map (
      iRItype => sRItype,
      iRa     => sRaPix,
      iRb     => sRbPix,
      iIx     => sIx,
      oErrval => sErrval
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable req     : AlertLogIDType;
    constant N_RAND  : natural := 4000;

    procedure drive_check (
      ri  : std_logic;
      ra  : integer;
      rb  : integer;
      ix  : integer;
      msg : string
    ) is

      variable px : integer;
      variable e  : integer;

    begin

      sRItype <= ri;
      sRaPix     <= to_unsigned(ra, BITNESS);
      sRbPix     <= to_unsigned(rb, BITNESS);
      sIx     <= to_unsigned(ix, BITNESS);
      wait for 1 ns;

      if (ri = '1') then
        px := ra;
      else
        px := rb;
      end if;
      e := ix - px;
      AffirmIfEqual(req, checked_integer(sErrval), e, msg);
      ICover(cov, (std_to_int(ri), sgn(e)));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a18_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A18", 200);
    cov := NewID("RItype x errSign");
    SetFieldName(cov, "RItype", "errSign");
    for axis0 in 0 to 1 loop
      for axis1 in 0 to 2 loop
        AddCross(cov, "RItype=" & to_string(axis0) & " / " & "errSign=" & to_string(axis1), GenBin(axis0), GenBin(axis1));
      end loop;
    end loop;

    drive_check('1', 0, PX_MAX, PX_MAX, "ri1 pos");
    drive_check('1', PX_MAX, 0, 0, "ri1 neg");
    drive_check('0', PX_MAX, 0, PX_MAX, "ri0 pos");
    drive_check('0', 0, PX_MAX, 0, "ri0 neg");

    drive_check('0', 1, 0, 0, "RI0 zero error");
    drive_check('1', PX_MAX, 0, PX_MAX, "RI1 zero error");

    for i in 1 to N_RAND loop

      if (rv.RandInt(0, 1) = 0) then
        drive_check('1', rv.RandInt(0, PX_MAX), rv.RandInt(0, PX_MAX), rv.RandInt(0, PX_MAX), "rand ri1");
      else
        drive_check('0', rv.RandInt(0, PX_MAX), rv.RandInt(0, PX_MAX), rv.RandInt(0, PX_MAX), "rand ri0");
      end if;
      exit when IsCovered(cov) and i > 200;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "RItype x errSign coverage closed");

    end_of_test("tb_a18_osvvm");
    wait;

  end process stim;

end architecture sim;
