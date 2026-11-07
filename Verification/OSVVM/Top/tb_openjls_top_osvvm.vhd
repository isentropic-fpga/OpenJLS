-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_openjls_top_osvvm: openjls_top control plane under stress against the H.3 golden
--
-- Payload correctness belongs to the golden suite; this TB checks the output
-- stays byte-identical under backpressure, input stalls, resets and
-- back-to-back images. Phase B's 48x48 noise image is big enough for a held
-- iReady to stall oReady.
--
-- Guidelines:
--   G2.MinMax   N/A: owned by module TBs
--   G2.Clamp    N/A: owned by module TBs
--   G2.Checked  N/A: slv byte compare, X never matches
--   G3.Stim     N/A: owned by module TBs
--   G4.Config   BITNESS N/A: 12 and 16 run in tb_openjls_axis_osvvm
--   G4 other    N/A: Run/Coding owned by module TBs + golden suite

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library osvvm;
  context osvvm.OsvvmContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_openjls_top_osvvm is
  generic (
    MAX_W      : positive := 4096;
    MAX_H      : positive := 4096;
    OUT_WIDTH  : natural  := CO_OUT_WIDTH_STD;
    -- Bind to the funcsim netlist (Verification/Post synth); defaults only
    POST_SYNTH : boolean  := false
  );
end entity tb_openjls_top_osvvm;

