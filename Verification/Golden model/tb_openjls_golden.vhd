-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

----------------------------------------------------------------------------------
  -- Engineer:    Vitor Mendes Camilo
  --
  -- Testbench: tb_openjls_golden
  --
  -- Golden-model cross-check. Encodes a single-component PGM with OpenJLS and
  -- byte-for-byte compares the result against a reference .jls produced by the
  -- CharLS encoder (built from source — see ThirdParty/fetch_third_party.sh).
  -- Unlike the T.87 conformance suite (which compares against the ITU-supplied
  -- vectors), this lets us check arbitrary images — notably the 8-bit planes of
  -- TEST8, which exercise the BITNESS=8 datapath that TEST16 never touches.
  --
  -- One image per run, fully parametrized via generics; build_run.sh loops over
  -- the image set, passing PGM_PATH/JLS_PATH/OUT_PATH/BITNESS each time.
  -- Image dimensions and sample width are read from the PGM header at runtime.
  --
  -- Behavioral (NVC) or post-synthesis netlist sim via POST_SYNTH_FRIENDLY.
  ----------------------------------------------------------------------------------
  use work.openjls_pkg.all;

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use std.textio.all;
  use std.env.all;

entity tb_openjls_golden is
  generic (
    -- Repo root, with trailing '/'. The launcher injects it (build_run.sh passes
    -- -gREPO_ROOT); empty default => paths resolve relative to CWD.
    REPO_ROOT           : string  := "";
    -- Input PGM, CharLS-minted golden .jls, and the OpenJLS output artifact.
    -- Relative to REPO_ROOT; build_run.sh injects one image per run.
    PGM_PATH            : string  := "Verification/T87 conformance/Reference Images/TEST8R.PGM";
    JLS_PATH            : string  := "Verification/Golden model/Output/Golden/TEST8R_charls.jls";
    OUT_PATH            : string  := "Verification/Golden model/Output/OpenJLS/TEST8R_OPENJLS.jls";
    -- Pixel bit depth. Must match the PGM maxval (asserted below) and the DUT
    -- pixel-port width. 8 for the TEST8 planes, 12 for TEST16.
    BITNESS             : natural := 8;
    OUT_WIDTH           : natural := CO_OUT_WIDTH_STD;
    FULL_RATE_STUFFER    : natural range 0 to 1 := 0;
    -- true: instantiate the top bare (post-synthesis netlist). false: behavioral
    -- sim with the explicit generic map below (behavioral flow).
    POST_SYNTH_FRIENDLY : boolean := false
  );
end entity tb_openjls_golden;

