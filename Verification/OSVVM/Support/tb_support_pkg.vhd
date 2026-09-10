-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library osvvm;
  context osvvm.OsvvmContext;

package tb_support_pkg is

  constant TB_J_TABLE : integer_vector(0 to 31) :=
    (0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
     4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12, 13, 14, 15);

  constant CLK_PERIOD_DEFAULT : time := 10 ns;

  -- T.87 Annex H.3 conformance image (4x4, 8-bit, NEAR=0) and its known-good
  -- 57-byte JPEG-LS stream. Shared self-contained oracle for the Xilinx wrapper
  -- TBs; the same vectors live in Top/tb_openjls_top_osvvm.vhd (the module that
  -- owns payload correctness). Held as integer_vector so the OSVVM AxiStream
  -- burst API (PushBurst / CheckBurst) consumes them directly.
  constant H3_WIDTH    : natural := 4;
  constant H3_HEIGHT   : natural := 4;
  constant H3_BITNESS  : natural := 8;

  constant H3_PIXELS   : integer_vector(0 to 15) :=
    (0, 0, 90, 74, 68, 50, 43, 205, 64, 145, 145, 145, 100, 145, 145, 145);

  constant H3_EXPECTED : integer_vector(0 to 56) :=
    (16#FF#, 16#D8#, 16#FF#, 16#F7#, 16#00#, 16#0B#, 16#08#, 16#00#, 16#04#, 16#00#, 16#04#,
     16#01#, 16#01#, 16#11#, 16#00#, 16#FF#, 16#DA#, 16#00#, 16#08#, 16#01#, 16#01#, 16#00#,
     16#00#, 16#00#, 16#00#,
     16#C0#, 16#00#, 16#00#, 16#6C#, 16#80#, 16#20#, 16#8E#, 16#01#, 16#C0#, 16#00#, 16#00#,
     16#57#, 16#40#, 16#00#, 16#00#, 16#6E#, 16#E6#, 16#00#, 16#00#, 16#01#, 16#BC#, 16#18#,
     16#00#, 16#00#, 16#05#, 16#D8#, 16#00#, 16#00#, 16#91#, 16#60#,
     16#FF#, 16#D9#);

  -- 12-bit companion image (4x4, NEAR=0) for the two-byte pixel lane of the
  -- Xilinx stream wrapper (BITNESS 9..16 -> 16-bit TDATA). Golden minted with
  -- the vendored CharLS encoder after the byte-exact T16E0.JLS trust gate
  -- (same flow as "Verification/Golden model/build_run.sh"):
  --   charls-cli encode b12.pgm b12.jls    # P5, 4x4, maxval 4095, big-endian
  -- Pixel values span the full 12-bit range (0/4095), sit above the 8-bit
  -- ceiling (so a dropped upper byte cannot go unnoticed) and include a flat
  -- run to enter run mode.
  constant B12_WIDTH   : natural := 4;
  constant B12_HEIGHT  : natural := 4;
  constant B12_BITNESS : natural := 12;

  constant B12_PIXELS  : integer_vector(0 to 15) :=
    (0, 4095, 2048, 1024, 300, 300, 300, 300, 256, 511, 2047, 3000, 100, 100, 2048, 4000);

  constant B12_EXPECTED : integer_vector(0 to 62) :=
    (16#FF#, 16#D8#, 16#FF#, 16#F7#, 16#00#, 16#0B#, 16#0C#, 16#00#, 16#04#, 16#00#, 16#04#,
     16#01#, 16#01#, 16#11#, 16#00#, 16#FF#, 16#DA#, 16#00#, 16#08#, 16#01#, 16#01#, 16#00#,
     16#00#, 16#00#, 16#00#,
     16#A0#, 16#00#, 16#00#, 16#00#, 16#00#, 16#0F#, 16#FE#, 16#FF#, 16#78#, 16#01#, 16#60#,
     16#01#, 16#66#, 16#04#, 16#03#, 16#70#, 16#1F#, 16#80#, 16#00#, 16#00#, 16#00#, 16#06#,
     16#FF#, 16#5E#, 16#EA#, 16#1D#, 16#C0#, 16#7D#, 16#00#, 16#0F#, 16#00#, 16#00#, 16#00#,
     16#00#, 16#28#, 16#00#, 16#FF#, 16#D9#);

  -- Label the delay models created internally by the OSVVM AXI components.
  -- Their stock bins have blank names and repeated model names in YAML.
  procedure label_delay_coverage(id : DelayCoverageIDType; prefix : string);

  -- Numeric conversion must not turn X/U outputs into an apparently correct 0.
  impure function checked_integer(value : unsigned) return integer;
  impure function checked_integer(value : signed) return integer;
  impure function checked_bit(value : std_logic) return integer;

  procedure monitor_stream (
    signal clk, rst, valid, ready : in std_logic;
    signal data, keep : in std_logic_vector;
    signal last : in std_logic;
    constant reset_active : std_logic := '1';
    constant msb_first : boolean := true
  );

  procedure clk_tick (
    signal   clk    : in    std_logic;
    constant cycles : in    natural := 1
  );

  procedure apply_reset (
    signal   clk    : in    std_logic;
    signal   rst    : out   std_logic;
    constant cycles : in    natural := 4;
    constant active : in    std_logic := '1'
  );

  procedure end_of_test (
    constant test_name : in string
  );

end package tb_support_pkg;

package body tb_support_pkg is

  procedure label_delay_coverage(id : DelayCoverageIDType; prefix : string) is
    procedure label_model(model : CoverageIDType; label_text : string) is
      variable bounds : RangeArrayType(1 to GetBinValLength(model));
    begin
      -- SetName is the pinned OSVVM API for renaming an already-created model;
      -- replacing its ID would discard the VC's configured distributions.
      SetName(model, prefix & " " & label_text);
      if bounds'length = 1 then
        SetFieldName(model, label_text);
      else
        SetFieldName(model, "ready after valid (0/1)", "delay cycles");
      end if;
      for bin_index in 1 to GetNumBins(model) loop
        bounds := GetBinVal(model, bin_index);
        if bounds'length = 1 then
          SetBinName(model, bin_index, prefix & " " & label_text & " " &
            to_string(bounds(1).Min) & ".." & to_string(bounds(1).Max));
        else
          SetBinName(model, bin_index, prefix & " " & label_text &
            " readyAfterValid=" & to_string(bounds(1).Min) &
            " cycles=" & to_string(bounds(2).Min) & ".." & to_string(bounds(2).Max));
        end if;
      end loop;
    end procedure;
  begin
    label_model(id.BurstLengthCov, "burst length");
    label_model(id.BurstDelayCov, "burst delay");
    label_model(id.BeatDelayCov, "beat delay");
  end procedure;



  impure function checked_integer(value : unsigned) return integer is
  begin
    AlertIf(GetAlertLogID("KnownOutputs"), Is_X(std_logic_vector(value)), "unknown unsigned DUT output");
    return to_integer(value);
  end function;

  impure function checked_integer(value : signed) return integer is
  begin
    AlertIf(GetAlertLogID("KnownOutputs"), Is_X(std_logic_vector(value)), "unknown signed DUT output");
    return to_integer(value);
  end function;

  impure function checked_bit(value : std_logic) return integer is
  begin
    AlertIf(GetAlertLogID("KnownOutputs"), value /= '0' and value /= '1', "unknown DUT control output");
    if value = '1' then return 1; else return 0; end if;
  end function;



  procedure monitor_stream (
    signal clk, rst, valid, ready : in std_logic;
    signal data, keep : in std_logic_vector;
    signal last : in std_logic;
    constant reset_active : std_logic := '1';
    constant msb_first : boolean := true
  ) is
    constant id : AlertLogIDType := GetAlertLogID("StreamProtocol");
    variable held : boolean := false;
    variable held_data : std_logic_vector(data'range);
    variable held_keep : std_logic_vector(keep'range);
    variable held_last : std_logic;
    variable gap : boolean;
    variable lane : natural;
  begin
    loop
      wait until rising_edge(clk);
      if rst = reset_active then
        held := false;
      else
        if held then
          AffirmIf(id, valid = '1', "pending valid held until accepted");
          AffirmIfEqual(id, data, held_data, "pending data held until accepted");
          AffirmIfEqual(id, keep, held_keep, "pending keep held until accepted");
          AffirmIfEqual(id, last, held_last, "pending last held until accepted");
        end if;
        AffirmIf(id, last /= '1' or valid = '1', "last requires valid");
        if valid = '1' then
          AffirmIf(id, not Is_X(data) and not Is_X(keep) and not Is_X(last), "valid beat has known data and metadata");
          AffirmIf(id, unsigned(keep) /= 0, "valid beat contains bytes");
          gap := false;
          for i in 0 to keep'length - 1 loop
            if msb_first then lane := keep'high - i;
            else lane := keep'low + i;
            end if;
            if keep(lane) = '0' then
              gap := true;
            else
              AffirmIf(id, not gap, "keep lanes are contiguous and correctly aligned");
            end if;
          end loop;
          AffirmIf(id, last = '1' or keep = (keep'range => '1'), "partial beat only at image end");
        end if;
        held := valid = '1' and ready = '0';
        held_data := data;
        held_keep := keep;
        held_last := last;
      end if;
    end loop;
  end procedure;



  procedure clk_tick (
    signal   clk    : in    std_logic;
    constant cycles : in    natural := 1
  ) is
  begin
    for i in 1 to cycles loop
      wait until rising_edge(clk);
    end loop;
  end procedure;

  procedure apply_reset (
    signal   clk    : in    std_logic;
    signal   rst    : out   std_logic;
    constant cycles : in    natural := 4;
    constant active : in    std_logic := '1'
  ) is
  begin
    rst <= active;
    for i in 1 to cycles loop
      wait until rising_edge(clk);
    end loop;
    rst <= not active;
    wait until rising_edge(clk);
  end procedure;

  procedure end_of_test (
    constant test_name : in string
  ) is
    variable errors : integer;
  begin
    -- EndOfTestReports = ReportAlerts + YAML emission (alerts, functional
    -- coverage, scoreboards) consumed by the OSVVM script flow's HTML reports.
    SetAlertLogReportMode(ALERT_DEFAULT_ID, NONZERO);
    errors := EndOfTestReports;
    if errors = 0 then
      report test_name & ": PASS" severity note;
    else
      report test_name & ": FAIL" severity failure;
    end if;
    std.env.stop;
  end procedure;

end package body tb_support_pkg;
