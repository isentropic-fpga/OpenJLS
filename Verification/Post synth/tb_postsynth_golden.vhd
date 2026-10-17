-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

-- tb_postsynth_golden: the funcsim netlist against CharLS-minted .jls files
--
-- Loops a manifest of images, resetting with the new dimensions between them,
-- so the ~30 s netlist load is paid once. Driven by build_run_golden.sh.

use work.openjls_pkg.all;

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use std.textio.all;
  use std.env.all;

entity tb_postsynth_golden is
  generic (
    -- With trailing '/'; the paths below are relative to it
    REPO_ROOT    : string  := "";
    -- One image stem per line
    MANIFEST     : string  := "Verification/Post synth/Output/manifest.txt";
    IMAGES_DIR   : string  := "Verification/Golden model/Images/";
    GOLDEN_DIR   : string  := "Verification/Golden model/Output/Golden/";
    OUT_DIR      : string  := "Verification/Golden model/Output/OpenJLS/";
    -- Must match the netlist's synthesis generics
    BITNESS          : natural := 8;
    MAX_IMAGE_WIDTH  : positive := 7216;
    MAX_IMAGE_HEIGHT : positive := 5412;
    OUT_WIDTH        : natural  := 64
  );
end entity tb_postsynth_golden;

architecture bench of tb_postsynth_golden is

  constant MAX_DIFF_LOG   : natural := 8;   -- per image
  constant CLK_PERIOD     : time    := 10 ns;
  constant BYTES_PER_WORD : natural := OUT_WIDTH / 8;
  constant COLLECT_MARGIN : natural := 4096;

  type pixel_array_t is array (natural range <>) of natural;
  type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);
  type pixel_ptr_t is access pixel_array_t;
  type byte_ptr_t is access byte_array_t;

  signal iClk         : std_logic;
  signal iRst         : std_logic;
  signal iValid       : std_logic;
  signal iPixel       : std_logic_vector(BITNESS - 1 downto 0);
  signal oReady       : std_logic;
  signal iImageWidth  : std_logic_vector(15 downto 0);
  signal iImageHeight : std_logic_vector(15 downto 0);
  signal oData        : std_logic_vector(OUT_WIDTH - 1 downto 0);
  signal oValid       : std_logic;
  signal oKeep        : std_logic_vector(OUT_WIDTH / 8 - 1 downto 0);
  signal oLast        : std_logic;
  signal iReady       : std_logic;

  signal sImgW        : natural := 1;
  signal sImgH        : natural := 1;
  signal sStallCnt    : natural := 0;

  shared variable collected      : byte_ptr_t;
  shared variable collectedCount : natural;
  shared variable lastCount      : natural;
  shared variable errCount       : natural;   -- cumulative

  procedure check (
    cond : boolean;
    msg  : string
  ) is
  begin

    if (not cond) then
      report msg
        severity error;
      errCount := errCount + 1;
    end if;

  end procedure check;

  function hex2 (
    v : std_logic_vector(7 downto 0)
  ) return string is

    constant HEX : string(1 to 16) := "0123456789ABCDEF";
    variable r   : string(1 to 2);

  begin

    r(1) := HEX(to_integer(unsigned(v(7 downto 4))) + 1);
    r(2) := HEX(to_integer(unsigned(v(3 downto 0))) + 1);
    return r;

  end function hex2;

  type char_file_t is file of character;

  procedure read_byte (
    file f : char_file_t;
    b      : out std_logic_vector(7 downto 0);
    eof    : out boolean
  ) is

    variable c : character;

  begin

    if endfile(f) then
      eof := true;
      b   := (others => '0');
    else
      read(f, c);
      eof := false;
      b   := std_logic_vector(to_unsigned(character'pos(c), 8));
    end if;

  end procedure read_byte;

  procedure write_byte (
    file f : char_file_t;
    b      : std_logic_vector(7 downto 0)
  ) is

    variable c : character;

  begin

    c := character'val(to_integer(unsigned(b)));
    write(f, c);

  end procedure write_byte;

  -- Skips whitespace and '#' comments; consumes the one delimiter after the number
  procedure read_pgm_int (
    file f : char_file_t;
    v      : out natural
  ) is

    variable c         : character;
    variable acc       : natural;
    variable started   : boolean;
    variable inComment : boolean;

  begin

    loop

      assert not endfile(f)
        report "PGM: unexpected EOF in header"
        severity failure;
      read(f, c);

      if (inComment) then
        if (c = LF or c = CR) then
          inComment := false;
        end if;
      elsif (not started) then
        if (c = '#') then
          inComment := true;
        elsif (c >= '0' and c <= '9') then
          acc     := character'pos(c) - character'pos('0');
          started := true;
        end if;
      else
        if (c >= '0' and c <= '9') then
          acc := acc * 10 + character'pos(c) - character'pos('0');
        else
          v := acc;
          return;
        end if;
      end if;

    end loop;

  end procedure read_pgm_int;

  -- Trailing CR/LF/space, so CRLF manifests work
  function rtrim (
    s : string
  ) return string is

    variable hi : integer := s'high;

  begin

    while hi >= s'low and (s(hi) = CR or s(hi) = LF or s(hi) = ' ' or s(hi) = HT) loop

      hi := hi - 1;

    end loop;

    return s(s'low to hi);

  end function rtrim;

begin

  clk_proc : process is
  begin

    iClk <= '0';
    wait for CLK_PERIOD / 2;
    iClk <= '1';
    wait for CLK_PERIOD / 2;

  end process clk_proc;

  iImageWidth  <= std_logic_vector(to_unsigned(sImgW, iImageWidth'length));
  iImageHeight <= std_logic_vector(to_unsigned(sImgH, iImageHeight'length));

  -- write_vhdl -mode funcsim names the architecture STRUCTURE
  dut : entity work.openjls_top(STRUCTURE)
    port map (
      iClk         => iClk,
      iRst         => iRst,
      iValid       => iValid,
      iPixel       => iPixel,
      oReady       => oReady,
      iImageWidth  => iImageWidth,
      iImageHeight => iImageHeight,
      oData        => oData,
      oValid       => oValid,
      oKeep        => oKeep,
      oLast        => oLast,
      iReady       => iReady
    );

  -- First byte in the MSB lane
  collect : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        collectedCount := 0;
        lastCount      := 0;
      elsif (oValid = '1' and iReady = '1') then

        for i in 0 to BYTES_PER_WORD - 1 loop

          if (oKeep(BYTES_PER_WORD - 1 - i) = '1') then
            if (collectedCount < collected.all'length) then
              collected.all(collectedCount) := oData(OUT_WIDTH - 1 - i * 8 downto OUT_WIDTH - (i + 1) * 8);
            end if;
            collectedCount := collectedCount + 1;
          end if;

        end loop;

        if (oLast = '1') then
          lastCount := lastCount + 1;
        end if;
      end if;
    end if;

  end process collect;

  iReady <= '1';

  mon_stall : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iValid = '1' and oReady = '0') then
        sStallCnt <= sStallCnt + 1;
      end if;
    end if;

  end process mon_stall;

  stim : process is

    variable pixels : pixel_ptr_t;
    variable refbuf : byte_ptr_t;
    variable refLen : natural;
    variable nPix   : natural;

    procedure do_reset is
    begin

      iRst   <= '1';
      iValid <= '0';

      for i in 0 to 4 loop

        wait until rising_edge(iClk);

      end loop;

      iRst <= '0';
      wait until rising_edge(iClk);

      while oReady /= '1' loop

        wait until rising_edge(iClk);

      end loop;

    end procedure do_reset;

    procedure load_pgm (
      path : string;
      wo   : out natural;
      ho   : out natural;
      no   : out natural
    ) is

      file     f      : char_file_t;
      variable bHi    : std_logic_vector(7 downto 0);
      variable bLo    : std_logic_vector(7 downto 0);
      variable eof    : boolean;
      variable magic0 : std_logic_vector(7 downto 0);
      variable magic1 : std_logic_vector(7 downto 0);
      variable w      : natural;
      variable h      : natural;
      variable mx     : natural;
      variable np     : natural;
      variable pix    : natural;

    begin

      file_open(f, path, read_mode);

      read_byte(f, magic0, eof);
      read_byte(f, magic1, eof);
      assert magic0 = x"50" and magic1 = x"35"
        report "PGM: magic mismatch (expected P5)"
        severity failure;

      read_pgm_int(f, w);
      read_pgm_int(f, h);
      read_pgm_int(f, mx);

      np := w * h;
      assert w <= MAX_IMAGE_WIDTH and h <= MAX_IMAGE_HEIGHT
        report "Test image exceeds MAX_IMAGE_WIDTH/HEIGHT"
        severity failure;
      pixels := new pixel_array_t(0 to np - 1);
      assert mx = (2 ** BITNESS) - 1
        report "PGM maxval does not match BITNESS"
        severity failure;

      for i in 0 to np - 1 loop

        read_byte(f, bHi, eof);
        assert not eof
          report "PGM: unexpected EOF in body"
          severity failure;

        if (mx < 256) then
          pix := to_integer(unsigned(bHi));
        else
          read_byte(f, bLo, eof);
          assert not eof
            report "PGM: unexpected EOF in body"
            severity failure;
          pix := to_integer(unsigned(bHi)) * 256 + to_integer(unsigned(bLo));
        end if;

        assert pix <= mx
          report "PGM: pixel exceeds maxval"
          severity failure;
        pixels.all(i) := pix;

      end loop;

      file_close(f);
      wo := w;
      ho := h;
      no := np;

    end procedure load_pgm;

    procedure load_jls (
      path : string
    ) is

      file     f   : char_file_t;
      variable b   : std_logic_vector(7 downto 0);
      variable eof : boolean;
      variable n   : natural;

    begin

      file_open(f, path, read_mode);
      n := 0;

      loop

        read_byte(f, b, eof);
        exit when eof;
        n := n + 1;

      end loop;

      file_close(f);

      refLen := n;
      refbuf := new byte_array_t(0 to n - 1);

      file_open(f, path, read_mode);

      for i in 0 to n - 1 loop

        read_byte(f, b, eof);
        refbuf.all(i) := b;

      end loop;

      file_close(f);

    end procedure load_jls;

    procedure save_collected (
      path : string;
      n    : natural
    ) is

      file f : char_file_t;

    begin

      file_open(f, path, write_mode);

      for i in 0 to n - 1 loop

        write_byte(f, collected.all(i));

      end loop;

      file_close(f);

    end procedure save_collected;

    procedure feed_image is
    begin

      for i in 0 to nPix - 1 loop

        iPixel <= std_logic_vector(to_unsigned(pixels.all(i), BITNESS));
        iValid <= '1';
        wait until oReady = '1' and rising_edge(iClk);

      end loop;

      iValid <= '0';

    end procedure feed_image;

    procedure wait_images (
      n : natural
    ) is
    begin

      for i in 0 to 2000000 loop

        exit when lastCount >= n;
        wait until rising_edge(iClk);

      end loop;

    end procedure wait_images;

    procedure compare_slice (
      base : natural;
      tag  : string
    ) is

      variable logged : natural;

    begin

      for i in 0 to refLen - 1 loop

        if (base + i < collectedCount and base + i < collected.all'length) then
          if (collected.all(base + i) /= refbuf.all(i)) then
            if (logged < MAX_DIFF_LOG) then
              report tag & " byte " & integer'image(i) &
                     " mismatch: exp=" & hex2(refbuf.all(i)) &
                     " got=" & hex2(collected.all(base + i))
                severity error;
              logged := logged + 1;
            end if;
            errCount := errCount + 1;
          end if;
        end if;

      end loop;

    end procedure compare_slice;

    -- ok on a byte-exact match; buffers are reallocated per image
    procedure run_one (
      stem : string;
      ok   : out boolean
    ) is

      variable imgW    : natural;
      variable imgH    : natural;
      variable errBase : natural;

    begin

      if (pixels /= null) then
        deallocate(pixels);
      end if;
      if (refbuf /= null) then
        deallocate(refbuf);
      end if;
      if (collected /= null) then
        deallocate(collected);
      end if;

      errBase := errCount;

      load_pgm(REPO_ROOT & IMAGES_DIR & stem & ".pgm", imgW, imgH, nPix);
      sImgW <= imgW;
      sImgH <= imgH;
      load_jls(REPO_ROOT & GOLDEN_DIR & stem & "_charls.jls");
      collected := new byte_array_t(0 to refLen + COLLECT_MARGIN - 1);

      do_reset;
      feed_image;
      wait_images(1);

      check(collectedCount = refLen,
            stem & ": byte count mismatch: got " & integer'image(collectedCount) &
            " expected " & integer'image(refLen));
      compare_slice(0, stem);

      if (errCount /= errBase) then
        save_collected(REPO_ROOT & OUT_DIR & stem & "_PS.jls",
                       collectedCount);
      end if;

      ok := errCount = errBase;

    end procedure run_one;

    file     mf    : text;
    variable ln    : line;
    variable ok    : boolean;
    variable mPass : natural := 0;
    variable mFail : natural := 0;
    variable nImg  : natural := 0;

  begin

    iRst   <= '1';
    iValid <= '0';
    iPixel <= (others => '0');

    assert iPixel'length = BITNESS
      report "iPixel width (" & integer'image(iPixel'length) &
             ") /= BITNESS (" & integer'image(BITNESS) &
             ") - netlist generics do not match the testbench"
      severity failure;
    report "Post-synth netlist: BITNESS=" & integer'image(BITNESS) &
           " MAX=" & integer'image(MAX_IMAGE_WIDTH) & "x" & integer'image(MAX_IMAGE_HEIGHT) &
           " OUT_WIDTH=" & integer'image(OUT_WIDTH);

    file_open(mf, REPO_ROOT & MANIFEST, read_mode);

    while not endfile(mf) loop

      readline(mf, ln);

      if (ln'length > 0) then

        if (rtrim(ln.all)'length > 0) then
          nImg := nImg + 1;

          run_one(rtrim(ln.all), ok);

          if (ok) then
            mPass := mPass + 1;
            report "PASS " & rtrim(ln.all) & " (" & integer'image(collectedCount) & " B)";
          else
            mFail := mFail + 1;
            report "FAIL " & rtrim(ln.all)
              severity error;
          end if;
        end if;
      end if;

    end loop;

    file_close(mf);

    if (sStallCnt > 0) then
      report "Pipeline stalled " & integer'image(sStallCnt) &
             " cycle(s) across the manifest with no downstream backpressure " &
             "(internal stall, e.g. byte_stuffer >4 B/cycle overrun)"
        severity warning;
    end if;

    report "MANIFEST RESULT: " & integer'image(mPass) & "/" & integer'image(nImg) &
           " PASS, " & integer'image(mFail) & " FAIL";
    assert mFail = 0
      report "Post-synth golden cross-check FAILED on " & integer'image(mFail) & " image(s)"
      severity failure;

    finish;

  end process stim;

end architecture bench;
