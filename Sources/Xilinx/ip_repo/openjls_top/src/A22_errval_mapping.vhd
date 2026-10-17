-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a22_errval_mapping: T.87 A.22, run-interruption Errval to EMErrval

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a22_errval_mapping is
  generic (
    ERROR_WIDTH         : natural := CO_ERROR_VALUE_WIDTH_STD;
    MAPPED_ERRVAL_WIDTH : natural := CO_MAPPED_ERROR_VAL_WIDTH_STD
  );
  port (
    iErrval             : in    signed (ERROR_WIDTH - 1 downto 0);
    iRiType             : in    std_logic;
    iMap                : in    std_logic;
    oEmErrVal           : out   unsigned (MAPPED_ERRVAL_WIDTH - 1 downto 0)
  );
end entity a22_errval_mapping;

architecture behavioral of a22_errval_mapping is

begin

  p_errval_map : process (iErrval, iRiType, iMap) is

    variable vRI       : integer;
    variable vMap      : integer;
    variable vEmErrval : integer;

  begin

    vRI  := std_to_int(iRiType);
    vMap := std_to_int(iMap);

    vEmErrval := 2 * abs(to_integer(iErrval)) - vRI - vMap;

    -- Absorbs delta-cycle transients (iMap trails iErrval by a delta); settled value is >= 0
    if (vEmErrval < 0) then
      vEmErrval := 0;
    end if;

    assert vEmErrval < 2 ** MAPPED_ERRVAL_WIDTH report "a22: EMErrval out of range" severity error;

    oEmErrVal <= to_unsigned(vEmErrval, oEmErrVal'length);

  end process p_errval_map;

end architecture behavioral;
