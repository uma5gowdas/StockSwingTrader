"""Common agent envelope (six-agent plan section 5.2) and its validation.

Rules on top of the JSON Schema (agents/schemas/envelope.schema.json):
  - available false  -> score null, direction null, confidence null,
                        data_sources [] and a non-empty reason
  - synthetic true   -> non-empty warning
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any, Dict, List, Optional

from jsonschema import Draft202012Validator

from agents import __version__

SCHEMA_PATH = Path(__file__).resolve().parent / "schemas" / "envelope.schema.json"
DEFAULT_TTL_HOURS = 36


class EnvelopeError(ValueError):
    """Envelope does not satisfy the schema or the rule checks."""


def utc_now_iso() -> str:
    """Current time as ISO-8601 UTC (YYYY-mm-ddTHH:MM:SSZ)."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@lru_cache(maxsize=1)
def _validator() -> Draft202012Validator:
    schema = json.loads(SCHEMA_PATH.read_text())
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema)


def envelope_errors(obj: Any) -> List[str]:
    """All schema and rule violations of OBJ (empty list when valid)."""
    errors = [
        "%s: %s" % ("/".join(str(p) for p in e.absolute_path) or "<root>", e.message)
        for e in sorted(_validator().iter_errors(obj), key=lambda e: list(e.absolute_path))
    ]
    if not isinstance(obj, dict):
        return errors
    if obj.get("available") is False:
        if obj.get("score") is not None:
            errors.append("rule: available false requires score null")
        if obj.get("direction") is not None:
            errors.append("rule: available false requires direction null")
        if obj.get("confidence") is not None:
            errors.append("rule: available false requires confidence null")
        if obj.get("data_sources"):
            errors.append("rule: available false requires data_sources []")
        if not obj.get("reason"):
            errors.append("rule: available false requires a reason")
    if obj.get("synthetic") is True and not obj.get("warning"):
        errors.append("rule: synthetic true requires a non-empty warning")
    return errors


def validate_envelope(obj: Any) -> Dict[str, Any]:
    """Return OBJ when valid; raise EnvelopeError listing every violation."""
    errors = envelope_errors(obj)
    if errors:
        raise EnvelopeError("; ".join(errors))
    return obj


def make_envelope(
    agent: str,
    symbol: str,
    as_of: str,
    *,
    score: Optional[float],
    direction: Optional[str],
    confidence: Optional[float],
    data_sources: List[str],
    synthetic: bool = False,
    warning: Optional[str] = None,
    available: bool = True,
    reason: Optional[str] = None,
    features: Optional[Dict[str, Any]] = None,
    evidence: Optional[List[Dict[str, Any]]] = None,
    veto: Optional[Dict[str, Any]] = None,
    llm: Optional[Dict[str, Any]] = None,
    validation: Optional[Dict[str, Any]] = None,
    ttl_hours: float = DEFAULT_TTL_HOURS,
    generated_at: Optional[str] = None,
    agent_version: str = __version__,
) -> Dict[str, Any]:
    """Build and validate an envelope with exactly the section 5.2 fields."""
    env = {
        "agent": agent,
        "agent_version": agent_version,
        "symbol": symbol,
        "as_of": as_of,
        "generated_at": generated_at or utc_now_iso(),
        "ttl_hours": ttl_hours,
        "available": available,
        "reason": reason,
        "data_sources": list(data_sources),
        "synthetic": synthetic,
        "score": score,
        "direction": direction,
        "confidence": confidence,
        "veto": veto or {"active": False, "code": None, "detail": None},
        "features": features or {},
        "evidence": evidence or [],
        "llm": llm or {"mode": "none", "model": None, "tokens": 0, "cost_usd": 0.0, "cached": False},
        "validation": validation or {"gate_id": None, "passed": False},
        "warning": warning,
    }
    return validate_envelope(env)


def unavailable_envelope(agent: str, symbol: str, as_of: str, reason: str, **kwargs: Any) -> Dict[str, Any]:
    """Envelope for 'no usable data': available false, score/direction/confidence null."""
    return make_envelope(
        agent, symbol, as_of,
        score=None, direction=None, confidence=None, data_sources=[],
        available=False, reason=reason or "unavailable", **kwargs,
    )
