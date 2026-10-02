-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This file is part of OpenJLS. Available under GPLv3 or a
-- commercial license. See LICENSE and README for details.
--

----------------------------------------------------------------------------------
-- Engineer:    Vitor Mendes Camilo
--
-- Module Name: jls_framer - Behavioral
-- Description:
--
--   Wraps the byte-stuffed compressed payload with JPEG-LS framing markers:
--     SOI + SOF55 + SOS  (header, 25 bytes, before data)
--     EOI = FF D9        (footer, 2 bytes, after data)
--
--   Architecture:
--     - One byte FIFO holds payload bytes. The FF D9 footer is pushed into
--       the FIFO right after byte_stuffer's last word on iEoi, so the output
--       side sees footer bytes as ordinary data and oLast falls out naturally.
--     - Header bytes come from a combinational ROM (get_header_byte). The
--       FIFO never stores header bytes since there are too many of them and
--       we need the FIFO to store new data as the HEADER is being sent.
--     - Output FSM (IDLE / HEADER / DATA) selects header ROM vs FIFO per beat.
--       Splicing handles the partial last header beat (filled from the FIFO)
--       and the partial last data beat (cut at sEndOfImage with oLast).
--     - byte_stuffer is never back-pressured. The FIFO is sized so that
--       pushes always fit under correct upstream behavior.
--
--   iEoi (1-cycle pulse): asserts on byte_stuffer's last word for the image.
--   That cycle the framer pushes (iBsValidBytes byte_stuffer bytes) followed
--   by (FF D9), and latches sEndOfImage to the offset (from FIFO head) of the
--   trailing D9. The output FSM watches this offset; when the bytes popped
--   this cycle reach it, oLast asserts on that beat.
--
--   In-flight EoI offsets are held in a small queue (EOI_FIFO_DEPTH) so that
--   tiny back-to-back images can have multiple D9 markers pending in the FIFO
--   at once. Depth 3 covers the smallest line_buffer-supported image (3x1)
--   pipelined back-to-back; overflow is caught by an assert at push time.
--
--   Image dimensions are fixed at reset by the top level and read directly
--   from the ports without registering.
--
--   IN_WIDTH     : word width from byte_stuffer  (CO_BYTE_STUFFER_OUT_WIDTH)
--   OUT_WIDTH    : final output word width        (CO_OUT_WIDTH_STD)
--   BUFFER_BYTES : payload FIFO depth in bytes (auto-derived; see below)
--
---------------------------------------------------------------------------
-- BUFFER_BYTES sizing (worst-case occupancy)
---------------------------------------------------------------------------
--   Two regimes contribute to peak FIFO occupancy:
--
--   1) iEoi cycle (single-image worst case):
--        DATA pop fires only when vCount >= BYTES_OUT, so vCount_pre at iEoi
--        can sit at BYTES_OUT - 1 without triggering a pop. The iEoi cycle
--        then pushes (iBsValidBytes <= BYTES_IN) plus the 2 footer bytes:
--          vCount_iEoi_max = BYTES_OUT - 1 + BYTES_IN + 2
--
--   2) Back-to-back images (image N+1 starts pushing while N drains):
--        From iEoi cycle T, the FF D9 marker takes
--          D = ceil(vCount_iEoi_max / BYTES_OUT)
--        cycles to reach the FIFO head and emit (oLast fires on the D9 beat).
--        After that, the framer transits to HEADER and emits the 25-byte
--        marker block over
--          N_h = ceil(HEADER_LEN / BYTES_OUT)
--        beats. The first (N_h - 1) HEADER beats pull bytes from the ROM and
--        do not pop the FIFO; the final mixed beat splices ROM + FIFO bytes
--        and pops (BYTES_OUT - HEADER_LEN mod BYTES_OUT) data bytes.
--
--        Worst case: byte_stuffer begins pushing image N+1 the cycle after
--        iEoi and continues at BYTES_IN/cycle throughout. Since BYTES_OUT is
--        normally >= BYTES_IN, image N drains faster than N+1 accumulates,
--        so by the time the mixed HEADER beat fires N's bytes are gone and
--        only N+1's bytes occupy the FIFO. Peak N+1 bytes (after the mixed
--        beat's net push):
--          PEAK_N1 = (D + N_h) * BYTES_IN
--                  - (BYTES_OUT - HEADER_LEN mod BYTES_OUT)
--
--   General formula (peak FIFO occupancy across all phases):
--
--     V_iEoi  = BYTES_OUT + BYTES_IN + 1
--     D       = ceil(V_iEoi    / BYTES_OUT)
--     N_h     = ceil(HEADER_LEN / BYTES_OUT)
--
--     BUFFER_BYTES = max(
--       V_iEoi,                                              (a) iEoi cycle
--       D * BYTES_IN,                                        (b) end of N drain
--       (D + N_h - 1) * BYTES_IN,                            (c) last full hdr beat
--       (D + N_h) * BYTES_IN - (N_h*BYTES_OUT - HEADER_LEN)  (d) after mixed beat
--     )
--
--   For typical configs with BYTES_IN <= BYTES_OUT, term (d) dominates.
--
--   Standard config (BYTES_IN=8, BYTES_OUT=9, HEADER_LEN=25):
--     V_iEoi = 18, D = 2, N_h = 3
--     (a)=18, (b)=16, (c)=32, (d)=(5*8) - (3*9 - 25) = 40 - 2 = 38
--     BUFFER_BYTES = 38
--
--   This also implies that outputting the last bytes after EOI can take several
--   cycles, the image last byte needs to be tracked to assert oLast, padding and
--   oKeep on the correct beat.
--
--   Caveat: the BUFFER_BYTES formula above assumes iReady = '1' steady-state.
--   With sustained downstream backpressure the FIFO has no bound (no upstream
--   stall path). A runtime assert catches overflow in simulation.
----------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.openjls_pkg.all;

