"""Offline fixtures (tests/fixtures/agents/). Fixture bars are generated
(tests/fixtures/agents/make_fixtures.py), so they are always synthetic."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Optional

from agents.config import PROJECT_ROOT

FIXTURE_WARNING = "Offline fixture bars (generated, SYNTHETIC); not market data"


def fixtures_dir() -> Path:
    """tests/fixtures/agents under the project root."""
    return PROJECT_ROOT / "tests" / "fixtures" / "agents"


def is_offline() -> bool:
    """True when SST_OFFLINE == '1' (no network; fixtures only)."""
    return os.environ.get("SST_OFFLINE") == "1"


def load_fixture_bars(symbol: str):
    """Fixture bars for SYMBOL as a DataFrame (DatetimeIndex 'date'; columns
    open, high, low, close, volume), or None when there is no fixture."""
    from agents.cache import check_symbol  # local import: avoid cycles

    try:
        check_symbol(symbol)
    except ValueError:
        return None
    path = fixtures_dir() / "bars" / ("%s.csv" % symbol)
    if not path.is_file():
        return None
    import pandas as pd

    df = pd.read_csv(path, parse_dates=["date"]).set_index("date").sort_index()
    return df[["open", "high", "low", "close", "volume"]].astype(float)
