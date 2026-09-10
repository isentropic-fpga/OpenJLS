-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: byte_stuffer
--
-- First stateful-module OSVVM TB and the template for the rest. It settles the
-- stateful pattern the combinational tb_a11 template can't show:
--
--   * reference-as-process: an independent bit-stream FF-stuffer model that
--     turns the accepted input bits into the expected output byte stream
--     (T.87: a '0' bit is stuffed after every 0xFF byte; the final sub-byte
--     residue is zero-padded *after* stuffing, matching the DUT contract);
--   * osvvm.ScoreboardPkg_slv as the order-checking oracle (expected bytes
--     pushed by the driver, popped/checked by the output monitor);
--   * randomized handshake on BOTH sides — iReady (downstream backpressure)
--     and iStall (upstream stall) — which is exactly the coverage the golden
--     suite stopped exercising (see project-backpressure-coverage-gap);
--   * directed corners seeded from already-fixed bugs (multi-word flush,
--     post-stuffing residue pad, skid latch) plus the EOI terminal variants.
--
-- iStall is forced high whenever oAlmostFull is high (the real top-level stall
-- contract) and additionally asserted at random — stalling more is always safe,
-- stalling less would overrun the FIFO and trip the DUT's own write-drop assert.
--
-- IN_WIDTH is a generic (= byte_stuffer LIMIT). Defaults to CO_LIMIT_STD (48,
-- the 12-bit config); OpenJls.pro re-runs it at 32 and 64 (the 8-/16-bit
-- LIMITs) via [generic IN_WIDTH ...].
--------------------------------------------------------------------------------

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

  -- DUT config -----------------------------------------------------------------
  constant OUT_BYTES       : natural := 4;
  constant OUT_WIDTH       : natural := OUT_BYTES * 8;
  constant BURST_DEPTH     : natural := 16;
  constant VLEN_W          : natural := log2ceil(IN_WIDTH + 1);
  constant OBYTES_W        : natural := log2ceil(OUT_BYTES + 1);

  -- Stimulus sizing
  constant CLK_PERIOD      : time    := CLK_PERIOD_DEFAULT;
  constant N_RANDOM        : natural := 60; -- random images
  constant MAX_BEATS       : natural := 40; -- beats per random image

  -- DUT interface --------------------------------------------------------------
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

  -- TB plumbing ----------------------------------------------------------------
  -- Expected output bytes, pushed in emission order by the driver model.
  constant SB_ID : ScoreboardIDType := NewID("byte_stuffer SB");
  -- Coverage.
  shared variable covEmit  : CoverageIDType;      -- bytes emitted per accepted beat (0..4)
  shared variable covFlush : CoverageIDType;      -- flush terminal type (0..3)
  shared variable covCross : CoverageIDType;      -- (emitBytes>0) x (oAlmostFull)
  shared variable covStuff : CoverageIDType;      -- stuff event per emitted byte (none/first/run)

  -- Stuff-event codes (the module's headline behaviour: a '0' is stuffed after
  -- every 0xFF payload byte). (this-byte-FF x prev-byte-FF) would have an
  -- unreachable cell -- the byte after a stuff carries the stuff bit as its MSB
  -- so it can never itself be 0xFF -- so the reachable axis is per-image run
  -- count: an image with no stuff, its first stuff, and a subsequent (run) stuff.
  constant SE_NONE         : integer := 0;  -- emitted byte != 0xFF, no stuff
  constant SE_FIRST        : integer := 1;  -- first 0xFF (stuff) of the image
  constant SE_RUN          : integer := 2;  -- a later 0xFF (stuff) in the same image

  -- Driver -> monitor image handshake.
  signal sImagesSent       : natural;       -- flushes presented by the driver
  signal sFlushDone        : natural;       -- oFlushDone beats seen by the monitor
  signal sDriverDone       : boolean;

  -- Random upstream-stall enable (ORed with oAlmostFull, driven by stall proc).
  signal sRandStall        : std_logic;

  -- Monitor ignores output during a reset-aborted (mid-image) sequence.
  signal sIgnore           : boolean := false;

  -- Flush-type codes (coverage + sanity).
  constant FT_EMPTY        : integer := 0;  -- flush with no payload bits
  constant FT_CLEAN        : integer := 1;  -- byte-aligned, no residue
  constant FT_RESIDUE      : integer := 2;  -- sub-byte real residue padded
  constant FT_DANGLING     : integer := 3;  -- trailing 0xFF -> stuffed 0x00 byte

