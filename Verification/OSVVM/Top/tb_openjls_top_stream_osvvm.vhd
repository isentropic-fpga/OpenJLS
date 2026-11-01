-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_openjls_top_stream_osvvm: back-to-back images through openjls_top against CharLS
--
-- Each variant fails on the byte_stuffer image-merge bug. REFS holds the CharLS length and
-- CRC-32 of each image, so the pixel generator must not change.
--
-- Guidelines:
--   G2          N/A: owned by module TBs
--   G3          N/A: owned by module TBs
--   G4 other    N/A: Edge/Run/Coding owned by module TBs + golden suite
--   G5          N/A: no reset, resets belong to tb_openjls_top_osvvm

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.math_real.all;

library osvvm;
  context osvvm.OsvvmContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_openjls_top_stream_osvvm is
  generic (
    BITNESS   : positive := 16;
    W         : positive := 4;
    H         : positive := 4;
    SEED      : positive := 2;
    VALID_PCT : natural  := 100;
    READY_PCT : natural  := 100
  );
end entity tb_openjls_top_stream_osvvm;

architecture sim of tb_openjls_top_stream_osvvm is

  constant OUT_WIDTH : positive := 64;
  constant MAXV      : natural  := 2 ** BITNESS - 1;
  -- Output idle this long after the last expected oLast, or mid-stream: a lost EOI hangs here
  constant IDLE_LIMIT : natural := 20000;

  type ref_t is record
    bitness, w, h, seed, image, length : natural;
    crc                                : std_logic_vector(31 downto 0);
  end record ref_t;

  type refs_t is array (natural range <>) of ref_t;

  constant REFS : refs_t := (
    (8, 128, 16, 2, 0, 1214, x"34ED204F"),
    (8, 128, 16, 2, 1, 1241, x"62AA0955"),
    (8, 128, 16, 2, 2, 1246, x"673142A5"),
    (8, 128, 16, 2, 3, 1308, x"998DDAB7"),
    (8, 128, 16, 2, 4, 1283, x"740E708C"),
    (8, 128, 16, 2, 5, 1234, x"C21E9DB3"),
    (8, 128, 16, 2, 6, 1239, x"5E15AE50"),
    (8, 128, 16, 2, 7, 1244, x"8745673E"),
    (8, 128, 16, 2, 8, 1261, x"7B2F1F58"),
    (8, 128, 16, 2, 9, 1243, x"5F66474A"),
    (10, 16, 16, 1, 0, 242, x"A9B323B7"),
    (10, 16, 16, 1, 1, 296, x"91B3FB0A"),
    (10, 16, 16, 1, 2, 335, x"28BC1FC5"),
    (10, 16, 16, 1, 3, 298, x"20FE8C49"),
    (10, 16, 16, 1, 4, 240, x"302F7652"),
    (10, 16, 16, 1, 5, 254, x"B1D7F6F5"),
    (10, 16, 16, 1, 6, 312, x"4664B422"),
    (10, 16, 16, 1, 7, 312, x"A8EC0ABC"),
    (10, 16, 16, 1, 8, 304, x"26E6C913"),
    (10, 16, 16, 1, 9, 241, x"78F968DB"),
    (12, 256, 64, 4, 0, 12951, x"61BA5E70"),
    (12, 256, 64, 4, 1, 13158, x"4DA8080C"),
    (12, 256, 64, 4, 2, 13148, x"6F301543"),
    (16, 4, 4, 2, 0, 29, x"E4D25484"),
    (16, 4, 4, 2, 1, 64, x"D53CA489"),
    (16, 4, 4, 2, 2, 80, x"A924EFEE"),
    (16, 4, 4, 2, 3, 56, x"097361F3"),
    (16, 4, 4, 2, 4, 47, x"A95A3691"),
    (16, 4, 4, 2, 5, 35, x"D181511B"),
    (16, 4, 4, 2, 6, 64, x"D53CA489"),
    (16, 4, 4, 2, 7, 87, x"FBE0A509"),
    (16, 4, 4, 2, 8, 56, x"D961BB8D"),
    (16, 4, 4, 2, 9, 47, x"A95A3691"),
    (16, 4, 4, 2, 10, 35, x"C7967A4A"),
    (16, 4, 4, 2, 11, 64, x"D53CA489"),
    (16, 4, 4, 2, 12, 87, x"F4839C1C"),
    (16, 4, 4, 2, 13, 51, x"AD4981BF"),
    (16, 4, 4, 2, 14, 47, x"A95A3691"),
    (16, 4, 4, 2, 15, 35, x"613CABC6"),
    (16, 4, 4, 2, 16, 64, x"D53CA489"),
    (16, 4, 4, 2, 17, 89, x"CC202C4E"),
    (16, 4, 4, 2, 18, 56, x"F3060B03"),
    (16, 4, 4, 2, 19, 47, x"A95A3691"),
    (9, 64, 32, 3, 0, 1467, x"C8A00DA3"),
    (9, 64, 32, 3, 1, 1428, x"8CB68CB8"),
    (9, 64, 32, 3, 2, 1402, x"85E57DD4"),
    (9, 64, 32, 3, 3, 1368, x"CC281589"),
    (9, 64, 32, 3, 4, 1407, x"CD060EA5"),
    (9, 64, 32, 3, 5, 1403, x"68D2DD36"),
    (9, 64, 32, 3, 6, 1420, x"6095FC8B"),
    (9, 64, 32, 3, 7, 1457, x"9134CD2D"),
    (9, 64, 32, 3, 8, 1361, x"90991B38"),
    (9, 64, 32, 3, 9, 1387, x"1E6500B7"),
    (11, 16, 16, 4, 0, 268, x"7C02173B"),
    (11, 16, 16, 4, 1, 332, x"04C67336"),
    (11, 16, 16, 4, 2, 361, x"E6B4D473"),
    (11, 16, 16, 4, 3, 314, x"AB2DBB4C"),
    (11, 16, 16, 4, 4, 268, x"44617C46"),
    (11, 16, 16, 4, 5, 284, x"548EF81C"),
    (11, 16, 16, 4, 6, 343, x"5A59195E"),
    (11, 16, 16, 4, 7, 359, x"B9421607"),
    (11, 16, 16, 4, 8, 352, x"A5C6AC98"),
    (11, 16, 16, 4, 9, 275, x"2D71E1AD"),
    (13, 8, 8, 3, 0, 59, x"85022744"),
    (13, 8, 8, 3, 1, 104, x"2410F8D4"),
    (13, 8, 8, 3, 2, 129, x"FBBBCA0A"),
    (13, 8, 8, 3, 3, 110, x"4269EEC4"),
    (13, 8, 8, 3, 4, 134, x"5C12C8BD"),
    (13, 8, 8, 3, 5, 66, x"3C029DBF"),
    (13, 8, 8, 3, 6, 104, x"2410F8D4"),
    (13, 8, 8, 3, 7, 138, x"F6183DAE"),
    (13, 8, 8, 3, 8, 110, x"E3400348"),
    (13, 8, 8, 3, 9, 130, x"9ED40050"),
    (14, 32, 8, 3, 0, 341, x"68F33A96"),
    (14, 32, 8, 3, 1, 391, x"683204F8"),
    (14, 32, 8, 3, 2, 389, x"1462D9A7"),
    (14, 32, 8, 3, 3, 371, x"E9C187D2"),
    (14, 32, 8, 3, 4, 355, x"73C45276"),
    (14, 32, 8, 3, 5, 352, x"1D30D0DE"),
    (14, 32, 8, 3, 6, 415, x"8F9B8B6F"),
    (14, 32, 8, 3, 7, 381, x"85E12E71"),
    (14, 32, 8, 3, 8, 369, x"90A2978D"),
    (14, 32, 8, 3, 9, 396, x"B6E2CAFF"),
    (15, 4, 1, 2, 0, 28, x"371A0DDA"),
    (15, 4, 1, 2, 1, 38, x"23C37802"),
    (15, 4, 1, 2, 2, 40, x"2B3911A0"),
    (15, 4, 1, 2, 3, 36, x"28613D2B"),
    (15, 4, 1, 2, 4, 32, x"63898F2A"),
    (15, 4, 1, 2, 5, 32, x"80EB0F07"),
    (15, 4, 1, 2, 6, 38, x"23C37802"),
    (15, 4, 1, 2, 7, 45, x"BC2F26FB"),
    (15, 4, 1, 2, 8, 39, x"964E58CE"),
    (15, 4, 1, 2, 9, 32, x"63898F2A")
  );

  function image_count return natural is
    variable n : natural := 0;
  begin

    for i in REFS'range loop

      if (REFS(i).bitness = BITNESS and REFS(i).w = W and REFS(i).h = H and REFS(i).seed = SEED) then
        n := n + 1;
      end if;

    end loop;

    return n;

  end function image_count;

  function ref_of (image : natural) return ref_t is
  begin

    for i in REFS'range loop

      if (REFS(i).bitness = BITNESS and REFS(i).w = W and REFS(i).h = H and REFS(i).seed = SEED and
          REFS(i).image = image) then
        return REFS(i);
      end if;

    end loop;

    return (0, 0, 0, 0, 0, 0, (others => '0'));

  end function ref_of;

  function crc32_byte (
    crc  : std_logic_vector(31 downto 0);
    data : std_logic_vector(7 downto 0)
  ) return std_logic_vector is

    variable c : std_logic_vector(31 downto 0) := crc;

  begin

    for i in 0 to 7 loop

      if ((c(0) xor data(i)) = '1') then
        c := ('0' & c(31 downto 1)) xor x"EDB88320";
      else
        c := '0' & c(31 downto 1);
      end if;

    end loop;

    return c;

  end function crc32_byte;

  constant NIMG : natural := image_count;

  signal clk            : std_logic := '1';
  signal rst            : std_logic := '1';
  signal iValid, iReady : std_logic := '0';
  signal iPixel         : std_logic_vector(BITNESS - 1 downto 0) := (others => '0');
  signal dimW, dimH     : std_logic_vector(15 downto 0);
  signal oReady, oValid : std_logic;
  signal oLast          : std_logic;
  signal oData          : std_logic_vector(OUT_WIDTH - 1 downto 0);
  signal oKeep          : std_logic_vector(OUT_WIDTH / 8 - 1 downto 0);

  shared variable covMerge : CoverageIDType;

