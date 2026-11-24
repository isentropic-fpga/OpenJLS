-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
-- jls_framer as openjls_top drives it: dims latched in reset, at most CO_MAX_IMAGES_IN_FLIGHT images,
-- data and EOI only for a started image, EOI only on a beat, accepted EOI beats never on consecutive cycles
-- (byte_stuffer check, bs_eoi_gap)
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
  constant BI : natural := BYTE_STUFFER_OUT_WIDTH / 8;
  attribute anyseq : boolean;
  -- free
  signal iRst_i, iStart_i, iEoi_i, iValid_i, iReady_i : std_logic;
  signal iWidth_i : unsigned(log2ceil(MAX_IMAGE_WIDTH + 1) - 1 downto 0);
  signal iHeight_i : unsigned(log2ceil(MAX_IMAGE_HEIGHT + 1) - 1 downto 0);
  signal iWord_i : std_logic_vector(BYTE_STUFFER_OUT_WIDTH - 1 downto 0);
  signal iBe_i : unsigned(log2ceil(BI + 1) - 1 downto 0);
  attribute anyseq of iRst_i, iStart_i, iEoi_i, iValid_i, iReady_i, iWidth_i, iHeight_i, iWord_i, iBe_i : signal is true;
  -- end free
  signal sInit : std_logic := '1';
  signal sPrevRst : std_logic := '1';
  signal sPrevEoi : std_logic := '0';
  signal sPrevW : unsigned(iWidth_i'range);
  signal sPrevH : unsigned(iHeight_i'range);
  -- sFlight: start to last output beat accepted (as openjls_top p_images_in_flight); sOpen: start to EOI input
  signal sFlight, sOpen : natural range 0 to 7 := 0;
  signal sStartN : natural range 0 to 1;

  type t_out is record
    w : std_logic_vector(OUT_WIDTH - 1 downto 0);
    v, l, r : std_logic;
    nb : unsigned(log2ceil(OUT_WIDTH / 8 + 1) - 1 downto 0);
  end record;
  signal g, m : t_out;

  -- AXIS: only bytes under TKEEP count (the top derives oKeep from oByteEnable)
  function same (a, b : t_out) return boolean is
  begin
    if a.v /= b.v or a.r /= b.r or (a.v = '1' and (a.l /= b.l or a.nb /= b.nb)) then
      return false;
    end if;
    if a.v = '1' then
      for i in 0 to OUT_WIDTH / 8 - 1 loop
        if i < to_integer(a.nb) and a.w(OUT_WIDTH - 1 - 8 * i downto OUT_WIDTH - 8 - 8 * i)
                                    /= b.w(OUT_WIDTH - 1 - 8 * i downto OUT_WIDTH - 8 - 8 * i) then
          return false;
        end if;
      end loop;
    end if;
    return true;
  end function;

begin

  sStartN <= 1 when iStart_i = '1' else 0;

  p_env : process (clk) is
    variable vF, vO : natural range 0 to 8;
  begin
    if rising_edge(clk) then
      sInit <= '0';
      sPrevRst <= iRst_i;
      sPrevEoi <= iEoi_i and iValid_i and g.r;
      sPrevW <= iWidth_i; sPrevH <= iHeight_i;
      if iRst_i = '1' then
        sFlight <= 0; sOpen <= 0;
      else
        vF := sFlight; vO := sOpen;
        if iStart_i = '1' then vF := vF + 1; vO := vO + 1; end if;
        if g.v = '1' and iReady_i = '1' and g.l = '1' then vF := vF - 1; end if;
        if iValid_i = '1' and iEoi_i = '1' and g.r = '1' then vO := vO - 1; end if;
        sFlight <= vF; sOpen <= vO;
      end if;
    end if;
  end process p_env;

  u_gold : entity work.jls_framer(behavioral)
    generic map (BITNESS => BITNESS, IN_WIDTH => BYTE_STUFFER_OUT_WIDTH, OUT_WIDTH => OUT_WIDTH,
                 MAX_IMAGE_WIDTH => MAX_IMAGE_WIDTH, MAX_IMAGE_HEIGHT => MAX_IMAGE_HEIGHT)
    port map (iClk => clk, iRst => iRst_i, iStart => iStart_i, iImageWidth => iWidth_i, iImageHeight => iHeight_i,
              iEoi => iEoi_i, iWord => iWord_i, iValid => iValid_i, iByteEnable => iBe_i, oReady => g.r,
              iReady => iReady_i, oWord => g.w, oValid => g.v, oByteEnable => g.nb, oLast => g.l);
  u_mut : entity work.jls_framer_mut(behavioral)
    generic map (BITNESS => BITNESS, IN_WIDTH => BYTE_STUFFER_OUT_WIDTH, OUT_WIDTH => OUT_WIDTH,
                 MAX_IMAGE_WIDTH => MAX_IMAGE_WIDTH, MAX_IMAGE_HEIGHT => MAX_IMAGE_HEIGHT)
    port map (iClk => clk, iRst => iRst_i, iStart => iStart_i, iImageWidth => iWidth_i, iImageHeight => iHeight_i,
              iEoi => iEoi_i, iWord => iWord_i, iValid => iValid_i, iByteEnable => iBe_i, oReady => m.r,
              iReady => iReady_i, oWord => m.w, oValid => m.v, oByteEnable => m.nb, oLast => m.l);

  -- @CHECK@
  -- psl default clock is rising_edge(clk);
  -- psl assume always (sInit = '1' -> iRst_i = '1');
  -- psl assume always (iWidth_i >= 4 and iWidth_i <= MAX_IMAGE_WIDTH and iHeight_i >= 1 and iHeight_i <= MAX_IMAGE_HEIGHT);
  -- psl assume always ((sInit = '0' and sPrevRst = '0') -> (iWidth_i = sPrevW and iHeight_i = sPrevH));
  -- psl assume always (iRst_i = '1' -> (iStart_i = '0' and iValid_i = '0'));
  -- psl assume always (sFlight + sStartN <= CO_MAX_IMAGES_IN_FLIGHT);
  -- psl assume always (iValid_i = '1' -> (sOpen > 0 and iBe_i <= BI));
  -- psl assume always (iEoi_i = '1' -> iValid_i = '1');
  -- psl assume always ((sInit = '0' and iRst_i = '0') -> not (iEoi_i = '1' and iValid_i = '1' and g.r = '1' and sPrevEoi = '1'));
  -- psl assert always (sInit = '0' -> (same(g, m)));
  -- @END@

end architecture formal;
