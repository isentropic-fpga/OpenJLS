-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
-- Independent serial-bit scoreboard and sustained-rate/backpressure regression.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.olo_base_pkg_math.log2ceil;
use work.openjls_pkg.all;

entity tb_byte_stuffer_throughput is
  generic (
    IN_WIDTH : positive := 64;
    LANES : positive := 4;
    RANDOM_READY : boolean := false
  );
end entity;

architecture test of tb_byte_stuffer_throughput is
  constant BPP : positive := IN_WIDTH / 4;
  constant BEATS : positive := 4096;
  constant FULL_RATE : boolean := 8 * LANES - (LANES + 1) / 2 >= IN_WIDTH;
  signal clk : std_logic := '0';
  signal rst, valid, flush, stall, full, out_valid, last : std_logic := '0';
  signal ready : std_logic := '1';
  signal data : std_logic_vector(IN_WIDTH - 1 downto 0) := (others => '0');
  signal bits : unsigned(log2ceil(IN_WIDTH + 1) - 1 downto 0) := (others => '0');
  signal output : std_logic_vector(8 * LANES - 1 downto 0);
  signal bytes : unsigned(log2ceil(LANES + 1) - 1 downto 0);
  signal stalls, checked, images : natural := 0;
  signal scenario : natural := 0;
  function step(r : unsigned(31 downto 0)) return unsigned is
  begin
    return r(30 downto 0) & (r(31) xor r(21) xor r(1) xor r(0));
  end function;
