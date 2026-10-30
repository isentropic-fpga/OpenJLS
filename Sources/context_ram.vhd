-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- context_ram: context variables A, B, C, N for the 365 regular and 2 run-interruption contexts
--
-- Per-address init flags: after iEndOfImage, the first read of each context returns the initial values.
-- The flag lookup selects on the merged A.4.1 Qi, skipping the A.4.2 adder; the flag clear lands a cycle late.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library work;
  use work.olo_base_pkg_math.all;

entity context_ram is
  generic (
    RANGE_P         : positive := CO_RANGE_STD;
    RAM_DEPTH       : positive := 367;
    A_WIDTH         : positive := CO_AQ_WIDTH_STD;
    B_WIDTH         : positive := CO_BQ_WIDTH_STD;
    C_WIDTH         : positive := CO_CQ_WIDTH;
    N_WIDTH         : positive := CO_NQ_WIDTH_STD;
    TOTAL_WIDTH     : positive := CO_TOTAL_WIDTH_STD
  );
  port (
    iClk            : in    std_logic;
    iRst            : in    std_logic;
    iWrAddr         : in    std_logic_vector(log2ceil(RAM_DEPTH) - 1 downto 0);
    iWrEn           : in    std_logic;
    iWrData         : in    std_logic_vector(TOTAL_WIDTH - 1 downto 0);
    iRdAddr         : in    std_logic_vector(log2ceil(RAM_DEPTH) - 1 downto 0);
    -- iRdAddr as merged Qi (iRdAddr = 81 Q1 + 9 Q2 + Q3) when iRdRegular, else 365 + iRdRiType
    iRdRegular      : in    std_logic;
    iRdRiType       : in    std_logic;
    iRdQ1           : in    signed(3 downto 0);
    iRdQ2           : in    signed(3 downto 0);
    iRdQ3           : in    signed(3 downto 0);
    iRdEn           : in    std_logic;
    iEndOfImage     : in    std_logic;
    oRdData         : out   std_logic_vector(TOTAL_WIDTH - 1 downto 0);
    -- oRdData split: oRdAlt when oRdUseAlt else oRdBram. oRdAlt and oRdUseAlt come from registers
    oRdBram         : out   std_logic_vector(TOTAL_WIDTH - 1 downto 0);
    oRdAlt          : out   std_logic_vector(TOTAL_WIDTH - 1 downto 0);
    oRdUseAlt       : out   std_logic
  );
end entity context_ram;

architecture behavioral of context_ram is

  constant A_INIT      : natural := math_max(2, (RANGE_P + 32) / 64);
  constant B_INIT      : integer := 0;
  constant C_INIT      : integer := 0;
  constant N_INIT      : natural := 1;

  constant REG_CONTEXTS : natural := 365;

  -- (A | B | C | N); run contexts reuse it as (A | Nn | 0 | N) with Nn = 0
  constant CTX_INIT    : std_logic_vector(TOTAL_WIDTH - 1 downto 0) :=
                                                                       std_logic_vector(to_unsigned(A_INIT, A_WIDTH)) &
                                                                       std_logic_vector(to_signed(B_INIT, B_WIDTH)) &
                                                                       std_logic_vector(to_signed(C_INIT, C_WIDTH)) &
                                                                       std_logic_vector(to_unsigned(N_INIT, N_WIDTH));

  signal sUseInitValue : std_logic_vector(RAM_DEPTH - 1 downto 0); -- per address: next read returns CTX_INIT
  signal sUseInitReg   : std_logic;
  signal sLookup       : std_logic;
  -- Context key: '1' & Qi for regular, '0' & RItype for run; unique per context
  signal sRdKey        : std_logic_vector(12 downto 0);
  -- Last read, cleared next cycle; a back-to-back read of it bypasses the stale flag
  signal sClrPend      : std_logic;
  signal sClrAddr      : std_logic_vector(log2ceil(RAM_DEPTH) - 1 downto 0);
  signal sClrKey       : std_logic_vector(12 downto 0);
  signal sBramRdData   : std_logic_vector(TOTAL_WIDTH - 1 downto 0);

  -- Same-address write forwarding: WBR on top of an RBW BRAM
  signal sFwdSameReg   : std_logic;
  signal sWrDataReg    : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
  signal sRdAlt        : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
  signal sRdUseAlt     : std_logic;

