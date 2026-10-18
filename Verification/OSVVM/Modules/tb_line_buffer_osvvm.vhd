-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_line_buffer_osvvm: line_buffer against the T.87 A.2.1 border rules
--
-- Guidelines:
--   G2.MinMax   N/A: pixels pass through unchanged
--   G2.Clamp    N/A: no accumulator
--   G3.Stim     N/A: pixels pass through unchanged (random full range)
--   G4 other    N/A: Run/Coding/Stream not in scope

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library work;
  use work.olo_base_pkg_math.log2ceil;

library osvvm;
  context osvvm.OsvvmContext;

library tb_support;
  use tb_support.tb_support_pkg.all;

entity tb_line_buffer_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_line_buffer_osvvm;

architecture sim of tb_line_buffer_osvvm is

  constant MAX_W      : positive := 16;
  constant MAX_H      : positive := 16;
  constant PX_MAX     : integer  := (2 ** BITNESS) - 1;
  constant W_W        : natural  := log2ceil(MAX_W + 1);
  constant H_W        : natural  := log2ceil(MAX_H + 1);
  constant CLK_PERIOD : time     := CLK_PERIOD_DEFAULT;

  signal clk     : std_logic := '0';
  signal rst     : std_logic;
  signal iWidth  : unsigned(W_W - 1 downto 0);
  signal iHeight : unsigned(H_W - 1 downto 0);
  signal iValid  : std_logic;
  signal iPixel  : unsigned(BITNESS - 1 downto 0);
  signal oA      : unsigned(BITNESS - 1 downto 0);
  signal oB      : unsigned(BITNESS - 1 downto 0);
  signal oC      : unsigned(BITNESS - 1 downto 0);
  signal oD      : unsigned(BITNESS - 1 downto 0);
  signal oValid  : std_logic;
  signal oEol    : std_logic;
  signal oEoi    : std_logic;

  type image_t is array (0 to MAX_H - 1, 0 to MAX_W - 1) of integer;

