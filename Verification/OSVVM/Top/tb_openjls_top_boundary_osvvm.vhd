-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_openjls_top_boundary_osvvm: no state may cross an image boundary, at any BITNESS
--
-- Each image is encoded alone after a reset, then the same images run back-to-back with no
-- reset. The streams must match: a context, forward or parity leak across the boundary changes
-- the bytes. Noise and flood phases give BITNESS 12 and 16 the control-plane stress of
-- tb_openjls_top_osvvm, whose references are 8-bit.
--
-- Guidelines:
--   G1          N/A: the reference is the DUT's own post-reset run; byte accuracy is owned by the golden suite
--   G2          N/A: owned by module TBs
--   G3          N/A: owned by module TBs
--   G4 other    N/A: Edge/Run/Coding owned by module TBs + golden suite
--   G5          N/A: resets belong to tb_openjls_top_osvvm

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library osvvm;
  context osvvm.OsvvmContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_openjls_top_boundary_osvvm is
  generic (
    BITNESS   : positive range 8 to 16 := 8;
    OUT_WIDTH : natural                := CO_OUT_WIDTH_STD
  );
end entity tb_openjls_top_boundary_osvvm;

architecture sim of tb_openjls_top_boundary_osvvm is

  constant CLK_PERIOD     : time    := CLK_PERIOD_DEFAULT;
  constant BYTES_PER_WORD : natural := OUT_WIDTH / 8;
  constant MAXV           : natural := 2 ** BITNESS - 1;
  constant MAX_DIM        : natural := 64;
  constant HOLD_CYCLES    : natural := 1200;
  constant NOISE_W        : natural := 48;
  constant NOISE_H        : natural := 48;
  constant FLOOD_IMAGES   : natural := 8;
  constant MAX_STREAM     : natural := 40;

  type pixel_array_t is array (natural range <>) of natural;
  type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);

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

  -- Latched by the DUT during reset
  signal sImgW : natural := 4;
  signal sImgH : natural := 1;

  -- 0 always ready, 1 random (~33%), 2 hold low for HOLD_CYCLES once
  signal sBpMode : natural range 0 to 2 := 0;

  shared variable collected      : byte_array_t(0 to 131071);
  shared variable collectedCount : natural := 0;
  shared variable lastCount      : natural := 0;
  shared variable feedStallCnt   : natural := 0;

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

  dut : entity work.openjls_top(rtl)
    generic map (
      BITNESS          => BITNESS,
      MAX_IMAGE_WIDTH  => MAX_DIM,
      MAX_IMAGE_HEIGHT => MAX_DIM,
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

  collect_proc : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '1') then
        collectedCount := 0;
        lastCount      := 0;
      elsif (oValid = '1' and iReady = '1') then

        for i in 0 to BYTES_PER_WORD - 1 loop

          if (oKeep(BYTES_PER_WORD - 1 - i) = '1') then
            collected(collectedCount) := oData(OUT_WIDTH - 1 - i * 8 downto OUT_WIDTH - (i + 1) * 8);
            collectedCount            := collectedCount + 1;
          end if;

        end loop;

        if (oLast = '1') then
          lastCount := lastCount + 1;
        end if;
      end if;

      if (rst = '0' and iValid = '1' and oReady = '0') then
        feedStallCnt := feedStallCnt + 1;
      end if;
    end if;

  end process collect_proc;

  ready_proc : process is

    variable rv      : RandomPType;
    variable holdCnt : natural := 0;

  begin

    rv.InitSeed("boundary ready" & run_seed);
    iReady <= '1';

    loop

      wait until rising_edge(clk);

      case sBpMode is

        when 0 =>

          iReady  <= '1';
          holdCnt := 0;

        when 1 =>

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

  stim : process is

    variable rv        : RandomPType;
    variable reqStream : AlertLogIDType;
    variable reqNoise  : AlertLogIDType;
    variable refBuf    : byte_array_t(0 to 131071);
    variable refEnd    : integer_vector(0 to MAX_STREAM);
    variable snap      : natural;

    procedure do_reset is
    begin

      sBpMode <= 0;
      rst     <= '1';
      iValid  <= '0';
      iPixel  <= (others => '0');
      clk_tick(clk, 4);
      rst     <= '0';
      wait until rising_edge(clk);

      while (oReady /= '1') loop

        wait until rising_edge(clk);

      end loop;

    end procedure do_reset;

    procedure feed (
      img   : pixel_array_t;
      stall : boolean
    ) is
    begin

      for i in img'range loop

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

      for i in 0 to 999999 loop

        exit when lastCount >= n;
        wait until rising_edge(clk);

      end loop;

      AffirmIfEqual(GetAlertLogID("ImageCompletion"), lastCount, n, "expected image boundaries before timeout");

    end procedure wait_images;

    -- Encode each image alone, then the same images with no reset between them
    procedure check_stream (
      w     : natural;
      h     : natural;
      imgs  : pixel_array_t;
      stall : boolean;
      bp    : natural;
      msg   : string
    ) is

      constant N       : natural := imgs'length / (w * h);
      variable total   : natural := 0;
      variable ok      : boolean;
      variable first   : natural := 0;

    begin

      sImgW <= w;
      sImgH <= h;
      wait until rising_edge(clk);

      for k in 0 to N - 1 loop

        do_reset;
        feed(imgs(k * w * h to (k + 1) * w * h - 1), false);
        wait_images(1);

        for i in 0 to collectedCount - 1 loop

          refBuf(total + i) := collected(i);

        end loop;

        total       := total + collectedCount;
        refEnd(k)   := total;

      end loop;

      do_reset;
      sBpMode <= bp;
      feed(imgs, stall);
      wait_images(N);
      sBpMode <= 0;

      AffirmIfEqual(GetAlertLogID("DataChecks"), collectedCount, total, msg & " byte count");

      for k in 0 to N - 1 loop

        ok := collectedCount = total;

        for i in first to refEnd(k) - 1 loop

          ok := ok and collected(i) = refBuf(i);

        end loop;

        AffirmIf(reqStream, ok, msg & " image " & integer'image(k) & " matches its post-reset encoding");
        first := refEnd(k);

      end loop;

    end procedure check_stream;

    -- Pixels from 0 to top, so contexts repeat across the boundary
    procedure random_stream (
      w      : natural;
      h      : natural;
      top    : natural;
      n      : natural;
      stall  : boolean;
      bp     : natural
    ) is

      variable imgs : pixel_array_t(0 to n * w * h - 1);

    begin

      for i in imgs'range loop

        imgs(i) := rv.RandInt(0, top);

      end loop;

      check_stream(w, h, imgs, stall, bp, "random " & to_string(w) & "x" & to_string(h) & " top=" & to_string(top));

    end procedure random_stream;

    procedure noise_stress is

      variable img : pixel_array_t(0 to NOISE_W * NOISE_H - 1);
      variable ok  : boolean;
      variable len : natural;

      procedure compare (
        images : natural;
        msg    : string
      ) is
      begin

        ok := collectedCount = images * len;

        for i in 0 to images * len - 1 loop

          ok := ok and i < collectedCount and collected(i) = refBuf(i mod len);

        end loop;

        AffirmIf(reqNoise, ok, msg);

      end procedure compare;

    begin

      for i in img'range loop

        img(i) := rv.RandInt(0, MAXV);

      end loop;

      sImgW <= NOISE_W;
      sImgH <= NOISE_H;
      wait until rising_edge(clk);
      do_reset;
      feed(img, false);
      wait_images(1);
      len := collectedCount;

      for i in 0 to len - 1 loop

        refBuf(i) := collected(i);

      end loop;

      AffirmIf(GetAlertLogID("DataChecks"), len > 1000, "noise image larger than the internal buffers");

      -- A long downstream hold must reach oReady
      do_reset;
      snap    := feedStallCnt;
      sBpMode <= 2;
      feed(img, false);
      wait_images(1);
      sBpMode <= 0;
      AffirmIf(GetAlertLogID("FlowControl"), feedStallCnt > snap, "downstream hold reached oReady");
      compare(1, "noise, downstream hold");

      do_reset;
      sBpMode <= 1;
      feed(img, true);
      wait_images(1);
      compare(1, "noise, random backpressure and input stalls");

      do_reset;
      sBpMode <= 1;
      feed(img, true);
      AffirmIf(GetAlertLogID("DataChecks"), lastCount = 0, "second image fed while the first drains");
      feed(img, true);
      wait_images(2);
      compare(2, "noise, back-to-back under stress");

    end procedure noise_stress;

    procedure flood (
      held : boolean
    ) is

      variable img : pixel_array_t(0 to FLOOD_IMAGES * 4 - 1);
      variable ok  : boolean;

    begin

      for i in img'range loop

        img(i) := (i mod 4) * MAXV / 3;

      end loop;

      sImgW <= 4;
      sImgH <= 1;
      wait until rising_edge(clk);
      do_reset;
      feed(img(0 to 3), false);
      wait_images(1);
      snap := collectedCount;

      for i in 0 to snap - 1 loop

        refBuf(i) := collected(i);

      end loop;

      do_reset;
      sBpMode <= 2 when held else 0;
      feed(img, false);
      wait_images(FLOOD_IMAGES);
      sBpMode <= 0;

      ok := collectedCount = FLOOD_IMAGES * snap;

      for i in 0 to FLOOD_IMAGES * snap - 1 loop

        ok := ok and i < collectedCount and collected(i) = refBuf(i mod snap);

      end loop;

      AffirmIf(reqNoise, ok, "flood held=" & boolean'image(held) & " byte-exact");

    end procedure flood;

    variable direct : pixel_array_t(0 to 4 * 3 - 1);

  begin

    rst    <= '1';
    iValid <= '0';
    iPixel <= (others => '0');

    SetAlertLogName("tb_openjls_top_boundary_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name & run_seed);
    reqStream := GetReqID("OJLS.ImageBoundary", 643);
    reqNoise  := GetReqID("OJLS.StressAllDepths", 5);

    -- Run interruption with RItype 1 on the last pixel, then on the next image's first pixel:
    -- the second read sits one stage behind the first's write-back and must see init values
    for k in 0 to 2 loop

      direct(4 * k)     := MAXV / 2;
      direct(4 * k + 1) := 0;
      direct(4 * k + 2) := 0;
      direct(4 * k + 3) := MAXV / 2;

    end loop;

    check_stream(4, 1, direct, false, 0, "directed RI boundary");

    for top in 1 to 3 loop

      random_stream(4, 1, top, 40, false, 0);
      random_stream(4, 2, top, 40, false, 0);
      random_stream(5, 1, top, 40, false, 0);
      random_stream(8, 2, top, 20, false, 0);
      random_stream(4, 1, top, 40, true, 1);

    end loop;

    random_stream(4, 1, MAXV, 40, false, 0);
    random_stream(4, 3, MAXV, 40, false, 0);
    random_stream(8, 2, MAXV, 20, true, 1);

    noise_stress;
    flood(false);
    flood(true);

    end_of_test("tb_openjls_top_boundary_osvvm");
    wait;

  end process stim;

  watchdog : process is
  begin

    wait for 400 ms;
    Alert(GetAlertLogID("Watchdog"), "tb_openjls_top_boundary_osvvm: watchdog timeout", FAILURE);
    std.env.stop;

  end process watchdog;

end architecture sim;
