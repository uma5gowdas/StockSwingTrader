"""Configuration loader for the agent layer.

Keys are read the same way the bash agent reads them: a bash subprocess
sources config.template.sh and then ${SST_CONFIG_FILE:-<project>/config.sh}
(if present) and prints NUL-separated name/value pairs for a whitelist of
names (plus every AGENT_* / LLM_* variable). Non-empty file values win; the
process environment is the fallback.

Values are never printed or logged: Config.__repr__ masks them and status
output only reports has_<key> booleans.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Dict, Iterator, Optional
from urllib.parse import urlparse

PROJECT_ROOT = Path(__file__).resolve().parent.parent

# Names read from the config files (values are secrets for the KEY/SECRET ones)
WHITELIST = (
    "ALPACA_API_KEY",
    "ALPACA_SECRET_KEY",
    "ALPACA_BASE_URL",
    "ALPACA_DATA_URL",
    "API_KEY_FINNHUB",
    "API_KEY_NEWSAPI",
    "FRED_API_KEY",
    "SEC_USER_AGENT",
)
# Names whose presence (not value) is reported by `python -m agents status`
SECRET_NAMES = (
    "ALPACA_API_KEY",
    "ALPACA_SECRET_KEY",
    "API_KEY_FINNHUB",
    "API_KEY_NEWSAPI",
    "FRED_API_KEY",
    "SEC_USER_AGENT",
)
# Template placeholders that do not count as a configured key
PLACEHOLDERS = ("", "demo", "your_key_here", "changeme")

PAPER_HOST = "paper-api.alpaca.markets"
CONFIG_TIMEOUT_SECONDS = 15

_BASH_READER = r'''
src="$1"; shift
source "$src/config.template.sh" >/dev/null 2>&1 </dev/null
f="${SST_CONFIG_FILE:-$src/config.sh}"
if [[ -f "$f" ]]; then source "$f" >/dev/null 2>&1 </dev/null; fi
for n in "$@" $(compgen -v | grep -E '^(AGENT|LLM)S?_'); do
    printf '%s\0%s\0' "$n" "${!n}"
done
'''


class SafetyError(RuntimeError):
    """Raised when an action would leave the paper / read-only envelope."""


class Config:
    """Read-only mapping of whitelisted config values; repr masks values."""

    def __init__(self, values: Dict[str, str]):
        self._values = dict(values)

    def get(self, name: str, default: Optional[str] = None) -> Optional[str]:
        value = self._values.get(name)
        if value is None or value == "":
            return default
        return value

    def __getitem__(self, name: str) -> str:
        return self._values[name]

    def __contains__(self, name: object) -> bool:
        return name in self._values

    def __iter__(self) -> Iterator[str]:
        return iter(sorted(self._values))

    def names(self):
        return sorted(self._values)

    def has(self, name: str) -> bool:
        """True when NAME holds a non-placeholder value (value not exposed)."""
        value = (self._values.get(name) or "").strip()
        return value.lower() not in PLACEHOLDERS and not value.upper().startswith("YOUR_")

    def __repr__(self) -> str:
        shown = ", ".join(
            f"{n}={'<set>' if self._values.get(n) else '<empty>'}" for n in sorted(self._values)
        )
        return f"Config({shown})"

    __str__ = __repr__


def _read_config_files(env: Dict[str, str]) -> Dict[str, str]:
    """Run the bash reader; returns {} if bash fails or times out."""
    try:
        proc = subprocess.run(
            ["/bin/bash", "-c", _BASH_READER, "_", str(PROJECT_ROOT), *WHITELIST],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=CONFIG_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    parts = proc.stdout.split(b"\0")
    values: Dict[str, str] = {}
    for i in range(0, len(parts) - 1, 2):
        name = parts[i].decode("utf-8", "replace")
        if name:
            values[name] = parts[i + 1].decode("utf-8", "replace")
    return values


def _wanted(name: str) -> bool:
    return name in WHITELIST or name.startswith(("AGENT_", "AGENTS_", "LLM_"))


def load_config(env: Optional[Dict[str, str]] = None) -> Config:
    """Load whitelisted keys: non-empty config file values, else environment."""
    env = dict(os.environ if env is None else env)
    file_values = _read_config_files(env)
    names = set(WHITELIST)
    names.update(n for n in file_values if _wanted(n))
    names.update(n for n in env if _wanted(n))
    values: Dict[str, str] = {}
    for name in names:
        value = file_values.get(name, "")
        if value == "":
            value = env.get(name, "")
        values[name] = value
    return Config(values)


def endpoint_mode(cfg: Config) -> str:
    """PAPER, LOCAL (loopback stub) or LIVE, like broker_endpoint_mode."""
    url = cfg.get("ALPACA_BASE_URL", "") or ""
    if not url:
        return "PAPER"
    host = (urlparse(url).hostname or "").lower()
    if host == PAPER_HOST:
        return "PAPER"
    if host in ("127.0.0.1", "localhost", "::1"):
        return "LOCAL"
    return "LIVE"


def assert_paper(cfg: Config) -> None:
    """Raise SafetyError unless ALPACA_BASE_URL's host is paper-api.alpaca.markets."""
    url = cfg.get("ALPACA_BASE_URL", "") or ""
    host = (urlparse(url).hostname or "").lower() if url else ""
    if host != PAPER_HOST:
        raise SafetyError(
            "ALPACA_BASE_URL host must be %s for the agent layer (got %s)"
            % (PAPER_HOST, host or "<empty>")
        )