library work;
  use work.olo_base_pkg_math.log2ceil;

entity jls_framer is
  generic (
    BITNESS            : natural := CO_BITNESS_STD;
    IN_WIDTH           : natural := CO_BYTE_STUFFER_OUT_WIDTH;
    OUT_WIDTH          : natural := CO_OUT_WIDTH_STD;
    MAX_IMAGE_WIDTH    : natural := 4096;
    MAX_IMAGE_HEIGHT   : natural := 4096;
    -- Cushion between oReady deassertion and BUFFER_BYTES. Covers two
    -- in-flight cycles of byte_stuffer emission (decision + transfer pipeline)
    -- plus the +2 EOI footer push. Worst case: 2*BYTES_IN + 2.
    STALL_MARGIN_BYTES : natural := 2 * math_ceil_div(IN_WIDTH, 8) + 2
  );
  port (
    iClk               : in    std_logic;
    iRst               : in    std_logic;
    -- Image control
    iStart             : in    std_logic;
    iImageWidth        : in    unsigned(log2ceil(MAX_IMAGE_WIDTH + 1) - 1 downto 0);
    iImageHeight       : in    unsigned(log2ceil(MAX_IMAGE_HEIGHT + 1) - 1 downto 0);
    iEoi               : in    std_logic;
    -- Byte stuffer interface
    iWord              : in    std_logic_vector(IN_WIDTH - 1 downto 0);
    iValid             : in    std_logic;
    iByteEnable        : in    unsigned(log2ceil(IN_WIDTH / 8 + 1) - 1 downto 0);
    oReady             : out   std_logic;
    -- Output AXI stream interface
    oWord              : out   std_logic_vector(OUT_WIDTH - 1 downto 0);
    oValid             : out   std_logic;
    oByteEnable        : out   unsigned(log2ceil(OUT_WIDTH / 8 + 1) - 1 downto 0);
    oLast              : out   std_logic;
    iReady             : in    std_logic
  );
end entity jls_framer;

