#!/usr/bin/env python3
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
"""byte_stuffer byte order, split at the FIFO (full proofs instead of the bounded whole-module check).

  wr   stage 1: one tracked input bit is written at the same word-stream position; pad bits are zero; the BV queue
       gets the last word's real-bit count with that word
  fifo the main FIFO (depth BURST) and the BV queue (depth CO_MAX_IMAGES_IN_FLIGHT) return every entry in order
  rd   skid + stage 3: a word stream with those properties leaves de-stuffed in order (the stream.py checker)
Each part is a k-induction proof over helper invariants; each also runs a known-bad copy (BMC, must fail).
python3 bs_split.py [part ...]; env BS_BITS ("8 12 16"), BS_TIMEOUT (s), BS_WORK, BS_THREADS.
"""
import json, os, re, shutil, sys, multiprocessing as mp
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Common"))
from prep import prep, contracts
from flow import BASE, OLO, S, RESULTS, run

WORK = Path(os.environ.get("BS_WORK", "/tmp/feq_bs_split"))
TIMEOUT = int(os.environ.get("BS_TIMEOUT", 1800))
# Position counters saturate here; a + b stays inside the 32-bit VHDL integer. Images past 2^30 bits (128 MB of
# coded data) keep the tracked-bit checks below the cap but lose the end-of-image checks
CAP = 2**30 - 1
FLIGHT = int(re.search(r"CO_MAX_IMAGES_IN_FLIGHT\s*:\s*natural\s*:=\s*(\d+)", (S / "openjls_pkg.vhd").read_text())[1])
BITS = [int(b) for b in os.environ.get("BS_BITS", "8 12 16").split()]

DECL = """
  constant CAP : natural := @CAP@;
  attribute anyconst : boolean;
  attribute anyseq : boolean;
  signal sInitF : std_logic := '1';
  signal tI : natural range 0 to 3;
  signal tN : natural range 0 to CAP;
  attribute anyconst of tI, tN : signal is true;
  signal fBad : std_logic;
  function fsat (a, b : natural) return natural is
  begin
    if a + b > CAP then return CAP; end if;
    return a + b;
  end function;
  function tail_zero (w : std_logic_vector; n : unsigned) return boolean is
  begin
    for i in w'range loop
      if i < w'length - to_integer(n) and w(i) /= '0' then return false; end if;
    end loop;
    return true;
  end function;
"""

# Stage 1 and the input side; FIFO and BV queue cut. Full tied low: the proved RTL assert (byte_stuffer.vhd:329)
# says Full is only high when no write is due, so it never changes stage 1
WR_DECL = DECL + """
  signal inImg, wImg : natural range 0 to 4;
  signal inBit, wBit : natural range 0 to CAP;
  signal tV, tVal, tEnd : std_logic;
  signal tLen : natural range 0 to CAP;
"""
WR_BODY = """
  sInitF <= '0' when rising_edge(iClk);

  sFifoFull <= '0'; sFifoAlmFull <= '0'; sFifoInReady <= '1';
  sFifoOutValid <= '0'; sFifoOutData <= (others => '0'); sBvQueueOutData <= (others => '0');

  p_in : process (iClk) is
    variable vLen : natural;
  begin
    if rising_edge(iClk) then
      vLen := to_integer(iWordValidLen);
      if iRst = '1' then
        inImg <= 0; inBit <= 0; tV <= '0'; tVal <= '0'; tEnd <= '0'; tLen <= 0;
      elsif iStall = '0' and iWordValid = '1' then
        if inImg = tI then
          if tN >= inBit and tN < inBit + vLen then
            tV <= '1'; tVal <= iWord(IN_WIDTH - 1 - (tN - inBit));
          end if;
          if iFlush = '1' then
            tEnd <= '1'; tLen <= fsat(inBit, vLen);
          end if;
        end if;
        if iFlush = '1' then
          inBit <= 0; inImg <= inImg + 1 when inImg < 4 else 4;
        else
          inBit <= fsat(inBit, vLen);
        end if;
      end if;
    end if;
  end process p_in;

  p_wchk : process (all) is
    variable vB, vBad : std_logic;
  begin
    vBad := '0';
    if sFifoInValid = '1' and wImg = tI then
      if tN >= wBit and tN < wBit + FIFO_BITS then
        vB := sFifoInData(FIFO_BITS - (tN - wBit) - @OFF@);
        if tEnd = '1' and tN >= tLen then
          if vB /= '0' then vBad := '1'; end if;
        elsif tV = '0' or vB /= tVal then
          vBad := '1';
        end if;
      end if;
      if sFifoInData(LAST_POS) = '1' then
        -- Saturating sums: tLen = min(length, CAP) on both sides of the split
        if tEnd = '0' or sBvQueueInValid = '0' or (wBit < CAP and tLen <= wBit) or tLen > fsat(wBit, FIFO_BITS)
           or unsigned(sBvQueueInData) = 0 or unsigned(sBvQueueInData) > FIFO_BITS
           or fsat(wBit, to_integer(unsigned(sBvQueueInData))) /= tLen then
          vBad := '1';
        end if;
      elsif tEnd = '1' and tLen < CAP and wBit + FIFO_BITS >= tLen then
        vBad := '1';
      end if;
    end if;
    if sBvQueueInValid = '1' and not (sFifoInValid = '1' and sFifoInData(LAST_POS) = '1') then
      vBad := '1';
    end if;
    fBad <= vBad;
  end process p_wchk;

  p_wreg : process (iClk) is
  begin
    if rising_edge(iClk) then
      if iRst = '1' then
        wImg <= 0; wBit <= 0;
      elsif sFifoInValid = '1' then
        if sFifoInData(LAST_POS) = '1' then
          wBit <= 0; wImg <= wImg + 1 when wImg < 4 else 4;
        else
          wBit <= fsat(wBit, FIFO_BITS);
        end if;
      end if;
    end if;
  end process p_wreg;

  -- psl assume always (sInitF = '1' -> iRst = '1');
  -- psl assume always (iWordValidLen <= IN_WIDTH and (iWordValid = '0' or (iWordValidLen > 0 and tail_zero(iWord, iWordValidLen))));
  -- psl assume always (iFlush = '1' -> iWordValid = '1');
  -- RTL precondition, proved by the rtl_asserts byte_stuffer check (no flush while one is pending)
  -- psl assume always ((sFlush = '1' and iStall = '0') -> sFlushPending = '0');
  -- psl assume always (tN < CAP - 2 * IN_WIDTH);
  -- psl wr_ok : assert always ((sInitF = '0' and iRst = '0') -> fBad = '0');
"""

