-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a13_update_bias: T.87 A.13, bias update of B[Q] and C[Q]

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a13_update_bias is
  generic (
    B_WIDTH : natural := CO_BQ_WIDTH_STD;
    N_WIDTH : natural := CO_NQ_WIDTH_STD;
    C_WIDTH : natural := CO_CQ_WIDTH;
    MIN_C   : integer := CO_MIN_CQ;
    MAX_C   : integer := CO_MAX_CQ
  );
  port (
    iBq     : in    signed (B_WIDTH - 1 downto 0);
    iNq     : in    unsigned (N_WIDTH - 1 downto 0);
    iCq     : in    signed (C_WIDTH - 1 downto 0);
    oBq     : out   signed (B_WIDTH - 1 downto 0);
    oCq     : out   signed (C_WIDTH - 1 downto 0)
  );
end entity a13_update_bias;

architecture rtl of a13_update_bias is

  signal sIsBNegBranch : std_logic;
  signal sIsBPosBranch : std_logic;
  signal sNeedNegClp   : std_logic;
  signal sNeedPosClp   : std_logic;
  signal sNqSig        : signed(iBq'range);
  signal sBNegFinal    : signed(iBq'range);
  signal sBPosFinal    : signed(iBq'range);
  signal sCDec         : signed(iCq'range);
  signal sCInc         : signed(iCq'range);

begin

  sNqSig <= resize(signed('0' & iNq), B_WIDTH);

  sIsBNegBranch <= '1' when iBq <= - sNqSig else
                   '0';
  sIsBPosBranch <= '1' when iBq > 0 else
                   '0';

  sCDec <= iCq - 1 when iCq > MIN_C else
           iCq;
  sCInc <= iCq + 1 when iCq < MAX_C else
           iCq;

  sNeedNegClp <= '1' when iBq + sNqSig <= - sNqSig else
                 '0';
  sNeedPosClp <= '1' when iBq - sNqSig > 0 else
                 '0';

  sBNegFinal <= - sNqSig + 1 when sNeedNegClp = '1' else
                iBq + sNqSig;
  sBPosFinal <= to_signed(0, sBPosFinal'length) when sNeedPosClp = '1' else
                iBq - sNqSig;

  oBq <= sBNegFinal when sIsBNegBranch = '1' else
         sBPosFinal when sIsBPosBranch = '1' else
         iBq;

  oCq <= sCDec when sIsBNegBranch = '1' else
         sCInc when sIsBPosBranch = '1' else
         iCq;

  postponed assert is_x(oCq) or iCq < MIN_C or iCq > MAX_C or (oCq >= MIN_C and oCq <= MAX_C)
    report "a13: C outside [MIN_C, MAX_C]" severity error;

end architecture rtl;
