"""Exact Python port of the bash v2 scan pipeline (plan decisions D12, D15).

What it ports, line by line and quirks included:

  lib/indicators.sh   calc_mean, calc_stddev, calc_max, calc_ema, calc_rsi,
                      calc_macd, calc_bollinger_bands, calc_atr, calc_obv,
                      calc_stochastic, calc_williams_r
  lib/scoring.sh      score_rsi, score_macd, score_bollinger_bands,
                      score_stochastic, score_williams_r, score_obv_trend,
                      score_mean_reversion_setup, score_trend_follow_setup,
                      kalman_trend_from_closes, build_v2_inputs,
                      calculate_confluence_score_v2 (MiroFish and agents off)
  lib/regime_detector.sh  detect_market_regime (closes passed by the caller)
  StockSwingTrader_Agent.sh  calculate_all_indicators and the grep-based
                      extraction in score_stock

Numeric model. Bash keeps every value as a string; each `bc` call parses
decimal strings and prints a decimal string. This module does the same: values
are strings and every bc expression is evaluated by a small bc interpreter
(`bc()`), using bc's scale rules:

  number literal  scale = digits after the point ("1.50" -> 2)
  a + b, a - b    exact, scale max(sa, sb)
  a * b           exact product truncated to min(sa + sb, max(scale, sa, sb))
  a / b           truncated (toward zero) to `scale` digits
  sqrt(a)         truncated to max(scale, sa)
  relational      1 or 0
  `bc` = scale 0, `bc -l` = scale 20, "scale=N; expr" = scale N.
  A syntax error ("--5", " > 70" for an empty argument) or a division by zero
  prints nothing, so the bash variable is "" and `(( $(...) ))` is false.
  bc has no negative zero.

`printf "%.Nf"` (bash builtin, strtold; long double == double on arm64) is
format(float(s), '.Nf'): C rounding of the binary double ("12.500" -> "12").
An empty string prints as 0. `awk` arithmetic is IEEE double; `jq` arithmetic
is IEEE double with C round() (half away from zero).

Known bash quirks reproduced on purpose (do not "fix" them here):
  * calc_ema rounds to 2 decimals at every step and feeds the rounded value
    back (bash JSON array; zeros before index period-1).
  * calc_macd: signal == macd, so the histogram is always 0.00; the EMA values
    are picked with grep '[0-9.]*', which drops a minus sign.
  * calc_bollinger_bands uses the SAMPLE std (n-1), middle rounded first.
  * calc_atr starts prev_close at 0 and averages the last N true ranges.
  * calc_stochastic / calc_williams_r: raw %K, %D = %K.
  * calculate_all_indicators passes CLOSES ONLY to calc_stochastic and
    calc_williams_r (D15), so the "H L C" triples are consecutive closes
    (scan_stoch_williams_from_closes).
  * score_stock greps '"macd":[0-9.]*' etc., which turns a negative MACD,
    signal, histogram ("-0.00" too) or %K into "" (score_stock_extraction).
  * score_* use plain `bc` (scale 0): e.g. 0.2 / 0.3 == 0 in score_macd;
    "(-$histogram)" with a negative histogram is "--x", a bc syntax error.
  * build_v2_inputs computes EMA12/26 in jq at full precision (unlike
    calc_ema); sma_200 is null with fewer than 200 closes.
"""

from __future__ import annotations

import importlib.util
import json
import math
import re
from decimal import ROUND_DOWN, ROUND_HALF_UP, Context, Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Union

PROJECT_ROOT = Path(__file__).resolve().parents[2]

# Defaults the agent gets from config.template.sh (the parity goldens run
# with an empty config.sh, so these are the values in effect).
OBV_LOOKBACK = 10
KALMAN_TREND_THRESHOLD_PCT = 0.5
V2_SENTIMENT_WEIGHT = 0.10

# ============================================================================
# bc interpreter
# ============================================================================

_CTX = Context(prec=600, rounding=ROUND_DOWN, Emax=10 ** 6, Emin=-(10 ** 6))


class BcError(Exception):
    """bc would print an error (and nothing on stdout)."""


def _scale(d: Decimal) -> int:
    e = d.as_tuple().exponent
    return -e if isinstance(e, int) and e < 0 else 0


def _norm(d: Decimal) -> Decimal:
    """bc has no negative zero."""
    return d.copy_abs() if d.is_zero() else d


def _trunc(d: Decimal, s: int) -> Decimal:
    return _norm(d.quantize(Decimal(1).scaleb(-s, _CTX), rounding=ROUND_DOWN, context=_CTX))


_TOKEN = re.compile(r"\s*(?:(\d+\.?\d*|\.\d+)|(\+\+|--|<=|>=|==|!=|[-+*/()<>]))")


def _tokenize(expr: str) -> List[str]:
    toks: List[str] = []
    pos, n = 0, len(expr)
    while pos < n:
        if expr[pos:].strip() == "":
            break
        m = _TOKEN.match(expr, pos)
        if not m or m.end() == pos:
            raise BcError("bad token")
        tok = m.group(1) or m.group(2)
        if tok in ("++", "--"):
            raise BcError("increment/decrement on a non-variable")
        toks.append(tok)
        pos = m.end()
    if not toks:
        raise BcError("empty expression")
    return toks


class _Parser:
    def __init__(self, toks: List[str], scale: int):
        self.t, self.i, self.scale = toks, 0, scale

    def peek(self) -> Optional[str]:
        return self.t[self.i] if self.i < len(self.t) else None

    def take(self) -> str:
        tok = self.peek()
        if tok is None:
            raise BcError("unexpected end")
        self.i += 1
        return tok

    def parse(self) -> Decimal:
        v = self.rel()
        if self.peek() is not None:
            raise BcError("trailing tokens")
        return v

    def rel(self) -> Decimal:
        a = self.add()
        while self.peek() in ("<", ">", "<=", ">=", "==", "!="):
            op = self.take()
            b = self.add()
            r = {"<": a < b, ">": a > b, "<=": a <= b, ">=": a >= b, "==": a == b, "!=": a != b}[op]
            a = Decimal(1 if r else 0)
        return a

    def add(self) -> Decimal:
        a = self.mul()
        while self.peek() in ("+", "-"):
            op = self.take()
            b = self.mul()
            a = _norm(_CTX.add(a, b) if op == "+" else _CTX.subtract(a, b))
        return a

    def mul(self) -> Decimal:
        a = self.unary()
        while self.peek() in ("*", "/"):
            op = self.take()
            b = self.unary()
            if op == "*":
                sa, sb = _scale(a), _scale(b)
                a = _trunc(_CTX.multiply(a, b), min(sa + sb, max(self.scale, sa, sb)))
            else:
                if b.is_zero():
                    raise BcError("divide by zero")
                a = _trunc(_CTX.divide(a, b), self.scale)
        return a

    def unary(self) -> Decimal:
        if self.peek() == "-":
            self.take()
            return _norm(-self.unary())
        return self.primary()

    def primary(self) -> Decimal:
        tok = self.take()
        if tok == "(":
            v = self.rel()
            if self.take() != ")":
                raise BcError("missing )")
            return v
        if tok[0].isdigit() or tok[0] == ".":
            return _norm(Decimal(tok))
        raise BcError("unexpected token %r" % tok)


