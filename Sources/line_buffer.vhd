-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

----------------------------------------------------------------------------------
-- Engineer:    Vitor Mendes Camilo
--
-- Module Name: line_buffer - Behavioral
--
-- Notes:
--              Stores one row of pixels on FIFO and provides the four T.87 causal
--              context neighbors for each pixel, where x is the current pixel:
--
--                  c  b  d
--                  a  x
--
--              a = left neighbor        (same row, col-1)
--              b = upper neighbor       (previous row, col)
--              c = upper-left neighbor  (previous row, col-1)
--              d = upper-right neighbor (previous row, col+1)
--
--              Border conditions (T.87 A.2.1):
--                First row      : b = c = d = 0
--                Col 0 (rows>0) : a = Rb = first pixel of previous row
--                                 c = Ra from start of previous row
--                                   = first pixel of the row before that
--                Col W-1        : d = b (replicate last pixel of previous row)
--
-- Assumptions:
--              iImageWidth >= 3, iImageHeight >= 1.
--              iImageWidth and iImageHeight are stable for the entire image.
--
----------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library work;
  use work.olo_base_pkg_math.log2ceil;

entity line_buffer is
  generic (
    MAX_IMAGE_WIDTH  : positive range 3 to integer'high;
    MAX_IMAGE_HEIGHT : positive;
    BITNESS          : natural := CO_BITNESS_STD
  );
  port (
    iClk             : in    std_logic;
    iRst             : in    std_logic;
    iImageWidth      : in    unsigned(log2ceil(MAX_IMAGE_WIDTH + 1) - 1 downto 0);
    iImageHeight     : in    unsigned(log2ceil(MAX_IMAGE_HEIGHT + 1) - 1 downto 0);
    iValid           : in    std_logic;
    iPixel           : in    unsigned(BITNESS - 1 downto 0);
    oA               : out   unsigned(BITNESS - 1 downto 0);
    oB               : out   unsigned(BITNESS - 1 downto 0);
    oC               : out   unsigned(BITNESS - 1 downto 0);
    oD               : out   unsigned(BITNESS - 1 downto 0);
    oValid           : out   std_logic;
    oEol             : out   std_logic; -- end of line
    oEoi             : out   std_logic  -- end of image
  );
end entity line_buffer;

architecture behavioral of line_buffer is

  constant COL_WIDTH         : natural := log2ceil(MAX_IMAGE_WIDTH + 1);
  constant ROW_WIDTH         : natural := log2ceil(MAX_IMAGE_HEIGHT + 1);

  type fifo_state_t is (preload, wait_end_first_row, nominal);

  signal sFifoState          : fifo_state_t;

  signal sFifoOutReady       : std_logic;
  signal sFifoOutValid       : std_logic;
  signal sFifoOutData        : std_logic_vector(BITNESS - 1 downto 0);
  signal sFifoFull           : std_logic;
  signal sFifoEmpty          : std_logic;
  signal sD                  : unsigned(BITNESS - 1 downto 0); -- d: upper-right
  signal sB                  : unsigned(BITNESS - 1 downto 0); -- b: upper
  signal sC                  : unsigned(BITNESS - 1 downto 0); -- c: upper-left
  signal sA                  : unsigned(BITNESS - 1 downto 0); -- a: left
  signal sBorderC            : unsigned(BITNESS - 1 downto 0); -- c at col 0: sB captured at col 0 of previous row
  signal sColCounter         : unsigned(COL_WIDTH - 1 downto 0);
  signal sRowCounter         : unsigned(ROW_WIDTH - 1 downto 0);
  signal sIsLastCol          : boolean;
  signal sIsLastRow          : boolean;
  signal sIsEoi              : boolean;
  signal sIsEol              : boolean;
  signal sIsFifoOutHandshake : boolean;
  signal sIsFirstCol         : boolean;
  signal sPreloadCounter     : unsigned(1 downto 0);
  signal sFifoInValid        : std_logic;

