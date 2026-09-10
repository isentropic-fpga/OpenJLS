-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM top-level control-plane stress testbench: openjls_top.
--
-- Per the verification plan, the golden suite owns payload correctness; OSVVM
-- here proves the *envelope* survives stress. Two phases:
--
-- Phase A — T.87 Annex H.3 image (4x4, 8-bit, NEAR=0), known 57-byte output
-- as the invariance oracle:
--   * downstream backpressure (random iReady de-assertion) -> byte-identical
--   * upstream input stalls (random iValid gaps)           -> byte-identical
--   * mid-image reset injection                            -> next image still
--                                                             encodes correctly
--   * back-to-back images (next image fed while the previous one is still
--     draining) -> N x golden bytes; exercises the image-parity machinery
--     (ctx straggler refusal, framer start queue, EOI FIFO)
--
-- Phase B — 48x48 random-noise image (incompressible, ~2.3 kB coded output,
-- far beyond the framer FIFO + byte_stuffer buffer). A clean run captures the
-- reference; every stressed run must reproduce it byte-identically:
--   * long iReady hold -> oReady must DROP (stall propagates upstream through
--     framer FIFO -> byte_stuffer almost-full -> pipeline freeze); affirmed
--     non-vacuously via a stall monitor. The H.3 image is too small to ever
--     trigger this path.
--   * reset while the output is draining (input done, oLast pending)
--   * random backpressure + input stalls, also back-to-back
--
-- Coverage closes on conjunctions: (backpressure x input-stall) cross,
-- upstream stall propagation, back-to-back (clean / stressed), reset
-- (mid-feed / mid-feed-under-stress / mid-drain).
--
-- Requirements tracked (see Verification/OSVVM/README.md registry):
--   T87.H3               output byte-identical to the Annex H.3 golden stream
--   OJLS.BackToBack      next image accepted while the previous one drains
--   OJLS.RIForward       run-interruption context forwarding (sFwdRiHit) emits
--                        the CharLS golden byte-for-byte (Phase A3)
--   OJLS.NoStallCompress oReady never drops during a clean feed (byte_stuffer
--                        buffer must not fill while compressing)
--   OJLS.NoStallEOL      ... including across line / image boundaries
--
-- Restores the output-backpressure / stall-recovery coverage the golden TB
-- dropped (project-backpressure-coverage-gap).
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library osvvm;
  context osvvm.OsvvmContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_openjls_top_osvvm is
  -- Non-default variants are driven from OpenJls.pro via [generic ...].
  generic (
    MAX_W      : positive := 4096;
    MAX_H      : positive := 4096;
    OUT_WIDTH  : natural  := CO_OUT_WIDTH_STD;   -- 64
    -- Bind the DUT to a Vivado funcsim netlist analyzed into work in place of
    -- the RTL (see Verification/Post synth). Defaults-only: the netlist bakes
    -- this TB's default config at synthesis.
    POST_SYNTH : boolean  := false
  );
end entity tb_openjls_top_osvvm;

