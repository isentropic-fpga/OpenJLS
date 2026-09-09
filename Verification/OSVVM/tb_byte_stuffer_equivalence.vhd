-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- Cycle-by-cycle comparison against a supplied pre-change byte_stuffer.
-- Run with compare_byte_stuffer.sh. The regular OSVVM test supplies the
-- independent bit-stream oracle; this test additionally locks throughput,
-- latency, backpressure, flush timing, and reset behavior to the baseline.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.olo_base_pkg_math.log2ceil;

entity tb_byte_stuffer_equivalence is
  generic (
    IN_WIDTH      : positive := 48;
    RANDOM_STALLS : boolean := true;
    IMAGE_COUNT   : positive := 2000
  );
end entity;

architecture sim of tb_byte_stuffer_equivalence is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal stall, ready, valid, flush : std_logic := '0';
  signal data : std_logic_vector(IN_WIDTH - 1 downto 0) := (others => '0');
  signal bits : unsigned(log2ceil(IN_WIDTH + 1) - 1 downto 0) := (others => '0');
  signal word_new, word_old : std_logic_vector(31 downto 0);
  signal bytes_new, bytes_old : unsigned(2 downto 0);
  signal valid_new, valid_old, full_new, full_old, last_new, last_old : std_logic;
  signal done : boolean := false;

  procedure random_step(variable state : inout unsigned(31 downto 0)) is
  begin
    state := state xor shift_left(state, 13);
    state := state xor shift_right(state, 17);
    state := state xor shift_left(state, 5);
  end procedure;
begin
  clk <= not clk after 5 ns;

  candidate : entity work.byte_stuffer(behavioral)
    generic map (IN_WIDTH => IN_WIDTH, OUT_BYTES_PER_CYCLE => 4, OUT_WIDTH => 32, BURST_DEPTH => 16)
    port map (
      iClk => clk, iRst => rst, iStall => stall, iWord => data,
      iWordValid => valid, iWordValidLen => bits, iFlush => flush,
      oWord => word_new, oWordValid => valid_new, oValidBytes => bytes_new,
      iReady => ready, oAlmostFull => full_new, oFlushDone => last_new
    );

  baseline : entity work.byte_stuffer_baseline(behavioral)
    generic map (IN_WIDTH => IN_WIDTH, OUT_BYTES_PER_CYCLE => 4, OUT_WIDTH => 32, BURST_DEPTH => 16)
    port map (
      iClk => clk, iRst => rst, iStall => stall, iWord => data,
      iWordValid => valid, iWordValidLen => bits, iFlush => flush,
      oWord => word_old, oWordValid => valid_old, oValidBytes => bytes_old,
      iReady => ready, oAlmostFull => full_old, oFlushDone => last_old
    );

  flow_control : process (clk) is
    variable rng : unsigned(31 downto 0) := x"BA5E1234";
    variable pause_left : natural := 0;
  begin
    if rising_edge(clk) then
      random_step(rng);
      if rst = '1' then
        stall <= '0';
        ready <= '1';
        pause_left := 0;
      else
        stall <= full_new;
        ready <= '1';
        if RANDOM_STALLS then
          if rng(2 downto 0) = 0 then
            stall <= '1';
          end if;
          if pause_left > 0 then
            ready <= '0';
            pause_left := pause_left - 1;
          elsif rng(6 downto 3) = 0 then
            ready <= '0';
            pause_left := to_integer(rng(11 downto 7));
          end if;
        end if;
      end if;
    end if;
  end process;

  compare : process (clk) is
    variable checked_cycles, emitted_bytes : natural := 0;
  begin
    if rising_edge(clk) and rst = '0' then
      checked_cycles := checked_cycles + 1;
      assert valid_new = valid_old report "output cycle changed" severity failure;
      assert full_new = full_old report "upstream stall timing changed" severity failure;
      assert last_new = last_old report "flush timing changed" severity failure;
      if valid_new = '1' then
        assert bytes_new = bytes_old report "bytes per cycle changed" severity failure;
        emitted_bytes := emitted_bytes + to_integer(bytes_new);
        for lane in 0 to 3 loop
          if lane < to_integer(bytes_new) then
            assert word_new(31 - lane * 8 downto 24 - lane * 8) =
                   word_old(31 - lane * 8 downto 24 - lane * 8)
              report "output byte changed" severity failure;
          end if;
        end loop;
      end if;
      if done then
        report "PASS: " & integer'image(checked_cycles) & " identical cycles, " &
               integer'image(emitted_bytes) & " identical output bytes";
      end if;
    end if;
  end process;

  stimulus : process is
    variable rng : unsigned(31 downto 0) := x"1234CAFE";
    variable word_value : std_logic_vector(IN_WIDTH - 1 downto 0);
    variable length, beats : positive;

    procedure send_word(word_bits : positive; is_last : std_logic) is
    begin
      data <= word_value;
      bits <= to_unsigned(word_bits, bits'length);
      valid <= '1';
      flush <= is_last;
      loop
        wait until rising_edge(clk);
        exit when stall = '0';
      end loop;
      valid <= '0';
      flush <= '0';
    end procedure;

    procedure reset_dut is
    begin
      rst <= '1';
      valid <= '0';
      flush <= '0';
      for cycle in 1 to 6 loop
        wait until rising_edge(clk);
      end loop;
      rst <= '0';
      wait until rising_edge(clk);
      assert valid_new = '0' and valid_old = '0' and last_new = '0' and last_old = '0'
        report "reset did not clear outputs" severity failure;
    end procedure;
  begin
    reset_dut;
    for image_index in 1 to IMAGE_COUNT loop
      random_step(rng);
      beats := 1 + to_integer(rng(6 downto 0)) mod 100;
      for beat in 1 to beats loop
        random_step(rng);
        length := 1 + to_integer(rng(7 downto 0)) mod IN_WIDTH;
        for bit_index in word_value'range loop
          random_step(rng);
          word_value(bit_index) := rng(0);
        end loop;
        -- Sustained maximum-width streams exercise refill and four-byte
        -- emission, both with no stuffing and with maximal stuffing.
        if image_index mod 4 = 0 then
          word_value := (others => '0');
          length := IN_WIDTH;
        elsif image_index mod 4 = 1 then
          word_value := (others => '1');
          length := IN_WIDTH;
        elsif rng(3 downto 2) = 0 then
          word_value := (others => '1');
        end if;
        if beat = beats then
          send_word(length, '1');
        else
          send_word(length, '0');
        end if;
      end loop;
      loop
        wait until rising_edge(clk);
        exit when last_new = '1';
      end loop;
      if image_index mod 127 = 0 then
        -- Abort an unfinished image with data in flight, then recover.
        for beat in 1 to 4 loop
          send_word(IN_WIDTH, '0');
        end loop;
        reset_dut;
      end if;
    end loop;
    -- Keep the clock running for the monitor's final sample/report.
    done <= true;
    wait for 11 ns;
    report "Cycle equivalence passed, IN_WIDTH=" & integer'image(IN_WIDTH) &
           ", RANDOM_STALLS=" & boolean'image(RANDOM_STALLS);
    std.env.finish;
  end process;

  watchdog : process is
  begin
    wait for 20 ms;
    assert false report "equivalence watchdog timeout" severity failure;
  end process;
end architecture;
