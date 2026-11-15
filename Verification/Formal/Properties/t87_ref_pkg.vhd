-- Copyright (C) 2026 Vitor Mendes Camilo
-- SPDX-License-Identifier: GPL-3.0-only
-- T.87 reference for t87_eq.py, transcribed from the C code segments in Docs/Requirements.md (NEAR = 0).
-- bug = true moves one boundary of the segment; the fault-injection check must then fail.

library ieee;
  use ieee.numeric_std.all;

package t87_ref_pkg is

  -- C.2.4.1.1, MAXVAL >= 128; n selects T1, T2 or T3
  function t87_threshold (n : positive; maxval : integer) return integer;
  -- A.3
  function t87_run_mode (d1, d2, d3 : integer; bug : boolean := false) return boolean;
  -- A.4
  function t87_quantize (d, t1, t2, t3 : integer; bug : boolean := false) return integer;
  -- A.4.1, returns SIGN
  function t87_sign (q1, q2, q3 : integer; bug : boolean := false) return integer;
  -- A.5
  function t87_predict (ra, rb, rc : integer; bug : boolean := false) return integer;
  -- A.6 + A.7
  function t87_errval (ix, px, sign, c, maxval : integer; bug : boolean := false) return integer;
  -- A.9 (ModRange)
  function t87_modrange (e, rng : integer; bug : boolean := false) return integer;
  -- A.10, n >= 1 and a < 2^24
  function t87_k (n, a : integer; bug : boolean := false) return integer;
  -- A.11
  function t87_merrval (k, b, n, e : integer; bug : boolean := false) return integer;
  -- A.11.1 LG(k, glimit): unary zeros, suffix length and suffix value
  function t87_lg_zeros (k, merr, glimit, qbpp : integer; bug : boolean := false) return integer;
  function t87_lg_len (k, merr, glimit, qbpp : integer; bug : boolean := false) return integer;
  function t87_lg_val (k, merr, glimit, qbpp : integer; bug : boolean := false) return integer;
  -- A.12 + A.13, regular context update
  function t87_n_new (n, reset : integer) return integer;
  function t87_a_new (a, e, n, reset : integer) return integer;
  function t87_b_new (b, e, n, reset : integer; bug : boolean := false) return integer;
  function t87_c_new (b, c, e, n, reset, min_c, max_c : integer) return integer;
  -- A.17 to A.19, run interruption
  function t87_ritype (ra, rb : integer) return integer;
  function t87_ri_sign (ra, rb : integer; bug : boolean := false) return integer;
  function t87_ri_errval (ra, rb, ix, rng : integer; bug : boolean := false) return integer;
  -- A.21, A.22
  function t87_map (k, e, nn, n : integer; bug : boolean := false) return integer;
  function t87_emerrval (e, ritype, mapv : integer) return integer;
  -- A.23
  function t87_ri_a_new (a, n, emerr, ritype, reset : integer; bug : boolean := false) return integer;
  function t87_ri_nn_new (nn, n, e, reset : integer) return integer;

end package t87_ref_pkg;

