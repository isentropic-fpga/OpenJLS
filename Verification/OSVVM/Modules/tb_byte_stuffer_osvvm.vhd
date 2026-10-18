-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_byte_stuffer_osvvm: byte_stuffer against a T.87 FF-stuffing bit-stream model
--
-- The residue is zero-padded after stuffing. iStall follows oAlmostFull plus
-- random stalls; stalling less would overrun the FIFO.
--
-- Guidelines:
--   G2.MinMax   N/A: bit packing, no arithmetic node
--   G2.Clamp    N/A: no accumulator
--   G3.Stim     N/A: payload random, FF runs in G4.Branch stuffEvent
--   G4 other    N/A: Edge/Run/Coding not in scope

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library osvvm;
  context osvvm.OsvvmContext;
  use osvvm.ScoreboardPkg_slv.all;

library work;
  use work.olo_base_pkg_math.log2ceil;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_byte_stuffer_osvvm is
  generic (
    IN_WIDTH : natural := CO_LIMIT_STD
  );
end entity tb_byte_stuffer_osvvm;

architecture sim of tb_byte_stuffer_osvvm is

  constant OUT_BYTES       : natural := 4;
  constant OUT_WIDTH       : natural := OUT_BYTES * 8;
  constant BURST_DEPTH     : natural := 16;
  constant VLEN_W          : natural := log2ceil(IN_WIDTH + 1);
  constant OBYTES_W        : natural := log2ceil(OUT_BYTES + 1);

  constant CLK_PERIOD      : time    := CLK_PERIOD_DEFAULT;
  constant N_RANDOM        : natural := 60;
  constant MAX_BEATS       : natural := 40;

  signal clk               : std_logic;
  signal rst               : std_logic;
  signal iStall            : std_logic;
  signal iWord             : std_logic_vector(IN_WIDTH - 1 downto 0);
  signal iWordValid        : std_logic;
  signal iWordValidLen     : unsigned(VLEN_W - 1 downto 0);
  signal iFlush            : std_logic;
  signal oWord             : std_logic_vector(OUT_WIDTH - 1 downto 0);
  signal oWordValid        : std_logic;
  signal oValidBytes       : unsigned(OBYTES_W - 1 downto 0);
  signal iReady            : std_logic;
  signal oAlmostFull       : std_logic;
  signal oFlushDone        : std_logic;

  constant SB_ID : ScoreboardIDType := NewID("byte_stuffer SB");
  shared variable covEmit  : CoverageIDType;
  shared variable covFlush : CoverageIDType;
  shared variable covCross : CoverageIDType;
  shared variable covStuff : CoverageIDType;
  shared variable covRst   : CoverageIDType;

  -- Stuff events per image. FF x prev-FF can't be crossed: the byte after a
  -- stuff has a '0' MSB.
  constant SE_NONE         : integer := 0;
  constant SE_FIRST        : integer := 1;
  constant SE_RUN          : integer := 2;

  signal sImagesSent       : natural;
  signal sFlushDone        : natural;
  signal sDriverDone       : boolean;

  signal sRandStall        : std_logic;

  -- Skip output of a reset-aborted image
  signal sIgnore           : boolean := false;

  constant FT_EMPTY        : integer := 0;
  constant FT_CLEAN        : integer := 1;
  constant FT_RESIDUE      : integer := 2;
  constant FT_DANGLING     : integer := 3;  -- trailing 0xFF -> stuffed 0x00 byte

