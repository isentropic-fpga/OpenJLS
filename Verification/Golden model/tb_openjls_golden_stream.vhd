-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

-- tb_openjls_golden_stream: same-size images back-to-back with no reset between
-- them, each byte-compared against its own CharLS .jls
--
-- build_run_stream.sh concatenates the pixels and the .jls files. RTL only: the
-- window counter reads byte_stuffer internals.

use work.openjls_pkg.all;

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.math_real.all;
  use std.textio.all;
  use std.env.all;

entity tb_openjls_golden_stream is
  generic (
    REPO_ROOT : string   := "";
    PIX_PATH  : string   := "";
    JLS_PATH  : string   := "";
    LEN_PATH  : string   := "";
    RES_PATH  : string   := "";
    BITNESS   : positive := 12;
    W         : positive := 256;
    H         : positive := 64;
    N_IMAGES  : positive := 200;
    READY_PCT : positive range 1 to 100 := 100;
    VALID_PCT : positive range 1 to 100 := 100;
    OUT_WIDTH : positive := CO_OUT_WIDTH_STD;
    SEED      : positive := 1
  );
end entity tb_openjls_golden_stream;

architecture bench of tb_openjls_golden_stream is

  constant BYTES      : natural  := OUT_WIDTH / 8;
  constant CLK_PERIOD : time     := 10 ns;
  -- A lost EOI hangs here; a whole flat image can pass with no output
  constant IDLE_LIMIT : natural  := (50 * W * H + 2000) * (100 / VALID_PCT) + 2000 * (100 / READY_PCT);
  constant MAX_REPORT : natural  := 8;

  type char_file_t is file of character;

  signal iClk   : std_logic := '0';
  signal iRst   : std_logic := '1';
  signal iValid : std_logic := '0';
  signal iPixel : std_logic_vector(BITNESS - 1 downto 0) := (others => '0');
  signal oReady : std_logic;
  signal oData  : std_logic_vector(OUT_WIDTH - 1 downto 0);
  signal oValid : std_logic;
  signal oKeep  : std_logic_vector(BYTES - 1 downto 0);
  signal oLast  : std_logic;
  signal iReady : std_logic := '0';

  signal sWindowHits : natural := 0;