architecture behavioral of jls_framer is

  constant NEAR                 : natural := 0;
  constant BYTES_IN             : natural := IN_WIDTH / 8;
  constant BYTES_OUT            : natural := OUT_WIDTH / 8;
  constant HEADER_LEN           : natural := 25;

  -- Auto-derived FIFO depth (worst-case occupancy; see file header).
  -- BUFFER_BYTES_NOMINAL handles steady-state (iReady='1') traffic.
  -- STALL_MARGIN_BYTES extends the FIFO so oAlmostFull can assert at the
  -- nominal threshold and still absorb in-flight bytes from the upstream
  -- pipeline (Reg5b → bit_packer → byte_stuffer) before the stall reaches.
  constant V_IEOI               : natural := BYTES_OUT + BYTES_IN + 1;
  constant D_DRAIN              : natural := math_ceil_div(V_IEOI, BYTES_OUT);
  constant N_H                  : natural := math_ceil_div(HEADER_LEN, BYTES_OUT);
  -- Header-tail carry: bytes of the final header beat not covered by the
  -- header itself. Expressed via math_min to stay in natural for wide
  -- OUT_WIDTHs, where N_H * BYTES_OUT - HEADER_LEN exceeds the fill.
  constant H_SLACK              : natural := N_H * BYTES_OUT - HEADER_LEN;
  constant BUFFER_BYTES_NOMINAL : natural := math_max(
                                                      math_max(V_IEOI, D_DRAIN * BYTES_IN),
                                                      (D_DRAIN + N_H) * BYTES_IN - math_min(BYTES_IN, H_SLACK));
  constant BUFFER_BYTES         : natural := BUFFER_BYTES_NOMINAL + STALL_MARGIN_BYTES;
  constant BUFFER_WIDTH         : natural := BUFFER_BYTES * 8;

  type fsm_t is (idle, header, data);

  signal sFsmState              : fsm_t;

  -- EoI tracker: queue of footer (D9) byte offsets for in-flight images.
  -- Needed for really small images, like the 4x4 image on T.87 H.3 example
  constant EOI_FIFO_DEPTH       : natural := 2;

  type eoi_offsets_t is array(natural range <>) of natural range 0 to BUFFER_BYTES;

  signal sBuffer                : std_logic_vector(BUFFER_WIDTH - 1 downto 0);
  signal sFifoByteCount         : natural range 0 to BUFFER_BYTES;
  signal sEoiFifo               : eoi_offsets_t(0 to EOI_FIFO_DEPTH - 1);
  signal sEoiCount              : natural range 0 to EOI_FIFO_DEPTH;

  signal sOutWord               : std_logic_vector(OUT_WIDTH - 1 downto 0);
  signal sOutValid              : std_logic;
  signal sOutLast               : std_logic;
  signal sValidBytes            : unsigned(log2ceil(OUT_WIDTH / 8 + 1) - 1 downto 0);

  signal sHeaderByteIdx         : natural range 0 to HEADER_LEN;
  -- Pending-start counter. Holds iStart pulses that arrive while an earlier
  -- image is still being framed. Each EOI dequeues one. Sized to absorb the
  -- worst-case lead of upstream over the framer when byte_stuffer's FIFO is
  -- buffering several images at once.
  constant START_QUEUE_DEPTH    : natural := 4;
  signal   sNextPending         : natural range 0 to START_QUEUE_DEPTH;

  signal sAxiHandshake          : boolean;

  -- Returns the i-th byte of the 25-byte JPEG-LS frame header.
  -- Header layout:
  --   [0-1]   FF D8              SOI
  --   [2-5]   FF F7 00 0B        SOF55 marker + Lf=11
  --   [6]     P                  precision (BITNESS)
  --   [7-8]   Y[15:8] Y[7:0]     image height (runtime)
  --   [9-10]  X[15:8] X[7:0]     image width  (runtime)
  --   [11]    01                 Nf=1
  --   [12-14] 01 11 00           C1=1, H1V1=0x11, Tq1=0
  --   [15-16] FF DA              SOS marker
  --   [17-18] 00 08              Ls=8
  --   [19]    01                 Ns=1
  --   [20-21] 01 00              Cs1=1, Tm1=0
  --   [22]    NEAR
  --   [23-24] 00 00              ILV=0, Al/Ah=0

  function get_header_byte (
    idx    : natural;
    width  : unsigned(15 downto 0);
    height : unsigned(15 downto 0)
  ) return std_logic_vector is
  begin

    case idx is

      when 0 =>

        return x"FF";

      when 1 =>

        return x"D8";

      when 2 =>

        return x"FF";

      when 3 =>

        return x"F7";

      when 4 =>

        return x"00";

      when 5 =>

        return x"0B";

      when 6 =>

        return std_logic_vector(to_unsigned(BITNESS, 8));

      when 7 =>

        return std_logic_vector(height(15 downto 8));

      when 8 =>

        return std_logic_vector(height(7 downto 0));

      when 9 =>

        return std_logic_vector(width(15 downto 8));

      when 10 =>

        return std_logic_vector(width(7 downto 0));

      when 11 =>

        return x"01";

      when 12 =>

        return x"01";

      when 13 =>

        return x"11";

      when 14 =>

        return x"00";

      when 15 =>

        return x"FF";

      when 16 =>

        return x"DA";

      when 17 =>

        return x"00";

      when 18 =>

        return x"08";

      when 19 =>

        return x"01";

      when 20 =>

        return x"01";

      when 21 =>

        return x"00";

      when 22 =>

        return std_logic_vector(to_unsigned(NEAR, 8));

      when 23 =>

        return x"00";

      when 24 =>

        return x"00";

      when others =>

        return x"00";

    end case;

  end function get_header_byte;

  -- Pop head EoI: shift remaining entries down, decrement their offsets by
  -- bytes popped this beat, decrement count.

  procedure pop_eoi (
    variable fifo : inout eoi_offsets_t;
    variable cnt  : inout natural;
    constant emit : in natural
  ) is
  begin

    for k in 0 to EOI_FIFO_DEPTH - 2 loop

      if (k + 1 < cnt) then
        fifo(k) := fifo(k + 1) - emit;
      else
        fifo(k) := 0;
      end if;

    end loop;

    fifo(EOI_FIFO_DEPTH - 1) := 0;
    cnt                      := cnt - 1;

  end procedure pop_eoi;

  -- Decrement all live EoI offsets by bytes popped this beat (no head pop).

  procedure dec_eoi (
    variable fifo : inout eoi_offsets_t;
    constant cnt  : in natural;
    constant emit : in natural
  ) is
  begin

    for k in 0 to EOI_FIFO_DEPTH - 1 loop

      if (k < cnt) then
        fifo(k) := fifo(k) - emit;
      end if;

    end loop;

  end procedure dec_eoi;

