-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
-- line_buffer as openjls_top drives it: dims stable within an image, 4 <= width, 1 <= height
library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.all;

entity @NAME@ is
  generic (
    BITNESS          : natural := 8;
    MAX_IMAGE_WIDTH  : natural := 7;
    MAX_IMAGE_HEIGHT : natural := 4
  )@PORT@;
end entity @NAME@;

architecture formal of @NAME@ is

  constant WW : natural := log2ceil(MAX_IMAGE_WIDTH + 1);
  constant HW : natural := log2ceil(MAX_IMAGE_HEIGHT + 1);
  attribute anyseq : boolean;
  -- free
  signal iRst_i, iValid_i : std_logic;
  signal iPixel_i : unsigned(BITNESS - 1 downto 0);
  signal iW_i : unsigned(WW - 1 downto 0);
  signal iH_i : unsigned(HW - 1 downto 0);
  attribute anyseq of iRst_i, iValid_i, iPixel_i, iW_i, iH_i : signal is true;
  -- end free
  signal sInit : std_logic := '1';
  signal sCol : unsigned(WW - 1 downto 0);
  signal sRow : unsigned(HW - 1 downto 0);
  signal sPrevW : unsigned(WW - 1 downto 0);
  signal sPrevH : unsigned(HW - 1 downto 0);

  type t_out is record
    a, b, c, d : unsigned(BITNESS - 1 downto 0);
    v, eol, eoi : std_logic;
  end record;
  signal g, m : t_out;

  -- p_reg1 reads the neighbours and flags only with oValid
  function same (x, y : t_out) return boolean is
  begin
    return x.v = y.v and (x.v = '0' or (x.a = y.a and x.b = y.b and x.c = y.c and x.d = y.d
                                         and x.eol = y.eol and x.eoi = y.eoi));
  end function;

begin

  p_env : process (clk) is
  begin
    if rising_edge(clk) then
      sInit  <= '0';
      sPrevW <= iW_i;
      sPrevH <= iH_i;
      if iRst_i = '1' then
        sCol <= (others => '0'); sRow <= (others => '0');
      elsif iValid_i = '1' then
        if sCol = iW_i - 1 then
          sCol <= (others => '0');
          sRow <= (others => '0') when sRow = iH_i - 1 else sRow + 1;
        else
          sCol <= sCol + 1;
        end if;
      end if;
    end if;
  end process p_env;

  u_gold : entity work.line_buffer(behavioral)
    generic map (MAX_IMAGE_WIDTH => MAX_IMAGE_WIDTH, MAX_IMAGE_HEIGHT => MAX_IMAGE_HEIGHT, BITNESS => BITNESS)
    port map (iClk => clk, iRst => iRst_i, iImageWidth => iW_i, iImageHeight => iH_i, iValid => iValid_i,
              iPixel => iPixel_i, oA => g.a, oB => g.b, oC => g.c, oD => g.d, oValid => g.v, oEol => g.eol, oEoi => g.eoi);
  u_mut : entity work.line_buffer_mut(behavioral)
    generic map (MAX_IMAGE_WIDTH => MAX_IMAGE_WIDTH, MAX_IMAGE_HEIGHT => MAX_IMAGE_HEIGHT, BITNESS => BITNESS)
    port map (iClk => clk, iRst => iRst_i, iImageWidth => iW_i, iImageHeight => iH_i, iValid => iValid_i,
              iPixel => iPixel_i, oA => m.a, oB => m.b, oC => m.c, oD => m.d, oValid => m.v, oEol => m.eol, oEoi => m.eoi);

  -- @CHECK@
  -- psl default clock is rising_edge(clk);
  -- psl assume always (sInit = '1' -> iRst_i = '1');
  -- psl assume always (iW_i >= 4 and iW_i <= MAX_IMAGE_WIDTH and iH_i >= 1 and iH_i <= MAX_IMAGE_HEIGHT);
  -- psl assume always ((iValid_i = '1' or sCol /= 0 or sRow /= 0) -> (iW_i = sPrevW and iH_i = sPrevH));
  -- psl assert always (sInit = '0' -> (same(g, m)));
  -- @END@

end architecture formal;
