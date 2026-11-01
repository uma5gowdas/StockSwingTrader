"""Technical Agent: `python -m agents technical run|status`.

run: for each symbol, load about 400 calendar days of daily bars ending at
AS_OF (agents.data.load_bars; offline = fixtures, labeled synthetic), compute
the TA-Lib features (talib_features.compute_features) and write one envelope
to cache/agents/technical/<as_of>/<SYMBOL>.json (atomic, schema-validated).

  score       round((score_rsi + score_macd + score_bollinger_bands) / 3),
              the bash scorers (bash_compat, bc semantics) applied to the
              TA-Lib RSI / MACD / BBANDS values formatted %.2f: a cross-check
              of the scan's 30% technical component
  direction   trend_state up -> bullish, down -> bearish, else neutral
  confidence  min(1, ADX14 / 50)
  features    every TA-Lib value + regime_adx (bash rules, real ADX14),
              regime_bash (bash_compat.detect_market_regime on the last 60
              closes) and atr_14
  ttl_hours   36

Fewer than MIN_BARS (60) bars, or no data -> an unavailable envelope (still
written, so the bash adapter reports UNAVAILABLE instead of MISSING).
The scan reads features.regime_adx only when AGENTS_ENABLED=true and
AGENT_TECHNICAL_ENABLED=true (D14); it never runs this agent itself.
"""

from __future__ import annotations

import argparse
from datetime import date, timedelta
from typing import Any, Dict, Iterable, List, Optional

from agents.cache import cache_root, check_as_of, write_envelope
from agents.envelope import make_envelope, unavailable_envelope

AGENT = "technical"
MIN_BARS = 60
HISTORY_DAYS = 400
TTL_HOURS = 36


def _as_of_date(as_of: Optional[str]) -> date:
    if as_of:
        check_as_of(as_of)
        return date.fromisoformat(as_of)
    from agents.data.alpaca import ny_today

    return ny_today()


def build_envelope(symbol: str, as_of: str, bars) -> Dict[str, Any]:
    """Envelope for one symbol from a BarsResult / Unavailable."""
    from agents.technical import bash_compat as bc
    from agents.technical.talib_features import compute_features

    if not getattr(bars, "available", False):
        return unavailable_envelope(AGENT, symbol, as_of, getattr(bars, "reason", None) or "no data")
    df = bars.df
    if len(df) < MIN_BARS:
        return unavailable_envelope(AGENT, symbol, as_of, "insufficient bars: %d < %d" % (len(df), MIN_BARS))
    feats = compute_features(df)
    closes = [bc.num_text(float(x)) for x in df["close"].iloc[-MIN_BARS:]]
    feats["regime_bash"] = bc.detect_market_regime(closes, symbol).get("regime")

    def f2(x):
        return "" if x is None else format(x, ".2f")

    parts = [
        int(bc.score_rsi(f2(feats.get("rsi_14")))),
        int(bc.score_macd(f2(feats.get("macd")), f2(feats.get("macd_signal")), f2(feats.get("macd_hist")))),
        int(bc.score_bollinger_bands(f2(feats.get("close")), f2(feats.get("bb_upper")),
                                     f2(feats.get("bb_middle")), f2(feats.get("bb_lower")))),
    ]
    score = int(format(sum(parts) / 3.0, ".0f"))
    feats["score_parts"] = {"rsi": parts[0], "macd": parts[1], "bollinger_bands": parts[2]}
    direction = {"up": "bullish", "down": "bearish"}.get(feats.get("trend_state"), "neutral")
    adx = feats.get("adx_14")
    confidence = None if adx is None else round(min(1.0, max(0.0, adx / 50.0)), 4)
    return make_envelope(
        AGENT, symbol, as_of,
        score=max(0, min(100, score)), direction=direction, confidence=confidence,
        data_sources=[bars.data_source], synthetic=bool(bars.synthetic),
        warning=bars.warning,
        features=feats, ttl_hours=TTL_HOURS,
    )


def run(symbols: Iterable[str], as_of: Optional[str] = None, offline: bool = False,
        root=None, client=None) -> Dict[str, Any]:
    """Write one envelope per symbol; returns {as_of, written, unavailable, files}."""
    import os

    from agents.data import load_bars

    if offline:
        os.environ["SST_OFFLINE"] = "1"
    d = _as_of_date(as_of)
    as_of_s = d.isoformat()
    syms = list(symbols)
    bars = load_bars(syms, d - timedelta(days=HISTORY_DAYS), d, as_of=d, client=client)
    written: List[str] = []
    unavailable: Dict[str, str] = {}
    files: List[str] = []
    for s in syms:
        env = build_envelope(s, as_of_s, bars[s])
        files.append(str(write_envelope(env, root)))
        if env["available"]:
            written.append(s)
        else:
            unavailable[s] = env["reason"]
    return {"agent": AGENT, "as_of": as_of_s, "written": written, "unavailable": unavailable, "files": files}


def status(root=None) -> Dict[str, Any]:
    """Cached as_of dirs and symbol counts under cache/agents/technical."""
    base = (root or cache_root()) / AGENT
    dirs = []
    if base.is_dir():
        for p in sorted(base.iterdir()):
            if p.is_dir():
                dirs.append({"as_of": p.name, "symbols": len(list(p.glob("*.json")))})
    return {"technical_cache_dir": str(base), "as_of_dirs": dirs}


# ---------------------------------------------------------------------------
# CLI handlers (registered in agents.cli.HANDLERS)
# ---------------------------------------------------------------------------

def cli_run(args: argparse.Namespace) -> int:
    from agents.cli import EXIT_ERROR, EXIT_OK, EXIT_UNAVAILABLE, emit, parse_symbols

    try:
        syms = parse_symbols(args.symbols)
    except ValueError as exc:
        emit({"error": "invalid_symbol", "detail": str(exc)})
        return EXIT_ERROR
    if not syms:
        emit({"error": "missing_symbols", "detail": "use --symbols AAA,BBB"})
        return EXIT_ERROR
    summary = run(syms, as_of=args.as_of, offline=bool(args.offline))
    emit(summary)
    return EXIT_OK if summary["written"] else EXIT_UNAVAILABLE


def cli_status(args: argparse.Namespace) -> int:
    from agents.cli import EXIT_OK, emit, status_payload

    out = status_payload(AGENT)
    out.update(status())
    emit(out)
    return EXIT_OK
