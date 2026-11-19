-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
-- A15_A16 with its openjls_top loop per copy: Reg1 mode from oInRunNext, A14, sRunCntReg
library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.all;

entity @NAME@ is
  generic (
    BITNESS : natural := 8;
    MAX_IMAGE_WIDTH : natural := 4096
  )@PORT@;
end entity @NAME@;

architecture formal of @NAME@ is

  constant RUN_CNT_WIDTH : natural := log2ceil(MAX_IMAGE_WIDTH + 1);
  attribute anyseq : boolean;
  -- free
  signal iRst_i, iStall_i, iLbValid_i, iCtxRun_i, iEol_i, iEoi_i : std_logic;
  signal iIx_i, iRa_i, iRb_i : unsigned(BITNESS - 1 downto 0);
  attribute anyseq of iRst_i, iStall_i, iLbValid_i, iCtxRun_i, iEol_i, iEoi_i, iIx_i, iRa_i, iRb_i : signal is true;
  -- end free
  signal sInit : std_logic := '1';
  signal sCol : unsigned(RUN_CNT_WIDTH - 1 downto 0);
  signal sCE : std_logic;
  signal sR1Ix, sR1Ra, sR1Rb : unsigned(BITNESS - 1 downto 0);
  signal sReg1Eol, sReg1Eoi : std_logic;

  type t_copy is record
    run, inRunNext, rawValid, riValid : std_logic;
    rawLen, riIdx : unsigned(4 downto 0);
    rawVal, cnt, cntReg : unsigned(RUN_CNT_WIDTH - 1 downto 0);
    riIx, riRa, riRb : unsigned(BITNESS - 1 downto 0);
    hit, cont : std_logic;
  end record;
  signal g, m : t_copy;

  -- A11_2 keeps only the low RawLen bits of RawVal
  function low (v : unsigned; n : unsigned) return unsigned is
    variable r : unsigned(v'range) := (others => '0');
  begin
    for i in v'range loop
      if i < to_integer(n) then r(i) := v(i); end if;
    end loop;
    return r;
  end function;

  -- Stage 2 token as p_reg2 latches it
  function same (a, b : t_copy) return boolean is
  begin
    if a.run /= b.run then return false; end if;
    if a.run = '0' then return true; end if;
    if a.riValid /= b.riValid or a.rawValid /= b.rawValid then return false; end if;
    if a.riValid = '0' and a.rawValid = '0' then return true; end if;
    if a.rawLen /= b.rawLen or low(a.rawVal, a.rawLen) /= low(b.rawVal, b.rawLen) then return false; end if;
    return a.riValid = '0' or (a.riIdx = b.riIdx and a.riIx = b.riIx and a.riRa = b.riRa and a.riRb = b.riRb);
  end function;

begin

  sCE <= not iStall_i;

  p_env : process (clk) is
  begin
    if rising_edge(clk) then
      sInit <= '0';
      if iRst_i = '1' then
        sCol <= (others => '0'); g.run <= '0'; m.run <= '0'; g.cntReg <= (others => '0'); m.cntReg <= (others => '0');
        sReg1Eol <= '0'; sReg1Eoi <= '0';
      elsif sCE = '1' then
        g.run <= iLbValid_i and (iCtxRun_i or g.inRunNext);
        m.run <= iLbValid_i and (iCtxRun_i or m.inRunNext);
        sR1Ix <= iIx_i; sR1Ra <= iRa_i; sR1Rb <= iRb_i;
        sReg1Eol <= iLbValid_i and iEol_i;
        sReg1Eoi <= iLbValid_i and iEoi_i;
        if iLbValid_i = '1' then
          sCol <= (others => '0') when iEol_i = '1' else sCol + 1;
        end if;
        if g.run = '1' then g.cntReg <= g.cnt when g.cont = '1' else (others => '0'); end if;
        if m.run = '1' then m.cntReg <= m.cnt when m.cont = '1' else (others => '0'); end if;
      end if;
    end if;
  end process p_env;

  g_a14 : entity work.a14_run_length_determination(behavioral)
    generic map (BITNESS => BITNESS, RUN_CNT_WIDTH => RUN_CNT_WIDTH)
    port map (iRa => sR1Ra, iIx => sR1Ix, iRunCnt => g.cntReg, iEol => sReg1Eol,
              oRunCnt => g.cnt, oRunHit => g.hit, oRunContinue => g.cont);
  m_a14 : entity work.a14_run_length_determination(behavioral)
    generic map (BITNESS => BITNESS, RUN_CNT_WIDTH => RUN_CNT_WIDTH)
    port map (iRa => sR1Ra, iIx => sR1Ix, iRunCnt => m.cntReg, iEol => sReg1Eol,
              oRunCnt => m.cnt, oRunHit => m.hit, oRunContinue => m.cont);

  u_gold : entity work.a15_a16_encode_run(behavioral)
    generic map (BITNESS => BITNESS, RUN_CNT_WIDTH => RUN_CNT_WIDTH)
    port map (iClk => clk, iRst => iRst_i, iCE => sCE, iEoi => sReg1Eoi, iRunCnt => g.cnt, iRunCntPrev => g.cntReg,
              iRunHit => g.hit, iRunContinue => g.cont, iModeIsRun => g.run, iIx => sR1Ix, iRa => sR1Ra, iRb => sR1Rb,
              oRawValid => g.rawValid, oRawSuffixLen => g.rawLen, oRawSuffixVal => g.rawVal, oRiValid => g.riValid,
              oRiIx => g.riIx, oRiRa => g.riRa, oRiRb => g.riRb, oRiRunIndex => g.riIdx, oInRunNext => g.inRunNext);
  u_mut : entity work.a15_a16_encode_run_mut(behavioral)
    generic map (BITNESS => BITNESS, RUN_CNT_WIDTH => RUN_CNT_WIDTH)
    port map (iClk => clk, iRst => iRst_i, iCE => sCE, iEoi => sReg1Eoi, iRunCnt => m.cnt, iRunCntPrev => m.cntReg,
              iRunHit => m.hit, iRunContinue => m.cont, iModeIsRun => m.run, iIx => sR1Ix, iRa => sR1Ra, iRb => sR1Rb,
              oRawValid => m.rawValid, oRawSuffixLen => m.rawLen, oRawSuffixVal => m.rawVal, oRiValid => m.riValid,
              oRiIx => m.riIx, oRiRa => m.riRa, oRiRb => m.riRb, oRiRunIndex => m.riIdx, oInRunNext => m.inRunNext);

  -- What the top consumes, only on a live (not stalled) run token: p_reg2 latches with CE2
  -- @CHECK@
  -- psl default clock is rising_edge(clk);
  -- psl assume always (sInit = '1' -> iRst_i = '1');
  -- psl assume always (iEoi_i = '1' -> iEol_i = '1');
  -- psl assume always (sCol < MAX_IMAGE_WIDTH - 1 or iEol_i = '1' or iLbValid_i = '0');
  -- psl assert always (sInit = '0' -> (sCE = '0' or same(g, m)));
  -- @END@

end architecture formal;
