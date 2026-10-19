-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_jls_framer_osvvm: jls_framer against an independent T.87 frame model
--
-- Guidelines:
--   G2.MinMax   N/A: byte framing, no arithmetic node
--   G2.Clamp    N/A: no accumulator
--   G3.Stim     N/A: payload random bytes
--   G4 other    N/A: Edge/Run/Coding not in scope
--   G6.Code     N/A: get_header_byte "when others", the index stays below the header length

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library work;
  use work.olo_base_pkg_math.log2ceil;

library osvvm;
  context osvvm.OsvvmContext;
  use osvvm.ScoreboardPkg_slv.all;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_jls_framer_osvvm is
  generic (
    OUT_WIDTH : natural  := CO_OUT_WIDTH_STD;
    MAX_W     : positive := 4096;
    MAX_H     : positive := 4096
  );
end entity tb_jls_framer_osvvm;

architecture sim of tb_jls_framer_osvvm is

  constant BITNESS    : natural := CO_BITNESS_STD;
  constant IN_WIDTH   : natural := CO_BYTE_STUFFER_OUT_WIDTH;
  constant BYTES_IN   : natural := IN_WIDTH / 8;
  constant BYTES_OUT  : natural := OUT_WIDTH / 8;
  constant WDIM       : natural := log2ceil(MAX_W + 1);
  constant HDIM       : natural := log2ceil(MAX_H + 1);
  constant BE_IN_W    : natural := log2ceil(IN_WIDTH / 8 + 1);
  constant BE_OUT_W   : natural := log2ceil(OUT_WIDTH / 8 + 1);
  constant CLK_PERIOD : time    := CLK_PERIOD_DEFAULT;
  constant N_IMAGES   : natural := 30;
  -- Wide OUT_WIDTHs need payload past the header's last-beat fill
  constant MAX_WORDS  : natural := math_max(24, 2 * BYTES_OUT);

  signal clk      : std_logic := '0';
  signal rst      : std_logic;
  signal iStart   : std_logic;
  signal iWidth   : unsigned(WDIM - 1 downto 0);
  signal iHeight  : unsigned(HDIM - 1 downto 0);
  signal iEoi     : std_logic;
  signal iWord    : std_logic_vector(IN_WIDTH - 1 downto 0);
  signal iValid   : std_logic;
  signal iByteEn  : unsigned(BE_IN_W - 1 downto 0);
  signal oReady   : std_logic;
  signal oWord    : std_logic_vector(OUT_WIDTH - 1 downto 0);
  signal oValid   : std_logic;
  signal oByteEn  : unsigned(BE_OUT_W - 1 downto 0);
  signal oLast    : std_logic;
  signal iReady   : std_logic;

  constant SB_ID : ScoreboardIDType := NewID("framer SB");
  signal sImagesSent       : natural;
  signal sImagesDone       : natural;
  signal sDriverDone       : boolean;
  -- Skip output of a reset-aborted image
  signal sIgnore           : boolean := false;

  -- T.87 frame header, independent of the RTL ROM
  function header_byte (
    idx : natural;
    w   : natural;
    h   : natural
  ) return std_logic_vector is
  begin

    case idx is

      when 0  => return x"FF";                                           -- SOI
      when 1  => return x"D8";
      when 2  => return x"FF";                                           -- SOF55
      when 3  => return x"F7";
      when 4  => return x"00";                                           -- Lf = 11
      when 5  => return x"0B";
      when 6  => return std_logic_vector(to_unsigned(BITNESS, 8));       -- P
      when 7  => return std_logic_vector(to_unsigned(h / 256, 8));       -- Y hi
      when 8  => return std_logic_vector(to_unsigned(h mod 256, 8));     -- Y lo
      when 9  => return std_logic_vector(to_unsigned(w / 256, 8));       -- X hi
      when 10 => return std_logic_vector(to_unsigned(w mod 256, 8));     -- X lo
      when 11 => return x"01";                                           -- Nf
      when 12 => return x"01";                                           -- C1
      when 13 => return x"11";                                           -- H1V1
      when 14 => return x"00";                                           -- Tq1
      when 15 => return x"FF";                                           -- SOS
      when 16 => return x"DA";
      when 17 => return x"00";                                           -- Ls = 8
      when 18 => return x"08";
      when 19 => return x"01";                                           -- Ns
      when 20 => return x"01";                                           -- Cs1
      when 21 => return x"00";                                           -- Tm1
      when 22 => return x"00";                                           -- NEAR
      when 23 => return x"00";                                           -- ILV
      when others => return x"00";                                       -- Al/Ah
    end case;

  end function header_byte;

