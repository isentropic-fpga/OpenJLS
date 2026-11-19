-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
-- Miter: gold top (library openjls) and mutant top (work) on the same random stimulus; reports any output difference.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.math_real.all;
library openjls;

entity tb_miter is
  generic (BITNESS : positive := 8; OUT_WIDTH : positive := 64; SEED : positive := 1; SEGS : positive := 150);
end entity;

architecture sim of tb_miter is
  constant MAXD : natural := 64;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal iValid, iReady : std_logic := '0';
  signal iPixel : std_logic_vector(BITNESS-1 downto 0) := (others => '0');
  signal w, h : std_logic_vector(15 downto 0) := x"0004";
  signal rA, vA, lA, rB, vB, lB : std_logic;
  signal dA, dB : std_logic_vector(OUT_WIDTH-1 downto 0);
  signal kA, kB : std_logic_vector(OUT_WIDTH/8-1 downto 0);
  signal readyPct : real := 1.0;
  signal cycles : natural := 0;
  signal done : boolean := false;
  function mask(d, k : std_logic_vector) return std_logic_vector is
    variable r : std_logic_vector(d'range) := d;
  begin
    for i in 0 to k'length-1 loop
      if k(i) /= '1' then r(8*i+7 downto 8*i) := (others => '0'); end if;
    end loop;
    return r;
  end function;
begin
  clk <= not clk after 5 ns when not done;
  a : entity openjls.openjls_top(rtl)
    generic map (BITNESS=>BITNESS, MAX_IMAGE_WIDTH=>MAXD, MAX_IMAGE_HEIGHT=>MAXD, OUT_WIDTH=>OUT_WIDTH)
    port map (iClk=>clk, iRst=>rst, iValid=>iValid, iPixel=>iPixel, oReady=>rA, iImageWidth=>w, iImageHeight=>h,
              oData=>dA, oValid=>vA, oKeep=>kA, oLast=>lA, iReady=>iReady);
  b : entity work.openjls_top(rtl)
    generic map (BITNESS=>BITNESS, MAX_IMAGE_WIDTH=>MAXD, MAX_IMAGE_HEIGHT=>MAXD, OUT_WIDTH=>OUT_WIDTH)
    port map (iClk=>clk, iRst=>rst, iValid=>iValid, iPixel=>iPixel, oReady=>rB, iImageWidth=>w, iImageHeight=>h,
              oData=>dB, oValid=>vB, oKeep=>kB, oLast=>lB, iReady=>iReady);

  compare : process (clk) begin
    if falling_edge(clk) and rst = '0' then
      cycles <= cycles + 1;
      if rA /= rB or vA /= vB or (vA = '1' and (kA /= kB or lA /= lB or mask(dA, kA) /= mask(dB, kB))) then
        report "MITER: DIFF at cycle " & integer'image(cycles) severity failure;
      end if;
    end if;
  end process;

  rdy : process
    variable s1 : positive := SEED; variable s2 : positive := SEED + 77; variable x : real;
  begin
    wait until rising_edge(clk);
    uniform(s1, s2, x);
    iReady <= '1' when x < readyPct else '0';
  end process;

  stim : process
    variable s1 : positive := SEED + 5; variable s2 : positive := SEED + 991;
    impure function rnd(lo, hi : integer) return integer is
      variable x : real;
    begin
      uniform(s1, s2, x);
      return lo + integer(floor(x * real(hi - lo + 1)));
    end function;
    variable iw, ih, n, top, vp, base : integer;
    constant PCT : integer_vector := (100, 100, 95, 50, 30, 10, 3);
  begin
    for seg in 1 to SEGS loop
      iw := rnd(4, 24); ih := rnd(1, 8); n := rnd(1, 12);
      case rnd(0, 3) is
        when 0 => top := 1;
        when 1 => top := 3;
        when 2 => top := 15;
        when others => top := 2**BITNESS - 1;
      end case;
      vp := PCT(rnd(0, 6)); readyPct <= real(PCT(rnd(0, 6))) / 100.0;
      w <= std_logic_vector(to_unsigned(iw, 16)); h <= std_logic_vector(to_unsigned(ih, 16));
      rst <= '1'; iValid <= '0'; wait for 40 ns; wait until rising_edge(clk); rst <= '0';
      wait until rising_edge(clk);
      for p in 1 to n * iw * ih loop
        while rnd(0, 99) >= vp loop
          iValid <= '0'; wait until rising_edge(clk);
        end loop;
        base := rnd(0, 2**BITNESS - 1 - top);
        if rnd(0, 3) = 0 then base := 0; end if;
        iPixel <= std_logic_vector(to_unsigned(base + rnd(0, top), BITNESS));
        iValid <= '1';
        wait until rising_edge(clk) and rA = '1';
        -- abort a few segments mid-image
        exit when seg mod 17 = 0 and p = n * iw * ih / 2;
      end loop;
      iValid <= '0';
      readyPct <= 0.6;
      for c in 1 to 2500 loop wait until rising_edge(clk); end loop;
    end loop;
    report "MITER: SAME " & integer'image(cycles) & " cycles";
    done <= true;
    wait;
  end process;
end architecture;