# Helper invariants for wr (k-induction): the input register and the accumulator against the input and write
# counters. While a flush is pending the accumulator holds the closed image (sAccumCountBitsFlush bits, the last
# slice with sFlushValidBits real bits) and then the head of the next one
WR_HELP_DECL = """
  signal rgImg : natural range 0 to 4;
  signal rgBit : natural range 0 to CAP;
  signal h : std_logic_vector(0 to 5);
  function isat (a : natural) return natural is
  begin
    if a >= 4 then return 4; end if;
    return a + 1;
  end function;
"""
WR_HELP = """
  p_ghost : process (iClk) is
  begin
    if rising_edge(iClk) then
      if iRst = '1' then
        rgImg <= 0; rgBit <= 0;
      elsif iStall = '0' and iWordValid = '1' then
        rgImg <= inImg; rgBit <= inBit;
      end if;
    end if;
  end process p_ghost;

  p_help : process (all) is
    variable c, cf, fv, ln, hd, aBase, eImg, eBit : natural;
    variable aImg : natural range 0 to 4;
    variable v : std_logic_vector(h'range);
    variable ex : std_logic;
  begin
    c := to_integer(sAccumCountBits); cf := to_integer(sAccumCountBitsFlush);
    fv := to_integer(sFlushValidBits); ln := to_integer(sWordValidLen);
    v := (others => '1');
    -- accumulator position: the write counters plus the word in the output register
    aImg := wImg; aBase := wBit;
    if sFifoInValid = '1' then
      if sFifoInData(LAST_POS) = '1' then aImg := isat(wImg); aBase := 0; else aBase := fsat(wBit, FIFO_BITS); end if;
    end if;
    -- h0: input register and accumulator bookkeeping
    if ln > IN_WIDTH or (sFlush = '1' and sWordValid = '0') then v(0) := '0'; end if;
    for i in 0 to IN_WIDTH - 1 loop
      if sWordMask(IN_WIDTH - 1 - i) /= bool2bit(i < ln) then v(0) := '0'; end if;
      if sWordValid = '1' and i >= ln and sWord(IN_WIDTH - 1 - i) /= '0' then v(0) := '0'; end if;
    end loop;
    if sWordValid = '1' and ln = 0 then v(0) := '0'; end if;
    if sCountGeFifo /= (c >= FIFO_BITS) then v(0) := '0'; end if;
    if c < FIFO_BITS and to_integer(sNeedBits) /= FIFO_BITS - c then v(0) := '0'; end if;
    if c >= FIFO_BITS and to_integer(sNeedBits) /= 1 then v(0) := '0'; end if;
    -- A flush writes its first word when taken, so at most the last word is left pending
    if sFlushPending = '0' and c > FIFO_BITS then v(0) := '0'; end if;
    if sFlushPending = '1' and (c /= FIFO_BITS or cf /= FIFO_BITS or fv = 0 or fv > FIFO_BITS) then v(0) := '0'; end if;
    -- h1: accumulator bits past the count are zero
    for i in 0 to ACCUM_BITS - 1 loop
      if i >= c and sAccumBuffer(ACCUM_BITS - 1 - i) /= '0' then v(1) := '0'; end if;
    end loop;
    -- h2: input and register positions follow the accumulator
    if sFlushPending = '1' then hd := c - cf; eImg := isat(aImg); eBit := hd;
    else eImg := aImg; eBit := fsat(aBase, c); end if;
    if sWordValid = '1' then
      if rgImg /= eImg or rgBit /= eBit then v(2) := '0'; end if;
      if sFlush = '1' then eImg := isat(rgImg); eBit := 0; else eBit := fsat(rgBit, ln); end if;
    end if;
    if inImg /= eImg or inBit /= eBit then v(2) := '0'; end if;
    -- h3: tracked-image bookkeeping
    if tEnd /= bool2bit(inImg > tI) then v(3) := '0'; end if;
    if tV /= bool2bit((inImg = tI and tN < inBit) or (inImg > tI and tN < tLen)) then v(3) := '0'; end if;
    if tEnd = '1' and aImg = tI then
      if sFlushPending = '1' and tLen /= fsat(aBase, cf - FIFO_BITS + fv) then v(3) := '0'; end if;
      if sFlushPending = '0' and not (sWordValid = '1' and sFlush = '1' and rgImg = tI and tLen = fsat(rgBit, ln)) then
        v(3) := '0';
      end if;
    end if;
    if tEnd = '1' and sWordValid = '1' and sFlush = '1' and rgImg = tI and tLen /= fsat(rgBit, ln) then v(3) := '0'; end if;
    -- h4: tracked bit in the input register
    if sWordValid = '1' and rgImg = tI and tN >= rgBit and tN < rgBit + ln then
      if sWord(IN_WIDTH - 1 - (tN - rgBit)) /= tVal then v(4) := '0'; end if;
    end if;
    -- h5: tracked bit in the accumulator (closed image, then the next image's head)
    ex := '0' when tEnd = '1' and tN >= tLen else tVal;
    if aImg = tI and tN >= aBase then
      if (sFlushPending = '1' and tN - aBase < cf) or (sFlushPending = '0' and tN - aBase < c) then
        if sAccumBuffer(ACCUM_BITS - 1 - (tN - aBase)) /= ex then v(5) := '0'; end if;
      end if;
    end if;
    if sFlushPending = '1' and isat(aImg) = tI and tN < c - cf then
      if sAccumBuffer(ACCUM_BITS - 1 - cf - tN) /= tVal then v(5) := '0'; end if;
    end if;
    h <= v;
  end process p_help;
""" + "\n".join(f"  -- psl whelp{i} : assert always ((sInitF = '0' and iRst = '0') -> h({i}) = '1');" for i in range(6)) + "\n"

