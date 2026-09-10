-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: a20_compute_temp (combinational).
--
-- T.87 Code segment A.20 (with Q = RItype+365 supplying Aq/Nq from one read):
--   RItype==0 -> TEMP = A[365] = Aq
--   RItype==1 -> TEMP = A[366] + (N[366] >> 1) = Aq + (Nq >> 1)
-- Coverage closes both RItype paths.
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

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a20_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A20", 50);
    cov := NewID("RItype");
    SetFieldName(cov, "RItype");
    AddBins(cov, "A only", GenBin(0));
    AddBins(cov, "A plus floor N/2", GenBin(1));

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

      -- Keep Aq + Nq/2 within A_WIDTH for the ri1 path.
      if (rv.RandInt(0, 1) = 0) then
        drive_check('0', rv.RandInt(0, A_MAX), rv.RandInt(0, N_MAX), "rand ri0");
      else
        drive_check('1', rv.RandInt(0, A_MAX - N_MAX), rv.RandInt(0, N_MAX), "rand ri1");
      end if;
      exit when IsCovered(cov) and i > 50;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "RItype coverage closed");

    end_of_test("tb_a20_osvvm");
    wait;

  end process stim;

end architecture sim;
