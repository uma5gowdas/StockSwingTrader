"""$0 LLM budget ledger: every call is authorised here BEFORE any HTTP request.

  LLM_MONTHLY_BUDGET_USD (default 0)  cloud calls refused when estimated cost
                                      + month-to-date spend exceeds it (so a
                                      budget of 0 refuses every cloud call)
  LLM_MAX_CALLS_PER_RUN  (default 0)  calls per process (local ones included;
                                      0 refuses every call)
Ledger: <cache_root>/llm/ledger.jsonl, one JSON line per authorised call.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


class BudgetRefused(RuntimeError):
    """The call would exceed LLM_MONTHLY_BUDGET_USD or LLM_MAX_CALLS_PER_RUN."""


def _num(name: str, default: float) -> float:
    try:
        value = float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default
    return value if value >= 0 else default


def ledger_path() -> Path:
    from agents.cache import cache_root

    return cache_root() / "llm" / "ledger.jsonl"


class BudgetLedger:
    """Month-to-date spend and per-run call count."""

    def __init__(self, path: Optional[Path] = None):
        self.path = Path(path) if path else ledger_path()
        self.calls_this_run = 0

    def month_to_date_usd(self) -> float:
        month = datetime.now(timezone.utc).strftime("%Y-%m")
        total = 0.0
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                for line in fh:
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        continue
                    if str(rec.get("ts", "")).startswith(month):
                        total += float(rec.get("cost_usd", 0) or 0)
        except OSError:
            pass
        return total

    def authorize(self, mode: str, est_cost_usd: float) -> None:
        """Raise BudgetRefused unless the call fits both limits."""
        max_calls = int(_num("LLM_MAX_CALLS_PER_RUN", 0))
        if self.calls_this_run + 1 > max_calls:
            raise BudgetRefused("LLM_MAX_CALLS_PER_RUN=%d reached" % max_calls)
        if mode == "cloud":
            budget = _num("LLM_MONTHLY_BUDGET_USD", 0.0)
            if budget <= 0 or self.month_to_date_usd() + max(est_cost_usd, 0.0) > budget:
                raise BudgetRefused("LLM_MONTHLY_BUDGET_USD=%g leaves no room" % budget)

    def record(self, mode: str, model: Optional[str], tokens: int, cost_usd: float) -> None:
        """Count the call and append it to the ledger."""
        self.calls_this_run += 1
        self.path.parent.mkdir(parents=True, exist_ok=True)
        rec = {
            "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "mode": mode, "model": model, "tokens": int(tokens), "cost_usd": float(cost_usd),
        }
        with open(self.path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec) + "\n")