# Skid + stage 3; FIFO and BV queue outputs free, popped words meet the wr guarantees for the tracked bit
RD_DECL = DECL + """
  signal fOV : std_logic;
  signal fOD : std_logic_vector(FIFO_WIDTH - 1 downto 0);
  signal fBV : std_logic_vector(LAST_BITS_WIDTH - 1 downto 0);
  attribute anyseq of fOV, fOD, fBV : signal is true;
  signal tVal : std_logic;
  signal tLen : natural range 1 to CAP;
  attribute anyconst of tVal, tLen : signal is true;
  signal fPop, fOk, tV, tEnd : std_logic;
  signal rImg, sImg : natural range 0 to 4;
  signal rBit, rLast : natural range 0 to CAP;
  signal outImg, nOutImg : natural range 0 to 4;
  signal outBit, nOutBit, dBefore, nDBefore : natural range 0 to CAP;
  signal oPrevFF, nPrevFF, lbStuffed, nLbStuffed : std_logic;
"""
RD_BODY = """
  sInitF <= '0' when rising_edge(iClk);
  sFifoFull <= '0'; sFifoAlmFull <= '0'; sFifoInReady <= '1';
  sFifoOutValid <= fOV; sFifoOutData <= fOD; sBvQueueOutData <= fBV;
  fPop <= fOV and sFifoOutReady;

  p_rchk : process (all) is
    variable vOk : std_logic;
  begin
    vOk := '1';
    if fPop = '1' and rImg = tI then
      if tN >= rBit and tN < rBit + FIFO_BITS then
        if tN < tLen and fOD(FIFO_BITS - (tN - rBit)) /= tVal then vOk := '0'; end if;
        if tN >= tLen and fOD(FIFO_BITS - (tN - rBit)) /= '0' then vOk := '0'; end if;
      end if;
      if fOD(LAST_POS) = '1' then
        if (rBit < CAP and tLen <= rBit) or tLen > fsat(rBit, FIFO_BITS) then vOk := '0'; end if;
      elsif tLen < CAP and rBit + FIFO_BITS >= tLen then
        vOk := '0';
      end if;
    end if;
    if sBvQueueOutReady = '1' and sImg = tI and fsat(rLast, to_integer(unsigned(fBV))) /= tLen then vOk := '0'; end if;
    fOk <= vOk;
  end process p_rchk;

  p_rreg : process (iClk) is
  begin
    if rising_edge(iClk) then
      if iRst = '1' then
        rImg <= 0; rBit <= 0; rLast <= 0; sImg <= 0; tV <= '0'; tEnd <= '0';
      else
        if fPop = '1' then
          if rImg = tI and tN >= rBit and tN < rBit + FIFO_BITS and tN < tLen then tV <= '1'; end if;
          if fOD(LAST_POS) = '1' then
            if rImg = tI then tEnd <= '1'; rLast <= rBit; end if;
            rBit <= 0; rImg <= rImg + 1 when rImg < 4 else 4;
          else
            rBit <= fsat(rBit, FIFO_BITS);
          end if;
        end if;
        if sBvQueueOutReady = '1' then sImg <= sImg + 1 when sImg < 4 else 4; end if;
      end if;
    end if;
  end process p_rreg;

  -- De-stuffer (stream.py): walks the beat's bytes from the top
  p_out : process (all) is
    variable vB    : std_logic_vector(7 downto 0);
    variable vD, vDb : natural range 0 to CAP;
    variable vPrev, vLbS, vBad : std_logic;
    variable vTop  : natural;
  begin
    vD := outBit; vPrev := oPrevFF; vDb := dBefore; vLbS := lbStuffed; vBad := '0';
    if sOutValidReg = '1' then
      for k in 0 to 3 loop
        if k < to_integer(sOutBytesValidReg) then
          vB := sOutWordReg(31 - 8 * k downto 24 - 8 * k);
          vDb := vD; vLbS := vPrev;
          vTop := 7;
          if vPrev = '1' and @SKIP@ then
            vTop := 6;
            if vB(7) /= '0' then vBad := '1'; end if;
          end if;
          for b in 7 downto 0 loop
            if b <= vTop then
              if outImg = tI and vD = tN then
                if tN >= tLen then
                  if vB(b) /= '0' then vBad := '1'; end if;
                elsif tV = '0' or vB(b) /= tVal then
                  vBad := '1';
                end if;
              end if;
              vD := fsat(vD, 1);
            end if;
          end loop;
          vPrev := '1' when vB = x"FF" else '0';
        end if;
      end loop;
    end if;
    nOutImg <= outImg; nOutBit <= vD; nPrevFF <= vPrev; nDBefore <= vDb; nLbStuffed <= vLbS;
    if sFlushDone = '1' then
      if outImg = tI and (tEnd = '0' or (tLen < CAP - 16 and
          (vPrev = '1' or vD < tLen or (vDb >= tLen and vLbS = '0')))) then
        vBad := '1';
      end if;
      nOutImg <= outImg + 1 when outImg < 4 else 4;
      nOutBit <= 0; nPrevFF <= '0'; nDBefore <= 0; nLbStuffed <= '0';
    end if;
    fBad <= vBad;
  end process p_out;

  p_out_reg : process (iClk) is
  begin
    if rising_edge(iClk) then
      if iRst = '1' then
        outImg <= 0; outBit <= 0; oPrevFF <= '0'; dBefore <= 0; lbStuffed <= '0';
      else
        outImg <= nOutImg; outBit <= nOutBit; oPrevFF <= nPrevFF; dBefore <= nDBefore; lbStuffed <= nLbStuffed;
      end if;
    end if;
  end process p_out_reg;

  -- psl assume always (sInitF = '1' -> iRst = '1');
  -- psl assume always (fOk = '1');
  -- psl assume always (unsigned(fBV) >= 1 and unsigned(fBV) <= FIFO_BITS);
  -- psl assume always (tLen >= 1);
  -- psl assume always (tN < CAP - 2 * IN_WIDTH);
  -- psl rd_ok : assert always ((sInitF = '0' and iRst = '0') -> fBad = '0');
"""

