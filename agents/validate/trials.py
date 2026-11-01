"""Trial log cache/agents/validate/trials.jsonl (one JSON object per line).

Every evaluation of a config is appended:
  {run_id, ts, signal_id, config_hash, params, fold, phase: train|test|full,
   sharpe, trades, data_source}
config_hash = sha256 of the sorted params + costs + universe + data range,
so the same config on another universe / range / cost model is a new trial.
The DSR trial count is N = max(grid size, distinct config_hash values for
that signal_id across all runs in the log): repeated runs raise the bar.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

from agents.cache import cache_root
from agents.envelope import utc_now_iso


def trials_path(root: Optional[Path] = None) -> Path:
    return (root or cache_root()) / "validate" / "trials.jsonl"


def config_hash(params: Dict[str, Any], costs: Dict[str, Any], universe: Iterable[str],
                data_range: Dict[str, str]) -> str:
    blob = json.dumps({"params": params, "costs": costs, "universe": sorted(universe),
                       "data_range": data_range}, sort_keys=True, default=str, separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def append_trials(records: List[Dict[str, Any]], root: Optional[Path] = None) -> Path:
    """Append RECORDS (dicts; ts added when missing) as JSONL lines."""
    path = trials_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    ts = utc_now_iso()
    lines = []
    for r in records:
        rec = dict(r)
        rec.setdefault("ts", ts)
        lines.append(json.dumps(rec, sort_keys=False, default=str, allow_nan=False) + "\n")
    data = "".join(lines).encode("utf-8")
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    return path


def read_trials(root: Optional[Path] = None) -> List[Dict[str, Any]]:
    path = trials_path(root)
    out: List[Dict[str, Any]] = []
    if not path.is_file():
        return out
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
    return out


def distinct_configs(signal_id: str, root: Optional[Path] = None) -> int:
    return len({r.get("config_hash") for r in read_trials(root)
                if r.get("signal_id") == signal_id and r.get("config_hash")})


def n_trials(signal_id: str, grid_size: int, root: Optional[Path] = None) -> int:
    """DSR trial count N = max(grid size, distinct logged config hashes)."""
    return max(int(grid_size), distinct_configs(signal_id, root))
