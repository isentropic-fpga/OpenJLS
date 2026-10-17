-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

----------------------------------------------------------------------------------
-- Engineer:    Vitor Mendes Camilo
--
-- Module Name: A23_run_interruption_update - Behavioral
--
-- Description:                         Code segment A.23
--                                      Update of variables for run interruption sample
--
----------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a23_run_interruption_update is
  generic (
    A_WIDTH     : natural := CO_AQ_WIDTH_STD;
    N_WIDTH     : natural := CO_NQ_WIDTH_STD;
    NN_WIDTH    : natural := CO_NNQ_WIDTH_STD;
    ERROR_WIDTH : natural := CO_ERROR_VALUE_WIDTH_STD;
    RESET       : natural := CO_RESET_STD
  );
  port (
    iErrVal     : in    signed (ERROR_WIDTH - 1 downto 0);
    iRiType     : in    std_logic;
    iAq         : in    unsigned (A_WIDTH - 1 downto 0);
    iNq         : in    unsigned (N_WIDTH - 1 downto 0);
    iNn         : in    unsigned (NN_WIDTH - 1 downto 0);
    oAq         : out   unsigned (A_WIDTH - 1 downto 0);
    oNq         : out   unsigned (N_WIDTH - 1 downto 0);
    oNn         : out   unsigned (NN_WIDTH - 1 downto 0)
  );
end entity a23_run_interruption_update;

architecture behavioral of a23_run_interruption_update is

begin

  p_ri_update : process (iErrVal, iRiType, iAq, iNq, iNn) is

    variable vAq : integer;
    variable vNq : integer;
    variable vNn : integer;

  begin

    vAq := to_integer(iAq);
    vNq := to_integer(iNq);
    vNn := to_integer(iNn);

    if (iErrVal < 0) then
      vNn := vNn + 1;
    end if;

    -- Mert 2018 Fig. 9 equivalence: A[Q] += abs(Errval) - RItype
    vAq := vAq + abs(to_integer(iErrVal)) - std_to_int(iRiType);

    if (vNq = integer(RESET)) then
      vAq := vAq / 2;
      vNq := vNq / 2;
      vNn := vNn / 2;
    end if;

    vNq := vNq + 1;

    -- A in [0, 2^A_WIDTH - 1]; N in [1, RESET]; Nn in [0, 2^NN_WIDTH - 1]
    assert vAq < 2 ** A_WIDTH report "a23: A out of range" severity error;
    assert iNq > RESET or vNq <= integer(RESET) report "a23: N above RESET" severity error;
    assert vNn < 2 ** NN_WIDTH report "a23: Nn out of range" severity error;

    oAq <= to_unsigned(vAq, oAq'length);
    oNq <= to_unsigned(vNq, oNq'length);
    oNn <= to_unsigned(vNn, oNn'length);

  end process p_ri_update;

end architecture behavioral;
