-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a20_2_osvvm: a20_2_compute_k against the T.87 A.10 loop on the A.20.2 operand
--
-- Aq and TEMP always differ, so a wrong select cannot pass.
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

  -- T.87 A.10; n >= 1 ends the loop by MAX_K
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
    variable mm, st : CoverageIDType;

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
      ICover(mm, (1, n));
      ICover(mm, (2, av));
      ICover(mm, (3, tv));
      ICover(st, (1, n));
      ICover(st, (2, av));
      ICover(st, (3, tv));

    end procedure drive_check;

  begin

    SetAlertLogName("tb_a20_2_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A20.2", 400);

    cov := NewID("G4.Coding mode x k");
    SetFieldName(cov, "RItype", "k");
    for ri in 0 to 1 loop
      AddCross(cov, "mode=" & to_string(ri) & " / k=0", GenBin(ri), GenBin(0));
      AddCross(cov, "mode=" & to_string(ri) & " / k interior", GenBin(ri), GenBin(1));
      AddCross(cov, "mode=" & to_string(ri) & " / k=MAX_K", GenBin(ri), GenBin(2));
    end loop;

    -- The unselected operand sits at the opposite k extreme
    mm := NewID("G2.MinMax node x value");
    add_value_bin(mm, 1, "N", 1);
    add_value_bin(mm, 1, "N", N_MAX);
    add_value_bin(mm, 2, "A", 0);
    add_value_bin(mm, 2, "A", A_MAX);
    add_value_bin(mm, 3, "TEMP", 0);
    add_value_bin(mm, 3, "TEMP", A_MAX);
    st := NewID("G3.Stim node x value");
    add_value_bin(st, 1, "N MSB", 2 ** (N_WIDTH - 1), N_MAX);
    add_value_bin(st, 2, "A MSB", 2 ** (A_WIDTH - 1), A_MAX);
    add_value_bin(st, 3, "TEMP MSB", 2 ** (A_WIDTH - 1), A_MAX);
    drive_check(0, N_MAX, A_MAX, A_MAX, "max N/A/TEMP regular");
    drive_check(1, N_MAX, A_MAX, A_MAX, "max N/A/TEMP RI");
    drive_check(0, 1, 0, A_MAX, "regular k=0, TEMP max");
    drive_check(0, 1, A_MAX, 0, "regular k max, TEMP 0");
    drive_check(1, 1, 0, A_MAX, "RI k max, A 0");
    drive_check(1, 1, A_MAX, 0, "RI k=0, A max");

    -- Every N * 2^k threshold, +-1; the unselected operand is its complement
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
    affirm_covered(mm, "N/A/TEMP min/max covered");
    affirm_covered(st, "N/A/TEMP MSB covered");

    end_of_test("tb_a20_2_osvvm");
    wait;

  end process stim;

end architecture sim;
