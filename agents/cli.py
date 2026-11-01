"""Single CLI: python -m agents <agent> <command> [options].

Agents:   market | fundamental | technical | quant | validate | portfolio
Commands: run | status | train | gate   (validate adds its own, e.g. parity)
Exit codes: 0 ok, 1 error (incl. not_implemented), 2 data unavailable.

`python -m agents status` (top level or any agent) prints the agent version,
the venv python, the endpoint mode, has_<key> booleans and the cache dir. It
never prints a key value.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Callable, Dict, List, Optional, Tuple

from agents import AGENT_NAMES, __version__

EXIT_OK, EXIT_ERROR, EXIT_UNAVAILABLE = 0, 1, 2
COMMANDS = ("run", "status", "train", "gate")

# (agent, command) -> handler(args) -> exit code. Later phases register here.
HANDLERS: Dict[Tuple[str, str], Callable[[argparse.Namespace], int]] = {}


def emit(obj) -> None:
    """Print OBJ as one JSON document on stdout."""
    sys.stdout.write(json.dumps(obj, indent=2, sort_keys=False, default=str) + "\n")
    sys.stdout.flush()


def error(obj: dict, code: int = EXIT_ERROR) -> int:
    emit(obj)
    return code


class _Parser(argparse.ArgumentParser):
    """argparse exits 2 on usage errors; 2 means 'data unavailable' here."""

    def error(self, message):  # noqa: D401
        emit({"error": "usage", "detail": message})
        sys.exit(EXIT_ERROR)


def build_parser() -> argparse.ArgumentParser:
    p = _Parser(prog="python -m agents", description="StockSwingTrader agent layer (read-only, paper)")
    p.add_argument("agent", nargs="?", help="|".join(AGENT_NAMES) + " (or 'status')")
    p.add_argument("command", nargs="?", help="|".join(COMMANDS))
    p.add_argument("--symbols", help="Comma-separated symbols, e.g. AAPL,MSFT")
    p.add_argument("--as-of", dest="as_of", help="YYYY-MM-DD (default: today, America/New_York)")
    p.add_argument("--offline", action="store_true", help="Fixtures only (same as SST_OFFLINE=1)")
    p.add_argument("--start", help="Start date YYYY-MM-DD")
    p.add_argument("--end", help="End date YYYY-MM-DD")
    p.add_argument("--signals", help="Comma-separated signal ids")
    p.add_argument("--benchmark", help="Benchmark symbol (default SPY)")
    p.add_argument("--report-dir", dest="report_dir", help="Directory for reports")
    p.add_argument("--version", action="store_true", help="Print the agent layer version")
    return p


def parse_symbols(raw: Optional[str]) -> List[str]:
    """'aapl, msft' -> ['AAPL', 'MSFT']; raises ValueError on a bad symbol."""
    from agents.cache import check_symbol

    if not raw:
        return []
    return [check_symbol(s.strip().upper()) for s in raw.split(",") if s.strip()]


def status_payload(agent: Optional[str] = None) -> dict:
    """Status JSON: names and booleans only, never values."""
    from agents.cache import cache_root
    from agents.config import SECRET_NAMES, endpoint_mode, load_config

    cfg = load_config()
    out = {
        "agent": agent,
        "agents_version": __version__,
        "python": sys.executable,
        "python_version": "%d.%d.%d" % sys.version_info[:3],
        "endpoint_mode": endpoint_mode(cfg),
        "offline": os.environ.get("SST_OFFLINE") == "1",
        "agents_enabled": (cfg.get("AGENTS_ENABLED") or "false") == "true",
        "llm_provider": (cfg.get("LLM_PROVIDER") or "none"),
        "cache_dir": str(cache_root()),
    }
    for name in SECRET_NAMES:
        out["has_" + name.lower()] = cfg.has(name)
    return out


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if args.version:
        emit({"agents_version": __version__})
        return EXIT_OK
    if args.offline:
        os.environ["SST_OFFLINE"] = "1"
    if args.as_of and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.as_of):
        return error({"error": "invalid_as_of", "detail": "use YYYY-MM-DD"})

    agent, command = args.agent, args.command
    if agent is None or (agent == "status" and command is None):
        try:
            emit(status_payload(None))
        except Exception as exc:  # config reader failure etc.
            return error({"error": "status_failed", "detail": type(exc).__name__})
        return EXIT_OK
    if agent not in AGENT_NAMES:
        return error({"error": "unknown_agent", "agent": agent, "agents": list(AGENT_NAMES)})
    if command is None:
        return error({"error": "missing_command", "agent": agent, "commands": list(COMMANDS)})

    handler = HANDLERS.get((agent, command))
    if handler is None and command == "status":
        emit(status_payload(agent))
        return EXIT_OK
    if handler is None:
        if command in COMMANDS:
            return error({"error": "not_implemented", "agent": agent, "command": command})
        return error({"error": "unknown_command", "agent": agent, "command": command,
                      "commands": list(COMMANDS)})
    try:
        return int(handler(args))
    except Exception as exc:
        from agents.config import SafetyError

        if isinstance(exc, SafetyError):
            return error({"error": "safety", "agent": agent, "detail": str(exc)})
        return error({"error": "internal", "agent": agent, "detail": "%s: %s" % (type(exc).__name__, exc)})


if __name__ == "__main__":
    sys.exit(main())