begin

  clk_proc : process is
  begin

    clk <= '1';
    wait for CLK_PERIOD / 2;
    clk <= '0';
    wait for CLK_PERIOD / 2;

  end process clk_proc;

  dut : entity work.line_buffer(behavioral)
    generic map (
      MAX_IMAGE_WIDTH  => MAX_W,
      MAX_IMAGE_HEIGHT => MAX_H,
      BITNESS          => BITNESS
    )
    port map (
      iClk         => clk,
      iRst         => rst,
      iImageWidth  => iWidth,
      iImageHeight => iHeight,
      iValid       => iValid,
      iPixel       => iPixel,
      oA           => oA,
      oB           => oB,
      oC           => oC,
      oD           => oD,
      oValid       => oValid,
      oEol         => oEol,
      oEoi         => oEoi
    );

  stim : process is

    variable rv  : RandomPType;
    variable cov : CoverageIDType;
    variable cfg : CoverageIDType;
    variable rs  : CoverageIDType;
    variable img : image_t;
    variable req : AlertLogIDType;

    -- 0 outside the image
    impure function px (
      r : integer;
      c : integer
    ) return integer is
    begin

      if (r < 0 or c < 0) then
        return 0;
      else
        return img(r, c);
      end if;

    end function px;

    procedure ref_nbr (
      r  : integer;
      c  : integer;
      w  : integer;
      ea : out integer;
      eb : out integer;
      ec : out integer;
      ed : out integer
    ) is
    begin

      if (c = 0) then
        ea := px(r - 1, 0);            -- = b at col 0
      else
        ea := px(r, c - 1);
      end if;

      if (r = 0) then
        eb := 0;
        ec := 0;
        ed := 0;
      else
        eb := px(r - 1, c);
        if (c = 0) then
          ec := px(r - 2, 0);          -- Ra at the start of the previous row
        else
          ec := px(r - 1, c - 1);
        end if;
        if (c = w - 1) then
          ed := px(r - 1, c);          -- replicate the previous row's last pixel
        else
          ed := px(r - 1, c + 1);
        end if;
      end if;

    end procedure ref_nbr;

    -- gaps adds iValid stalls
    procedure run_image (
      w    : integer;
      h    : integer;
      gaps : boolean
    ) is

      variable ea  : integer;
      variable eb  : integer;
      variable ec  : integer;
      variable ed  : integer;
      variable rt  : integer;
      variable ct  : integer;

    begin

      for r in 0 to h - 1 loop

        for c in 0 to w - 1 loop

          img(r, c) := rv.RandInt(0, PX_MAX);

        end loop;

      end loop;

      iWidth  <= to_unsigned(w, W_W);
      iHeight <= to_unsigned(h, H_W);

      for r in 0 to h - 1 loop

        for c in 0 to w - 1 loop

          -- Forced gaps at row start/end; random gaps alone may miss them
          if gaps and (c = 0 or c = w - 1) then
            iValid <= '0';
            iPixel <= to_unsigned(PX_MAX, BITNESS);
            for pause in 1 to 3 loop
              wait for 1 ns;
              AffirmIf(GetAlertLogID("Protocol"), oValid = '0' and oEol = '0' and oEoi = '0', "boundary gap suppresses flags");
              wait until rising_edge(clk);
            end loop;
          end if;
          if (gaps) then
            while (rv.DistValInt(((1, 1), (0, 4))) = 1) loop

              iValid <= '0';
              iPixel <= to_unsigned(rv.RandInt(0, PX_MAX), BITNESS);
              wait for 1 ns;
              AffirmIf(GetAlertLogID("Protocol"), oValid = '0' and oEol = '0' and oEoi = '0', "invalid gap suppresses flags");
              wait until rising_edge(clk);

            end loop;
          end if;

          iValid <= '1';
          iPixel <= to_unsigned(img(r, c), BITNESS);
          wait for 1 ns;

          ref_nbr(r, c, w, ea, eb, ec, ed);
          AffirmIfEqual(req, checked_integer(oA), ea, "a r=" & integer'image(r) & " c=" & integer'image(c));
          AffirmIfEqual(req, checked_integer(oB), eb, "b r=" & integer'image(r) & " c=" & integer'image(c));
          AffirmIfEqual(req, checked_integer(oC), ec, "c r=" & integer'image(r) & " c=" & integer'image(c));
          AffirmIfEqual(req, checked_integer(oD), ed, "d r=" & integer'image(r) & " c=" & integer'image(c));
          AffirmIf(GetAlertLogID("Protocol"), oValid = '1', "oValid on presented pixel");
          AffirmIf(GetAlertLogID("Protocol"), oEol = bool2bit(c = w - 1), "oEol at last col");
          AffirmIf(GetAlertLogID("Protocol"), oEoi = bool2bit(c = w - 1 and r = h - 1), "oEoi at last pixel");

          if (r = 0) then
            rt := 0;
          else
            rt := 1;
          end if;
          if (c = 0) then
            ct := 0;
          elsif (c = w - 1) then
            ct := 2;
          else
            ct := 1;
          end if;
          ICover(cov, (rt, ct));

          wait until rising_edge(clk);

        end loop;

      end loop;

      iValid <= '0';
      ICover(cfg, (w, h));

    end procedure run_image;

    -- n pixels, then iRst; phase 0 idle, 1 first row, 2 middle row, 3 last row
    procedure reset_after (
      w : integer;
      h : integer;
      n : integer
    ) is
    begin

      iWidth  <= to_unsigned(w, W_W);
      iHeight <= to_unsigned(h, H_W);
      for k in 1 to n loop
        iPixel <= to_unsigned(rv.RandInt(0, PX_MAX), BITNESS);
        iValid <= '1';
        wait until rising_edge(clk);
      end loop;
      iValid <= '0';
      if (n = 0) then
        ICover(rs, 0);
      elsif (n <= w) then
        ICover(rs, 1);
      elsif (n > (h - 1) * w) then
        ICover(rs, 3);
      else
        ICover(rs, 2);
      end if;
      apply_reset(clk, rst, 4, '1');
      wait for 1 ns;
      AffirmIf(GetAlertLogID("ResetRecovery"), oValid = '0', "mid-image reset: oValid low while idle");
      run_image(5, 4, false);

    end procedure reset_after;

  begin

    iWidth  <= to_unsigned(MAX_W, W_W);
    iHeight <= to_unsigned(MAX_H, H_W);
    iValid  <= '0';
    iPixel  <= (others => '0');

    SetAlertLogName("tb_line_buffer_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    -- 2477 pixels x 4 neighbours
    req := GetReqID("OJLS.LineBuffer", 9908);
    cov := NewID("G4.Edge rowPos x colPos");
    SetFieldName(cov, "rowPos", "colPos");
    for axis0 in 0 to 1 loop
      for axis1 in 0 to 2 loop
        AddCross(cov, "rowPos=" & to_string(axis0) & " / " & "colPos=" & to_string(axis1), GenBin(axis0), GenBin(axis1));
      end loop;
    end loop;

    cfg := NewID("G4.Config width x height");
    for wi in 0 to 1 loop
      for hi in 0 to 1 loop
        AddCross(cfg, "width=" & to_string(4 + wi * (MAX_W - 4)) & " / height=" & to_string(1 + hi * (MAX_H - 1)),
                 GenBin(4 + wi * (MAX_W - 4)), GenBin(1 + hi * (MAX_H - 1)));
      end loop;
    end loop;
    rs := NewID("G5.States resetPhase");
    AddBins(rs, "idle", GenBin(0));
    AddBins(rs, "first row", GenBin(1));
    AddBins(rs, "middle row", GenBin(2));
    AddBins(rs, "last row", GenBin(3));

    apply_reset(clk, rst, 4, '1');

    -- Back to back; EOI auto-resets the window
    run_image(4, 3, false);
    run_image(5, 4, false);
    run_image(8, 1, false);
    run_image(6, 5, true);
    run_image(16, 6, false);
    run_image(7, 3, true);
    for width in 4 to MAX_W loop
      run_image(width, 1, true);
      run_image(width, MAX_H, true);
    end loop;

    -- Mid-image reset ---
    reset_after(6, 6, 9);       -- ~1.5 rows, past preload
    reset_after(6, 6, 0);
    reset_after(6, 6, 3);
    reset_after(6, 6, 33);

    WriteBin(cov);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "row x col position coverage closed");
    affirm_covered(cfg, "width x height extremes coverage closed");
    affirm_covered(rs, "reset phase coverage closed");

    end_of_test("tb_line_buffer_osvvm");
    wait;

  end process stim;

  watchdog : process is
  begin

    wait for 50 ms;
    Alert(GetAlertLogID("Watchdog"), "tb_line_buffer_osvvm: watchdog timeout", FAILURE);
    std.env.stop;

  end process watchdog;

end architecture sim;
