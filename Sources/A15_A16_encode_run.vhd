-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- a15_a16_encode_run: T.87 A.15 + A.16, run-length encoding
--
-- Mealy FSM on A.14's combinational outputs. sNextBound is the run count of the next A.15 '1' bit:
-- 2^J[RUNindex] at run start, then + 2^J[RUNindex + 1] per hit. RUNindex resets only at iEoi.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

entity a15_a16_encode_run is
  generic (
    BITNESS       : natural := CO_BITNESS_STD;
    RUN_CNT_WIDTH : natural := 16
  );
  port (
    iClk          : in    std_logic;
    iRst          : in    std_logic;
    iCE           : in    std_logic;
    iEoi          : in    std_logic;

    -- From A14, unregistered
    iRunCnt       : in    unsigned(RUN_CNT_WIDTH - 1 downto 0);
    iRunHit       : in    std_logic;
    iRunContinue  : in    std_logic;

    iModeIsRun    : in    std_logic;

    -- Valid on the break cycle
    iIx           : in    unsigned(BITNESS - 1 downto 0);
    iRa           : in    unsigned(BITNESS - 1 downto 0);
    iRb           : in    unsigned(BITNESS - 1 downto 0);

    -- A.15 '1' bits and the A.16 break prefix; can fire together with oRiValid
    oRawValid     : out   std_logic;
    oRawSuffixLen : out   unsigned(4 downto 0);
    oRawSuffixVal : out   unsigned(RUN_CNT_WIDTH - 1 downto 0);

    -- RI token on break; oRiRunIndex is RUNindex before the A.16 decrement
    oRiValid      : out   std_logic;
    oRiIx         : out   unsigned(BITNESS - 1 downto 0);
    oRiRa         : out   unsigned(BITNESS - 1 downto 0);
    oRiRb         : out   unsigned(BITNESS - 1 downto 0);
    oRiRunIndex   : out   unsigned(4 downto 0);
    oInRunNext    : out   std_logic
  );
end entity a15_a16_encode_run;

architecture behavioral of a15_a16_encode_run is

  constant C_BOUND_WIDTH : natural := RUN_CNT_WIDTH + 1;

  signal sRunIndex       : unsigned(4 downto 0);                  -- [0, 31], full type: saturated at 31
  signal sNextBound      : unsigned(C_BOUND_WIDTH - 1 downto 0);  -- [1, 2^RUN_CNT_WIDTH + 2^15]
  signal sInRun          : std_logic;

  signal sRunIndexNext   : unsigned(4 downto 0);
  signal sNextBoundNext  : unsigned(C_BOUND_WIDTH - 1 downto 0);
  signal sInRunNext      : std_logic;

begin

  -- Contracts (PSL, simulation only)
  -- psl default clock is rising_edge(iClk);
  -- psl assert always ((iRst = '1' or iEoi = '1') -> next (sInRun = '0' and sRunIndex = 0)) report "a15_a16: run state must clear one cycle after iEoi/reset";
  -- psl assert always (iModeIsRun = '0' -> (oRawValid = '0' and oRiValid = '0')) report "a15_a16: no tokens outside run mode";

  p_comb : process (sRunIndex, sNextBound, sInRun,
                    iRunCnt, iRunHit, iRunContinue, iModeIsRun, iEoi, iRst,
                    iIx, iRa, iRb) is

    variable vJ        : natural;
    variable vJNext    : natural;
    variable vStep     : unsigned(C_BOUND_WIDTH - 1 downto 0);
    variable vStepNext : unsigned(C_BOUND_WIDTH - 1 downto 0);
    variable vBoundHit : boolean;
    variable vNewIndex : unsigned(4 downto 0);

  begin

    oRawValid     <= '0';
    oRawSuffixLen <= to_unsigned(1, 5);
    oRawSuffixVal <= to_unsigned(1, RUN_CNT_WIDTH);
    oRiValid      <= '0';
    oRiIx         <= iIx;
    oRiRa         <= iRa;
    oRiRb         <= iRb;
    oRiRunIndex   <= sRunIndex;

    sRunIndexNext  <= sRunIndex;
    sNextBoundNext <= sNextBound;
    sInRunNext     <= sInRun;

    if (iModeIsRun = '1' and iRst = '0') then
      vJ    := CO_J_TABLE(to_integer(sRunIndex));
      vStep := shift_left(to_unsigned(1, C_BOUND_WIDTH), vJ);
      if (sRunIndex < 31) then
        vJNext := CO_J_TABLE(to_integer(sRunIndex) + 1);
      else
        vJNext := CO_J_TABLE(31);
      end if;
      vStepNext := shift_left(to_unsigned(1, C_BOUND_WIDTH), vJNext);

      if (iRunHit = '1') then
        -- A.15: match
        vBoundHit := resize(iRunCnt, C_BOUND_WIDTH) = sNextBound;
        vNewIndex := sRunIndex;

        if (vBoundHit) then
          oRawValid <= '1';
          if (sRunIndex < 31) then
            vNewIndex := sRunIndex + 1;
          end if;
        end if;

        sInRunNext <= '1';

        if (iRunContinue = '0') then
          -- EOLine
          sInRunNext <= '0';
          if (not vBoundHit and iRunCnt > 0) then
            oRawValid <= '1'; -- A16 EOLine '1' bit
          end if;
          sRunIndexNext  <= vNewIndex;
          sNextBoundNext <= shift_left(to_unsigned(1, C_BOUND_WIDTH),
                                       CO_J_TABLE(to_integer(vNewIndex)));
        else
          sRunIndexNext <= vNewIndex;
          if (vBoundHit) then
            sNextBoundNext <= sNextBound + vStepNext;
          end if;
        end if;
      else
        -- A.16: break, including on the first run-mode pixel (RUNcnt = 0 gives a single '0').
        -- Suffix = pixels since the last boundary.
        oRawValid     <= '1';
        oRawSuffixLen <= to_unsigned(vJ + 1, 5);
        oRawSuffixVal <= iRunCnt - resize(sNextBound - vStep, RUN_CNT_WIDTH);
        oRiValid      <= '1';
        oRiIx         <= iIx;
        oRiRa         <= iRa;
        oRiRb         <= iRb;

        if (sRunIndex > 0) then
          vNewIndex := sRunIndex - 1;
        else
          vNewIndex := (others => '0');
        end if;

        sInRunNext     <= '0';
        sRunIndexNext  <= vNewIndex;
        sNextBoundNext <= shift_left(to_unsigned(1, C_BOUND_WIDTH),
                                     CO_J_TABLE(to_integer(vNewIndex)));
      end if;
    end if;

  end process p_comb;

  oInRunNext <= sInRunNext;

  p_state_reg : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iRst = '1' or iEoi = '1') then
        sRunIndex  <= (others => '0');
        sNextBound <= to_unsigned(1, C_BOUND_WIDTH);
        sInRun     <= '0';
      elsif (iCE = '1') then
        sRunIndex  <= sRunIndexNext;
        sNextBound <= sNextBoundNext;
        sInRun     <= sInRunNext;
      end if;
    end if;

  end process p_state_reg;

end architecture behavioral;