begin

  -- Combinatorial process ----------------------------------------------------------------
  comb_proc : process (iValid, iImageWidth, iImageHeight, sFifoState,
                       sFifoOutReady, sFifoOutValid, sColCounter, sRowCounter,
                       sIsLastCol, sIsLastRow, sIsFirstCol, sIsEol, sIsEoi,
                       sA, sB, sC, sD, sBorderC) is
  begin

    oValid              <= iValid;
    sIsLastCol          <= sColCounter = iImageWidth - 1;
    sIsLastRow          <= sRowCounter = iImageHeight - 1;
    sIsFirstCol         <= sColCounter = 0;
    sIsEol              <= sIsLastCol and iValid = '1';
    sIsEoi              <= sIsLastCol and sIsLastRow and iValid = '1';
    oEoi                <= bool2bit(sIsEoi);
    oEol                <= bool2bit(sIsEol);
    sIsFifoOutHandshake <= (sFifoOutReady and sFifoOutValid) = '1';

    -- Read FIFO logic ------------------------------------------------------
    if (sFifoState = preload) then
      sFifoOutReady <= '1';
    elsif (sFifoState = nominal) then
      sFifoOutReady <= iValid;
    else
      sFifoOutReady <= '0';
    end if;

    -- Corner case handling for border conditions (T.87 A.2.1) --------------
    if (sRowCounter = 0) then                                          -- First row: b = c = d = 0
      oB <= (others => '0');
      oC <= (others => '0');
      oD <= (others => '0');
    else
      oB <= sB;
      if (sIsFirstCol) then
        oC <= sBorderC;                                                -- Col 0: c = Ra from start of previous row
      else
        oC <= sC;
      end if;

      if (sIsLastCol) then
        oD <= sB;                                                      -- Last col: replicate last pixel of previous row (= b)
      else
        oD <= sD;
      end if;
    end if;

    if (sIsFirstCol) then
      oA <= sB;                                                        -- First col: replicate first pixel of previous row (= b)
    else
      oA <= sA;
    end if;

  end process comb_proc; ----------------------------------------------------------------------------

  -- Clocked Process ----------------------------------------------------------------------
  clocked_proc : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sPreloadCounter <= (others => '0');
        sFifoState      <= preload;

        sColCounter <= (others => '0');
        sRowCounter <= (others => '0');

        sB       <= (others => '0');
        sC       <= (others => '0');
        sD       <= (others => '0');
        sA       <= (others => '0');
        sBorderC <= (others => '0');
      else
        -- FIFO control FSM ----------------------------
        -- sFifoOutReady is controlled combinationally using these states
        case sFifoState is

          when preload =>

            -- When FIFO receives the first pixels it loads them into registers, preparing for nominal operation
            -- Only loads b and d, since c is out of image

            if (sIsFifoOutHandshake) then
              sPreloadCounter <= sPreloadCounter + 1;
              if (sPreloadCounter = 1) then
                sFifoState <= wait_end_first_row;

                if (sIsEol) then                           -- needs this check to work with images with width=4 (Annex H.3 test image)
                  sFifoState <= nominal;
                end if;
              end if;
            end if;

          when wait_end_first_row =>

            -- Nominal operation starts only on second row, since first row has no valid context
            if (sIsEol) then
              sFifoState <= nominal;
            end if;

          when nominal =>

            -- On valid operation, every new pixel steps the context window by reading a new neighbor pixels and shifting the current ones

            if (sIsEoi) then
              sFifoState      <= preload;
              sPreloadCounter <= (others => '0');
            end if;

        end case;

        -- Counters -------------------------------------
        if (iValid = '1') then
          if (sIsLastCol) then
            sColCounter <= (others => '0');
            if (sIsLastRow) then
              sRowCounter <= (others => '0');
            else
              sRowCounter <= sRowCounter + 1;
            end if;
          else
            sColCounter <= sColCounter + 1;
          end if;
        end if;

        -- Output control -------------------------------
        -- Shift context window
        if (sIsFifoOutHandshake) then
          sC <= sB;
          sB <= sD;
          sD <= unsigned(sFifoOutData);
        elsif (sFifoState = nominal and iValid = '1') then
          -- FIFO empty (last row, end of row): sD has no new data but sB/sC still step
          sC <= sB;
          sB <= sD;
        end if;

        if (iValid = '1') then
          -- Store last pixel
          sA <= iPixel;

          if (sIsFirstCol) then
            sBorderC <= sB;                                -- Capture sB at col 0 for use as c border at col 0 of next ro
          end if;
        end if;

        if (sIsEoi) then
          sB       <= (others => '0');
          sC       <= (others => '0');
          sD       <= (others => '0');
          sA       <= (others => '0');
          sBorderC <= (others => '0');
        end if;
      end if;
    end if;

  end process clocked_proc; -----------------------------------------------------------------------------

  -- Instance FIFO -------------------------------------------------------------------------
  sFifoInValid <= iValid and not bool2bit(sIsLastRow);

  fifo_inst : entity work.olo_base_fifo_sync(rtl)
    generic map (
      WIDTH_G       => BITNESS,
      DEPTH_G       => MAX_IMAGE_WIDTH,
      RAMBEHAVIOR_G => "RBW"
    )
    port map (
      Clk           => iClk,
      Rst           => iRst,
      In_Data       => std_logic_vector(iPixel),
      In_Valid      => sFifoInValid,
      Out_Ready     => sFifoOutReady,
      Out_Data      => sFifoOutData,
      Out_Valid     => sFifoOutValid,
      Full          => sFifoFull,
      Empty         => sFifoEmpty
    );

  -- Col in [0, width - 1], row in [0, height - 1]
  postponed assert is_x(iImageWidth) or is_x(sColCounter) or sColCounter < iImageWidth
    report "line_buffer: column counter past width" severity error;
  postponed assert is_x(iImageHeight) or is_x(sRowCounter) or sRowCounter < iImageHeight
    report "line_buffer: row counter past height" severity error;

end architecture behavioral;
