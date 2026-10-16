-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: a20_2_compute_k (combinational).
--
-- T.87 written requirement A.20.2: in run interruption, k follows A.10 with
-- TEMP in place of A[Q]; in regular mode A.10 runs on A[Q]. The reference is
-- the A.10 loop on the mode-selected operand. Aq and TEMP are always driven
-- with different values so a wrong select cannot pass. Coverage crosses mode
-- with k at zero, interior and maximum.
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

entity tb_a20_2_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a20_2_osvvm;

architecture sim of tb_a20_2_osvvm is

  constant A_WIDTH : natural := BITNESS + log2ceil(CO_RESET_STD);
  constant K_WIDTH : natural := log2ceil(BITNESS + log2ceil(CO_RESET_STD) + 1);
  constant N_WIDTH : natural := CO_NQ_WIDTH_STD;
  constant MAX_K   : natural := A_WIDTH;
  constant A_MAX   : integer := (2 ** A_WIDTH) - 1;
  constant N_MAX   : integer := (2 ** N_WIDTH) - 1;

  signal sRi   : std_logic;
  signal sAq   : unsigned(A_WIDTH - 1 downto 0);
  signal sTemp : unsigned(A_WIDTH - 1 downto 0);
  signal sNq   : unsigned(N_WIDTH - 1 downto 0);
  signal sK    : unsigned(K_WIDTH - 1 downto 0);

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

  function k_class (
    k : integer
  ) return integer is
  begin

    if (k = 0) then
      return 0;
    elsif (k = MAX_K) then
      return 2;
    else
      return 1;
    end if;

  end function k_class;

begin

  dut : entity work.a20_2_compute_k(behavioral)
    generic map (
      A_WIDTH => A_WIDTH,
      K_WIDTH => K_WIDTH,
      N_WIDTH => N_WIDTH
    )
    port map (
      iRunInterruption => sRi,
      iAq              => sAq,
      iTemp            => sTemp,
      iNq              => sNq,
      oK               => sK
    );

  stim : process is

    variable rv     : RandomPType;
    variable cov    : CoverageIDType;
    variable req    : AlertLogIDType;
    variable a      : integer;
    variable t      : integer;
    constant N_RAND : natural := 6000;

    procedure drive_check (
      ri  : integer;
      n   : integer;
      av  : integer;
      tv  : integer;
      msg : string
    ) is

      variable e : integer;

    begin

      sRi   <= bool2bit(ri = 1);
      sNq   <= to_unsigned(n, N_WIDTH);
      sAq   <= to_unsigned(av, A_WIDTH);
      sTemp <= to_unsigned(tv, A_WIDTH);
      wait for 1 ns;
      if (ri = 1) then
        e := ref_k(n, tv);
      else
        e := ref_k(n, av);
      end if;
      AffirmIfEqual(req, checked_integer(sK), e,
                    msg & " RI=" & integer'image(ri) & " N=" & integer'image(n) &
                    " A=" & integer'image(av) & " TEMP=" & integer'image(tv));
      ICover(cov, (ri, k_class(e)));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a20_2_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A20.2", 400);

    cov := NewID("mode x k");
    SetFieldName(cov, "RItype", "k");
    for ri in 0 to 1 loop
      AddCross(cov, "mode=" & to_string(ri) & " / k=0", GenBin(ri), GenBin(0));
      AddCross(cov, "mode=" & to_string(ri) & " / k interior", GenBin(ri), GenBin(1));
      AddCross(cov, "mode=" & to_string(ri) & " / k=MAX_K", GenBin(ri), GenBin(2));
    end loop;

    -- Directed: the unselected operand sits at the opposite k extreme.
    drive_check(0, 1, 0, A_MAX, "regular k=0, TEMP max");
    drive_check(0, 1, A_MAX, 0, "regular k max, TEMP 0");
    drive_check(1, 1, 0, A_MAX, "RI k max, A 0");
    drive_check(1, 1, A_MAX, 0, "RI k=0, A max");

    -- Every N*2^k +-1 threshold on the selected operand; the other side is
    -- its bitwise complement so the two k values differ.
    for ri in 0 to 1 loop
      for n in 1 to N_MAX loop
        for k in 0 to MAX_K loop
          for delta in -1 to 1 loop
            a := n * (2 ** k) + delta;
            if a >= 0 and a <= A_MAX then
              if ri = 1 then
                drive_check(ri, n, A_MAX - a, a, "TEMP threshold");
              else
                drive_check(ri, n, a, A_MAX - a, "A threshold");
              end if;
            end if;
          end loop;
        end loop;
      end loop;
    end loop;

    for i in 1 to N_RAND loop

      a := rv.RandInt(0, A_MAX);
      t := rv.RandInt(0, A_MAX);
      drive_check(rv.RandInt(0, 1), rv.RandInt(1, N_MAX), a, t, "rand");
      exit when IsCovered(cov) and i > 400;

    end loop;

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "mode x k coverage closed");

    end_of_test("tb_a20_2_osvvm");
    wait;

  end process stim;

end architecture sim;