# Helper invariants for rd (k-induction): ghost positions of the skid word and the stuff buffer, tied to the
# pop counters on one side and the de-stuffer on the other
RD_HELP_DECL = """
  signal skImg, bufImg : natural range 0 to 4;
  signal skBase, bufEnd : natural range 0 to CAP;
  signal h : std_logic_vector(0 to 7);
  function isat (a : natural) return natural is
  begin
    if a >= 4 then return 4; end if;
    return a + 1;
  end function;
"""
RD_HELP = """
  p_ghost : process (iClk) is
  begin
    if rising_edge(iClk) then
      if iRst = '1' then
        skImg <= 0; skBase <= 0; bufImg <= 0; bufEnd <= 0;
      else
        if fPop = '1' then skImg <= rImg; skBase <= rBit; end if;
        if sLastPending = '1' then
          if iReady = '1' then bufImg <= isat(bufImg); bufEnd <= 0; end if;
        elsif sSkidTaken = '1' then
          if sSkidLast = '1' then bufEnd <= fsat(bufEnd, to_integer(unsigned(fBV)));
          else bufEnd <= fsat(bufEnd, FIFO_BITS); end if;
        end if;
      end if;
    end if;
  end process p_ghost;

  p_help : process (all) is
    variable c : natural;
    variable w : std_logic;
    variable v : std_logic_vector(h'range);
    function ex (n : natural) return std_logic is
    begin
      if n < tLen then return tVal; end if;
      return '0';
    end function;
  begin
    c := to_integer(sStuffBufferBits);
    v := (others => '1');
    -- h0: count, its one-hot and room decodes; final-beat state
    if c > HOLD_BITS or (sSkidRoom = '1') /= (c <= HOLD_BITS - FIFO_BITS) then v(0) := '0'; end if;
    for i in sCountIs'range loop
      if (sCountIs(i) = '1') /= (c = i) then v(0) := '0'; end if;
    end loop;
    if sLastPending = '1' and (sStuffBufferLast = '0' or c >= 8) then v(0) := '0'; end if;
    if sOutBytesValidReg > 4 or (sFlushDone = '1' and sOutValidReg = '0') then v(0) := '0'; end if;
    -- h1: FF flags of the buffer and of the skid word
    -- ff_flags_ok with fixed loop bounds (GHDL synth)
    for j in 0 to HOLD_BITS - 1 loop
      if j + 8 <= c or sStuffBufferLast = '0' then
        w := '1';
        for k in 0 to 7 loop
          if j + k < HOLD_BITS and j + k < c and sStuffBuffer(HOLD_BITS - 1 - j - k) /= '1' then w := '0'; end if;
        end loop;
        if sFF(j) /= w then v(1) := '0'; end if;
      end if;
    end loop;
    if sSkidValid = '1' then
      for i in 0 to FIFO_BITS - 1 loop
        if sSkidFF(i) /= ones_window(sSkidData, i, math_min(i + 8, FIFO_BITS)) then v(1) := '0'; end if;
      end loop;
      for m in 0 to 7 loop
        if sSkidPre(m) /= ones_window(sSkidData, 0, m) then v(1) := '0'; end if;
      end loop;
    end if;
    -- h2: pop counters against the skid and buffer ghosts
    if sSkidValid = '1' then
      if sSkidLast = '0' and (rImg /= skImg or rBit /= fsat(skBase, FIFO_BITS)) then v(2) := '0'; end if;
      if sSkidLast = '1' and (rImg /= isat(skImg) or rBit /= 0) then v(2) := '0'; end if;
      if sStuffBufferLast = '0' and (skImg /= bufImg or skBase /= bufEnd) then v(2) := '0'; end if;
      if sStuffBufferLast = '1' and (skImg /= isat(bufImg) or skBase /= 0) then v(2) := '0'; end if;
    else
      if sStuffBufferLast = '0' and (rImg /= bufImg or rBit /= bufEnd) then v(2) := '0'; end if;
      if sStuffBufferLast = '1' and (rImg /= isat(bufImg) or rBit /= 0) then v(2) := '0'; end if;
    end if;
    if sStuffBufferLast = '1' and sImg /= isat(bufImg) then v(2) := '0'; end if;
    if sStuffBufferLast = '0' and sImg /= bufImg then v(2) := '0'; end if;
    -- h3: tracked-image bookkeeping
    if tEnd /= bool2bit(rImg > tI) then v(3) := '0'; end if;
    if tV /= bool2bit(tN < tLen and (rImg > tI or (rImg = tI and tN < rBit))) then v(3) := '0'; end if;
    if sSkidValid = '1' and skImg = tI then
      if sSkidLast = '1' and (rLast /= skBase or (skBase < CAP and tLen <= skBase) or tLen > fsat(skBase, FIFO_BITS)) then
        v(3) := '0';
      end if;
      if sSkidLast = '0' and tLen < CAP and skBase + FIFO_BITS >= tLen then v(3) := '0'; end if;
    end if;
    if bufImg = tI and (bufEnd > tLen or (sStuffBufferLast = '1' and bufEnd /= tLen)) then v(3) := '0'; end if;
    -- h4: tracked bit in the skid word
    if sSkidValid = '1' and skImg = tI and skBase < CAP - FIFO_BITS and tN >= skBase and tN < skBase + FIFO_BITS then
      if sSkidData(FIFO_BITS - 1 - (tN - skBase)) /= ex(tN) then v(4) := '0'; end if;
    end if;
    -- h5: tracked bit in the stuff buffer
    if bufEnd < CAP and c > bufEnd then v(5) := '0'; end if;
    if bufImg = tI and bufEnd < CAP and c <= bufEnd and c <= HOLD_BITS and tN < bufEnd and tN >= bufEnd - c then
      if sStuffBuffer(HOLD_BITS - 1 - (tN - (bufEnd - c))) /= ex(tN) then v(5) := '0'; end if;
    end if;
    -- h6: de-stuffer position and last-byte state against the buffer
    if nOutImg /= bufImg or nPrevFF /= sPrevFF then v(6) := '0'; end if;
    if bufEnd < CAP and c <= bufEnd and nOutBit /= bufEnd - c then v(6) := '0'; end if;
    if bufEnd = CAP and nOutBit < CAP - HOLD_BITS then v(6) := '0'; end if;
    -- h7: the last emitted byte holds data
    if nOutBit > 0 and nOutBit < CAP and (nDBefore >= nOutBit or nDBefore + 8 < nOutBit) then v(7) := '0'; end if;
    h <= v;
  end process p_help;
  -- psl help0 : assert always ((sInitF = '0' and iRst = '0') -> h(0) = '1');
  -- psl help1 : assert always ((sInitF = '0' and iRst = '0') -> h(1) = '1');
  -- psl help2 : assert always ((sInitF = '0' and iRst = '0') -> h(2) = '1');
  -- psl help3 : assert always ((sInitF = '0' and iRst = '0') -> h(3) = '1');
  -- psl help4 : assert always ((sInitF = '0' and iRst = '0') -> h(4) = '1');
  -- psl help5 : assert always ((sInitF = '0' and iRst = '0') -> h(5) = '1');
  -- psl help6 : assert always ((sInitF = '0' and iRst = '0') -> h(6) = '1');
  -- psl help7 : assert always ((sInitF = '0' and iRst = '0') -> h(7) = '1');
"""

