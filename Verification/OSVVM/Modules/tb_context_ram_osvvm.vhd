-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--
-- tb_context_ram_osvvm: context_ram against a behavioral model of its contract
--
-- The first read of an address since reset/EOI returns CTX_INIT; after that, a
-- same-cycle write to the read address forwards. A read on the EOI cycle uses
-- the ending image's flags. Accesses on the first reset cycle land in BRAM but
-- stay masked by the re-arm; their read result is a don't-care.
--
-- Guidelines:
--   G2.Clamp    N/A: no accumulator
--   G3.Stim     N/A: fields stored, no arithmetic
--   G4 other    N/A: Edge/Run/Coding not in scope

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

entity tb_context_ram_osvvm is
  generic (BITNESS : natural range 8 to 16 := CO_BITNESS_STD);
end entity tb_context_ram_osvvm;

architecture sim of tb_context_ram_osvvm is

  constant RANGE_P     : positive := 2 ** BITNESS;
  constant RAM_DEPTH   : positive := 367;
  constant A_WIDTH     : positive := BITNESS + log2ceil(CO_RESET_STD);
  constant B_WIDTH     : positive := BITNESS + 1;
  constant C_WIDTH     : positive := CO_CQ_WIDTH;
  constant N_WIDTH     : positive := CO_NQ_WIDTH_STD;
  constant TOTAL_WIDTH : positive := A_WIDTH + B_WIDTH + C_WIDTH + N_WIDTH;
  constant ADDR_W      : natural  := log2ceil(RAM_DEPTH);
  constant CLK_PERIOD  : time     := CLK_PERIOD_DEFAULT;

  constant A_INIT   : natural := math_max(2, (RANGE_P + 32) / 64);
  constant CTX_INIT : std_logic_vector(TOTAL_WIDTH - 1 downto 0) :=
    std_logic_vector(to_unsigned(A_INIT, A_WIDTH)) &
    std_logic_vector(to_signed(0, B_WIDTH)) &
    std_logic_vector(to_signed(0, C_WIDTH)) &
    std_logic_vector(to_unsigned(1, N_WIDTH));

  -- Field extremes
  constant W_MIN : std_logic_vector(TOTAL_WIDTH - 1 downto 0) :=
    std_logic_vector(to_unsigned(0, A_WIDTH)) &
    std_logic_vector(to_signed(-2 ** (B_WIDTH - 1), B_WIDTH)) &
    std_logic_vector(to_signed(-2 ** (C_WIDTH - 1), C_WIDTH)) &
    std_logic_vector(to_unsigned(0, N_WIDTH));
  constant W_MAX : std_logic_vector(TOTAL_WIDTH - 1 downto 0) := not W_MIN;
  constant A_LO  : natural := TOTAL_WIDTH - A_WIDTH;
  constant B_LO  : natural := A_LO - B_WIDTH;
  constant C_LO  : natural := B_LO - C_WIDTH;

  signal clk     : std_logic := '0';
  signal rst     : std_logic;
  signal iWrAddr : std_logic_vector(ADDR_W - 1 downto 0);
  signal iWrEn   : std_logic;
  signal iWrData : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
  signal iRdAddr : std_logic_vector(ADDR_W - 1 downto 0);
  signal iRdEn   : std_logic;
  signal iEoi    : std_logic;
  signal oRdData : std_logic_vector(TOTAL_WIDTH - 1 downto 0);

  type mem_t is array (0 to RAM_DEPTH - 1) of std_logic_vector(TOTAL_WIDTH - 1 downto 0);
  type ini_t is array (0 to RAM_DEPTH - 1) of boolean;

