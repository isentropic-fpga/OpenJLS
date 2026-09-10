-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: a15_a16_encode_run (stateful Mealy FSM).
--
-- The RTL emits the A.15 unary run-segment bits incrementally (one per rg
-- boundary as the run advances) instead of as an end-of-run burst, and emits the
-- A.16 terminal (break code + RI token, or the EOL residual '1'). This TB is
-- transaction-level: it drives a complete run (M matches + a terminal), collects
-- every emitted bit (oRawSuffixVal, oRawSuffixLen MSB-first) into a bit string,
-- and compares it against the T.87 A.15/A.16 algorithm (Docs/Project.md) computed
-- independently as a burst. RUNindex persistence across runs (reset only at EOI)
-- is validated implicitly: the reference tracks RUNindex with the C model and the
-- next run's bits depend on it. Coverage: terminal type, immediate break,
-- EOI reset, and the start-RUNindex range.
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.log2ceil;

library osvvm;
  context osvvm.OsvvmContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_a15_a16_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_a15_a16_osvvm;

architecture sim of tb_a15_a16_osvvm is

  constant RC_W       : natural := 16;
  constant CLK_PERIOD : time    := CLK_PERIOD_DEFAULT;
  constant MAXBITS    : natural := 8192;

  constant T_BREAK    : integer := 0;
  constant T_EOL      : integer := 1;

  -- Run-mode pixel literals (Ra==Ix => match; Ix/=Ra => break).
  constant RUNVAL     : integer := 10;
  constant BRKPIX     : integer := 50;
  constant RBVAL      : integer := 20;

  signal clk          : std_logic := '0';
  signal rst          : std_logic;
  signal iEoi         : std_logic;
  signal iCE          : std_logic := '1';
  signal iRunCnt      : unsigned(RC_W - 1 downto 0);
  signal iRunHit      : std_logic;
  signal iRunCont     : std_logic;
  signal iModeIsRun   : std_logic;
  signal iIx          : unsigned(BITNESS - 1 downto 0);
  signal iRaPix       : unsigned(BITNESS - 1 downto 0);
  signal iRbPix       : unsigned(BITNESS - 1 downto 0);
  signal oRawValid    : std_logic;
  signal oRawSuffixLen : unsigned(4 downto 0);
  signal oRawSuffixVal : unsigned(RC_W - 1 downto 0);
  signal oRiValid     : std_logic;
  signal oRiIx        : unsigned(BITNESS - 1 downto 0);
  signal oRiRa        : unsigned(BITNESS - 1 downto 0);
  signal oRiRb        : unsigned(BITNESS - 1 downto 0);
  signal oRiRunIndex  : unsigned(4 downto 0);
  signal oInRunNext   : std_logic;

  -- Append nbits of val (MSB-first) as '0'/'1' chars onto buf.
  procedure app (
    buf   : inout string;
    len   : inout natural;
    val   : natural;
    nbits : natural
  ) is
  begin

    for i in nbits - 1 downto 0 loop

      len := len + 1;
      if ((val / (2 ** i)) mod 2 = 1) then
        buf(len) := '1';
      else
        buf(len) := '0';
      end if;

    end loop;

  end procedure app;

  -- T.87 A.15 + A.16 burst reference for one run.
  procedure gen_expected (
    r0      : natural;
    m       : natural;
    term    : integer;
    buf     : inout string;
    len     : inout natural;
    newIdx  : out natural;
    riFires : out boolean
  ) is

    variable ri   : natural;
    variable cnt  : natural;
    variable step : natural;

  begin

    len := 0;
    ri  := r0;
    cnt := m;

    -- A.15: emit a '1' per completed run segment of length 2^J[RUNindex].
    loop

      step := 2 ** TB_J_TABLE(ri);
      exit when cnt < step;
      app(buf, len, 1, 1);
      cnt := cnt - step;
      if (ri < 31) then
        ri := ri + 1;
      end if;

    end loop;

    -- A.16 terminal.
    if (term = T_BREAK) then
      -- '0' marker then residual in J[RUNindex] bits = cnt in (J+1) bits.
      app(buf, len, cnt, TB_J_TABLE(ri) + 1);
      if (ri > 0) then
        ri := ri - 1;
      end if;
      riFires := true;
    else
      if (cnt > 0) then
        app(buf, len, 1, 1);
      end if;
      riFires := false;
    end if;

    newIdx := ri;

  end procedure gen_expected;

