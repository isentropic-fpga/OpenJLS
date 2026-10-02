-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

-------------------------------------------------------------------------------------------------------------
-- Engineer:    Vitor Mendes Camilo
--
-- Module Name: openjls_axis - rtl
-- Description: AXI4-Stream wrapper around openjls_top (flavor A).
--
--          Pure structural adaptation — no state, no clocked logic:
--
--            * s_axis_pixel : pixel input. One pixel per beat, right-justified in a
--              byte-aligned TDATA (16 bits for BITNESS 9..16, 8 bits for
--              BITNESS 8). TLAST is accepted and ignored: the core counts
--              width x height internally and flags end-of-image itself.
--
--            * m_axis_jls : encoded .jls byte stream. The core packs the first
--              stream byte into the MSB lanes of oData and fills oKeep from
--              the top lane down; AXI maps byte lane 0 (TDATA[7:0]) to the
--              lowest memory address. The wrapper therefore byte-swaps TDATA
--              and remaps oKeep to an LSB-aligned TKEEP so a memory-mapped
--              consumer (e.g. AXI DMA S2MM) sees the file byte order.
--              Partial beats (TKEEP not all-ones) only occur on the TLAST
--              beat, as required by AXI DMA.
--
--            * iImageWidth/iImageHeight/iRst stay plain ports: the core
--              samples the dimensions only while iRst = '1', so whoever owns
--              reset owns configuration. See openjls_axis_regs for the
--              AXI-Lite flavor that wraps this contract in registers.
--
-------------------------------------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

-- AXI port names must keep the <prefix>_t* suffix convention (lowercase,
-- underscores) for Vivado IP integrator interface inference; the prefix
-- becomes the interface name in the block diagram.
-- vsg_off port_010

entity openjls_axis is
  generic (
    BITNESS          : positive range 8 to 16    := 12;
    MAX_IMAGE_WIDTH  : positive range 4 to 65535 := 4096;
    MAX_IMAGE_HEIGHT : positive range 1 to 65535 := 4096;
    OUT_WIDTH        : positive range 48 to 1024 := CO_OUT_WIDTH_STD;
    -- 1: provision the stuffer for LIMIT bits every cycle; requires wider output.
    FULL_RATE_STUFFER : natural range 0 to 1 := 0
  );
  port (
    iClk                : in    std_logic;
    iRst                : in    std_logic;
    iImageWidth         : in    std_logic_vector(15 downto 0);
    iImageHeight        : in    std_logic_vector(15 downto 0);
    -- AXI4-Stream slave — one pixel per beat, right-justified
    s_axis_pixel_tdata  : in    std_logic_vector(8 * ((BITNESS + 7) / 8) - 1 downto 0);
    s_axis_pixel_tvalid : in    std_logic;
    s_axis_pixel_tlast  : in    std_logic;
    s_axis_pixel_tready : out   std_logic;
    -- AXI4-Stream master — encoded .jls byte stream
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
      OUT_WIDTH        => OUT_WIDTH,
      FULL_RATE_STUFFER => FULL_RATE_STUFFER
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

  -- Byte-lane swap: core packs the first stream byte into the MSB lanes;
  -- AXI byte lane 0 (TDATA[7:0]) goes to the lowest memory address. After the
  -- swap the valid bytes of a partial (TLAST) beat sit in lanes 0..N-1 with
  -- an LSB-aligned contiguous TKEEP, as AXI DMA expects.

  gen_byte_swap : for i in 0 to OUT_WIDTH / 8 - 1 generate
    m_axis_jls_tdata((i + 1) * 8 - 1 downto i * 8) <= sCoreData(OUT_WIDTH - i * 8 - 1 downto OUT_WIDTH - (i + 1) * 8);
    m_axis_jls_tkeep(i)                            <= sCoreKeep(OUT_WIDTH / 8 - 1 - i);
  end generate gen_byte_swap;

end architecture rtl;
