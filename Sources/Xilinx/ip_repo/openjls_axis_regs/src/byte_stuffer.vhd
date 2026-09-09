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
--     Stage 2 — BRAM-backed sync FIFO
--
--     Stage 3 — FF stuffer + output emit:
--       Refills a holding register using the nine fixed alignments allowed
--       by the refill contract (0..8 old bits). Each cycle forms up to four
--       output bytes by decoding all eight legal stuffing layouts in
--       parallel. Each layout uses fixed bit slices and constant valid-bit
--       thresholds. One-hot selection chooses the output, the last FF state,
--       and a fixed-shift remainder without a serial lane-resolution chain.
--
--       The end-of-image terminal beat (sub-byte residue, a pending stuff
--       bit with no follow-up data, or a byte-aligned clean end) is split
--       into its own cycle via sLastPending: the final byte (or 0-byte beat)
--       is assembled, latched, and emitted on the following beat. Adds at
--       most 1 cycle of latency per image boundary and keeps the pad-byte
--       assembly off the critical path.
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
--   OUT_BYTES_PER_CYCLE : output bytes/cycle; must be 4 (fixed layout table).
--   BURST_DEPTH         : depth of the BRAM-backed FIFO (in wide words).
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
    OUT_BYTES_PER_CYCLE : natural := CO_BYTE_STUFFER_OUT_BYTES_PER_CYCLE; -- Stuffs up to 4 bytes/cycle, not to be changed
    OUT_WIDTH           : natural := CO_BYTE_STUFFER_OUT_WIDTH;
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
  constant LAST_POS               : natural := 0;
  constant DATA_LSB               : natural := 1;
  constant FIFO_WIDTH             : natural := FIFO_BITS + 1;

  -- Sideband byte-valid queue depth: bounds the number of in-flight
  -- last-flag words allowed in the main FIFO simultaneously.
  constant BYTE_VALID_QUEUE_DEPTH : natural := 3;

  -- AlmFull asserts STALL_CUSHION_ENTRIES below Full so the FIFO can absorb
  -- in-flight tokens while the top-level stall signal propagates through its
  -- pipeline (registered AlmFulls + registered sStallLogic = ~4 cycles).
  constant STALL_CUSHION_ENTRIES  : natural := 5;
  constant ALM_FULL_LEVEL         : natural := BURST_DEPTH - STALL_CUSHION_ENTRIES;

  -- Stage 3 holding register: one FIFO pop + 1 byte (deadlock floor). Bits
  -- stored MSB-first (oldest emitted first).
  constant HOLD_BYTES             : natural := FIFO_BYTES + 1;
  constant HOLD_BITS              : natural := HOLD_BYTES * 8;

  -- A stuffed byte starts with zero, so two adjacent output bytes cannot
  -- both stuff. These are all eight possible four-byte layouts, including
  -- both incoming sPrevFF states. A '1' means that lane consumes seven bits.
  type layout_array is array (0 to 7) of std_logic_vector(0 to 3);
  constant STUFF_LAYOUT : layout_array := (
    "0000", "0001", "0010", "0100", "0101", "1000", "1001", "1010"
  );
  type lane_count_array is array (0 to 7, 0 to 3) of natural range 0 to 32;
  constant LANE_START : lane_count_array := (
    (0, 8, 16, 24), (0, 8, 16, 24), (0, 8, 16, 23),
    (0, 8, 15, 23), (0, 8, 15, 23), (0, 7, 15, 23),
    (0, 7, 15, 23), (0, 7, 15, 22)
  );
  constant LANE_END : lane_count_array := (
    (8, 16, 24, 32), (8, 16, 24, 31), (8, 16, 23, 31),
    (8, 15, 23, 31), (8, 15, 23, 30), (7, 15, 23, 31),
    (7, 15, 23, 30), (7, 15, 22, 30)
  );
  type consume_array is array (natural range <>) of natural range 0 to 32;
  constant CONSUME_BITS : consume_array := (0, 7, 8, 15, 16, 22, 23, 24, 30, 31, 32);

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

  -- Final-word valid-bit-count queue (FIFO) signals
  signal sBvQueueInValid          : std_logic;
  signal sBvQueueInData           : std_logic_vector(LAST_BITS_WIDTH - 1 downto 0);
  signal sBvQueueOutReady         : std_logic;
  signal sBvQueueOutData          : std_logic_vector(LAST_BITS_WIDTH - 1 downto 0);

  -- Stage 3 (FF stuffer + emit) state.
  signal sStuffBuffer             : std_logic_vector(HOLD_BITS - 1 downto 0);
  signal sStuffBufferBits         : unsigned(log2ceil(HOLD_BITS + 1) - 1 downto 0);
  signal sStuffBufferLast         : std_logic;
  signal sPrevFF                  : std_logic;
  signal sOutWordReg              : std_logic_vector(OUT_WIDTH - 1 downto 0);
  signal sOutValidReg             : std_logic;
  signal sOutBytesValidReg        : unsigned(log2ceil(OUT_BYTES_PER_CYCLE + 1) - 1 downto 0);
  signal sFlushDone               : std_logic;

  -- End-of-image terminal beat
  signal sLastPending             : std_logic;