def bc_str(d: Decimal) -> str:
    """How bc prints D: no leading 0 before the point, '0' for zero."""
    if d.is_zero():
        return "0"
    s = format(d, "f")
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if s.startswith("0."):
        s = s[1:]
    return ("-" if neg else "") + s


def bc_eval(expr: str, scale: int = 0) -> Decimal:
    """Evaluate one bc expression; raises BcError where bc prints an error."""
    return _Parser(_tokenize(expr), scale).parse()


def bc(expr: str, scale: int = 0) -> str:
    """`echo EXPR | bc` (scale 0), bc(expr, 20) = `bc -l`; '' on error."""
    try:
        return bc_str(bc_eval(expr, scale))
    except (BcError, InvalidOperation):
        return ""


def bc_l(expr: str) -> str:
    return bc(expr, 20)


def bc_true(expr: str, scale: int = 20) -> bool:
    """`(( $(echo EXPR | bc -l) ))`: false for '' and 0."""
    out = bc(expr, scale)
    if out == "":
        return False
    try:
        return Decimal(out) != 0
    except InvalidOperation:
        return False


def _to_float(s: Any) -> float:
    if s is None:
        return 0.0
    if isinstance(s, (int, float)):
        return float(s)
    s = str(s).strip()
    if s == "":
        return 0.0
    try:
        return float(s)
    except ValueError:
        m = re.match(r"[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?", s)
        return float(m.group(0)) if m else 0.0


def printf_f(s: Any, digits: int) -> str:
    """bash `printf "%.Nf" S`."""
    return format(_to_float(s), ".%df" % digits)


def awk_num(s: Any) -> float:
    """awk's numeric value of a -v string ('' -> 0)."""
    return _to_float(s)


def jq_round(x: float) -> float:
    """jq round (C round(): half away from zero) on the exact double."""
    return float(Decimal(x).quantize(Decimal(1), rounding=ROUND_HALF_UP))


def _jq_r4(x: Optional[float]) -> Optional[float]:
    return None if x is None else jq_round(x * 10000) / 10000


def num_text(x: Any) -> str:
    """Text a JSON number takes in the bash pipeline (input strings as is;
    floats in shortest repr, integral volumes without '.0')."""
    if isinstance(x, str):
        return x
    if isinstance(x, bool):
        raise TypeError("bool is not a price")
    if isinstance(x, int):
        return str(x)
    f = float(x)
    return repr(f)


def _jq_num_str(x: Optional[float]) -> str:
    """jq `tostring` of a computed double (shortest round-trip)."""
    if x is None:
        return ""
    if float(x).is_integer() and abs(x) < 1e17:
        return str(int(x))
    return repr(float(x))


# ============================================================================
# lib/indicators.sh
# ============================================================================

def calc_mean(arr: Sequence[str]) -> str:
    """calc_mean: running sum with plain bc, then sum / count with bc -l."""
    arr = list(arr)
    if not arr:
        return "0"
    total = "0"
    for v in arr:
        total = bc("%s + %s" % (total, v))
    return bc_l("%s / %d" % (total, len(arr)))


def calc_stddev(arr: Sequence[str]) -> str:
    """calc_stddev: SAMPLE std (n-1), every step in bc -l."""
    arr = list(arr)
    if len(arr) <= 1:
        return "0"
    mean = calc_mean(arr)
    sum_sq = "0"
    for v in arr:
        diff = bc_l("%s - %s" % (v, mean))
        sq = bc_l("%s * %s" % (diff, diff))
        sum_sq = bc_l("%s + %s" % (sum_sq, sq))
    variance = bc_l("%s / (%d - 1)" % (sum_sq, len(arr)))
    try:
        d = bc_eval(variance, 20)
        if d < 0:
            return ""
        s = max(20, _scale(d))
        root = Context(prec=600, rounding=ROUND_DOWN).sqrt(d)
        return bc_str(_trunc(root, s))
    except (BcError, InvalidOperation):
        return ""


def calc_max(arr: Sequence[str]) -> str:
    """calc_max: first strictly greater value wins (the original string)."""
    arr = list(arr)
    mx = arr[0]
    for v in arr:
        if bc_true("%s > %s" % (v, mx)):
            mx = v
    return mx


def calc_ema_values(period: int, prices: Sequence[str]) -> List[str]:
    """calc_ema as a list of strings: '0.00' before index period-1, the SMA
    seed at period-1, then (p - ema) * mult + ema; %.2f at every step."""
    prices = list(prices)
    mult = bc("2 / (%d + 1)" % period, 6)
    ema = "0"
    out: List[str] = []
    for i, p in enumerate(prices):
        if i < period:
            if i == period - 1:
                ema = calc_mean(prices[:period])
        else:
            ema = bc_l("(%s - %s) * %s + %s" % (p, ema, mult, ema))
        ema = printf_f(ema, 2)
        out.append(ema)
    return out


def calc_ema(period: int, prices: Sequence[str]) -> str:
    """calc_ema output: JSON array text '[0.00,...,101.23]'."""
    return "[" + ",".join(calc_ema_values(period, prices)) + "]"


def calc_rsi(period: int, prices: Sequence[str]) -> str:
    """calc_rsi: Wilder smoothing seeded with the mean of the first PERIOD
    diffs; diff == 0 takes the loss branch (adds 0); %.2f."""
    prices = list(prices)
    count = len(prices)
    if count < period + 1:
        return '{"rsi":0,"signal":"insufficient_data"}'
    gains, losses = "0", "0"
    for i in range(1, period + 1):
        diff = bc_l("%s - %s" % (prices[i], prices[i - 1]))
        if bc_true("%s > 0" % diff):
            gains = bc_l("%s + %s" % (gains, diff))
        else:
            losses = bc_l("%s - %s" % (losses, diff))
    avg_gain = bc_l("%s / %d" % (gains, period))
    avg_loss = bc_l("%s / %d" % (losses, period))
    for i in range(period + 1, count):
        diff = bc_l("%s - %s" % (prices[i], prices[i - 1]))
        if bc_true("%s > 0" % diff):
            avg_gain = bc_l("(%s * (%d - 1) + %s) / %d" % (avg_gain, period, diff, period))
            avg_loss = bc_l("(%s * (%d - 1)) / %d" % (avg_loss, period, period))
        else:
            avg_gain = bc_l("(%s * (%d - 1)) / %d" % (avg_gain, period, period))
            avg_loss = bc_l("(%s * (%d - 1) - %s) / %d" % (avg_loss, period, diff, period))
    if bc_true("%s > 0" % avg_loss):
        rs = bc_l("%s / %s" % (avg_gain, avg_loss))
        rsi = bc_l("100 - (100 / (1 + %s))" % rs)
    else:
        rsi = "100"
    rsi = printf_f(rsi, 2)
    signal = "neutral"
    if bc_true("%s > 70" % rsi):
        signal = "overbought"
    elif bc_true("%s < 30" % rsi):
        signal = "oversold"
    return '{"rsi":%s,"signal":"%s"}' % (rsi, signal)


