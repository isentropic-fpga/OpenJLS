-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a12_a13_update: T.87 A.12 and A.13 fused, regular-mode update of A[Q], B[Q], C[Q]
--
-- A.13 tests and adds N[Q] on the B[Q] that A.12 just produced. Each sum here is one carry chain over
-- B + Errval + constant-or-N instead of two adders in series. Rescale halves the A.12 B[Q], so its
-- offsets are scaled to test the unhalved sum; every test is then a sign bit, with no zero detect.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a12_a13_update is
  generic (
    ERROR_WIDTH : natural := CO_ERROR_VALUE_WIDTH_STD;
    A_WIDTH     : natural := CO_AQ_WIDTH_STD;
    B_WIDTH     : natural := CO_BQ_WIDTH_STD;
    N_WIDTH     : natural := CO_NQ_WIDTH_STD;
    C_WIDTH     : natural := CO_CQ_WIDTH;
    MIN_C       : integer := CO_MIN_CQ;
    MAX_C       : integer := CO_MAX_CQ;
    RESET       : natural := CO_RESET_STD
  );
  port (
    iErrorVal   : in    signed (ERROR_WIDTH - 1 downto 0);
    iAq         : in    unsigned (A_WIDTH - 1 downto 0);
    iBq         : in    signed (B_WIDTH - 1 downto 0);
    iCq         : in    signed (C_WIDTH - 1 downto 0);
    iNq         : in    unsigned (N_WIDTH - 1 downto 0);
    -- Next N[Q] and iNq = RESET, registered by the caller off the update path
    iNqNew      : in    unsigned (N_WIDTH - 1 downto 0);
    iRescale    : in    std_logic;
    oAq         : out   unsigned (A_WIDTH - 1 downto 0);
    oBq         : out   signed (B_WIDTH - 1 downto 0);
    oCq         : out   signed (C_WIDTH - 1 downto 0);
    -- Branch taken, set even when C is clamped
    oDec        : out   std_logic;
    oInc        : out   std_logic
  );
end entity a12_a13_update;

