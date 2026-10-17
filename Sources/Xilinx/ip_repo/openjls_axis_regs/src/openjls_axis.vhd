-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- openjls_axis: AXI4-Stream wrapper of openjls_top
--
-- One pixel per s_axis_pixel beat, right-justified; TLAST is ignored (the core counts W x H).
-- m_axis_jls is byte-swapped so lane 0 carries the first file byte and TKEEP is LSB-aligned, as
-- AXI DMA S2MM expects; only the TLAST beat is partial.
-- iImageWidth/iImageHeight are sampled while iRst = '1'; openjls_axis_regs wraps this in registers.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

-- <prefix>_t* port names: Vivado IP integrator infers the interfaces from them
-- vsg_off port_010

entity openjls_axis is
  generic (
    BITNESS          : positive range 8 to 16    := 12;
    MAX_IMAGE_WIDTH  : positive range 4 to 65535 := 4096;
    MAX_IMAGE_HEIGHT : positive range 1 to 65535 := 4096;
    OUT_WIDTH        : positive range 48 to 1024 := CO_OUT_WIDTH_STD
  );
  port (
    iClk                : in    std_logic;
    iRst                : in    std_logic;
    iImageWidth         : in    std_logic_vector(15 downto 0);
    iImageHeight        : in    std_logic_vector(15 downto 0);
    -- Pixel in, right-justified
    s_axis_pixel_tdata  : in    std_logic_vector(8 * ((BITNESS + 7) / 8) - 1 downto 0);
    s_axis_pixel_tvalid : in    std_logic;
    s_axis_pixel_tlast  : in    std_logic;
    s_axis_pixel_tready : out   std_logic;
    -- Encoded .jls out
    m_axis_jls_tdata    : out   std_logic_vector(OUT_WIDTH - 1 downto 0);
    m_axis_jls_tkeep    : out   std_logic_vector(OUT_WIDTH / 8 - 1 downto 0);
    m_axis_jls_tvalid   : out   std_logic;
    m_axis_jls_tlast    : out   std_logic;
    m_axis_jls_tready   : in    std_logic
  );

  -- Vivado IP integrator interface inference
  attribute x_interface_info                   : string;
  attribute x_interface_parameter              : string;
  attribute x_interface_info of iClk           : signal is "xilinx.com:signal:clock:1.0 iClk CLK";
  attribute x_interface_parameter of iClk      : signal is "ASSOCIATED_BUSIF s_axis_pixel:m_axis_jls, ASSOCIATED_RESET iRst";
  attribute x_interface_info of iRst           : signal is "xilinx.com:signal:reset:1.0 iRst RST";
  attribute x_interface_parameter of iRst      : signal is "POLARITY ACTIVE_HIGH";
end entity openjls_axis;

architecture rtl of openjls_axis is

  signal sCoreData : std_logic_vector(OUT_WIDTH - 1 downto 0);
  signal sCoreKeep : std_logic_vector(OUT_WIDTH / 8 - 1 downto 0);

begin

  u_openjls_top : entity work.openjls_top(rtl)
    generic map (
      BITNESS          => BITNESS,
      MAX_IMAGE_WIDTH  => MAX_IMAGE_WIDTH,
      MAX_IMAGE_HEIGHT => MAX_IMAGE_HEIGHT,
      OUT_WIDTH        => OUT_WIDTH
    )
    port map (
      iClk             => iClk,
      iRst             => iRst,
      iValid           => s_axis_pixel_tvalid,
      iPixel           => s_axis_pixel_tdata(BITNESS - 1 downto 0),
      oReady           => s_axis_pixel_tready,
      iImageWidth      => iImageWidth,
      iImageHeight     => iImageHeight,
      oData            => sCoreData,
      oValid           => m_axis_jls_tvalid,
      oKeep            => sCoreKeep,
      oLast            => m_axis_jls_tlast,
      iReady           => m_axis_jls_tready
    );

  -- The core puts the first byte in the MSB lane; AXI lane 0 is the lowest address

  gen_byte_swap : for i in 0 to OUT_WIDTH / 8 - 1 generate
    m_axis_jls_tdata((i + 1) * 8 - 1 downto i * 8) <= sCoreData(OUT_WIDTH - i * 8 - 1 downto OUT_WIDTH - (i + 1) * 8);
    m_axis_jls_tkeep(i)                            <= sCoreKeep(OUT_WIDTH / 8 - 1 - i);
  end generate gen_byte_swap;

end architecture rtl;