architecture sim of tb_openjls_top_osvvm is

  constant CLK_PERIOD     : time     := CLK_PERIOD_DEFAULT;
  constant BITNESS        : natural  := 8;
  constant BYTES_PER_WORD : natural  := OUT_WIDTH / 8;

  constant IMG_W : natural := 4;
  constant IMG_H : natural := 4;

  -- Phase B stress image: random noise is incompressible, so its coded output
  -- (~1 byte/pixel) dwarfs the framer FIFO + byte_stuffer buffer and a held
  -- iReady must propagate a stall all the way to oReady.
  constant BIG_W : natural := 48;
  constant BIG_H : natural := 48;

  -- Cycles iReady is held low in the stall-propagation run (mode 2).
  constant HOLD_CYCLES : natural := 1200;

  type pixel_array_t is array (natural range <>) of natural;

  constant PIXELS : pixel_array_t(0 to 15) :=
    (0, 0, 90, 74, 68, 50, 43, 205, 64, 145, 145, 145, 100, 145, 145, 145);

  type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);

  -- T.87 Annex H.3 golden output: 25-byte header + 30-byte payload + FF D9.
  constant EXPECTED : byte_array_t(0 to 56) :=
    (x"FF", x"D8", x"FF", x"F7", x"00", x"0B", x"08", x"00", x"04", x"00", x"04",
     x"01", x"01", x"11", x"00", x"FF", x"DA", x"00", x"08", x"01", x"01", x"00",
     x"00", x"00", x"00",
     x"C0", x"00", x"00", x"6C", x"80", x"20", x"8E", x"01", x"C0", x"00", x"00",
     x"57", x"40", x"00", x"00", x"6E", x"E6", x"00", x"00", x"01", x"BC", x"18",
     x"00", x"00", x"05", x"D8", x"00", x"00", x"91", x"60",
     x"FF", x"D9");
  constant EXP_BYTES : natural := EXPECTED'length;

  -- Run-interruption forwarding image (6x6, 8-bit, 3 grey levels). The flat
  -- regions enter run mode and interrupt on consecutive samples, so two
  -- run-interruption updates land on the same context one pipeline stage apart
  -- and exercise the sFwdRiHit data-forwarding path (the RI twin of the regular
  -- Q3==Q4 forward the H.3 image already covers). RI_EXPECTED is the CharLS
  -- golden for this image; the byte stream is independent of OUT_WIDTH.
  constant RI_W      : natural := 6;
  constant RI_H      : natural := 6;

  constant RI_PIXELS : pixel_array_t(0 to RI_W * RI_H - 1) :=
    (2, 2, 2, 0, 1, 1, 2, 2, 2, 0, 1, 2, 2, 0, 0, 2, 2, 1,
     1, 0, 1, 2, 1, 2, 0, 1, 1, 1, 1, 0, 1, 0, 2, 0, 2, 1);

  constant RI_EXPECTED : byte_array_t(0 to 39) :=
    (x"FF", x"D8", x"FF", x"F7", x"00", x"0B", x"08", x"00", x"06", x"00", x"06",
     x"01", x"01", x"11", x"00", x"FF", x"DA", x"00", x"08", x"01", x"01", x"00",
     x"00", x"00", x"00", x"79", x"12", x"F3", x"48", x"E5", x"12", x"7A", x"94",
     x"A9", x"ED", x"CA", x"4E", x"00", x"FF", x"D9");
  constant RI_EXP_BYTES : natural := RI_EXPECTED'length;

  signal clk     : std_logic := '0';
  signal rst     : std_logic;
  signal iValid  : std_logic;
  signal iPixel  : std_logic_vector(BITNESS - 1 downto 0);
  signal oReady  : std_logic;
  signal iWidth  : std_logic_vector(15 downto 0);
  signal iHeight : std_logic_vector(15 downto 0);
  signal oData   : std_logic_vector(OUT_WIDTH - 1 downto 0);
  signal oValid  : std_logic;
  signal oKeep   : std_logic_vector(OUT_WIDTH / 8 - 1 downto 0);
  signal oLast   : std_logic;
  signal iReady  : std_logic;

  -- Image dimensions are latched by the DUT during reset; stim switches these
  -- before re-resetting for Phase B.
  signal sImgW : natural;
  signal sImgH : natural;

  -- Downstream backpressure mode: 0 always ready, 1 random (~33% ready),
  -- 2 one-shot hold (iReady low for HOLD_CYCLES, then high until mode change).
  signal sBpMode : natural range 0 to 2;

  -- Arms the no-stall requirements monitor. Only clean feeds (no downstream
  -- backpressure, no input gaps) may arm it: stalls are legal under stress.
  signal sNoStall : boolean := false;

  shared variable collected      : byte_array_t(0 to 32767);
  shared variable collectedCount : natural;
  shared variable lastCount      : natural;
  -- Cycles where the DUT refused an offered pixel (iValid=1, oReady=0):
  -- evidence that downstream backpressure propagated upstream.
  shared variable feedStallCnt   : natural;