begin
  clk <= not clk after 5 ns;
  dut : entity work.byte_stuffer
    generic map (IN_WIDTH => IN_WIDTH, OUT_BYTES_PER_CYCLE => LANES, BURST_DEPTH => 64)
    port map (iClk => clk, iRst => rst, iStall => stall, iWord => data,
      iWordValid => valid, iWordValidLen => bits, iFlush => flush,
      oWord => output, oWordValid => out_valid, oValidBytes => bytes,
      iReady => ready, oAlmostFull => full, oFlushDone => last);

  flow : process(clk)
    variable rng : unsigned(31 downto 0) := x"18263745";
    variable pause : natural := 0;
  begin
    if rising_edge(clk) then
      -- Registered return path; maximum-rate input continues during propagation.
      stall <= full;
      ready <= '1';
      if RANDOM_READY then
        rng := step(rng);
        if pause > 0 then
          pause := pause - 1;
          ready <= '0';
        elsif rng(7 downto 0) = 0 then
          pause := 100;
          ready <= '0';
        end if;
      end if;
      if rst = '0' and valid = '1' and stall = '1' then
        stalls <= stalls + 1;
      end if;
    end if;
  end process;

  scoreboard : process(clk)
    type queue_t is array(0 to 1000000) of std_logic_vector(7 downto 0);
    variable queue : queue_t;
    type end_queue_t is array(0 to 8191) of natural;
    variable ends : end_queue_t;
    variable ew, er : natural := 0;
    variable wr, rd, count : natural := 0;
    variable byte : std_logic_vector(7 downto 0) := (others => '0');
    variable prev_ff : boolean := false;
    procedure append(b : std_logic) is
    begin
      byte(7 - count) := b;
      count := count + 1;
      if count = 8 then
        queue(wr) := byte;
        wr := wr + 1;
        prev_ff := byte = x"FF";
        byte := (others => '0');
        count := 0;
      end if;
    end procedure;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        wr := 0; rd := 0; ew := 0; er := 0; count := 0; prev_ff := false;
        byte := (others => '0');
      else
        if valid = '1' and stall = '0' then
          for i in 0 to to_integer(bits) - 1 loop
            if prev_ff and count = 0 then
              append('0');
            end if;
            append(data(IN_WIDTH - 1 - i));
          end loop;
          if flush = '1' then
            if prev_ff and count = 0 then
              append('0');
            end if;
            while count /= 0 loop
              append('0');
            end loop;
            prev_ff := false;
            ends(ew) := wr; ew := ew + 1;
          end if;
        end if;
        if out_valid = '1' then
          for lane in 0 to to_integer(bytes) - 1 loop
            assert rd < wr report "unexpected byte" severity failure;
            assert output(output'high - 8 * lane downto output'high - 8 * lane - 7) = queue(rd)
              report "serial scoreboard mismatch at byte " & integer'image(rd) severity failure;
            rd := rd + 1;
          end loop;
          checked <= rd;
          if last = '1' then
            assert er < ew and rd = ends(er) report "flush boundary mismatch" severity failure;
            er := er + 1;
            images <= images + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  stimulus : process
    variable rng : unsigned(31 downto 0) := x"CADE1234";
    variable word : std_logic_vector(data'range);
    variable length, before_stalls : natural;
    procedure send(n : positive; terminal : boolean) is
    begin
      data <= word; bits <= to_unsigned(n, bits'length); valid <= '1';
      flush <= bool2bit(terminal);
      loop
        wait until rising_edge(clk);
        exit when stall = '0';
      end loop;
      valid <= '0'; flush <= '0';
    end procedure;
  begin
    rst <= '1';
    for i in 1 to 8 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);
    for pattern in 0 to 3 loop
      scenario <= pattern;
      before_stalls := stalls;
      for beat in 1 to BEATS loop
        word := (others => '0');
        length := IN_WIDTH;
        case pattern is
          when 0 => null;
          when 1 => word := (others => '1');
          when 2 =>
            -- Legal regular Golomb escape for k=0, MErrval=2**(BPP-1):
            -- LIMIT-QBPP-1 zero bits, delimiter, QBPP-bit MErrval-1.
            word(BPP) := '1';
            word(BPP - 1 downto 0) := std_logic_vector(to_unsigned(2**(BPP-1)-1, BPP));
          when others =>
            rng := step(rng);
            length := 1 + to_integer(rng(7 downto 0)) mod IN_WIDTH;
            for b in word'range loop
              rng := step(rng); word(b) := rng(0);
            end loop;
        end case;
        send(length, beat = BEATS);
      end loop;
      wait until images = pattern + 1;
      report "pattern=" & integer'image(pattern) & " stalls=" & integer'image(stalls-before_stalls);
      if FULL_RATE and not RANDOM_READY then
        assert stalls = before_stalls report "full-rate stuffer backpressured input" severity failure;
      elsif not RANDOM_READY and (pattern = 1 or (IN_WIDTH > 32 and pattern < 3)) then
        assert stalls > before_stalls report "baseline stress did not reach backpressure" severity failure;
      end if;
      wait until rising_edge(clk);
    end loop;
    -- No inter-image wait: a terminal bubble eventually fills any finite
    -- FIFO even if payload throughput alone equals the input rate.
    for pattern in 0 to 2 loop
      before_stalls := stalls;
      for frame in 1 to 1024 loop
        for beat in 1 to 4 loop
          word := (others => bool2bit(pattern /= 0));
          length := IN_WIDTH;
          if pattern = 2 then
            rng := step(rng);
            length := 1 + to_integer(rng(7 downto 0)) mod IN_WIDTH;
          end if;
          if beat = 4 and pattern /= 2 then
            -- Alternate full and partial terminals, keeping all earlier
            -- words full so stage 1 needs at most one flush write.
            length := IN_WIDTH - (frame mod 8);
          end if;
          send(length, beat = 4);
        end loop;
      end loop;
      wait until images = 4 + (pattern + 1) * 1024;
      report "continuous frames pattern=" & integer'image(pattern) &
        " stalls=" & integer'image(stalls-before_stalls);
      if FULL_RATE and LANES > IN_WIDTH / 8 + 1 and not RANDOM_READY then
        assert stalls = before_stalls report "terminal bubbles stalled input" severity failure;
      end if;
      wait until rising_edge(clk);
    end loop;
    report "PASS: width=" & integer'image(IN_WIDTH) & " lanes=" & integer'image(LANES) &
      " random_ready=" & boolean'image(RANDOM_READY) & " checked_bytes=" & integer'image(checked);
    std.env.finish;
  end process;
  watchdog : process
  begin
    wait for 10 ms;
    assert false report "throughput watchdog" severity failure;
  end process;
end architecture;
