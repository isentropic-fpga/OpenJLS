-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- context_ram: context variables A, B, C, N for the 365 regular and 2 run-interruption contexts
--
-- Per-address init flags: after iEndOfImage, the first read of each context returns the initial values.

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
    iRdEn           : in    std_logic;
    iEndOfImage     : in    std_logic;
    oRdData         : out   std_logic_vector(TOTAL_WIDTH - 1 downto 0)
  );
end entity context_ram;

architecture behavioral of context_ram is

  constant A_INIT      : natural := math_max(2, (RANGE_P + 32) / 64);
  constant B_INIT      : integer := 0;
  constant C_INIT      : integer := 0;
  constant N_INIT      : natural := 1;

  -- (A | B | C | N); run contexts reuse it as (A | Nn | 0 | N) with Nn = 0
  constant CTX_INIT    : std_logic_vector(TOTAL_WIDTH - 1 downto 0) :=
                                                                       std_logic_vector(to_unsigned(A_INIT, A_WIDTH)) &
                                                                       std_logic_vector(to_signed(B_INIT, B_WIDTH)) &
                                                                       std_logic_vector(to_signed(C_INIT, C_WIDTH)) &
                                                                       std_logic_vector(to_unsigned(N_INIT, N_WIDTH));

  signal sUseInitValue : std_logic_vector(RAM_DEPTH - 1 downto 0); -- per address: next read returns CTX_INIT
  signal sUseInitReg   : std_logic;
  signal sBramRdData   : std_logic_vector(TOTAL_WIDTH - 1 downto 0);

  -- Same-address write forwarding: WBR on top of an RBW BRAM
  signal sFwdSameReg   : std_logic;
  signal sWrDataReg    : std_logic_vector(TOTAL_WIDTH - 1 downto 0);

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

  p_init_tracker : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sUseInitValue <= (others => '1');
      else
        if (iRdEn = '1') then
          sUseInitReg                                  <= sUseInitValue(to_integer(unsigned(iRdAddr)));
          sUseInitValue(to_integer(unsigned(iRdAddr))) <= '0';
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

  oRdData <= CTX_INIT when sUseInitReg = '1' else
             sWrDataReg when sFwdSameReg = '1' else
             sBramRdData;

  postponed assert iRdEn /= '1' or is_x(iRdAddr) or unsigned(iRdAddr) < RAM_DEPTH
    report "context_ram: read address past depth" severity error;
  postponed assert iWrEn /= '1' or is_x(iWrAddr) or unsigned(iWrAddr) < RAM_DEPTH
    report "context_ram: write address past depth" severity error;

end architecture behavioral;