begin

  clk_proc : process is
  begin

    clk <= '1';
    wait for CLK_PERIOD / 2;
    clk <= '0';
    wait for CLK_PERIOD / 2;

  end process clk_proc;

  dut : entity work.context_ram(behavioral)
    generic map (
      RANGE_P     => RANGE_P,
      RAM_DEPTH   => RAM_DEPTH,
      A_WIDTH     => A_WIDTH,
      B_WIDTH     => B_WIDTH,
      C_WIDTH     => C_WIDTH,
      N_WIDTH     => N_WIDTH,
      TOTAL_WIDTH => TOTAL_WIDTH
    )
    port map (
      iClk        => clk,
      iRst        => rst,
      iWrAddr     => iWrAddr,
      iWrEn       => iWrEn,
      iWrData     => iWrData,
      iRdAddr     => iRdAddr,
      iRdEn       => iRdEn,
      iEndOfImage => iEoi,
      oRdData     => oRdData
    );

  stim : process is

    variable rv       : RandomPType;
    variable cov      : CoverageIDType;
    variable covEoiRd : CoverageIDType;
    variable mm       : CoverageIDType;
    variable rs       : CoverageIDType;
    variable req      : AlertLogIDType;
    variable mem   : mem_t := (others => (others => '0'));
    variable ini   : ini_t := (others => true);
    variable touched : ini_t := (others => false);

    -- One access cycle; eoi = '1' asserts iEndOfImage on the same cycle
    procedure step (
      rdEn   : std_logic;
      rdAddr : natural;
      wrEn   : std_logic;
      wrAddr : natural;
      wrData : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
      msg    : string;
      eoi    : std_logic := '0'
    ) is

      variable exp     : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
      variable outcome : integer;
      variable held : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
      variable q    : std_logic_vector(TOTAL_WIDTH - 1 downto 0);

    begin

      held := oRdData;
      iRdEn   <= rdEn;
      iRdAddr <= std_logic_vector(to_unsigned(rdAddr, ADDR_W));
      iWrEn   <= wrEn;
      iWrAddr <= std_logic_vector(to_unsigned(wrAddr, ADDR_W));
      iWrData <= wrData;
      iEoi    <= eoi;

      exp     := (others => '0');
      outcome := -1;
      if (rdEn = '1') then
        if (ini(rdAddr)) then
          exp     := CTX_INIT;
          outcome := 0;
        elsif (wrEn = '1' and wrAddr = rdAddr) then
          exp     := wrData;
          outcome := 2;
        else
          exp     := mem(rdAddr);
          outcome := 1;
        end if;
      end if;

      wait until rising_edge(clk);

      if (eoi = '1') then
        ini := (others => true);
      elsif (rdEn = '1') then
        ini(rdAddr) := false;
      end if;
      if (wrEn = '1') then
        mem(wrAddr)     := wrData;
        touched(wrAddr) := true;
      end if;

      wait for 1 ns;
      iEoi <= '0';
      if (rdEn = '1') then
        q := oRdData;
        AffirmIfEqual(req, q, exp, msg);
        ICover(mm, (0, checked_integer(unsigned(q(TOTAL_WIDTH - 1 downto A_LO)))));
        ICover(mm, (1, checked_integer(signed(q(A_LO - 1 downto B_LO)))));
        ICover(mm, (2, checked_integer(signed(q(B_LO - 1 downto C_LO)))));
        ICover(mm, (3, checked_integer(unsigned(q(C_LO - 1 downto 0)))));
        ICover(cov, outcome);
        if (eoi = '1') then
          ICover(covEoiRd, outcome);
        end if;
      else
        AffirmIfEqual(GetAlertLogID("ReadEnableHold"), oRdData, held, msg & " read disabled holds output");
      end if;

    end procedure step;

    procedure pulse_eoi is
    begin

      iRdEn <= '0';
      iWrEn <= '0';
      iEoi  <= '1';
      wait until rising_edge(clk);
      ini  := (others => true);
      iEoi <= '0';
      wait for 1 ns;

    end procedure pulse_eoi;

    procedure pulse_rst is
    begin

      iRdEn <= '0';
      iWrEn <= '0';
      rst   <= '1';
      ICover(rs, 0);
      clk_tick(clk, 2);
      rst   <= '0';
      ini := (others => true);
      wait until rising_edge(clk);
      wait for 1 ns;

    end procedure pulse_rst;

    -- Read and write in flight on the first reset cycle; the read is unchecked
    procedure pulse_rst_access (
      rdAddr : natural;
      wrAddr : natural;
      wrData : std_logic_vector(TOTAL_WIDTH - 1 downto 0)
    ) is
    begin

      iRdEn   <= '1';
      iRdAddr <= std_logic_vector(to_unsigned(rdAddr, ADDR_W));
      iWrEn   <= '1';
      iWrAddr <= std_logic_vector(to_unsigned(wrAddr, ADDR_W));
      iWrData <= wrData;
      rst     <= '1';
      ICover(rs, 1);
      wait until rising_edge(clk);
      mem(wrAddr)     := wrData;
      touched(wrAddr) := true;
      iRdEn <= '0';
      iWrEn <= '0';
      clk_tick(clk, 1);
      rst <= '0';
      ini := (others => true);
      wait until rising_edge(clk);
      wait for 1 ns;

    end procedure pulse_rst_access;

    variable a    : natural;
    variable d    : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
    constant ZERO : std_logic_vector(TOTAL_WIDTH - 1 downto 0) := (others => '0');

  begin

    iWrAddr <= (others => '0');
    iWrEn   <= '0';
    iWrData <= (others => '0');
    iRdAddr <= (others => '0');
    iRdEn   <= '0';
    iEoi    <= '0';

    SetAlertLogName("tb_context_ram_osvvm");
    SetLogEnable(PASSED, FALSE);
    rv.InitSeed(rv'instance_name);
    -- 18 directed + 3 x RAM_DEPTH sweep + 2 + at least 201 random
    req := GetReqID("OJLS.CtxRam", 1322);
    cov := NewID("G4.Stream readOutcome");
    SetFieldName(cov, "readOutcome");
    AddBins(cov, "initial value", GenBin(0));
    AddBins(cov, "stored value", GenBin(1));
    AddBins(cov, "forwarded write", GenBin(2));
    covEoiRd := NewID("G4.Stream readOnEoiCycle");
    SetFieldName(covEoiRd, "readOnEoiCycle");
    AddBins(covEoiRd, "initial on EOI", GenBin(0));
    AddBins(covEoiRd, "stored on EOI", GenBin(1));
    AddBins(covEoiRd, "forwarded on EOI", GenBin(2));

    rs := NewID("G5.States resetPhase");
    AddBins(rs, "idle", GenBin(0));
    AddBins(rs, "read+write in flight", GenBin(1));
    mm := NewID("G2.MinMax field x value");
    add_value_bin(mm, 0, "A", 0);
    add_value_bin(mm, 0, "A", 2 ** A_WIDTH - 1);
    add_value_bin(mm, 1, "B", -2 ** (B_WIDTH - 1));
    add_value_bin(mm, 1, "B", 2 ** (B_WIDTH - 1) - 1);
    add_value_bin(mm, 2, "C", -2 ** (C_WIDTH - 1));
    add_value_bin(mm, 2, "C", 2 ** (C_WIDTH - 1) - 1);
    add_value_bin(mm, 3, "N", 0);
    add_value_bin(mm, 3, "N", 2 ** N_WIDTH - 1);

    apply_reset(clk, rst, 4, '1');

    -- Directed ---
    d := std_logic_vector(to_unsigned(12345, TOTAL_WIDTH));
    step('1', 7, '1', 7, d, "addr7 first read = CTX_INIT (init wins over fwd)");
    step('1', 7, '0', 0, ZERO, "addr7 second read = written value");
    d := std_logic_vector(to_unsigned(54321, TOTAL_WIDTH));
    step('1', 7, '1', 7, d, "addr7 forward new data");
    -- The held value differs from the RAM's old data, so a dropped forward shows
    step('0', 8, '1', 9, not d, "idle after forwarding");
    step('1', 7, '0', 0, ZERO, "addr7 read = forwarded value");

    pulse_eoi;
    step('1', 7, '0', 0, ZERO, "addr7 after EOI = CTX_INIT");

    pulse_rst;
    step('1', 7, '0', 0, ZERO, "addr7 after mid-op iRst = CTX_INIT");
    step('1', 13, '0', 0, ZERO, "addr13 after iRst = CTX_INIT");

    -- Accesses on the first reset cycle ---
    d := std_logic_vector(to_unsigned(7777, TOTAL_WIDTH));
    step('1', 40, '1', 40, d, "addr40 init read + write-back");
    step('1', 40, '0', 0, ZERO, "addr40 = written value");
    d := std_logic_vector(to_unsigned(9999, TOTAL_WIDTH));
    pulse_rst_access(40, 55, d);
    step('1', 40, '0', 0, ZERO, "addr40 after reset-with-read-in-flight = CTX_INIT");
    step('1', 55, '0', 0, ZERO, "addr55 written during reset = CTX_INIT (init masks)");
    step('1', 55, '0', 0, ZERO, "addr55 second read = value written during reset");

    -- Read on the EOI cycle (tail escape bug) ---
    d := std_logic_vector(to_unsigned(3333, TOTAL_WIDTH));
    step('1', 21, '1', 21, d, "addr21 init read + write-back");
    step('1', 21, '0', 0, ZERO, "addr21 = written value");
    step('1', 33, '0', 0, ZERO, "fresh addr33 on EOI cycle = CTX_INIT", '1');
    step('1', 21, '0', 0, ZERO, "addr21 after EOI = CTX_INIT");
    step('1', 21, '0', 0, ZERO, "seen addr21 on EOI cycle = BRAM value", '1');
    step('1', 21, '0', 0, ZERO, "addr21 after second EOI = CTX_INIT");

    -- Field extremes through the BRAM and the forwarding path
    step('1', 50, '1', 50, W_MIN, "addr50 init read + write field minima");
    step('1', 50, '0', 0, ZERO, "addr50 read field minima");
    step('1', 50, '1', 50, W_MAX, "addr50 forward field maxima");
    step('1', 50, '0', 0, ZERO, "addr50 read field maxima");

    -- Address sweep ---
    pulse_eoi;
    for addr in 0 to RAM_DEPTH - 1 loop
      d := std_logic_vector(to_unsigned(addr + 1, TOTAL_WIDTH));
      step('1', addr, '1', addr, d, "address sweep first use");
    end loop;
    for addr in 0 to RAM_DEPTH - 1 loop
      step('1', addr, '0', 0, ZERO, "address sweep retained value");
    end loop;
    for addr in 0 to RAM_DEPTH - 1 loop
      d := rv.RandSlv(TOTAL_WIDTH);
      step('1', addr, '1', (addr + 1) mod RAM_DEPTH, d, "independent read/write");
      step('0', (addr + 2) mod RAM_DEPTH, '1', addr, not d, "write-only cycle");
      step('0', addr, '0', addr, ZERO, "idle cycle");
    end loop;
    step('1', 366, '1', 366, d, "forward on EOI", '1');
    step('1', 366, '0', 0, ZERO, "EOI rearms forwarded address");

    -- Random ---
    for i in 1 to 4000 loop

      a := rv.RandInt(0, RAM_DEPTH - 1);
      d := rv.RandSlv(TOTAL_WIDTH);

      -- ~1 in 40 reads ride an EOI cycle, like the last pixel
      if (rv.DistValInt(((1, 1), (0, 40))) = 1) then
        step('1', a, '1', a, d, "rand rmw+eoi a=" & integer'image(a), '1');
      else
        step('1', a, '1', a, d, "rand rmw a=" & integer'image(a));
      end if;

      if (rv.DistValInt(((1, 1), (0, 60))) = 1) then
        pulse_eoi;
      elsif (rv.DistValInt(((1, 1), (0, 80))) = 1) then
        pulse_rst;
      elsif (rv.DistValInt(((1, 1), (0, 100))) = 1) then
        pulse_rst_access(rv.RandInt(0, RAM_DEPTH - 1),
                         rv.RandInt(0, RAM_DEPTH - 1), rv.RandSlv(TOTAL_WIDTH));
      end if;

      exit when IsCovered(cov) and IsCovered(covEoiRd) and i > 200;

    end loop;

    WriteBin(cov);
    WriteBin(covEoiRd);
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(cov), "read-outcome coverage closed");
    AffirmIf(GetAlertLogID("CoverageClosure"), IsCovered(covEoiRd), "read-on-EOI-cycle coverage closed");
    affirm_covered(mm, "field min/max coverage closed");
    affirm_covered(rs, "reset phase coverage closed");

    end_of_test("tb_context_ram_osvvm");
    wait;

  end process stim;

  watchdog : process is
  begin

    wait for 50 ms;
    Alert(GetAlertLogID("Watchdog"), "tb_context_ram_osvvm: watchdog timeout", FAILURE);
    std.env.stop;

  end process watchdog;

end architecture sim;
