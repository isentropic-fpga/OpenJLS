-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: jls_framer (stateful AXI-stream framer).
--
-- Wraps the byte-stuffed payload with the JPEG-LS frame: 25-byte header
-- (SOI + SOF55 + SOS, with runtime height/width) before the data
-- and the EOI footer FF D9 after it. The reference is the JPEG-LS frame format
-- (T.87): for each image the expected output byte stream is
--   header(W,H) ++ payload_bytes ++ 0xFF 0xD9
-- pushed to an OSVVM scoreboard in emission order. The monitor pops every output
-- byte (oByteEnable bytes per beat, MSB-first) on the AXI handshake and checks it,
-- and asserts oLast lands exactly on the trailing 0xD9 beat. Upstream oReady and
-- downstream random iReady backpressure are both honoured. Images are serialized
-- (drain before the next) so dimensions stay coherent.
--------------------------------------------------------------------------------

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
  -- Non-default variants are driven from OpenJls.pro via [generic ...].
  generic (
    OUT_WIDTH : natural  := CO_OUT_WIDTH_STD;                   -- 64
    MAX_W     : positive := 4096;
    MAX_H     : positive := 4096
  );
end entity tb_jls_framer_osvvm;

architecture sim of tb_jls_framer_osvvm is

  constant BITNESS    : natural := CO_BITNESS_STD;
  constant IN_WIDTH   : natural := CO_BYTE_STUFFER_OUT_WIDTH;   -- 32
  constant BYTES_IN   : natural := IN_WIDTH / 8;
  constant BYTES_OUT  : natural := OUT_WIDTH / 8;
  constant WDIM       : natural := log2ceil(MAX_W + 1);
  constant HDIM       : natural := log2ceil(MAX_H + 1);
  constant BE_IN_W    : natural := log2ceil(IN_WIDTH / 8 + 1);
  constant BE_OUT_W   : natural := log2ceil(OUT_WIDTH / 8 + 1);
  constant CLK_PERIOD : time    := CLK_PERIOD_DEFAULT;
  constant N_IMAGES   : natural := 30;
  -- Scale image length with the beat size so wide OUT_WIDTHs still emit full
  -- data beats (payload must outrun the 25-byte header's final-beat fill).
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
  -- Monitor ignores output during an aborted (reset-interrupted) image.
  signal sIgnore           : boolean := false;

  -- JPEG-LS frame header (T.87), transcribed independently of the RTL ROM.
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

  -----------------------------------------------------------------------------
  -- Driver: per image push header(W,H) ++ payload ++ FF D9 to the scoreboard,
  -- then stream the payload words (honouring oReady) with iEoi on the last.
  -----------------------------------------------------------------------------
  driver : process is

    variable rv : RandomPType;

    -- Wait for an oReady cycle, present the word, push it on the edge.
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

    -- Push one full image: header(w,h) ++ payload ++ FF D9 to the scoreboard
    -- and stream the matching payload words (iEoi on the last).
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

    apply_reset(clk, rst, 4, '1');

    for img in 1 to N_IMAGES loop

      send_image(rv.RandInt(4, MAX_W), rv.RandInt(1, MAX_H), rv.RandInt(1, MAX_WORDS));
      sImagesSent <= img;
      -- Serialize: drain this image before the next (keeps dims coherent).
      wait until sImagesDone = img;

    end loop;

    --------------------------------------------------------------------------
    -- Mid-operation iRst: start an image and abort it with iRst before the
    -- footer. The aborted output is ignored (never pushed to the scoreboard);
    -- after reset the framer must be idle, and the next image must frame
    -- correctly. Recovery goes through the scoreboard normally.
    --------------------------------------------------------------------------
    sIgnore <= true;
    iWidth  <= to_unsigned(64, WDIM);
    iHeight <= to_unsigned(64, HDIM);
    push_word(rv.RandSlv(IN_WIDTH), 4, '0', '1');   -- iStart + first word, no sb push
    push_word(rv.RandSlv(IN_WIDTH), 4, '0', '0');
    push_word(rv.RandSlv(IN_WIDTH), 4, '0', '0');
    apply_reset(clk, rst, 4, '1');
    wait for 1 ns;
    AffirmIf(GetAlertLogID("ResetRecovery"), oValid = '0', "mid-op reset: framer output idle after iRst");
    sIgnore <= false;
    wait until rising_edge(clk);

    send_image(rv.RandInt(4, MAX_W), rv.RandInt(1, MAX_H), rv.RandInt(1, MAX_WORDS));
    sImagesSent <= N_IMAGES + 1;
    wait until sImagesDone = N_IMAGES + 1;

    --------------------------------------------------------------------------
    -- Directed: two back-to-back minimal images (payload = the FF D9 footer
    -- only, zero stuffed bytes). Both EOIs queue inside the framer while the
    -- first image's header is still draining — the EOI lands in the final
    -- partial header beat, the EOI FIFO holds its full EOI_FIFO_DEPTH=2, the
    -- pop shifts the second entry down, and the FSM takes both terminal arms:
    -- straight back to header (image B pending) and then to idle.
    --------------------------------------------------------------------------
    for img in 1 to 2 loop

      for k in 0 to 24 loop

        Push(SB_ID, '0' & header_byte(k, 16, 1));

      end loop;

      Push(SB_ID, '0' & x"FF");
      Push(SB_ID, '1' & x"D9");

    end loop;

    iWidth  <= to_unsigned(16, WDIM);
    iHeight <= to_unsigned(1, HDIM);
    push_word(rv.RandSlv(IN_WIDTH), 0, '1', '1');   -- image A: start+EOI, no payload
    push_word(rv.RandSlv(IN_WIDTH), 0, '1', '1');   -- image B: queued behind A
    sImagesSent <= N_IMAGES + 3;
    wait until sImagesDone = N_IMAGES + 3;

    sDriverDone <= true;
    wait;

  end process driver;

  -----------------------------------------------------------------------------
  -- Monitor: random downstream backpressure; check every output byte and that
  -- oLast coincides with the trailing 0xD9.
  -----------------------------------------------------------------------------
  monitor : process is

    variable rv      : RandomPType;
    variable nb      : natural;
    variable byte    : std_logic_vector(7 downto 0);
    variable lastByte : std_logic_vector(7 downto 0);
    variable done    : natural;
    variable covBeat : CoverageIDType;

  begin

    iReady <= '1';
    done   := 0;
    covBeat := NewID("partialBeat");
    SetFieldName(covBeat, "partialBeat");
    AddBins(covBeat, "partialBeat", GenBin(1, BYTES_OUT - 1, 1));
    AddBins(covBeat, "fullBeat", GenBin(BYTES_OUT, BYTES_OUT));
    rv.InitSeed(rv'instance_name);
    wait until rst = '0';

    loop

      -- ~80% ready.
      iReady <= bool2bit(rv.DistValInt(((1, 4), (0, 1))) = 1);
      wait for 1 ns;

      if (oValid = '1' and iReady = '1' and not sIgnore) then
        nb := checked_integer(oByteEn);
        AffirmIf(GetAlertLogID("Protocol"), nb >= 1 and nb <= BYTES_OUT, "valid beat has legal byte count");
        ICover(covBeat, nb);

        for i in 0 to nb - 1 loop

          byte     := oWord(OUT_WIDTH - 1 - i * 8 downto OUT_WIDTH - (i + 1) * 8);
          lastByte := byte;
          Check(SB_ID, bool2bit(oLast = '1' and i = nb - 1) & byte);

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

  -- Check the entire pending AXI beat, including metadata, across backpressure.
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
