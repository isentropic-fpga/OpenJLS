-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: a19_run_interruption_error (combinational).
--
-- T.87 Code segment A.19 with NEAR=0 (Quantize is identity, Rx=Ix):
--   if (RItype==0 && Ra>Rb) { Errval = -Errval; SIGN = -1; } else SIGN = +1;
--   Errval = ModRange(Errval, RANGE);     -- A.9 inline
-- Reference applies the sign flip then the A.9 modulo reduction. Coverage
-- crosses the sign-flip condition with the upper-half subtract of ModRange.
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

entity tb_a19_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a19_osvvm;

architecture sim of tb_a19_osvvm is

  constant RANGE_P : natural := 2 ** BITNESS;
  constant PX_MAX  : integer := (2 ** BITNESS) - 1;
  constant ERR_LO  : integer := -PX_MAX;
  constant ERR_HI  : integer := PX_MAX;

  signal sErrIn  : signed(BITNESS downto 0);
  signal sRItype : std_logic;
  signal sRaPix     : unsigned(BITNESS - 1 downto 0);
  signal sRbPix     : unsigned(BITNESS - 1 downto 0);
  signal sErrOut : signed(BITNESS downto 0);
  signal sSign   : std_logic;

begin

  dut : entity work.a19_run_interruption_error(behavioral)
    generic map (
      BITNESS => BITNESS,
      RANGE_P => RANGE_P
    )
    port map (
      iErrval => sErrIn,
      iRItype => sRItype,
      iRa     => sRaPix,
      iRb     => sRbPix,
      oErrval => sErrOut,
      oSign   => sSign
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable req     : AlertLogIDType;
    constant N_RAND  : natural := 6000;

    procedure drive_check (
      err : integer;
      ri  : std_logic;
      ra  : integer;
      rb  : integer;
      msg : string
    ) is

      variable flip   : boolean;
      variable e      : integer;
      variable adj    : integer;
      variable result : integer;
      variable eSign  : std_logic;
      variable gh     : integer;
      variable wn     : integer;   -- wrapNeg modulo branch (adj < 0 -> +RANGE)

    begin

      sErrIn  <= to_signed(err, BITNESS + 1);
      sRItype <= ri;
      sRaPix     <= to_unsigned(ra, BITNESS);
      sRbPix     <= to_unsigned(rb, BITNESS);
      wait for 1 ns;

      flip := (ri = '0') and (ra > rb);
      if (flip) then
        e     := -err;
        eSign := CO_SIGN_NEG;
      else
        e     := err;
        eSign := CO_SIGN_POS;
      end if;

      adj := e;
      if (adj < 0) then
        adj := adj + RANGE_P;
        wn  := 1;
      else
        wn := 0;
      end if;
      if (adj >= (RANGE_P + 1) / 2) then
        result := adj - RANGE_P;
        gh     := 1;
      else
        result := adj;
        gh     := 0;
      end if;

      AffirmIfEqual(req, checked_integer(sErrOut), result, msg & " err");
      AffirmIfEqual(req, checked_bit(sSign), std_to_int(eSign), msg & " sign");
      ICover(cov, (std_to_int(eSign), wn, gh));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a19_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A19", 300);
    cov := NewID("sign x wrapNeg x geHalf");
    SetFieldName(cov, "sign", "wrapNeg", "geHalf");
    for axis0 in 0 to 1 loop
      for axis1 in 0 to 1 loop
        for axis2 in 0 to 1 loop
          AddCross(cov, "sign=" & to_string(axis0) & " / " & "wrapNeg=" & to_string(axis1) & " / " & "geHalf=" & to_string(axis2), GenBin(axis0), GenBin(axis1), GenBin(axis2));
        end loop;
      end loop;
    end loop;

    -- Directed corners.
    drive_check(0, '0', 5, 1, "flip err0");           -- flip, e=0
    drive_check(ERR_HI, '0', 5, 1, "flip max");       -- flip large
    drive_check(ERR_LO, '1', 5, 1, "no flip (ri1)");
    drive_check(ERR_HI, '0', 1, 5, "no flip (ra<rb)");

    -- Equality of Ra/Rb must not flip; both sides of each modulo threshold.
    for ri in 0 to 1 loop
      for relation in -1 to 1 loop
        for delta in -1 to 1 loop
          drive_check((RANGE_P + 1) / 2 + delta, bool2bit(ri = 1), 10 + relation, 10, "positive half");
          drive_check(-(RANGE_P / 2) + delta, bool2bit(ri = 1), 10 + relation, 10, "negative half");
          drive_check(delta, bool2bit(ri = 1), 10 + relation, 10, "zero boundary");
        end loop;
      end loop;
    end loop;

    for i in 1 to N_RAND loop

      -- Bias the flip condition (ri=0, Ra>Rb) so both sign bins fill.
      if (rv.RandInt(0, 1) = 0) then
        drive_check(rv.RandInt(ERR_LO, ERR_HI), '0', 100, 50, "rand flip");
      else
        drive_check(rv.RandInt(ERR_LO, ERR_HI),
                    bool2bit(rv.RandInt(0, 1) = 1),
                    rv.RandInt(0, PX_MAX), rv.RandInt(0, PX_MAX), "rand");
      end if;
      exit when IsCovered(cov) and i > 300;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "sign x wrapNeg x geHalf coverage closed");

    end_of_test("tb_a19_osvvm");
    wait;

  end process stim;

end architecture sim;
