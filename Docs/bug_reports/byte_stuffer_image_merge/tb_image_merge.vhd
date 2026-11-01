-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
-- tb_image_merge: back-to-back images into openjls_top, dumps pixels and output bytes for a CharLS compare

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.math_real.all;
  use std.textio.all;

entity tb_image_merge is
  generic (
    BITNESS   : positive := 16;
    W         : positive := 4;
    H         : positive := 4;
    NIMG      : positive := 30;
    VALID_PCT : natural  := 100;
    READY_PCT : natural  := 100;
    SEED      : positive := 1;
    DUMP      : string   := "case"
  );
end entity tb_image_merge;

architecture sim of tb_image_merge is
  constant OUT_WIDTH : positive := 64;
  constant MAXV      : natural  := 2 ** BITNESS - 1;

  signal clk, rst       : std_logic := '1';
  signal iValid, iReady : std_logic := '0';
  signal iPixel         : std_logic_vector(BITNESS - 1 downto 0) := (others => '0');
  signal dimW, dimH     : std_logic_vector(15 downto 0);
  signal oReady, oValid : std_logic;
  signal oLast          : std_logic;
  signal oData          : std_logic_vector(OUT_WIDTH - 1 downto 0);
  signal oKeep          : std_logic_vector(OUT_WIDTH / 8 - 1 downto 0);
  signal done           : boolean := false;
begin
  dimW <= std_logic_vector(to_unsigned(W, 16));
  dimH <= std_logic_vector(to_unsigned(H, 16));
  clk  <= not clk after 5 ns when not done;

  u_dut : entity work.openjls_top
    generic map (BITNESS => BITNESS, MAX_IMAGE_WIDTH => 4096, MAX_IMAGE_HEIGHT => 4096, OUT_WIDTH => OUT_WIDTH)
    port map (clk, rst, iValid, iPixel, oReady, dimW, dimH, oData, oValid, oKeep, oLast, iReady);

  -- Region mix per 8x4 tile: flat (run mode), ramp, full-range noise, small noise, 0/MAX extremes
  p_stim : process is
    file     pf      : text;
    variable pl      : line;
    variable s1, s2  : positive := SEED;
    variable s3, s4  : positive := SEED + 7;
    variable r       : real;
    variable px      : integer;
    variable lastv   : integer := MAXV / 2;
  begin
    file_open(pf, DUMP & "_pix.txt", write_mode);
    for i in 1 to 4 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);
    for k in 0 to NIMG - 1 loop
      for y in 0 to H - 1 loop
        for x in 0 to W - 1 loop
          uniform(s1, s2, r);
          case ((x / 8) + (y / 4) * 3 + k) mod 5 is
            when 0      => px := (k * 37) mod (MAXV + 1);
            when 1      => px := ((x + y) * (MAXV / (W + H))) mod (MAXV + 1);
            when 2      => px := integer(floor(r * real(MAXV + 1)));
            when 3      => px := lastv + integer(floor(r * 9.0)) - 4;
            when others => px := MAXV * (x mod 2);
          end case;
          px    := maximum(0, minimum(MAXV, px));
          lastv := px;
          write(pl, integer'image(px));
          writeline(pf, pl);
          iPixel <= std_logic_vector(to_unsigned(px, BITNESS));
          loop
            uniform(s3, s4, r);
            if r * 100.0 < real(VALID_PCT) then
              iValid <= '1';
              wait until rising_edge(clk);
              exit when oReady = '1';
            else
              iValid <= '0';
              wait until rising_edge(clk);
            end if;
          end loop;
        end loop;
      end loop;
    end loop;
    iValid <= '0';
    file_close(pf);
    wait;
  end process p_stim;

  p_ready : process is
    variable s1, s2 : positive := SEED + 101;
    variable r      : real;
  begin
    wait until rising_edge(clk);
    uniform(s1, s2, r);
    iReady <= '1' when r * 100.0 < real(READY_PCT) else '0';
  end process p_ready;

  -- The bug's trigger: the skid refills while the stuff buffer still holds an image's last word
  p_merge : process is
    alias taken is <<signal .tb_image_merge.u_dut.u_byte_stuffer.sSkidTaken : std_logic>>;
    alias last  is <<signal .tb_image_merge.u_dut.u_byte_stuffer.sStuffBufferLast : std_logic>>;
  begin
    wait until rising_edge(clk);
    if taken = '1' and last = '1' then
      report "MERGE: skid refill while the stuff buffer holds a last word" severity warning;
    end if;
  end process p_merge;

  p_out : process is
    file     ofile : text;
    variable ol    : line;
    variable lasts : natural := 0;
    variable idle  : natural := 0;
  begin
    file_open(ofile, DUMP & "_out.txt", write_mode);
    wait until rst = '0';
    loop
      wait until rising_edge(clk);
      if oValid = '1' and iReady = '1' then
        idle := 0;
        for i in 0 to OUT_WIDTH / 8 - 1 loop
          if oKeep(OUT_WIDTH / 8 - 1 - i) = '1' then
            write(ol, integer'image(to_integer(unsigned(oData(OUT_WIDTH - 1 - 8 * i downto OUT_WIDTH - 8 * (i + 1))))) & " ");
          end if;
        end loop;
        if oLast = '1' then
          write(ol, string'("L"));
          lasts := lasts + 1;
        end if;
        writeline(ofile, ol);
      else
        idle := idle + 1;
      end if;
      exit when (lasts = NIMG and idle > 200) or idle > 200000;
    end loop;
    file_close(ofile);
    report "RESULT: oLast " & integer'image(lasts) & " of " & integer'image(NIMG) & " images";
    done <= true;
    wait;
  end process p_out;
end architecture sim;
