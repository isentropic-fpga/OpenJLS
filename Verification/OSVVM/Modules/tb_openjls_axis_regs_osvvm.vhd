-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM AXI4-Stream + AXI4-Lite wrapper testbench: openjls_axis_regs (flavor B).
--
-- Exercises the hand-written AXI4-Lite register file and reset controller -- the
-- part of the Xilinx wrappers with no other in-sim coverage (the HIL demo only
-- ever touched the handful of registers it needed). An OSVVM Axi4LiteManager
-- drives the control bus; the AxiStream VCs drive pixels and capture the encoded
-- stream (as in tb_openjls_axis_osvvm).
--
-- Phase 1 -- register map (OJLS.AxiLiteRegMap):
--   * RO identity/config read exact: ID, VERSION, CAPS, MAXDIM
--   * WIDTH/HEIGHT read-write, then out-of-range writes clamp to MAX
--   * partial-WSTRB byte-lane merges (1-byte writes at byte offsets 0 and 1)
--   * RO register write is dropped (responded OKAY), value unchanged
--   * write-only CTRL and unmapped offsets read back zero
-- Phase 2 -- APPLY reconfiguration (OJLS.AxiApplyReconfig):
--   * write WIDTH/HEIGHT = 4, pulse CTRL.APPLY, then stream the H.3 image and
--     check the 57-byte golden -> a register-configured encode is byte-exact.
--
-- Note: the "config write dropped while BUSY" path (openjls_axis_regs.vhd) is
-- unreachable from a real AXI-Lite master -- BUSY is a one-clock APPLY pulse and
-- a bus write cannot land inside it -- so that branch is intentionally not
-- covered here.
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library osvvm;
  context osvvm.OsvvmContext;
  use osvvm.ScoreboardPkg_slv.all;   -- Push/Pop on the stream BurstFifo

library osvvm_axi4;
  context osvvm_axi4.AxiStreamContext;
  context osvvm_axi4.Axi4LiteContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_openjls_axis_regs_osvvm is
  generic (
    MAX_W     : positive range 4 to 65535 := 4096;
    MAX_H     : positive range 1 to 65535 := 4096;
    OUT_WIDTH : positive range 48 to 1024 := CO_OUT_WIDTH_STD   -- 64
  );
end entity tb_openjls_axis_regs_osvvm;

