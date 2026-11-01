"""Cache layout and atomic JSON writes.

Layout (all under cache_root(), gitignored):
  <agent>/<as_of>/<SYMBOL>.json   agent envelopes
  gates/<signal_id>.json          validation gates
  validate/...                    validation reports, signal cache, trials
  data/alpaca/...                 bar cache
  llm/ledger.jsonl                LLM budget ledger
"""

from __future__ import annotations

import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any, Optional, Union

from agents import AGENT_NAMES
from agents.config import PROJECT_ROOT
from agents.envelope import validate_envelope

SYMBOL_RE = re.compile(r"^[A-Z0-9.-]{1,10}$")
AS_OF_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
SIGNAL_ID_RE = re.compile(r"^[a-z0-9_]{1,64}$")


def cache_root() -> Path:
    """AGENT_CACHE_DIR (default <project>/cache/agents); relative -> project root."""
    raw = os.environ.get("AGENT_CACHE_DIR") or "cache/agents"
    path = Path(raw)
    if not path.is_absolute():
        path = PROJECT_ROOT / path
    return path


def check_symbol(symbol: str) -> str:
    """Return SYMBOL if it matches ^[A-Z0-9.-]{1,10}$ without '..'; else ValueError."""
    if not isinstance(symbol, str) or not SYMBOL_RE.fullmatch(symbol) or ".." in symbol:
        raise ValueError("invalid symbol: %r" % (symbol,))
    return symbol


def check_as_of(as_of: str) -> str:
    if not isinstance(as_of, str) or not AS_OF_RE.fullmatch(as_of):
        raise ValueError("invalid as_of (YYYY-MM-DD): %r" % (as_of,))
    return as_of


def cache_path(agent: str, as_of: str, symbol: str, root: Optional[Path] = None) -> Path:
    """Path of an agent envelope; validates every component (no traversal)."""
    if agent not in AGENT_NAMES:
        raise ValueError("unknown agent: %r" % (agent,))
    check_as_of(as_of)
    check_symbol(symbol)
    return (root or cache_root()) / agent / as_of / ("%s.json" % symbol)


def gate_path(signal_id: str, root: Optional[Path] = None) -> Path:
    """Path of a gate file gates/<signal_id>.json (signal_id ^[a-z0-9_]{1,64}$)."""
    if not isinstance(signal_id, str) or not SIGNAL_ID_RE.fullmatch(signal_id):
        raise ValueError("invalid signal id: %r" % (signal_id,))
    return (root or cache_root()) / "gates" / ("%s.json" % signal_id)


def atomic_write_json(path: Union[str, Path], obj: Any) -> Path:
    """Write OBJ as JSON to PATH atomically (temp file in the same dir, fsync,
    os.replace). The temp file is removed on any error."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(obj, indent=2, sort_keys=False, allow_nan=False) + "\n"
    tmp = tempfile.NamedTemporaryFile(
        "w", dir=str(path.parent), prefix=".%s." % path.name, suffix=".tmp",
        delete=False, encoding="utf-8",
    )
    try:
        with tmp:
            tmp.write(data)
            tmp.flush()
            os.fsync(tmp.fileno())
        os.replace(tmp.name, path)
    except BaseException:
        try:
            os.unlink(tmp.name)
        except FileNotFoundError:
            pass
        raise
    return path


def write_envelope(envelope: dict, root: Optional[Path] = None) -> Path:
    """Validate ENVELOPE and write it to its cache path; returns the path."""
    validate_envelope(envelope)
    path = cache_path(envelope["agent"], envelope["as_of"], envelope["symbol"], root=root)
    return atomic_write_json(path, envelope)


def read_json(path: Union[str, Path]) -> Optional[Any]:
    """Parsed JSON at PATH, or None if missing/unparsable."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None