begin

  dimW <= std_logic_vector(to_unsigned(W, 16));
  dimH <= std_logic_vector(to_unsigned(H, 16));
  clk  <= not clk after CLK_PERIOD_DEFAULT / 2;

  dut : entity work.openjls_top
    generic map (
      BITNESS          => BITNESS,
      MAX_IMAGE_WIDTH  => 4096,
      MAX_IMAGE_HEIGHT => 4096,
      OUT_WIDTH        => OUT_WIDTH
    )
    port map (
      iClk         => clk,
      iRst         => rst,
      iValid       => iValid,
      iPixel       => iPixel,
      oReady       => oReady,
      iImageWidth  => dimW,
      iImageHeight => dimH,
      oData        => oData,
      oValid       => oValid,
      oKeep        => oKeep,
      oLast        => oLast,
      iReady       => iReady
    );

  -- Region mix per 8x4 tile: flat (run mode), ramp, full-range noise, small noise, 0/MAX extremes
  stim_proc : process is

    variable s1, s2 : positive := SEED;
    variable s3, s4 : positive := SEED + 7;
    variable r      : real;
    variable px     : integer;
    variable lastv  : integer := MAXV / 2;

  begin

    for i in 1 to 4 loop

      wait until rising_edge(clk);

    end loop;

    rst <= '0';
    wait until rising_edge(clk);

    for k in 0 to NIMG - 1 loop
      for y in 0 to H - 1 loop
        for x in 0 to W - 1 loop

          uniform(s1, s2, r);

          case ((x / 8) + (y / 4) * 3 + k) mod 5 is

            when 0 =>
              px := (k * 37) mod (MAXV + 1);

            when 1 =>
              px := ((x + y) * (MAXV / (W + H))) mod (MAXV + 1);

            when 2 =>
              px := integer(floor(r * real(MAXV + 1)));

            when 3 =>
              px := lastv + integer(floor(r * 9.0)) - 4;

            when others =>
              px := MAXV * (x mod 2);

          end case;

          px     := maximum(0, minimum(MAXV, px));
          lastv  := px;
          iPixel <= std_logic_vector(to_unsigned(px, BITNESS));

          loop

            uniform(s3, s4, r);
            if (r * 100.0 < real(VALID_PCT)) then
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
    wait;

  end process stim_proc;

  ready_proc : process is

    variable s1, s2 : positive := SEED + 101;
    variable r      : real;

  begin

    wait until rising_edge(clk);
    uniform(s1, s2, r);
    if (r * 100.0 < real(READY_PCT)) then
      iReady <= '1';
    else
      iReady <= '0';
    end if;

  end process ready_proc;

  -- The refill-across-images window of the image-merge bug, independent of the skid hold
  merge_window_proc : process is

    alias skidValid is <<signal .tb_openjls_top_stream_osvvm.dut.u_byte_stuffer.sSkidValid : std_logic>>;
    alias bufLast   is <<signal .tb_openjls_top_stream_osvvm.dut.u_byte_stuffer.sStuffBufferLast : std_logic>>;
    alias bufBits   is <<signal .tb_openjls_top_stream_osvvm.dut.u_byte_stuffer.sStuffBufferBits : unsigned>>;
    -- The framer's ready, not the top's: it can differ from the TB's iReady
    alias bufReady  is <<signal .tb_openjls_top_stream_osvvm.dut.u_byte_stuffer.iReady : std_logic>>;

  begin

    wait until rising_edge(clk);
    if (rst = '0' and bufReady = '1' and skidValid = '1' and bufLast = '1' and bufBits = 8) then
      ICover(covMerge, 1);
    end if;

  end process merge_window_proc;

  check_proc : process is

    variable req    : AlertLogIDType;
    variable crc    : std_logic_vector(31 downto 0) := (others => '1');
    variable length : natural := 0;
    variable image  : natural := 0;
    variable idle   : natural := 0;
    variable expect : ref_t;

  begin

    SetAlertLogName("tb_openjls_top_stream_osvvm");
    SetLogEnable(PASSED, FALSE);
    -- Floor under the smallest variant: 3 images, length and CRC each
    req      := GetReqID("OJLS.ImageStream", 6);
    covMerge := NewID("G4.Stream nextImageWaiting");
    AddBins(covMerge, "8 residue bits, next image in skid", GenBin(1));
    AffirmIf(GetAlertLogID("Config"), NIMG > 0, "generics select a REFS case");

    wait until rst = '0';

    loop

      wait until rising_edge(clk);

      if (oValid = '1' and iReady = '1') then
        idle := 0;

        for i in 0 to OUT_WIDTH / 8 - 1 loop

          if (oKeep(OUT_WIDTH / 8 - 1 - i) = '1') then
            crc    := crc32_byte(crc, oData(OUT_WIDTH - 1 - 8 * i downto OUT_WIDTH - 8 * (i + 1)));
            length := length + 1;
          end if;

        end loop;

        if (oLast = '1') then
          expect := ref_of(image);
          AffirmIfEqual(req, length, expect.length, "image " & to_string(image) & " length");
          AffirmIfEqual(req, not crc, expect.crc, "image " & to_string(image) & " CRC-32");
          image  := image + 1;
          crc    := (others => '1');
          length := 0;
        end if;
      else
        idle := idle + 1;
      end if;

      exit when idle > IDLE_LIMIT;

    end loop;

    AffirmIfEqual(GetAlertLogID("Completion"), image, NIMG, "one oLast per image");
    AffirmIfEqual(GetAlertLogID("Completion"), length, 0, "no bytes after the last oLast");
    affirm_covered(covMerge, "next-image-waiting coverage closed");
    end_of_test("tb_openjls_top_stream_osvvm");
    wait;

  end process check_proc;

end architecture sim;