architecture sim of tb_openjls_top_osvvm is

  constant CLK_PERIOD     : time     := CLK_PERIOD_DEFAULT;
  constant BITNESS        : natural  := 8;
  constant BYTES_PER_WORD : natural  := OUT_WIDTH / 8;

  constant IMG_W : natural := 4;
  constant IMG_H : natural := 4;

  -- Noise is incompressible, so its output outgrows the framer and byte_stuffer buffers
  constant BIG_W : natural := 48;
  constant BIG_H : natural := 48;

  constant HOLD_CYCLES : natural := 1200;
  -- Past every per-image queue in openjls_top (deepest: jls_framer start queue, 4)
  constant FLOOD_IMAGES : natural := 8;

  type pixel_array_t is array (natural range <>) of natural;

  constant PIXELS : pixel_array_t(0 to 15) :=
    (0, 0, 90, 74, 68, 50, 43, 205, 64, 145, 145, 145, 100, 145, 145, 145);

  type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);

  -- T.87 H.3 golden
  constant EXPECTED : byte_array_t(0 to 56) :=
    (x"FF", x"D8", x"FF", x"F7", x"00", x"0B", x"08", x"00", x"04", x"00", x"04",
     x"01", x"01", x"11", x"00", x"FF", x"DA", x"00", x"08", x"01", x"01", x"00",
     x"00", x"00", x"00",
     x"C0", x"00", x"00", x"6C", x"80", x"20", x"8E", x"01", x"C0", x"00", x"00",
     x"57", x"40", x"00", x"00", x"6E", x"E6", x"00", x"00", x"01", x"BC", x"18",
     x"00", x"00", x"05", x"D8", x"00", x"00", x"91", x"60",
     x"FF", x"D9");
  constant EXP_BYTES : natural := EXPECTED'length;

  -- Two run interruptions hit the same context one stage apart (sFwdRiHit).
  -- RI_EXPECTED is the CharLS golden.
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

  -- C[Q] at MAX_C/MIN_C under forwarding must stay off chains P/M; row 0 keeps one context
  constant CSAT_W : natural := 136;

  constant CSAT_P_PIXELS : pixel_array_t(0 to CSAT_W - 1) :=
    (194, 118, 69, 42, 255, 171, 152, 116, 35, 255, 128, 85, 255, 195, 179, 65, 255,
     162, 47, 254, 115, 38, 0, 33, 255, 186, 120, 255, 138, 255, 134, 62, 255, 203,
     128, 225, 96, 255, 109, 255, 98, 255, 140, 44, 255, 112, 21, 241, 160, 255, 115,
     255, 180, 53, 183, 52, 35, 136, 255, 105, 0, 43, 163, 255, 94, 255, 138, 255,
     124, 234, 150, 255, 80, 255, 115, 255, 130, 48, 181, 255, 120, 255, 53, 230, 70,
     156, 255, 60, 255, 66, 220, 69, 195, 29, 142, 248, 92, 156, 52, 197, 72, 157,
     255, 68, 227, 33, 255, 48, 162, 255, 29, 255, 65, 137, 255, 80, 204, 28, 223,
     255, 30, 177, 255, 75, 255, 34, 150, 180, 255, 109, 164, 255, 60, 220, 255, 103);

  constant CSAT_P_EXPECTED : byte_array_t(0 to 178) :=
    (x"FF", x"D8", x"FF", x"F7", x"00", x"0B", x"08", x"00", x"01", x"00", x"88",
     x"01", x"01", x"11", x"00", x"FF", x"DA", x"00", x"08", x"01", x"01", x"00",
     x"00", x"00", x"00", x"00", x"00", x"01", x"79", x"00", x"00", x"01", x"97",
     x"60", x"E4", x"A0", x"60", x"B9", x"F0", x"A9", x"E0", x"6C", x"42", x"2B",
     x"30", x"46", x"12", x"19", x"8B", x"42", x"27", x"E1", x"C1", x"CB", x"11",
     x"06", x"C2", x"E2", x"A0", x"80", x"76", x"18", x"0F", x"4A", x"C8", x"5A",
     x"95", x"87", x"C3", x"F3", x"E0", x"B8", x"52", x"1B", x"9E", x"0A", x"CD",
     x"D1", x"84", x"85", x"EB", x"C8", x"C3", x"21", x"E0", x"8D", x"C8", x"B0",
     x"54", x"2E", x"22", x"8E", x"06", x"43", x"E3", x"01", x"54", x"F4", x"29",
     x"09", x"58", x"8D", x"C5", x"82", x"31", x"8B", x"21", x"A0", x"56", x"98",
     x"26", x"2D", x"35", x"52", x"2B", x"0A", x"CE", x"CB", x"03", x"C7", x"43",
     x"00", x"90", x"56", x"18", x"20", x"85", x"0C", x"82", x"03", x"D1", x"68",
     x"64", x"F6", x"40", x"32", x"25", x"1D", x"BD", x"08", x"CF", x"07", x"0F",
     x"47", x"A8", x"42", x"81", x"F1", x"D0", x"70", x"82", x"32", x"3B", x"AE",
     x"10", x"1D", x"1F", x"D8", x"42", x"D3", x"69", x"3D", x"F1", x"F5", x"04",
     x"C8", x"6A", x"33", x"BC", x"AA", x"97", x"19", x"84", x"84", x"83", x"E5",
     x"90", x"FF", x"D9");

  constant CSAT_M_PIXELS : pixel_array_t(0 to CSAT_W - 1) :=
    (255, 95, 153, 255, 255, 92, 114, 210, 250, 116, 150, 255, 39, 55, 176, 58, 80,
     121, 228, 255, 73, 147, 255, 63, 199, 255, 21, 118, 255, 109, 180, 56, 121, 156,
     255, 73, 217, 80, 137, 255, 115, 255, 83, 198, 107, 159, 255, 115, 255, 62, 190,
     255, 83, 167, 255, 104, 255, 76, 255, 111, 203, 81, 255, 64, 221, 86, 255, 78,
     160, 255, 81, 158, 53, 180, 77, 246, 74, 255, 24, 168, 115, 255, 91, 255, 91,
     236, 118, 255, 89, 255, 110, 63, 255, 123, 255, 107, 40, 255, 46, 255, 98, 255,
     255, 40, 0, 255, 93, 255, 52, 255, 117, 255, 73, 255, 60, 254, 104, 255, 113,
     255, 34, 255, 97, 75, 255, 119, 22, 255, 118, 255, 113, 27, 24, 24, 23, 133);

  constant CSAT_M_EXPECTED : byte_array_t(0 to 175) :=
    (x"FF", x"D8", x"FF", x"F7", x"00", x"0B", x"08", x"00", x"01", x"00", x"88",
     x"01", x"01", x"11", x"00", x"FF", x"DA", x"00", x"08", x"01", x"01", x"00",
     x"00", x"00", x"00", x"40", x"00", x"00", x"1B", x"E7", x"11", x"1E", x"00",
     x"F3", x"8C", x"EA", x"86", x"34", x"F3", x"3F", x"A7", x"C9", x"16", x"47",
     x"99", x"FC", x"CE", x"B4", x"CA", x"6D", x"A6", x"F7", x"F1", x"8D", x"07",
     x"59", x"3C", x"5D", x"16", x"D5", x"44", x"D4", x"58", x"E4", x"52", x"98",
     x"B6", x"67", x"D2", x"61", x"19", x"D9", x"2A", x"74", x"9B", x"D6", x"47",
     x"9D", x"CE", x"BB", x"FD", x"4F", x"CF", x"A9", x"F0", x"71", x"DA", x"2C",
     x"14", x"CB", x"D5", x"BF", x"86", x"A3", x"71", x"A0", x"57", x"AA", x"D6",
     x"8A", x"76", x"7E", x"DD", x"47", x"1E", x"A1", x"EF", x"50", x"AF", x"D2",
     x"AD", x"3B", x"14", x"2B", x"E7", x"E5", x"6E", x"A5", x"5B", x"FD", x"BB",
     x"79", x"D6", x"69", x"D6", x"EB", x"BD", x"96", x"F7", x"CF", x"6B", x"AF",
     x"5D", x"FB", x"AD", x"F6", x"2F", x"9C", x"06", x"8B", x"95", x"17", x"7E",
     x"BD", x"2C", x"37", x"5D", x"EA", x"4D", x"23", x"F2", x"A5", x"68", x"E5",
     x"B8", x"ED", x"71", x"59", x"EC", x"37", x"2F", x"BB", x"BF", x"25", x"B6",
     x"ED", x"97", x"71", x"EA", x"BE", x"5F", x"EF", x"DA", x"40", x"FF", x"D9");

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
  signal sImgW : natural;
  signal sImgH : natural;

  -- 0 always ready, 1 random (~33%), 2 hold low for HOLD_CYCLES once
  signal sBpMode : natural range 0 to 2;

  -- Arms the no-stall monitor; only clean feeds may set it
  signal sNoStall : boolean := false;

  shared variable collected      : byte_array_t(0 to 32767);
  shared variable collectedCount : natural;
  shared variable lastCount      : natural;
  -- Offered pixels refused by the DUT
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

  -- Component + default binding: the funcsim netlist has no generics and its
  -- architecture is STRUCTURE, so entity work.openjls_top(rtl) can't bind to it
  dut : if POST_SYNTH generate

    -- Ports at this TB's defaults; any other netlist fails elaboration
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

  -- Output collector ---
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

  -- Upstream stall monitor ---
  stall_mon : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '0' and iValid = '1' and oReady = '0') then
        feedStallCnt := feedStallCnt + 1;
      end if;
    end if;

  end process stall_mon;

  -- No-stall monitor ---
  -- While armed, every offered pixel is accepted at once, line and image
  -- boundaries included. Goals are lower bounds, so a vacuous run fails.
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

  -- Downstream backpressure ---
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

          -- ~33% ready
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

  -- Stimulus ---
  stim : process is

    variable rv         : RandomPType;
    variable covSweep   : CoverageIDType;
    variable pt         : integer_vector(1 to 3);
    variable nImages    : positive;
    variable covUp      : CoverageIDType;
    variable covB2B     : CoverageIDType;
    variable covRst     : CoverageIDType;
    variable covCfg     : CoverageIDType;
    variable base       : natural;
    variable baseL      : natural;
    variable bigImg     : pixel_array_t(0 to BIG_W * BIG_H - 1);
    variable refBuf     : byte_array_t(0 to 8191);
    variable refLen     : natural;
    variable vStallSnap : natural;
    variable reqH3      : AlertLogIDType;
    variable reqB2B     : AlertLogIDType;
    variable reqRI      : AlertLogIDType;
    variable reqCSat    : AlertLogIDType;
    variable reqFlood   : AlertLogIDType;
    variable floodOk    : boolean;

    procedure do_reset is
    begin

      rst    <= '1';
      iValid <= '0';
      iPixel <= (others => '0');
      clk_tick(clk, 4);

      -- In-flight beats of an aborted image must be dropped
      wait for 1 ns;
      AffirmIf(GetAlertLogID("ResetRecovery"), oValid = '0', "reset: output stream idle");
      AffirmIf(GetAlertLogID("ResetRecovery"), oLast = '0', "reset: oLast cleared");

      rst <= '0';
      wait until rising_edge(clk);

      while (oReady /= '1') loop

        wait until rising_edge(clk);

      end loop;

    end procedure do_reset;

    -- stall inserts random iValid gaps; count truncates the image for reset injection
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

    -- `images` H.3 images back-to-back, checked against as many golden copies
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
        -- Image 1's oLast can't have fired yet, so image 2 overlaps its drain
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

    procedure run_golden (
      pixels   : pixel_array_t;
      expected : byte_array_t;
      req      : AlertLogIDType;
      msg      : string
    ) is
    begin

      do_reset;
      base     := collectedCount;
      baseL    := lastCount;
      sBpMode  <= 0;
      sNoStall <= false;
      feed(pixels, false, pixels'length);
      wait_images(1);

      AffirmIfEqual(req, collectedCount - base, expected'length, msg & " byte count");
      for i in 0 to expected'length - 1 loop

        if (base + i < collectedCount) then
          AffirmIfEqual(req, collected(base + i), expected(i), msg & " byte " & integer'image(i));
        end if;

      end loop;

    end procedure run_golden;

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
    covSweep := NewID("G4.Stream bp x inputStall x prelude");
    SetFieldName(covSweep, "bp", "inputStall", "prelude");
    for axis0 in 0 to 1 loop
      for axis1 in 0 to 1 loop
        for axis2 in 0 to 2 loop
          AddCross(covSweep, "bp=" & to_string(axis0) & " / " & "inputStall=" & to_string(axis1) & " / " & "prelude=" & to_string(axis2), GenBin(axis0), GenBin(axis1), GenBin(axis2));
        end loop;
      end loop;
    end loop;
    covUp := NewID("G4.Stream upstreamStallPropagated");
    SetFieldName(covUp, "upstreamStallPropagated");
    AddBins(covUp, "upstreamStallPropagated", GenBin(1, 1));
    covB2B := NewID("G4.Stream backToBack clean/stressed/minimal");
    SetFieldName(covB2B, "backToBack clean/stressed/minimal");
    AddBins(covB2B, "clean overlap", GenBin(0));
    AddBins(covB2B, "stressed overlap", GenBin(1));
    AddBins(covB2B, "minimal image overlap", GenBin(2));
    covRst := NewID("G5.States reset midFeed/midFeedStress/midDrain");
    SetFieldName(covRst, "reset midFeed/midFeedStress/midDrain");
    AddBins(covRst, "reset during input", GenBin(0));
    AddBins(covRst, "reset during stressed input", GenBin(1));
    AddBins(covRst, "reset during output", GenBin(2));

    -- MAX is only reached in the MAX 48x48 variant
    covCfg := NewID("G4.Config G4.Edge width x height");
    AddBins(covCfg, "width=4 / height=1", GenBin(0));
    if (MAX_W = BIG_W and MAX_H = BIG_H) then
      AddBins(covCfg, "width=MAX / height=MAX", GenBin(1));
    end if;

    -- BackToBack: b2b x3, B5 and C
    reqH3    := GetReqID("T87.H3", EXP_BYTES);
    reqB2B   := GetReqID("OJLS.BackToBack", 3);
    reqRI    := GetReqID("OJLS.RIForward", RI_EXP_BYTES);
    reqFlood := GetReqID("OJLS.ImageFlood", 2 * (FLOOD_IMAGES + 1));

    do_reset;

    -- Phase A: H.3 under each stress axis ---
    run_check(0, false, 1, "baseline");
    run_check(1, false, 1, "downstream backpressure");
    run_check(0, true, 1, "input stall");
    run_check(1, true, 1, "backpressure + stall");

    -- Back-to-back ---
    run_check(0, false, 3, "b2b x3");
    ICover(covB2B, 0);

    -- Mid-image reset ---
    sBpMode <= 0;
    feed(PIXELS, false, 8);
    do_reset;
    run_check(0, false, 1, "post-reset recovery");
    ICover(covRst, 0);

    sBpMode  <= 1;
    sNoStall <= false;
    feed(PIXELS, true, 6);
    do_reset;
    run_check(1, true, 1, "post-reset recovery under stress");
    ICover(covRst, 1);

    -- Intelligent Coverage sweep ---
    -- prelude: 0 none, 1 aborted partial image, 2 back-to-back pair
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

    -- RI context forwarding ---
    -- The only image that takes sFwdRiHit
    sImgW <= RI_W;
    sImgH <= RI_H;
    run_golden(RI_PIXELS, RI_EXPECTED, reqRI, "RI-forward");

    -- Regular context forwarding with C[Q] saturated ---
    if (MAX_W >= CSAT_W) then
      reqCSat := GetReqID("OJLS.CSatForward", CSAT_P_EXPECTED'length + CSAT_M_EXPECTED'length);
      sImgW   <= CSAT_W;
      sImgH   <= 1;
      run_golden(CSAT_P_PIXELS, CSAT_P_EXPECTED, reqCSat, "C=MAX_C forward");
      run_golden(CSAT_M_PIXELS, CSAT_M_EXPECTED, reqCSat, "C=MIN_C forward");
    end if;

    -- Phase B: 48x48 noise, clean run as the reference ---
    sImgW <= BIG_W;
    sImgH <= BIG_H;
    do_reset;

    for i in bigImg'range loop

      bigImg(i) := rv.RandInt(0, 2 ** BITNESS - 1);

    end loop;

    -- B1: clean reference
    base     := collectedCount;
    baseL    := lastCount;
    sBpMode  <= 0;
    sNoStall <= true;
    feed(bigImg, false, bigImg'length);
    wait_images(1);
    refLen := collectedCount - base;
    AffirmIfEqual(GetAlertLogID("DataChecks"), lastCount - baseL, 1, "B1: reference image completed");
    ICover(covCfg, 1);
    -- Smaller than the buffers, B3 could never stall
    AffirmIf(GetAlertLogID("DataChecks"), refLen > 1000, "B1: stress image defeats internal buffering" &
                            " (refLen=" & integer'image(refLen) & ")");
    for i in 0 to refLen - 1 loop

      refBuf(i) := collected(base + i);

    end loop;

    -- B2: reset while the output drains
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

    -- B3: a long iReady hold must drop oReady
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

    -- B4: random backpressure and input stalls
    base    := collectedCount;
    baseL   := lastCount;
    sBpMode <= 1;
    feed(bigImg, true, bigImg'length);
    wait_images(1);
    check_against_ref("B4 random stress");

    -- B5: B4, back-to-back
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

    -- Phase C: 4x1 back-to-back ---
    -- Each image feeds faster than the pipeline flushes, the tightest case for
    -- start/EOI bookkeeping
    sImgW <= 4;
    sImgH <= 1;
    do_reset;

    base     := collectedCount;
    baseL    := lastCount;
    sBpMode  <= 0;
    sNoStall <= true;
    feed(PIXELS, false, 4);
    wait_images(1);
    refLen := collectedCount - base;
    AffirmIfEqual(GetAlertLogID("DataChecks"), lastCount - baseL, 1, "C: reference 4x1 image completed");
    ICover(covCfg, 0);
    for i in 0 to refLen - 1 loop

      refBuf(i) := collected(base + i);

    end loop;

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

    -- Flood: minimal images past every per-image queue, downstream ready then held ---
    -- With iReady high only the in-flight cap can drop oReady
    sNoStall <= false;
    for held in boolean loop

      vStallSnap := feedStallCnt;
      base       := collectedCount;
      baseL      := lastCount;
      sBpMode    <= 2 when held else 0;
      for n in 1 to FLOOD_IMAGES loop

        feed(PIXELS, false, 4);

      end loop;
      wait_images(FLOOD_IMAGES);
      sBpMode <= 0;
      AffirmIf(reqFlood, feedStallCnt > vStallSnap, "flood held=" & boolean'image(held) & " stalled the input");

      for n in 0 to FLOOD_IMAGES - 1 loop

        floodOk := collectedCount - base = FLOOD_IMAGES * refLen;
        for i in 0 to refLen - 1 loop

          floodOk := floodOk and base + n * refLen + i < collectedCount and
                     collected(base + n * refLen + i) = refBuf(i);

        end loop;
        AffirmIf(reqFlood, floodOk, "flood held=" & boolean'image(held) & " image " & integer'image(n) & " byte-exact");

      end loop;

    end loop;

    -- Phase D: below-minimum dims fall back to MAX ---
    -- Only the header's Y/X fields are checked; the image is then aborted
    sImgW    <= 0;
    sImgH    <= 0;
    sNoStall <= false;   -- pxIdx line math assumes sImgW
    do_reset;
    base    := collectedCount;
    sBpMode <= 0;
    -- Above OUT_WIDTH 200 the first beat waits for payload bytes
    feed(bigImg, false, bigImg'length);

    for i in 0 to 199999 loop

      exit when collectedCount - base >= 14;
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

    -- Phase D2: above-maximum dims clamp to MAX ---
    -- Needs MAX + 1 to fit the 16-bit port
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
    do_reset;

    WriteBin(covSweep);
    WriteBin(covUp);
    WriteBin(covB2B);
    WriteBin(covRst);
    affirm_covered(covCfg, "width x height coverage closed");
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
