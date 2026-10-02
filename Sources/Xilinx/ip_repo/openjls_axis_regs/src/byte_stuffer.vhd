-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

----------------------------------------------------------------------------------
-- Engineer:    Vitor Mendes Camilo
--
-- Module Name: byte_stuffer - Behavioral
-- Description:
--
--   Per T.87: every 0xFF byte in the encoded bitstream must be followed by a
--   stuffed '0' bit so decoders can distinguish payload from markers (an FF
--   followed by a byte with MSB='1' denotes a marker).
--
--   Three internal stages:
--
--     Stage 1 — bit packer:
--       Accumulates input bits MSB-first into a 2*FIFO_BITS accumulator.
--       Drains a fixed FIFO_BITS-wide word into the FIFO whenever enough
--       bits are present. On flush the sub-byte residue is padded to a
--       byte boundary; the final FIFO write is always FIFO_BITS wide
--       (zero-padded if needed) and carries the final word's real valid-bit
--       count (the byte-boundary pad excluded) plus last_flag=1. Stage 3
--       counts only those real bits, so the pad is never emitted; the
--       genuine residue is padded post-stuffing at the terminal beat.
--
--     Stage 2 — sync FIFO (RAMSTYLE "auto": memory type chosen by synthesis)
--
--     Stage 3 — FF stuffer + output emit:
--       Refills a holding register using the nine fixed alignments allowed
--       by the refill contract (0..8 old bits). Each cycle forms up to OUT_BYTES_PER_CYCLE
--       output bytes by decoding all legal stuffing layouts in
--       parallel. Each layout uses fixed bit slices and constant valid-bit
--       thresholds. One-hot selection chooses the output, the last FF state,
--       and a fixed-shift remainder without a serial lane-resolution chain.
--
--       The end-of-image terminal beat (sub-byte residue, a pending stuff
--       bit with no follow-up data, or a byte-aligned clean end) is split
--       into its own cycle in compatibility mode via sLastPending: the final byte (or 0-byte beat)
--       is assembled, latched, and emitted on the following beat. Adds at
--       most 1 cycle of latency per image boundary and keeps the pad-byte
--       assembly off the critical path. Full-rate mode reserves one extra
--       lane for terminal padding and emits EOI with the last payload beat,
--       removing this bubble even across uninterrupted frames. A formatter
--       pipeline stage adds one cycle of output latency in full-rate mode;
--       downstream must reserve space for that additional in-flight beat.
--
--   Flush protocol (iFlush, single-cycle pulse from upstream on the cycle
--   the bit_packer presents the image's last word):
--     - Stage 1 pads its sub-byte residue and tags the final FIFO write
--       with last_flag=1.
--     - Stage 3 latches the last_flag when it pops that word. Once the
--       holding register drains, it inserts a final stuff '0' if the last
--       payload byte was 0xFF, zero-pads the output accumulator to a byte
--       boundary, emits the remaining whole bytes, and pulses oFlushDone
--       on the final output beat (oFlushDone is sampled together with
--       oWordValid='1', matching jls_framer's iEOI contract).
--
-- Generics:
--   IN_WIDTH            : bit_packer worst-case word width (= LIMIT).
--   OUT_BYTES_PER_CYCLE : output bytes/cycle, 4..10 (elaboration-time layouts).
--   BURST_DEPTH         : depth of the sync FIFO (in wide words).
--
----------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library work;
  use work.olo_base_pkg_math.log2ceil;

entity byte_stuffer is
  generic (
    IN_WIDTH            : natural := CO_LIMIT_STD;
    OUT_BYTES_PER_CYCLE : natural := CO_BYTE_STUFFER_OUT_BYTES_PER_CYCLE; -- 4 lanes for compatibility; 6/8/10 for full-rate 32/48/64-bit input including terminals
    OUT_WIDTH           : natural := OUT_BYTES_PER_CYCLE * 8;
    BURST_DEPTH         : natural := CO_BYTE_STUFFER_BURST_DEPTH
  );
  port (
    iClk                : in    std_logic;
    iRst                : in    std_logic;
    iStall              : in    std_logic;                                -- Acts as oReady, always ready to receive data unless stalled
    iWord               : in    std_logic_vector(IN_WIDTH - 1 downto 0);
    iWordValid          : in    std_logic;
    iWordValidLen       : in    unsigned(log2ceil(IN_WIDTH + 1) - 1 downto 0);
    iFlush              : in    std_logic;
    oWord               : out   std_logic_vector(OUT_WIDTH - 1 downto 0);
    oWordValid          : out   std_logic;
    oValidBytes         : out   unsigned(log2ceil(OUT_BYTES_PER_CYCLE + 1) - 1 downto 0);
    iReady              : in    std_logic;
    oAlmostFull         : out   std_logic;
    oFlushDone          : out   std_logic
  );
end entity byte_stuffer;

architecture behavioral of byte_stuffer is

  -- Constants ----------------------------------------------------------------

  -- Stage 1 sizing
  constant FIFO_BYTES             : natural := math_ceil_div(IN_WIDTH, 8);
  constant FIFO_BITS              : natural := FIFO_BYTES * 8;
  constant ACCUM_BITS             : natural := 2 * FIFO_BITS;
  -- Width of the final word's valid-bit count carried alongside the last FIFO
  -- word (0..FIFO_BITS). Stage 1's byte-boundary pad (added so the FIFO word is
  -- whole bytes) is excluded from this count, so stage 3 never emits the pad
  -- bits; the genuine sub-byte residue is padded post-stuffing at the terminal.
  constant LAST_BITS_WIDTH        : natural := log2ceil(FIFO_BITS + 1);

  -- FIFO entry layout (LSB-first):
  --   bit  [0]              : last_flag
  --   bits [1 .. FIFO_BITS] : data
  --   remaining high bits   : final valid-bit count (only used with last_flag)
  constant LAST_POS               : natural := 0;
  constant DATA_LSB               : natural := 1;
  constant COUNT_LSB              : natural := FIFO_BITS + 1;
  constant FIFO_WIDTH             : natural := COUNT_LSB + LAST_BITS_WIDTH;

  -- Carry the final valid-bit count in the same entry as its data. A tiny
  -- independent queue can overflow on short frames long before this FIFO fills.

  -- AlmFull asserts STALL_CUSHION_ENTRIES below Full so the FIFO can absorb
  -- in-flight tokens while the top-level stall signal propagates through its
  -- pipeline (registered AlmFulls + registered sStallLogic = ~4 cycles).
  constant STALL_CUSHION_ENTRIES  : natural := 5;
  constant ALM_FULL_LEVEL         : natural := BURST_DEPTH - STALL_CUSHION_ENTRIES;

  -- Stage 3 holding register: one FIFO pop + 1 byte (deadlock floor). Bits
  -- stored MSB-first (oldest emitted first).
  constant HOLD_BYTES             : natural := FIFO_BYTES + 1;
  constant HOLD_BITS              : natural := HOLD_BYTES * 8;

  -- At full rate every ready cycle leaves only a sub-byte residue. Express
  -- that invariant structurally so synthesis does not build a wide feedback
  -- mux for unreachable states. Refill still supplies a full combinational word.
  constant DATA_LANES : positive := math_min(OUT_BYTES_PER_CYCLE, FIFO_BYTES + 1);
  constant FULL_RATE : boolean :=
    8 * DATA_LANES - (DATA_LANES + 1) / 2 >= FIFO_BITS;
  function holding_state_bits return positive is
  begin
    if FULL_RATE then return 8; else return HOLD_BITS; end if;
  end function;
  constant STATE_BITS : positive := holding_state_bits;

  -- Enumerate legal layouts at elaboration, not at run time. A stuffed
  -- byte has MSB=0, so adjacent lanes cannot both require a stuff bit.
  -- Each candidate below uses only fixed slices and constant thresholds.
  function layout_count return positive is
    variable a : positive := 1;
    variable b : positive := 2;
    variable c : positive;
  begin
    for lane in 2 to DATA_LANES loop
      c := a + b;
      a := b;
      b := c;
    end loop;
    return b;
  end function;
  type layout_array is array (0 to layout_count - 1) of
    std_logic_vector(0 to DATA_LANES - 1);
  function make_layouts return layout_array is
    variable result : layout_array;
    variable bits : unsigned(DATA_LANES - 1 downto 0);
    variable legal : boolean;
    variable index : natural := 0;
  begin
    for value in 0 to 2 ** DATA_LANES - 1 loop
      bits := to_unsigned(value, bits'length);
      legal := (bits and shift_right(bits, 1)) = 0;
      if legal then
        result(index) := std_logic_vector(bits);
        index := index + 1;
      end if;
    end loop;
    return result;
  end function;
  constant STUFF_LAYOUT : layout_array := make_layouts;
  type lane_count_array is array (STUFF_LAYOUT'range, 0 to DATA_LANES - 1)
    of natural range 0 to OUT_WIDTH;
  function lane_counts(is_end : boolean) return lane_count_array is
    variable result : lane_count_array;
    variable count : natural;
  begin
    for p in STUFF_LAYOUT'range loop
      count := 0;
      for lane in 0 to DATA_LANES - 1 loop
        result(p, lane) := count;
        if STUFF_LAYOUT(p)(lane) = '1' then
          count := count + 7;
        else
          count := count + 8;
        end if;
        if is_end then
          result(p, lane) := count;
        end if;
      end loop;
    end loop;
    return result;
  end function;
  constant LANE_START : lane_count_array := lane_counts(false);
  constant LANE_END   : lane_count_array := lane_counts(true);
  -- Only consumption counts reachable by a complete prefix need a shifter.
  type consume_array is array (natural range <>) of natural range 0 to OUT_WIDTH;
  function make_consumes return consume_array is
    variable used : boolean_vector(0 to OUT_WIDTH) := (others => false);
    variable result : consume_array(0 to OUT_WIDTH);
    variable count : natural := 0;
  begin
    used(0) := true;
    for p in STUFF_LAYOUT'range loop
      for lane in 0 to DATA_LANES - 1 loop
        used(LANE_END(p, lane)) := true;
      end loop;
    end loop;
    for bits in used'range loop
      if used(bits) then
        result(count) := bits;
        count := count + 1;
      end if;
    end loop;
    return result(0 to count - 1);
  end function;
  constant CONSUME_BITS : consume_array := make_consumes;

  -- Signals ---------------------------------------------------------------------
  -- Input register
  signal sWord                    : std_logic_vector(IN_WIDTH - 1 downto 0);
  signal sWordValidLen            : unsigned(log2ceil(IN_WIDTH + 1) - 1 downto 0);
  signal sWordValid               : std_logic;
  signal sFlush                   : std_logic;

  -- Stage 1 accumulator
  signal sAccumBuffer             : std_logic_vector(ACCUM_BITS - 1 downto 0);
  signal sAccumCountBits          : unsigned(log2ceil(ACCUM_BITS + 1) - 1 downto 0);
  signal sAccumCountBitsFlush     : unsigned(log2ceil(ACCUM_BITS + 1) - 1 downto 0);
  signal sFlushValidBits          : unsigned(LAST_BITS_WIDTH - 1 downto 0);
  signal sFlushPending            : std_logic;

  -- FIFO interface
  signal sFifoInData              : std_logic_vector(FIFO_WIDTH - 1 downto 0);
  signal sFifoInValid             : std_logic;
  signal sFifoInReady             : std_logic;
  signal sFifoOutData             : std_logic_vector(FIFO_WIDTH - 1 downto 0);
  signal sFifoOutValid            : std_logic;
  signal sFifoOutReady            : std_logic;
  signal sFifoAlmFull             : std_logic;
  signal sFifoFull                : std_logic;

  -- Skid buffer between FIFO output and Stage 3 consume
  -- Helps timing on FPGAs with poor interconnects
  signal sSkidWord                : std_logic_vector(FIFO_WIDTH - 1 downto 0);
  signal sSkidData                : std_logic_vector(FIFO_BITS - 1 downto 0);
  signal sSkidValid               : std_logic;
  signal sSkidTaken               : std_logic;
  signal sSkidLast                : std_logic;

  -- Stage 3 (FF stuffer + emit) state.
  signal sStuffBuffer             : std_logic_vector(HOLD_BITS - 1 downto 0);
  signal sStuffBufferBits         : unsigned(log2ceil(STATE_BITS + 1) - 1 downto 0);
  signal sStuffBufferLast         : std_logic;
  signal sPrevFF                  : std_logic;
  signal sOutWordReg              : std_logic_vector(OUT_WIDTH - 1 downto 0);
  signal sOutValidReg             : std_logic;
  signal sOutBytesValidReg        : unsigned(log2ceil(OUT_BYTES_PER_CYCLE + 1) - 1 downto 0);
  signal sFlushDone               : std_logic;

  -- Optional full-rate output formatter. Its extra register keeps terminal
  -- padding off the state-feedback/layout critical path. The receiver must
  -- reserve space for two cycles of in-flight beats after iReady deasserts.
  signal sEmitWord                : std_logic_vector(OUT_WIDTH - 1 downto 0);
  signal sEmitValid               : std_logic;
  signal sEmitBytes               : unsigned(log2ceil(OUT_BYTES_PER_CYCLE + 1) - 1 downto 0);
  signal sEmitLast                : std_logic;
  signal sEmitTail                : std_logic_vector(7 downto 0);
  signal sEmitTailBits            : unsigned(2 downto 0);
  signal sEmitPrevFF              : std_logic;

  -- End-of-image terminal beat
  signal sLastPending             : std_logic;

begin

  -- ASSERTIONS --------------------------------------------------------------------
  assert OUT_BYTES_PER_CYCLE >= 4 and OUT_BYTES_PER_CYCLE <= 10
    report "byte_stuffer: supported output lane counts are 4 through 10"
    severity failure;

  assert OUT_WIDTH = OUT_BYTES_PER_CYCLE * 8 and DATA_LANES * 8 <= HOLD_BITS
    report "byte_stuffer: output width must match lanes and fit the holding register"
    severity failure;

  assert BURST_DEPTH > STALL_CUSHION_ENTRIES
    report "byte_stuffer: BURST_DEPTH must exceed STALL_CUSHION_ENTRIES"
    severity failure;

  assert not (sFifoInValid = '1' and sFifoInReady = '0')
    report "byte_stuffer: FIFO write dropped - AlmFull cushion undersized vs stall latency"
    severity failure;

  -- Contract assertions in PSL (temporal, signal-level; active in NVC sims
  -- via --psl, plain comments to synthesis) --------------------------------------
  -- psl default clock is rising_edge(iClk);
  -- psl assert always (iRst = '1' -> next (oWordValid = '0' and oFlushDone = '0')) report "byte_stuffer: reset must clear the output beat and oFlushDone";
  -- psl assert never (oFlushDone = '1' and oWordValid = '0') report "byte_stuffer: oFlushDone only fires on a valid output beat (framer iEoi contract)";
  -- Consecutive EOI beats are legal when queued short frames drain without
  -- a terminal bubble; oFlushDone qualifies each beat, it is not edge-detected.
  -- psl assert always (oWordValid = '1' -> oValidBytes <= OUT_BYTES_PER_CYCLE) report "byte_stuffer: oValidBytes exceeds the per-cycle output cap";
  ---------------------------------------------------------------------------------

  oWord       <= sOutWordReg;
  oWordValid  <= sOutValidReg;
  oValidBytes <= sOutBytesValidReg;
  oFlushDone  <= sFlushDone;
  oAlmostFull <= sFifoAlmFull;

  -------------------------------------------------------------------------------------------------------------------------
  -- INPUT REGISTER
  -------------------------------------------------------------------------------------------------------------------------
  -- Retimes bit_packer output. Latches only on iStall='0' (bit_packer holds its
  -- output across a stall, so one latch == one consume). Not a skid: the
  -- accumulator can't backpressure, so iStall is the only legal gate.

  input_reg_proc : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sWord         <= (others => '0');
        sWordValidLen <= (others => '0');
        sWordValid    <= '0';
        sFlush        <= '0';
      elsif (iStall = '0') then
        sWord         <= iWord;
        sWordValidLen <= iWordValidLen;
        sWordValid    <= iWordValid;
        sFlush        <= iFlush;
      end if;
    end if;

  end process input_reg_proc;

  -------------------------------------------------------------------------------------------------------------------------
  -- STAGE 1: Accumulator
  -------------------------------------------------------------------------------------------------------------------------
  -- Accumulates the variable length word from bit packer until its wide enough to fit
  -- in the data FIFO, pack them as byte-valid + last_flag.
  --
  -- NOTE: Flush can take up to 2 cycles

  stage1_proc : process (iClk) is

    variable vAccumBuffer         : std_logic_vector(ACCUM_BITS - 1 downto 0);
    variable vAccumCountBits      : natural range 0 to ACCUM_BITS;
    variable vAccumCountBitsFlush : natural range 0 to ACCUM_BITS;
    variable vFlushValidBits      : natural range 0 to FIFO_BITS;
    variable vFlushRawBits        : natural range 0 to ACCUM_BITS;
    variable vValidLenInt         : natural;
    variable vFlushPending        : std_logic;
    variable vPadBits             : natural;
    variable vLastFlag            : std_logic;
    variable vWide                : std_logic_vector(ACCUM_BITS - 1 downto 0);
    variable vMaskTop             : std_logic_vector(ACCUM_BITS - 1 downto 0);
    variable vShifted             : std_logic_vector(ACCUM_BITS - 1 downto 0);
    variable vMask                : std_logic_vector(ACCUM_BITS - 1 downto 0);

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sAccumBuffer         <= (others => '0');
        sAccumCountBits      <= (others => '0');
        sAccumCountBitsFlush <= (others => '0');
        sFlushValidBits      <= (others => '0');
        sFlushPending        <= '0';
        sFifoInValid         <= '0';
        sFifoInData          <= (others => '0');
      else
        vAccumBuffer         := sAccumBuffer;
        vAccumCountBits      := to_integer(sAccumCountBits);
        vAccumCountBitsFlush := to_integer(sAccumCountBitsFlush);
        vFlushValidBits      := to_integer(sFlushValidBits);
        vValidLenInt         := to_integer(sWordValidLen);
        vFlushPending        := sFlushPending;

        sFifoInValid    <= '0';
        sFifoInData(FIFO_WIDTH - 1 downto COUNT_LSB) <= (others => '0');

        ---------------------------------------------------------------------------------
        -- WRITE to Accumulator
        ---------------------------------------------------------------------------------
        -- Append input bits (MSB-first)

        if (sWordValid = '1' and iStall = '0') then
          vWide                                              := (others => '0');
          vWide(ACCUM_BITS - 1 downto ACCUM_BITS - IN_WIDTH) := sWord;
          vMaskTop                                           := (others => '0');

          for i in 0 to IN_WIDTH - 1 loop

            if (i < vValidLenInt) then
              vMaskTop(ACCUM_BITS - 1 - i) := '1';
            end if;

          end loop;

          vShifted        := std_logic_vector(shift_right(unsigned(vWide), vAccumCountBits));
          vMask           := std_logic_vector(shift_right(unsigned(vMaskTop), vAccumCountBits));
          vAccumBuffer    := (vAccumBuffer and not vMask) or (vShifted and vMask);
          vAccumCountBits := vAccumCountBits + vValidLenInt;
        end if;

        -- Flush entry: pad sub-byte residue to byte boundary, then pad up to
        -- the next FIFO_BITS multiple so every drain becomes a constant
        -- FIFO_BITS shift downstream.
        if (sFlush = '1' and iStall = '0') then
          assert vFlushPending = '0'
            report "byte_stuffer: iFlush asserted while a flush is already pending"
            severity failure;

          -- Raw valid-bit count at flush (before any padding). The valid bits
          -- of the final FIFO word are derived from this once the FIFO_BITS pad
          -- is known (below) — using the full count here is only correct for a
          -- single-word flush and overflows on a multi-word flush.
          vFlushRawBits := vAccumCountBits;

          -- byte-boundary pad
          if ((vAccumCountBits mod 8) /= 0) then
            vPadBits := 8 - (vAccumCountBits mod 8);

            for j in 0 to 7 loop

              if (j < vPadBits) then
                vAccumBuffer(ACCUM_BITS - 1 - vAccumCountBits) := '0';
                vAccumCountBits                                := vAccumCountBits + 1;
              end if;

            end loop;

          end if;

          -- FIFO_BITS-multiple pseudo-pad (no bit is written)
          if ((vAccumCountBits mod FIFO_BITS) /= 0) then
            vPadBits        := FIFO_BITS - (vAccumCountBits mod FIFO_BITS);
            vAccumCountBits := vAccumCountBits + vPadBits;
          end if;

          vAccumCountBitsFlush := vAccumCountBits;

          -- Real bits carried by the final FIFO word: the raw bits falling in
          -- the last FIFO_BITS slice. Single-word flush -> equals vFlushRawBits;
          -- multi-word flush -> the remainder, always in (0, FIFO_BITS].
          vFlushValidBits := vFlushRawBits + FIFO_BITS - vAccumCountBitsFlush;

          vFlushPending := '1';
        end if;

        ---------------------------------------------------------------------------------
        -- READ from Accumulator to FIFO
        ---------------------------------------------------------------------------------
        -- Single constant-shift drain

        assert not (sFifoFull = '1' and (vFlushPending = '1' or vAccumCountBits >= FIFO_BITS))
          report "byte_stuffer: FIFO full but accumulator didn't stall"
          severity failure;

        if (sFifoFull = '0') then
          if (vFlushPending = '1') then
            if (vAccumCountBitsFlush = FIFO_BITS) then
              vLastFlag       := '1';
              sFifoInData(FIFO_WIDTH - 1 downto COUNT_LSB) <=
                std_logic_vector(to_unsigned(vFlushValidBits, LAST_BITS_WIDTH));
              vFlushPending   := '0';
            else
              vLastFlag := '0';
            end if;

            sFifoInData(COUNT_LSB - 1 downto 0) <= vAccumBuffer(ACCUM_BITS - 1 downto ACCUM_BITS - FIFO_BITS) & vLastFlag;
            sFifoInValid <= '1';

            vAccumBuffer         := std_logic_vector(shift_left(unsigned(vAccumBuffer), FIFO_BITS));
            vAccumCountBits      := vAccumCountBits - FIFO_BITS;
            vAccumCountBitsFlush := vAccumCountBitsFlush - FIFO_BITS;
          elsif (vAccumCountBits >= FIFO_BITS) then
            sFifoInData(COUNT_LSB - 1 downto 0) <= vAccumBuffer(ACCUM_BITS - 1 downto ACCUM_BITS - FIFO_BITS) & '0';
            sFifoInValid <= '1';

            vAccumBuffer    := std_logic_vector(shift_left(unsigned(vAccumBuffer), FIFO_BITS));
            vAccumCountBits := vAccumCountBits - FIFO_BITS;
          end if;
        end if;

        sAccumBuffer         <= vAccumBuffer;
        sAccumCountBits      <= to_unsigned(vAccumCountBits, sAccumCountBits'length);
        sAccumCountBitsFlush <= to_unsigned(vAccumCountBitsFlush, sAccumCountBitsFlush'length);
        sFlushValidBits      <= to_unsigned(vFlushValidBits, sFlushValidBits'length);
        sFlushPending        <= vFlushPending;

        assert vAccumCountBits <= ACCUM_BITS
          report "byte_stuffer: stage 1 accumulator overflow"
          severity failure;
      end if;
    end if;

  end process stage1_proc;

  -------------------------------------------------------------------------------------------------------------------------
  -- STAGE 2: FIFOs (Data and byte valid)
  -------------------------------------------------------------------------------------------------------------------------
  fifo_inst : entity work.olo_base_fifo_sync(rtl)
    generic map (
      WIDTH_G        => FIFO_WIDTH,
      DEPTH_G        => BURST_DEPTH,
      ALMFULLON_G    => true,
      ALMFULLLEVEL_G => ALM_FULL_LEVEL,
      RAMSTYLE_G     => "auto",
      RAMBEHAVIOR_G  => "RBW"
    )
    port map (
      Clk            => iClk,
      Rst            => iRst,
      In_Data        => sFifoInData,
      In_Valid       => sFifoInValid,
      In_Ready       => sFifoInReady,
      Out_Data       => sFifoOutData,
      Out_Valid      => sFifoOutValid,
      Out_Ready      => sFifoOutReady,
      Full           => sFifoFull,
      AlmFull        => sFifoAlmFull,
      Empty          => open,
      AlmEmpty       => open
    );

  -------------------------------------------------------------------------------------------------------------------------
  -- STAGE 3: FF stuffer + output emit
  -------------------------------------------------------------------------------------------------------------------------
  -- Stuffs a '0' bit after a 0xFF byte in data, this is required by the
  -- standard T.87 since a byte 0xFF followed by a bit '1' denotes a
  -- marker and markers aren't allowed on the payload
  --
  -- NOTE: Flush can take up to 2 cycles

  -- Stage 3 drains the skid buffer when it has data and the hold has room.
  sSkidTaken <= '1' when sSkidValid = '1'
                         and sStuffBufferBits <= to_unsigned(HOLD_BITS - FIFO_BITS, sStuffBufferBits'length)
                         and iReady = '1'
                         and sLastPending = '0'
                         and sStuffBufferLast = '0' else
                '0';
  -- Pop FIFO when the skid buffer is empty or being drained this cycle.
  sFifoOutReady <= '1' when sSkidValid = '0' or sSkidTaken = '1' else
                   '0';

  sSkidData <= sSkidWord(COUNT_LSB - 1 downto DATA_LSB);
  sSkidLast <= sSkidWord(LAST_POS);

  skid_proc : process (iClk) is
  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sSkidValid <= '0';
        sSkidWord  <= (others => '0');
      else
        if (sSkidTaken = '1') then
          sSkidValid <= '0';
        end if;
        if (sFifoOutValid = '1' and sFifoOutReady = '1') then
          sSkidWord  <= sFifoOutData;
          sSkidValid <= '1';
        end if;
      end if;
    end if;

  end process skid_proc;

  gen_formatter : if FULL_RATE and OUT_BYTES_PER_CYCLE > DATA_LANES generate
    format_proc : process(iClk) is
      variable word : std_logic_vector(OUT_WIDTH - 1 downto 0);
      variable pad : std_logic_vector(7 downto 0);
      variable count : natural range 0 to OUT_BYTES_PER_CYCLE;
      variable tail_bits : natural range 0 to 7;
    begin
      if rising_edge(iClk) then
        if iRst = '1' then
          sOutWordReg <= (others => '0');
          sOutBytesValidReg <= (others => '0');
          sOutValidReg <= '0';
          sFlushDone <= '0';
        else
          word := sEmitWord;
          count := to_integer(sEmitBytes);
          tail_bits := to_integer(sEmitTailBits);
          pad := (others => '0');
          if sEmitLast = '1' and (tail_bits > 0 or sEmitPrevFF = '1') then
            if sEmitPrevFF = '1' then
              if tail_bits > 0 then
                pad(6 downto 7 - tail_bits) := sEmitTail(7 downto 8 - tail_bits);
              end if;
            elsif tail_bits > 0 then
              pad(7 downto 8 - tail_bits) := sEmitTail(7 downto 8 - tail_bits);
            end if;
            for lane in 0 to DATA_LANES loop
              if lane = count then
                word(OUT_WIDTH - 1 - lane * 8 downto OUT_WIDTH - (lane + 1) * 8) := pad;
              end if;
            end loop;
            count := count + 1;
          end if;
          sOutWordReg <= word;
          sOutBytesValidReg <= to_unsigned(count, sOutBytesValidReg'length);
          sOutValidReg <= sEmitValid;
          sFlushDone <= sEmitLast;
        end if;
      end if;
    end process;
  else generate
    sOutWordReg <= sEmitWord;
    sOutBytesValidReg <= sEmitBytes;
    sOutValidReg <= sEmitValid;
    sFlushDone <= sEmitLast;
  end generate;

  stage3_proc : process (iClk) is

    variable vStuffBuffer     : std_logic_vector(HOLD_BITS - 1 downto 0);
    variable vStuffBufferBits : natural range 0 to HOLD_BITS;
    variable vStuffBufferLast : std_logic;
    variable vPrevFF          : std_logic;

    variable vValidBitsInt  : natural range 0 to FIFO_BITS;
    variable vRefillBuffer  : std_logic_vector(HOLD_BITS - 1 downto 0);
    variable vRefillWord    : std_logic_vector(HOLD_BITS - 1 downto 0);
    variable vRefillMask    : std_logic_vector(HOLD_BITS - 1 downto 0);

    variable vPath          : std_logic_vector(STUFF_LAYOUT'range);
    variable vPreviousByte  : std_logic_vector(7 downto 0);
    variable vTakeShift     : std_logic_vector(CONSUME_BITS'range);
    variable vPathMask      : std_logic_vector(OUT_WIDTH - 1 downto 0);
    variable vCandidateWord : std_logic_vector(OUT_WIDTH - 1 downto 0);
    variable vCandidateByte : std_logic_vector(7 downto 0);
    variable vLaneSelected  : std_logic;
    variable vBytesMask     : unsigned(sEmitBytes'range);
    variable vEmitBytesBits : unsigned(sEmitBytes'range);
    variable vBufferMask    : std_logic_vector(HOLD_BITS - 1 downto 0);
    variable vNextBuffer    : std_logic_vector(HOLD_BITS - 1 downto 0);
    variable vCountMask     : unsigned(log2ceil(HOLD_BITS + 1) - 1 downto 0);
    variable vNextCount     : unsigned(log2ceil(HOLD_BITS + 1) - 1 downto 0);

    variable vEmitData   : std_logic_vector(OUT_WIDTH - 1 downto 0);
    variable vEmitBytes  : natural range 0 to OUT_BYTES_PER_CYCLE;
    variable vEmitLastFF : std_logic;
    variable vPadByte    : std_logic_vector(7 downto 0);

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sStuffBuffer      <= (others => '0');
        sStuffBufferBits  <= (others => '0');
        sStuffBufferLast  <= '0';
        sPrevFF           <= '0';
        sEmitWord       <= (others => '0');
        sEmitValid      <= '0';
        sEmitBytes <= (others => '0');
        sEmitLast        <= '0';
        sLastPending      <= '0';
        sEmitTail         <= (others => '0');
        sEmitTailBits     <= (others => '0');
        sEmitPrevFF       <= '0';
      elsif (sLastPending = '1') then
        -- EOI terminal beat, assembled outside the layout decoder (1 extra cycle,
        -- absorbed by the stage 2 FIFO). Sub-byte residue or dangling 0xFF
        -- emits one padded byte; a byte-aligned clean end emits a 0-byte beat.

        if (iReady = '1') then
          vStuffBufferBits := to_integer(sStuffBufferBits);
          vPadByte         := (others => '0');

          if (sPrevFF = '1') then
            -- Stuff '0' at MSB, up to 7 real bits below it, zero pad.
            if (vStuffBufferBits > 0) then
              vPadByte(6 downto 7 - vStuffBufferBits) := sStuffBuffer(HOLD_BITS - 1 downto HOLD_BITS - vStuffBufferBits);
            end if;
          elsif (vStuffBufferBits > 0) then
            vPadByte(7 downto 8 - vStuffBufferBits) := sStuffBuffer(HOLD_BITS - 1 downto HOLD_BITS - vStuffBufferBits);
          end if;

          if (vStuffBufferBits = 0 and sPrevFF = '0') then
            sEmitWord       <= (others => '0');
            sEmitBytes <= (others => '0');
          else
            sEmitWord(OUT_WIDTH - 1 downto OUT_WIDTH - 8) <= vPadByte;
            sEmitWord(OUT_WIDTH - 9 downto 0)             <= (others => '0');
            sEmitBytes                               <= to_unsigned(1, sEmitBytes'length);
          end if;

          sEmitValid     <= '1';
          sEmitLast       <= '1';
          sLastPending     <= '0';
          sStuffBufferLast <= '0';
          sPrevFF          <= '0';
          sStuffBuffer     <= (others => '0');
          sStuffBufferBits <= (others => '0');
        else
          sEmitValid <= '0';
          sEmitLast   <= '0';
        end if;
      else
        vStuffBuffer     := sStuffBuffer;
        vStuffBufferBits := to_integer(sStuffBufferBits);
        vStuffBufferLast := sStuffBufferLast;
        vPrevFF          := sPrevFF;
        vEmitBytes       := 0;
        vEmitData        := (others => '0');
        sEmitLast       <= '0';

        ----------------------------------------------------------------------
        -- (1) Refill: drain the skid buffer into the holding buffer.
        -- Only the final word may be partial.
        ----------------------------------------------------------------------
        if (sSkidTaken = '1') then
          -- The refill contract allows at most eight old bits. Express the
          -- nine legal alignments as fixed wiring, including a final FIFO word.
          -- Invalid trailing bits may be copied: the real-bit count below
          -- prevents their emission, and the next refill overwrites them.
          vRefillBuffer := (others => '0');
          for offset in 0 to HOLD_BITS - FIFO_BITS loop

            vRefillWord := (others => '0');
            if (offset > 0) then
              vRefillWord(HOLD_BITS - 1 downto HOLD_BITS - offset) :=
                sStuffBuffer(HOLD_BITS - 1 downto HOLD_BITS - offset);
            end if;
            vRefillWord(HOLD_BITS - 1 - offset downto HOLD_BITS - offset - FIFO_BITS) := sSkidData;
            vRefillMask := (others => bool2bit(vStuffBufferBits = offset));
            vRefillBuffer := vRefillBuffer or (vRefillWord and vRefillMask);

          end loop;
          vStuffBuffer := vRefillBuffer;
          if (sSkidLast = '0') then
            vValidBitsInt := FIFO_BITS;
          else
            vValidBitsInt := to_integer(unsigned(sSkidWord(FIFO_WIDTH - 1 downto COUNT_LSB)));
            vStuffBufferLast := '1';
          end if;
          vStuffBufferBits := vStuffBufferBits + vValidBitsInt;
        end if;

        -- Decode each layout independently from fixed windows. No selected
        -- byte or selected consumption count feeds the next lane's predicate.
        for p in STUFF_LAYOUT'range loop
          vPath(p) := bool2bit(vPrevFF = STUFF_LAYOUT(p)(0));
          for lane in 1 to DATA_LANES - 1 loop
            if STUFF_LAYOUT(p)(lane - 1) = '1' then
              vPreviousByte := '0' & vStuffBuffer(HOLD_BITS - 1 - LANE_START(p, lane - 1)
                                                  downto HOLD_BITS - LANE_END(p, lane - 1));
            else
              vPreviousByte := vStuffBuffer(HOLD_BITS - 1 - LANE_START(p, lane - 1)
                                           downto HOLD_BITS - LANE_END(p, lane - 1));
            end if;
            vPath(p) := vPath(p) and
                        bool2bit(bool2bit(vPreviousByte = x"FF") = STUFF_LAYOUT(p)(lane));
          end loop;
        end loop;

        vEmitData      := (others => '0');
        vEmitBytesBits := (others => '0');
        vEmitLastFF    := '0';
        vTakeShift     := (others => '0');

        for p in STUFF_LAYOUT'range loop

          vCandidateWord := (others => '0');
          vPathMask      := (others => vPath(p));

          for lane in 0 to DATA_LANES - 1 loop

            if (STUFF_LAYOUT(p)(lane) = '1') then
              vCandidateByte := '0' & vStuffBuffer(HOLD_BITS - 1 - LANE_START(p, lane)
                                                   downto HOLD_BITS - LANE_END(p, lane));
            else
              vCandidateByte := vStuffBuffer(HOLD_BITS - 1 - LANE_START(p, lane)
                                            downto HOLD_BITS - LANE_END(p, lane));
            end if;
            vCandidateWord(OUT_WIDTH - 1 - lane * 8 downto OUT_WIDTH - (lane + 1) * 8) := vCandidateByte;

            -- Select the last complete lane using constant thresholds. The
            -- end thresholds increase strictly, so exactly one lane wins.
            vLaneSelected := vPath(p) and iReady and
                             bool2bit(vStuffBufferBits >= LANE_END(p, lane));
            if (lane < DATA_LANES - 1) then
              vLaneSelected := vLaneSelected and
                               bool2bit(vStuffBufferBits < LANE_END(p, lane + 1));
            end if;
            vBytesMask     := (others => vLaneSelected);
            vEmitBytesBits := vEmitBytesBits or (to_unsigned(lane + 1, vEmitBytesBits'length) and vBytesMask);
            vEmitLastFF    := vEmitLastFF or (vLaneSelected and bool2bit(vCandidateByte = x"FF"));

            for k in CONSUME_BITS'range loop

              if (CONSUME_BITS(k) = LANE_END(p, lane)) then
                vTakeShift(k) := vTakeShift(k) or vLaneSelected;
              end if;

            end loop;

          end loop;

          vEmitData := vEmitData or (vCandidateWord and vPathMask);

        end loop;

        ----------------------------------------------------------------------
        -- (4) Select fixed shifts and constant count decrements in parallel.
        --     No general barrel shifter follows a late selected integer count.
        --     Include the no-emission case so stalls preserve all input bits.
        ----------------------------------------------------------------------
        vEmitBytes := to_integer(vEmitBytesBits);
        -- No complete first byte: this decision does not depend on the
        -- layout decoder or the selected output count.
        vTakeShift(0) := not iReady or bool2bit(vStuffBufferBits < 7) or
                         (not vPrevFF and bool2bit(vStuffBufferBits = 7));
        vNextBuffer := (others => '0');
        vNextCount  := (others => '0');

        for k in CONSUME_BITS'range loop

          vBufferMask := (others => vTakeShift(k));
          vCountMask  := (others => vTakeShift(k));
          vNextBuffer := vNextBuffer or
                         (std_logic_vector(shift_left(unsigned(vStuffBuffer), CONSUME_BITS(k))) and vBufferMask);
          -- Unsigned arithmetic deliberately wraps on unselected candidates
          -- with too few bits. Their mask is zero; only a legal count wins.
          vNextCount := vNextCount or
                        ((to_unsigned(vStuffBufferBits, vNextCount'length) - CONSUME_BITS(k)) and vCountMask);

        end loop;

        vStuffBuffer     := vNextBuffer;
        vStuffBufferBits := to_integer(vNextCount);
        if (vEmitBytes > 0) then
          vPrevFF := vEmitLastFF;
        end if;

        ----------------------------------------------------------------------
        -- (5) Output register and flush-done / drain entry.
        ----------------------------------------------------------------------
        if (vEmitBytes > 0) then
          sEmitWord       <= vEmitData;
          sEmitBytes <= to_unsigned(vEmitBytes, sEmitBytes'length);
          sEmitValid      <= '1';
        else
          sEmitValid <= '0';
        end if;

        -- Once the last word is consumed and only a sub-byte residue remains
        -- (bits < 8, including the bits=0 clean end), hand off to the
        -- sLastPending branch which assembles the final beat off this path.
        if (iReady = '1'
            and vStuffBufferLast = '1'
            and vStuffBufferBits < 8) then
          if FULL_RATE and OUT_BYTES_PER_CYCLE > DATA_LANES then
            -- A reserved terminal lane removes the per-image drain bubble.
            -- Every ready cycle leaves <8 bits; at most one padded byte is
            -- required, and payload can never occupy the reserved lane.
            sEmitTail <= vStuffBuffer(HOLD_BITS - 1 downto HOLD_BITS - 8);
            sEmitTailBits <= to_unsigned(vStuffBufferBits, sEmitTailBits'length);
            sEmitPrevFF <= vPrevFF;
            sEmitWord <= vEmitData;
            sEmitBytes <= to_unsigned(vEmitBytes, sEmitBytes'length);
            sEmitValid <= '1';
            sEmitLast <= '1';
            vStuffBuffer := (others => '0');
            vStuffBufferBits := 0;
            vStuffBufferLast := '0';
            vPrevFF := '0';
          else
            sLastPending <= '1';
          end if;
        end if;

        sStuffBuffer <= (others => '0');
        sStuffBuffer(HOLD_BITS - 1 downto HOLD_BITS - STATE_BITS) <=
          vStuffBuffer(HOLD_BITS - 1 downto HOLD_BITS - STATE_BITS);
        assert not FULL_RATE or vStuffBufferBits < 8
          report "byte_stuffer: full-rate residue invariant violated" severity failure;
        sStuffBufferBits <= to_unsigned(vStuffBufferBits, sStuffBufferBits'length);
        sStuffBufferLast <= vStuffBufferLast;
        sPrevFF          <= vPrevFF;
      end if;
    end if;

  end process stage3_proc;

end architecture behavioral;