def _grep_last_unsigned(arr_json: str) -> str:
    """`grep -o '[0-9.]*' | tail -1` (a minus sign is dropped)."""
    found = [m for m in re.findall(r"[0-9.]+", arr_json)]
    return found[-1] if found else ""


def calc_macd(prices: Sequence[str]) -> str:
    """calc_macd: EMA12 - EMA26 (last calc_ema values), %.2f; signal = macd;
    histogram = macd - signal (always 0.00)."""
    ema12 = _grep_last_unsigned(calc_ema(12, prices))
    ema26 = _grep_last_unsigned(calc_ema(26, prices))
    macd = printf_f(bc_l("%s - %s" % (ema12, ema26)), 2)
    signal = macd
    hist = printf_f(bc_l("%s - %s" % (macd, signal)), 2)
    return '{"macd":%s,"signal":%s,"histogram":%s}' % (macd, signal, hist)


def calc_bollinger_bands(period: int, std_dev: Union[int, str], prices: Sequence[str]) -> str:
    """calc_bollinger_bands: last PERIOD prices, middle %.2f first, sample std
    %.6f, upper/lower from the rounded middle and std, %.2f; %B."""
    prices = list(prices)
    count = len(prices)
    if count < period:
        return '{"upper":0,"middle":0,"lower":0,"pct_b":0}'
    recent = prices[count - period:]
    middle = printf_f(calc_mean(recent), 2)
    std = printf_f(calc_stddev(recent), 6)
    upper = printf_f(bc_l("%s + (%s * %s)" % (middle, std_dev, std)), 2)
    lower = printf_f(bc_l("%s - (%s * %s)" % (middle, std_dev, std)), 2)
    current = prices[-1]
    bandwidth = bc_l("%s - %s" % (upper, lower))
    pct_b = "0"
    if bc_true("%s > 0" % bandwidth):
        pct_b = printf_f(bc_l("(%s - %s) / %s" % (current, lower, bandwidth)), 2)
    return '{"upper":%s,"middle":%s,"lower":%s,"pct_b":%s}' % (upper, middle, lower, pct_b)


def calc_atr(period: int, hlc: Sequence[str]) -> str:
    """calc_atr: TR with prev_close starting at 0; ATR = mean of the last
    PERIOD true ranges, %.2f; '0' with fewer than PERIOD candles."""
    hlc = list(hlc)
    count = len(hlc) // 3
    if count < period:
        return "0"
    trs: List[str] = []
    prev = "0"
    for i in range(count):
        h, l, c = hlc[i * 3], hlc[i * 3 + 1], hlc[i * 3 + 2]
        tr1 = bc_l("%s - %s" % (h, l))
        tr2 = bc_l("(%s - %s)" % (h, prev))
        tr3 = bc_l("(%s - %s)" % (l, prev))
        if bc_true("%s < 0" % tr2):
            tr2 = bc_l("0 - (%s)" % tr2)
        if bc_true("%s < 0" % tr3):
            tr3 = bc_l("0 - (%s)" % tr3)
        trs.append(calc_max([tr1, tr2, tr3]))
        prev = c
    return printf_f(calc_mean(trs[count - period:]), 2)


def calc_obv_values(cv: Sequence[str]) -> List[str]:
    """calc_obv as strings: first volume, then +/- volume (plain bc)."""
    cv = list(cv)
    count = len(cv) // 2
    obv, prev, out = "0", "0", []
    for i in range(count):
        close, vol = cv[i * 2], cv[i * 2 + 1]
        if i == 0:
            obv = vol
        else:
            if bc_true("%s > %s" % (close, prev)):
                obv = bc("%s + %s" % (obv, vol))
            elif bc_true("%s < %s" % (close, prev)):
                obv = bc("%s - %s" % (obv, vol))
        out.append(obv)
        prev = close
    return out


def calc_obv(cv: Sequence[str]) -> str:
    return "[" + ",".join(calc_obv_values(cv)) + "]"


def _hh_ll(hlc: List[str], count: int, period: int):
    hh, ll = "0", "999999"
    for i in range(count - period, count):
        h, l = hlc[i * 3], hlc[i * 3 + 1]
        if bc_true("%s > %s" % (h, hh)):
            hh = h
        if bc_true("%s < %s" % (l, ll)):
            ll = l
    return hh, ll


def calc_stochastic(period: int, hlc: Sequence[str]) -> str:
    """calc_stochastic over H L C triples: raw %K (%.2f), %D = %K; 50 when
    the range is empty."""
    hlc = list(hlc)
    count = len(hlc) // 3
    if count < period:
        return '{"k_line":0,"d_line":0}'
    hh, ll = _hh_ll(hlc, count, period)
    close = hlc[(count - 1) * 3 + 2]
    den = bc_l("%s - %s" % (hh, ll))
    k = "50"
    if bc_true("%s > 0" % den):
        k = printf_f(bc_l("100 * (%s - %s) / %s" % (close, ll, den)), 2)
    return '{"k_line":%s,"d_line":%s}' % (k, k)


def calc_williams_r(period: int, hlc: Sequence[str]) -> str:
    """calc_williams_r over H L C triples (%.2f); '-50' when short/flat."""
    hlc = list(hlc)
    count = len(hlc) // 3
    if count < period:
        return "-50"
    hh, ll = _hh_ll(hlc, count, period)
    close = hlc[(count - 1) * 3 + 2]
    den = bc_l("%s - %s" % (hh, ll))
    w = "-50"
    if bc_true("%s > 0" % den):
        w = printf_f(bc_l("-100 * (%s - %s) / %s" % (hh, close, den)), 2)
    return w


