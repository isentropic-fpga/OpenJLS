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
-- Writes land a cycle late from a register. The read word loads a second register under iWordCE, along with the
-- three writes the read cannot see: the one before it, the one with it, and the one a cycle after.

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
    -- Low on stall: holds the write history a stalled read still has to forward from
    iAdvance        : in    std_logic;
    -- Loads the output word; high the cycle after iRdEn unless stalled
    iWordCE         : in    std_logic;
    oRdData         : out   std_logic_vector(TOTAL_WIDTH - 1 downto 0)
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
  signal sBramWord     : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
  signal sUseInitWord  : std_logic;

  signal sWrPendEn     : std_logic;
  signal sWrPendAddr   : std_logic_vector(log2ceil(RAM_DEPTH) - 1 downto 0);
  signal sWrPendData   : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
  signal sWrPend2En    : std_logic;
  signal sWrPend2Addr  : std_logic_vector(log2ceil(RAM_DEPTH) - 1 downto 0);
  signal sWrPend2Data  : std_logic_vector(TOTAL_WIDTH - 1 downto 0);

  -- Same-address write forwarding: WBR on top of an RBW BRAM. New: the write at the word load; Old: the two before it
  signal sFwdNew       : std_logic;
  signal sFwdOld       : std_logic;
  signal sFwdNewData   : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
  signal sFwdOldData   : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
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
      Wr_Addr         => sWrPendAddr,
      Wr_Ena          => sWrPendEn,
      Wr_Be           => open,
      Wr_Data         => sWrPendData,
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

  -- No reset: a write on the first reset cycle still lands, as with the unregistered port.
  -- A stall repeats the pending write, which is harmless: no read runs meanwhile
  p_wr_pend : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iAdvance = '1') then
        sWrPendEn    <= iWrEn;
        sWrPendAddr  <= iWrAddr;
        sWrPendData  <= iWrData;
        sWrPend2En   <= sWrPendEn;
        sWrPend2Addr <= sWrPendAddr;
        sWrPend2Data <= sWrPendData;
      end if;
    end if;

  end process p_wr_pend;

  -- No reset and no other load, so it maps onto the BRAM output register
  p_word : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iWordCE = '1') then
        sBramWord <= sBramRdData;
      end if;
    end if;

  end process p_word;

  -- sClrAddr holds the read address here. The newest write wins at the output, so iWrData lands on a plain register
  p_fwd : process (iClk) is

    variable vPend1Hit : std_logic;
    variable vPend2Hit : std_logic;

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sUseInitWord <= '0';
        sFwdNew      <= '0';
        sFwdOld      <= '0';
        sFwdNewData  <= (others => '0');
        sFwdOldData  <= (others => '0');
      elsif (iWordCE = '1') then
        vPend1Hit := sWrPendEn and bool2bit(sWrPendAddr = sClrAddr);
        vPend2Hit := sWrPend2En and bool2bit(sWrPend2Addr = sClrAddr);

        sUseInitWord <= sUseInitReg;
        sFwdNew      <= iWrEn and bool2bit(iWrAddr = sClrAddr);
        sFwdOld      <= vPend1Hit or vPend2Hit;
        sFwdNewData  <= iWrData;
        if (vPend1Hit = '1') then
          sFwdOldData <= sWrPendData;
        else
          sFwdOldData <= sWrPend2Data;
        end if;
      end if;
    end if;

  end process p_fwd;

  sRdAlt    <= CTX_INIT when sUseInitWord = '1' else
               sFwdNewData when sFwdNew = '1' else
               sFwdOldData;
  sRdUseAlt <= sUseInitWord or sFwdNew or sFwdOld;

  oRdData   <= sRdAlt when sRdUseAlt = '1' else
               sBramWord;

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
