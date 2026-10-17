-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

----------------------------------------------------------------------------------
-- Engineer:    Vitor Mendes Camilo
--
-- Module Name: A15_A16_encode_run - Behavioral
-- Description: Code segments A.15 and A.16 — run-segment encoding.
--
--              Mealy FSM: outputs are combinational from A14's current outputs
--              and registered state. A14 is connected combinationally (no
--              register between A14 and this stage).
--
--              sNextBound: cumulative pixel count at which the next A15 '1' bit
--              fires. Initialized to 2^J[RUNindex] at run start; advances by
--              2^J[RUNindex+1] on each boundary hit.
--
--              Each cycle when iRunHit='1':
--                if iRunCnt == sNextBound → emit A15 '1' (oA15Valid).
--              When run ends (iRunContinue='0'):
--                EOLine, residual > 0: emit A16 '1' bit (only if no boundary hit).
--                Break (iRunHit='0'): emit RI token with A16 prefix. Covers
--                both breaks after one or more matches (sInRun='1') and the
--                immediate-break case on the first pixel of run mode
--                (sInRun='0', RUNcnt=0 → single '0' bit + RI).
--
--              RUNindex persists across runs within a scan; resets at iEoi.
----------------------------------------------------------------------------------

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

    -- From A14 (combinational — no register between A14 and this stage)
    iRunCnt       : in    unsigned(RUN_CNT_WIDTH - 1 downto 0); -- A14 oRunCnt
    iRunHit       : in    std_logic;                            -- A14 oRunHit
    iRunContinue  : in    std_logic;                            -- A14 oRunContinue

    -- Mode gate: only process when pipeline is in run mode
    iModeIsRun    : in    std_logic;

    -- Pixel data for RI token (valid on break cycle)
    iIx           : in    unsigned(BITNESS - 1 downto 0);
    iRa           : in    unsigned(BITNESS - 1 downto 0);
    iRb           : in    unsigned(BITNESS - 1 downto 0);

    -- Raw bit token: A15 '1' bits (SuffixLen=1, SuffixVal=1) and
    --               A16 break prefix (SuffixLen=J+1, SuffixVal=residual).
    --               oRiValid may be asserted simultaneously on break.
    oRawValid     : out   std_logic;
    oRawSuffixLen : out   unsigned(4 downto 0);
    oRawSuffixVal : out   unsigned(RUN_CNT_WIDTH - 1 downto 0);

    -- Run-interruption token (break case only); carries Ix/Ra/Rb for Golomb path.
    -- oRiRunIndex is RUNindex before the A.16 decrement, used by A.22.1 to
    -- compute glimit = LIMIT - J[RUNindex] - 1.
    oRiValid      : out   std_logic;
    oRiIx         : out   unsigned(BITNESS - 1 downto 0);
    oRiRa         : out   unsigned(BITNESS - 1 downto 0);
    oRiRb         : out   unsigned(BITNESS - 1 downto 0);
    oRiRunIndex   : out   unsigned(4 downto 0);
    oInRunNext    : out   std_logic                             -- Tells top level we are mid-run
  );
end entity a15_a16_encode_run;

architecture behavioral of a15_a16_encode_run is

  constant C_BOUND_WIDTH : natural := RUN_CNT_WIDTH + 1;

  -- Registered state
  signal sRunIndex       : unsigned(4 downto 0);                  -- [0, 31], full type: saturated at 31
  signal sNextBound      : unsigned(C_BOUND_WIDTH - 1 downto 0);  -- [1, 2^RUN_CNT_WIDTH + 2^15]
  signal sInRun          : std_logic;

  -- Next-state signals (driven combinationally, captured by clocked process)
  signal sRunIndexNext   : unsigned(4 downto 0);
  signal sNextBoundNext  : unsigned(C_BOUND_WIDTH - 1 downto 0);
  signal sInRunNext      : std_logic;

begin

  -- Contract assertions in PSL (active in NVC sims via --psl, plain comments
  -- to synthesis): run state and RUNindex must clear one cycle after iEoi
  -- (T.87: RUNindex persists across runs within a scan only); tokens only
  -- fire in run mode.
  -- psl default clock is rising_edge(iClk);
  -- psl assert always ((iRst = '1' or iEoi = '1') -> next (sInRun = '0' and sRunIndex = 0)) report "a15_a16: run state must clear one cycle after iEoi/reset";
  -- psl assert always (iModeIsRun = '0' -> (oRawValid = '0' and oRiValid = '0')) report "a15_a16: no tokens outside run mode";

  -- ── Combinational: outputs and next-state ─────────────────────────────────
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

    -- Output defaults
    oRawValid     <= '0';
    oRawSuffixLen <= to_unsigned(1, 5);
    oRawSuffixVal <= to_unsigned(1, RUN_CNT_WIDTH);
    oRiValid      <= '0';
    oRiIx         <= iIx;
    oRiRa         <= iRa;
    oRiRb         <= iRb;
    oRiRunIndex   <= sRunIndex;

    -- Next-state defaults: hold current
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
        -- ── A.15: matching pixel ───────────────────────────────────────────
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
          -- Run continues
          sRunIndexNext <= vNewIndex;
          if (vBoundHit) then
            sNextBoundNext <= sNextBound + vStepNext;
          end if;
        end if;
      else
        -- ── A.16: break (iRunHit='0') ─────────────────────────────────────
        -- Covers both break-after-matches (sInRun='1') and immediate break on
        -- the first pixel of run mode (sInRun='0', RUNcnt=0).
        -- residual = iRunCnt - (sNextBound - vStep) = count since last boundary
        -- (for immediate break: iRunCnt=0, sNextBound=1, vStep=1 → residual=0,
        --  SuffixLen = J[0]+1 = 1 → single '0' break marker).
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

  -- ── Clocked: state registers ──────────────────────────────────────────────
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
