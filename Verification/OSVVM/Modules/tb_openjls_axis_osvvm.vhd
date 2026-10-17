-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_openjls_axis_osvvm: openjls_axis against golden .jls streams, via the OSVVM AXI4-Stream VCs
--
-- BITNESS 8 replays T.87 H.3, 12 and 16 CharLS-minted images. Runs 0..3 sweep
-- TREADY x TVALID gaps, run 4 raises TLAST mid-image; then three mid-op resets.
--
-- Guidelines:
--   G1.Req      OJLS.AxiStreamTransparent
--   G1.Ojls     CharLS-minted streams through the AXI4-Stream VCs
--   G2.Range    N/A: wrapper, no arithmetic (no asserts)
--   G2.MinMax   N/A: wrapper
--   G2.Clamp    N/A: no accumulator
--   G2.Checked  checked_* on all outputs
--   G3.Stim     N/A: wrapper
--   G4.Stream   G4.Stream handshake profile
--   G4.Config   BITNESS 8/12/16, OUT_WIDTH 48 variants (OpenJls.pro)
--   G4 other    N/A: Edge/Run/Coding not in scope
--   G5          G5.States resetPhase; outputs idle after reset, aborted output discarded, replay checked
--   G6.Code     fully covered

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library osvvm;
  context osvvm.OsvvmContext;
  use osvvm.ScoreboardPkg_slv.all;

library osvvm_axi4;
  context osvvm_axi4.AxiStreamContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_openjls_axis_osvvm is
  generic (
    BITNESS   : positive range 8 to 16    := H3_BITNESS;        -- 8, 12 or 16
    OUT_WIDTH : positive range 48 to 1024 := CO_OUT_WIDTH_STD
  );
end entity tb_openjls_axis_osvvm;

