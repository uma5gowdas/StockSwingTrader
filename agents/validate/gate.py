"""Gate criteria (six-agent plan §5.6, phase 0-1 plan D20) and gate files.

Thresholds (env-overridable):
  GATE_MIN_OOS_SHARPE      0.5    oos_sharpe >= 0.5
  GATE_SPY_SHARPE_MARGIN   0.1    oos_sharpe >= spy_sharpe - 0.1
  GATE_MIN_DSR             0.95   dsr >= 0.95
  GATE_MAX_PBO             0.30   pbo <= 0.30
  GATE_MAX_DD_MULT         1.2    oos_max_dd <= 1.2 x spy_max_dd
  GATE_MIN_OOS_TRADES      100    oos_trades >= 100
  GATE_MIN_POSITIVE_FOLDS  0.60   share of folds with oos_return > 0 >= 0.60
  GATE_MIN_BASELINE_FOLDS  0.60   baseline_improvement: share of folds whose OOS
                           return beats the baseline signal's OOS return on
                           the same folds >= 0.60; applicable only when the
                           metrics carry baseline_signal_id (Phase 2 quant
                           signals); otherwise not_applicable (the four base
                           signals; recorded, not counted)
A missing metric (None) fails its criterion.
passed = every applicable criterion passed AND synthetic is false AND every
symbol (and the benchmark) has real data. Reasons list each failure
('synthetic_data', 'non_real_data:<SYM>', '<criterion>: <value> <op>
<threshold>').

Gate file cache/agents/gates/<signal_id>.json: atomic, schema-validated
(agents/schemas/gate.schema.json); lib/agent_adapter.sh agent_gate_get reads
signal_id, generated_at, passed and synthetic.
"""

from __future__ import annotations

import json
import math
import os
from functools import lru_cache
from pathlib import Path
from typing import Any, Dict, List, Optional

from jsonschema import Draft202012Validator

from agents.cache import atomic_write_json, gate_path

SCHEMA_PATH = Path(__file__).resolve().parent.parent / "schemas" / "gate.schema.json"

GATE_DEFAULTS = {
    "GATE_MIN_OOS_SHARPE": 0.5,
    "GATE_SPY_SHARPE_MARGIN": 0.1,
    "GATE_MIN_DSR": 0.95,
    "GATE_MAX_PBO": 0.30,
    "GATE_MAX_DD_MULT": 1.2,
    "GATE_MIN_OOS_TRADES": 100,
    "GATE_MIN_POSITIVE_FOLDS": 0.60,
    "GATE_MIN_BASELINE_FOLDS": 0.60,
}
CRITERIA = ("min_oos_sharpe", "vs_spy_sharpe", "min_dsr", "max_pbo", "max_drawdown_vs_spy",
            "min_oos_trades", "min_positive_folds", "baseline_improvement")
REAL_SOURCE_PREFIXES = ("alpaca:", "yfinance")


class GateError(ValueError):
    """Gate dict does not satisfy the schema or the rule checks."""


def thresholds(env: Optional[Dict[str, str]] = None) -> Dict[str, float]:
    env = os.environ if env is None else env
    out = {}
    for k, d in GATE_DEFAULTS.items():
        try:
            v = float(env.get(k, d))
            out[k] = v if math.isfinite(v) else float(d)
        except (TypeError, ValueError):
            out[k] = float(d)
    return out


def _num(x) -> Optional[float]:
    if x is None:
        return None
    try:
        f = float(x)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def _crit(value, threshold, op: str) -> Dict[str, Any]:
    v, t = _num(value), _num(threshold)
    if v is None or t is None:
        ok = False
    elif op == ">=":
        ok = v >= t
    else:
        ok = v <= t
    return {"value": v, "threshold": t, "op": op, "passed": bool(ok), "applicable": True}