begin

  assert IN_WIDTH mod 8 = 0
    report "jls_framer: IN_WIDTH must be a multiple of 8"
    severity failure;

  assert OUT_WIDTH mod 8 = 0
    report "jls_framer: OUT_WIDTH must be a multiple of 8"
    severity failure;

  assert BYTES_OUT >= BYTES_IN + 1
    report "jls_framer: OUT_WIDTH must be at least one byte wider than IN_WIDTH for FIFO stability under absolute worst-case scenario (sustained max-rate output across back-to-back images)"
    severity failure;

  sAxiHandshake <= (iReady and sOutValid) = '1';

  -- Contract assertions in PSL: the output side is an AXI-Stream master —
  -- these hold for any downstream behaviour (active in NVC sims via --psl,
  -- plain comments to synthesis).
  -- psl default clock is rising_edge(iClk);
  -- psl assert always (iRst = '1' -> next (oValid = '0' and oLast = '0')) report "jls_framer: reset must clear the output stream";
  -- psl assert always ((iRst = '0' and oValid = '1' and iReady = '0') -> next (oValid = '1')) report "jls_framer: oValid must hold until the beat is accepted (AXIS)";
  -- psl assert never (oLast = '1' and oValid = '0') report "jls_framer: oLast is only meaningful on a valid beat";

  oWord       <= sOutWord;
  oValid      <= sOutValid;
  oByteEnable <= sValidBytes;
  oLast       <= sOutLast;

  -- Ready/valid handshake with byte_stuffer: deasserts at the nominal
  -- sizing threshold, leaving STALL_MARGIN_BYTES headroom for the
  -- 1-cycle handshake latency (byte_stuffer's registered output).
  oReady <= '1' when sFifoByteCount < BUFFER_BYTES_NOMINAL else
            '0';

  -------------------------------------------------------------------------------------------------------------
  -- SYNCHRONOUS PROCESS
  -------------------------------------------------------------------------------------------------------------
  sync_proc : process (iClk) is

    variable vBuffer            : std_logic_vector(BUFFER_WIDTH - 1 downto 0);
    variable vFifoByteCount     : natural range 0 to BUFFER_BYTES;
    variable vEoiIdxFifo        : eoi_offsets_t(0 to EOI_FIFO_DEPTH - 1);
    variable vEoiCount          : natural range 0 to EOI_FIFO_DEPTH;
    variable vWidth             : unsigned(15 downto 0);
    variable vHeight            : unsigned(15 downto 0);
    variable vHeaderBytesRemain : natural range 0 to HEADER_LEN;
    variable vDataNeededBytes   : natural range 0 to BYTES_OUT;
    variable vEmitDataBytes     : natural range 0 to BYTES_OUT;
    variable vCanEmit           : boolean;
    variable vEoiInBeat         : boolean;
    variable vOffsetI           : natural range 0 to BYTES_OUT;
    variable vNextPending       : natural range 0 to START_QUEUE_DEPTH;

  begin

    if rising_edge(iClk) then
      if (iRst = '1') then
        sFsmState      <= idle;
        sBuffer        <= (others => '0');
        sFifoByteCount <= 0;
        sEoiFifo       <= (others => 0);
        sEoiCount      <= 0;
        sOutWord       <= (others => '0');
        sOutValid      <= '0';
        sOutLast       <= '0';
        sValidBytes    <= (others => '0');
        sHeaderByteIdx <= 0;
        sNextPending   <= 0;
      else
        vBuffer        := sBuffer;
        vFifoByteCount := sFifoByteCount;
        vEoiIdxFifo    := sEoiFifo;
        vEoiCount      := sEoiCount;
        vWidth         := resize(iImageWidth, 16);
        vHeight        := resize(iImageHeight, 16);
        vCanEmit       := sAxiHandshake or sOutValid = '0';
        vNextPending   := sNextPending;

        -- iStart latching: queue starts so back-to-back images can be buffered
        -- in byte_stuffer while framer drains earlier images.
        if (iStart = '1') then
          assert vNextPending < START_QUEUE_DEPTH
            report "jls_framer: iStart dropped (start queue full)"
            severity failure;
          vNextPending := vNextPending + 1;
        end if;

        -----------------------------------------------------------------------------------------------------
        -- READ
        -----------------------------------------------------------------------------------------------------
        -- Beat was consumed
        if (sAxiHandshake) then
          sOutValid <= '0';
          sOutLast  <= '0';
        end if;

        case sFsmState is

          when idle =>

            if (vNextPending > 0) then
              sFsmState      <= header;
              sHeaderByteIdx <= 0;
              vNextPending   := vNextPending - 1;
            end if;

          when header =>

            if (vCanEmit) then
              vHeaderBytesRemain := HEADER_LEN - sHeaderByteIdx;

              if (vHeaderBytesRemain >= BYTES_OUT) then
                -- Full header beat from HEADER ROM

                for i in 0 to BYTES_OUT - 1 loop

                  sOutWord(OUT_WIDTH - 1 - i * 8 downto OUT_WIDTH - (i + 1) * 8) <= get_header_byte(sHeaderByteIdx + i, vWidth, vHeight);

                end loop;

                sValidBytes <= to_unsigned(BYTES_OUT, sValidBytes'length);
                sOutValid   <= '1';
                sOutLast    <= '0';

                if (sHeaderByteIdx + BYTES_OUT = HEADER_LEN) then
                  sFsmState <= data;
                else
                  sHeaderByteIdx <= sHeaderByteIdx + BYTES_OUT;
                end if;
              else
                -- Last partial beat, fill remaining bytes from the DATA FIFO

                vDataNeededBytes := BYTES_OUT - vHeaderBytesRemain;

                -- Check for EOI in the FIFO bytes
                vEoiInBeat := vEoiCount > 0 and vEoiIdxFifo(0) < vDataNeededBytes;
                if (vEoiInBeat) then
                  vEmitDataBytes := vEoiIdxFifo(0) + 1;
                else
                  vEmitDataBytes := vDataNeededBytes;
                end if;

                if (vFifoByteCount >= vEmitDataBytes) then
                  -- FIFO has enough bytes
                  -- Otherwise it'll stall here until it does

                  for i in 0 to BYTES_OUT - 1 loop

                    if (i < vHeaderBytesRemain) then
                      sOutWord(OUT_WIDTH - 1 - i * 8 downto OUT_WIDTH - (i + 1) * 8) <= get_header_byte(sHeaderByteIdx + i, vWidth, vHeight);
                    elsif (i < vHeaderBytesRemain + vEmitDataBytes) then
                      vOffsetI                                                       := i - vHeaderBytesRemain;
                      sOutWord(OUT_WIDTH - 1 - i * 8 downto OUT_WIDTH - (i + 1) * 8) <= vBuffer(BUFFER_WIDTH - 1 - vOffsetI * 8 downto BUFFER_WIDTH - (vOffsetI + 1) * 8);
                    else
                      sOutWord(OUT_WIDTH - 1 - i * 8 downto OUT_WIDTH - (i + 1) * 8) <= (others => '0');
                    end if;

                  end loop;

                  sValidBytes    <= to_unsigned(vHeaderBytesRemain + vEmitDataBytes, sValidBytes'length);
                  sOutValid      <= '1';
                  vBuffer        := std_logic_vector(shift_left(unsigned(vBuffer), vEmitDataBytes * 8));
                  vFifoByteCount := vFifoByteCount - vEmitDataBytes;

                  if (vEoiInBeat) then
                    sOutLast <= '1';
                    pop_eoi(vEoiIdxFifo, vEoiCount, vEmitDataBytes);

                    if (vNextPending > 0) then
                      sFsmState      <= header;
                      sHeaderByteIdx <= 0;
                      vNextPending   := vNextPending - 1;
                    else
                      sFsmState <= idle;
                    end if;
                  else
                    sOutLast  <= '0';
                    dec_eoi(vEoiIdxFifo, vEoiCount, vEmitDataBytes);
                    sFsmState <= data;
                  end if;
                end if;
              end if;
            end if;

          when data =>

            if (vCanEmit) then
              vEoiInBeat := vEoiCount > 0 and vEoiIdxFifo(0) < BYTES_OUT;
              if (vEoiInBeat) then
                vEmitDataBytes := vEoiIdxFifo(0) + 1;
              else
                vEmitDataBytes := BYTES_OUT;
              end if;

              if (vFifoByteCount >= vEmitDataBytes) then

                for i in 0 to BYTES_OUT - 1 loop

                  if (i < vEmitDataBytes) then
                    sOutWord(OUT_WIDTH - 1 - i * 8 downto OUT_WIDTH - (i + 1) * 8) <= vBuffer(BUFFER_WIDTH - 1 - i * 8 downto BUFFER_WIDTH - (i + 1) * 8);
                  else
                    sOutWord(OUT_WIDTH - 1 - i * 8 downto OUT_WIDTH - (i + 1) * 8) <= (others => '0');
                  end if;

                end loop;

                sValidBytes    <= to_unsigned(vEmitDataBytes, sValidBytes'length);
                sOutValid      <= '1';
                vBuffer        := std_logic_vector(shift_left(unsigned(vBuffer), vEmitDataBytes * 8));
                vFifoByteCount := vFifoByteCount - vEmitDataBytes;

                if (vEoiInBeat) then
                  sOutLast <= '1';
                  pop_eoi(vEoiIdxFifo, vEoiCount, vEmitDataBytes);

                  if (vNextPending > 0) then
                    sFsmState      <= header;
                    sHeaderByteIdx <= 0;
                    vNextPending   := vNextPending - 1;
                  else
                    sFsmState <= idle;
                  end if;
                else
                  sOutLast <= '0';
                  dec_eoi(vEoiIdxFifo, vEoiCount, vEmitDataBytes);
                end if;
              end if;
            end if;

        end case;

        -----------------------------------------------------------------------------------------------------
        -- WRITE
        -----------------------------------------------------------------------------------------------------
        if (iValid = '1') then

          for i in 0 to BYTES_IN - 1 loop

            if (i < to_integer(iByteEnable)) then
              vBuffer(BUFFER_WIDTH - 1 - (vFifoByteCount + i) * 8 downto BUFFER_WIDTH - (vFifoByteCount + i + 1) * 8) := iWord(IN_WIDTH - 1 - i * 8 downto IN_WIDTH - (i + 1) * 8);
            end if;

          end loop;

          vFifoByteCount := vFifoByteCount + to_integer(iByteEnable);

          if (iEoi = '1') then
            -- Push FOOTER into the FIFO right after the last data byte
            vBuffer(BUFFER_WIDTH - 1 - vFifoByteCount * 8 downto BUFFER_WIDTH - (vFifoByteCount + 1) * 8)       := x"FF";
            vBuffer(BUFFER_WIDTH - 1 - (vFifoByteCount + 1) * 8 downto BUFFER_WIDTH - (vFifoByteCount + 2) * 8) := x"D9";
            vFifoByteCount                                                                                      := vFifoByteCount + 2;

            assert vEoiCount < EOI_FIFO_DEPTH
              report "jls_framer: EoI FIFO overflow; back-to-back images closer than depth allows"
              severity failure;

            vEoiIdxFifo(vEoiCount) := vFifoByteCount - 1;
            vEoiCount              := vEoiCount + 1;
          end if;
        end if;

        assert vFifoByteCount <= BUFFER_BYTES
          report "jls_framer: payload FIFO overflow (vCount exceeds BUFFER_BYTES; check sizing assumptions or sustained backpressure)"
          severity failure;

        sBuffer        <= vBuffer;
        sFifoByteCount <= vFifoByteCount;
        sEoiFifo       <= vEoiIdxFifo;
        sEoiCount      <= vEoiCount;
        sNextPending   <= vNextPending;
      end if;
    end if;

  end process sync_proc;

end architecture behavioral;
