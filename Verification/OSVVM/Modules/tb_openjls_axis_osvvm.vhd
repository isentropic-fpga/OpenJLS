-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM AXI4-Stream wrapper testbench: openjls_axis (flavor A).
--
-- Proves the AXI4-Stream adapter is transparent: for the T.87 Annex H.3 image
-- the reconstructed .jls byte stream is identical to the known-good 57-byte
-- golden, under every handshake condition the adapter must survive. The core's
-- own OSVVM TB owns payload correctness and native-interface stall coverage;
-- here the OSVVM AxiStream verification components drive the AXI boundary the
-- HIL demo exercised on silicon but the sim regression never did.
--
-- Pixels are streamed in via an AxiStreamTransmitter (one pixel per beat on
-- the byte-aligned lane the DUT derives from BITNESS; word-burst mode) and the
-- encoded stream is captured by an AxiStreamReceiver in byte-burst mode, which
-- honours TKEEP to drop the trailing bytes of the partial final beat --
-- exactly reconstructing the file byte order the wrapper produces. Five
-- back-to-back images cover the combinations:
--   run 0  clean                          run 1  output backpressure (TREADY gaps)
--   run 2  input stall (TVALID gaps)      run 3  both at once
--   run 4  input TLAST mid-image (image split across two send bursts)
-- Back-to-back (no reset between images) also exercises the adapter across the
-- core's image-boundary machinery. The BITNESS generic selects the image: 8
-- replays the H.3 conformance vectors, 12 a CharLS-minted golden whose pixels
-- ride a 16-bit lane with garbage driven on the TDATA bits above BITNESS.
--
-- Requirement tracked (see Verification/OSVVM/README.md registry):
--   OJLS.AxiStreamTransparent  m_axis_jls byte-identical to the golden for
--                              every image, under backpressure and input stalls
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library osvvm;
  context osvvm.OsvvmContext;
  use osvvm.ScoreboardPkg_slv.all;   -- Push/Pop/CheckBurst on the stream BurstFifo

library osvvm_axi4;
  context osvvm_axi4.AxiStreamContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_openjls_axis_osvvm is
  generic (
    BITNESS   : positive range 8 to 16    := H3_BITNESS;        -- 8 or 12
    OUT_WIDTH : positive range 48 to 1024 := CO_OUT_WIDTH_STD   -- 64
  );
end entity tb_openjls_axis_osvvm;

architecture sim of tb_openjls_axis_osvvm is

  constant CLK_PERIOD : time := CLK_PERIOD_DEFAULT;

  -- Pixel side: one sample per beat on a byte-aligned lane, following the DUT
  -- port law (8 bits for BITNESS 8, 16 bits for BITNESS 9..16). Encoded side:
  -- OUT_WIDTH-wide beats.
  constant PIX_DATA_W : natural := 8 * ((BITNESS + 7) / 8);
  constant JLS_DATA_W : natural := OUT_WIDTH;

  -- Golden vector selection: BITNESS 8 replays the T.87 Annex H.3 conformance
  -- image, BITNESS 12 the CharLS-minted companion (B12_* in tb_support_pkg).
  function pick_iv (constant a : integer_vector; constant b : integer_vector)
    return integer_vector is
  begin
    if BITNESS = 8 then
      return a;
    end if;
    return b;
  end function pick_iv;

  function pick_n (constant a : natural; constant b : natural) return natural is
  begin
    if BITNESS = 8 then
      return a;
    end if;
    return b;
  end function pick_n;

  constant IMG_PIXELS   : integer_vector := pick_iv(H3_PIXELS, B12_PIXELS);
  constant IMG_EXPECTED : integer_vector := pick_iv(H3_EXPECTED, B12_EXPECTED);
  constant IMG_WIDTH    : natural        := pick_n(H3_WIDTH, B12_WIDTH);
  constant IMG_HEIGHT   : natural        := pick_n(H3_HEIGHT, B12_HEIGHT);

  -- Sideband widths (unused by the DUT, but the VC ports must be sized).
  constant ID_W   : natural := 8;
  constant DEST_W : natural := 4;
  constant USER_W : natural := 4;
  constant PARAM_W : natural := ID_W + DEST_W + USER_W + 1;

  constant CINIT_ID   : std_logic_vector(ID_W - 1 downto 0)   := (others => '0');
  constant CINIT_DEST : std_logic_vector(DEST_W - 1 downto 0) := (others => '0');
  constant CINIT_USER : std_logic_vector(USER_W - 1 downto 0) := (others => '0');

  signal clk      : std_logic := '0';
  signal nReset   : std_logic := '0';
  signal sCoreRst : std_logic;

  -- Pixel AXI4-Stream (TB transmitter -> DUT slave)
  signal sPixTValid : std_logic;
  signal sPixTReady : std_logic;
  signal sPixTData  : std_logic_vector(PIX_DATA_W - 1 downto 0);
  signal sPixTLast  : std_logic;
  signal sPixTID    : std_logic_vector(ID_W - 1 downto 0);
  signal sPixTDest  : std_logic_vector(DEST_W - 1 downto 0);
  signal sPixTUser  : std_logic_vector(USER_W - 1 downto 0);
  signal sPixTStrb  : std_logic_vector(PIX_DATA_W / 8 - 1 downto 0);
  signal sPixTKeep  : std_logic_vector(PIX_DATA_W / 8 - 1 downto 0);

  -- Encoded AXI4-Stream (DUT master -> TB receiver)
  signal sJlsTValid : std_logic;
  signal sJlsTReady : std_logic;
  signal sJlsTData  : std_logic_vector(JLS_DATA_W - 1 downto 0);
  signal sJlsTKeep  : std_logic_vector(JLS_DATA_W / 8 - 1 downto 0);
  signal sJlsTLast  : std_logic;
  signal sJlsTID    : std_logic_vector(ID_W - 1 downto 0)   := (others => '0');
  signal sJlsTDest  : std_logic_vector(DEST_W - 1 downto 0) := (others => '0');
  signal sJlsTUser  : std_logic_vector(USER_W - 1 downto 0) := (others => '0');
  signal sJlsTStrb  : std_logic_vector(JLS_DATA_W / 8 - 1 downto 0) := (others => '1');

  signal StreamTxRec : StreamRecType(
    DataToModel(PIX_DATA_W - 1 downto 0),
    DataFromModel(PIX_DATA_W - 1 downto 0),
    ParamToModel(PARAM_W - 1 downto 0),
    ParamFromModel(PARAM_W - 1 downto 0)
  );

  signal StreamRxRec : StreamRecType(
    DataToModel(JLS_DATA_W - 1 downto 0),
    DataFromModel(JLS_DATA_W - 1 downto 0),
    ParamToModel(PARAM_W - 1 downto 0),
    ParamFromModel(PARAM_W - 1 downto 0)
  );

