-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a10_osvvm: a10_compute_k against the T.87 A.10 loop
--
-- Guidelines:
--   G2.Clamp    N/A: no accumulator
--   G4 other    N/A: Edge/Run/Stream not in scope
--   G5          N/A: combinational

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.log2ceil;

library osvvm;
  context osvvm.OsvvmContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_a10_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a10_osvvm;

architecture sim of tb_a10_osvvm is

  constant A_WIDTH : natural := BITNESS + log2ceil(CO_RESET_STD);
  constant K_WIDTH : natural := log2ceil(BITNESS + log2ceil(CO_RESET_STD) + 1);
  constant N_WIDTH : natural := CO_NQ_WIDTH_STD;
  constant MAX_K   : natural := A_WIDTH;
  constant A_MAX   : integer := (2 ** A_WIDTH) - 1;
  constant N_MAX   : integer := (2 ** N_WIDTH) - 1;

  signal sNq : unsigned(N_WIDTH - 1 downto 0);
  signal sAq : unsigned(A_WIDTH - 1 downto 0);
  signal sHalf : std_logic;
  signal sK  : unsigned(K_WIDTH - 1 downto 0);

  -- T.87 A.10, or A.20.2 TEMP = A + (N >> 1) with add_half; N >= 1 is a T.87 invariant, so the loop ends by MAX_K
  function ref_k (
    n        : integer;
    a        : integer;
    add_half : std_logic
  ) return integer is

    variable k : integer := 0;
    variable t : integer := a;

  begin

    if (add_half = '1') then
      t := a + n / 2;
    end if;

    while (n * (2 ** k) < t and k < MAX_K) loop

      k := k + 1;

    end loop;

    return k;

  end function ref_k;

begin

  dut : entity work.a10_compute_k(behavioral)
    generic map (
      A_WIDTH => A_WIDTH,
      K_WIDTH => K_WIDTH,
      N_WIDTH => N_WIDTH
    )
    port map (
      iNq => sNq,
      iAq => sAq,
      iAddHalfN => sHalf,
      oK  => sK
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable mm, st  : CoverageIDType;
    variable req     : AlertLogIDType;
    constant N_RAND  : natural := 6000;

    procedure drive_one (
      n    : integer;
      a    : integer;
      half : std_logic;
      msg  : string
    ) is
    begin

      sNq   <= to_unsigned(n, N_WIDTH);
      sAq   <= to_unsigned(a, A_WIDTH);
      sHalf <= half;
      wait for 1 ns;
      AffirmIfEqual(req, checked_integer(sK), ref_k(n, a, half),
                    msg & " N=" & integer'image(n) & " A=" & integer'image(a) & " half=" & std_logic'image(half));
      ICover(cov, ref_k(n, a, half));
      ICover(mm, (1, n));
      ICover(mm, (2, a));
      ICover(st, (1, n));
      ICover(st, (2, a));

    end procedure drive_one;

    procedure drive_check (
      n   : integer;
      a   : integer;
      msg : string
    ) is
    begin

      drive_one(n, a, '0', msg);
      -- A + (N >> 1) stays inside the module's no-wrap range
      if (a + n / 2 <= A_MAX) then
        drive_one(n, a, '1', msg);
      end if;

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a10_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name & run_seed);
    req := GetReqID("T87.A10", 16000);

    cov := NewID("G4.Coding kZero");
    SetFieldName(cov, "kZero");
    for k in 0 to MAX_K loop
      AddBins(cov, "k=" & to_string(k), GenBin(k));
    end loop;

    mm := NewID("G2.MinMax node x value");
    add_value_bin(mm, 1, "N", 1);
    add_value_bin(mm, 1, "N", N_MAX);
    add_value_bin(mm, 2, "A", 0);
    add_value_bin(mm, 2, "A", A_MAX);
    st := NewID("G3.Stim node x value");
    add_value_bin(st, 1, "N MSB", 2 ** (N_WIDTH - 1), N_MAX);
    add_value_bin(st, 2, "A MSB", 2 ** (A_WIDTH - 1), A_MAX);
    -- Directed corners
    drive_check(64, 0, "A=0 -> k=0");
    drive_check(1, 1, "N>=A -> k=0");
    drive_check(1, 2, "k=1");
    drive_check(1, A_MAX, "max k");
    drive_check(N_MAX, A_MAX, "big N big A");

    -- Every N * 2^k threshold, +-1
    for n in 1 to N_MAX loop
      for k in 0 to MAX_K loop
        for delta in -1 to 1 loop
          if n * (2 ** k) + delta >= 0 and n * (2 ** k) + delta <= A_MAX then
            drive_check(n, n * (2 ** k) + delta, "k threshold");
          end if;
        end loop;
      end loop;
    end loop;

    -- Nq = 0 is the reset value: no k matches a non-zero A, the "none" code is MAX_K + 1 in K_WIDTH bits
    for a in 1 to 3 loop
      sNq   <= to_unsigned(0, N_WIDTH);
      sAq   <= to_unsigned(a, A_WIDTH);
      sHalf <= '0';
      wait for 1 ns;
      AffirmIfEqual(req, checked_integer(sK), (MAX_K + 1) mod 2 ** K_WIDTH, "N=0 fallback");
    end loop;

    for i in 1 to N_RAND loop

      drive_check(rv.RandInt(1, N_MAX), rv.RandInt(0, A_MAX), "rand");

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "k range coverage closed");
    affirm_covered(mm, "N/A min/max covered");
    affirm_covered(st, "N/A MSB covered");

    end_of_test("tb_a10_osvvm");
    wait;

  end process stim;

end architecture sim;
