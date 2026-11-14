-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
-- A.14-A.16 as openjls_top drives them (stage-1 register, p_run_cnt, stall) vs a T.87 run coder model.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.all;

entity run_coder is
  generic (
    BITNESS : natural := 8;
    WIDTH   : natural := 8;
    LIVE    : natural := 0;
    HELP    : natural := 0
  );
  port (clk : in std_logic);
end entity run_coder;

architecture formal of run_coder is

  constant RUN_CNT_WIDTH : natural := log2ceil(WIDTH + 1);

  attribute anyseq : boolean;
  signal iRst, iValid, iA3Run, iEoi, iStall : std_logic;
  signal iIx, iRa, iRb : unsigned(BITNESS - 1 downto 0);
  attribute anyseq of iRst, iValid, iA3Run, iEoi, iStall, iIx, iRa, iRb : signal is true;

  signal sInit : std_logic := '1';
  signal sCol  : natural range 0 to WIDTH - 1;
  signal sEol  : std_logic;
  signal sCE   : std_logic;

  -- Stage-1 register (p_reg1)
  signal r1V, r1Run, r1Eol, r1Eoi : std_logic;
  signal r1Ix, r1Ra, r1Rb    : unsigned(BITNESS - 1 downto 0);
  signal sRunCntReg          : unsigned(RUN_CNT_WIDTH - 1 downto 0);

  signal sRunCnt                    : unsigned(RUN_CNT_WIDTH - 1 downto 0);
  signal sHit, sContinue            : std_logic;
  signal oRawValid, oRiValid, oNext : std_logic;
  signal oRawLen, oRiIdx            : unsigned(4 downto 0);
  signal oRawVal                    : unsigned(RUN_CNT_WIDTH - 1 downto 0);
  signal oRiIx, oRiRa, oRiRb        : unsigned(BITNESS - 1 downto 0);

  -- T.87 model: RUNindex, run length since the last A.15 '1' bit, in-run flag
  signal mIdx   : natural range 0 to 31;
  signal mRem   : natural range 0 to WIDTH;
  signal mInRun : std_logic;
  -- Its output for the stage-1 token
  signal eRawValid, eRiValid, eNext : std_logic;
  signal eRawLen                    : natural range 0 to 31;
  signal eRawVal                    : natural range 0 to WIDTH;
  signal nIdx                       : natural range 0 to 31;
  signal nRem                       : natural range 0 to WIDTH;

  signal dIdx   : unsigned(4 downto 0);
  signal dNB, dNBM1 : unsigned(RUN_CNT_WIDTH downto 0);
  signal dInRun : std_logic;

  function pow2j (i : natural) return natural is
  begin
    return 2 ** CO_J_TABLE(i);
  end function;