begin

  stream_contract : monitor_stream(clk, sCoreRst, sJlsTValid, sJlsTReady, sJlsTData, sJlsTKeep, sJlsTLast, '1', false);

  assert BITNESS = 8 or BITNESS = 12
    report "tb_openjls_axis_osvvm carries golden vectors for BITNESS 8 and 12 only"
    severity failure;

  clk      <= not clk after CLK_PERIOD / 2;
  nReset   <= '0', '1' after 8 * CLK_PERIOD;
  sCoreRst <= not nReset;                     -- core samples dims while iRst = '1'

  ------------------------------------------------------------------------------
  -- DUT + AXI4-Stream verification components
  ------------------------------------------------------------------------------
  u_dut : entity work.openjls_axis(rtl)
    generic map (
      BITNESS          => BITNESS,
      MAX_IMAGE_WIDTH  => IMG_WIDTH,
      MAX_IMAGE_HEIGHT => IMG_HEIGHT,
      OUT_WIDTH        => OUT_WIDTH
    )
    port map (
      iClk                => clk,
      iRst                => sCoreRst,
      iImageWidth         => std_logic_vector(to_unsigned(IMG_WIDTH, 16)),
      iImageHeight        => std_logic_vector(to_unsigned(IMG_HEIGHT, 16)),
      s_axis_pixel_tdata  => sPixTData,
      s_axis_pixel_tvalid => sPixTValid,
      s_axis_pixel_tlast  => sPixTLast,
      s_axis_pixel_tready => sPixTReady,
      m_axis_jls_tdata    => sJlsTData,
      m_axis_jls_tkeep    => sJlsTKeep,
      m_axis_jls_tvalid   => sJlsTValid,
      m_axis_jls_tlast    => sJlsTLast,
      m_axis_jls_tready   => sJlsTReady
    );

  u_tx : AxiStreamTransmitter
    generic map (
      MODEL_ID_NAME => "PixelInput",
      INIT_ID     => CINIT_ID,
      INIT_DEST   => CINIT_DEST,
      INIT_USER   => CINIT_USER,
      INIT_LAST   => 0,
      tperiod_Clk => CLK_PERIOD
    )
    port map (
      Clk      => clk,
      nReset   => nReset,
      TValid   => sPixTValid,
      TReady   => sPixTReady,
      TID      => sPixTID,
      TDest    => sPixTDest,
      TUser    => sPixTUser,
      TData    => sPixTData,
      TStrb    => sPixTStrb,
      TKeep    => sPixTKeep,
      TLast    => sPixTLast,
      TransRec => StreamTxRec
    );

  u_rx : AxiStreamReceiver
    generic map (
      MODEL_ID_NAME => "EncodedOutput",
      INIT_ID     => CINIT_ID,
      INIT_DEST   => CINIT_DEST,
      INIT_USER   => CINIT_USER,
      INIT_LAST   => 0,
      tperiod_Clk => CLK_PERIOD
    )
    port map (
      Clk      => clk,
      nReset   => nReset,
      TValid   => sJlsTValid,
      TReady   => sJlsTReady,
      TID      => sJlsTID,
      TDest    => sJlsTDest,
      TUser    => sJlsTUser,
      TData    => sJlsTData,
      TStrb    => sJlsTStrb,
      TKeep    => sJlsTKeep,
      TLast    => sJlsTLast,
      TransRec => StreamRxRec
    );

  ------------------------------------------------------------------------------
  -- Stimulus: 5 back-to-back images. Runs 0..3 sweep the stall profiles
  -- (output backpressure x input gaps); run 4 splits the image across two send
  -- bursts so the transmitter raises TLAST mid-image, proving the DUT frames
  -- on the pixel count alone and ignores s_axis_pixel_tlast.
  -- SendBurstAsync queues the pixels without blocking, then GetBurst drains the
  -- encoded packet concurrently, so the core never deadlocks on a full output
  -- buffer.
  ------------------------------------------------------------------------------
  p_stim : process is

    variable numBytes : integer;
    variable delayCov : DelayCoverageIDType;
    variable rxByte   : std_logic_vector(7 downto 0);
    variable reqPass  : AlertLogIDType;

    -- Transmitted image: golden pixels plus garbage on any TDATA bits above
    -- BITNESS (16-bit lane, BITNESS 9..15). The DUT must ignore those bits;
    -- for BITNESS 8/16 the vector is IMG_PIXELS unchanged.
    variable vPix : integer_vector(0 to IMG_PIXELS'length - 1);

  begin

    SetTestName("tb_openjls_axis_osvvm");
    SetLogEnable(PASSED, TRUE);

    -- Let the VCs create their burst FIFOs before the first PushBurst.
    wait for 0 ns;
    wait for 0 ns;
    reqPass := GetReqID("OJLS.AxiStreamTransparent", 5 * IMG_EXPECTED'length);

    wait until nReset = '1';
    GetDelayCoverageID(StreamTxRec, delayCov);
    label_delay_coverage(delayCov, "Pixel input");
    GetDelayCoverageID(StreamRxRec, delayCov);
    label_delay_coverage(delayCov, "Encoded output");
    WaitForClock(StreamTxRec, 2);
    -- Pixel side in word mode: one burst-FIFO element per beat, so a 12-bit
    -- sample rides its 16-bit lane unsplit. Encoded side in byte mode:
    -- TKEEP-aware unpacking of OUT_WIDTH beats, partial final beat included.
    SetBurstMode(StreamTxRec, STREAM_BURST_WORD_MODE);
    SetBurstMode(StreamRxRec, STREAM_BURST_BYTE_MODE);

    for i in vPix'range loop
      vPix(i) := IMG_PIXELS(i) +
                 (i mod 2 ** (PIX_DATA_W - BITNESS)) * 2 ** BITNESS;
    end loop;

    for run in 0 to 4 loop

      -- Output backpressure on runs 1 and 3; input stalls on runs 2 and 3.
      if run = 1 or run = 3 then
        SetAxiStreamOptions(StreamRxRec, RECEIVE_READY_DELAY_CYCLES, 3);
      else
        SetAxiStreamOptions(StreamRxRec, RECEIVE_READY_DELAY_CYCLES, 0);
      end if;

      if run = 2 or run = 3 then
        SetAxiStreamOptions(StreamTxRec, TRANSMIT_VALID_DELAY_CYCLES, 2);
      else
        SetAxiStreamOptions(StreamTxRec, TRANSMIT_VALID_DELAY_CYCLES, 0);
      end if;

      if run = 4 then
        -- Split image: the transmitter raises TLAST after the first half.
        PushBurst(StreamTxRec.BurstFifo, vPix(0 to vPix'length / 2 - 1), PIX_DATA_W);
        SendBurstAsync(StreamTxRec, vPix'length / 2);
        PushBurst(StreamTxRec.BurstFifo, vPix(vPix'length / 2 to vPix'high), PIX_DATA_W);
        SendBurstAsync(StreamTxRec, vPix'length - vPix'length / 2);
      else
        PushBurst(StreamTxRec.BurstFifo, vPix, PIX_DATA_W);
        SendBurstAsync(StreamTxRec, vPix'length);
      end if;

      GetBurst(StreamRxRec, numBytes);
      AffirmIfEqual(reqPass, numBytes, IMG_EXPECTED'length,
                    "run " & to_string(run) & " encoded byte count");
      for i in 0 to numBytes - 1 loop
        Pop(StreamRxRec.BurstFifo, rxByte);
        AffirmIfEqual(reqPass, checked_integer(unsigned(rxByte)), IMG_EXPECTED(i),
                      "run " & to_string(run) & " byte " & to_string(i));
      end loop;

    end loop;

    WaitForClock(StreamTxRec, 4);
    end_of_test("tb_openjls_axis_osvvm");
    wait;

  end process p_stim;

  watchdog : process is
  begin
    wait for 20 ms;
    Alert(GetAlertLogID("Watchdog"), "AXI transaction or image completion timed out", FAILURE);
    std.env.stop;
  end process;

end architecture sim;