begin

  stream_contract : monitor_stream(clk, rst, oValid, iReady, oData, oKeep, oLast);

  clk_proc : process is
  begin

    clk <= '0';
    wait for CLK_PERIOD / 2;
    clk <= '1';
    wait for CLK_PERIOD / 2;

  end process clk_proc;

  iWidth  <= std_logic_vector(to_unsigned(sImgW, iWidth'length));
  iHeight <= std_logic_vector(to_unsigned(sImgH, iHeight'length));

  -- Each branch declares its own component and lets default binding pick up
  -- whatever openjls_top the build analyzed into work: the funcsim netlist is
  -- genericless (config baked at synthesis) and its architecture is STRUCTURE,
  -- so a direct entity work.openjls_top(rtl) instantiation cannot analyze
  -- against it.
  dut : if POST_SYNTH generate

    -- Ports fixed at this TB's defaults; a netlist baked with anything else
    -- fails elaboration here on the width mismatch.
    component openjls_top is
      port (
        iClk         : in    std_logic;
        iRst         : in    std_logic;
        iValid       : in    std_logic;
        iPixel       : in    std_logic_vector(BITNESS - 1 downto 0);
        oReady       : out   std_logic;
        iImageWidth  : in    std_logic_vector(15 downto 0);
        iImageHeight : in    std_logic_vector(15 downto 0);
        oData        : out   std_logic_vector(OUT_WIDTH - 1 downto 0);
        oValid       : out   std_logic;
        oKeep        : out   std_logic_vector(OUT_WIDTH / 8 - 1 downto 0);
        oLast        : out   std_logic;
        iReady       : in    std_logic
      );
    end component openjls_top;

  begin

    dut_post_syn : openjls_top
      port map (
        iClk         => clk,
        iRst         => rst,
        iValid       => iValid,
        iPixel       => iPixel,
        oReady       => oReady,
        iImageWidth  => iWidth,
        iImageHeight => iHeight,
        oData        => oData,
        oValid       => oValid,
        oKeep        => oKeep,
        oLast        => oLast,
        iReady       => iReady
      );

  else generate

    component openjls_top is
      generic (
        BITNESS          : positive range 8 to 16    := 12;
        MAX_IMAGE_WIDTH  : positive range 4 to 65535 := 4096;
        MAX_IMAGE_HEIGHT : positive range 1 to 65535 := 4096;
        OUT_WIDTH        : positive range 48 to 1024 := CO_OUT_WIDTH_STD
      );
      port (
        iClk         : in    std_logic;
        iRst         : in    std_logic;
        iValid       : in    std_logic;
        iPixel       : in    std_logic_vector(BITNESS - 1 downto 0);
        oReady       : out   std_logic;
        iImageWidth  : in    std_logic_vector(15 downto 0);
        iImageHeight : in    std_logic_vector(15 downto 0);
        oData        : out   std_logic_vector(OUT_WIDTH - 1 downto 0);
        oValid       : out   std_logic;
        oKeep        : out   std_logic_vector(OUT_WIDTH / 8 - 1 downto 0);
        oLast        : out   std_logic;
        iReady       : in    std_logic
      );
    end component openjls_top;

  begin

    dut_behav : openjls_top
      generic map (
        BITNESS          => BITNESS,
        MAX_IMAGE_WIDTH  => MAX_W,
        MAX_IMAGE_HEIGHT => MAX_H,
        OUT_WIDTH        => OUT_WIDTH
      )
      port map (
        iClk         => clk,
        iRst         => rst,
        iValid       => iValid,
        iPixel       => iPixel,
        oReady       => oReady,
        iImageWidth  => iWidth,
        iImageHeight => iHeight,
        oData        => oData,
        oValid       => oValid,
        oKeep        => oKeep,
        oLast        => oLast,
        iReady       => iReady
      );

  end generate dut;

  -----------------------------------------------------------------------------
  -- Output collector (oKeep bytes, MSB-first, on the AXI handshake).
  -----------------------------------------------------------------------------
  collect_proc : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '1') then
        collectedCount := 0;
        lastCount      := 0;
      elsif (oValid = '1' and iReady = '1') then

        for i in 0 to BYTES_PER_WORD - 1 loop

          if (oKeep(BYTES_PER_WORD - 1 - i) = '1') then
            if (collectedCount < collected'length) then
              collected(collectedCount) := oData(OUT_WIDTH - 1 - i * 8 downto OUT_WIDTH - (i + 1) * 8);
            end if;
            collectedCount := collectedCount + 1;
          end if;

        end loop;

        if (oLast = '1') then
          lastCount := lastCount + 1;
        end if;
      end if;
    end if;

  end process collect_proc;

  -----------------------------------------------------------------------------
  -- Upstream stall monitor.
  -----------------------------------------------------------------------------
  stall_mon : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '0' and iValid = '1' and oReady = '0') then
        feedStallCnt := feedStallCnt + 1;
      end if;
    end if;

  end process stall_mon;

  -----------------------------------------------------------------------------
  -- No-stall requirements monitor. While armed, every offered pixel must be
  -- accepted immediately (OJLS.NoStallCompress: the byte_stuffer buffer never
  -- fills while compressing), including the first pixel after a line or image
  -- boundary (OJLS.NoStallEOL). Goals are conservative lower bounds of the
  -- guaranteed armed check counts, so a vacuous run fails the requirement.
  -----------------------------------------------------------------------------
  nostall_mon : process (clk) is

    variable reqCompress : AlertLogIDType := ALERTLOG_ID_NOT_ASSIGNED;
    variable reqEol      : AlertLogIDType := ALERTLOG_ID_NOT_ASSIGNED;
    variable pxIdx       : natural;

  begin

    if rising_edge(clk) then
      if (reqCompress = ALERTLOG_ID_NOT_ASSIGNED) then
        reqCompress := GetReqID("OJLS.NoStallCompress", 5000);
        reqEol      := GetReqID("OJLS.NoStallEOL", 100);
      end if;

      if (rst = '1' or not sNoStall) then
        pxIdx := 0;
      else
        if (iValid = '1') then
          AffirmIf(reqCompress, oReady = '1',
                   "clean-feed stall at pixel " & integer'image(pxIdx));

          if (pxIdx > 0 and pxIdx mod sImgW = 0) then
            AffirmIf(reqEol, oReady = '1',
                     "clean-feed stall at line/image boundary, pixel " &
                     integer'image(pxIdx));
          end if;
        end if;

        if (iValid = '1' and oReady = '1') then
          pxIdx := pxIdx + 1;
        end if;
      end if;
    end if;

  end process nostall_mon;

  -----------------------------------------------------------------------------
  -- Downstream backpressure driver.
  -----------------------------------------------------------------------------
  ready_proc : process is

    variable rv      : RandomPType;
    variable holdCnt : natural;

  begin

    rv.InitSeed("ready");
    iReady  <= '1';
    holdCnt := 0;

    loop

      wait until rising_edge(clk);

      case sBpMode is

        when 0 =>

          iReady  <= '1';
          holdCnt := 0;

        when 1 =>

          -- ~33% ready, with occasional ready bursts to guarantee drain.
          iReady  <= bool2bit(rv.DistValInt(((1, 1), (0, 2))) = 1);
          holdCnt := 0;

        when others =>

          if (holdCnt < HOLD_CYCLES) then
            iReady  <= '0';
            holdCnt := holdCnt + 1;
          else
            iReady <= '1';
          end if;

      end case;

    end loop;

  end process ready_proc;

  -----------------------------------------------------------------------------
  -- Stimulus.
  -----------------------------------------------------------------------------
  stim : process is

    variable rv         : RandomPType;
    variable covSweep   : CoverageIDType;
    variable pt         : integer_vector(1 to 3);
    variable nImages    : positive;
    variable covUp      : CoverageIDType;
    variable covB2B     : CoverageIDType;
    variable covRst     : CoverageIDType;
    variable base       : natural;
    variable baseL      : natural;
    variable bigImg     : pixel_array_t(0 to BIG_W * BIG_H - 1);
    variable refBuf     : byte_array_t(0 to 8191);
    variable refLen     : natural;
    variable vStallSnap : natural;
    variable reqH3      : AlertLogIDType;
    variable reqB2B     : AlertLogIDType;
    variable reqRI      : AlertLogIDType;

    procedure do_reset is
    begin

      rst    <= '1';
      iValid <= '0';
      iPixel <= (others => '0');
      clk_tick(clk, 4);

      -- Reset must clear the output stream (matters when injected mid-image:
      -- any in-flight beats must be dropped, not emitted after recovery).
      wait for 1 ns;
      AffirmIf(GetAlertLogID("ResetRecovery"), oValid = '0', "reset: output stream idle");
      AffirmIf(GetAlertLogID("ResetRecovery"), oLast = '0', "reset: oLast cleared");

      rst <= '0';
      wait until rising_edge(clk);

      while (oReady /= '1') loop

        wait until rising_edge(clk);

      end loop;

    end procedure do_reset;

    -- Feed pixels from img; stall inserts random iValid gaps; count = how many
    -- pixels to feed (full image unless truncated for reset injection).
    procedure feed (
      img   : pixel_array_t;
      stall : boolean;
      count : natural
    ) is
    begin

      for i in 0 to count - 1 loop

        if (stall) then
          while (rv.DistValInt(((1, 1), (0, 3))) = 1) loop

            iValid <= '0';
            wait until rising_edge(clk);

          end loop;
        end if;

        iPixel <= std_logic_vector(to_unsigned(img(i), BITNESS));
        iValid <= '1';
        wait until oReady = '1' and rising_edge(clk);

      end loop;

      iValid <= '0';

    end procedure feed;

    procedure wait_images (
      n : natural
    ) is
    begin

      for i in 0 to 199999 loop

        exit when lastCount >= baseL + n;
        wait until rising_edge(clk);

      end loop;

      AffirmIfEqual(GetAlertLogID("ImageCompletion"), lastCount - baseL, n, "expected image boundaries before timeout");
    end procedure wait_images;

    -- Encode `images` H.3 images back-to-back (no inter-image gap) and assert
    -- the output equals `images` copies of the golden bytes.
    procedure run_check (
      bp     : natural range 0 to 1;
      stall  : boolean;
      images : positive;
      msg    : string
    ) is
    begin

      base     := collectedCount;
      baseL    := lastCount;
      sBpMode  <= bp;
      sNoStall <= bp = 0 and not stall;
      for k in 1 to images loop

        feed(PIXELS, stall, PIXELS'length);
        -- Image k's last pixel entered one cycle ago, so its oLast cannot
        -- have fired: image k+1 is fed while image k is still draining.
        if (k = 1 and images > 1) then
          AffirmIf(reqB2B, lastCount = baseL, msg & ": b2b overlap");
        end if;

      end loop;

      wait_images(images);

      AffirmIfEqual(reqH3, collectedCount - base, images * EXP_BYTES, msg & " byte count");
      for i in 0 to images * EXP_BYTES - 1 loop

        if (base + i < collectedCount) then
          AffirmIfEqual(reqH3, collected(base + i), EXPECTED(i mod EXP_BYTES),
                        msg & " byte " & integer'image(i));
        end if;

      end loop;

    end procedure run_check;

    -- Compare the bytes collected since `base` against the Phase B reference.
    procedure check_against_ref (
      msg : string
    ) is
    begin

      AffirmIfEqual(GetAlertLogID("DataChecks"), collectedCount - base, refLen, msg & " byte count");
      for i in 0 to refLen - 1 loop

        if (base + i < collectedCount) then
          AffirmIfEqual(GetAlertLogID("DataChecks"), collected(base + i), refBuf(i),
                        msg & " byte " & integer'image(i));
        end if;

      end loop;

    end procedure check_against_ref;

  begin

    rst     <= '1';
    iValid  <= '0';
    iPixel  <= (others => '0');
    sBpMode <= 0;
    sImgW   <= IMG_W;
    sImgH   <= IMG_H;
    feedStallCnt := 0;

    SetAlertLogName("tb_openjls_top_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    covSweep := NewID("bp x inputStall x prelude");
    SetFieldName(covSweep, "bp", "inputStall", "prelude");
    for axis0 in 0 to 1 loop
      for axis1 in 0 to 1 loop
        for axis2 in 0 to 2 loop
          AddCross(covSweep, "bp=" & to_string(axis0) & " / " & "inputStall=" & to_string(axis1) & " / " & "prelude=" & to_string(axis2), GenBin(axis0), GenBin(axis1), GenBin(axis2));
        end loop;
      end loop;
    end loop;
    covUp := NewID("upstreamStallPropagated");
    SetFieldName(covUp, "upstreamStallPropagated");
    AddBins(covUp, "upstreamStallPropagated", GenBin(1, 1));
    covB2B := NewID("backToBack clean/stressed/minimal");
    SetFieldName(covB2B, "backToBack clean/stressed/minimal");
    AddBins(covB2B, "clean overlap", GenBin(0));
    AddBins(covB2B, "stressed overlap", GenBin(1));
    AddBins(covB2B, "minimal image overlap", GenBin(2));
    covRst := NewID("reset midFeed/midFeedStress/midDrain");
    SetFieldName(covRst, "reset midFeed/midFeedStress/midDrain");
    AddBins(covRst, "reset during input", GenBin(0));
    AddBins(covRst, "reset during stressed input", GenBin(1));
    AddBins(covRst, "reset during output", GenBin(2));

    -- Requirement goals: H.3 = at least one full golden image; BackToBack = the
    -- three directed b2b runs (b2b x3, B5 stressed, C minimal).
    reqH3  := GetReqID("T87.H3", EXP_BYTES);
    reqB2B := GetReqID("OJLS.BackToBack", 3);
    reqRI  := GetReqID("OJLS.RIForward", RI_EXP_BYTES);

    do_reset;

    --------------------------------------------------------------------------
    -- Phase A directed: each stress axis, clean baseline first.
    --------------------------------------------------------------------------
    run_check(0, false, 1, "baseline");
    run_check(1, false, 1, "downstream backpressure");
    run_check(0, true, 1, "input stall");
    run_check(1, true, 1, "backpressure + stall");

    --------------------------------------------------------------------------
    -- Back-to-back: three images streamed with no inter-image gap. Exercises
    -- the image-parity machinery (ctx straggler refusal, forwarding guards),
    -- the framer start queue and the in-flight EOI FIFO.
    --------------------------------------------------------------------------
    run_check(0, false, 3, "b2b x3");
    ICover(covB2B, 0);

    --------------------------------------------------------------------------
    -- Mid-image reset injection, then a clean image must still be correct.
    --------------------------------------------------------------------------
    sBpMode <= 0;
    feed(PIXELS, false, 8);         -- partial image (8 of 16 pixels)
    do_reset;                       -- abort mid-image
    run_check(0, false, 1, "post-reset recovery");
    ICover(covRst, 0);

    -- Reset injection while under backpressure, then recover.
    sBpMode  <= 1;
    sNoStall <= false;
    feed(PIXELS, true, 6);
    do_reset;
    run_check(1, true, 1, "post-reset recovery under stress");
    ICover(covRst, 1);

    --------------------------------------------------------------------------
    -- Phase A Intelligent Coverage sweep: bp x inputStall x prelude, where
    -- prelude 0 = none, 1 = aborted partial image (mid-feed reset), 2 = the
    -- checked image is a back-to-back pair. RandCovPoint picks a random
    -- *uncovered* bin each pass (WeightMode REMAIN), so the 12-bin cross
    -- closes in exactly 12 passes instead of a coupon-collector tail.
    --------------------------------------------------------------------------
    for r in 1 to 60 loop

      exit when IsCovered(covSweep);
      pt := RandCovPoint(covSweep);

      nImages := 1;

      if (pt(3) = 1) then
        sBpMode  <= pt(1);
        sNoStall <= pt(1) = 0 and pt(2) = 0;
        feed(PIXELS, pt(2) = 1, rv.RandInt(1, PIXELS'length - 1));
        do_reset;
      elsif (pt(3) = 2) then
        nImages := 2;
      end if;

      run_check(pt(1), pt(2) = 1, nImages,
                "ic bp=" & to_string(pt(1)) & " st=" & to_string(pt(2)) &
                " pre=" & to_string(pt(3)));

      ICover(covSweep, pt);

    end loop;

    --------------------------------------------------------------------------
    -- Phase A3: run-interruption context forwarding. The 6x6 RI image drives
    -- two run-interruption updates to the same context one pipeline stage
    -- apart (sFwdRiHit). Byte-compared against the CharLS golden — the H.3
    -- image never takes this path, so it is the only directed cover for it.
    --------------------------------------------------------------------------
    sImgW    <= RI_W;
    sImgH    <= RI_H;
    do_reset;
    base     := collectedCount;
    baseL    := lastCount;
    sBpMode  <= 0;
    sNoStall <= false;
    feed(RI_PIXELS, false, RI_PIXELS'length);
    wait_images(1);

    AffirmIfEqual(reqRI, collectedCount - base, RI_EXP_BYTES, "RI-forward byte count");
    for i in 0 to RI_EXP_BYTES - 1 loop

      if (base + i < collectedCount) then
        AffirmIfEqual(reqRI, collected(base + i), RI_EXPECTED(i),
                      "RI-forward byte " & integer'image(i));
      end if;

    end loop;

    --------------------------------------------------------------------------
    -- Phase B: 48x48 random-noise image. Dimensions latch during reset.
    -- The clean run's output is the invariance reference for every stressed
    -- run (payload correctness itself is the golden suite's job).
    --------------------------------------------------------------------------
    sImgW <= BIG_W;
    sImgH <= BIG_H;
    do_reset;

    for i in bigImg'range loop

      bigImg(i) := rv.RandInt(0, 2 ** BITNESS - 1);

    end loop;

    -- B1: clean reference run.
    base     := collectedCount;
    baseL    := lastCount;
    sBpMode  <= 0;
    sNoStall <= true;
    feed(bigImg, false, bigImg'length);
    wait_images(1);
    refLen := collectedCount - base;
    AffirmIfEqual(GetAlertLogID("DataChecks"), lastCount - baseL, 1, "B1: reference image completed");
    -- Must dwarf the framer FIFO + byte_stuffer buffer, or the hold run below
    -- could never propagate a stall and the coverage would be vacuous.
    AffirmIf(GetAlertLogID("DataChecks"), refLen > 1000, "B1: stress image defeats internal buffering" &
                            " (refLen=" & integer'image(refLen) & ")");
    for i in 0 to refLen - 1 loop

      refBuf(i) := collected(base + i);

    end loop;

    -- B2: reset while the output is draining (input done, oLast pending),
    -- then a clean re-run must reproduce the reference.
    base  := collectedCount;
    baseL := lastCount;
    feed(bigImg, false, bigImg'length);
    for i in 0 to 199999 loop

      exit when collectedCount - base >= refLen / 2;
      wait until rising_edge(clk);

    end loop;

    AffirmIf(GetAlertLogID("ResetRecovery"), lastCount = baseL, "B2: output still in flight at reset");
    do_reset;
    ICover(covRst, 2);
    base  := collectedCount;
    baseL := lastCount;
    feed(bigImg, false, bigImg'length);
    wait_images(1);
    check_against_ref("B2 post-mid-drain-reset");

    -- B3: long iReady hold -> the stall must propagate upstream (oReady drops
    -- while pixels are being offered), then release and drain byte-identical.
    vStallSnap := feedStallCnt;
    base       := collectedCount;
    baseL      := lastCount;
    sBpMode    <= 2;
    sNoStall   <= false;
    feed(bigImg, false, bigImg'length);
    wait_images(1);
    sBpMode <= 0;
    AffirmIf(GetAlertLogID("FlowControl"), feedStallCnt > vStallSnap,
             "B3: downstream hold propagated to oReady (upstream stall seen)");
    ICover(covUp, 1);
    check_against_ref("B3 stall propagation");

    -- B4: random backpressure + input stalls.
    base    := collectedCount;
    baseL   := lastCount;
    sBpMode <= 1;
    feed(bigImg, true, bigImg'length);
    wait_images(1);
    check_against_ref("B4 random stress");

    -- B5: back-to-back under backpressure + input stalls.
    base    := collectedCount;
    baseL   := lastCount;
    sBpMode <= 1;
    feed(bigImg, true, bigImg'length);
    AffirmIf(reqB2B, lastCount = baseL, "B5: image 2 fed while image 1 still draining");
    feed(bigImg, true, bigImg'length);
    wait_images(2);
    sBpMode <= 0;

    AffirmIfEqual(GetAlertLogID("DataChecks"), collectedCount - base, 2 * refLen, "B5 byte count");
    for i in 0 to 2 * refLen - 1 loop

      if (base + i < collectedCount) then
        AffirmIfEqual(GetAlertLogID("DataChecks"), collected(base + i), refBuf(i mod refLen),
                      "B5 byte " & integer'image(i));
      end if;

    end loop;

    ICover(covB2B, 1);

    --------------------------------------------------------------------------
    -- Phase C: minimal legal image (4x1) back-to-back. The whole image feeds
    -- in fewer cycles than the pipeline's flush latency, so image 2 is fed
    -- entirely while image 1 is still in flight end-to-end — the tightest
    -- squeeze on the start/EOI bookkeeping.
    --------------------------------------------------------------------------
    sImgW <= 4;
    sImgH <= 1;
    do_reset;

    -- Clean single run captures the 4x1 reference (header + payload + FF D9).
    base     := collectedCount;
    baseL    := lastCount;
    sBpMode  <= 0;
    sNoStall <= true;
    feed(PIXELS, false, 4);
    wait_images(1);
    refLen := collectedCount - base;
    AffirmIfEqual(GetAlertLogID("DataChecks"), lastCount - baseL, 1, "C: reference 4x1 image completed");
    for i in 0 to refLen - 1 loop

      refBuf(i) := collected(base + i);

    end loop;

    -- Back-to-back x3, continuous.
    base  := collectedCount;
    baseL := lastCount;
    feed(PIXELS, false, 4);
    AffirmIf(reqB2B, lastCount = baseL, "C b2b: image 2 fed while image 1 still draining");
    feed(PIXELS, false, 4);
    feed(PIXELS, false, 4);
    wait_images(3);

    AffirmIfEqual(GetAlertLogID("DataChecks"), collectedCount - base, 3 * refLen, "C b2b byte count");
    for i in 0 to 3 * refLen - 1 loop

      if (base + i < collectedCount) then
        AffirmIfEqual(GetAlertLogID("DataChecks"), collected(base + i), refBuf(i mod refLen),
                      "C b2b byte " & integer'image(i));
      end if;

    end loop;

    ICover(covB2B, 2);

    --------------------------------------------------------------------------
    -- Phase D: below-minimum dimensions fall back to MAX_IMAGE_WIDTH/HEIGHT
    -- (latched during reset, with a warning). Encoding a full 4096x4096 image
    -- is golden-suite territory; the observable contract checked here is the
    -- frame header's Y/X fields, which emit before any payload is needed.
    -- The image is then aborted with the (already verified) mid-image reset.
    --------------------------------------------------------------------------
    sImgW    <= 0;
    sImgH    <= 0;
    sNoStall <= false;   -- pxIdx line math is meaningless under the fallback dims
    do_reset;
    base    := collectedCount;
    sBpMode <= 0;
    -- Noise feed: at OUT_WIDTH > 200 the header no longer fills a whole beat,
    -- so the first beat (and the Y/X fields in it) waits for payload bytes.
    feed(bigImg, false, bigImg'length);

    for i in 0 to 199999 loop

      exit when collectedCount - base >= 14;   -- header bytes 0..13 collected
      wait until rising_edge(clk);

    end loop;

    AffirmIfEqual(GetAlertLogID("DataChecks"), collected(base + 7),
                  std_logic_vector(to_unsigned(MAX_H / 256, 8)),
                  "D: header Y hi = MAX_IMAGE_HEIGHT");
    AffirmIfEqual(GetAlertLogID("DataChecks"), collected(base + 8),
                  std_logic_vector(to_unsigned(MAX_H mod 256, 8)),
                  "D: header Y lo = MAX_IMAGE_HEIGHT");
    AffirmIfEqual(GetAlertLogID("DataChecks"), collected(base + 9),
                  std_logic_vector(to_unsigned(MAX_W / 256, 8)),
                  "D: header X hi = MAX_IMAGE_WIDTH");
    AffirmIfEqual(GetAlertLogID("DataChecks"), collected(base + 10),
                  std_logic_vector(to_unsigned(MAX_W mod 256, 8)),
                  "D: header X lo = MAX_IMAGE_WIDTH");

    --------------------------------------------------------------------------
    -- Phase D2: above-maximum dimensions clamp to MAX_IMAGE_WIDTH/HEIGHT too
    -- (the mirror of Phase D's below-minimum fallback). Same observable
    -- contract: the header Y/X fields read back the clamped maxima. Reachable
    -- only when MAX+1 fits the port width (e.g. 4096 -> 13-bit port, so 4097
    -- is representable); a power-of-two-minus-one MAX leaves the port saturated
    -- at MAX with no representable over-max value (see README), so guard on it.
    --------------------------------------------------------------------------
    if (MAX_W < 2 ** iWidth'length - 1 and MAX_H < 2 ** iHeight'length - 1) then

      sImgW    <= MAX_W + 1;
      sImgH    <= MAX_H + 1;
      sNoStall <= false;
      do_reset;
      base    := collectedCount;
      sBpMode <= 0;
      feed(bigImg, false, bigImg'length);

      for i in 0 to 199999 loop

        exit when collectedCount - base >= 14;
        wait until rising_edge(clk);

      end loop;

      AffirmIfEqual(GetAlertLogID("DataChecks"), collected(base + 7),
                    std_logic_vector(to_unsigned(MAX_H / 256, 8)),
                    "D2: header Y hi = MAX_IMAGE_HEIGHT (over-max clamp)");
      AffirmIfEqual(GetAlertLogID("DataChecks"), collected(base + 8),
                    std_logic_vector(to_unsigned(MAX_H mod 256, 8)),
                    "D2: header Y lo = MAX_IMAGE_HEIGHT (over-max clamp)");
      AffirmIfEqual(GetAlertLogID("DataChecks"), collected(base + 9),
                    std_logic_vector(to_unsigned(MAX_W / 256, 8)),
                    "D2: header X hi = MAX_IMAGE_WIDTH (over-max clamp)");
      AffirmIfEqual(GetAlertLogID("DataChecks"), collected(base + 10),
                    std_logic_vector(to_unsigned(MAX_W mod 256, 8)),
                    "D2: header X lo = MAX_IMAGE_WIDTH (over-max clamp)");

    end if;

    sImgW <= IMG_W;
    sImgH <= IMG_H;
    do_reset;                                  -- abort the fallback image

    WriteBin(covSweep);
    WriteBin(covUp);
    WriteBin(covB2B);
    WriteBin(covRst);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covSweep), "bp x input-stall x prelude cross closed");
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covUp), "upstream-stall-propagation coverage closed");
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covB2B), "back-to-back coverage closed");
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covRst), "reset-recovery coverage closed");

    end_of_test("tb_openjls_top_osvvm");
    wait;

  end process stim;

  watchdog : process is
  begin

    wait for 200 ms;
    Alert(GetAlertLogID("Watchdog"), "tb_openjls_top_osvvm: watchdog timeout", FAILURE);
    std.env.stop;

  end process watchdog;

end architecture sim;
