-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- line_buffer: one-row FIFO giving the causal neighbours of x
--
--   c b d
--   a x

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
    oEol             : out   std_logic;
    oEoi             : out   std_logic
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
  signal sBorderC            : unsigned(BITNESS - 1 downto 0); -- c at col 0: b latched at col 0 of the previous row
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

    if (sFifoState = preload) then
      sFifoOutReady <= '1';
    elsif (sFifoState = nominal) then
      sFifoOutReady <= iValid;
    else
      sFifoOutReady <= '0';
    end if;

    -- T.87 A.2.1 borders
    if (sRowCounter = 0) then
      oB <= (others => '0');
      oC <= (others => '0');
      oD <= (others => '0');
    else
      oB <= sB;
      if (sIsFirstCol) then
        oC <= sBorderC;
      else
        oC <= sC;
      end if;

      if (sIsLastCol) then
        oD <= sB;
      else
        oD <= sD;
      end if;
    end if;

    if (sIsFirstCol) then
      oA <= sB;
    else
      oA <= sA;
    end if;

  end process comb_proc;

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
        case sFifoState is

          when preload =>

            -- Preload b and d from the FIFO
            if (sIsFifoOutHandshake) then
              sPreloadCounter <= sPreloadCounter + 1;
              if (sPreloadCounter = 1) then
                sFifoState <= wait_end_first_row;

                if (sIsEol) then                           -- width = 4 (T.87 H.3 test image)
                  sFifoState <= nominal;
                end if;
              end if;
            end if;

          when wait_end_first_row =>

            if (sIsEol) then
              sFifoState <= nominal;
            end if;

          when nominal =>

            if (sIsEoi) then
              sFifoState      <= preload;
              sPreloadCounter <= (others => '0');
            end if;

        end case;

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

        if (sIsFifoOutHandshake) then
          sC <= sB;
          sB <= sD;
          sD <= unsigned(sFifoOutData);
        elsif (sFifoState = nominal and iValid = '1') then
          -- FIFO empty on the last row: b and c still step
          sC <= sB;
          sB <= sD;
        end if;

        if (iValid = '1') then
          sA <= iPixel;

          if (sIsFirstCol) then
            sBorderC <= sB;
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

  end process clocked_proc;

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

  postponed assert is_x(iImageWidth) or is_x(sColCounter) or sColCounter < iImageWidth
    report "line_buffer: column counter past width" severity error;
  postponed assert is_x(iImageHeight) or is_x(sRowCounter) or sRowCounter < iImageHeight
    report "line_buffer: row counter past height" severity error;

end architecture behavioral;
