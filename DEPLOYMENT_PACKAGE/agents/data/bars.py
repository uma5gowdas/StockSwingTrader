"""load_bars: one entry point for daily bars with explicit data-source labels.

  offline (SST_OFFLINE=1)  fixtures only: data_source 'fixture', synthetic
                           True, warning set; no fixture -> Unavailable
  online                   Alpaca first ('alpaca:sip' / 'alpaca:iex');
                           then yfinance only when AGENT_DATA_FALLBACK=yfinance
                           ('yfinance', warning 'fallback source'); then
                           fixtures only when SST_ALLOW_SYNTHETIC=1 (labeled)
Never silently synthetic.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Dict, Iterable, Optional, Union

import pandas as pd

from agents.cache import check_symbol
from agents.data import yf_fallback
from agents.data.alpaca import staleness_cutoff, ny_today, _parse_date
from agents.fixtures import FIXTURE_WARNING, is_offline, load_fixture_bars


@dataclass
class BarsResult:
    df: pd.DataFrame
    data_source: str
    synthetic: bool
    warning: Optional[str]
    available: bool = True


@dataclass
class Unavailable:
    reason: str
    available: bool = False
    data_source: Optional[str] = None


def _slice(df: pd.DataFrame, start, end, as_of) -> pd.DataFrame:
    lo = pd.Timestamp(_parse_date(start))
    hi = pd.Timestamp(min(_parse_date(end), _parse_date(as_of)))
    return df[(df.index >= lo) & (df.index <= hi)]


def _fixture(symbol: str, start, end, as_of) -> Union[BarsResult, Unavailable]:
    df = load_fixture_bars(symbol)
    if df is None:
        return Unavailable("no fixture for %s" % symbol)
    df = _slice(df, start, end, as_of)
    if not len(df):
        return Unavailable("no fixture bars in range")
    return BarsResult(df, "fixture", True, FIXTURE_WARNING)


def load_bars(symbols: Iterable[str], start, end, as_of=None, client=None) -> Dict[str, Union[BarsResult, Unavailable]]:
    """{SYM: BarsResult | Unavailable} for daily bars START..END (<= AS_OF)."""
    syms = [check_symbol(s) for s in symbols]
    as_of = _parse_date(as_of) if as_of else ny_today()
    if is_offline():
        return {s: _fixture(s, start, end, as_of) for s in syms}

    if client is None:
        from agents.data.alpaca import AlpacaBarsClient

        client = AlpacaBarsClient()  # SafetyError (non-paper / bad host) propagates
    out: Dict[str, Union[BarsResult, Unavailable]] = dict(client.fetch(syms, start, end, as_of=as_of))

    if yf_fallback.is_enabled():
        cutoff = staleness_cutoff(as_of)
        for s in syms:
            if isinstance(out.get(s), BarsResult):
                continue
            df = yf_fallback.fetch(s, start, end)
            if df is None:
                continue
            df = _slice(df, start, end, as_of)
            if len(df) and df.index[-1].date() >= cutoff:
                out[s] = BarsResult(df, "yfinance", False, yf_fallback.WARNING)

    if os.environ.get("SST_ALLOW_SYNTHETIC") == "1":
        for s in syms:
            if not isinstance(out.get(s), BarsResult):
                fx = _fixture(s, start, end, as_of)
                if isinstance(fx, BarsResult):
                    out[s] = fx
    return {s: out[s] for s in syms}