architecture rtl of a12_a13_update is

  constant RESCALED_N : natural := RESET / 2 + 1;
  -- Guard bits so no sum wraps, for any iBq and the largest rescale offset
  constant SUM_WIDTH  : natural := maximum(B_WIDTH, N_WIDTH + 3) + 3;

  subtype t_sum is signed(SUM_WIDTH - 1 downto 0);

  -- a + b + c + cin as carry-save then one carry chain
  function add3 (a, b, c : t_sum; cin : std_logic) return t_sum is
    variable vA, vB, vC, vMaj : std_logic_vector(SUM_WIDTH - 1 downto 0);
    variable vSum             : unsigned(SUM_WIDTH downto 0);
  begin
    vA   := std_logic_vector(a);
    vB   := std_logic_vector(b);
    vC   := std_logic_vector(c);
    vMaj := (vA and vB) or (vA and vC) or (vB and vC);
    -- The extra low bit carries cin into the chain
    vSum := unsigned((vA xor vB xor vC) & '1') + unsigned(vMaj(SUM_WIDTH - 2 downto 0) & '0' & cin);
    return signed(vSum(SUM_WIDTH downto 1));
  end function add3;

  function const_sum (v : integer) return t_sum is
  begin
    return to_signed(v, SUM_WIDTH);
  end function const_sum;

  signal sErrSign  : std_logic;
  signal sErrExt   : unsigned(A_WIDTH - 1 downto 0);
  signal sAqSum    : unsigned(A_WIDTH downto 0);
  signal sAqNew    : unsigned(A_WIDTH - 1 downto 0);

  signal sB        : t_sum;
  signal sE        : t_sum;
  signal sN        : t_sum;
  signal sNNew     : t_sum;
  signal sNot      : t_sum;

  signal sTNegSum  : t_sum;
  signal sTClpNSum : t_sum;
  signal sTPosSum  : t_sum;
  signal sTClpPSum : t_sum;
  signal sMidSum   : t_sum;
  signal sPlusSum  : t_sum;
  signal sMinusSum : t_sum;

  signal sIsNeg    : std_logic;
  signal sIsPos    : std_logic;
  signal sClpNeg   : std_logic;
  signal sClpPos   : std_logic;

  signal sCDec     : signed(iCq'range);
  signal sCInc     : signed(iCq'range);

begin

  -- A + |Errval| in one chain: conditional invert plus carry-in, no negate in series
  sErrSign <= iErrorVal(iErrorVal'high);
  sErrExt  <= unsigned(resize(iErrorVal, A_WIDTH)) xor (A_WIDTH - 1 downto 0 => sErrSign);
  sAqSum   <= unsigned(iAq & '1') + unsigned(sErrExt & sErrSign);
  sAqNew   <= sAqSum(A_WIDTH downto 1);

  oAq <= shift_right(sAqNew, 1) when iRescale = '1' else
         sAqNew;

  sB    <= resize(iBq, SUM_WIDTH);
  sE    <= resize(iErrorVal, SUM_WIDTH);
  sN    <= signed(resize(iNq, SUM_WIDTH));
  sNNew <= signed(resize(iNqNew, SUM_WIDTH));
  sNot  <= not sNNew;

  sTNegSum  <= add3(sB, sE, const_sum(2 * RESCALED_N - 2), '0') when iRescale = '1' else
               add3(sB, sE, sN, '0');
  sTClpNSum <= add3(sB, sE, const_sum(4 * RESCALED_N - 2), '0') when iRescale = '1' else
               add3(sB, sE, sN(SUM_WIDTH - 2 downto 0) & '1', '0');
  sTPosSum  <= add3(sB, sE, const_sum(-2), '0') when iRescale = '1' else
               add3(sB, sE, const_sum(-1), '0');
  sTClpPSum <= add3(sB, sE, const_sum(-2 * RESCALED_N - 2), '0') when iRescale = '1' else
               add3(sB, sE, sNot, '0');

  sMidSum   <= add3(sB, sE, const_sum(0), '0');
  sPlusSum  <= add3(sB, sE, const_sum(2 * RESCALED_N), '0') when iRescale = '1' else
               add3(sB, sE, sNNew, '0');
  sMinusSum <= add3(sB, sE, const_sum(-2 * RESCALED_N), '0') when iRescale = '1' else
               add3(sB, sE, sNot, '1');

  sIsNeg  <= sTNegSum(SUM_WIDTH - 1);
  sClpNeg <= sTClpNSum(SUM_WIDTH - 1);
  sIsPos  <= not sTPosSum(SUM_WIDTH - 1);
  sClpPos <= not sTClpPSum(SUM_WIDTH - 1);

  sCDec <= iCq - 1 when iCq > MIN_C else
           iCq;
  sCInc <= iCq + 1 when iCq < MAX_C else
           iCq;

  oBq <= resize(1 - signed(resize(iNqNew, B_WIDTH + 1)), B_WIDTH) when sIsNeg = '1' and sClpNeg = '1' else
         resize(shift_right(sPlusSum, 1), B_WIDTH) when sIsNeg = '1' and iRescale = '1' else
         resize(sPlusSum, B_WIDTH) when sIsNeg = '1' else
         to_signed(0, B_WIDTH) when sIsPos = '1' and sClpPos = '1' else
         resize(shift_right(sMinusSum, 1), B_WIDTH) when sIsPos = '1' and iRescale = '1' else
         resize(sMinusSum, B_WIDTH) when sIsPos = '1' else
         resize(shift_right(sMidSum, 1), B_WIDTH) when iRescale = '1' else
         resize(sMidSum, B_WIDTH);

  oCq <= sCDec when sIsNeg = '1' else
         sCInc when sIsPos = '1' else
         iCq;

  oDec <= sIsNeg;
  oInc <= sIsPos and not sIsNeg;

  postponed assert is_x(sAqNew) or sAqNew >= iAq report "a12_a13: A wrapped" severity error;
  postponed assert is_x(oCq) or iCq < MIN_C or iCq > MAX_C or (oCq >= MIN_C and oCq <= MAX_C)
    report "a12_a13: C outside [MIN_C, MAX_C]" severity error;

end architecture rtl;