# Order of one FIFO: a write chosen at any time is read back after exactly the entries ahead of it
FIFO = """library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.olo_base_pkg_math.all;

entity fq is
  generic (W : natural := 33; D : natural := 64);
  port (clk : in std_logic);
end entity fq;

architecture formal of fq is
  attribute anyseq : boolean;
  signal rst, iv, ordy, pick : std_logic;
  signal id : std_logic_vector(W - 1 downto 0);
  attribute anyseq of rst, iv, ordy, pick, id : signal is true;
  signal irdy, ov : std_logic;
  signal od : std_logic_vector(W - 1 downto 0);
  signal sInit : std_logic := '1';
  signal occ, ahead : natural range 0 to D;
  signal trk : std_logic;
  signal tData : std_logic_vector(W - 1 downto 0);
  signal wr, rd : std_logic;
begin
  sInit <= '0' when rising_edge(clk);
  u : entity work.olo_base_fifo_sync
    generic map (Width_g => W, Depth_g => D, RamBehavior_g => "RBW")
    port map (Clk => clk, Rst => rst, In_Data => id, In_Valid => iv, In_Ready => irdy, Out_Data => od,
              Out_Valid => ov, Out_Ready => ordy);
  wr <= iv; rd <= ov and ordy;
  p : process (clk) is
    variable vR : natural range 0 to 1;
  begin
    if rising_edge(clk) then
      vR := 1 when rd = '1' else 0;
      if rst = '1' then
        occ <= 0; trk <= '0'; ahead <= 0;
      else
        if wr = '1' and rd = '0' then occ <= occ + 1; elsif wr = '0' and rd = '1' and occ > 0 then occ <= occ - 1; end if;
        if trk = '1' and rd = '1' then
          if ahead = 0 then trk <= '0'; else ahead <= ahead - 1; end if;
        end if;
        if trk = '0' and wr = '1' and pick = '1' then
          trk <= '1'; tData <= id;
          ahead <= occ - vR + @AHEAD@;
        end if;
      end if;
    end if;
  end process;
  -- psl default clock is rising_edge(clk);
  -- psl assume always (sInit = '1' -> rst = '1');
  -- Writes only when ready: the cushion check (main FIFO) and the in-flight cap (BV queue)
  -- psl assume always (iv = '1' -> irdy = '1');
  -- psl fifo_ok : assert always ((sInit = '0' and rst = '0' and trk = '1' and rd = '1' and ahead = 0) -> od = tData);
  -- psl assert always ((sInit = '0' and rst = '0') -> occ <= D);
end architecture formal;
"""