package body t87_ref_pkg is

  function iabs (v : integer) return integer is
  begin
    if v < 0 then
      return -v;
    end if;
    return v;
  end function;

  function b2i (b : boolean) return integer is
  begin
    if b then
      return 1;
    end if;
    return 0;
  end function;

  function t87_clamp (i, j, maxval : integer) return integer is
  begin
    if i > maxval or i < j then
      return j;
    end if;
    return i;
  end function;

  function t87_threshold (n : positive; maxval : integer) return integer is
    variable vMin   : integer := maxval;
    variable factor : integer;
    variable t1     : integer;
    variable t2     : integer;
  begin
    if vMin > 4095 then
      vMin := 4095;
    end if;
    factor := (vMin + 128) / 256;
    t1     := t87_clamp(factor * (3 - 2) + 2, 1, maxval);
    t2     := t87_clamp(factor * (7 - 3) + 3, t1, maxval);
    if n = 1 then
      return t1;
    elsif n = 2 then
      return t2;
    end if;
    return t87_clamp(factor * (21 - 4) + 4, t2, maxval);
  end function;

  function t87_run_mode (d1, d2, d3 : integer; bug : boolean := false) return boolean is
  begin
    return d1 = 0 and d2 = 0 and (d3 = 0 or bug);
  end function;

  function t87_quantize (d, t1, t2, t3 : integer; bug : boolean := false) return integer is
  begin
    if d <= -t3 then
      return -4;
    elsif d <= -t2 then
      return -3;
    elsif d <= -t1 then
      return -2;
    elsif d < 0 then
      return -1;
    elsif d <= 0 then
      return 0;
    elsif d < t1 then
      return 1;
    elsif d < t2 then
      return 2;
    elsif d < t3 or (bug and d = t3) then
      return 3;
    end if;
    return 4;
  end function;

  function t87_sign (q1, q2, q3 : integer; bug : boolean := false) return integer is
  begin
    if q1 < 0 or (q1 = 0 and q2 < 0) or (q1 = 0 and q2 = 0 and q3 < 0 and not bug) then
      return -1;
    end if;
    return 1;
  end function;

  function t87_predict (ra, rb, rc : integer; bug : boolean := false) return integer is
    variable vMax : integer := ra;
    variable vMin : integer := rb;
  begin
    if rb > ra then
      vMax := rb;
      vMin := ra;
    end if;
    if rc >= vMax then
      if bug then
        return vMax;
      end if;
      return vMin;
    elsif rc <= vMin then
      return vMax;
    end if;
    return ra + rb - rc;
  end function;

  function t87_errval (ix, px, sign, c, maxval : integer; bug : boolean := false) return integer is
    variable vPx : integer := px;
  begin
    if sign = 1 then
      vPx := vPx + c;
    else
      vPx := vPx - c;
    end if;
    if vPx > maxval then
      vPx := maxval;
    elsif vPx < 0 and not bug then
      vPx := 0;
    end if;
    if sign = -1 then
      return vPx - ix;
    end if;
    return ix - vPx;
  end function;

  function t87_modrange (e, rng : integer; bug : boolean := false) return integer is
    variable vE : integer := e;
  begin
    if vE < 0 then
      vE := vE + rng;
    end if;
    if vE >= (rng + 1) / 2 + b2i(bug) then
      vE := vE - rng;
    end if;
    return vE;
  end function;

  -- n << i grows with i (n >= 1), so the C loop stops at the count of i with (n << i) < a
  function t87_k (n, a : integer; bug : boolean := false) return integer is
    variable k : integer := 0;
  begin
    for i in 0 to 24 loop
      if n * 2 ** i < a or (bug and n * 2 ** i = a) then
        k := k + 1;
      end if;
    end loop;
    return k;
  end function;

  function t87_merrval (k, b, n, e : integer; bug : boolean := false) return integer is
  begin
    if k = 0 and (2 * b <= -n) and not (bug and 2 * b = -n) then
      if e >= 0 then
        return 2 * e + 1;
      end if;
      return -2 * (e + 1);
    end if;
    if e >= 0 then
      return 2 * e;
    end if;
    return -2 * e - 1;
  end function;

  function lg_high (k, merr : integer) return integer is
  begin
    return to_integer(shift_right(to_unsigned(merr, 30), k));
  end function;

  function lg_escape (k, merr, glimit, qbpp : integer; bug : boolean) return boolean is
  begin
    return not (lg_high(k, merr) < glimit - qbpp - 1 or (bug and lg_high(k, merr) = glimit - qbpp - 1));
  end function;

  function t87_lg_zeros (k, merr, glimit, qbpp : integer; bug : boolean := false) return integer is
  begin
    if lg_escape(k, merr, glimit, qbpp, bug) then
      return glimit - qbpp - 1;
    end if;
    return lg_high(k, merr);
  end function;

  function t87_lg_len (k, merr, glimit, qbpp : integer; bug : boolean := false) return integer is
  begin
    if lg_escape(k, merr, glimit, qbpp, bug) then
      return qbpp;
    end if;
    return k;
  end function;

  function t87_lg_val (k, merr, glimit, qbpp : integer; bug : boolean := false) return integer is
  begin
    if lg_escape(k, merr, glimit, qbpp, bug) then
      return merr - 1;
    end if;
    return merr - to_integer(shift_left(to_unsigned(lg_high(k, merr), 30), k));
  end function;

  function t87_n_new (n, reset : integer) return integer is
  begin
    if n = reset then
      return n / 2 + 1;
    end if;
    return n + 1;
  end function;

  function t87_a_new (a, e, n, reset : integer) return integer is
    variable vA : integer := a + iabs(e);
  begin
    if n = reset then
      vA := vA / 2;
    end if;
    return vA;
  end function;

  -- B after A.12, before A.13
  function b12 (b, e, n, reset : integer) return integer is
    variable vB : integer := b + e;
  begin
    if n = reset then
      if vB >= 0 then
        vB := vB / 2;
      else
        vB := -((1 - vB) / 2);
      end if;
    end if;
    return vB;
  end function;

  function t87_b_new (b, e, n, reset : integer; bug : boolean := false) return integer is
    variable vB : integer := b12(b, e, n, reset);
    variable vN : integer := t87_n_new(n, reset);
  begin
    if vB <= -vN then
      vB := vB + vN;
      if vB <= -vN then
        vB := -vN + 1;
      end if;
    elsif vB > 0 then
      vB := vB - vN;
      if vB > 0 and not bug then
        vB := 0;
      end if;
    end if;
    return vB;
  end function;

  function t87_c_new (b, c, e, n, reset, min_c, max_c : integer) return integer is
    variable vB : integer := b12(b, e, n, reset);
    variable vN : integer := t87_n_new(n, reset);
  begin
    if vB <= -vN then
      if c > min_c then
        return c - 1;
      end if;
    elsif vB > 0 then
      if c < max_c then
        return c + 1;
      end if;
    end if;
    return c;
  end function;

  function t87_ritype (ra, rb : integer) return integer is
  begin
    if iabs(ra - rb) <= 0 then
      return 1;
    end if;
    return 0;
  end function;

  function t87_ri_sign (ra, rb : integer; bug : boolean := false) return integer is
  begin
    if t87_ritype(ra, rb) = 0 and (ra > rb or (bug and ra < rb)) then
      return -1;
    end if;
    return 1;
  end function;

  function t87_ri_errval (ra, rb, ix, rng : integer; bug : boolean := false) return integer is
    variable vPx : integer := rb;
    variable vE  : integer;
  begin
    if t87_ritype(ra, rb) = 1 then
      vPx := ra;
    end if;
    vE := ix - vPx;
    if t87_ri_sign(ra, rb, bug) = -1 then
      vE := -vE;
    end if;
    return t87_modrange(vE, rng);
  end function;

  function t87_map (k, e, nn, n : integer; bug : boolean := false) return integer is
  begin
    if k = 0 and e > 0 and 2 * nn < n then
      return 1;
    elsif e < 0 and (2 * nn >= n) and not (bug and 2 * nn = n) then
      return 1;
    elsif e < 0 and k /= 0 then
      return 1;
    end if;
    return 0;
  end function;

  function t87_emerrval (e, ritype, mapv : integer) return integer is
  begin
    return 2 * iabs(e) - ritype - mapv;
  end function;

  function t87_ri_a_new (a, n, emerr, ritype, reset : integer; bug : boolean := false) return integer is
    variable vA : integer := a + (emerr + 1 - ritype + b2i(bug)) / 2;
  begin
    if n = reset then
      vA := vA / 2;
    end if;
    return vA;
  end function;

  function t87_ri_nn_new (nn, n, e, reset : integer) return integer is
    variable vNn : integer := nn;
  begin
    if e < 0 then
      vNn := vNn + 1;
    end if;
    if n = reset then
      vNn := vNn / 2;
    end if;
    return vNn;
  end function;

end package body t87_ref_pkg;