begin

  -- Accesses can ride the first reset cycle (valids clear synchronously). Harmless:
  -- the init flags re-arm and win, and the read result is discarded downstream.

  olo_base_ram_sdp_inst : entity work.olo_base_ram_sdp(rtl)
    generic map (
      DEPTH_G         => RAM_DEPTH,
      WIDTH_G         => TOTAL_WIDTH,
      ISASYNC_G       => false,
      RDLATENCY_G     => 1,
      RAMSTYLE_G      => "auto",
      RAMBEHAVIOR_G   => "RBW",
      USEBYTEENABLE_G => false,
      INITSTRING_G    => "",
      INITFORMAT_G    => "NONE"
    )
    port map (
      Clk             => iClk,
      Wr_Addr         => iWrAddr,
      Wr_Ena          => iWrEn,
      Wr_Be           => open,
      Wr_Data         => iWrData,
      Rd_Clk          => open,
      Rd_Addr         => iRdAddr,
      Rd_Ena          => iRdEn,
      Rd_Data         => sBramRdData
    );

  sRdKey <= '1' & std_logic_vector(iRdQ1 & iRdQ2 & iRdQ3) when iRdRegular = '1' else
            (0 => iRdRiType, others => '0');

  -- Select tree Q3, then Q2, then Q1; rows indexed by the raw 4-bit Qi
  p_lookup : process (all) is

    variable vRow : std_logic_vector(0 to 15);
    variable vL2  : std_logic_vector(0 to 15);
    variable vL1  : std_logic_vector(0 to 15);
    variable vIdx : integer;

  begin

    vL1 := (others => '0');
    for i1 in 0 to 4 loop
      vL2 := (others => '0');
      for i2 in -4 to 4 loop
        vRow := (others => '0');
        for i3 in -4 to 4 loop
          vIdx := 81 * i1 + 9 * i2 + i3;
          if (vIdx >= 0 and vIdx < REG_CONTEXTS) then
            vRow(to_integer(unsigned(to_signed(i3, 4)))) := sUseInitValue(vIdx);
          end if;
        end loop;
        vL2(to_integer(unsigned(to_signed(i2, 4)))) := vRow(to_integer(unsigned(iRdQ3)));
      end loop;
      vL1(i1) := vL2(to_integer(unsigned(iRdQ2)));
    end loop;

    if (iRdRegular = '1') then
      sLookup <= vL1(to_integer(unsigned(iRdQ1)));
    elsif (iRdRiType = '1') then
      sLookup <= sUseInitValue(REG_CONTEXTS + 1);
    else
      sLookup <= sUseInitValue(REG_CONTEXTS);
    end if;

  end process p_lookup;

  p_init_tracker : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sUseInitValue <= (others => '1');
        sClrPend      <= '0';
      else
        -- The EOI read's clear would hit the next image
        sClrPend <= iRdEn and not iEndOfImage;

        if (iRdEn = '1') then
          sUseInitReg <= sLookup and not (sClrPend and bool2bit(sClrKey = sRdKey));
          sClrAddr    <= iRdAddr;
          sClrKey     <= sRdKey;
        end if;

        if (sClrPend = '1') then
          sUseInitValue(to_integer(unsigned(sClrAddr))) <= '0';
        end if;

        if (iEndOfImage = '1') then
          sUseInitValue <= (others => '1');
        end if;
      end if;
    end if;

  end process p_init_tracker;

  p_fwd : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sFwdSameReg <= '0';
        sWrDataReg  <= (others => '0');
      elsif (iRdEn = '1') then
        sFwdSameReg <= iWrEn and bool2bit(iWrAddr = iRdAddr);
        sWrDataReg  <= iWrData;
      end if;
    end if;

  end process p_fwd;

  sRdAlt    <= CTX_INIT when sUseInitReg = '1' else
               sWrDataReg;
  sRdUseAlt <= sUseInitReg or sFwdSameReg;

  oRdData   <= sRdAlt when sRdUseAlt = '1' else
               sBramRdData;
  oRdBram   <= sBramRdData;
  oRdAlt    <= sRdAlt;
  oRdUseAlt <= sRdUseAlt;

  postponed assert iRdEn /= '1' or is_x(iRdAddr) or unsigned(iRdAddr) < RAM_DEPTH
    report "context_ram: read address past depth" severity error;
  postponed assert iRdEn /= '1' or iRdRegular /= '1' or is_x(iRdAddr) or is_x(sRdKey)
    or 81 * to_integer(iRdQ1) + 9 * to_integer(iRdQ2) + to_integer(iRdQ3) = to_integer(unsigned(iRdAddr))
    report "context_ram: read Qi disagree with the read address" severity error;
  postponed assert iRdEn /= '1' or iRdRegular /= '0' or is_x(iRdAddr) or is_x(iRdRiType)
    or to_integer(unsigned(iRdAddr)) = REG_CONTEXTS + to_integer(unsigned'('0' & iRdRiType))
    report "context_ram: read RItype disagrees with the read address" severity error;
  postponed assert iWrEn /= '1' or is_x(iWrAddr) or unsigned(iWrAddr) < RAM_DEPTH
    report "context_ram: write address past depth" severity error;

end architecture behavioral;