# Helper version of the depth-64 FIFO proof (k-induction): formal-only copies of the vendored RAM and FIFO that
# only add output ports (pointers, levels, the RAM cell at one fixed address); no logic changes
def fifo_dbg_copies(d):
    ram = (OLO / "olo_base_ram_sdp.vhd").read_text()
    # entity, component and private entity port lists
    ram, n = re.subn(r"^( +)Rd_Data     : out   std_logic_vector\(Width_g - 1 downto 0\)\n",
                     lambda m: f"{m[1]}Rd_Data     : out   std_logic_vector(Width_g - 1 downto 0);\n"
                     f"{m[1]}Dbg_Addr    : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0) := (others => '0');\n"
                     f"{m[1]}Dbg_Cell    : out   std_logic_vector(Width_g - 1 downto 0)\n", ram, flags=re.M)
    assert n == 3
    pm = "                Rd_Data     => Rd_Data\n"
    assert ram.count(pm) == 1
    ram = ram.replace(pm, "                Rd_Data     => Rd_Data,\n                Dbg_Addr    => Dbg_Addr,\n                Dbg_Cell    => Dbg_Cell\n")
    wr = "                if Wr_Ena = '1' then\n                    Mem_v(to_integer(unsigned(Wr_Addr))) := Wr_Data;\n                end if;\n"
    assert ram.count(wr) >= 1
    ram = ram.replace(wr, wr + "                Dbg_Cell <= Mem_v(to_integer(unsigned(Dbg_Addr)));\n", 1)
    fifo = (OLO / "olo_base_fifo_sync.vhd").read_text()
    st = "        AlmEmpty      : out   std_logic\n    );\nend entity;"
    assert fifo.count(st) == 1
    fifo = fifo.replace(st, """        AlmEmpty      : out   std_logic;
        Dbg_Addr      : in    std_logic_vector(log2ceil(Depth_g) - 1 downto 0) := (others => '0');
        Dbg_Cell      : out   std_logic_vector(Width_g - 1 downto 0);
        Dbg_WrAddr    : out   std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Dbg_RdAddr    : out   std_logic_vector(log2ceil(Depth_g) - 1 downto 0);
        Dbg_WrLevel   : out   std_logic_vector(log2ceil(Depth_g + 1) - 1 downto 0);
        Dbg_RdLevel   : out   std_logic_vector(log2ceil(Depth_g + 1) - 1 downto 0);
        Dbg_RdUp      : out   std_logic;
        Dbg_WrDown    : out   std_logic
    );
end entity;""")
    pmf = "            Rd_Data     => Out_Data\n"
    assert fifo.count(pmf) == 1
    fifo = fifo.replace(pmf, "            Rd_Data     => Out_Data,\n            Dbg_Addr    => Dbg_Addr,\n            Dbg_Cell    => Dbg_Cell\n")
    lv = "    In_Level  <= r.WrLevel;\n"
    assert fifo.count(lv) == 1
    fifo = fifo.replace(lv, lv + "    Dbg_WrAddr <= r.WrAddr; Dbg_RdAddr <= r.RdAddr; Dbg_WrLevel <= r.WrLevel; Dbg_RdLevel <= r.RdLevel;\n"
                        "    Dbg_RdUp <= r.RdUp; Dbg_WrDown <= r.WrDown;\n")
    (d / "ram_dbg.vhd").write_text(ram); (d / "fifo_dbg.vhd").write_text(fifo)
    return ["ram_dbg.vhd", "fifo_dbg.vhd"]