def scan_stoch_williams_from_closes(closes: Sequence[str]):
    """What calculate_all_indicators really computes (D15): it passes CLOSES
    ONLY to calc_stochastic/calc_williams_r, so the triples are consecutive
    closes. Returns (stochastic_json_text, williams_text)."""
    closes = list(closes)
    return calc_stochastic(14, closes), calc_williams_r(14, closes)


# ============================================================================
# lib/scoring.sh: indicator scores (plain bc, scale 0)
# ============================================================================

def score_rsi(rsi: str) -> str:
    rsi = "" if rsi is None else str(rsi)
    score = "50"
    if bc_true("%s > 70" % rsi):
        score = bc("100 - ((%s - 70) * 1.5)" % rsi)
        if bc_true("%s < 0" % score, 0):
            score = "0"
    elif bc_true("%s < 30" % rsi):
        score = bc("(30 - %s) * 1.5" % rsi)
        if bc_true("%s > 100" % score, 0):
            score = "100"
    else:
        score = bc("40 + (%s - 30) * 0.33" % rsi)
    return printf_f(score, 0)


def score_macd(macd: str, signal: str, histogram: str) -> str:
    macd = "" if macd is None else str(macd)
    signal = "" if signal is None else str(signal)
    histogram = "" if histogram is None else str(histogram)
    score = "50"
    if bc_true("%s > 0" % histogram):
        if bc_true("%s > %s" % (macd, signal)):
            score = bc("50 + ((%s / (0.1 + %s)) * 50)" % (histogram, histogram))
        else:
            score = "60"
    elif bc_true("%s < 0" % histogram):
        if bc_true("%s < %s" % (macd, signal)):
            score = bc("50 - (((-%s) / (0.1 - %s)) * 50)" % (histogram, histogram))
            if bc_true("%s < 0" % score, 0):
                score = "0"
        else:
            score = "40"
    if bc_true("%s > 100" % score, 0):
        score = "100"
    if bc_true("%s < 0" % score, 0):
        score = "0"
    return printf_f(score, 0)


def score_bollinger_bands(price: str, upper: str, middle: str, lower: str) -> str:
    price, upper, lower = ("" if v is None else str(v) for v in (price, upper, lower))
    score = "50"
    pos = "0"
    bandwidth = bc_l("%s - %s" % (upper, lower))
    if bc_true("%s > 0" % bandwidth):
        pos = bc_l("(%s - %s) / %s" % (price, lower, bandwidth))
    if bc_true("%s < 0.3" % pos):
        score = bc("100 - (%s * 100)" % pos)
    elif bc_true("%s > 0.7" % pos):
        score = bc("100 - ((%s - 0.7) * 100)" % pos)
    else:
        score = bc("50 + (%s - 0.5) * 20" % pos)
    if bc_true("%s > 100" % score, 0):
        score = "100"
    if bc_true("%s < 0" % score, 0):
        score = "0"
    return printf_f(score, 0)


def score_stochastic(k_line: str) -> str:
    k = "" if k_line is None else str(k_line)
    if bc_true("%s > 80" % k):
        score = bc("100 - ((%s - 80) * 2.5)" % k)
    elif bc_true("%s < 20" % k):
        score = bc("(%s) * 2.5" % k)
    else:
        score = bc("25 + (%s - 20) * 0.625" % k)
    if bc_true("%s > 100" % score, 0):
        score = "100"
    if bc_true("%s < 0" % score, 0):
        score = "0"
    return printf_f(score, 0)


def score_williams_r(williams_r: str) -> str:
    w = "" if williams_r is None else str(williams_r)
    score = bc("(%s + 100)" % w)
    if bc_true("%s < 0" % score, 0):
        score = "0"
    if bc_true("%s > 100" % score, 0):
        score = "100"
    return printf_f(score, 0)


# ============================================================================
# lib/scoring.sh: v2 helpers (jq / awk, IEEE double)
# ============================================================================

def score_obv_trend(obv: Sequence[float], volumes: Sequence[float], lookback: int = OBV_LOOKBACK) -> Dict[str, Any]:
    """score_obv_trend (jq): ratio = delta / (N * mean(vol[-N:])), clamped to
    [-1, 1]; score = floor(50 + 50 * r + 0.5)."""
    o, v, n = [float(x) for x in obv], [float(x) for x in volumes], int(lookback)
    if len(o) < n + 1 or len(v) < n:
        return {"obv_score": 50, "obv_available": False, "obv_change": None, "obv_lookback": n}
    d = o[-1] - o[-1 - n]
    mv = _jq_add(v[-n:]) / n
    r = d / (n * mv) if mv > 0 else 0
    rc = max(min(r, 1), -1)
    return {"obv_score": int(math.floor((50 + 50 * rc) + 0.5)), "obv_available": True,
            "obv_change": _json_num(d), "obv_lookback": n}


def _jq_add(xs: Sequence[float]) -> float:
    total = None
    for x in xs:
        total = x if total is None else total + x
    return 0.0 if total is None else total


def _json_num(x: Optional[float]):
    if x is None:
        return None
    return int(x) if float(x).is_integer() and abs(x) < 1e17 else x


def score_mean_reversion_setup(rsi, close, upper, lower, last_volume, avg_volume_20, macd, signal) -> int:
    """score_mean_reversion_setup (awk), int(x + 0.5 + 1000) - 1000 rounding."""
    rsi, c, u, l = awk_num(rsi), awk_num(close), awk_num(upper), awk_num(lower)
    lv, av, m, s = awk_num(last_volume), awk_num(avg_volume_20), awk_num(macd), awk_num(signal)
    rt = (50 - rsi) / 20
    rt = max(min(rt, 1), -1) * 25
    f = 0.5
    if u - l > 0:
        f = (c - l) / (u - l)
    bt = (0.5 - f) / 0.5
    bt = max(min(bt, 1), -1) * 15
    vm = 1.2 if lv + 0 > av + 0 else 1.0
    mt = 5 if m > s else (-5 if m < s else 0)
    x = int(50 + vm * (rt + bt) + mt + 0.5 + 1000) - 1000
    return max(0, min(100, x))


def score_trend_follow_setup(close, ema12, ema26, sma50, sma200, last_volume, avg_volume_30) -> int:
    """score_trend_follow_setup (awk); '' SMA -> term 0."""
    c, e12, e26 = awk_num(close), awk_num(ema12), awk_num(ema26)
    t = 0
    if e12 > e26:
        t += 15
    elif e12 < e26:
        t -= 15
    if sma50 not in (None, ""):
        s50 = awk_num(sma50)
        t += 15 if c > s50 else (-15 if c < s50 else 0)
    if sma200 not in (None, ""):
        s200 = awk_num(sma200)
        t += 10 if c > s200 else (-10 if c < s200 else 0)
    vm = 1.2 if awk_num(last_volume) > awk_num(avg_volume_30) else 1.0
    x = int(50 + vm * t + 0.5 + 1000) - 1000
    return max(0, min(100, x))


