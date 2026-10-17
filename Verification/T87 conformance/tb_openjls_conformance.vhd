-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

-- tb_openjls_t87_conformance: openjls_top against the ITU T16E0.JLS from TEST16.PGM
--
-- Encodes the image twice back to back, the second time under output
-- backpressure; both must match. Only the first is saved to Output/.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use std.textio.all;
  use std.env.all;
  use work.openjls_pkg.all;

entity tb_openjls_t87_conformance is
  generic (
    REPO_ROOT : string := "./"
  );
end entity tb_openjls_t87_conformance;

architecture bench of tb_openjls_t87_conformance is

  constant DUMP_VCD              : boolean := false;
  constant MAX_DIFF_LOG          : natural := 16;

  constant PGM_PATH              : string := REPO_ROOT & "Verification/T87 conformance/Reference Images/TEST16.PGM";
  constant JLS_PATH              : string := REPO_ROOT & "Verification/T87 conformance/Reference Images/T16E0.JLS";
  constant OUT_PATH              : string := REPO_ROOT & "Verification/T87 conformance/Output/T16E0_OPENJLS.JLS";

  constant CLK_PERIOD            : time     := 10 ns;
  constant BITNESS               : natural  := 12;
  constant MAX_IMAGE_WIDTH       : positive := 4096;
  constant MAX_IMAGE_HEIGHT      : positive := 4096;
  constant OUT_WIDTH             : natural  := CO_OUT_WIDTH_STD;
  constant BYTES_PER_WORD        : natural  := OUT_WIDTH / 8;

  constant IMG_W                 : natural := 256;
  constant IMG_H                 : natural := 256;
  constant N_PIX                 : natural := IMG_W * IMG_H;

  type pixel_array_t is array (natural range <>) of natural;

  type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);

  constant COLLECT_CAP           : natural := 262144;

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

  -- Arms one backpressure episode in bp_ctrl
  signal sBpReq                  : std_logic;

  shared variable collected      : byte_array_t(0 to COLLECT_CAP - 1);
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

  iImageWidth  <= std_logic_vector(to_unsigned(IMG_W, iImageWidth'length));
  iImageHeight <= std_logic_vector(to_unsigned(IMG_H, iImageHeight'length));

  dut : entity work.openjls_top(rtl)
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
            if (collectedCount < collected'length) then
              collected(collectedCount) := oData(OUT_WIDTH - 1 - i * 8 downto OUT_WIDTH - (i + 1) * 8);
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

  -- Per sBpReq: hold iReady low until oReady drops, BP_EXTRA cycles more, release
  bp_ctrl : process is

    constant BP_TIMEOUT : natural := 100000;
    constant BP_EXTRA   : natural := 8;

  begin

    iReady <= '1';
    wait until rising_edge(iClk);

    if (sBpReq = '1') then
      iReady <= '0';

      for i in 0 to BP_TIMEOUT loop

        wait until rising_edge(iClk);
        exit when oReady = '0';

      end loop;

      check(oReady = '0', "Backpressure did not propagate upstream (oReady stayed high)");

      for i in 0 to BP_EXTRA - 1 loop

        wait until rising_edge(iClk);

      end loop;

      iReady <= '1';
      wait until sBpReq = '0';
    end if;

  end process bp_ctrl;

  stim : process is

    variable pixels : pixel_array_t(0 to N_PIX - 1);
    variable refbuf : byte_array_t(0 to COLLECT_CAP - 1);
    variable refLen : natural;

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
      path : string
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

      assert w = IMG_W and h = IMG_H
        report "PGM dimensions mismatch"
        severity failure;
      assert mx = (2 ** BITNESS) - 1
        report "PGM maxval does not match BITNESS"
        severity failure;

      -- 2 bytes per pixel, big-endian
      for i in 0 to N_PIX - 1 loop

        read_byte(f, bHi, eof);
        assert not eof
          report "PGM: unexpected EOF in body"
          severity failure;
        read_byte(f, bLo, eof);
        assert not eof
          report "PGM: unexpected EOF in body"
          severity failure;
        pix       := to_integer(unsigned(bHi)) * 256 + to_integer(unsigned(bLo));
        assert pix <= mx
          report "PGM: pixel exceeds maxval"
          severity failure;
        pixels(i) := pix;

      end loop;

      file_close(f);

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

      loop

        read_byte(f, b, eof);
        exit when eof;
        assert n < refbuf'length
          report "Reference JLS exceeds buffer"
          severity failure;
        refbuf(n) := b;
        n         := n + 1;

      end loop;

      refLen := n;
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

        write_byte(f, collected(i));

      end loop;

      file_close(f);
      report "Wrote " & integer'image(n) & " bytes to " & path;

    end procedure save_collected;

    procedure feed_image is
    begin

      for i in 0 to N_PIX - 1 loop

        iPixel <= std_logic_vector(to_unsigned(pixels(i), BITNESS));
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

        if (base + i < collectedCount) then
          if (collected(base + i) /= refbuf(i)) then
            if (logged < MAX_DIFF_LOG) then
              report tag & " byte " & integer'image(i) &
                     " mismatch: exp=" & hex2(refbuf(i)) &
                     " got=" & hex2(collected(base + i))
                severity error;
              logged := logged + 1;
            end if;
            errCount := errCount + 1;
          end if;
        end if;

      end loop;

    end procedure compare_slice;

  begin

    iRst   <= '1';
    iValid <= '0';
    iPixel <= (others => '0');
    sBpReq <= '0';

    report "DUT config: BITNESS=" & integer'image(BITNESS) &
           " OUT_WIDTH=" & integer'image(OUT_WIDTH) &
           " MAX_IMAGE=" & integer'image(MAX_IMAGE_WIDTH) & "x" & integer'image(MAX_IMAGE_HEIGHT);
    assert IMG_W <= MAX_IMAGE_WIDTH and IMG_H <= MAX_IMAGE_HEIGHT
      report "Test image exceeds MAX_IMAGE_WIDTH/HEIGHT"
      severity failure;

    report "Loading PGM: " & PGM_PATH;
    load_pgm(PGM_PATH);

    report "Loading reference JLS: " & JLS_PATH;
    load_jls(JLS_PATH);

    do_reset;

    report "Image 1: feeding " & integer'image(N_PIX) & " pixels (conformance)";
    feed_image;

    sBpReq <= '1';
    report "Image 2: back-to-back, with output backpressure";
    feed_image;
    sBpReq <= '0';

    wait_images(2);
    report "Encoder produced " & integer'image(collectedCount) & " bytes";
    save_collected(OUT_PATH, refLen);

    check(collectedCount = 2 * refLen,
          "Byte count mismatch: got " & integer'image(collectedCount) &
          " expected " & integer'image(2 * refLen));
    compare_slice(0,      "Image 1");
    compare_slice(refLen, "Image 2");

    if (errCount > 0) then
      report "tb_openjls_t87_conformance RESULT: FAIL (" &
             integer'image(errCount) & " errors)"
        severity failure;
    else
      report "tb_openjls_t87_conformance RESULT: PASS"
        severity note;
    end if;

    finish;

  end process stim;

end architecture bench;