begin

  -- ASSERTIONS --------------------------------------------------------------------
  assert OUT_BYTES_PER_CYCLE = 4
    report "byte_stuffer: OUT_BYTES_PER_CYCLE must be 4 (stuffing arrays are hardcoded to 4 lanes)"
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
  -- psl assert always (oFlushDone = '1' -> next (oFlushDone = '0')) report "byte_stuffer: oFlushDone is a strict 1-cycle pulse";
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
        sBvQueueInValid      <= '0';
        sBvQueueInData       <= (others => '0');
      else
        vAccumBuffer         := sAccumBuffer;
        vAccumCountBits      := to_integer(sAccumCountBits);
        vAccumCountBitsFlush := to_integer(sAccumCountBitsFlush);
        vFlushValidBits      := to_integer(sFlushValidBits);
        vValidLenInt         := to_integer(sWordValidLen);
        vFlushPending        := sFlushPending;

        sFifoInValid    <= '0';
        sBvQueueInValid <= '0';

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
              sBvQueueInValid <= '1';
              sBvQueueInData  <= std_logic_vector(to_unsigned(vFlushValidBits, LAST_BITS_WIDTH));
              vFlushPending   := '0';
            else
              vLastFlag := '0';
            end if;

            sFifoInData  <= vAccumBuffer(ACCUM_BITS - 1 downto ACCUM_BITS - FIFO_BITS) & vLastFlag;
            sFifoInValid <= '1';

            vAccumBuffer         := std_logic_vector(shift_left(unsigned(vAccumBuffer), FIFO_BITS));
            vAccumCountBits      := vAccumCountBits - FIFO_BITS;
            vAccumCountBitsFlush := vAccumCountBitsFlush - FIFO_BITS;
          elsif (vAccumCountBits >= FIFO_BITS) then
            sFifoInData  <= vAccumBuffer(ACCUM_BITS - 1 downto ACCUM_BITS - FIFO_BITS) & '0';
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

  -- Read last-word valid-bit-count FIFO on Last word
  sBvQueueOutReady <= sSkidTaken and sSkidLast;

  byte_valid_fifo_inst : entity work.olo_base_fifo_sync(rtl)
    generic map (
      WIDTH_G       => LAST_BITS_WIDTH,
      DEPTH_G       => BYTE_VALID_QUEUE_DEPTH,
      RAMSTYLE_G    => "auto",
      RAMBEHAVIOR_G => "RBW"
    )
    port map (
      Clk           => iClk,
      Rst           => iRst,
      In_Data       => sBvQueueInData,
      In_Valid      => sBvQueueInValid,
      In_Ready      => open,
      Out_Data      => sBvQueueOutData,
      Out_Valid     => open,
      Out_Ready     => sBvQueueOutReady,
      Full          => open,
      Empty         => open
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
                         and sLastPending = '0' else
                '0';
  -- Pop FIFO when the skid buffer is empty or being drained this cycle.
  sFifoOutReady <= '1' when sSkidValid = '0' or sSkidTaken = '1' else
                   '0';

  sSkidData <= sSkidWord(FIFO_WIDTH - 1 downto DATA_LSB);
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

  stage3_proc : process (iClk) is

    variable vStuffBuffer     : std_logic_vector(HOLD_BITS - 1 downto 0);
    variable vStuffBufferBits : natural range 0 to HOLD_BITS;
    variable vStuffBufferLast : std_logic;
    variable vPrevFF          : std_logic;

    variable vValidBitsInt  : natural range 0 to FIFO_BITS;
    variable vRefillBuffer  : std_logic_vector(HOLD_BITS - 1 downto 0);
    variable vRefillWord    : std_logic_vector(HOLD_BITS - 1 downto 0);
    variable vRefillMask    : std_logic_vector(HOLD_BITS - 1 downto 0);

    -- Fixed-window FF flags used to decode the layout. The final emitted
    -- lane's FF state is computed independently in the candidate loop.
    variable ff0        : std_logic; -- offset 0
    variable ff1a, ff1b : std_logic; -- offsets 7, 8
    variable ff2a, ff2b : std_logic; -- offsets 15, 16

    variable vPath          : std_logic_vector(0 to 7);
    variable vTakeShift     : std_logic_vector(CONSUME_BITS'range);
    variable vPathMask      : std_logic_vector(OUT_WIDTH - 1 downto 0);
    variable vCandidateWord : std_logic_vector(OUT_WIDTH - 1 downto 0);
    variable vCandidateByte : std_logic_vector(7 downto 0);
    variable vLaneSelected  : std_logic;
    variable vBytesMask     : unsigned(sOutBytesValidReg'range);
    variable vEmitBytesBits : unsigned(sOutBytesValidReg'range);
    variable vBufferMask    : std_logic_vector(HOLD_BITS - 1 downto 0);
    variable vNextBuffer    : std_logic_vector(HOLD_BITS - 1 downto 0);
    variable vCountMask     : unsigned(sStuffBufferBits'range);
    variable vNextCount     : unsigned(sStuffBufferBits'range);

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
        sOutWordReg       <= (others => '0');
        sOutValidReg      <= '0';
        sOutBytesValidReg <= (others => '0');
        sFlushDone        <= '0';
        sLastPending      <= '0';
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
            sOutWordReg       <= (others => '0');
            sOutBytesValidReg <= (others => '0');
          else
            sOutWordReg(OUT_WIDTH - 1 downto OUT_WIDTH - 8) <= vPadByte;
            sOutWordReg(OUT_WIDTH - 9 downto 0)             <= (others => '0');
            sOutBytesValidReg                               <= to_unsigned(1, sOutBytesValidReg'length);
          end if;

          sOutValidReg     <= '1';
          sFlushDone       <= '1';
          sLastPending     <= '0';
          sStuffBufferLast <= '0';
          sPrevFF          <= '0';
          sStuffBuffer     <= (others => '0');
          sStuffBufferBits <= (others => '0');
        else
          sOutValidReg <= '0';
          sFlushDone   <= '0';
        end if;
      else
        vStuffBuffer     := sStuffBuffer;
        vStuffBufferBits := to_integer(sStuffBufferBits);
        vStuffBufferLast := sStuffBufferLast;
        vPrevFF          := sPrevFF;
        vEmitBytes       := 0;
        vEmitData        := (others => '0');
        sFlushDone       <= '0';

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
            vValidBitsInt := to_integer(unsigned(sBvQueueOutData));
            vStuffBufferLast := '1';
          end if;
          vStuffBufferBits := vStuffBufferBits + vValidBitsInt;
        end if;

        ----------------------------------------------------------------------
        -- (2) Parallel-precompute the layout decoder's fixed-window FF flags.
        ----------------------------------------------------------------------
        ff0  := bool2bit(vStuffBuffer(HOLD_BITS - 1 downto HOLD_BITS - 8) = x"FF");
        ff1a := bool2bit(vStuffBuffer(HOLD_BITS - 8 downto HOLD_BITS - 15) = x"FF");
        ff1b := bool2bit(vStuffBuffer(HOLD_BITS - 9 downto HOLD_BITS - 16) = x"FF");
        ff2a := bool2bit(vStuffBuffer(HOLD_BITS - 16 downto HOLD_BITS - 23) = x"FF");
        ff2b := bool2bit(vStuffBuffer(HOLD_BITS - 17 downto HOLD_BITS - 24) = x"FF");

        ----------------------------------------------------------------------
        -- (3) Decode all layouts in parallel. Each predicate depends only on
        --     the incoming FF state and fixed-window comparisons, never on
        --     a byte or consumption count selected by another lane.
        ----------------------------------------------------------------------
        vPath(0) := not vPrevFF and not ff0 and not ff1b and not ff2b;
        vPath(1) := not vPrevFF and not ff0 and not ff1b and     ff2b;
        vPath(2) := not vPrevFF and not ff0 and     ff1b;
        vPath(3) := not vPrevFF and     ff0 and not ff2a;
        vPath(4) := not vPrevFF and     ff0 and     ff2a;
        vPath(5) :=     vPrevFF and not ff1a and not ff2a;
        vPath(6) :=     vPrevFF and not ff1a and     ff2a;
        vPath(7) :=     vPrevFF and     ff1a;

        vEmitData      := (others => '0');
        vEmitBytesBits := (others => '0');
        vEmitLastFF    := '0';
        vTakeShift     := (others => '0');

        for p in STUFF_LAYOUT'range loop

          vCandidateWord := (others => '0');
          vPathMask      := (others => vPath(p));

          for lane in 0 to OUT_BYTES_PER_CYCLE - 1 loop

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
            if (lane < OUT_BYTES_PER_CYCLE - 1) then
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
          sOutWordReg       <= vEmitData;
          sOutBytesValidReg <= to_unsigned(vEmitBytes, sOutBytesValidReg'length);
          sOutValidReg      <= '1';
        else
          sOutValidReg <= '0';
        end if;

        -- Once the last word is consumed and only a sub-byte residue remains
        -- (bits < 8, including the bits=0 clean end), hand off to the
        -- sLastPending branch which assembles the final beat off this path.
        if (iReady = '1'
            and vStuffBufferLast = '1'
            and vStuffBufferBits < 8) then
          sLastPending <= '1';
        end if;

        sStuffBuffer     <= vStuffBuffer;
        sStuffBufferBits <= to_unsigned(vStuffBufferBits, sStuffBufferBits'length);
        sStuffBufferLast <= vStuffBufferLast;
        sPrevFF          <= vPrevFF;
      end if;
    end if;

  end process stage3_proc;

end architecture behavioral;