_KALMAN_MOD = None


def _kalman_module():
    """lib/kalman_inference.py loaded from the repo (the module bash runs)."""
    global _KALMAN_MOD
    if _KALMAN_MOD is None:
        path = PROJECT_ROOT / "lib" / "kalman_inference.py"
        spec = importlib.util.spec_from_file_location("sst_kalman_inference", str(path))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)  # type: ignore[union-attr]
        _KALMAN_MOD = mod
    return _KALMAN_MOD


def kalman_filtered(closes: Sequence[float], q: float = 0.01, r: float = 0.1) -> List[float]:
    """apply_kalman_filter_fast (python path): filtered prices rounded to 6
    dp exactly as the CLI's JSON (round(p, 6), parsed back by jq)."""
    prices = [float(p) for p in closes]
    if not prices:
        return []
    res = _kalman_module().KalmanFilter1D(q=float(q), r=float(r)).filter(prices)
    return json.loads(json.dumps(res["filtered_prices"]))


def kalman_trend_from_closes(closes: Sequence[float], threshold: float = KALMAN_TREND_THRESHOLD_PCT) -> Dict[str, Any]:
    """kalman_trend_from_closes: 5-bar slope % of the filtered closes."""
    try:
        f = kalman_filtered(closes)
    except Exception:
        f = []
    if len(f) < 6 or f[-6] == 0:
        return {"kalman_trend": 0, "kalman_slope_pct": None, "kalman_available": False}
    s = (f[-1] - f[-6]) / f[-6] * 100
    t = float(threshold)
    trend = 1 if s > t else (-1 if s < -t else 0)
    return {"kalman_trend": trend, "kalman_slope_pct": _json_num(jq_round(s * 10000) / 10000),
            "kalman_available": True}


# ============================================================================
# lib/regime_detector.sh: detect_market_regime with caller closes
# ============================================================================

def _regime_ema_or_mean(period: int, closes: List[str]) -> str:
    if not closes:
        return ""
    if len(closes) < period:
        return printf_f(calc_mean(closes), 2)
    return calc_ema_values(period, closes)[-1]


def _grep_field_unsigned(json_text: str, key: str) -> str:
    """grep -o '"KEY":[0-9.]*' | cut -d: -f2 (negative -> '')."""
    m = re.search(r'"%s":([0-9.]*)' % re.escape(key), json_text)
    return m.group(1) if m else ""


def detect_trend_direction(ema_20: str, ema_50: str) -> str:
    a = int(printf_f(ema_20 if ema_20 != "" else "100", 0))
    b = int(printf_f(ema_50 if ema_50 != "" else "100", 0))
    return "up" if a > b else ("down" if a < b else "neutral")


def detect_market_regime(closes: Sequence[str], symbol: str = "SYM") -> Dict[str, Any]:
    """detect_market_regime SYMBOL N CLOSES... (data_source 'caller'; no
    timestamp). Fewer than 20 closes -> unknown / available false."""
    closes = [num_text(c) for c in closes]
    if len(closes) < 20:
        return {"regime": "unknown", "available": False,
                "reason": "need at least 20 closing prices, got %d" % len(closes),
                "data_source": None, "symbol": symbol}
    ema_20 = _regime_ema_or_mean(20, closes)
    ema_50 = _regime_ema_or_mean(50, closes)
    if ema_20 == "" or ema_50 == "":
        ema_20, ema_50 = "100", "100"
    bb = calc_bollinger_bands(20, 2, closes)
    bb_upper = _grep_field_unsigned(bb, "upper")
    bb_middle = _grep_field_unsigned(bb, "middle")
    bb_lower = _grep_field_unsigned(bb, "lower")
    if bb_middle == "":
        bb_middle, bb_upper, bb_lower = "100", "110", "90"
    d = abs(awk_num(ema_20) - awk_num(ema_50)) * 10
    adx = format(min(d, 100), ".2f")
    volatility = "50"
    if bb_middle != "" and awk_num(bb_middle) > 0:
        v = (awk_num(bb_upper) - awk_num(bb_lower)) * 100 / awk_num(bb_middle)
        volatility = format(min(v, 100), ".2f")
    trend = detect_trend_direction(ema_20, ema_50)
    regime = "sideways"
    if awk_num(volatility) > 20:
        regime = "volatile"
    elif awk_num(adx) > 25:
        if trend == "up":
            regime = "trending_bull"
        elif trend == "down":
            regime = "trending_bear"
    else:
        regime = "sideways"
    return {
        "regime": regime,
        "adx": float(printf_f(adx or "0", 2)),
        "trend": trend,
        "volatility": float(printf_f(volatility or "50", 2)),
        "ema_20": float(printf_f(ema_20 or "100", 2)),
        "ema_50": float(printf_f(ema_50 or "100", 2)),
        "bb_upper": float(printf_f(bb_upper or "110", 2)),
        "bb_middle": float(printf_f(bb_middle or "100", 2)),
        "bb_lower": float(printf_f(bb_lower or "90", 2)),
        "data_source": "caller",
        "symbol": symbol,
    }


# ============================================================================
# build_v2_inputs (jq EMA at full precision, tail means)
# ============================================================================

def _jq_ema(c: List[float], p: int) -> Optional[float]:
    if len(c) < p:
        return None
    e = _jq_add(c[0:p]) / p
    for x in c[p:]:
        e = (x - e) * (2 / (p + 1)) + e
    return e


def _tailmean(a: List[float], n: int) -> Optional[float]:
    if len(a) < n or n == 0:
        return None
    return _jq_add(a[-n:]) / n


