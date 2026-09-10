-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: a10_compute_k (combinational).
--
-- T.87 Code segment A.10: for(k=0; (N[Q]<<k) < A[Q]; k++). Reference is that
-- loop directly. N>=1 is a T.87 invariant (the counter starts at 1), so the loop
-- always terminates by k = A_WIDTH. Coverage closes k=0, an interior k, and the
-- maximum k.
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
  signal sK  : unsigned(K_WIDTH - 1 downto 0);

  -- T.87 A.10 loop. n >= 1 guarantees termination at k <= MAX_K.
  function ref_k (
    n : integer;
    a : integer
  ) return integer is

    variable k : integer := 0;

  begin

    while (n * (2 ** k) < a and k < MAX_K) loop

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
      oK  => sK
    );

  stim : process is

    variable rv      : RandomPType;
    variable cov     : CoverageIDType;
    variable req     : AlertLogIDType;
    constant N_RAND  : natural := 6000;

    procedure drive_check (
      n   : integer;
      a   : integer;
      msg : string
    ) is
    begin

      sNq <= to_unsigned(n, N_WIDTH);
      sAq <= to_unsigned(a, A_WIDTH);
      wait for 1 ns;
      AffirmIfEqual(req, checked_integer(sK), ref_k(n, a),
                    msg & " N=" & integer'image(n) & " A=" & integer'image(a));
      ICover(cov, ref_k(n, a));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a10_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A10", 400);

    cov := NewID("kZero");
    SetFieldName(cov, "kZero");
    for k in 0 to MAX_K loop
      AddBins(cov, "k=" & to_string(k), GenBin(k));
    end loop;

    -- Directed corners.
    drive_check(64, 0, "A=0 -> k=0");
    drive_check(1, 1, "N>=A -> k=0");
    drive_check(1, 2, "k=1");
    drive_check(1, A_MAX, "max k");
    drive_check(N_MAX, A_MAX, "big N big A");

    -- Random sweep (N >= 1).
    -- Test every representable N*2^k transition, not just three broad k bins.
    for n in 1 to N_MAX loop
      for k in 0 to MAX_K loop
        for delta in -1 to 1 loop
          if n * (2 ** k) + delta >= 0 and n * (2 ** k) + delta <= A_MAX then
            drive_check(n, n * (2 ** k) + delta, "k threshold");
          end if;
        end loop;
      end loop;
    end loop;

    for i in 1 to N_RAND loop

      drive_check(rv.RandInt(1, N_MAX), rv.RandInt(0, A_MAX), "rand");
      exit when IsCovered(cov) and i > 400;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "k range coverage closed");

    end_of_test("tb_a10_osvvm");
    wait;

  end process stim;

end architecture sim;