begin

  iClk <= not iClk after CLK_PERIOD / 2;

  dut : entity work.openjls_top(rtl)
    generic map (
      BITNESS          => BITNESS,
      MAX_IMAGE_WIDTH  => 65535,
      MAX_IMAGE_HEIGHT => 65535,
      OUT_WIDTH        => OUT_WIDTH
    )
    port map (
      iClk         => iClk,
      iRst         => iRst,
      iValid       => iValid,
      iPixel       => iPixel,
      oReady       => oReady,
      iImageWidth  => std_logic_vector(to_unsigned(W, 16)),
      iImageHeight => std_logic_vector(to_unsigned(H, 16)),
      oData        => oData,
      oValid       => oValid,
      oKeep        => oKeep,
      oLast        => oLast,
      iReady       => iReady
    );

  stim : process is

    file     f : char_file_t;
    variable c : character;
    variable p : natural;
    variable s1 : positive := SEED + 202;
    variable s2 : positive := SEED + 303;
    variable r  : real;

  begin

    file_open(f, REPO_ROOT & PIX_PATH, read_mode);

    for i in 1 to 8 loop

      wait until rising_edge(iClk);

    end loop;

    iRst <= '0';
    wait until rising_edge(iClk);
    wait until oReady = '1' and rising_edge(iClk);

    for i in 1 to N_IMAGES * W * H loop

      read(f, c);
      p := character'pos(c);
      if (BITNESS > 8) then
        read(f, c);
        p := p * 256 + character'pos(c);
      end if;
      uniform(s1, s2, r);
      while (r * 100.0 >= real(VALID_PCT)) loop

        iValid <= '0';
        wait until rising_edge(iClk);
        uniform(s1, s2, r);

      end loop;
      iPixel <= std_logic_vector(to_unsigned(p, BITNESS));
      iValid <= '1';
      wait until oReady = '1' and rising_edge(iClk);

    end loop;

    iValid <= '0';
    file_close(f);
    wait;

  end process stim;

  ready_proc : process is

    variable s1 : positive := SEED;
    variable s2 : positive := SEED + 101;
    variable r  : real;

  begin

    uniform(s1, s2, r);
    if (r * 100.0 < real(READY_PCT)) then
      iReady <= '1';
    else
      iReady <= '0';
    end if;
    wait until rising_edge(iClk);

  end process ready_proc;

  -- Next image's word waiting in the skid while the last word's final 8 bits drain
  window_proc : process is

    alias skidValid is <<signal .tb_openjls_golden_stream.dut.u_byte_stuffer.sSkidValid : std_logic>>;
    alias bufLast   is <<signal .tb_openjls_golden_stream.dut.u_byte_stuffer.sStuffBufferLast : std_logic>>;
    alias bufBits   is <<signal .tb_openjls_golden_stream.dut.u_byte_stuffer.sStuffBufferBits : unsigned>>;
    alias bufReady  is <<signal .tb_openjls_golden_stream.dut.u_byte_stuffer.iReady : std_logic>>;

  begin

    wait until rising_edge(iClk);
    if (iRst = '0' and bufReady = '1' and skidValid = '1' and bufLast = '1' and bufBits = 8) then
      sWindowHits <= sWindowHits + 1;
    end if;

  end process window_proc;

  check_proc : process is

    file     jls       : char_file_t;
    file     lens      : text;
    file     res       : text;
    variable ln        : line;
    variable matched   : natural := 0;
    variable c         : character;
    variable remaining : integer := 0;
    variable image     : natural := 0;
    variable offset    : natural := 0;
    variable idle      : natural := 0;
    variable errors    : natural := 0;
    variable badImage  : boolean := false;
    variable badImages : natural := 0;
    variable b         : std_logic_vector(7 downto 0);

  begin

    file_open(jls, REPO_ROOT & JLS_PATH, read_mode);
    file_open(lens, REPO_ROOT & LEN_PATH, read_mode);
    file_open(res, REPO_ROOT & RES_PATH, write_mode);
    readline(lens, ln);
    read(ln, remaining);

    wait until iRst = '0';

    loop

      wait until rising_edge(iClk);

      if (oValid = '1' and iReady = '1') then
        idle := 0;

        for i in 0 to BYTES - 1 loop

          if (oKeep(BYTES - 1 - i) = '1') then
            b := oData(OUT_WIDTH - 1 - i * 8 downto OUT_WIDTH - (i + 1) * 8);
            if (remaining > 0) then
              read(jls, c);
              if (to_integer(unsigned(b)) /= character'pos(c)) then
                badImage := true;
                if (errors < MAX_REPORT) then
                  report "image " & integer'image(image) & " byte " & integer'image(offset) & " differs";
                end if;
                errors := errors + 1;
              else
                matched := matched + 1;
              end if;
              remaining := remaining - 1;
            else
              badImage := true;
              if (errors < MAX_REPORT) then
                report "image " & integer'image(image) & " longer than its reference";
              end if;
              errors := errors + 1;
            end if;
            offset := offset + 1;
          end if;

        end loop;

        if (oLast = '1') then
          if (remaining /= 0) then
            badImage := true;
            report "image " & integer'image(image) & " short by " & integer'image(remaining) & " bytes";
            errors := errors + 1;
            for i in 1 to remaining loop

              read(jls, c);

            end loop;
          end if;
          if (badImage) then
            badImages := badImages + 1;
          end if;
          write(ln, integer'image(image) & " " & integer'image(matched) & " " & boolean'image(not badImage));
          writeline(res, ln);
          matched := 0;
          badImage := false;
          image    := image + 1;
          offset   := 0;
          remaining := 0;
          if (image < N_IMAGES) then
            readline(lens, ln);
            read(ln, remaining);
          end if;
        end if;
      else
        idle := idle + 1;
      end if;

      exit when idle > IDLE_LIMIT or (image = N_IMAGES and idle > 1000);

    end loop;

    report "stream: images=" & integer'image(image) & "/" & integer'image(N_IMAGES) &
           " bad=" & integer'image(badImages) & " errors=" & integer'image(errors) &
           " window_hits=" & integer'image(sWindowHits);

    assert image = N_IMAGES and errors = 0
      report "tb_openjls_golden_stream RESULT: FAIL"
      severity failure;

    report "tb_openjls_golden_stream RESULT: PASS";
    finish;

  end process check_proc;

end architecture bench;
