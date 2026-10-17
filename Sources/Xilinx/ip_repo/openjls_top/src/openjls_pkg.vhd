-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- openjls_pkg: shared constants, types and helpers

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.olo_base_pkg_math.log2ceil;
  use work.olo_base_pkg_math.log2;

package openjls_pkg is

  -- Internal ----------------------------------------------------------------------------
  constant CO_SIGN_POS         : std_logic := '0';
  constant CO_SIGN_NEG         : std_logic := '1';
  constant CO_MIN_IMAGE_WIDTH  : natural   := 4;
  constant CO_MIN_IMAGE_HEIGHT : natural   := 1;

  -- Aliases, not local functions: a local body is not elaborated yet for the
  -- constants below (LRM 14.4.2). Also avoids `min` clashing with the TIME unit.
  alias math_max is work.olo_base_pkg_math.max [integer, integer return integer];
  alias math_min is work.olo_base_pkg_math.min [integer, integer return integer];

  -- unsigned overloads (open-logic has none)
  function math_min (
    a,
    b      : in unsigned
  ) return unsigned;

  function math_max (
    a,
    b      : in unsigned
  ) return unsigned;

  function math_ceil_div (
    a,
    b : in natural
  ) return natural;

  function std_to_int (
    s       : in std_logic
  ) return integer;

  function bool2bit (
    b         : in boolean
  ) return std_logic;

  -- Reference configuration ------------------------------------------------------------
  constant CO_BITNESS_STD   : natural := 12;
  constant CO_NEAR_STD      : natural := 0;
  constant CO_OUT_WIDTH_STD : natural := 64;

  -- Defined values from T.87 ----------------------------------------------------------
  constant CO_BITNESS_MAX_WIDTH          : natural := 16;
  constant CO_MAX_VAL_STD                : natural := 2 ** CO_BITNESS_STD - 1;
  constant CO_ERROR_VALUE_WIDTH_STD      : natural := CO_BITNESS_STD + 1;
  constant CO_MAPPED_ERROR_VAL_WIDTH_STD : natural := CO_BITNESS_STD + 2;
  constant CO_CQ_WIDTH                   : natural := 8;
  constant CO_RANGE_STD : natural := CO_MAX_VAL_STD + 1;
  constant CO_QBPP_STD  : natural := log2ceil(CO_RANGE_STD);
  constant CO_BPP_STD   : natural := math_max(2, log2ceil(CO_MAX_VAL_STD + 1));
  constant CO_LIMIT_STD : natural := 2 * (CO_BPP_STD + math_max(8, CO_BPP_STD));

  type j_table_array is array (0 to 31) of natural;

  constant CO_J_TABLE : j_table_array :=
  (
    0,
    0,
    0,
    0,
    1,
    1,
    1,
    1,
    2,
    2,
    2,
    2,
    3,
    3,
    3,
    3,
    4,
    4,
    5,
    5,
    6,
    6,
    7,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15
  );

  constant CO_J_TABLE_SIZE : natural := CO_J_TABLE'length;

  -- Defined ranges from T.87 ----------------------------------------------------------
  constant CO_MAX_VAL_MAX_WIDTH : natural := 16;
  constant CO_RESET_MAX_WIDTH   : natural := 16;
  constant CO_MAX_CQ            : integer := 127;
  constant CO_MIN_CQ            : integer := - 128;
  constant CO_NEAR_MAX_STD      : natural := math_min(255, CO_MAX_VAL_STD / 2);

  constant CO_RESET_STD : natural := 64;                                        -- T.87 default RESET

  -- Not fixed by T.87; same derivation as openjls_top
  constant CO_AQ_WIDTH_STD        : natural := CO_BPP_STD + log2ceil(CO_RESET_STD);            -- A < RESET * 2^(bpp-1), +1 for the sum
  constant CO_BQ_WIDTH_STD        : natural := CO_BPP_STD + 1;                                 -- holds B + Errval
  constant CO_K_WIDTH_STD         : natural := log2ceil(CO_AQ_WIDTH_STD + 1);                  -- k in [0, A_WIDTH]
  constant CO_NQ_WIDTH_STD        : natural := log2ceil(CO_RESET_STD + 1);                     -- N counts up to RESET
  constant CO_NNQ_WIDTH_STD       : natural := log2ceil(CO_RESET_STD);                         -- Nn < RESET
  constant CO_UNARY_WIDTH_STD     : natural := log2ceil(CO_LIMIT_STD - CO_QBPP_STD);           -- max LIMIT - QBPP - 1
  constant CO_SUFFIX_WIDTH_STD    : natural := CO_AQ_WIDTH_STD;                                -- k or QBPP bits, both <= A_WIDTH
  constant CO_SUFFIXLEN_WIDTH_STD : natural := math_max(CO_K_WIDTH_STD, log2ceil(15 + 2));     -- J max = 15
  constant CO_TOTAL_WIDTH_STD     : natural := CO_AQ_WIDTH_STD + CO_BQ_WIDTH_STD + CO_CQ_WIDTH + CO_NQ_WIDTH_STD;

  -- Bit-packer / byte-stuffer / framer interface widths -------------------------
  constant CO_BIT_PACKER_OUT_WIDTH             : natural := CO_LIMIT_STD;
  constant CO_BYTE_STUFFER_OUT_BYTES_PER_CYCLE : natural := 4;
  constant CO_BYTE_STUFFER_OUT_WIDTH           : natural := CO_BYTE_STUFFER_OUT_BYTES_PER_CYCLE * 8;
  constant CO_BYTE_STUFFER_BURST_DEPTH         : natural := 16;

end package openjls_pkg;

package body openjls_pkg is

  function math_min (
    a,
    b : in unsigned
  ) return unsigned is
  begin

    if (a < b) then
      return a;
    else
      return b;
    end if;

  end function math_min;

  function math_max (
    a,
    b : in unsigned
  ) return unsigned is
  begin

    if (a > b) then
      return a;
    else
      return b;
    end if;

  end function math_max;

  function math_ceil_div (
    a,
    b : in natural
  ) return natural is
  begin

    return (a + b - 1) / b;

  end function math_ceil_div;

  function std_to_int (
    s : in std_logic
  ) return integer is
  begin

    -- Only an explicit '1' maps to 1: no spurious 1 from 'U' at sim start
    if (s = '1') then
      return 1;
    else
      return 0;
    end if;

  end function std_to_int;

  function bool2bit (
    b : in boolean
  ) return std_logic is
  begin

    if (b) then
      return '1';
    else
      return '0';
    end if;

  end function bool2bit;

end package body openjls_pkg;
