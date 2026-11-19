-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
-- context_ram with the BRAM cut out: both copies read one free word (their RAM ports see the same values,
-- so their RAM contents match). Addresses, Q ranges and word liveness as openjls_top drives them
library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.all;

entity @NAME@ is
  generic (
    @TOPGENS@
  )@PORT@;
end entity @NAME@;

architecture formal of @NAME@ is

  @CONSTS@
  constant AW : natural := log2ceil(RAM_DEPTH);
  attribute anyseq : boolean;
  -- free
  signal iRst_i, iWrEn_i, iRdRegular_i, iRdRiType_i, iRdEn_i, iEndOfImage_i, iAdvance_i, iWordCE_i : std_logic;
  signal iWrAddr_i : std_logic_vector(AW - 1 downto 0);
  signal iWrData_i, iRam_i : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
  signal iRdQ1_i, iRdQ2_i, iRdQ3_i : signed(3 downto 0);
  attribute anyseq of iRst_i, iWrEn_i, iRdRegular_i, iRdRiType_i, iRdEn_i, iEndOfImage_i, iAdvance_i, iWordCE_i,
                      iWrAddr_i, iWrData_i, iRam_i, iRdQ1_i, iRdQ2_i, iRdQ3_i : signal is true;
  -- end free
  signal sInit : std_logic := '1';
  signal sRdAddr : std_logic_vector(AW - 1 downto 0);
  signal sPend, sLive : std_logic;

  type t_out is record
    d, bram, alt : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
    useAlt : std_logic;
  end record;
  signal g, m : t_out;

begin

  sRdAddr <= std_logic_vector(to_unsigned(81 * to_integer(iRdQ1_i) + 9 * to_integer(iRdQ2_i) + to_integer(iRdQ3_i), AW))
             when iRdRegular_i = '1' else
             std_logic_vector(to_unsigned(365, AW)) when iRdRiType_i = '0' else
             std_logic_vector(to_unsigned(366, AW));

  -- A word is live from the iWordCE that loads a read's data until the next iWordCE
  p_env : process (clk) is
  begin
    if rising_edge(clk) then
      sInit <= '0';
      if iRst_i = '1' then
        sPend <= '0'; sLive <= '0';
      elsif iWordCE_i = '1' then
        sLive <= sPend; sPend <= iRdEn_i;
      else
        sPend <= sPend or iRdEn_i;
      end if;
    end if;
  end process p_env;

  u_gold : entity work.context_ram(behavioral)
    generic map (RANGE_P => RANGE_P, RAM_DEPTH => RAM_DEPTH, A_WIDTH => A_STORED, B_WIDTH => B_STORED,
                 C_WIDTH => C_STORED, N_WIDTH => N_STORED, TOTAL_WIDTH => TOTAL_WIDTH)
    port map (iClk => clk, iRst => iRst_i, iWrAddr => iWrAddr_i, iWrEn => iWrEn_i, iWrData => iWrData_i,
              iRdAddr => sRdAddr, iRdRegular => iRdRegular_i, iRdRiType => iRdRiType_i, iRdQ1 => iRdQ1_i,
              iRdQ2 => iRdQ2_i, iRdQ3 => iRdQ3_i, iRdEn => iRdEn_i, iEndOfImage => iEndOfImage_i,
              iAdvance => iAdvance_i, iWordCE => iWordCE_i, iFormalRamRd => iRam_i,
              oRdData => g.d, oRdBram => g.bram, oRdAlt => g.alt, oRdUseAlt => g.useAlt);
  u_mut : entity work.context_ram_mut(behavioral)
    generic map (RANGE_P => RANGE_P, RAM_DEPTH => RAM_DEPTH, A_WIDTH => A_STORED, B_WIDTH => B_STORED,
                 C_WIDTH => C_STORED, N_WIDTH => N_STORED, TOTAL_WIDTH => TOTAL_WIDTH)
    port map (iClk => clk, iRst => iRst_i, iWrAddr => iWrAddr_i, iWrEn => iWrEn_i, iWrData => iWrData_i,
              iRdAddr => sRdAddr, iRdRegular => iRdRegular_i, iRdRiType => iRdRiType_i, iRdQ1 => iRdQ1_i,
              iRdQ2 => iRdQ2_i, iRdQ3 => iRdQ3_i, iRdEn => iRdEn_i, iEndOfImage => iEndOfImage_i,
              iAdvance => iAdvance_i, iWordCE => iWordCE_i, iFormalRamRd => iRam_i,
              oRdData => m.d, oRdBram => m.bram, oRdAlt => m.alt, oRdUseAlt => m.useAlt);

  -- @CHECK@
  -- psl default clock is rising_edge(clk);
  -- psl assume always (sInit = '1' -> iRst_i = '1');
  -- psl assume always (iRdQ1_i >= 0 and iRdQ1_i <= 4 and iRdQ2_i >= -4 and iRdQ2_i <= 4 and iRdQ3_i >= -4 and iRdQ3_i <= 4);
  -- A4_1 sign merge: the first nonzero Qi is positive, so the context index is in [0, 364]
  -- psl assume always (81 * to_integer(iRdQ1_i) + 9 * to_integer(iRdQ2_i) + to_integer(iRdQ3_i) >= 0);
  -- psl assume always (unsigned(iWrAddr_i) < RAM_DEPTH);
  -- psl assert always (sInit = '0' -> (sLive = '0' or (g.d = m.d and g.bram = m.bram and g.alt = m.alt and g.useAlt = m.useAlt)));
  -- @END@

end architecture formal;