def evaluate_criteria(metrics: Dict[str, Any], th: Optional[Dict[str, float]] = None) -> Dict[str, Dict[str, Any]]:
    """Criteria dict {name: {value, threshold, op, passed, applicable}}."""
    th = th or thresholds()
    base_min = th.get("GATE_MIN_BASELINE_FOLDS", GATE_DEFAULTS["GATE_MIN_BASELINE_FOLDS"])
    if metrics.get("baseline_signal_id"):
        baseline = _crit(metrics.get("pct_folds_beating_baseline"), base_min, ">=")
        baseline["note"] = "share of folds with OOS return > %s's OOS return" % metrics["baseline_signal_id"]
    else:
        baseline = {"value": None, "threshold": None, "op": "n/a", "passed": None, "applicable": False,
                    "note": "not_applicable: base signal (no added component to compare)"}
    spy_sr = _num(metrics.get("spy_sharpe"))
    spy_dd = _num(metrics.get("spy_max_dd"))
    return {
        "min_oos_sharpe": _crit(metrics.get("oos_sharpe"), th["GATE_MIN_OOS_SHARPE"], ">="),
        "vs_spy_sharpe": _crit(metrics.get("oos_sharpe"),
                               None if spy_sr is None else spy_sr - th["GATE_SPY_SHARPE_MARGIN"], ">="),
        "min_dsr": _crit(metrics.get("dsr"), th["GATE_MIN_DSR"], ">="),
        "max_pbo": _crit(metrics.get("pbo"), th["GATE_MAX_PBO"], "<="),
        "max_drawdown_vs_spy": _crit(metrics.get("oos_max_dd"),
                                     None if spy_dd is None else spy_dd * th["GATE_MAX_DD_MULT"], "<="),
        "min_oos_trades": _crit(metrics.get("oos_trades"), th["GATE_MIN_OOS_TRADES"], ">="),
        "min_positive_folds": _crit(metrics.get("pct_positive_folds"), th["GATE_MIN_POSITIVE_FOLDS"], ">="),
        "baseline_improvement": baseline,
    }


def is_real_source(src: Optional[str]) -> bool:
    return bool(src) and any(str(src).startswith(p) for p in REAL_SOURCE_PREFIXES)


def decide(criteria: Dict[str, Dict[str, Any]], synthetic: bool,
           symbol_sources: Dict[str, str]) -> (bool, List[str]):
    """(passed, reasons)."""
    reasons: List[str] = []
    if synthetic:
        reasons.append("synthetic_data")
    for sym, src in sorted(symbol_sources.items()):
        if not is_real_source(src):
            reasons.append("non_real_data:%s" % sym)
    for name in CRITERIA:
        c = criteria.get(name)
        if not c or not c.get("applicable"):
            continue
        if not c.get("passed"):
            reasons.append("%s: %s %s %s" % (name, _fmt(c.get("value")), c.get("op"), _fmt(c.get("threshold"))))
    return (not reasons), reasons


def _fmt(x) -> str:
    if x is None:
        return "null"
    if isinstance(x, float):
        return "%.4g" % x
    return str(x)


@lru_cache(maxsize=1)
def _validator() -> Draft202012Validator:
    schema = json.loads(SCHEMA_PATH.read_text())
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema)


def gate_errors(obj: Any) -> List[str]:
    errors = ["%s: %s" % ("/".join(str(p) for p in e.absolute_path) or "<root>", e.message)
              for e in sorted(_validator().iter_errors(obj), key=lambda e: list(e.absolute_path))]
    if isinstance(obj, dict) and obj.get("passed") is True:
        if obj.get("synthetic") is not False:
            errors.append("rule: passed requires synthetic false")
        for name, c in (obj.get("criteria") or {}).items():
            if isinstance(c, dict) and c.get("applicable") and c.get("passed") is not True:
                errors.append("rule: passed requires criterion %s passed" % name)
        if obj.get("reasons"):
            errors.append("rule: passed requires no reasons")
    return errors


def validate_gate(obj: Any) -> Dict[str, Any]:
    errors = gate_errors(obj)
    if errors:
        raise GateError("; ".join(errors))
    return obj


def write_gate(gate: Dict[str, Any], root: Optional[Path] = None) -> Path:
    """Validate GATE and write it atomically to gates/<signal_id>.json."""
    validate_gate(gate)
    return atomic_write_json(gate_path(gate["signal_id"], root), gate)


def read_gates(root: Optional[Path] = None) -> List[Dict[str, Any]]:
    """Every parsable gate file under gates/ (sorted by file name)."""
    from agents.cache import cache_root, read_json

    base = (root or cache_root()) / "gates"
    out = []
    if base.is_dir():
        for p in sorted(base.glob("*.json")):
            g = read_json(p)
            if isinstance(g, dict):
                out.append(g)
    return out