begin

  clk_proc : process is
  begin

    clk <= '1';
    wait for CLK_PERIOD / 2;
    clk <= '0';
    wait for CLK_PERIOD / 2;

  end process clk_proc;

  dut : entity work.byte_stuffer(behavioral)
    generic map (
      IN_WIDTH            => IN_WIDTH,
      OUT_BYTES_PER_CYCLE => OUT_BYTES,
      OUT_WIDTH           => OUT_WIDTH,
      BURST_DEPTH         => BURST_DEPTH
    )
    port map (
      iClk                => clk,
      iRst                => rst,
      iStall              => iStall,
      iWord               => iWord,
      iWordValid          => iWordValid,
      iWordValidLen       => iWordValidLen,
      iFlush              => iFlush,
      oWord               => oWord,
      oWordValid          => oWordValid,
      oValidBytes         => oValidBytes,
      iReady              => iReady,
      oAlmostFull         => oAlmostFull,
      oFlushDone          => oFlushDone
    );

  -- Upstream stall ---
  -- Registered; the almost-full cushion absorbs the extra cycle
  stall_proc : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '1') then
        iStall <= '0';
      else
        iStall <= oAlmostFull or sRandStall;
      end if;
    end if;

  end process stall_proc;

  rand_stall_proc : process is

    variable rv : RandomPType;

  begin

    rv.InitSeed("stall");
    sRandStall <= '0';
    wait until rst = '0';

    loop

      wait until rising_edge(clk);
      -- ~20% extra stall
      if (rv.DistValInt(((1, 20), (0, 80))) = 1) then
        sRandStall <= '1';
      else
        sRandStall <= '0';
      end if;

      exit when sDriverDone;

    end loop;

    sRandStall <= '0';
    wait;

  end process rand_stall_proc;

  -- Downstream backpressure ---
  ready_proc : process is

    variable rv    : RandomPType;
    variable burst : integer;

  begin

    rv.InitSeed("ready");
    iReady <= '1';
    wait until rst = '0';

    loop

      wait until rising_edge(clk);
      -- 1 in 12: long not-ready burst to fill the FIFO
      if (rv.DistValInt(((1, 1), (0, 11))) = 1) then
        iReady <= '0';
        burst  := rv.RandInt(2, 2 * BURST_DEPTH);

        for i in 1 to burst loop

          wait until rising_edge(clk);
          exit when sDriverDone;

        end loop;

        iReady <= '1';
      elsif (rv.DistValInt(((1, 3), (0, 1))) = 1) then
        -- ~75% ready
        iReady <= '1';
      else
        iReady <= '0';
      end if;

      exit when sDriverDone;

    end loop;

    iReady <= '1';
    wait;

  end process ready_proc;

  -- Monitor ---
  -- A presented beat was already granted by an earlier iReady, so it is checked unconditionally
  monitor_proc : process is

    variable nb      : natural;
    variable byte    : std_logic_vector(7 downto 0);
    variable cnt     : natural;
    variable af      : integer;
    variable hasData : integer;
    variable req     : AlertLogIDType;

  begin

    -- Floor under the smallest variant
    req := GetReqID("OJLS.ByteStuffer", 2900);
    cnt := 0;
    wait until rst = '0';

    loop

      wait until rising_edge(clk);

      if (oWordValid = '1' and not sIgnore) then
        nb := checked_integer(oValidBytes);
        if (oAlmostFull = '1') then
          af := 1;
        else
          af := 0;
        end if;
        if (nb > 0) then
          hasData := 1;
        else
          hasData := 0;
        end if;
        ICover(covEmit, nb);
        ICover(covCross, (hasData, af));

        for i in 0 to nb - 1 loop

          byte := oWord(OUT_WIDTH - 1 - i * 8 downto OUT_WIDTH - (i + 1) * 8);
          AffirmIfEqual(req, byte, Pop(SB_ID), "stuffed byte");

        end loop;

      end if;

      if (oFlushDone = '1' and not sIgnore) then
        AffirmIf(GetAlertLogID("Protocol"), oWordValid = '1', "oFlushDone must coincide with oWordValid");
        cnt        := cnt + 1;
        sFlushDone <= cnt;
      end if;

      exit when sDriverDone and sFlushDone = sImagesSent and IsEmpty(SB_ID);

    end loop;

    wait;

  end process monitor_proc;

  -- Driver and reference model ---
  stim_proc : process is

    variable rv : RandomPType;

    constant ZERO_W : std_logic_vector(IN_WIDTH - 1 downto 0) := (others => '0');

    variable curByte    : std_logic_vector(7 downto 0);
    variable bitsInByte : natural range 0 to 8;
    variable anyBits    : boolean;
    variable lastEmitFF : boolean;
    variable realSince  : boolean;       -- real bit since last emit
    variable stuffSeen  : boolean;

    -- A '0' is stuffed after every completed 0xFF byte

    procedure push_bit (
      b : std_logic
    ) is
    begin

      curByte(7 - bitsInByte) := b;
      bitsInByte              := bitsInByte + 1;
      anyBits                 := true;
      realSince               := true;

      if (bitsInByte = 8) then
        Push(SB_ID, curByte);
        if (curByte = x"FF") then
          if (stuffSeen) then
            ICover(covStuff, SE_RUN);
          else
            ICover(covStuff, SE_FIRST);
          end if;
          stuffSeen  := true;
          lastEmitFF := true;
          realSince  := false;
          curByte    := (others => '0');
          bitsInByte := 1;
        else
          ICover(covStuff, SE_NONE);
          lastEmitFF := false;
          curByte    := (others => '0');
          bitsInByte := 0;
        end if;
      end if;

    end procedure push_bit;

    procedure push_word (
      w   : std_logic_vector;
      len : natural
    ) is
    begin

      for i in 0 to len - 1 loop

        push_bit(w(IN_WIDTH - 1 - i));

      end loop;

    end procedure push_word;

    procedure finish_image is

      variable ft : integer;

    begin

      if (not anyBits) then
        ft := FT_EMPTY;
      elsif (bitsInByte = 0) then
        ft := FT_CLEAN;
      elsif (bitsInByte = 1 and lastEmitFF and not realSince) then
        ft := FT_DANGLING;
      else
        ft := FT_RESIDUE;
      end if;

      if (bitsInByte > 0) then
        Push(SB_ID, curByte);                -- low bits already '0'
      end if;

      ICover(covFlush, ft);

      curByte    := (others => '0');
      bitsInByte := 0;
      anyBits    := false;
      lastEmitFF := false;
      realSince  := false;
      stuffSeen  := false;

    end procedure finish_image;

    -- Hold the beat until an edge with iStall = '0'

    procedure send_beat (
      w     : std_logic_vector;
      len   : natural;
      valid : std_logic;
      flush : std_logic
    ) is
    begin

      iWord         <= w;
      iWordValidLen <= to_unsigned(len, VLEN_W);
      iWordValid    <= valid;
      iFlush        <= flush;

      loop

        wait until rising_edge(clk);
        exit when iStall = '0';

      end loop;

      -- Append before flush, as the DUT does
      if (valid = '1') then
        push_word(w, len);
      end if;

      if (flush = '1') then
        finish_image;
      end if;

      iWordValid <= '0';
      iFlush     <= '0';

    end procedure send_beat;

    -- iFlush rides the last valid word, never an empty beat

    procedure send_image (
      beats : natural
    ) is

      variable w   : std_logic_vector(IN_WIDTH - 1 downto 0);
      variable len : natural;

    begin

      for n in 1 to beats loop

        -- ~30% all-ones words for stuff runs
        if (rv.DistValInt(((1, 3), (0, 7))) = 1) then
          w := (others => '1');
        else
          w := (others => '0');

          for k in 0 to IN_WIDTH / 8 - 1 loop

            if (rv.DistValInt(((1, 1), (0, 7))) = 1) then
              w(IN_WIDTH - 1 - k * 8 downto IN_WIDTH - (k + 1) * 8) := x"FF";
            else
              w(IN_WIDTH - 1 - k * 8 downto IN_WIDTH - (k + 1) * 8) := rv.RandSlv(0, 255, 8);
            end if;

          end loop;

        end if;

        len := rv.RandInt(1, IN_WIDTH);

        if (n = beats) then
          send_beat(w, len, '1', '1');
        else
          send_beat(w, len, '1', '0');
        end if;

      end loop;

      sImagesSent <= sImagesSent + 1;
      wait until sFlushDone = sImagesSent;

    end procedure send_image;

    procedure directed (
      w   : std_logic_vector(IN_WIDTH - 1 downto 0);
      len : natural
    ) is
    begin

      send_beat(w, len, '1', '1');
      sImagesSent <= sImagesSent + 1;
      wait until sFlushDone = sImagesSent;

    end procedure directed;

    -- n full beats (flush on the last if flush = '1'), then iRst; the output is unscored
    procedure reset_mid (
      n     : natural;
      flush : std_logic
    ) is
    begin

      sIgnore <= true;

      for k in 1 to n loop

        iWord         <= rv.RandSlv(IN_WIDTH);
        iWordValidLen <= to_unsigned(IN_WIDTH, VLEN_W);
        iWordValid    <= '1';
        if (k = n) then
          iFlush <= flush;
        else
          iFlush <= '0';
        end if;

        loop

          wait until rising_edge(clk);
          exit when iStall = '0';

        end loop;

      end loop;

      iWordValid <= '0';
      iFlush     <= '0';
      if (n = 0) then
        ICover(covRst, 0);
      else
        ICover(covRst, 1 + std_to_int(flush));
      end if;
      apply_reset(clk, rst, 6, '1');
      wait for 1 ns;
      AffirmIf(GetAlertLogID("ResetRecovery"), oWordValid = '0', "mid-op reset: byte_stuffer output cleared");
      AffirmIf(GetAlertLogID("ResetRecovery"), oFlushDone = '0', "mid-op reset: no flush-done after reset");

      curByte    := (others => '0');
      bitsInByte := 0;
      anyBits    := false;
      lastEmitFF := false;
      realSince  := false;
      stuffSeen  := false;

      sIgnore <= false;
      wait until rising_edge(clk);

      send_image(rv.RandInt(1, MAX_BEATS));

    end procedure reset_mid;

    variable ones : std_logic_vector(IN_WIDTH - 1 downto 0);
    variable wtmp : std_logic_vector(IN_WIDTH - 1 downto 0);

  begin

    iWord         <= ZERO_W;
    iWordValid    <= '0';
    iWordValidLen <= (others => '0');
    iFlush        <= '0';

    curByte    := (others => '0');
    bitsInByte := 0;
    anyBits    := false;
    lastEmitFF := false;
    realSince  := false;
    stuffSeen  := false;

    SetAlertLogName("tb_byte_stuffer_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);

    covEmit := NewID("G4.Stream emitBytes");
    SetFieldName(covEmit, "emitBytes");
    for count in 0 to OUT_BYTES loop
      AddBins(covEmit, "emitted bytes=" & to_string(count), GenBin(count));
    end loop;
    -- FT_EMPTY is unreachable (see below)
    covFlush := NewID("G4.Stream flushType");
    SetFieldName(covFlush, "flushType");
    AddBins(covFlush, "byte aligned", GenBin(1));
    AddBins(covFlush, "padded residue", GenBin(2));
    AddBins(covFlush, "dangling FF", GenBin(3));
    -- No 0-byte bin: the terminal beat only fires once the FIFO has drained
    covCross := NewID("G4.Stream data x almostFull");
    SetFieldName(covCross, "data", "almostFull");
    for almost_full in 0 to 1 loop
      AddCross(covCross, "data beat / almostFull=" & to_string(almost_full),
               GenBin(1), GenBin(almost_full));
    end loop;
    covStuff := NewID("G4.Branch stuffEvent");
    SetFieldName(covStuff, "stuffEvent");
    AddBins(covStuff, "noStuff",    GenBin(SE_NONE, SE_NONE));
    AddBins(covStuff, "firstStuff", GenBin(SE_FIRST, SE_FIRST));
    AddBins(covStuff, "runStuff",   GenBin(SE_RUN, SE_RUN));

    covRst := NewID("G5.States resetPhase");
    AddBins(covRst, "idle", GenBin(0));
    AddBins(covRst, "mid-image", GenBin(1));
    AddBins(covRst, "flush draining", GenBin(2));

    apply_reset(clk, rst, 6, '1');
    ones := (others => '1');

    -- Directed ---
    -- No empty flush: every word carries >= 1 bit (Golomb stop bit, raw suffix
    -- len >= 1) and the flush rides the last word
    wtmp                                   := (others => '0');
    wtmp(IN_WIDTH - 1 downto IN_WIDTH - 8) := x"5A";
    directed(wtmp, 8);

    wtmp                                   := (others => '0');
    wtmp(IN_WIDTH - 1 downto IN_WIDTH - 8) := x"FF";
    directed(wtmp, 8);

    wtmp                                   := (others => '0');
    wtmp(IN_WIDTH - 1 downto IN_WIDTH - 5) := "10101";
    directed(wtmp, 5);

    for len in 1 to IN_WIDTH loop
      directed(ones, len);
      directed(ZERO_W, len);
    end loop;
    send_beat(ones, IN_WIDTH, '0', '0'); -- invalid beat must not enter the stream
    directed(ZERO_W, 8);

    -- Consecutive stuffs across the 4-slot chain
    directed(ones, IN_WIDTH);

    -- Multi-word flush on a partial beat (valid-bits overflow regression)
    send_beat(ones, IN_WIDTH, '1', '0');
    send_beat(ones, IN_WIDTH, '1', '0');
    wtmp                                    := (others => '0');
    wtmp(IN_WIDTH - 1 downto IN_WIDTH - 12) := x"FF" & "0101";
    directed(wtmp, 12);

    -- Back-to-back tiny images
    for n in 1 to 4 loop

      wtmp                                   := (others => '0');
      wtmp(IN_WIDTH - 1 downto IN_WIDTH - 8) := std_logic_vector(to_unsigned(n * 32, 8));
      directed(wtmp, 8);

    end loop;

    -- Random ---
    for img in 1 to N_RANDOM loop

      send_image(rv.RandInt(1, MAX_BEATS));

    end loop;

    -- Mid-op reset: mid-image, idle, flush draining ---
    reset_mid(4, '0');
    reset_mid(0, '0');
    reset_mid(4, '1');

    sDriverDone <= true;
    wait for 10 * CLK_PERIOD;

    AffirmIf(GetAlertLogID("ScoreboardCompletion"), IsEmpty(SB_ID), "scoreboard drained (all expected bytes consumed)");
    AffirmIfEqual(GetAlertLogID("ScoreboardCompletion"), GetErrorCount(SB_ID), 0, "scoreboard mismatches");

    WriteBin(covEmit);
    WriteBin(covFlush);
    WriteBin(covCross);
    WriteBin(covStuff);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covEmit), "emitBytes coverage closed");
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covFlush), "flushType coverage closed");
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covCross), "data x almostFull coverage closed");
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covStuff), "stuff-event coverage closed");
    affirm_covered(covRst, "reset phase coverage closed");

    end_of_test("tb_byte_stuffer_osvvm");
    wait;

  end process stim_proc;
  watchdog_proc : process is
  begin

    wait for 20 ms;
    Alert(GetAlertLogID("Watchdog"), "tb_byte_stuffer_osvvm: watchdog timeout", FAILURE);
    std.env.stop;

  end process watchdog_proc;

end architecture sim;