def build_v2_inputs(symbol: str, closes: Sequence[str], volumes: Sequence[str], obv: Sequence[str],
                    rsi: str = "50", macd: str = "0", signal: str = "0",
                    bb_upper: str = "0", bb_lower: str = "0") -> Dict[str, Any]:
    """build_v2_inputs: OBV trend, MR/TF setup scores, Kalman trend, regime
    and the jq stats, as the one-line JSON object bash prints."""
    closes_s = [num_text(x) for x in closes]
    c = [float(x) for x in closes_s]
    v = [float(x) for x in volumes]
    stats = {
        "ema_12": _jq_r4(_jq_ema(c, 12)), "ema_26": _jq_r4(_jq_ema(c, 26)),
        "sma_50": _jq_r4(_tailmean(c, 50)), "sma_200": _jq_r4(_tailmean(c, 200)),
        "last_close": c[-1] if c else None, "last_volume": v[-1] if v else None,
        "avg_volume_20": _jq_r4(_tailmean(v, 20)), "avg_volume_30": _jq_r4(_tailmean(v, 30)),
        "closes_count": len(c),
    }
    close_s = closes_s[-1] if closes_s else ""
    lastv_s = _jq_num_str(stats["last_volume"])
    o = score_obv_trend([float(x) for x in obv], v)
    mr = score_mean_reversion_setup(rsi, close_s or "0", bb_upper, bb_lower, lastv_s or "0",
                                    _jq_num_str(stats["avg_volume_20"]) or "0", macd, signal)
    tf = score_trend_follow_setup(close_s or "0", _jq_num_str(stats["ema_12"]) or "0",
                                  _jq_num_str(stats["ema_26"]) or "0", _jq_num_str(stats["sma_50"]),
                                  _jq_num_str(stats["sma_200"]), lastv_s or "0",
                                  _jq_num_str(stats["avg_volume_30"]) or "0")
    k = kalman_trend_from_closes(c)
    regime, detail = "unknown", None
    if len(c) >= 20:
        detail = detect_market_regime(closes_s, symbol)
        if detail.get("available") is not False and detail.get("data_source") == "caller":
            regime = detail.get("regime") or "unknown"
    out: Dict[str, Any] = dict(o)
    out.update({"mr_score": mr, "tf_score": tf})
    out.update(k)
    out.update({
        "regime": regime, "regime_detail": detail,
        "ema_12": _json_num(stats["ema_12"]), "ema_26": _json_num(stats["ema_26"]),
        "sma_50": _json_num(stats["sma_50"]), "sma_200": _json_num(stats["sma_200"]),
        "last_volume": _json_num(stats["last_volume"]),
        "avg_volume_20": _json_num(stats["avg_volume_20"]),
        "avg_volume_30": _json_num(stats["avg_volume_30"]),
        "closes_count": stats["closes_count"],
    })
    return out


# ============================================================================
# StockSwingTrader_Agent.sh: calculate_all_indicators + score_stock
# ============================================================================

def _bars_strings(window) -> Dict[str, List[str]]:
    """Columns of a bars window as the strings bash greps out of the OHLCV
    JSON. Accepts a DataFrame (open/high/low/close/volume) or a list of dicts."""
    if hasattr(window, "columns"):
        rows = window[["high", "low", "close", "volume"]].itertuples(index=False, name=None)
        data = [{"high": h, "low": l, "close": c, "volume": v} for h, l, c, v in rows]
    else:
        data = list(window)
    out = {"high": [], "low": [], "close": [], "volume": []}
    for row in data:
        for k in ("high", "low", "close"):
            out[k].append(num_text(row[k]))
        vol = row["volume"]
        if isinstance(vol, str):
            m = re.match(r"[0-9]*", vol)
            vol_s = m.group(0) if m else ""
        else:
            vol_s = str(int(float(vol)))  # grep '"volume":[0-9]*' keeps the integer part
        out["volume"].append(vol_s)
    return out


def calculate_all_indicators(symbol: str, window, data_source: str = "fixture") -> Optional[Dict[str, Any]]:
    """calculate_all_indicators: indicator strings + v2_inputs + the exact
    echo text score_stock greps. None with fewer than 30 closes."""
    cols = _bars_strings(window)
    closes = cols["close"]
    if len(closes) < 30:
        return None
    rsi = calc_rsi(14, closes)
    m = re.search(r'"rsi":([0-9.]*)', rsi)
    rsi_value = m.group(1) if m else ""
    macd = calc_macd(closes)
    bb = calc_bollinger_bands(20, 2, closes)
    stoch, williams = scan_stoch_williams_from_closes(closes)
    hlc: List[str] = []
    for i in range(len(closes)):
        hlc += [cols["high"][i], cols["low"][i], closes[i]]
    atr = calc_atr(14, hlc)
    cv: List[str] = []
    for i in range(len(closes)):
        cv += [closes[i], cols["volume"][i]]
    obv_vals = calc_obv_values(cv)
    macd_j, bb_j = json.loads(macd), json.loads(bb)
    v2_inputs = build_v2_inputs(
        symbol, closes, cols["volume"], obv_vals, rsi_value or "50",
        _jq_num_str(macd_j.get("macd", 0)) if macd_j.get("macd") is not None else "0",
        _jq_num_str(macd_j.get("signal", 0)) if macd_j.get("signal") is not None else "0",
        _json_text(bb, "upper"), _json_text(bb, "lower"))
    last_close = closes[-1]
    text = (
        "{\n"
        '        "symbol":"%s",\n'
        '        "data_source":"%s",\n'
        '        "last_close":%s,\n'
        '        "indicators": {\n'
        '            "rsi": %s,\n'
        '            "macd": %s,\n'
        '            "bollinger_bands": %s,\n'
        '            "stochastic": %s,\n'
        '            "williams_r": %s,\n'
        '            "atr": %s\n'
        "        },\n"
        '        "v2_inputs": %s\n'
        "    }"
    ) % (symbol, data_source, last_close, rsi, macd, bb, stoch, williams, atr,
         json.dumps(v2_inputs, separators=(",", ":")))
    return {
        "symbol": symbol, "data_source": data_source, "last_close": last_close,
        "indicators": {"rsi": rsi, "macd": macd, "bollinger_bands": bb, "stochastic": stoch,
                       "williams_r": williams, "atr": atr},
        "obv": "[" + ",".join(obv_vals) + "]",
        "v2_inputs": v2_inputs,
        "text": text,
    }


def _json_text(obj_text: str, key: str) -> str:
    """jq -r '.KEY // 0' on bash JSON text (jq 1.8 keeps number literals)."""
    m = re.search(r'"%s":(-?[0-9.]+)' % re.escape(key), obj_text)
    return m.group(1) if m else "0"


def _grep_o(pattern: str, text: str) -> List[str]:
    """grep -o PATTERN (per line, non-empty matches only)."""
    out: List[str] = []
    for line in text.split("\n"):
        out += [m.group(0) for m in re.finditer(pattern, line) if m.group(0)]
    return out


def _pipe(text: str, *patterns: str, head: bool = False) -> str:
    """echo TEXT | grep -o P1 [| head -1] | grep -o P2 ... -> newline joined."""
    cur = text
    for i, p in enumerate(patterns):
        res = _grep_o(p, cur)
        if i == 0 and head:
            res = res[:1]
        cur = "\n".join(res)
    return cur


