-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

--------------------------------------------------------------------------------
-- OSVVM testbench: context_ram (stateful memory contract).
--
-- Architectural block (no T.87 C segment). Contract verified against an
-- independent behavioral model:
--   * RdLatency = 1.
--   * First read of an address since reset/EOI returns CTX_INIT (the packed
--     A_INIT|B_INIT|C_INIT|N_INIT word), regardless of prior writes; the read
--     clears the init flag for that address.
--   * Same-cycle write to the read address forwards iWrData (WBR rebuilt over the
--     RBW BRAM) -- but only once the address is past its init read (init wins).
--   * Otherwise the read returns the last written value (RBW: a same-cycle write
--     to a *different* path does not affect this read).
--   * Reset / EndOfImage re-arms every address to CTX_INIT (BRAM contents kept).
--   * A read issued ON the iEndOfImage cycle (the pipeline does this: EOI rides
--     with the last pixel, whose context read is in flight that same cycle)
--     resolves against the ENDING image's init flags; the re-arm applies after.
--     Regression for the boundary-image bug where this read returned raw BRAM
--     for a first-use context (k=0 -> spurious escape on the last pixel).
--   * Accesses CAN be in flight on the first reset cycle (the pipeline's
--     valid registers clear synchronously, so the pre-reset valid still
--     drives the enables that cycle). They must be harmless: the re-arm wins
--     over the read's flag-clear, a write lands in BRAM but stays masked by
--     the re-armed init flag, and the read result is a don't-care (every
--     downstream consumer is reset on the cycle it would be used).
-- Every address is written before any second read so the modelled and real
-- BRAM contents always agree.
-- Coverage closes the three read outcomes plus fresh/seen reads on EOI cycles.
--------------------------------------------------------------------------------

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

  -- CTX_INIT packing, mirroring the module's documented init word.
  constant A_INIT   : natural := math_max(2, (RANGE_P + 32) / 64);
  constant CTX_INIT : std_logic_vector(TOTAL_WIDTH - 1 downto 0) :=
    std_logic_vector(to_unsigned(A_INIT, A_WIDTH)) &
    std_logic_vector(to_signed(0, B_WIDTH)) &
    std_logic_vector(to_signed(0, C_WIDTH)) &
    std_logic_vector(to_unsigned(1, N_WIDTH));

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
    variable mem   : mem_t := (others => (others => '0'));
    variable ini   : ini_t := (others => true);
    variable touched : ini_t := (others => false);  -- has the test written it?

    -- One access cycle. Computes the expected read result from the model
    -- (pre-write), advances the model at the edge, then checks oRdData.
    -- eoi='1' asserts iEndOfImage on the same cycle: the read still resolves
    -- against the ending image's flags; the all-address re-arm applies after.
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

    begin

      held := oRdData;
      iRdEn   <= rdEn;
      iRdAddr <= std_logic_vector(to_unsigned(rdAddr, ADDR_W));
      iWrEn   <= wrEn;
      iWrAddr <= std_logic_vector(to_unsigned(wrAddr, ADDR_W));
      iWrData <= wrData;
      iEoi    <= eoi;

      -- Expected result (computed before this cycle's write applies).
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

      -- Model state update at the edge. EOI re-arms every address (the
      -- in-flight read's own flag-clear is subsumed by the re-arm).
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
        AffirmIfEqual(GetAlertLogID("DataChecks"), oRdData, exp, msg);
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
      ini  := (others => true);                  -- re-arm init, keep mem
      iEoi <= '0';
      wait for 1 ns;

    end procedure pulse_eoi;

    -- Mid-operation iRst: re-arms init for every address (keeps BRAM), same as EOI.
    procedure pulse_rst is
    begin

      iRdEn <= '0';
      iWrEn <= '0';
      rst   <= '1';
      clk_tick(clk, 2);
      rst   <= '0';
      ini := (others => true);                    -- re-arm init, keep mem
      wait until rising_edge(clk);
      wait for 1 ns;

    end procedure pulse_rst;

    -- Mid-operation iRst with a read and a write in flight on the FIRST reset
    -- cycle (the pipeline does this: its valid registers clear synchronously).
    -- The read result is a don't-care (not checked); the write lands in BRAM
    -- (no reset on the memory) but is masked by the re-armed init flag.
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
      wait until rising_edge(clk);
      mem(wrAddr)     := wrData;                  -- the write still lands
      touched(wrAddr) := true;
      iRdEn <= '0';
      iWrEn <= '0';
      clk_tick(clk, 1);
      rst <= '0';
      ini := (others => true);                    -- re-arm init, keep mem
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
    cov := NewID("readOutcome");
    SetFieldName(cov, "readOutcome");
    AddBins(cov, "initial value", GenBin(0));
    AddBins(cov, "stored value", GenBin(1));
    AddBins(cov, "forwarded write", GenBin(2));   -- init / bram / forward
    covEoiRd := NewID("readOnEoiCycle");
    SetFieldName(covEoiRd, "readOnEoiCycle");
    AddBins(covEoiRd, "initial on EOI", GenBin(0));
    AddBins(covEoiRd, "stored on EOI", GenBin(1));
    AddBins(covEoiRd, "forwarded on EOI", GenBin(2)); -- fresh / RAM / forwarded

    apply_reset(clk, rst, 4, '1');

    --------------------------------------------------------------------------
    -- Directed: init read, then read-modify-write, then forward, then re-read.
    --------------------------------------------------------------------------
    d := std_logic_vector(to_unsigned(12345, TOTAL_WIDTH));
    -- First read of addr 7 -> CTX_INIT, with the write-back in the same cycle.
    step('1', 7, '1', 7, d, "addr7 first read = CTX_INIT (init wins over fwd)");
    -- Read addr 7 again -> the written value from the BRAM.
    step('1', 7, '0', 0, ZERO, "addr7 second read = written value");
    -- Same-cycle read+write addr 7 -> forwarded new data (past init).
    d := std_logic_vector(to_unsigned(54321, TOTAL_WIDTH));
    step('1', 7, '1', 7, d, "addr7 forward new data");
    -- Hold immediately after forwarding: the retained value differs from
    -- the RAM's old-data output, so dropping the forwarding select is visible.
    step('0', 8, '1', 9, not d, "idle after forwarding");
    -- Confirm the forwarded write landed.
    step('1', 7, '0', 0, ZERO, "addr7 read = forwarded value");

    -- EOI re-arms init: addr 7 reads CTX_INIT again.
    pulse_eoi;
    step('1', 7, '0', 0, ZERO, "addr7 after EOI = CTX_INIT");

    -- Mid-operation iRst re-arms init exactly like EOI: addr 7 (written/read
    -- above, so on the BRAM path) must revert to CTX_INIT after a reset.
    pulse_rst;
    step('1', 7, '0', 0, ZERO, "addr7 after mid-op iRst = CTX_INIT");
    -- And a fresh address is still an init read post-reset.
    step('1', 13, '0', 0, ZERO, "addr13 after iRst = CTX_INIT");

    --------------------------------------------------------------------------
    -- Directed: accesses in flight on the FIRST reset cycle (found by the
    -- top-level mid-stream reset stress; the module previously assumed them
    -- away). The re-arm must win over the in-flight read's flag-clear, and
    -- the in-flight write must stay masked until its post-reset init read.
    --------------------------------------------------------------------------
    d := std_logic_vector(to_unsigned(7777, TOTAL_WIDTH));
    step('1', 40, '1', 40, d, "addr40 init read + write-back");
    step('1', 40, '0', 0, ZERO, "addr40 = written value");
    d := std_logic_vector(to_unsigned(9999, TOTAL_WIDTH));
    pulse_rst_access(40, 55, d);
    step('1', 40, '0', 0, ZERO, "addr40 after reset-with-read-in-flight = CTX_INIT");
    step('1', 55, '0', 0, ZERO, "addr55 written during reset = CTX_INIT (init masks)");
    step('1', 55, '0', 0, ZERO, "addr55 second read = value written during reset");

    --------------------------------------------------------------------------
    -- Directed regression (boundary-image bug): a read in flight ON the EOI
    -- cycle. The preceding read is a seen address, so the buggy version's
    -- stale flag served raw BRAM for the fresh address below.
    --------------------------------------------------------------------------
    d := std_logic_vector(to_unsigned(3333, TOTAL_WIDTH));
    step('1', 21, '1', 21, d, "addr21 init read + write-back");
    step('1', 21, '0', 0, ZERO, "addr21 = written value");
    -- Fresh address read on the EOI cycle: must be CTX_INIT, not raw BRAM.
    step('1', 33, '0', 0, ZERO, "fresh addr33 on EOI cycle = CTX_INIT", '1');
    -- Re-armed by that EOI: addr 21 is fresh again despite its BRAM value.
    step('1', 21, '0', 0, ZERO, "addr21 after EOI = CTX_INIT");
    -- Seen address read on the EOI cycle: must be the BRAM value (the buggy
    -- version's stale flag could equally serve CTX_INIT here).
    step('1', 21, '0', 0, ZERO, "seen addr21 on EOI cycle = BRAM value", '1');
    step('1', 21, '0', 0, ZERO, "addr21 after second EOI = CTX_INIT");

    --------------------------------------------------------------------------
    -- Constrained-random: random addresses, always read-modify-write so the
    -- modelled and real BRAM stay in sync.
    --------------------------------------------------------------------------
    -- Initialize every physical address with unique data, including 365/366.
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

    for i in 1 to 4000 loop

      a := rv.RandInt(0, RAM_DEPTH - 1);
      d := rv.RandSlv(TOTAL_WIDTH);

      -- ~1-in-40 reads ride an EOI cycle (the last-pixel pattern); otherwise
      -- plain read-modify-write.
      if (rv.DistValInt(((1, 1), (0, 40))) = 1) then
        step('1', a, '1', a, d, "rand rmw+eoi a=" & integer'image(a), '1');
      else
        step('1', a, '1', a, d, "rand rmw a=" & integer'image(a));
      end if;

      -- Occasional idle-cycle EOI or mid-stream iRst (with or without an
      -- access in flight on the first reset cycle) as well.
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
