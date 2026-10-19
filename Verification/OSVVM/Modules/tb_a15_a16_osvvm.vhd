-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_a15_a16_osvvm: a15_a16_encode_run against the T.87 A.15/A.16 C code
--
-- The RTL emits run bits incrementally; the TB collects a whole run and
-- compares it against the burst the C code writes.
--
-- Guidelines:
--   G3.Stim     N/A: inputs are run events, no signed source
--   G4 other    N/A: Edge/Coding/Stream not in scope

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

  -- Append nbits of val, MSB first
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

  -- T.87 A.15/A.16 for one run
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

    -- A.15
    loop

      step := 2 ** TB_J_TABLE(ri);
      exit when cnt < step;
      app(buf, len, 1, 1);
      cnt := cnt - step;
      if (ri < 31) then
        ri := ri + 1;
      end if;

    end loop;

    -- A.16
    if (term = T_BREAK) then
      -- '0' + J-bit residual = cnt in J + 1 bits
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
    variable cl      : CoverageIDType;
    variable covCnt  : CoverageIDType;
    variable rs      : CoverageIDType;
    variable req     : AlertLogIDType;

    variable actBuf  : string(1 to MAXBITS);
    variable actLen  : natural;
    variable expBuf  : string(1 to MAXBITS);
    variable expLen  : natural;
    variable carried : natural;       -- RUNindex across runs
    variable newIdx  : natural;
    variable riFires : boolean;

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

    procedure do_run (
      m    : natural;
      term : integer;
      eoi  : std_logic;
      msg  : string
    ) is

      variable nMatch : natural;
      variable terminalIdx : natural;
      variable residual : natural;
      variable sat : boolean := false;

    begin

      gen_expected(carried, m, term, expBuf, expLen, newIdx, riFires);
      actLen := 0;
      terminalIdx := carried;
      residual := m;
      while residual >= 2 ** TB_J_TABLE(terminalIdx) loop
        residual := residual - 2 ** TB_J_TABLE(terminalIdx);
        sat := sat or terminalIdx = 31;
        if terminalIdx < 31 then
          terminalIdx := terminalIdx + 1;
        end if;
      end loop;

      if (term = T_BREAK) then
        nMatch := m;
      else
        nMatch := m - 1;                 -- EOL: the last pixel is the terminal
      end if;

      for i in 1 to nMatch loop

        cycle_collect('1', '1', i, RUNVAL, RUNVAL, '0');
        wait until rising_edge(clk);

      end loop;

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

      AffirmIfEqual(req, actLen, expLen, msg & " bit-length");
      if (actLen = expLen) then
        AffirmIfEqual(req, actBuf(1 to actLen), expBuf(1 to expLen), msg & " bitstream");
      end if;

      ICover(covTerm, term);
      ICover(covImm, boolean'pos(m = 0));
      ICover(covEoi, std_to_int(eoi));
      ICover(covIdx, carried);
      ICover(covCnt, m);
      if sat then
        ICover(cl, 1);
      end if;
      if term = T_BREAK and terminalIdx = 31 then
        ICover(cl, 2);
      end if;

      if (eoi = '1') then
        carried := 0;
      else
        carried := newIdx;
      end if;

    end procedure do_run;

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

    -- iRst after n matches (0 = between runs); the next run starts from RUNindex 0
    procedure reset_mid (n : natural) is
    begin

      for i in 1 to n loop
        cycle_collect('1', '1', i, RUNVAL, RUNVAL, '0');
        wait until rising_edge(clk);
      end loop;
      iModeIsRun <= '0';
      iRunHit    <= '0';
      iRunCont   <= '0';
      iEoi       <= '0';
      iCE <= '0';
      ICover(rs, boolean'pos(n > 0));
      apply_reset(clk, rst, 4, '1');
      iCE <= '1';
      wait for 1 ns;
      AffirmIf(GetAlertLogID("ResetRecovery"), oRawValid = '0', "mid-op reset: no spurious raw output");
      AffirmIf(GetAlertLogID("ResetRecovery"), oInRunNext = '0', "mid-op reset: sInRun cleared");
      iModeIsRun <= '1';
      carried    := 0;
      do_run(3, T_BREAK, '0', "post-reset recovery");

    end procedure reset_mid;

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

    covTerm := NewID("G4.Run terminal");
    SetFieldName(covTerm, "terminal");
    AddBins(covTerm, "interruption", GenBin(0));
    AddBins(covTerm, "end of line", GenBin(1));
    covImm := NewID("G4.Run immediateBreak");
    SetFieldName(covImm, "immediateBreak");
    AddBins(covImm, "nonempty run", GenBin(0));
    AddBins(covImm, "immediate break", GenBin(1));
    covEoi := NewID("G4.Run eoiReset");
    SetFieldName(covEoi, "eoiReset");
    AddBins(covEoi, "within image", GenBin(0));
    AddBins(covEoi, "end of image", GenBin(1));
    covIdx := NewID("G4.Run G2.MinMax startIdx");
    SetFieldName(covIdx, "startIdx");
    AddBins(covIdx, "startIdx0", GenBin(0, 0));
    AddBins(covIdx, "startIdxLo", GenBin(1, 3, 1));
    AddBins(covIdx, "startIdxMid", GenBin(4, 10, 1));
    AddBins(covIdx, "startIdxHi", GenBin(11, 30, 1));
    AddBins(covIdx, "startIdx31", GenBin(31, 31));
    cl := NewID("G2.Clamp G2.MinMax RUNindex");
    SetFieldName(cl, "RUNindex");
    AddBins(cl, "RUNindex=31 / increment held", GenBin(1));
    AddBins(cl, "RUNindex=31 / break decrements", GenBin(2));

    covCnt := NewID("G2.MinMax G3.Stim RUNcnt");
    AddBins(covCnt, "RUNcnt=0", GenBin(0));
    AddBins(covCnt, "RUNcnt=2^RC_W-1 (MSB set)", GenBin(2 ** RC_W - 1));

    rs := NewID("G5.States resetPhase");
    AddBins(rs, "between runs", GenBin(0));
    AddBins(rs, "mid-run", GenBin(1));

    apply_reset(clk, rst, 4, '1');
    carried := 0;

    -- Directed ---
    do_run(0, T_BREAK, '0', "immediate break");
    do_run(1, T_BREAK, '0', "1-pixel run break");
    do_run(4, T_BREAK, '0', "4-match break");
    do_run(5, T_EOL, '0', "5-match EOL");
    idle(3);
    do_run(2, T_BREAK, '1', "break on EOI");

    -- Climb RUNindex with long EOL runs ---
    for n in 1 to 6 loop

      do_run(800, T_EOL, '0', "climb EOL");

    end loop;

    -- Saturate RUNindex ---
    -- 800-pixel runs stall at index 26; 33100 reaches 31, 40000 then crosses a
    -- segment boundary at 31
    do_run(33100, T_EOL, '0', "saturate RUNindex to 31");
    do_run(40000, T_EOL, '0', "boundary at saturated RUNindex");
    do_run(2 ** RC_W - 1, T_EOL, '0', "longest run RUNcnt can count");
    do_run(3, T_BREAK, '0', "break from saturated RUNindex");
    wait for 1 ns;
    AffirmIfEqual(req, checked_integer(oRiRunIndex), 30,
                  "RUNindex decremented from saturation by the break");

    -- Mid-op reset ---
    reset_mid(0);
    do_run(800, T_EOL, '0', "climb before mid-run reset");
    reset_mid(40);

    -- Random ---
    for r in 1 to 400 loop

      term := rv.RandInt(0, 1);

      if (term = T_BREAK and rv.DistValInt(((1, 1), (0, 6))) = 1) then
        m := 0;
      elsif (rv.DistValInt(((1, 1), (0, 3))) = 1) then
        m := rv.RandInt(1, 1500);
      else
        m := rv.RandInt(1, 12);
      end if;

      if (term = T_EOL and m = 0) then
        m := 1;
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
    affirm_covered(cl, "RUNindex saturation and step past covered");
    affirm_covered(covCnt, "RUNcnt min/max covered");
    affirm_covered(rs, "reset phase coverage closed");
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
