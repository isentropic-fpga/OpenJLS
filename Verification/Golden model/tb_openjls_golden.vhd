-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

-- tb_openjls_golden: openjls_top against a CharLS-minted .jls, one PGM per run
--
-- build_run.sh sets the paths and BITNESS per image. The output is never
-- backpressured, so any input stall is internal.

use work.openjls_pkg.all;

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use std.textio.all;
  use std.env.all;

entity tb_openjls_golden is
  generic (
    -- With trailing '/'; the paths below are relative to it
    REPO_ROOT           : string  := "";
    PGM_PATH            : string  := "Verification/T87 conformance/Reference Images/TEST8R.PGM";
    JLS_PATH            : string  := "Verification/Golden model/Output/Golden/TEST8R_charls.jls";
    OUT_PATH            : string  := "Verification/Golden model/Output/OpenJLS/TEST8R_OPENJLS.jls";
    -- Must match the PGM maxval
    BITNESS             : natural := 8;
    -- Instantiate the post-synthesis netlist bare, without a generic map
    POST_SYNTH_FRIENDLY : boolean := false
  );
end entity tb_openjls_golden;

architecture bench of tb_openjls_golden is

  constant DUMP_VCD              : boolean := false;
  constant MAX_DIFF_LOG          : natural := 16;

  constant FULL_PGM_PATH         : string := REPO_ROOT & PGM_PATH;
  constant FULL_JLS_PATH         : string := REPO_ROOT & JLS_PATH;
  constant FULL_OUT_PATH         : string := REPO_ROOT & OUT_PATH;

  constant CLK_PERIOD            : time     := 10 ns;
  -- Only the line buffer scales with MAX, one row, so run at the T.87 cap
  constant MAX_IMAGE_WIDTH       : positive := 65535;
  constant MAX_IMAGE_HEIGHT      : positive := 65535;
  constant OUT_WIDTH             : natural  := CO_OUT_WIDTH_STD;
  constant BYTES_PER_WORD        : natural  := OUT_WIDTH / 8;

  -- Heap-allocated to the image and golden sizes
  type pixel_array_t is array (natural range <>) of natural;
  type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);
  type pixel_ptr_t is access pixel_array_t;
  type byte_ptr_t is access byte_array_t;

  -- Room past the golden length so overproduction is caught, not truncated
  constant COLLECT_MARGIN        : natural := 4096;

  signal iClk                    : std_logic;
  signal iRst                    : std_logic;
  signal iValid                  : std_logic;
  signal iPixel                  : std_logic_vector(BITNESS - 1 downto 0);
  signal oReady                  : std_logic;
  signal iImageWidth             : std_logic_vector(15 downto 0);
  signal iImageHeight            : std_logic_vector(15 downto 0);
  signal oData                   : std_logic_vector(OUT_WIDTH - 1 downto 0);
  signal oValid                  : std_logic;
  signal oKeep                   : std_logic_vector(OUT_WIDTH / 8 - 1 downto 0);
  signal oLast                   : std_logic;
  signal iReady                  : std_logic;

  -- From the PGM header, set before reset so the DUT latches them
  signal sImgW                   : natural := 1;
  signal sImgH                   : natural := 1;

  signal sStallCnt               : natural := 0;

  shared variable collected      : byte_ptr_t;
  shared variable collectedCount : natural;
  shared variable lastCount      : natural;

  shared variable errCount       : natural;

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

  -- Binary file I/O ---

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

  dut : if POST_SYNTH_FRIENDLY generate

    dut_post_syn : entity work.openjls_top(rtl)

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

  else
    generate

    dut_behav : entity work.openjls_top(rtl)

      generic map (
        BITNESS          => BITNESS,
        MAX_IMAGE_WIDTH  => MAX_IMAGE_WIDTH,
        MAX_IMAGE_HEIGHT => MAX_IMAGE_HEIGHT,
        OUT_WIDTH        => OUT_WIDTH
      )
      port map (
        iClk             => iClk,
        iRst             => iRst,
        iValid           => iValid,
        iPixel           => iPixel,
        oReady           => oReady,
        iImageWidth      => iImageWidth,
        iImageHeight     => iImageHeight,
        oData            => oData,
        oValid           => oValid,
        oKeep            => oKeep,
        oLast            => oLast,
        iReady           => iReady
      );

  end generate dut;

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

    -- Binary PGM (P5) into pixels
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
      report "PGM header: w=" & integer'image(w) &
             " h=" & integer'image(h) &
             " maxval=" & integer'image(mx);

      np := w * h;
      assert w <= MAX_IMAGE_WIDTH and h <= MAX_IMAGE_HEIGHT
        report "Test image exceeds MAX_IMAGE_WIDTH/HEIGHT"
        severity failure;
      pixels := new pixel_array_t(0 to np - 1);
      assert mx = (2 ** BITNESS) - 1
        report "PGM maxval does not match BITNESS"
        severity failure;

      -- 2 bytes big-endian per sample above maxval 255
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

      -- Count first to size refbuf, then read
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
      report "Reference JLS bytes=" & integer'image(refLen);

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
      report "Wrote " & integer'image(n) & " bytes to " & path;

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

    variable imgW : natural;
    variable imgH : natural;

  begin

    iRst   <= '1';
    iValid <= '0';
    iPixel <= (others => '0');

    -- A netlist built with other generics fails here, not as a byte mismatch
    report "DUT config: BITNESS=" & integer'image(BITNESS) &
           " OUT_WIDTH=" & integer'image(OUT_WIDTH) &
           " MAX_IMAGE=" & integer'image(MAX_IMAGE_WIDTH) & "x" & integer'image(MAX_IMAGE_HEIGHT);
    assert iPixel'length = BITNESS
      report "iPixel width (" & integer'image(iPixel'length) &
             ") /= BITNESS (" & integer'image(BITNESS) &
             ") - DUT generics do not match the testbench"
      severity failure;

    report "Loading PGM: " & FULL_PGM_PATH;
    load_pgm(FULL_PGM_PATH, imgW, imgH, nPix);
    sImgW <= imgW;
    sImgH <= imgH;

    report "Loading golden JLS: " & FULL_JLS_PATH;
    load_jls(FULL_JLS_PATH);

    collected := new byte_array_t(0 to refLen + COLLECT_MARGIN - 1);

    do_reset;

    report "Feeding " & integer'image(nPix) & " pixels";
    feed_image;

    wait_images(1);
    report "Encoder produced " & integer'image(collectedCount) & " bytes";
    save_collected(FULL_OUT_PATH, refLen);

    check(collectedCount = refLen,
          "Byte count mismatch: got " & integer'image(collectedCount) &
          " expected " & integer'image(refLen));
    compare_slice(0, "Image");

    if (sStallCnt > 0) then
      report "Pipeline stalled " & integer'image(sStallCnt) &
             " cycle(s) under this image with no downstream backpressure " &
             "(internal stall, e.g. byte_stuffer >4 B/cycle overrun)"
        severity warning;
    end if;

    if (errCount > 0) then
      report "tb_openjls_golden RESULT: FAIL (" &
             integer'image(errCount) & " errors)"
        severity failure;
    else
      report "tb_openjls_golden RESULT: PASS"
        severity note;
    end if;

    finish;

  end process stim;

end architecture bench;