def score_stock_extraction(ind: Dict[str, Any]) -> Dict[str, str]:
    """The grep extraction in score_stock (StockSwingTrader_Agent.sh), on the
    calculate_all_indicators text. A negative MACD/signal/histogram/%K (and
    '-0.00') becomes ''. Returns the argument strings the scorers get."""
    text = ind["text"]
    rsi = _pipe(text, r'"rsi":[^}]*', head=True)
    rsi_value = (_grep_o(r"[0-9.]*", rsi) or [""])[0]
    macd = _pipe(text, r'"macd":[^}]*', head=True)
    macd_value = _pipe(macd, r'"macd":[0-9.]*', r"[0-9.]*")
    signal_value = _pipe(macd, r'"signal":[0-9.]*', r"[0-9.]*")
    histogram = _pipe(macd, r'"histogram":[0-9.]*', r"[0-9.]*")
    bb = _pipe(text, r'"bollinger_bands":[^}]*}', head=True)
    bb_upper = _pipe(bb, r'"upper":[0-9.]*', r"[0-9.]*")
    bb_middle = _pipe(bb, r'"middle":[0-9.]*', r"[0-9.]*")
    bb_lower = _pipe(bb, r'"lower":[0-9.]*', r"[0-9.]*")
    stoch = _pipe(text, r'"stochastic":[^}]*}', head=True)
    k_line = _pipe(stoch, r'"k_line":[0-9.]*', r"[0-9.]*")
    williams = _pipe(text, r'"williams_r": *-?[0-9.]*')
    williams = "\n".join(m.group(0) for line in williams.split("\n")
                         for m in [re.search(r"-?[0-9.]*$", line)] if m and m.group(0))
    return {"rsi": rsi_value, "macd": macd_value, "signal": signal_value, "histogram": histogram,
            "bb_upper": bb_upper, "bb_middle": bb_middle, "bb_lower": bb_lower,
            "k_line": k_line, "williams_r": williams}


# ============================================================================
# calculate_confluence_score_v2 (MiroFish and agents off)
# ============================================================================

def _awk_f1(x: float) -> str:
    return format(x, ".1f")


def calculate_confluence_score_v2(symbol: str, rsi_score, macd_score, bb_score, obv_score, regime: str,
                                  mr_score=50, tf_score=50, kalman_trend=0, sentiment: Any = "__absent__",
                                  ml_mode: Union[str, Dict[str, Any]] = "absent",
                                  sentiment_weight: float = V2_SENTIMENT_WEIGHT) -> Dict[str, Any]:
    """calculate_confluence_score_v2 without MiroFish/agents. ml_mode:
    'absent' (no predictor: 50 neutral, available), 'unavailable' or
    {'available': False, 'reason': ...}, or {'confidence', 'direction',
    ['data_source']}. sentiment: omitted (<= 9 args) or the 10th arg string."""
    rsi_score, macd_score, bb_score, obv_score = (str(x) for x in (rsi_score, macd_score, bb_score, obv_score))
    mr_score, tf_score, kalman_trend = str(mr_score), str(tf_score), str(kalman_trend)
    sent_passed = sentiment != "__absent__"
    sent_available = sent_applied = False
    sent_score: Any = None
    sent_w = 0.0
    if sent_passed and re.fullmatch(r"-?[0-9]+(\.[0-9]+)?", str(sentiment) if sentiment is not None else ""):
        sent_available = True
        sent_score = awk_num(sentiment) + 0
        w = sentiment_weight
        sent_w = min(float(w), 0.5)
        sent_applied = sent_w > 0

    ml_conf, ml_dir, ml_error = "50", "neutral", ""
    ml_available, ml_reason, ml_ds = True, "", ""
    if ml_mode == "unavailable" or (isinstance(ml_mode, dict) and ml_mode.get("available") is False):
        ml_available, ml_dir = False, "unavailable"
        ml_reason = (ml_mode.get("reason") if isinstance(ml_mode, dict) else None) or "no market data"
    elif isinstance(ml_mode, dict):
        ml_conf = str(ml_mode.get("confidence", 50))
        ml_dir = str(ml_mode.get("direction", "neutral"))
        ml_ds = str(ml_mode.get("data_source", "unknown"))
    elif ml_mode != "absent":
        raise ValueError("ml_mode must be 'absent', 'unavailable' or a dict")

    if regime == "sideways":
        rs = bc("(%s * 0.7) + (%s * 0.3)" % (mr_score, tf_score), 2)
    elif regime in ("trending_bull", "trending_bear"):
        rs = bc("(%s * 0.3) + (%s * 0.7)" % (mr_score, tf_score), 2)
    elif regime == "volatile":
        rs = bc("((%s * 0.5) + (%s * 0.5)) * 0.8" % (mr_score, tf_score), 2)
    else:
        rs = bc("(%s * 0.5) + (%s * 0.5)" % (mr_score, tf_score), 2)
    regime_score = printf_f(rs, 0)
    technical_score = printf_f(bc("(%s + %s + %s) / 3" % (rsi_score, macd_score, bb_score), 2), 0)
    if kalman_trend == "1":
        vt = bc("(%s * 0.8) + (75 * 0.2)" % obv_score, 2)
    elif kalman_trend == "-1":
        vt = bc("(%s * 0.8) + (25 * 0.2)" % obv_score, 2)
    else:
        vt = obv_score
    volume_trend_score = printf_f(vt, 0)

    if not ml_available:
        conf = bc("((%s * 35) + (%s * 30) + (%s * 20)) / 85 * 1 + 0"
                  % (regime_score, technical_score, volume_trend_score), 4)
    else:
        conf = bc("(%s * 0.15) + (%s * 0.35) + (%s * 0.30) + (%s * 0.20)"
                  % (ml_conf, regime_score, technical_score, volume_trend_score), 2)
    if sent_applied:
        conf = format(awk_num(conf) * (1 - sent_w) + sent_score * sent_w, ".4f")
    confluence_score = int(printf_f(conf, 0))

    wp: Dict[str, Any] = {"ml": 15, "regime": 35, "tech": 30, "vt": 20}
    if not ml_available:
        wp = {"ml": 0, "regime": float(_awk_f1(3500 / 85 * 1)), "tech": float(_awk_f1(3000 / 85 * 1)),
              "vt": float(_awk_f1(2000 / 85 * 1))}
    if sent_applied:
        k = 1 - sent_w
        if not ml_available:
            wp.update(regime=float(_awk_f1(3500 / 85 * 1 * k)), tech=float(_awk_f1(3000 / 85 * 1 * k)),
                      vt=float(_awk_f1(2000 / 85 * 1 * k)))
        else:
            wp = {"ml": float(_awk_f1(15 * 1 * k)), "regime": float(_awk_f1(35 * 1 * k)),
                  "tech": float(_awk_f1(30 * 1 * k)), "vt": float(_awk_f1(20 * 1 * k))}

    ml_comp: Dict[str, Any] = {"score": None if not ml_available else _int_or_float(ml_conf),
                               "direction": ml_dir, "weight_percent": wp["ml"]}
    data_warning = ""
    if not ml_available:
        ml_comp.update({"available": False, "reason": ml_reason, "data_source": None})
    elif ml_ds:
        ml_comp.update({"available": True, "data_source": ml_ds})
        if ml_ds == "synthetic":
            data_warning = "ML component used SYNTHETIC features (demo/test mode); not market data"

    components: Dict[str, Any] = {
        "ml_confidence": ml_comp,
        "regime_score": {"score": int(regime_score), "regime": regime, "weight_percent": wp["regime"]},
        "technical_score": {"score": int(technical_score), "weight_percent": wp["tech"]},
        "volume_trend_score": {"score": int(volume_trend_score), "weight_percent": wp["vt"]},
    }
    if sent_passed:
        components["sentiment"] = {"score": _int_or_float(sent_score) if sent_available else None,
                                   "available": sent_available,
                                   "weight_percent": float(_awk_f1(100 * sent_w)) if sent_applied else 0}

    bull = bear = 0
    ml_c = _to_float(ml_conf)
    if ml_dir == "up" and ml_c > 60:
        bull += 1
    elif ml_dir == "down" and ml_c > 60:
        bear += 1
    for sc in (int(regime_score), int(technical_score), int(volume_trend_score)):
        if sc > 60:
            bull += 1
        elif sc < 40:
            bear += 1
    agreement = bull + bear
    rec, note = "HOLD", ""
    if agreement >= 3:
        if bull >= 3 and bear == 0:
            if confluence_score > 70:
                rec, note = "STRONG_BUY", "Strong consensus across all indicators"
            elif confluence_score > 55:
                rec, note = "BUY", "Multiple bullish signals confirmed"
        elif bear >= 3 and bull == 0:
            if confluence_score < 30:
                rec, note = "STRONG_SELL", "Strong consensus across all indicators"
            elif confluence_score < 45:
                rec, note = "SELL", "Multiple bearish signals confirmed"
    else:
        if confluence_score > 60:
            rec, note = "BUY", "Moderately bullish; some conflicting signals"
        elif confluence_score < 40:
            rec, note = "SELL", "Moderately bearish; some conflicting signals"
        else:
            rec, note = "HOLD", "Mixed signals; await clearer direction"

    return {
        "confluence_score": confluence_score,
        "recommendation": rec,
        "signal_strength": agreement,
        "components": components,
        "breakdown": {
            "symbol": symbol,
            "individual_scores": {
                "rsi": int(rsi_score), "macd": int(macd_score), "bollinger_bands": int(bb_score),
                "obv": int(obv_score), "mean_reversion": int(mr_score), "trend_following": int(tf_score),
                "kalman_trend": int(kalman_trend),
            },
            "signal_counts": {"bullish_signals": bull, "bearish_signals": bear, "total_agreement": agreement},
        },
        "metadata": {"confidence_note": note, "ml_error": ml_error, "ml_available": ml_available,
                     "data_warning": data_warning},
    }


