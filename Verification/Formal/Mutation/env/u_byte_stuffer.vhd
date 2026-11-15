-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
-- byte_stuffer with the openjls_top stall loop (from gold's oAlmostFull; oAlmostFull is compared, so both
-- copies see one stall until the first divergence). Words as A11_2 emits them: zero past iWordValidLen
library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;
  use work.olo_base_pkg_math.all;

entity @NAME@ is
  generic (
    @TOPGENS@;
    BURST : natural := 8
  )@PORT@;
end entity @NAME@;

architecture formal of @NAME@ is

  @CONSTS@
  constant LW : natural := log2ceil(LIMIT + 1);
  attribute anyseq : boolean;
  -- free
  signal iRst_i, iWordValid_i, iFlush_i, iReady_i : std_logic;
  signal iWord_i : std_logic_vector(LIMIT - 1 downto 0);
  signal iLen_i : unsigned(LW - 1 downto 0);
  attribute anyseq of iRst_i, iWordValid_i, iFlush_i, iReady_i, iWord_i, iLen_i : signal is true;
  -- end free
  signal sInit : std_logic := '1';
  signal sGap : natural range 0 to 3 := 3;  -- accepted cycles since the last flush
  signal sAfReg, sStallDelay, sStallLogic, sStall : std_logic;

  type t_out is record
    w : std_logic_vector(BYTE_STUFFER_OUT_WIDTH - 1 downto 0);
    v, af, fd : std_logic;
    nb : unsigned(log2ceil(BYTE_STUFFER_OUT_BYTES_PER_CYCLE + 1) - 1 downto 0);
  end record;
  signal g, m : t_out;

  function tail_zero (w : std_logic_vector; n : unsigned) return boolean is
  begin
    for i in w'range loop
      if i < w'length - to_integer(n) and w(i) /= '0' then return false; end if;
    end loop;
    return true;
  end function;

  -- The framer reads oWord and oValidBytes only on a valid beat
  function same (a, b : t_out) return boolean is
  begin
    -- Only the first nb bytes (from the top) count: the framer writes j < oValidBytes
    if a.v /= b.v or a.af /= b.af or a.fd /= b.fd then return false; end if;
    if a.v = '0' then return true; end if;
    if a.nb /= b.nb then return false; end if;
    for i in a.w'range loop
      if i >= a.w'length - 8 * to_integer(a.nb) and a.w(i) /= b.w(i) then return false; end if;
    end loop;
    return true;
  end function;

begin

  -- p_stall_control
  sStall <= sAfReg;
  p_env : process (clk) is
  begin
    if rising_edge(clk) then
      sInit <= '0';
      if iRst_i = '1' then sGap <= 3;
      elsif sStallLogic = '0' then
        if iFlush_i = '1' then sGap <= 0; elsif sGap < 3 then sGap <= sGap + 1; end if;
      end if;
      if iRst_i = '1' then
        sAfReg <= '0'; sStallDelay <= '0'; sStallLogic <= '0';
      else
        sAfReg <= g.af; sStallDelay <= sStall; sStallLogic <= sStallDelay and sStall;
      end if;
    end if;
  end process p_env;

  u_gold : entity work.byte_stuffer(behavioral)
    generic map (IN_WIDTH => LIMIT, OUT_BYTES_PER_CYCLE => BYTE_STUFFER_OUT_BYTES_PER_CYCLE, BURST_DEPTH => BURST)
    port map (iClk => clk, iRst => iRst_i, iStall => sStallLogic, iWord => iWord_i, iWordValid => iWordValid_i,
              iWordValidLen => iLen_i, iFlush => iFlush_i, oWord => g.w, oWordValid => g.v, oValidBytes => g.nb,
              iReady => iReady_i, oAlmostFull => g.af, oFlushDone => g.fd);
  u_mut : entity work.byte_stuffer_mut(behavioral)
    generic map (IN_WIDTH => LIMIT, OUT_BYTES_PER_CYCLE => BYTE_STUFFER_OUT_BYTES_PER_CYCLE, BURST_DEPTH => BURST)
    port map (iClk => clk, iRst => iRst_i, iStall => sStallLogic, iWord => iWord_i, iWordValid => iWordValid_i,
              iWordValidLen => iLen_i, iFlush => iFlush_i, oWord => m.w, oWordValid => m.v, oValidBytes => m.nb,
              iReady => iReady_i, oAlmostFull => m.af, oFlushDone => m.fd);

  -- @CHECK@
  -- psl default clock is rising_edge(clk);
  -- psl assume always (sInit = '1' -> iRst_i = '1');
  -- psl assume always (iLen_i <= LIMIT and (iWordValid_i = '0' or (iLen_i > 0 and tail_zero(iWord_i, iLen_i))));
  -- psl assume always (iFlush_i = '1' -> iWordValid_i = '1');  -- header contract: iFlush arrives with the last word
  -- psl assume always ((iFlush_i = '1' and sStallLogic = '0') -> sGap = 3);  -- images >= 4 pixels: flushes >= 4 accepted cycles apart
  -- psl assert always (sInit = '0' -> (same(g, m)));
  -- @END@

end architecture formal;