architecture bench of tb_openjls_golden is

  -------------------------------------------------------------------------------------------------------------
  -- TB level controls
  -------------------------------------------------------------------------------------------------------------
  constant DUMP_VCD              : boolean := false;  -- waveform dump gated; large for 256x256
  constant MAX_DIFF_LOG          : natural := 16;     -- cap on logged byte mismatches before failure

  constant FULL_PGM_PATH         : string := REPO_ROOT & PGM_PATH;
  constant FULL_JLS_PATH         : string := REPO_ROOT & JLS_PATH;
  constant FULL_OUT_PATH         : string := REPO_ROOT & OUT_PATH;

  -- Test configuration
  constant CLK_PERIOD            : time     := 10 ns;
  -- DUT architectural maximum (openjls_top caps both at 65535, the T.87
  -- header field limit). The line buffer is the only memory that scales with
  -- width and is ~one row, so sizing to the max is cheap; full-image
  -- pixel/byte buffers are heap-allocated to the actual image (see below).
  -- This lets the suite run the largest images in the set (and ~100 MB-class
  -- images) without an artificial width/height cap.
  constant MAX_IMAGE_WIDTH       : positive := 65535;
  constant MAX_IMAGE_HEIGHT      : positive := 65535;
  constant BYTES_PER_WORD        : natural  := OUT_WIDTH / 8;

  -- Buffers are heap-allocated at runtime to fit the actual image, so there is
  -- no fixed pixel/byte ceiling: the suite scales to large (e.g. satellite)
  -- images, bounded only by the DUT's MAX_IMAGE_WIDTH/HEIGHT (asserted in
  -- load_pgm). Pointers are sized once the PGM header / golden length is known.
  type pixel_array_t is array (natural range <>) of natural;
  type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);
  type pixel_ptr_t is access pixel_array_t;
  type byte_ptr_t is access byte_array_t;

  -- Output headroom over the expected 2x reference length, so an encoder that
  -- overproduces is captured (and flagged) instead of silently truncated.
  constant COLLECT_MARGIN        : natural := 4096;

  -- DUT ports
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

  -- Image dimensions, read from the PGM header by stim and held stable so the
  -- input register latches them during reset.
  signal sImgW                   : natural := 1;
  signal sImgH                   : natural := 1;

  -- Internal-stall probe. A cycle with iValid='1' and oReady='0' is a pixel held
  -- back by the DUT; the output is never backpressured here (iReady tied high), so
  -- any such cycle is a purely internal stall (e.g. byte_stuffer >4 B/cycle overrun).
  signal sStallCnt               : natural := 0;

  -- Collection
  shared variable collected      : byte_ptr_t;  -- allocated by stim before feeding
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

  -------------------------------------------------------------------------------------------------------------
  -- Binary-byte file I/O (VHDL-2008 file of character)
  -------------------------------------------------------------------------------------------------------------

  type char_file_t is file of character;

  -- Read one byte; sets eof when no more data.

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

  -- Read ASCII unsigned decimal integer from PGM header. Skips leading whitespace
  -- and comment lines starting with '#'. Stops on first non-digit (which is
  -- consumed and discarded — the PGM spec says exactly one whitespace separates
  -- the maxval from the binary body, so callers using this for w/h/maxval read
  -- their delimiter implicitly).

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
      -- else: skip whitespace
      else
        if (c >= '0' and c <= '9') then
          acc := acc * 10 + character'pos(c) - character'pos('0');
        else
          -- delimiter consumed; done
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

  -- Dimensions read from the PGM header (set by stim before reset is released).
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
        OUT_WIDTH        => OUT_WIDTH,
        FULL_RATE_STUFFER => FULL_RATE_STUFFER
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

  -- Output collection: extract bytes per word using oKeep (MSB-first).
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

  -- This golden cross-check never backpressures the output: tie iReady high.
  iReady <= '1';

  -- Internal-stall probe: count cycles where the DUT holds a pixel back
  -- (iValid='1', oReady='0'). With iReady high this can only be an internal
  -- stall. Reported at end of run (warning if non-zero); see sStallCnt.
  mon_stall : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iValid = '1' and oReady = '0') then
        sStallCnt <= sStallCnt + 1;
      end if;
    end if;

  end process mon_stall;

  -- Stimulus
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

    -- Load a binary PGM (P5). Returns width/height/pixel-count; reads 1 byte per
    -- sample when maxval < 256, else 2 bytes big-endian. Fills `pixels`.
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

      -- Magic "P5"
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

      -- Body: 1 byte/sample if maxval < 256, else 2 bytes big-endian.
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

      -- Pass 1: count bytes so refbuf can be sized exactly. Pass 2: read them.
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

    -- Compare refLen collected bytes starting at `base` against the reference.
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

    -- Initial values for signals (no defaults — set explicitly here).
    -- iReady is tied high concurrently (output never backpressured).
    iRst   <= '1';
    iValid <= '0';
    iPixel <= (others => '0');

    -- Config guard. The pixel port width is fixed in a post-synth netlist; if it
    -- disagrees with BITNESS the netlist was built with different generics, so
    -- fail loudly here instead of producing a confusing byte mismatch later.
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

    -- Size the output buffer to the expected reference length (+margin).
    collected := new byte_array_t(0 to refLen + COLLECT_MARGIN - 1);

    do_reset;

    -- =========================================================================
    -- Feed the image once and byte-compare the encoder output against the golden
    -- reference. The output is never backpressured (iReady high), so any pixel
    -- held back (counted by mon_stall) is a purely internal stall.
    -- =========================================================================
    report "Feeding " & integer'image(nPix) & " pixels";
    feed_image;

    wait_images(1);
    report "Encoder produced " & integer'image(collectedCount) & " bytes";
    save_collected(FULL_OUT_PATH, refLen);

    check(collectedCount = refLen,
          "Byte count mismatch: got " & integer'image(collectedCount) &
          " expected " & integer'image(refLen));
    compare_slice(0, "Image");

    report "Internal stall cycles: " & integer'image(sStallCnt);
    assert FULL_RATE_STUFFER = 0 or sStallCnt = 0
      report "full-rate core stalled with continuously ready output" severity failure;
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