begin

  clk_proc : process is
  begin

    clk <= '1';
    wait for CLK_PERIOD / 2;
    clk <= '0';
    wait for CLK_PERIOD / 2;

  end process clk_proc;

  dut : entity work.a15_a16_encode_run(behavioral)
    generic map (
      BITNESS       => BITNESS,
      RUN_CNT_WIDTH => RC_W
    )
    port map (
      iClk          => clk,
      iRst          => rst,
      iCE           => iCE,
      iEoi          => iEoi,
      iRunCnt       => iRunCnt,
      iRunHit       => iRunHit,
      iRunContinue  => iRunCont,
      iModeIsRun    => iModeIsRun,
      iIx           => iIx,
      iRa           => iRaPix,
      iRb           => iRbPix,
      oRawValid     => oRawValid,
      oRawSuffixLen => oRawSuffixLen,
      oRawSuffixVal => oRawSuffixVal,
      oRiValid      => oRiValid,
      oRiIx         => oRiIx,
      oRiRa         => oRiRa,
      oRiRb         => oRiRb,
      oRiRunIndex   => oRiRunIndex,
      oInRunNext    => oInRunNext
    );

  stim : process is

    variable rv      : RandomPType;
    variable covTerm : CoverageIDType;
    variable covImm  : CoverageIDType;
    variable covEoi  : CoverageIDType;
    variable covIdx  : CoverageIDType;
    variable req     : AlertLogIDType;

    variable actBuf  : string(1 to MAXBITS);
    variable actLen  : natural;
    variable expBuf  : string(1 to MAXBITS);
    variable expLen  : natural;
    variable carried : natural;       -- expected RUNindex carried across runs
    variable newIdx  : natural;
    variable riFires : boolean;

    -- Present one cycle and (when emitting) collect bits into actBuf.
    procedure cycle_collect (
      hit  : std_logic;
      cont : std_logic;
      cnt  : natural;
      ix   : integer;
      ra   : integer;
      eoi  : std_logic
    ) is
      variable paused : std_logic_vector(2 + 5 + RC_W + 3 * BITNESS + 5 downto 0);
    begin

      iRunHit  <= hit;
      iRunCont <= cont;
      iRunCnt  <= to_unsigned(cnt, RC_W);
      iIx      <= to_unsigned(ix, BITNESS);
      iRaPix   <= to_unsigned(ra, BITNESS);
      iRbPix   <= to_unsigned(RBVAL, BITNESS);
      iEoi     <= eoi;
      wait for 1 ns;
      if eoi = '0' and rv.RandInt(0, 15) = 0 then
        iCE <= '0';
        paused := oRawValid & std_logic_vector(oRawSuffixLen) & std_logic_vector(oRawSuffixVal) &
                  oRiValid & std_logic_vector(oRiIx) & std_logic_vector(oRiRa) &
                  std_logic_vector(oRiRb) & std_logic_vector(oRiRunIndex) & oInRunNext;
        for cycle in 1 to 2 loop
          wait until rising_edge(clk);
          wait for 1 ns;
          AffirmIfEqual(GetAlertLogID("ClockEnable"),
            oRawValid & std_logic_vector(oRawSuffixLen) & std_logic_vector(oRawSuffixVal) &
            oRiValid & std_logic_vector(oRiIx) & std_logic_vector(oRiRa) &
            std_logic_vector(oRiRb) & std_logic_vector(oRiRunIndex) & oInRunNext,
            paused, "CE holds state and pending token");
        end loop;
        iCE <= '1';
      end if;

      if (oRawValid = '1') then
        app(actBuf, actLen, checked_integer(oRawSuffixVal), checked_integer(oRawSuffixLen));
      end if;

    end procedure cycle_collect;

    -- Drive a whole run; check the collected bitstream against the reference.
    procedure do_run (
      m    : natural;
      term : integer;
      eoi  : std_logic;
      msg  : string
    ) is

      variable nMatch : natural;
      variable terminalIdx : natural;
      variable residual : natural;

    begin

      gen_expected(carried, m, term, expBuf, expLen, newIdx, riFires);
      actLen := 0;
      terminalIdx := carried;
      residual := m;
      while residual >= 2 ** TB_J_TABLE(terminalIdx) loop
        residual := residual - 2 ** TB_J_TABLE(terminalIdx);
        if terminalIdx < 31 then
          terminalIdx := terminalIdx + 1;
        end if;
      end loop;

      if (term = T_BREAK) then
        nMatch := m;
      else
        nMatch := m - 1;                 -- EOL: last pixel is the terminal
      end if;

      -- Matching pixels (run continues).
      for i in 1 to nMatch loop

        cycle_collect('1', '1', i, RUNVAL, RUNVAL, '0');
        wait until rising_edge(clk);

      end loop;

      -- Terminal cycle.
      if (term = T_BREAK) then
        cycle_collect('0', '0', m, BRKPIX, RUNVAL, eoi);
      else
        cycle_collect('1', '0', m, RUNVAL, RUNVAL, eoi);
      end if;

      AffirmIf(req, oRiValid = bool2bit(riFires), msg & " RI-valid");
      if (term = T_BREAK) then
        AffirmIfEqual(req, checked_integer(oRiIx), BRKPIX, msg & " RI Ix");
        AffirmIfEqual(req, checked_integer(oRiRa), RUNVAL, msg & " RI Ra");
        AffirmIfEqual(req, checked_integer(oRiRb), RBVAL, msg & " RI Rb");
        AffirmIfEqual(req, checked_integer(oRiRunIndex), terminalIdx, msg & " RI index before decrement");
      end if;
      wait until rising_edge(clk);

      iEoi <= '0';

      -- Compare the collected run-segment bitstream.
      AffirmIfEqual(req, actLen, expLen, msg & " bit-length");
      if (actLen = expLen) then
        AffirmIfEqual(req, actBuf(1 to actLen), expBuf(1 to expLen), msg & " bitstream");
      end if;

      -- Coverage and carried-index update.
      ICover(covTerm, term);
      ICover(covImm, boolean'pos(m = 0));
      ICover(covEoi, std_to_int(eoi));
      ICover(covIdx, carried);

      if (eoi = '1') then
        carried := 0;
      else
        carried := newIdx;
      end if;

    end procedure do_run;

    -- Idle (not run mode): outputs must be quiet, state must hold.
    procedure idle (
      cycles : natural
    ) is
    begin

      iModeIsRun <= '0';
      iRunHit    <= '0';
      iRunCont   <= '0';

      for i in 1 to cycles loop

        wait for 1 ns;
        AffirmIf(GetAlertLogID("DataChecks"), oRawValid = '0', "idle: oRawValid must be 0 outside run mode");
        wait until rising_edge(clk);

      end loop;

      iModeIsRun <= '1';

    end procedure idle;

    variable m    : natural;
    variable term : integer;
    variable eoi  : std_logic;

  begin

    rst        <= '0';
    iEoi       <= '0';
    iRunCnt    <= (others => '0');
    iRunHit    <= '0';
    iRunCont   <= '0';
    iModeIsRun <= '1';
    iIx        <= (others => '0');
    iRaPix     <= (others => '0');
    iRbPix     <= (others => '0');

    SetAlertLogName("tb_a15_a16_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    req := GetReqID("T87.A15-A16", 100);

    covTerm := NewID("terminal");
    SetFieldName(covTerm, "terminal");
    AddBins(covTerm, "interruption", GenBin(0));
    AddBins(covTerm, "end of line", GenBin(1));
    covImm := NewID("immediateBreak");
    SetFieldName(covImm, "immediateBreak");
    AddBins(covImm, "nonempty run", GenBin(0));
    AddBins(covImm, "immediate break", GenBin(1));
    covEoi := NewID("eoiReset");
    SetFieldName(covEoi, "eoiReset");
    AddBins(covEoi, "within image", GenBin(0));
    AddBins(covEoi, "end of image", GenBin(1));
    covIdx := NewID("startIdx");
    SetFieldName(covIdx, "startIdx");
    AddBins(covIdx, "startIdx0", GenBin(0, 0));
    AddBins(covIdx, "startIdxLo", GenBin(1, 3, 1));
    AddBins(covIdx, "startIdxMid", GenBin(4, 10, 1));
    AddBins(covIdx, "startIdxHi", GenBin(11, 31, 1));

    apply_reset(clk, rst, 4, '1');
    carried := 0;

    --------------------------------------------------------------------------
    -- Directed regressions (mirror the ad-hoc suite).
    --------------------------------------------------------------------------
    do_run(0, T_BREAK, '0', "immediate break");
    do_run(1, T_BREAK, '0', "1-pixel run break");
    do_run(4, T_BREAK, '0', "4-match break");
    do_run(5, T_EOL, '0', "5-match EOL");
    idle(3);
    do_run(2, T_BREAK, '1', "break on EOI");      -- resets carried to 0

    --------------------------------------------------------------------------
    -- Climb RUNindex with consecutive long EOL runs (no break/EOI).
    --------------------------------------------------------------------------
    for n in 1 to 6 loop

      do_run(800, T_EOL, '0', "climb EOL");

    end loop;

    --------------------------------------------------------------------------
    -- Saturate RUNindex at 31. The J table tail grows exponentially
    -- (J[24..31] = 8..15), so 800-pixel runs stall at index 26 (next segment
    -- 1024); reaching 31 takes one run past the 2^14 segment, and a boundary
    -- WHILE at 31 (second run, past 2^15) proves the index holds there
    -- instead of overflowing.
    --------------------------------------------------------------------------
    do_run(33100, T_EOL, '0', "saturate RUNindex to 31");
    do_run(40000, T_EOL, '0', "boundary at saturated RUNindex");
    do_run(3, T_BREAK, '0', "break from saturated RUNindex");
    wait for 1 ns;
    AffirmIfEqual(req, checked_integer(oRiRunIndex), 30,
                  "RUNindex decremented from saturation by the break");

    --------------------------------------------------------------------------
    -- Mid-operation iRst (distinct from the iEoi path): RUNindex is high after
    -- the climb; assert iRst and confirm the FSM goes cold (no spurious output,
    -- sInRun cleared) and the next run encodes from RUNindex=0 again -- the
    -- bitstream check with carried=0 proves the state register was cleared.
    --------------------------------------------------------------------------
    iModeIsRun <= '0';
    iRunHit    <= '0';
    iRunCont   <= '0';
    iEoi       <= '0';
    iCE <= '0';
    apply_reset(clk, rst, 4, '1');
    iCE <= '1';
    wait for 1 ns;
    AffirmIf(GetAlertLogID("ResetRecovery"), oRawValid = '0', "mid-op reset: no spurious raw output");
    AffirmIf(GetAlertLogID("ResetRecovery"), oInRunNext = '0', "mid-op reset: sInRun cleared");
    iModeIsRun <= '1';
    carried    := 0;
    do_run(3, T_BREAK, '0', "post-reset recovery");

    --------------------------------------------------------------------------
    -- Constrained-random runs.
    --------------------------------------------------------------------------
    for r in 1 to 400 loop

      term := rv.RandInt(0, 1);

      -- Mix of immediate breaks, small runs, and long runs.
      if (term = T_BREAK and rv.DistValInt(((1, 1), (0, 6))) = 1) then
        m := 0;
      elsif (rv.DistValInt(((1, 1), (0, 3))) = 1) then
        m := rv.RandInt(1, 1500);
      else
        m := rv.RandInt(1, 12);
      end if;

      if (term = T_EOL and m = 0) then
        m := 1;                          -- EOL needs at least one pixel
      end if;

      eoi := bool2bit(rv.DistValInt(((1, 1), (0, 9))) = 1);

      do_run(m, term, eoi, "rand run r=" & integer'image(r));

      if (rv.DistValInt(((1, 1), (0, 4))) = 1) then
        idle(rv.RandInt(1, 3));
      end if;

      exit when IsCovered(covTerm) and IsCovered(covImm) and
                IsCovered(covEoi) and IsCovered(covIdx) and r > 50;

    end loop;

    WriteBin(covTerm);
    WriteBin(covImm);
    WriteBin(covEoi);
    WriteBin(covIdx);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covTerm), "terminal coverage closed");
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covImm), "immediate-break coverage closed");
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covEoi), "EOI-reset coverage closed");
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covIdx), "start-RUNindex coverage closed");

    end_of_test("tb_a15_a16_osvvm");
    wait;

  end process stim;

  watchdog : process is
  begin

    wait for 50 ms;
    Alert(GetAlertLogID("Watchdog"), "tb_a15_a16_osvvm: watchdog timeout", FAILURE);
    std.env.stop;

  end process watchdog;

end architecture sim;
