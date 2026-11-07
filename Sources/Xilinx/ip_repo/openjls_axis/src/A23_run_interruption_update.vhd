-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a23_run_interruption_update: T.87 A.23, run-interruption update of A[Q], N[Q], Nn[Q]

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

-- A.23 A increment, |Errval| - RItype, computed a stage ahead of the A update.
-- In RI, RItype 1 implies Errval /= 0, so one adder covers all four sign/RItype cases.
entity a23_aq_delta is
  generic (
    ERROR_WIDTH : natural
  );
  port (
    iErrVal : in    signed (ERROR_WIDTH - 1 downto 0);
    iRiType : in    std_logic;
    oDelta  : out   unsigned (ERROR_WIDTH - 2 downto 0)
  );
end entity a23_aq_delta;

architecture rtl of a23_aq_delta is

  signal sNeg : std_logic;
  signal sMag : unsigned (ERROR_WIDTH - 2 downto 0);
  signal sDec : unsigned (ERROR_WIDTH - 2 downto 0);
  signal sInc : unsigned (0 downto 0);

begin

  sNeg <= iErrVal(iErrVal'high);
  sMag <= unsigned(iErrVal(ERROR_WIDTH - 2 downto 0)) when sNeg = '0' else
          unsigned(not iErrVal(ERROR_WIDTH - 2 downto 0));
  sDec <= (others => iRiType and not sNeg);
  sInc(0) <= sNeg and not iRiType;

  oDelta <= sMag + sDec + sInc;

end architecture rtl;

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
    -- a23_aq_delta of iErrVal
    iAqDelta    : in    unsigned (ERROR_WIDTH - 2 downto 0);
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

  p_ri_update : process (iErrVal, iAqDelta, iAq, iNq, iNn) is

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

    -- Mert 2018 Fig. 9 form: A[Q] += abs(Errval) - RItype
    vAq := vAq + to_integer(iAqDelta);

    if (vNq = integer(RESET)) then
      vAq := vAq / 2;
      vNq := vNq / 2;
      vNn := vNn / 2;
    end if;

    vNq := vNq + 1;

    assert vAq < 2 ** A_WIDTH report "a23: A out of range" severity error;
    assert iNq > RESET or vNq <= integer(RESET) report "a23: N above RESET" severity error;
    assert vNn < 2 ** NN_WIDTH report "a23: Nn out of range" severity error;

    oAq <= to_unsigned(vAq, oAq'length);
    oNq <= to_unsigned(vNq, oNq'length);
    oNn <= to_unsigned(vNn, oNn'length);

  end process p_ri_update;

end architecture behavioral;