begin

  -----------------------------------------------------------------------------
  -- Clock
  -----------------------------------------------------------------------------
  clk_proc : process is
  begin

    clk <= '1';
    wait for CLK_PERIOD / 2;
    clk <= '0';
    wait for CLK_PERIOD / 2;

  end process clk_proc;

  -----------------------------------------------------------------------------
  -- DUT
  -----------------------------------------------------------------------------
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

  -----------------------------------------------------------------------------
  -- Upstream stall: ALWAYS stall when the FIFO is almost full (the real
  -- top-level contract), plus extra random stalls for coverage. Registered,
  -- which the AlmFull cushion is sized to tolerate.
  -----------------------------------------------------------------------------
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
      -- ~20% extra upstream stall.
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

  -----------------------------------------------------------------------------
  -- Downstream backpressure: weighted-random iReady, with occasional long
  -- not-ready bursts to fill the FIFO and exercise oAlmostFull / iStall.
  -----------------------------------------------------------------------------
  ready_proc : process is

    variable rv    : RandomPType;
    variable burst : integer;

  begin

    rv.InitSeed("ready");
    iReady <= '1';
    wait until rst = '0';

    loop

      wait until rising_edge(clk);
      -- 1-in-12 cycles, hold not-ready for a multi-cycle burst.
      if (rv.DistValInt(((1, 1), (0, 11))) = 1) then
        iReady <= '0';
        burst  := rv.RandInt(2, 2 * BURST_DEPTH);

        for i in 1 to burst loop

          wait until rising_edge(clk);
          exit when sDriverDone;

        end loop;

        iReady <= '1';
      elsif (rv.DistValInt(((1, 3), (0, 1))) = 1) then
        -- ~75% ready otherwise.
        iReady <= '1';
      else
        iReady <= '0';
      end if;

      exit when sDriverDone;

    end loop;

    iReady <= '1';
    wait;

  end process ready_proc;

  -----------------------------------------------------------------------------
  -- Output monitor: every cycle a beat is presented (oWordValid='1') the bytes
  -- have already been granted by a prior iReady, so they are checked
  -- unconditionally and in order against the scoreboard. oFlushDone marks the
  -- end of an image.
  -----------------------------------------------------------------------------
  monitor_proc : process is

    variable nb      : natural;
    variable byte    : std_logic_vector(7 downto 0);
    variable cnt     : natural;
    variable af      : integer;
    variable hasData : integer;

  begin

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
          Check(SB_ID, byte);

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

  -----------------------------------------------------------------------------
  -- Driver + reference model.
  -----------------------------------------------------------------------------
  stim_proc : process is

    variable rv : RandomPType;

    constant ZERO_W : std_logic_vector(IN_WIDTH - 1 downto 0) := (others => '0');

    -- Reference FF-stuffer state (one image).
    variable curByte    : std_logic_vector(7 downto 0);
    variable bitsInByte : natural range 0 to 8;
    variable anyBits    : boolean;
    variable lastEmitFF : boolean;
    variable realSince  : boolean;       -- real bit since last emit
    variable stuffSeen  : boolean;       -- a stuff already emitted in this image

    -- Append one payload bit (MSB-first) and emit expected bytes, stuffing a
    -- '0' after every completed 0xFF byte (the stuff bit becomes the next
    -- byte's MSB, so a stuffed byte can never itself be 0xFF).

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
          curByte    := (others => '0'); -- stuff '0' at MSB
          bitsInByte := 1;
        else
          ICover(covStuff, SE_NONE);
          lastEmitFF := false;
          curByte    := (others => '0');
          bitsInByte := 0;
        end if;
      end if;

    end procedure push_bit;

    -- Append the top `len` bits of a word (MSB-first), matching the DUT which
    -- takes the top valid bits of iWord.

    procedure push_word (
      w   : std_logic_vector;
      len : natural
    ) is
    begin

      for i in 0 to len - 1 loop

        push_bit(w(IN_WIDTH - 1 - i));

      end loop;

    end procedure push_word;

    -- Finalize the image at flush: push the padded final byte (if any), record
    -- the terminal type for coverage, and reset for the next image.

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
        Push(SB_ID, curByte);                -- unfilled low bits are already '0' (post-stuffing pad)
      end if;

      ICover(covFlush, ft);

      curByte    := (others => '0');
      bitsInByte := 0;
      anyBits    := false;
      lastEmitFF := false;
      realSince  := false;
      stuffSeen  := false;

    end procedure finish_image;

    -- Present one beat and advance only when iStall='0' on a rising edge
    -- (== one DUT latch/consume; bit_packer holds its output across a stall).

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

      -- consumed on this edge; update reference model in DUT order (append then flush)
      if (valid = '1') then
        push_word(w, len);
      end if;

      if (flush = '1') then
        finish_image;
      end if;

      iWordValid <= '0';
      iFlush     <= '0';

    end procedure send_beat;

    -- One image: random beats; flush rides the LAST valid word (the DUT
    -- contract -- iFlush pulses on the cycle the final word is presented, never
    -- on an empty beat). Then wait for full drain before the next image.

    procedure send_image (
      beats : natural
    ) is

      variable w   : std_logic_vector(IN_WIDTH - 1 downto 0);
      variable len : natural;

    begin

      for n in 1 to beats loop

        -- ~30% all-ones words to manufacture 0xFF output bytes and stuff runs.
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
          send_beat(w, len, '1', '1');   -- flush rides the final word
        else
          send_beat(w, len, '1', '0');
        end if;

      end loop;

      sImagesSent <= sImagesSent + 1;
      -- serialize images: wait for full drain before the next one
      wait until sFlushDone = sImagesSent;

    end procedure send_image;

    -- Directed beat helper: a single word of `len` valid bits.

    procedure directed (
      w   : std_logic_vector(IN_WIDTH - 1 downto 0);
      len : natural
    ) is
    begin

      send_beat(w, len, '1', '1');
      sImagesSent <= sImagesSent + 1;
      wait until sFlushDone = sImagesSent;

    end procedure directed;

    variable ones : std_logic_vector(IN_WIDTH - 1 downto 0);
    variable wtmp : std_logic_vector(IN_WIDTH - 1 downto 0);

  begin

    -- Stim-driven inputs (no signal defaults; assign before reset).
    iWord         <= ZERO_W;
    iWordValid    <= '0';
    iWordValidLen <= (others => '0');
    iFlush        <= '0';

    -- Reference FF-stuffer state.
    curByte    := (others => '0');
    bitsInByte := 0;
    anyBits    := false;
    lastEmitFF := false;
    realSince  := false;
    stuffSeen  := false;

    SetAlertLogName("tb_byte_stuffer_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);

    covEmit := NewID("emitBytes");
    SetFieldName(covEmit, "emitBytes");
    for count in 0 to OUT_BYTES loop
      AddBins(covEmit, "emitted bytes=" & to_string(count), GenBin(count));
    end loop;
    -- FT_EMPTY is unreachable (see directed-corner note) and excluded.
    covFlush := NewID("flushType");
    SetFieldName(covFlush, "flushType");
    AddBins(covFlush, "byte aligned", GenBin(1));
    AddBins(covFlush, "padded residue", GenBin(2));
    AddBins(covFlush, "dangling FF", GenBin(3));
    -- Require seeing data output BOTH with and without almost-full backpressure.
    -- (The 0-byte terminal beat only fires after the FIFO has drained, so
    -- 0-byte x almostFull is unreachable and deliberately not a bin.)
    covCross := NewID("data x almostFull");
    SetFieldName(covCross, "data", "almostFull");
    for almost_full in 0 to 1 loop
      AddCross(covCross, "data beat / almostFull=" & to_string(almost_full),
               GenBin(1), GenBin(almost_full));
    end loop;
    -- Stuff event per emitted byte: at least one image with no stuff, one with
    -- its first stuff, and one with a subsequent (run) stuff. Makes the FF->'0'
    -- stuffing -- the module's whole purpose -- visible in its own coverage.
    covStuff := NewID("stuffEvent");
    SetFieldName(covStuff, "stuffEvent");
    AddBins(covStuff, "noStuff",    GenBin(SE_NONE, SE_NONE));
    AddBins(covStuff, "firstStuff", GenBin(SE_FIRST, SE_FIRST));
    AddBins(covStuff, "runStuff",   GenBin(SE_RUN, SE_RUN));

    apply_reset(clk, rst, 6, '1');
    ones := (others => '1');

    --------------------------------------------------------------------------
    -- Directed corners (regression locks).
    --------------------------------------------------------------------------
    -- NOTE: a truly-empty flush (zero payload bits) is intentionally NOT tested
    -- -- it is unreachable. Every valid word into byte_stuffer carries >=1 bit
    -- (regular/RI: the Golomb unary stop bit in the bit_packer; token_raw:
    -- A15_A16 guarantees raw suffix len >=1), and flush rides the last valid
    -- word, so the accumulator is never empty at flush.

    -- Single non-FF byte, byte-aligned clean end.
    wtmp                                   := (others => '0');
    wtmp(IN_WIDTH - 1 downto IN_WIDTH - 8) := x"5A";
    directed(wtmp, 8);

    -- Single 0xFF byte -> trailing stuffed 0x00 (dangling-FF terminal).
    wtmp                                   := (others => '0');
    wtmp(IN_WIDTH - 1 downto IN_WIDTH - 8) := x"FF";
    directed(wtmp, 8);

    -- Sub-byte residue (5 real bits) padded post-stuffing.
    wtmp                                   := (others => '0');
    wtmp(IN_WIDTH - 1 downto IN_WIDTH - 5) := "10101";
    directed(wtmp, 5);

    for len in 1 to IN_WIDTH loop
      directed(ones, len);
      directed(ZERO_W, len);
    end loop;
    send_beat(ones, IN_WIDTH, '0', '0'); -- inactive garbage must not enter stream
    directed(ZERO_W, 8);

    -- Long 0xFF run in one beat: forces consecutive stuffs across the 4-slot
    -- chain (full-width all-ones).
    directed(ones, IN_WIDTH);

    -- Multi-word flush with residue: > FIFO width of all-ones, flushed on a
    -- final partial beat (regression for the multi-word valid-bits overflow).
    send_beat(ones, IN_WIDTH, '1', '0');
    send_beat(ones, IN_WIDTH, '1', '0');
    wtmp                                    := (others => '0');
    wtmp(IN_WIDTH - 1 downto IN_WIDTH - 12) := x"FF" & "0101";
    directed(wtmp, 12);

    -- Back-to-back tiny images (context reset between flushes).
    for n in 1 to 4 loop

      wtmp                                   := (others => '0');
      wtmp(IN_WIDTH - 1 downto IN_WIDTH - 8) := std_logic_vector(to_unsigned(n * 32, 8));
      directed(wtmp, 8);

    end loop;

    --------------------------------------------------------------------------
    -- Constrained-random images.
    --------------------------------------------------------------------------
    for img in 1 to N_RANDOM loop

      send_image(rv.RandInt(1, MAX_BEATS));

    end loop;

    --------------------------------------------------------------------------
    -- Mid-operation iRst: drive a partial image (valid beats, no flush) then
    -- assert iRst before the flush. The aborted bits are never scored (sIgnore);
    -- after reset the byte_stuffer must be idle, and a fresh image must come out
    -- byte-exact. The reference FF-stuffer state is clean here (last image was
    -- flushed) and is re-initialised below to mirror the reset.
    --------------------------------------------------------------------------
    sIgnore <= true;

    for k in 1 to 4 loop

      iWord         <= rv.RandSlv(IN_WIDTH);
      iWordValidLen <= to_unsigned(IN_WIDTH, VLEN_W);
      iWordValid    <= '1';
      iFlush        <= '0';

      loop

        wait until rising_edge(clk);
        exit when iStall = '0';

      end loop;

    end loop;

    iWordValid <= '0';
    iFlush     <= '0';
    apply_reset(clk, rst, 6, '1');
    wait for 1 ns;
    AffirmIf(GetAlertLogID("ResetRecovery"), oWordValid = '0', "mid-op reset: byte_stuffer output cleared");
    AffirmIf(GetAlertLogID("ResetRecovery"), oFlushDone = '0', "mid-op reset: no flush-done after reset");

    -- Re-initialise the reference FF-stuffer state to mirror the reset.
    curByte    := (others => '0');
    bitsInByte := 0;
    anyBits    := false;
    lastEmitFF := false;
    realSince  := false;
    stuffSeen  := false;

    sIgnore <= false;
    wait until rising_edge(clk);

    -- Recovery: a fresh image must encode byte-exact through the scoreboard.
    send_image(rv.RandInt(1, MAX_BEATS));

    --------------------------------------------------------------------------
    -- Done: every image already drained (each send_image/directed waits for its
    -- own oFlushDone), so just let the monitor settle, then report.
    --------------------------------------------------------------------------
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

    end_of_test("tb_byte_stuffer_osvvm");
    wait;

  end process stim_proc;

  -----------------------------------------------------------------------------
  -- Watchdog.
  -----------------------------------------------------------------------------
  watchdog_proc : process is
  begin

    wait for 20 ms;
    Alert(GetAlertLogID("Watchdog"), "tb_byte_stuffer_osvvm: watchdog timeout", FAILURE);
    std.env.stop;

  end process watchdog_proc;

end architecture sim;