def _int_or_float(x: Any):
    f = _to_float(x)
    return int(f) if f.is_integer() else f


# ============================================================================
# Whole scan path for one window
# ============================================================================

def score_stock(symbol: str, ind: Dict[str, Any], ml_mode: Union[str, Dict[str, Any]] = "absent",
                sentiment: str = "na", bollinger_price: Optional[str] = None) -> Dict[str, Any]:
    """score_stock in v2 mode (offline: no live quote, so the Bollinger price
    is the last close unless BOLLINGER_PRICE > 0 is given)."""
    ex = score_stock_extraction(ind)
    price = bollinger_price
    if price is None or awk_num(price) <= 0:
        price = ind["last_close"]
    scores = {
        "rsi": int(score_rsi(ex["rsi"])),
        "macd": int(score_macd(ex["macd"], ex["signal"], ex["histogram"])),
        "bollinger_bands": int(score_bollinger_bands(price, ex["bb_upper"], ex["bb_middle"], ex["bb_lower"])),
        "stochastic": int(score_stochastic(ex["k_line"])),
        "williams_r": int(score_williams_r(ex["williams_r"])),
    }
    v2 = ind.get("v2_inputs")
    v2_ok = isinstance(v2, dict)
    if not v2_ok:
        v2 = {"obv_score": 50, "obv_available": False, "mr_score": 50, "tf_score": 50,
              "kalman_trend": 0, "kalman_available": False, "regime": "unknown"}

    def _get(key, default):
        val = v2.get(key)
        return default if val is None or val is False else val

    obv_s, mr_s, tf_s = str(_get("obv_score", 50)), str(_get("mr_score", 50)), str(_get("tf_score", 50))
    kt, regime = str(_get("kalman_trend", 0)), str(_get("regime", "unknown"))
    obv_s = obv_s if re.fullmatch(r"[0-9]+", obv_s) else "50"
    mr_s = mr_s if re.fullmatch(r"[0-9]+", mr_s) else "50"
    tf_s = tf_s if re.fullmatch(r"[0-9]+", tf_s) else "50"
    kt = kt if re.fullmatch(r"-?[01]", kt) else "0"
    regime = regime or "unknown"
    scores["obv"] = int(obv_s)
    sent_arg = sentiment if sentiment not in (None, "", "null") else "na"
    scores["sentiment"] = None if sent_arg == "na" else _int_or_float(sent_arg)
    conf_v2 = calculate_confluence_score_v2(
        symbol, scores["rsi"], scores["macd"], scores["bollinger_bands"], obv_s, regime,
        mr_s, tf_s, kt, sent_arg, ml_mode=ml_mode)
    return {"symbol": symbol, "scores": scores, "confluence_v2": conf_v2, "v2_inputs": v2,
            "v2_inputs_available": v2_ok, "extraction": ex}


def v2_from_bars(window, ml_mode: Union[str, Dict[str, Any]] = "unavailable", sentiment: str = "na",
                 bollinger_price: Optional[str] = None, symbol: str = "SYM",
                 data_source: str = "fixture") -> Optional[Dict[str, Any]]:
    """calculate_all_indicators -> score_stock -> calculate_confluence_score_v2
    on one bars window (MiroFish and agents off). Returns None with fewer than
    30 bars, else {confluence_score, recommendation, signal_strength,
    components, breakdown, metadata, v2_inputs, scores, indicators}."""
    ind = calculate_all_indicators(symbol, window, data_source)
    if ind is None:
        return None
    s = score_stock(symbol, ind, ml_mode=ml_mode, sentiment=sentiment, bollinger_price=bollinger_price)
    out = dict(s["confluence_v2"])
    out.update({"v2_inputs": s["v2_inputs"], "scores": s["scores"], "indicators": ind["indicators"]})
    return out
