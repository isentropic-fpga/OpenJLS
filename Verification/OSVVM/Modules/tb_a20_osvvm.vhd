-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a20_osvvm: a20_compute_temp against the T.87 A.20 C code
--
-- Guidelines:
--   G1.Req      T87.A20
--   G1.Golden   A.20 C code as an integer reference
--   G2.Range    RTL A20_compute_temp.vhd (range comments + postponed asserts)
--   G2.MinMax   G2.MinMax node x value
--   G2.Clamp    N/A: no accumulator
--   G2.Checked  checked_* on all outputs
--   G3.Stim     G3.Stim node x value
--   G4.Run      G4.Run RItype
--   G4.Config   BITNESS 8/16 variants (OpenJls.pro)
--   G4 other    N/A: Edge/Coding/Stream not in scope
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

entity tb_a20_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a20_osvvm;

architecture sim of tb_a20_osvvm is

  constant A_WIDTH : natural := BITNESS + log2ceil(CO_RESET_STD);
  constant N_WIDTH : natural := CO_NQ_WIDTH_STD;
  constant A_MAX   : integer := (2 ** A_WIDTH) - 1;
  constant N_MAX   : integer := (2 ** N_WIDTH) - 1;

  signal sRItype : std_logic;
  signal sAq     : unsigned(A_WIDTH - 1 downto 0);
  signal sNq     : unsigned(N_WIDTH - 1 downto 0);
  signal sTemp   : unsigned(A_WIDTH - 1 downto 0);

begin

  dut : entity work.a20_compute_temp(behavioral)
    generic map (
      A_WIDTH => A_WIDTH,
      N_WIDTH => N_WIDTH
    )
    port map (
      iRItype => sRItype,
      iAq     => sAq,
      iNq     => sNq,
      oTemp   => sTemp
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable req     : AlertLogIDType;
    constant N_RAND  : natural := 3000;
    variable mm, st  : CoverageIDType;

    procedure drive_check (
      ri  : std_logic;
      a   : integer;
      n   : integer;
      msg : string
    ) is

      variable e : integer;

    begin

      sRItype <= ri;
      sAq     <= to_unsigned(a, A_WIDTH);
      sNq     <= to_unsigned(n, N_WIDTH);
      wait for 1 ns;

      if (ri = '0') then
        e := a;
      else
        e := a + (n / 2);
      end if;
      AffirmIfEqual(req, checked_integer(sTemp), e, msg & " a=" & integer'image(a) & " n=" & integer'image(n));
      ICover(cov, std_to_int(ri));
      ICover(mm, (1, a));
      ICover(mm, (2, n));
      ICover(mm, (3, e));
      ICover(st, (1, a));
      ICover(st, (2, n));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a20_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A20", 50);
    cov := NewID("G4.Run RItype");
    SetFieldName(cov, "RItype");
    AddBins(cov, "A only", GenBin(0));
    AddBins(cov, "A plus floor N/2", GenBin(1));

    mm := NewID("G2.MinMax node x value");
    add_value_bin(mm, 1, "A", 0);
    add_value_bin(mm, 1, "A", A_MAX);
    add_value_bin(mm, 2, "N", 0);
    add_value_bin(mm, 2, "N", N_MAX);
    add_value_bin(mm, 3, "TEMP", 0);
    add_value_bin(mm, 3, "TEMP", A_MAX);
    st := NewID("G3.Stim node x value");
    add_value_bin(st, 1, "A MSB", 2 ** (A_WIDTH - 1), A_MAX);
    add_value_bin(st, 2, "N MSB", 2 ** (N_WIDTH - 1), N_MAX);
    drive_check('0', 0, 0, "ri0 zero");
    drive_check('0', A_MAX, N_MAX, "ri0 max (N unused)");
    drive_check('1', 0, N_MAX, "ri1 odd N");
    drive_check('1', A_MAX - N_MAX / 2, N_MAX, "ri1 near-max");

    for n in 0 to N_MAX loop
      drive_check('0', A_MAX, n, "N ignored");
      drive_check('1', 0, n, "N parity");
      drive_check('1', A_MAX - n / 2, n, "largest nonoverflowing sum");
    end loop;

    for i in 1 to N_RAND loop

      -- Keep Aq + Nq/2 within A_WIDTH
      if (rv.RandInt(0, 1) = 0) then
        drive_check('0', rv.RandInt(0, A_MAX), rv.RandInt(0, N_MAX), "rand ri0");
      else
        drive_check('1', rv.RandInt(0, A_MAX - N_MAX), rv.RandInt(0, N_MAX), "rand ri1");
      end if;
      exit when IsCovered(cov) and i > 50;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "RItype coverage closed");
    affirm_covered(mm, "A/N/TEMP min/max covered");
    affirm_covered(st, "A/N MSB covered");

    end_of_test("tb_a20_osvvm");
    wait;

  end process stim;

end architecture sim;