# Tracks the entry written at one fixed address tA; helpers tie the checker's count and position to the pointers
FIFO_HELP = """library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.olo_base_pkg_math.all;

entity fq is
  generic (W : natural := 1; D : natural := 64);
  port (clk : in std_logic);
end entity fq;

architecture formal of fq is
  constant AW : natural := log2ceil(D);
  attribute anyseq : boolean;
  attribute anyconst : boolean;
  signal rst, iv, ordy, pick : std_logic;
  signal id : std_logic_vector(W - 1 downto 0);
  attribute anyseq of rst, iv, ordy, pick, id : signal is true;
  signal tA : std_logic_vector(AW - 1 downto 0);
  attribute anyconst of tA : signal is true;
  signal irdy, ov, rdUp, wrDown : std_logic;
  signal od, cell : std_logic_vector(W - 1 downto 0);
  signal wa, ra : std_logic_vector(AW - 1 downto 0);
  signal wl, rl : std_logic_vector(log2ceil(D + 1) - 1 downto 0);
  signal sInit : std_logic := '1';
  signal occ, ahead : natural range 0 to D;
  signal trk : std_logic;
  signal tData : std_logic_vector(W - 1 downto 0);
  signal wr, rd, h : std_logic;
begin
  sInit <= '0' when rising_edge(clk);
  u : entity work.olo_base_fifo_sync
    generic map (Width_g => W, Depth_g => D, RamBehavior_g => "RBW")
    port map (Clk => clk, Rst => rst, In_Data => id, In_Valid => iv, In_Ready => irdy, Out_Data => od,
              Out_Valid => ov, Out_Ready => ordy, Dbg_Addr => tA, Dbg_Cell => cell, Dbg_WrAddr => wa,
              Dbg_RdAddr => ra, Dbg_WrLevel => wl, Dbg_RdLevel => rl, Dbg_RdUp => rdUp, Dbg_WrDown => wrDown);
  wr <= iv; rd <= ov and ordy;
  p : process (clk) is
    variable vR : natural range 0 to 1;
  begin
    if rising_edge(clk) then
      vR := 1 when rd = '1' else 0;
      if rst = '1' then
        occ <= 0; trk <= '0'; ahead <= 0;
      else
        if wr = '1' and rd = '0' then occ <= occ + 1; elsif wr = '0' and rd = '1' and occ > 0 then occ <= occ - 1; end if;
        if trk = '1' and rd = '1' then
          if ahead = 0 then trk <= '0'; else ahead <= ahead - 1; end if;
        end if;
        if trk = '0' and wr = '1' and pick = '1' and wa = tA then
          trk <= '1'; tData <= id;
          ahead <= occ - vR;
        end if;
      end if;
    end if;
  end process;
  p_h : process (all) is
    variable vOk : boolean;
    variable o : integer;
  begin
    o := to_integer(unsigned(wl)) - to_integer(unsigned'("" & wrDown));
    vOk := to_integer(unsigned(wa)) < D and to_integer(unsigned(ra)) < D
           and to_integer(unsigned(wl)) <= D and o >= 0 and occ = o
           and to_integer(unsigned(rl)) + to_integer(unsigned'("" & rdUp)) = occ
           and (to_integer(unsigned(ra)) + occ) mod D = to_integer(unsigned(wa));
    if trk = '1' then
      vOk := vOk and ahead < occ and cell = tData
             and (to_integer(unsigned(ra)) + ahead) mod D = to_integer(unsigned(tA))
             and (ahead /= 0 or unsigned(rl) = 0 or od = tData);
    end if;
    h <= '1' when vOk else '0';
  end process;
  -- psl default clock is rising_edge(clk);
  -- psl assume always (sInit = '1' -> rst = '1');
  -- psl assume always (iv = '1' -> irdy = '1');
  -- psl assume always (to_integer(unsigned(tA)) < D);
  -- psl fifo_help : assert always ((sInit = '0' and rst = '0') -> h = '1');
  -- psl fifo_ok : assert always ((sInit = '0' and rst = '0' and trk = '1' and rd = '1' and ahead = 0) -> od = tData);
  -- psl assert always ((sInit = '0' and rst = '0') -> occ <= D);
end architecture formal;
"""