architecture sim of tb_openjls_axis_regs_osvvm is

  constant CLK_PERIOD : time := CLK_PERIOD_DEFAULT;

  -- AXI4-Lite control bus
  constant ADDR_W : natural := 32;
  constant DATA_W : natural := 32;

  -- Register byte offsets (mirrors openjls_axis_regs.vhd)
  constant A_ID      : std_logic_vector(ADDR_W - 1 downto 0) := x"00000000";
  constant A_VERSION : std_logic_vector(ADDR_W - 1 downto 0) := x"00000004";
  constant A_CAPS    : std_logic_vector(ADDR_W - 1 downto 0) := x"00000008";
  constant A_MAXDIM  : std_logic_vector(ADDR_W - 1 downto 0) := x"0000000C";
  constant A_WIDTH   : std_logic_vector(ADDR_W - 1 downto 0) := x"00000010";
  constant A_HEIGHT  : std_logic_vector(ADDR_W - 1 downto 0) := x"00000014";
  constant A_CTRL    : std_logic_vector(ADDR_W - 1 downto 0) := x"00000018";
  constant A_STATUS  : std_logic_vector(ADDR_W - 1 downto 0) := x"0000001C";
  constant A_UNMAP   : std_logic_vector(ADDR_W - 1 downto 0) := x"00000020";

  -- Expected RO values
  constant EXP_ID      : std_logic_vector(31 downto 0) := x"4F4A4C53";           -- "OJLS"
  constant EXP_VERSION : std_logic_vector(31 downto 0) := x"00010200";           -- 1.2.0
  constant EXP_CAPS    : std_logic_vector(31 downto 0) :=
    std_logic_vector(to_unsigned(H3_BITNESS + (OUT_WIDTH / 8) * 256, 32));
  constant EXP_MAXDIM  : std_logic_vector(31 downto 0) :=
    std_logic_vector(to_unsigned(MAX_W + MAX_H * 65536, 32));
  constant MAX_W_SLV   : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(MAX_W, 16));
  constant MAX_H_SLV   : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(MAX_H, 16));

  -- Stream side (identical widths to tb_openjls_axis_osvvm)
  constant PIX_DATA_W : natural := 8;
  constant JLS_DATA_W : natural := OUT_WIDTH;
  constant ID_W   : natural := 8;
  constant DEST_W : natural := 4;
  constant USER_W : natural := 4;
  constant PARAM_W : natural := ID_W + DEST_W + USER_W + 1;

  constant CINIT_ID   : std_logic_vector(ID_W - 1 downto 0)   := (others => '0');
  constant CINIT_DEST : std_logic_vector(DEST_W - 1 downto 0) := (others => '0');
  constant CINIT_USER : std_logic_vector(USER_W - 1 downto 0) := (others => '0');

  signal clk    : std_logic := '0';
  signal nReset : std_logic := '0';

  -- AXI4-Lite manager <-> DUT control bus (record wired to the DUT's flat ports)
  signal AxiBus : Axi4LiteRecType(
    WriteAddress(Addr(ADDR_W - 1 downto 0)),
    WriteData(Data(DATA_W - 1 downto 0), Strb(DATA_W / 8 - 1 downto 0)),
    ReadAddress(Addr(ADDR_W - 1 downto 0)),
    ReadData(Data(DATA_W - 1 downto 0))
  );

  signal ManagerRec : AddressBusRecType(
    Address(ADDR_W - 1 downto 0),
    DataToModel(DATA_W - 1 downto 0),
    DataFromModel(DATA_W - 1 downto 0)
  );

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

  clk    <= not clk after CLK_PERIOD / 2;
  nReset <= '0', '1' after 8 * CLK_PERIOD;

  ------------------------------------------------------------------------------
  -- DUT: flat AXI-Lite ports wired to the manager's AxiBus record subfields
  -- (manager drives address/data/valid; DUT drives ready/response/rdata).
  ------------------------------------------------------------------------------
  u_dut : entity work.openjls_axis_regs(rtl)
    generic map (
      BITNESS          => H3_BITNESS,
      MAX_IMAGE_WIDTH  => MAX_W,
      MAX_IMAGE_HEIGHT => MAX_H,
      OUT_WIDTH        => OUT_WIDTH
    )
    port map (
      aclk    => clk,
      aresetn => nReset,
      -- AXI4-Lite control
      s_axi_ctrl_awaddr  => AxiBus.WriteAddress.Addr(7 downto 0),
      s_axi_ctrl_awprot  => AxiBus.WriteAddress.Prot,
      s_axi_ctrl_awvalid => AxiBus.WriteAddress.Valid,
      s_axi_ctrl_awready => AxiBus.WriteAddress.Ready,
      s_axi_ctrl_wdata   => AxiBus.WriteData.Data,
      s_axi_ctrl_wstrb   => AxiBus.WriteData.Strb,
      s_axi_ctrl_wvalid  => AxiBus.WriteData.Valid,
      s_axi_ctrl_wready  => AxiBus.WriteData.Ready,
      s_axi_ctrl_bresp   => AxiBus.WriteResponse.Resp,
      s_axi_ctrl_bvalid  => AxiBus.WriteResponse.Valid,
      s_axi_ctrl_bready  => AxiBus.WriteResponse.Ready,
      s_axi_ctrl_araddr  => AxiBus.ReadAddress.Addr(7 downto 0),
      s_axi_ctrl_arprot  => AxiBus.ReadAddress.Prot,
      s_axi_ctrl_arvalid => AxiBus.ReadAddress.Valid,
      s_axi_ctrl_arready => AxiBus.ReadAddress.Ready,
      s_axi_ctrl_rdata   => AxiBus.ReadData.Data,
      s_axi_ctrl_rresp   => AxiBus.ReadData.Resp,
      s_axi_ctrl_rvalid  => AxiBus.ReadData.Valid,
      s_axi_ctrl_rready  => AxiBus.ReadData.Ready,
      -- AXI4-Stream
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

  u_manager : Axi4LiteManager
    port map (
      Clk      => clk,
      nReset   => nReset,
      AxiBus   => AxiBus,
      TransRec => ManagerRec
    );

  u_tx : AxiStreamTransmitter
    generic map (
      INIT_ID     => CINIT_ID,
      INIT_DEST   => CINIT_DEST,
      INIT_USER   => CINIT_USER,
      INIT_LAST   => 0,
      tperiod_Clk => CLK_PERIOD
    )
    port map (
      Clk => clk, nReset => nReset,
      TValid => sPixTValid, TReady => sPixTReady,
      TID => sPixTID, TDest => sPixTDest, TUser => sPixTUser,
      TData => sPixTData, TStrb => sPixTStrb, TKeep => sPixTKeep, TLast => sPixTLast,
      TransRec => StreamTxRec
    );

  u_rx : AxiStreamReceiver
    generic map (
      INIT_ID     => CINIT_ID,
      INIT_DEST   => CINIT_DEST,
      INIT_USER   => CINIT_USER,
      INIT_LAST   => 0,
      tperiod_Clk => CLK_PERIOD
    )
    port map (
      Clk => clk, nReset => nReset,
      TValid => sJlsTValid, TReady => sJlsTReady,
      TID => sJlsTID, TDest => sJlsTDest, TUser => sJlsTUser,
      TData => sJlsTData, TStrb => sJlsTStrb, TKeep => sJlsTKeep, TLast => sJlsTLast,
      TransRec => StreamRxRec
    );

  ------------------------------------------------------------------------------
  -- Stimulus
  ------------------------------------------------------------------------------
  p_stim : process is

    variable rdata    : std_logic_vector(DATA_W - 1 downto 0);
    variable numBytes : integer;
    variable rxByte   : std_logic_vector(7 downto 0);
    variable reqReg   : AlertLogIDType;
    variable reqApply : AlertLogIDType;
    variable reqAbort : AlertLogIDType;
    variable vResidue : integer;

  begin

    SetTestName("tb_openjls_axis_regs_osvvm");
    SetLogEnable(PASSED, TRUE);

    wait for 0 ns;
    wait for 0 ns;
    reqReg   := GetReqID("OJLS.AxiLiteRegMap", 16);
    reqApply := GetReqID("OJLS.AxiApplyReconfig", H3_EXPECTED'length);
    reqAbort := GetReqID("OJLS.AxiAbortReencode", H3_EXPECTED'length);

    wait until nReset = '1';
    WaitForClock(ManagerRec, 2);

    ----------------------------------------------------------------------------
    -- Phase 1: register map
    ----------------------------------------------------------------------------
    -- Read-only identity / configuration
    Read(ManagerRec, A_ID, rdata);
    AffirmIfEqual(reqReg, rdata, EXP_ID, "REG_ID");
    Read(ManagerRec, A_VERSION, rdata);
    AffirmIfEqual(reqReg, rdata, EXP_VERSION, "REG_VERSION");
    Read(ManagerRec, A_CAPS, rdata);
    AffirmIfEqual(reqReg, rdata, EXP_CAPS, "REG_CAPS");
    Read(ManagerRec, A_MAXDIM, rdata);
    AffirmIfEqual(reqReg, rdata, EXP_MAXDIM, "REG_MAXDIM");

    -- Power-on defaults: WIDTH/HEIGHT come out of reset at the MAX generics
    -- (must be read before the first write touches them)
    Read(ManagerRec, A_WIDTH, rdata);
    AffirmIfEqual(reqReg, rdata(15 downto 0), MAX_W_SLV, "WIDTH reset default");
    Read(ManagerRec, A_HEIGHT, rdata);
    AffirmIfEqual(reqReg, rdata(15 downto 0), MAX_H_SLV, "HEIGHT reset default");

    -- WIDTH / HEIGHT read-write
    Write(ManagerRec, A_WIDTH, x"00000004");
    Read(ManagerRec, A_WIDTH, rdata);
    AffirmIfEqual(reqReg, rdata(15 downto 0), x"0004", "WIDTH read-write");
    Write(ManagerRec, A_HEIGHT, x"00000004");
    Read(ManagerRec, A_HEIGHT, rdata);
    AffirmIfEqual(reqReg, rdata(15 downto 0), x"0004", "HEIGHT read-write");

    -- Out-of-range writes clamp to MAX (above the range, then below the floor)
    Write(ManagerRec, A_WIDTH, x"0000FFFF");
    Read(ManagerRec, A_WIDTH, rdata);
    AffirmIfEqual(reqReg, rdata(15 downto 0), MAX_W_SLV, "WIDTH clamp (over max)");
    Write(ManagerRec, A_WIDTH, x"00000002");
    Read(ManagerRec, A_WIDTH, rdata);
    AffirmIfEqual(reqReg, rdata(15 downto 0), MAX_W_SLV, "WIDTH clamp (under min)");

    -- Partial-WSTRB byte-lane merge: 1-byte writes at byte offsets 0 then 1
    Write(ManagerRec, A_WIDTH, x"00000100");           -- seed 0x0100
    Write(ManagerRec, x"00000010", x"04");             -- byte0 -> WSTRB 0001
    Read(ManagerRec, A_WIDTH, rdata);
    AffirmIfEqual(reqReg, rdata(15 downto 0), x"0104", "WIDTH WSTRB byte0 merge");
    Write(ManagerRec, x"00000011", x"02");             -- byte1 -> WSTRB 0010
    Read(ManagerRec, A_WIDTH, rdata);
    AffirmIfEqual(reqReg, rdata(15 downto 0), x"0204", "WIDTH WSTRB byte1 merge");

    -- RO write is dropped (OKAY response), value unchanged
    Write(ManagerRec, A_ID, x"DEADBEEF");
    Read(ManagerRec, A_ID, rdata);
    AffirmIfEqual(reqReg, rdata, EXP_ID, "REG_ID read-only");

    -- Write-only CTRL and unmapped offset read back zero
    Read(ManagerRec, A_CTRL, rdata);
    AffirmIfEqual(reqReg, rdata, x"00000000", "REG_CTRL reads zero");
    Read(ManagerRec, A_UNMAP, rdata);
    AffirmIfEqual(reqReg, rdata, x"00000000", "unmapped reads zero");

    ----------------------------------------------------------------------------
    -- Phase 2: APPLY reconfiguration + register-configured encode
    ----------------------------------------------------------------------------
    Write(ManagerRec, A_WIDTH, x"00000004");
    Write(ManagerRec, A_HEIGHT, x"00000004");
    Write(ManagerRec, A_CTRL, x"00000001");            -- APPLY: pulse core reset
    WaitForClock(ManagerRec, 4);
    Read(ManagerRec, A_STATUS, rdata);
    AffirmIfEqual(reqReg, rdata(0), '0', "STATUS BUSY clear after APPLY");
    AffirmIfEqual(reqReg, rdata(1), '1', "STATUS TREADY mirror high when idle");

    SetBurstMode(StreamTxRec, STREAM_BURST_BYTE_MODE);
    SetBurstMode(StreamRxRec, STREAM_BURST_BYTE_MODE);
    SetAxiStreamOptions(StreamRxRec, RECEIVE_READY_DELAY_CYCLES, 2);   -- light backpressure

    PushBurst(StreamTxRec.BurstFifo, H3_PIXELS);
    SendBurstAsync(StreamTxRec, H3_PIXELS'length);
    GetBurst(StreamRxRec, numBytes);
    AffirmIfEqual(reqApply, numBytes, H3_EXPECTED'length, "APPLY encode byte count");
    for i in 0 to numBytes - 1 loop
      Pop(StreamRxRec.BurstFifo, rxByte);
      AffirmIfEqual(reqApply, to_integer(unsigned(rxByte)), H3_EXPECTED(i),
                    "APPLY encode byte " & to_string(i));
    end loop;

    ----------------------------------------------------------------------------
    -- Phase 3: APPLY mid-image aborts the encode; the next image is clean
    ----------------------------------------------------------------------------
    -- Feed half an image and let the core consume it, then APPLY. The aborted
    -- encode has emitted only whole OUT_WIDTH beats (never TLAST), so the
    -- receiver holds that residue until the post-abort image's TLAST closes
    -- the burst. The fresh golden stream must sit byte-exact at the tail.
    PushBurst(StreamTxRec.BurstFifo, H3_PIXELS(0 to H3_PIXELS'length / 2 - 1));
    SendBurstAsync(StreamTxRec, H3_PIXELS'length / 2);
    WaitForClock(ManagerRec, 50);                      -- half image fully consumed
    Write(ManagerRec, A_CTRL, x"00000001");            -- APPLY: abort + re-arm
    WaitForClock(ManagerRec, 4);

    PushBurst(StreamTxRec.BurstFifo, H3_PIXELS);
    SendBurstAsync(StreamTxRec, H3_PIXELS'length);
    GetBurst(StreamRxRec, numBytes);

    vResidue := numBytes - H3_EXPECTED'length;
    AffirmIf(reqAbort,
             vResidue >= 0 and vResidue mod (OUT_WIDTH / 8) = 0,
             "aborted-image residue is whole beats (residue "
             & to_string(vResidue) & " bytes)");
    for i in 0 to numBytes - 1 loop
      Pop(StreamRxRec.BurstFifo, rxByte);
      if i >= vResidue then
        AffirmIfEqual(reqAbort, to_integer(unsigned(rxByte)),
                      H3_EXPECTED(i - vResidue),
                      "post-abort byte " & to_string(i - vResidue));
      end if;
    end loop;

    WaitForClock(ManagerRec, 4);
    end_of_test("tb_openjls_axis_regs_osvvm");
    wait;

  end process p_stim;

end architecture sim;