architecture sim of tb_openjls_axis_osvvm is

  constant CLK_PERIOD : time := CLK_PERIOD_DEFAULT;

  constant PIX_DATA_W : natural := 8 * ((BITNESS + 7) / 8);
  constant JLS_DATA_W : natural := OUT_WIDTH;

  function pick_iv (constant a, b, c : integer_vector) return integer_vector is
  begin
    if BITNESS = 8 then
      return a;
    elsif BITNESS = 12 then
      return b;
    end if;
    return c;
  end function pick_iv;

  function pick_n (constant a, b, c : natural) return natural is
  begin
    if BITNESS = 8 then
      return a;
    elsif BITNESS = 12 then
      return b;
    end if;
    return c;
  end function pick_n;

  constant IMG_PIXELS   : integer_vector := pick_iv(H3_PIXELS, B12_PIXELS, B16_PIXELS);
  constant IMG_EXPECTED : integer_vector := pick_iv(H3_EXPECTED, B12_EXPECTED, B16_EXPECTED);
  constant IMG_WIDTH    : natural        := pick_n(H3_WIDTH, B12_WIDTH, B16_WIDTH);
  constant IMG_HEIGHT   : natural        := pick_n(H3_HEIGHT, B12_HEIGHT, B16_HEIGHT);

  -- Unused by the DUT; the VC ports need a size
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
  signal sMidRst  : std_logic := '0';
  signal sAbort   : boolean   := false;       -- discard output before the receiver
  signal sAbortLast : boolean := false;

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

  -- Encoded AXI4-Stream (DUT master -> TB receiver), Rx copies gated by sAbort
  signal sJlsTValid : std_logic;
  signal sJlsTReady : std_logic;
  signal sRxTValid  : std_logic;
  signal sRxTReady  : std_logic;
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

  assert BITNESS = 8 or BITNESS = 12 or BITNESS = 16
    report "tb_openjls_axis_osvvm carries golden vectors for BITNESS 8, 12 and 16 only"
    severity failure;

  clk      <= not clk after CLK_PERIOD / 2;
  nReset   <= '0', '1' after 8 * CLK_PERIOD;
  sCoreRst <= not nReset or sMidRst;          -- core samples dims while iRst = '1'

  sRxTValid  <= '0' when sAbort else sJlsTValid;
  sJlsTReady <= '1' when sAbort else sRxTReady;

  p_abort_last : process (clk) is
  begin
    if rising_edge(clk) then
      if not sAbort then
        sAbortLast <= false;
      elsif sJlsTValid = '1' and sJlsTLast = '1' then
        sAbortLast <= true;
      end if;
    end if;
  end process p_abort_last;

  -- DUT and VCs ---
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
      TValid   => sRxTValid,
      TReady   => sRxTReady,
      TID      => sJlsTID,
      TDest    => sJlsTDest,
      TUser    => sJlsTUser,
      TData    => sJlsTData,
      TStrb    => sJlsTStrb,
      TKeep    => sJlsTKeep,
      TLast    => sJlsTLast,
      TransRec => StreamRxRec
    );

  -- Stimulus ---
  -- SendBurstAsync + GetBurst run concurrently so the core can't deadlock on a
  -- full output buffer
  p_stim : process is

    variable numBytes : integer;
    variable delayCov : DelayCoverageIDType;
    variable rxByte   : std_logic_vector(7 downto 0);
    variable reqPass  : AlertLogIDType;
    variable cov      : CoverageIDType;
    variable rs       : CoverageIDType;

    -- Golden pixels plus garbage on TDATA bits above BITNESS, which the DUT must ignore
    variable vPix : integer_vector(0 to IMG_PIXELS'length - 1);

    procedure send_check (split : boolean; tag : string) is
    begin
      if split then
        PushBurst(StreamTxRec.BurstFifo, vPix(0 to vPix'length / 2 - 1), PIX_DATA_W);
        SendBurstAsync(StreamTxRec, vPix'length / 2);
        PushBurst(StreamTxRec.BurstFifo, vPix(vPix'length / 2 to vPix'high), PIX_DATA_W);
        SendBurstAsync(StreamTxRec, vPix'length - vPix'length / 2);
      else
        PushBurst(StreamTxRec.BurstFifo, vPix, PIX_DATA_W);
        SendBurstAsync(StreamTxRec, vPix'length);
      end if;

      GetBurst(StreamRxRec, numBytes);
      AffirmIfEqual(reqPass, numBytes, IMG_EXPECTED'length, tag & " encoded byte count");
      for i in 0 to numBytes - 1 loop
        Pop(StreamRxRec.BurstFifo, rxByte);
        AffirmIfEqual(reqPass, checked_integer(unsigned(rxByte)), IMG_EXPECTED(i),
                      tag & " byte " & to_string(i));
      end loop;
    end procedure send_check;

    -- n pixels, iRst, then a full image; no TLAST may escape the aborted one
    procedure reset_mid (n : natural) is
    begin
      sAbort <= true;
      if n > 0 then
        PushBurst(StreamTxRec.BurstFifo, vPix(0 to n - 1), PIX_DATA_W);
        SendBurst(StreamTxRec, n);
      end if;
      if n = 0 then
        ICover(rs, 0);
      elsif n < vPix'length then
        ICover(rs, 1);
      else
        ICover(rs, 2);
      end if;
      WaitForClock(StreamTxRec, 1);
      sMidRst <= '1';
      WaitForClock(StreamTxRec, 4);
      AffirmIf(GetAlertLogID("ResetRecovery"), not sAbortLast,
               "aborted image emitted no TLAST before iRst");
      sMidRst <= '0';
      WaitForClock(StreamTxRec, 1);
      AffirmIf(GetAlertLogID("ResetRecovery"), sJlsTValid = '0' and sPixTReady = '1',
               "core idle and ready after iRst");
      sAbort <= false;
      WaitForClock(StreamTxRec, 1);
      send_check(false, "after reset at pixel " & to_string(n));
    end procedure reset_mid;

  begin

    SetTestName("tb_openjls_axis_osvvm");
    SetLogEnable(PASSED, TRUE);

    -- Let the VCs create their burst FIFOs
    wait for 0 ns;
    wait for 0 ns;
    reqPass := GetReqID("OJLS.AxiStreamTransparent", 8 * IMG_EXPECTED'length);

    cov := NewID("G4.Stream handshake profile");
    AddBins(cov, "clean", GenBin(0));
    AddBins(cov, "output backpressure", GenBin(1));
    AddBins(cov, "input stall", GenBin(2));
    AddBins(cov, "backpressure + stall", GenBin(3));
    AddBins(cov, "TLAST mid-image", GenBin(4));

    rs := NewID("G5.States resetPhase");
    AddBins(rs, "idle", GenBin(0));
    AddBins(rs, "mid-image", GenBin(1));
    AddBins(rs, "pixels in, output draining", GenBin(2));

    wait until nReset = '1';
    GetDelayCoverageID(StreamTxRec, delayCov);
    label_delay_coverage(delayCov, "Pixel input");
    GetDelayCoverageID(StreamRxRec, delayCov);
    label_delay_coverage(delayCov, "Encoded output");
    WaitForClock(StreamTxRec, 2);
    -- Word mode keeps a 12-bit sample whole on its 16-bit lane; byte mode honours TKEEP
    SetBurstMode(StreamTxRec, STREAM_BURST_WORD_MODE);
    SetBurstMode(StreamRxRec, STREAM_BURST_BYTE_MODE);

    for i in vPix'range loop
      vPix(i) := IMG_PIXELS(i) +
                 (i mod 2 ** (PIX_DATA_W - BITNESS)) * 2 ** BITNESS;
    end loop;

    for run in 0 to 4 loop

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

      send_check(run = 4, "run " & to_string(run));
      ICover(cov, run);

    end loop;

    -- Mid-op reset: idle, mid-image, all pixels in ---
    SetAxiStreamOptions(StreamRxRec, RECEIVE_READY_DELAY_CYCLES, 0);
    SetAxiStreamOptions(StreamTxRec, TRANSMIT_VALID_DELAY_CYCLES, 0);
    reset_mid(0);
    reset_mid(vPix'length / 2);
    reset_mid(vPix'length);

    affirm_covered(cov, "handshake profile coverage closed");
    affirm_covered(rs, "reset phase coverage closed");
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