def inject(t, decl, body):
    a = t.index("architecture behavioral of byte_stuffer is")
    b = t.index("\nbegin\n", a)
    t = t[:b] + decl + t[b:]
    for inst in ("fifo_inst", "byte_valid_fifo_inst"):
        m = re.search(rf"\n  {inst} : entity.*?\);\n", t, re.S)
        t = t[:m.start()] + "\n" + t[m.end():]
    return t.replace("end architecture behavioral;", body + "\nend architecture behavioral;", 1)


def job(arg):
    part, bits, live = arg
    d = WORK / f"{part}_b{bits}{'_live' if live else ''}"
    shutil.rmtree(d, ignore_errors=True); (d / "lib").mkdir(parents=True)
    limit = 2 * (bits + max(8, bits))
    # Proofs: k-induction over the helper invariants. Known-bad copies: BMC without helpers, so the failure is the
    # checked property itself
    mode, depth = ("bmc", 16) if live else ("prove", 3)
    if part.startswith("fifo"):
        w, dep = (limit + 1, 64) if part == "fifo" else (6, FLIGHT)
        if live:
            (d / "top.vhd").write_text(FIFO.replace("@AHEAD@", "1"))
            files = ["top.vhd"]
        else:
            (d / "top.vhd").write_text(FIFO_HELP)
            files = fifo_dbg_copies(d) + ["top.vhd"]
        top, gens = "fq", f"-gW={w} -gD={dep}"
    else:
        t = contracts(prep((S / "byte_stuffer.vhd").read_text(), "byte_stuffer.vhd"))
        if part == "wr":
            t = inject(t, WR_DECL + WR_HELP_DECL, WR_BODY.replace("@OFF@", "1" if live else "0") + ("" if live else WR_HELP))
        else:
            t = inject(t, RD_DECL + RD_HELP_DECL, RD_BODY.replace("@SKIP@", "false" if live else "true") + ("" if live else RD_HELP))
        (d / "bs.vhd").write_text(t.replace("@CAP@", str(CAP)))
        files, top, gens = ["bs.vhd"], "byte_stuffer", f"-gIN_WIDTH={limit} -gBURST_DEPTH=64"
    r = run(["ghdl", "-a", "--std=08", "-frelaxed", "-fpsl", "--workdir=lib"] + [str(f) for f in BASE] + files, d)
    out = dict(part=part, bits=bits, live=live)
    if r.returncode:
        return dict(out, res="ERROR", info=r.stderr[-800:])
    # bitwuzla: z3 is >30x slower on the 30-bit position counters
    (d / "p.sby").write_text(f"""[options]
mode {mode}
depth {depth}
[engines]
smtbmc bitwuzla
[script]
plugin -i ghdl
ghdl --std=08 -frelaxed -fpsl --workdir=lib {gens} {top}
prep -top {top}
flatten; memory_map; opt -fast; techmap; opt -fast; setundef -undriven -zero; setundef -zero -init; setundef -zero
[files]
lib
""")
    try:
        p = run(["sby", "-f", "p.sby"], d, timeout=TIMEOUT)
    except Exception:
        return dict(out, res="TIMEOUT")
    st = (d / "p" / "status").read_text().split()[0] if (d / "p" / "status").exists() else "ERROR"
    res = {"PASS": "PROVED" if mode == "prove" else "BOUNDED", "FAIL": "DISPROVED"}.get(st, st)
    if live and res == "DISPROVED":
        # the known-bad copy must fail on the checked property, not on an environment helper
        m = re.search(r"Assert failed in \S+: (\S+)", p.stdout)
        if not m or m[1] not in ("wr_ok", "rd_ok", "fifo_ok"):
            res = "WRONG_FAIL"
    return dict(out, res=res, info="" if st == "PASS" else (p.stdout + p.stderr)[-500:])


PARTS = ["wr", "fifo", "fifo_bv", "rd"]

if __name__ == "__main__":
    parts = sys.argv[1:] or PARTS
    js = [(p, b, False) for p in parts for b in ([8] if p == "fifo_bv" else BITS)] + [(p, 8, True) for p in parts]
    with mp.get_context("fork").Pool(min(len(js), int(os.environ.get("BS_THREADS", 16))), maxtasksperchild=1) as pool, \
            open(RESULTS / "bs_split.jsonl", "a") as f:
        for r in pool.imap_unordered(job, js):
            f.write(json.dumps(r) + "\n"); f.flush()
            print(json.dumps(r), flush=True)