begin

  sInit <= '0' when rising_edge(clk);
  sEol  <= '1' when sCol = WIDTH - 1 else '0';
  -- sCE1 of openjls_top with a token always waiting
  sCE   <= not iStall;

  p_env : process (clk) is
  begin
    if rising_edge(clk) then
      if iRst = '1' then
        sCol  <= 0;
        r1V <= '0'; r1Run <= '0'; r1Eol <= '0'; r1Eoi <= '0';
        sRunCntReg <= (others => '0');
      elsif sCE = '1' then
        if iValid = '1' then
          sCol <= 0 when sEol = '1' else sCol + 1;
        end if;
        r1V   <= iValid;
        -- Mode decision of p_reg1: A.3 says run, or the run goes on
        r1Run <= iValid and (iA3Run or oNext);
        r1Eol <= iValid and sEol;
        r1Eoi <= iValid and sEol and iEoi;
        r1Ix  <= iIx; r1Ra <= iRa; r1Rb <= iRb;
        -- p_run_cnt
        if r1Run = '1' then
          sRunCntReg <= sRunCnt when sContinue = '1' else (others => '0');
        end if;
      end if;
    end if;
  end process p_env;

  u_a14 : entity work.a14_run_length_determination
    generic map (BITNESS => BITNESS, RUN_CNT_WIDTH => RUN_CNT_WIDTH)
    port map (iRa => r1Ra, iIx => r1Ix, iRunCnt => sRunCntReg, iEol => r1Eol,
              oRunCnt => sRunCnt, oRunHit => sHit, oRunContinue => sContinue);

  u_a15 : entity work.a15_a16_encode_run
    generic map (BITNESS => BITNESS, RUN_CNT_WIDTH => RUN_CNT_WIDTH)
    port map (iClk => clk, iRst => iRst, iCE => sCE, iEoi => r1Eoi, iRunCnt => sRunCnt, iRunCntPrev => sRunCntReg,
              iRunHit => sHit, iRunContinue => sContinue, iModeIsRun => r1Run, iIx => r1Ix, iRa => r1Ra, iRb => r1Rb,
              oRawValid => oRawValid, oRawSuffixLen => oRawLen, oRawSuffixVal => oRawVal, oRiValid => oRiValid,
              oRiIx => oRiIx, oRiRa => oRiRa, oRiRb => oRiRb, oRiRunIndex => oRiIdx, oInRunNext => oNext,
              dIdx => dIdx, dNB => dNB, dNBM1 => dNBM1, dInRun => dInRun);

  -- A.14: the run goes on while Ix = RUNval (= Ra, NEAR = 0) and stops at EOLine.
  -- A.15: one '1' each time the run length since the last '1' reaches 2^J[RUNindex], then RUNindex + 1.
  -- A.16: on a break '0' + the remaining length in J[RUNindex] bits, then RUNindex - 1;
  -- at EOLine '1' if a remaining length is left. The C loops emit the same bits once per run.
  p_model_out : process (all) is
  begin
    eRawValid <= '0'; eRiValid <= '0'; eRawLen <= 1; eRawVal <= 1;
    nIdx <= mIdx; nRem <= mRem; eNext <= mInRun;
    if r1Run = '1' then
      if r1Ix = r1Ra then
        if mRem + 1 = pow2j(mIdx) then
          eRawValid <= '1';
          nRem      <= 0;
          nIdx      <= mIdx + 1 when mIdx < 31 else mIdx;
        else
          nRem <= mRem + 1;
          if r1Eol = '1' and LIVE /= 1 then
            eRawValid <= '1';
          end if;
        end if;
        eNext <= not r1Eol;
        if r1Eol = '1' then
          nRem <= 0;
        end if;
      else
        eRawValid <= '1';
        eRawLen   <= CO_J_TABLE(mIdx) + 1;
        eRawVal   <= mRem;
        eRiValid  <= '1';
        nIdx      <= mIdx - 1 when mIdx > 0 else 0;
        nRem      <= 0;
        eNext     <= '0';
      end if;
    end if;
  end process p_model_out;

  p_model : process (clk) is
  begin
    if rising_edge(clk) then
      if iRst = '1' or (sCE = '1' and r1Eoi = '1') then
        mIdx <= 0; mRem <= 0; mInRun <= '0';
      elsif sCE = '1' then
        mIdx <= nIdx; mRem <= nRem; mInRun <= eNext;
      end if;
    end if;
  end process p_model;

  -- psl default clock is rising_edge(clk);
  -- psl assume always (sInit = '1' -> iRst = '1');
  -- top_ctrl stall_empty: the input stops a cycle early, so a stall always finds stage 1 empty
  -- psl assume always (iStall = '1' -> r1V = '0');
  -- Outputs count only when stage 2 loads them (CE)
  -- psl assert always ((sInit = '0' and iRst = '0' and sCE = '1') ->
  --   (oRawValid = eRawValid and oRiValid = eRiValid and oNext = eNext));
  -- psl assert always ((sInit = '0' and iRst = '0' and sCE = '1' and eRawValid = '1') ->
  --   (to_integer(oRawLen) = eRawLen and to_integer(oRawVal) = eRawVal));
  -- psl assert always ((sInit = '0' and iRst = '0' and sCE = '1' and eRiValid = '1') ->
  --   (to_integer(oRiIdx) = mIdx and oRiIx = r1Ix and oRiRa = r1Ra and oRiRb = r1Rb));
  -- HELP: RTL state matches the model state (bound = 2^J[idx] + count - remainder); lets induction close
  -- psl assert always ((HELP = 0 or sInit = '1') or (to_integer(dIdx) = mIdx and dInRun = mInRun and
  --   to_integer(dNB) = pow2j(mIdx) + to_integer(sRunCntReg) - mRem and dNBM1 = dNB - 1 and
  --   mRem < pow2j(mIdx) and mRem <= to_integer(sRunCntReg) and to_integer(sRunCntReg) < WIDTH and
  --   (mInRun = '1' or (sRunCntReg = 0 and mRem = 0))));
  -- psl assert always ((HELP = 0 or sInit = '1') or ((r1Run = '0' or r1V = '1') and (r1Eol = '0' or r1V = '1') and
  --   sCol <= WIDTH - 1 and (r1Eoi = '0' or r1Eol = '1') and (r1Eol = '0' or sCol = 0) and
  --   (r1V = '0' or r1Eol = '1' or to_integer(sRunCntReg) < sCol) and (r1V = '1' or to_integer(sRunCntReg) <= sCol)));

end architecture formal;