begin

  clk_proc : process is
  begin

    clk <= '1';
    wait for CLK_PERIOD / 2;
    clk <= '0';
    wait for CLK_PERIOD / 2;

  end process clk_proc;

  dut : entity work.jls_framer(behavioral)
    generic map (
      BITNESS          => BITNESS,
      IN_WIDTH         => IN_WIDTH,
      OUT_WIDTH        => OUT_WIDTH,
      MAX_IMAGE_WIDTH  => MAX_W,
      MAX_IMAGE_HEIGHT => MAX_H
    )
    port map (
      iClk         => clk,
      iRst         => rst,
      iStart       => iStart,
      iImageWidth  => iWidth,
      iImageHeight => iHeight,
      iEoi         => iEoi,
      iWord        => iWord,
      iValid       => iValid,
      iByteEnable  => iByteEn,
      oReady       => oReady,
      oWord        => oWord,
      oValid       => oValid,
      oByteEnable  => oByteEn,
      oLast        => oLast,
      iReady       => iReady
    );

  -- Driver ---
  driver : process is

    variable rv   : RandomPType;
    variable rs   : CoverageIDType;
    variable sent : natural := 0;

    procedure push_word (
      wd    : std_logic_vector(IN_WIDTH - 1 downto 0);
      nbe   : natural;
      eoi   : std_logic;
      start : std_logic
    ) is
    begin

      loop

        wait until rising_edge(clk);
        wait for 1 ns;
        exit when oReady = '1';

      end loop;

      iValid  <= '1';
      iWord   <= wd;
      iByteEn <= to_unsigned(nbe, BE_IN_W);
      iEoi    <= eoi;
      iStart  <= start;
      wait until rising_edge(clk);
      iValid  <= '0';
      iEoi    <= '0';
      iStart  <= '0';

    end procedure push_word;

    procedure send_image (
      w      : natural;
      h      : natural;
      nWords : natural
    ) is

      variable word : std_logic_vector(IN_WIDTH - 1 downto 0);
      variable be   : natural;

    begin

      iWidth  <= to_unsigned(w, WDIM);
      iHeight <= to_unsigned(h, HDIM);
      wait until rising_edge(clk);

      for k in 0 to 24 loop

        Push(SB_ID, '0' & header_byte(k, w, h));

      end loop;

      for n in 1 to nWords loop

        word := rv.RandSlv(IN_WIDTH);

        if (n = nWords) then
          be := rv.RandInt(0, BYTES_IN);
        else
          be := rv.RandInt(1, BYTES_IN);
        end if;

        for i in 0 to be - 1 loop

          Push(SB_ID, '0' & word(IN_WIDTH - 1 - i * 8 downto IN_WIDTH - (i + 1) * 8));

        end loop;

        if (n = nWords) then
          Push(SB_ID, '0' & x"FF");
          Push(SB_ID, '1' & x"D9");
          push_word(word, be, '1', bool2bit(n = 1));
        else
          push_word(word, be, '0', bool2bit(n = 1));
        end if;

      end loop;

    end procedure send_image;

    -- n words (iEoi on the last if eoi = '1'), then iRst; the output is unscored
    procedure reset_mid (
      n   : natural;
      eoi : std_logic
    ) is
    begin

      sIgnore <= true;
      iWidth  <= to_unsigned(64, WDIM);
      iHeight <= to_unsigned(64, HDIM);
      for k in 1 to n loop
        push_word(rv.RandSlv(IN_WIDTH), 4, eoi and bool2bit(k = n), bool2bit(k = 1));
      end loop;
      if (n = 0) then
        ICover(rs, 0);
      elsif (eoi = '1') then
        ICover(rs, 3);
      elsif (n = 1) then
        ICover(rs, 1);
      else
        ICover(rs, 2);
      end if;
      apply_reset(clk, rst, 4, '1');
      wait for 1 ns;
      AffirmIf(GetAlertLogID("ResetRecovery"), oValid = '0', "mid-op reset: framer output idle after iRst");
      sIgnore <= false;
      wait until rising_edge(clk);

      send_image(rv.RandInt(4, MAX_W), rv.RandInt(1, MAX_H), rv.RandInt(1, MAX_WORDS));
      sent        := sent + 1;
      sImagesSent <= sent;
      wait until sImagesDone = sent;

    end procedure reset_mid;

  begin

    rst      <= '0';
    iStart   <= '0';
    iWidth   <= to_unsigned(8, WDIM);
    iHeight  <= to_unsigned(8, HDIM);
    iEoi     <= '0';
    iWord    <= (others => '0');
    iValid   <= '0';
    iByteEn  <= (others => '0');

    SetAlertLogName("tb_jls_framer_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);

    rs := NewID("G5.States resetPhase");
    AddBins(rs, "idle", GenBin(0));
    AddBins(rs, "start word", GenBin(1));
    AddBins(rs, "payload", GenBin(2));
    AddBins(rs, "EOI pending", GenBin(3));

    apply_reset(clk, rst, 4, '1');

    for img in 1 to N_IMAGES loop

      send_image(rv.RandInt(4, MAX_W), rv.RandInt(1, MAX_H), rv.RandInt(1, MAX_WORDS));
      sent        := sent + 1;
      sImagesSent <= sent;
      -- Drain before the next image so dims stay coherent
      wait until sImagesDone = sent;

    end loop;

    -- Mid-op reset: after start, idle, mid-payload, EOI pending ---
    reset_mid(1, '0');
    reset_mid(0, '0');
    reset_mid(12, '0');
    reset_mid(6, '1');

    -- Two back-to-back empty images ---
    -- Both EOIs queue while A's header drains: fills the EOI FIFO and takes both
    -- terminal FSM arms
    for img in 1 to 2 loop

      for k in 0 to 24 loop

        Push(SB_ID, '0' & header_byte(k, 16, 1));

      end loop;

      Push(SB_ID, '0' & x"FF");
      Push(SB_ID, '1' & x"D9");

    end loop;

    iWidth  <= to_unsigned(16, WDIM);
    iHeight <= to_unsigned(1, HDIM);
    push_word(rv.RandSlv(IN_WIDTH), 0, '1', '1');
    push_word(rv.RandSlv(IN_WIDTH), 0, '1', '1');
    sent        := sent + 2;
    sImagesSent <= sent;
    wait until sImagesDone = sent;

    affirm_covered(rs, "reset phase coverage closed");
    sDriverDone <= true;
    wait;

  end process driver;

  -- Monitor ---
  monitor : process is

    variable rv      : RandomPType;
    variable nb      : natural;
    variable byte    : std_logic_vector(7 downto 0);
    variable lastByte : std_logic_vector(7 downto 0);
    variable done    : natural;
    variable covBeat : CoverageIDType;
    variable req     : AlertLogIDType;

  begin

    iReady <= '1';
    done   := 0;
    -- Floor under the smallest variant
    req := GetReqID("OJLS.Framer", 1600);
    covBeat := NewID("G4.Stream partialBeat");
    SetFieldName(covBeat, "partialBeat");
    AddBins(covBeat, "partialBeat", GenBin(1, BYTES_OUT - 1, 1));
    AddBins(covBeat, "fullBeat", GenBin(BYTES_OUT, BYTES_OUT));
    rv.InitSeed(rv'instance_name);
    wait until rst = '0';

    loop

      -- ~80% ready
      iReady <= bool2bit(rv.DistValInt(((1, 4), (0, 1))) = 1);
      wait for 1 ns;

      if (oValid = '1' and iReady = '1' and not sIgnore) then
        nb := checked_integer(oByteEn);
        AffirmIf(GetAlertLogID("Protocol"), nb >= 1 and nb <= BYTES_OUT, "valid beat has legal byte count");
        ICover(covBeat, nb);

        for i in 0 to nb - 1 loop

          byte     := oWord(OUT_WIDTH - 1 - i * 8 downto OUT_WIDTH - (i + 1) * 8);
          lastByte := byte;
          AffirmIfEqual(req, bool2bit(oLast = '1' and i = nb - 1) & byte, Pop(SB_ID), "framed byte");

        end loop;

        if (oLast = '1') then
          AffirmIfEqual(GetAlertLogID("Protocol"), lastByte, std_logic_vector'(x"D9"), "oLast must land on the 0xD9 footer byte");
          done        := done + 1;
          sImagesDone <= done;
        end if;
      end if;

      wait until rising_edge(clk);

      exit when sDriverDone and done = sImagesSent and IsEmpty(SB_ID);

    end loop;

    AffirmIf(GetAlertLogID("ScoreboardCompletion"), IsEmpty(SB_ID), "scoreboard drained");
    AffirmIfEqual(GetAlertLogID("ScoreboardCompletion"), GetErrorCount(SB_ID), 0, "scoreboard mismatches");
    WriteBin(covBeat);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covBeat), "output beat-size coverage closed");

    end_of_test("tb_jls_framer_osvvm");
    wait;

  end process monitor;

  -- The pending beat, metadata included, holds across backpressure
  hold_monitor : process(clk) is
    variable held : boolean := false;
    variable word : std_logic_vector(oWord'range);
    variable count : unsigned(oByteEn'range);
    variable last : std_logic;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        held := false;
      else
        if held then
          AffirmIf(GetAlertLogID("OutputHold"), oValid = '1', "valid held until accepted");
          AffirmIfEqual(GetAlertLogID("OutputHold"), oWord, word, "data held until accepted");
          AffirmIfEqual(GetAlertLogID("OutputHold"), oByteEn, count, "byte count held until accepted");
          AffirmIfEqual(GetAlertLogID("OutputHold"), oLast, last, "last held until accepted");
        end if;
        held := oValid = '1' and iReady = '0';
        word := oWord;
        count := oByteEn;
        last := oLast;
      end if;
    end if;
  end process;

  watchdog : process is
  begin

    wait for 100 ms;
    Alert(GetAlertLogID("Watchdog"), "tb_jls_framer_osvvm: watchdog timeout", FAILURE);
    std.env.stop;

  end process watchdog;

end architecture sim;
